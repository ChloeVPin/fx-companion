// Equivalence probe: stock single-threaded walk vs fx-companion parallel
// walk, same tree, byte-for-byte comparison of the sorted relative path
// list. Exercises both targets and the ignored_paths set.
const std = @import("std");
const companion = @import("../src/core/workspace/fx_companion.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
const Timespec = extern struct { sec: isize, nsec: isize };
fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sortPaths(paths: [][]const u8) void {
    std.mem.sort([]const u8, paths, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

// Reference: single-threaded getdirentries DFS with a 2 KB buffer. This is
// syscall-for-syscall what stock std.Io.Dir.Iterator performs (readdir is a
// thin wrapper over getdirentries), so agreement here means agreement with
// stock fx's walk output.
extern "c" fn opendir(path: [*]const u8) ?*anyopaque;
extern "c" fn readdir(dirp: *anyopaque) ?[*]u8;
extern "c" fn closedir(dirp: *anyopaque) c_int;
fn stockWalk(
    arena: std.mem.Allocator,
    root: []const u8,
    ignored_names: []const []const u8,
    target_files: bool,
    cap: usize,
    out: *std.ArrayList([]const u8),
) !bool { // returns incomplete
    var stack: std.ArrayList([]const u8) = .empty; // NUL-terminated prefixes
    try stack.append(arena, try arena.dupeZ(u8, ""));
    var incomplete = false;
    var overlong: usize = 0;
    defer {
        for (stack.items) |item| arena.free(item);
        stack.deinit(arena);
    }
    const dp0 = opendir(root.ptr) orelse return error.OpenFailed;
    _ = closedir(dp0);

    while (stack.pop()) |prefix| {
        if (incomplete) break;
        var pathbuf: [4096]u8 = undefined;
        if (prefix.len == 0) {
            @memcpy(pathbuf[0..root.len], root);
            pathbuf[root.len] = 0;
        } else {
            @memcpy(pathbuf[0..root.len], root);
            pathbuf[root.len] = '/';
            @memcpy(pathbuf[root.len + 1 ..][0..prefix.len], prefix);
            pathbuf[root.len + 1 + prefix.len] = 0;
        }

        const dp = opendir(&pathbuf) orelse continue;
        defer _ = closedir(dp);
        while (true) {
            const dent = readdir(dp) orelse break;
            // readdir is the 64-bit-inode variant on modern Darwin:
            // d_ino u64 @0, d_seekoff u64 @8, d_reclen u16 @16,
            // d_namlen u16 @18, d_type u8 @20, name @21. (The getdirentries
            // buffer uses the legacy 32-bit-ino layout; they differ!)
            const reclen = std.mem.readInt(u16, dent[16..18], .little);
            if (reclen == 0) break;
            const namlen: usize = std.mem.readInt(u16, dent[18..20], .little);
            const dtype = dent[20];
            const name = dent[21 .. 21 + namlen];
            const dot = name.len == 1 and name[0] == '.';
            const dotdot = name.len == 2 and name[0] == '.' and name[1] == '.';
            if (dot or dotdot) continue;
            if (dtype != 4) { // file or symlink: stock has NO hidden filter
                if (!target_files) continue;
                if (isIgnoredList(ignored_names, name)) continue;
                if (out.items.len >= cap) {
                    incomplete = true;
                    return incomplete;
                }
                const rel_len = if (prefix.len == 0) name.len else prefix.len + 1 + name.len;
                if (rel_len > 2048) {
                    overlong += 1;
                    continue;
                }
                const rel = if (prefix.len == 0)
                    try arena.dupe(u8, name)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
                try out.append(arena, rel);
                continue;
            }
            // directory: hidden filter (unless include_hidden), ignore list,
            // then recurse. Same order as workspace_files.zig.
            if (!include_hidden and isHiddenName(name)) continue;
            if (isIgnoredList(ignored_names, name)) continue;
            const child = if (prefix.len == 0)
                try arena.dupeZ(u8, name)
            else
                try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ prefix, name }, 0);
            if (!target_files) try out.append(arena, child);
            try stack.append(arena, child);
        }
    }
    return incomplete;
}

fn isHiddenName(name: []const u8) bool {
    return name.len > 1 and name[0] == '.';
}

var include_hidden = false;

fn isIgnoredList(list: []const []const u8, name: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const cap_arg: usize = if (args.next()) |a| std.fmt.parseInt(usize, a, 10) catch 100_000 else 100_000;

    var gpa_state = std.heap.DebugAllocator(.{}){};
    const gpa = gpa_state.allocator();

    inline for (.{ true, false }) |target_files| {
        const ignored_names_default = [_][]const u8{
            ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage",
        };
        const cap: usize = cap_arg;
        // --- stock ---
        var arena_stock = std.heap.ArenaAllocator.init(gpa);
        defer arena_stock.deinit();
        var stock_list: std.ArrayList([]const u8) = .empty;
        const t0 = nowNs();
        const inc_s = try stockWalk(arena_stock.allocator(), root, &ignored_names_default, target_files, cap, &stock_list);
        const t_stock = nowNs() - t0;
        sortPaths(stock_list.items);

        // --- companion ---
        var arena_c = std.heap.ArenaAllocator.init(gpa);
        defer arena_c.deinit();
        var comp_list: std.ArrayList([]const u8) = .empty;
        var overlong: usize = 0;
        const t1 = nowNs();
        const incomplete = try companion.walkPaths(
            arena_c.allocator(),
            root,
            &ignored_names_default,
            null,
            target_files,
            false,
            cap,
            2048,
            null,
            &comp_list,
            &overlong,
        );
        const t_comp = nowNs() - t1;
        sortPaths(comp_list.items);

        const label = if (target_files) "files" else "dirs";
        std.debug.print("[{s}] stock={d} entries {d}us inc={}| companion={d} entries {d}us incomplete={}\n", .{
            label, stock_list.items.len, t_stock / 1000, inc_s, comp_list.items.len, t_comp / 1000, incomplete,
        });

        if (stock_list.items.len != comp_list.items.len) {
            std.debug.print("MISMATCH counts: stock:\n", .{});
            for (stock_list.items) |p| std.debug.print("  S '{s}'\n", .{p});
            std.debug.print("companion:\n", .{});
            for (comp_list.items) |p| std.debug.print("  C '{s}'\n", .{p});
            return error.CountMismatch;
        }
        for (stock_list.items, comp_list.items, 0..) |a, b, i| {
            if (!std.mem.eql(u8, a, b)) {
                std.debug.print("MISMATCH at {d}: stock='{s}' companion='{s}'\n", .{ i, a, b });
                return error.ContentMismatch;
            }
        }
        std.debug.print("[{s}] IDENTICAL\n", .{label});
    }
}
