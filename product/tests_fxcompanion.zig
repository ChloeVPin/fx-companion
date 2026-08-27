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
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn __error() *c_int;
extern "c" fn system(command: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

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

fn gitIdentityReady(root: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const head = std.fmt.bufPrintZ(&buf, "{s}/.git/HEAD", .{root}) catch return false;
    const fd_head = open(head.ptr, 0, 0);
    if (fd_head < 0) return false;
    _ = close(fd_head);
    const index = std.fmt.bufPrintZ(&buf, "{s}/.git/index", .{root}) catch return false;
    const fd_index = open(index.ptr, 0, 0);
    if (fd_index < 0) return false;
    _ = close(fd_index);
    return true;
}

fn verifyGitListEquivalence(root: []const u8, cap: usize, mutation_check: bool) !void {
    const options: workspace_files.Options = .{ .candidate_cap = cap };
    companion.clearSnapshotCache();
    const cold = try compareFiles(root, options, "files/git-primary-cold");
    const warm = try compareFiles(root, options, "files/git-primary-warm");
    const ready = gitIdentityReady(root);
    if (ready) {
        if (cold.hit) return error.UnexpectedGitColdCacheHit;
        if (!warm.hit) return error.MissingGitWarmCacheHit;
    } else {
        std.debug.print("[files/git-primary] no git identity; cache hit not required\n", .{});
    }
    if (!mutation_check or !ready) return;

    var mutation_buf: [1024]u8 = undefined;
    const mutation_path = try std.fmt.bufPrintZ(&mutation_buf, "{s}/.fxc-git-list-untracked", .{root});
    const O_WRONLY: c_int = 0x0001;
    const O_CREAT: c_int = 0x0200;
    const O_EXCL: c_int = 0x0800;
    const fd = open(mutation_path.ptr, O_WRONLY | O_CREAT | O_EXCL, @as(c_uint, 0o600));
    if (fd < 0) return error.CreateGitUntrackedFailed;
    var fd_open = true;
    defer {
        if (fd_open) _ = close(fd);
    }
    var mutation_exists = true;
    defer {
        if (mutation_exists) _ = unlink(mutation_path.ptr);
    }

    const after_create = try compareFiles(root, options, "files/git-primary-after-untracked-create");
    if (!after_create.hit) return error.GitCacheMissAfterUntrackedCreate;
    if (ftruncate(fd, 1) != 0) return error.WriteGitUntrackedFailed;
    const after_write = try compareFiles(root, options, "files/git-primary-after-untracked-write");
    if (!after_write.hit) return error.GitCacheMissAfterUntrackedWrite;
    _ = close(fd);
    fd_open = false;
    if (unlink(mutation_path.ptr) != 0) return error.DeleteGitUntrackedFailed;
    mutation_exists = false;
    const after_delete = try compareFiles(root, options, "files/git-primary-after-untracked-delete");
    if (!after_delete.hit) return error.GitCacheMissAfterUntrackedDelete;
}

fn runShell(cmd: [*:0]const u8) !void {
    const rc = system(cmd);
    if (rc != 0) {
        std.debug.print("cmd failed rc={d}: {s}\n", .{ rc, cmd });
        return error.GitCommandFailed;
    }
}

/// Throwaway git repo: tracked content-only stays warm; index/branch miss.
fn verifyGitIdentityMutations() !void {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/fxc-git-id-{d}", .{nowNs()});
    if (mkdir(path.ptr, 0o700) != 0) return error.TempDirFailed;
    var cmd_buf: [768]u8 = undefined;
    var cleaned = false;
    defer {
        if (!cleaned) {
            if (std.fmt.bufPrintZ(&cmd_buf, "rm -rf {s}", .{path})) |rm| {
                _ = system(rm);
            } else |_| {}
        }
    }

    const init_cmd = try std.fmt.bufPrintZ(
        &cmd_buf,
        "printf 'hello\\n' > {s}/tracked.txt && git -C {s} init -q && git -C {s} add tracked.txt && git -C {s} -c user.email=fxc@test -c user.name=fxc -c commit.gpgsign=false commit -qm init",
        .{ path, path, path, path },
    );
    try runShell(init_cmd);

    const options: workspace_files.Options = .{ .candidate_cap = 100_000 };
    companion.clearSnapshotCache();
    const cold = try compareFiles(path, options, "files/git-id-cold");
    if (cold.hit) return error.UnexpectedGitIdColdHit;
    const warm = try compareFiles(path, options, "files/git-id-warm");
    if (!warm.hit) return error.MissingGitIdWarmHit;

    var tracked_buf: [160]u8 = undefined;
    const tracked = try std.fmt.bufPrintZ(&tracked_buf, "{s}/tracked.txt", .{path});
    const fd = open(tracked.ptr, 0x0001, 0);
    if (fd < 0) return error.OpenTrackedFailed;
    if (ftruncate(fd, 8) != 0) {
        _ = close(fd);
        return error.TrackedContentWriteFailed;
    }
    _ = close(fd);
    const after_content = try compareFiles(path, options, "files/git-id-after-tracked-content");
    if (!after_content.hit) return error.GitCacheMissAfterTrackedContent;

    const extra_cmd = try std.fmt.bufPrintZ(&cmd_buf, "printf 'u\\n' > {s}/untracked.txt", .{path});
    try runShell(extra_cmd);
    // Default discover stays the tracked snapshot (1 path). Untracked modes must
    // exec git, not serve that snapshot — stock/boosted counts would diverge.
    const after_untracked_file = try compareFiles(path, options, "files/git-id-after-untracked-file");
    if (!after_untracked_file.hit) return error.GitCacheMissAfterUntrackedFile;
    _ = try compareFiles(path, .{
        .candidate_cap = 100_000,
        .include_untracked = true,
    }, "files/git-id-include-untracked");
    _ = try compareFiles(path, .{
        .candidate_cap = 100_000,
        .only_untracked = true,
    }, "files/git-id-only-untracked");

    const add_cmd = try std.fmt.bufPrintZ(
        &cmd_buf,
        "printf 'n\\n' > {s}/added.txt && git -C {s} add added.txt",
        .{ path, path },
    );
    try runShell(add_cmd);
    const after_add = try compareFiles(path, options, "files/git-id-after-index-add");
    if (after_add.hit) return error.StaleGitCacheAfterIndexAdd;
    const after_add_warm = try compareFiles(path, options, "files/git-id-after-index-add-warm");
    if (!after_add_warm.hit) return error.MissingGitWarmAfterIndexAdd;

    const branch_cmd = try std.fmt.bufPrintZ(&cmd_buf, "git -C {s} checkout -q -b fxc-other", .{path});
    try runShell(branch_cmd);
    const after_branch = try compareFiles(path, options, "files/git-id-after-branch");
    if (after_branch.hit) return error.StaleGitCacheAfterBranch;

    const rm_cmd = try std.fmt.bufPrintZ(&cmd_buf, "rm -rf {s}", .{path});
    _ = system(rm_cmd);
    cleaned = true;
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
    var fd_open = true;
    defer {
        if (fd_open) _ = close(fd);
    }
    var mutation_exists = true;
    defer {
        if (mutation_exists) _ = unlink(mutation_path.ptr);
    }

    const after_create = try compareFiles(root, options, "cache/after-create");
    if (after_create.hit) return error.StaleCacheAfterCreate;
    if (ftruncate(fd, 1) != 0) {
        std.debug.print("cache content mutation failed errno={d} path={s}\n", .{ __error().*, mutation_path });
        return error.WriteMutationFailed;
    }
    const after_content_write = try compareFiles(root, options, "cache/after-content-write");
    if (!after_content_write.hit) return error.CacheMissAfterContentOnlyWrite;
    _ = close(fd);
    fd_open = false;
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

    try verifyGitListEquivalence(root, cap, mutation_check);
    if (mutation_check) try verifyGitIdentityMutations();
    if (mutation_check) try verifyCacheInvalidation(root, cap);

    const case_count: usize = blk: {
        var n: usize = 9;
        if (mutation_check) n += 5;
        if (mutation_check and gitIdentityReady(root)) n += 3;
        if (mutation_check) n += 9;
        break :blk n;
    };
    std.debug.print("EQUIVALENCE_OK cases={d}\n", .{case_count});
}
