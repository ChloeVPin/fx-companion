//! readdir + lstat baseline via libc, mirroring classic du behavior.
//! Uses the system dirent/stat layouts through @cImport - no transcribed
//! structs.

const std = @import("std");
const shared = @import("fts_walk.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("string.h");
});

pub const WalkOut = shared.WalkOut;

var path_buf: [1024]u8 = undefined;

pub fn walkNames(root: []const u8) !WalkOut {
    var entries: u64 = 0;
    var bytes: u64 = 0;
    try start(root, false, &entries, &bytes);
    return .{ .entries = entries, .bytes_sum = bytes };
}

pub fn walkAttrs(root: []const u8) !WalkOut {
    var entries: u64 = 0;
    var bytes: u64 = 0;
    try start(root, true, &entries, &bytes);
    return .{ .entries = entries, .bytes_sum = bytes };
}

fn start(root: []const u8, want_attrs: bool, entries: *u64, bytes: *u64) !void {
    if (root.len >= path_buf.len - 2) return error.PathTooLong;
    @memcpy(path_buf[0..root.len], root);
    path_buf[root.len] = 0;
    recursePath(root.len, want_attrs, entries, bytes);
}

/// path_buf[0..len] holds the current directory path.
fn recursePath(len: usize, want_attrs: bool, entries: *u64, bytes: *u64) void {
    path_buf[len] = 0;
    const dp = c.opendir(@ptrCast(&path_buf)) orelse return;
    defer _ = c.closedir(dp);

    while (true) {
        const ent = c.readdir(dp) orelse break;
        const name_len = ent.*.d_namlen;
        const name = ent.*.d_name[0..name_len];
        // Skip "." and ".."
        if (name_len == 1 and name[0] == '.') continue;
        if (name_len == 2 and name[0] == '.' and name[1] == '.') continue;
        entries.* += 1;

        const dt_dir = ent.*.d_type == c.DT_DIR;
        const dt_reg = ent.*.d_type == c.DT_REG;
        if (!dt_dir and !dt_reg) continue;
        if (len + 1 + name_len >= path_buf.len - 1) continue;

        path_buf[len] = '/';
        @memcpy(path_buf[len + 1 ..][0..name_len], name);
        const child_len = len + 1 + name_len;

        if (dt_dir) {
            recursePath(child_len, want_attrs, entries, bytes);
        } else if (want_attrs) {
            path_buf[child_len] = 0;
            var st: c.struct_stat = undefined;
            if (c.lstat(@ptrCast(&path_buf), &st) == 0) {
                if (st.st_size > 0) bytes.* += @intCast(st.st_size);
            }
        }
    }
}
