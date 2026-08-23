//! getattrlistbulk-based traversal using sys/attr.h via @cImport.
//!
//! Record layout (verified by hexdump on macOS 27 / arm64):
//!   +0  u32 entry_length          stride to next record
//!   +4  u32 returned.commonattr   (attribute_set_t commonattr group only;
//!                                  vol/dir/file groups are zero here)
//!   +8  u32 returned.fileattr
//!   +12 u32 reserved              (bitmapcount padding to 16B header)
//!   then requested fields in THIS order (not ascending bit order!):
//!     ATTR_CMN_ERROR    u32
//!     ATTR_CMN_NAME     attrreference_t {i32 dataoffset; u32 length;}
//!                       name bytes live at record_start+dataoffset, NUL-terminated
//!     ATTR_CMN_OBJTYPE  u32
//!     ATTR_CMN_FILEID   u64
//!     ATTR_FILE_DATALENGTH u64
//!
//! Empirical rule: fields appear in descending bit order of their request
//! bits within each attribute group; groups in request order.

const std = @import("std");
const shared = @import("fts_walk.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/attr.h");
    @cInclude("unistd.h");
});

pub const WalkOut = shared.WalkOut;

const BUF_SIZE: usize = 128 * 1024; // healeycodes found this optimal

fn makeAttrlist() c.attrlist {
    return .{
        .bitmapcount = c.ATTR_BIT_MAP_COUNT,
        .reserved = 0,
        .commonattr = c.ATTR_CMN_RETURNED_ATTRS |
            c.ATTR_CMN_NAME |
            c.ATTR_CMN_OBJTYPE |
            c.ATTR_CMN_FILEID |
            c.ATTR_CMN_ERROR,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = c.ATTR_FILE_DATALENGTH,
        .forkattr = 0,
    };
}

fn rdU32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
fn rdI32(p: [*]const u8) i32 {
    return std.mem.readInt(i32, p[0..4], .little);
}
fn rdU64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}

// Directory paths live in one big heap block: DIR_CAP dirs x 512 bytes.
const DIR_CAP = 8192;
var dir_block: ?[]u8 = null;

fn getDir(idx: usize) *[512]u8 {
    if (dir_block == null) {
        dir_block = std.heap.c_allocator.alloc(u8, DIR_CAP * 512) catch @panic("oom");
    }
    return @ptrCast(dir_block.?[idx * 512 ..][0..512]);
}

pub fn walkNames(root: []const u8) !WalkOut {
    return walkCommon(root, false);
}

pub fn walkAttrs(root: []const u8) !WalkOut {
    return walkCommon(root, true);
}

fn walkCommon(root: []const u8, sum_sizes: bool) !WalkOut {
    if (root.len >= 512) return error.PathTooLong;
    var lens: [DIR_CAP]usize = undefined;

    @memcpy(getDir(0)[0..root.len], root);
    lens[0] = root.len;
    var stack: [DIR_CAP]usize = undefined;
    stack[0] = 0; // seed: root sits at dir index 0
    var top: usize = 1;
    var dirs_seen: usize = 1;

    const buffer = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch return error.Oom;
    defer std.heap.c_allocator.free(buffer);

    const attrs = makeAttrlist();

    var entries: u64 = 0;
    var bytes: u64 = 0;

    while (top > 0) {
        top -= 1;
        const idx = stack[top];
        const cur_len = lens[idx];
        const cur = getDir(idx);
        cur[cur_len] = 0;
        cur_z: {
            const dfd = c.open(@ptrCast(cur), c.O_RDONLY);
            if (dfd < 0) break :cur_z;
            defer _ = c.close(dfd);

            while (true) {
                const n = c.getattrlistbulk(dfd, @constCast(@ptrCast(&attrs)), buffer.ptr, BUF_SIZE, 0);
                if (n <= 0) break; // 0 exhausted; negative treated as done

                var p: usize = 0;
                var i: usize = 0;
                while (i < @as(usize, @intCast(n))) : (i += 1) {
                    const rec = buffer.ptr + p;
                    const entry_len = rdU32(rec);
                    if (entry_len == 0 or p + entry_len > BUF_SIZE) break;

                    // Fixed layout for this fixed request (verified by hexdump):
                    //   +0x00 u32 entry_len
                    //   +0x04 attribute_set_t (20 B)
                    //   +0x18 attrreference_t NAME (dataoffset relative to +0x18)
                    //   +0x20 u32 objtype
                    //   +0x28 u64 fileid        (4-byte pad before)
                    //   +0x30 u64 datalen       (files only)
                    //   name blob inline; record padded to 8.
                    const ref_addr = p + 0x18;
                    const off = rdI32(rec + 0x18);
                    const ln = rdU32(rec + 0x1C);
                    const obj_type = rdU32(rec + 0x20);
                    const datalen = rdU64(rec + 0x30);

                    var name: []const u8 = "";
                    if (ln > 0) {
                        const nb_i = @as(i64, @intCast(ref_addr)) + off;
                        if (nb_i >= 0 and nb_i + ln <= BUF_SIZE) {
                            const nb: usize = @intCast(nb_i);
                            const span = @min(ln - 1, BUF_SIZE - nb);
                            const nul = std.mem.indexOfScalar(u8, buffer[nb..][0..span], 0) orelse span;
                            name = buffer[nb..][0..nul];
                        }
                    }

                    if (name.len > 0 and !(name.len == 1 and name[0] == '.') and
                        !(name.len == 2 and name[0] == '.' and name[1] == '.'))
                    {
                        entries += 1;
                        if (obj_type == 1 and sum_sizes) { // vreg
                            if (datalen > 0) bytes += datalen;
                        } else if (obj_type == 2 and dirs_seen < DIR_CAP and top < DIR_CAP) { // vdir
                            const dst = getDir(dirs_seen);
                            if (cur_len + 1 + name.len < 512) {
                                @memcpy(dst[0..cur_len], cur[0..cur_len]);
                                dst[cur_len] = '/';
                                @memcpy(dst[cur_len + 1 ..][0..name.len], name);
                                lens[dirs_seen] = cur_len + 1 + name.len;
                                dirs_seen += 1;
                                stack[top] = dirs_seen - 1;
                                top += 1;
                            }
                        }
                    }

                    p += entry_len;
                }
            }
        }
    }

    return .{ .entries = entries, .bytes_sum = bytes };
}
