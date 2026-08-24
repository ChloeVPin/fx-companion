//! Public-API equivalence gate for fx-companion.
//!
//! This file is copied to `src/tests_fxcompanion.zig` after injection. Each
//! case runs the real pinned fx workspace walker twice in one process: first
//! with the companion disabled, then with it enabled. The comparison includes
//! path bytes, path order, source, truncation metadata, and overlong counts.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");
const workspace_files = @import("core/workspace/workspace_files.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
extern "c" fn alarm(seconds: c_uint) c_uint;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn truncate(path: [*:0]const u8, length: i64) c_int;
extern "c" fn __error() *c_int;

const Timespec = extern struct { sec: isize, nsec: isize };

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn comparePaths(label: []const u8, stock: []const []const u8, boosted: []const []const u8) !void {
    if (stock.len != boosted.len) {
        std.debug.print("[{s}] MISMATCH count stock={d} boosted={d}\n", .{ label, stock.len, boosted.len });
        return error.CountMismatch;
    }
    for (stock, boosted, 0..) |stock_path, boosted_path, index| {
        if (!std.mem.eql(u8, stock_path, boosted_path)) {
            std.debug.print("[{s}] MISMATCH index={d} stock='{s}' boosted='{s}'\n", .{
                label,
                index,
                stock_path,
                boosted_path,
            });
            return error.ContentMismatch;
        }
    }
}

fn compareFiles(
    root: []const u8,
    options: workspace_files.Options,
    label: []const u8,
) !companion.CacheObservation {
    var stock_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer stock_arena.deinit();
    workspace_files.companion_enabled = false;
    const stock_started = nowNs();
    const stock = try workspace_files.discover(stock_arena.allocator(), root, options);
    const stock_ns = nowNs() - stock_started;

    var boosted_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer boosted_arena.deinit();
    workspace_files.companion_enabled = true;
    const boosted_started = nowNs();
    const boosted = try workspace_files.discover(boosted_arena.allocator(), root, options);
    const boosted_ns = nowNs() - boosted_started;

    if (stock.source != boosted.source or
        stock.candidate_cap != boosted.candidate_cap or
        stock.incomplete != boosted.incomplete or
        stock.cap_reason != boosted.cap_reason or
        stock.skipped_overlong != boosted.skipped_overlong)
    {
        std.debug.print(
            "[{s}] MISMATCH metadata stock=(source={s}, cap={d}, incomplete={}, reason={any}, overlong={d}) boosted=(source={s}, cap={d}, incomplete={}, reason={any}, overlong={d})\n",
            .{
                label,
                @tagName(stock.source),
                stock.candidate_cap,
                stock.incomplete,
                stock.cap_reason,
                stock.skipped_overlong,
                @tagName(boosted.source),
                boosted.candidate_cap,
                boosted.incomplete,
                boosted.cap_reason,
                boosted.skipped_overlong,
            },
        );
        return error.MetadataMismatch;
    }
    try comparePaths(label, stock.files, boosted.files);
    std.debug.print("[{s}] IDENTICAL paths={d} stock={d}us boosted={d}us\n", .{
        label,
        stock.files.len,
        stock_ns / 1000,
        boosted_ns / 1000,
    });
    return companion.lastCacheObservation();
}

fn verifyCacheInvalidation(root: []const u8, cap: usize) !void {
    const options: workspace_files.Options = .{
        .candidate_cap = cap,
        .force_fallback = true,
        .sort_paths = true,
    };
    companion.clearSnapshotCache();
    const cold = try compareFiles(root, options, "cache/cold");
    if (cold.hit) return error.UnexpectedColdCacheHit;
    const warm = try compareFiles(root, options, "cache/warm");
    if (!warm.hit) return error.MissingWarmCacheHit;

    var mutation_buf: [1024]u8 = undefined;
    const mutation_path = try std.fmt.bufPrintZ(&mutation_buf, "{s}/.fxc-cache-equivalence", .{root});
    const O_WRONLY: c_int = 0x0001;
    const O_CREAT: c_int = 0x0200;
    const O_EXCL: c_int = 0x0800;
    const fd = open(mutation_path.ptr, O_WRONLY | O_CREAT | O_EXCL, @as(c_uint, 0o600));
    if (fd < 0) return error.CreateMutationFailed;
    _ = close(fd);
    var mutation_exists = true;
    defer {
        if (mutation_exists) _ = unlink(mutation_path.ptr);
    }

    const after_create = try compareFiles(root, options, "cache/after-create");
    if (after_create.hit) return error.StaleCacheAfterCreate;
    if (truncate(mutation_path.ptr, 1) != 0) {
        std.debug.print("cache content mutation failed errno={d} path={s}\n", .{ __error().*, mutation_path });
        return error.WriteMutationFailed;
    }
    const after_content_write = try compareFiles(root, options, "cache/after-content-write");
    if (!after_content_write.hit) return error.CacheMissAfterContentOnlyWrite;
    if (unlink(mutation_path.ptr) != 0) return error.DeleteMutationFailed;
    mutation_exists = false;
    const after_delete = try compareFiles(root, options, "cache/after-delete");
    if (after_delete.hit) return error.StaleCacheAfterDelete;
}

fn compareDirectories(root: []const u8, options: workspace_files.Options, label: []const u8) !void {
    var stop_requested: std.atomic.Value(bool) = .init(false);

    var stock_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer stock_arena.deinit();
    workspace_files.companion_enabled = false;
    const stock_started = nowNs();
    const stock = try workspace_files.discoverDirectoriesCancellable(
        stock_arena.allocator(),
        root,
        options,
        &stop_requested,
    );
    const stock_ns = nowNs() - stock_started;

    var boosted_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer boosted_arena.deinit();
    workspace_files.companion_enabled = true;
    const boosted_started = nowNs();
    const boosted = try workspace_files.discoverDirectoriesCancellable(
        boosted_arena.allocator(),
        root,
        options,
        &stop_requested,
    );
    const boosted_ns = nowNs() - boosted_started;

    if (stock.source != boosted.source or
        stock.candidate_cap != boosted.candidate_cap or
        stock.incomplete != boosted.incomplete or
        stock.cap_reason != boosted.cap_reason or
        stock.skipped_overlong != boosted.skipped_overlong)
    {
        std.debug.print("[{s}] MISMATCH directory metadata\n", .{label});
        return error.MetadataMismatch;
    }
    try comparePaths(label, stock.directories, boosted.directories);
    std.debug.print("[{s}] IDENTICAL paths={d} stock={d}us boosted={d}us\n", .{
        label,
        stock.directories.len,
        stock_ns / 1000,
        boosted_ns / 1000,
    });
}

pub fn main(init: std.process.Init.Minimal) !void {
    // A regressed worker-pool wakeup must fail CI promptly, not consume the
    // workflow's full timeout.
    _ = alarm(60);
    defer _ = alarm(0);

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const cap = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 100_000;
    const mutation_check = if (args.next()) |raw| std.mem.eql(u8, raw, "--mutation-check") else false;

    if (!companion.active()) return error.CompanionInactive;
    defer workspace_files.companion_enabled = true;

    _ = try compareFiles(root, .{
        .candidate_cap = cap,
        .force_fallback = true,
        .sort_paths = true,
    }, "files/sorted");
    _ = try compareFiles(root, .{
        .candidate_cap = cap,
        .force_fallback = true,
        .sort_paths = false,
    }, "files/source-order");
    _ = try compareFiles(root, .{
        .candidate_cap = cap,
        .force_fallback = true,
        .include_hidden = true,
        .sort_paths = true,
    }, "files/hidden");
    _ = try compareFiles(root, .{
        .candidate_cap = 0,
        .force_fallback = true,
        .sort_paths = true,
    }, "files/zero-cap");

    try compareDirectories(root, .{
        .candidate_cap = cap,
        .force_fallback = true,
        .sort_paths = true,
    }, "dirs/sorted");
    try compareDirectories(root, .{
        .candidate_cap = cap,
        .force_fallback = true,
        .sort_paths = false,
    }, "dirs/source-order");
    // On a Git worktree this exercises fx's ignored-path set. Elsewhere it
    // still compares the public fallback behavior.
    try compareDirectories(root, .{
        .candidate_cap = cap,
        .sort_paths = true,
    }, "dirs/git-aware");

    if (mutation_check) try verifyCacheInvalidation(root, cap);

    const case_count: usize = if (mutation_check) 12 else 7;
    std.debug.print("EQUIVALENCE_OK cases={d}\n", .{case_count});
}
