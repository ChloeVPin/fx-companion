//! fx-companion: accelerated workspace traversal for Apple Silicon.
//!
//! Drop-in replacement for the inner loop of walkWorkspacePaths on
//! macOS/arm64. Same directory-read syscall family as stock (getdirentries,
//! which std.Io.Dir.Iterator drives through readdir), but with 128 KB
//! per-worker buffers and an 8-thread work-stealing pool instead of a
//! 2 KB-buffer single thread. Sorted results are packed into a process-local
//! snapshot; repeat walks validate directory identity, mtime, and ctime before
//! materializing it. Output is byte-identical: relative slash paths, same
//! ignore/hidden/cap/overlong rules, and stock's exact first-N selection when
//! a candidate cap truncates the walk.
//!
//! Fallback contract: on any unsupported platform or hard failure this
//! returns error.CompanionUnavailable and the caller retries through the
//! stock single-threaded path. FX_NO_COMPANION=1 disables it entirely.
//! Sync primitives use pthreads directly: Zig 0.16 removed
//! std.Thread.Mutex/Condition, and fx already links libc.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    CompanionUnavailable,
    Canceled,
    OutOfMemory,
};

// Path params are [*]const u8 rather than [*:0]: every path we pass IS
// NUL-terminated by construction (dupeZ/allocSentinel), and this keeps
// scan()'s slice params simple. The terminator requirement is enforced
// at the call sites that build strings, not by the type here.
extern "c" fn open(path: [*]const u8, flags: c_int) c_int;
extern "c" fn openat(fd: c_int, path: [*]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
// Fixed-arity libc call; safe to hand-declare. The silent-noop variadic
// trap applies only to fcntl-style varargs functions.
extern "c" fn getdirentries(fd: c_int, buf: [*]u8, nbytes: usize, basep: *i64) isize;

// Thin pthread shims (Darwin's pthread types are opaque through cImport;
// runtime-init with default attrs, same pattern proven in fx-companion).
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("pthread.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const PMutex = struct {
    inner: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),

    fn init(self: *PMutex) void {
        var attr: c.pthread_mutexattr_t = std.mem.zeroes(c.pthread_mutexattr_t);
        _ = c.pthread_mutexattr_init(&attr);
        _ = c.pthread_mutex_init(&self.inner, &attr);
        _ = c.pthread_mutexattr_destroy(&attr);
    }
    fn deinit(self: *PMutex) void {
        _ = c.pthread_mutex_destroy(&self.inner);
    }
    fn lock(self: *PMutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }
    fn unlock(self: *PMutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

const PCond = struct {
    inner: c.pthread_cond_t = std.mem.zeroes(c.pthread_cond_t),

    fn init(self: *PCond) void {
        var attr: c.pthread_condattr_t = std.mem.zeroes(c.pthread_condattr_t);
        _ = c.pthread_condattr_init(&attr);
        _ = c.pthread_cond_init(&self.inner, &attr);
        _ = c.pthread_condattr_destroy(&attr);
    }
    fn deinit(self: *PCond) void {
        _ = c.pthread_cond_destroy(&self.inner);
    }
    fn signal(self: *PCond) void {
        _ = c.pthread_cond_signal(&self.inner);
    }
    fn broadcast(self: *PCond) void {
        _ = c.pthread_cond_broadcast(&self.inner);
    }
    fn wait(self: *PCond, mu: *PMutex) void {
        _ = c.pthread_cond_wait(&self.inner, &mu.inner);
    }
};

const O_RDONLY: c_int = 0;
const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;
const DT_LNK: u8 = 10;
const BUF_SIZE: usize = 128 * 1024;
const WORKERS: usize = 8;
const CACHE_KEY_BYTES: usize = 2048;
const CACHE_VALIDATE_WORKERS: usize = 8;
const CACHE_MAX_PATHS: usize = 1_000_000;
const CACHE_MAX_DIRECTORIES: usize = 100_000;
const CACHE_MAX_PATH_BYTES: usize = 128 * 1024 * 1024;
const CACHE_MAX_DIRECTORY_BYTES: usize = 64 * 1024 * 1024;

const CachedPath = struct {
    offset: u32,
    len: u32,
};

const CachedDirectory = struct {
    path: [:0]u8,
    expected: c.struct_stat,
};

const CapturedDirectory = struct {
    path: [:0]u8,
    before: c.struct_stat,
};

const SnapshotCache = struct {
    mu: PMutex = .{},
    valid: bool = false,
    key: [CACHE_KEY_BYTES]u8 = undefined,
    key_len: usize = 0,
    blob: ?[]u8 = null,
    paths: ?[]CachedPath = null,
    directories: ?[]CachedDirectory = null,
    incomplete: bool = false,
    overlong: usize = 0,

    fn clearLocked(self: *SnapshotCache) void {
        if (self.blob) |blob| std.heap.c_allocator.free(blob);
        if (self.paths) |paths| std.heap.c_allocator.free(paths);
        if (self.directories) |directories| {
            for (directories) |directory| std.heap.c_allocator.free(directory.path);
            std.heap.c_allocator.free(directories);
        }
        self.valid = false;
        self.key_len = 0;
        self.blob = null;
        self.paths = null;
        self.directories = null;
        self.incomplete = false;
        self.overlong = 0;
    }
};

const CacheKey = struct {
    bytes: [CACHE_KEY_BYTES]u8 = undefined,
    len: usize = 0,

    fn append(self: *CacheKey, bytes: []const u8) bool {
        if (bytes.len > self.bytes.len - self.len) return false;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return true;
    }

    fn appendU64(self: *CacheKey, input: usize) bool {
        const value: u64 = @intCast(input);
        return self.append(std.mem.asBytes(&value));
    }
};

var snapshot_cache: SnapshotCache = .{};
var snapshot_cache_init: std.atomic.Value(u8) = .init(0);
var last_cache_hit: std.atomic.Value(bool) = .init(false);
var last_cache_validation_ns: std.atomic.Value(u64) = .init(0);
var last_walk_directories: std.atomic.Value(u64) = .init(0);
var last_walk_syscalls: std.atomic.Value(u64) = .init(0);
var last_walk_dirent_bytes: std.atomic.Value(u64) = .init(0);
var last_walk_entries: std.atomic.Value(u64) = .init(0);

fn getSnapshotCache() *SnapshotCache {
    while (true) {
        switch (snapshot_cache_init.load(.acquire)) {
            0 => {
                if (snapshot_cache_init.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                    snapshot_cache.mu.init();
                    snapshot_cache_init.store(2, .release);
                    return &snapshot_cache;
                }
            },
            1 => std.atomic.spinLoopHint(),
            2 => return &snapshot_cache,
            else => unreachable,
        }
    }
}

fn makeCacheKey(
    workspace_root: []const u8,
    ignored_names: []const []const u8,
    target_files: bool,
    include_hidden: bool,
    candidate_cap: usize,
    max_relative_path_bytes: usize,
) ?CacheKey {
    var key = CacheKey{};
    const flags = [_]u8{
        1, // cache format version
        @intFromBool(target_files),
        @intFromBool(include_hidden),
    };
    if (!key.append(&flags) or
        !key.appendU64(workspace_root.len) or
        !key.append(workspace_root) or
        !key.appendU64(candidate_cap) or
        !key.appendU64(max_relative_path_bytes) or
        !key.appendU64(ignored_names.len)) return null;
    for (ignored_names) |ignored| {
        if (!key.appendU64(ignored.len) or !key.append(ignored)) return null;
    }
    return key;
}

fn cacheKeyMatches(cache: *const SnapshotCache, key: *const CacheKey) bool {
    return cache.valid and cache.key_len == key.len and
        std.mem.eql(u8, cache.key[0..cache.key_len], key.bytes[0..key.len]);
}

fn sameDirectoryStamp(left: c.struct_stat, right: c.struct_stat) bool {
    return left.st_dev == right.st_dev and
        left.st_ino == right.st_ino and
        left.st_mode == right.st_mode and
        left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec and
        left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec and
        left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec and
        left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

fn cacheFilesystemSupported(root_fd: c_int) bool {
    var filesystem: c.struct_statfs = undefined;
    if (c.fstatfs(root_fd, &filesystem) != 0) return false;
    const name: [*]const u8 = @ptrCast(&filesystem.f_fstypename);
    return std.mem.eql(u8, name[0..4], "apfs") and name[4] == 0;
}

const CacheValidationContext = struct {
    root_fd: c_int,
    directories: []const CachedDirectory,
    changed: std.atomic.Value(bool) = .init(false),
};

fn validateCacheLane(context: *CacheValidationContext, lane: usize) void {
    var index = lane;
    while (index < context.directories.len) : (index += CACHE_VALIDATE_WORKERS) {
        if (context.changed.load(.acquire)) return;
        const directory = context.directories[index];
        var current: c.struct_stat = undefined;
        const rc = if (directory.path.len == 0)
            c.fstat(context.root_fd, &current)
        else
            c.fstatat(context.root_fd, directory.path.ptr, &current, c.AT_SYMLINK_NOFOLLOW);
        if (rc != 0 or !sameDirectoryStamp(directory.expected, current)) {
            context.changed.store(true, .release);
            return;
        }
    }
}

fn validateCacheSequential(root_fd: c_int, directories: []const CachedDirectory) bool {
    for (directories) |directory| {
        var current: c.struct_stat = undefined;
        const rc = if (directory.path.len == 0)
            c.fstat(root_fd, &current)
        else
            c.fstatat(root_fd, directory.path.ptr, &current, c.AT_SYMLINK_NOFOLLOW);
        if (rc != 0 or !sameDirectoryStamp(directory.expected, current)) return false;
    }
    return true;
}

fn validateDirectorySnapshot(directories: []const CachedDirectory, workspace_root: []const u8) bool {
    var root_buf: [512]u8 = undefined;
    if (workspace_root.len >= root_buf.len) return false;
    @memcpy(root_buf[0..workspace_root.len], workspace_root);
    root_buf[workspace_root.len] = 0;
    const root_fd = open(&root_buf, O_RDONLY);
    if (root_fd < 0) return false;
    defer _ = close(root_fd);
    if (!cacheFilesystemSupported(root_fd)) return false;

    var context = CacheValidationContext{ .root_fd = root_fd, .directories = directories };
    var threads: [CACHE_VALIDATE_WORKERS - 1]std.Thread = undefined;
    var started: usize = 0;
    var spawn_failed = false;
    for (&threads, 1..) |*thread, lane| {
        thread.* = std.Thread.spawn(.{}, validateCacheLane, .{ &context, lane }) catch {
            spawn_failed = true;
            break;
        };
        started += 1;
    }
    if (!spawn_failed) validateCacheLane(&context, 0);
    for (threads[0..started]) |thread| thread.join();
    if (context.changed.load(.acquire)) return false;
    if (spawn_failed) return validateCacheSequential(root_fd, directories);
    return true;
}

fn validateSnapshot(cache: *const SnapshotCache, workspace_root: []const u8) bool {
    return validateDirectorySnapshot(cache.directories orelse return false, workspace_root);
}

fn materializeSnapshot(
    cache: *const SnapshotCache,
    arena: std.mem.Allocator,
    out_paths: *std.ArrayList([]const u8),
    out_overlong: *usize,
) Error!void {
    const blob = cache.blob orelse return error.CompanionUnavailable;
    const paths = cache.paths orelse return error.CompanionUnavailable;
    const owned_blob = arena.dupe(u8, blob) catch return error.OutOfMemory;
    errdefer arena.free(owned_blob);
    out_paths.ensureUnusedCapacity(arena, paths.len) catch return error.OutOfMemory;
    for (paths) |path| {
        const start: usize = path.offset;
        const len: usize = path.len;
        if (start > owned_blob.len or len > owned_blob.len - start) return error.CompanionUnavailable;
        out_paths.appendAssumeCapacity(owned_blob[start .. start + len]);
    }
    out_overlong.* = cache.overlong;
}

const BuiltSnapshot = struct {
    blob: []u8,
    paths: []CachedPath,
    directories: []CachedDirectory,
};

const BuiltPaths = struct {
    blob: []u8,
    paths: []CachedPath,
};

fn freeCachedDirectories(directories: []CachedDirectory) void {
    for (directories) |directory| std.heap.c_allocator.free(directory.path);
    std.heap.c_allocator.free(directories);
}

fn buildCachedPaths(paths_in: []const []const u8) ?BuiltPaths {
    if (paths_in.len > CACHE_MAX_PATHS) return null;
    var blob_len: usize = 0;
    for (paths_in) |path| {
        blob_len = std.math.add(usize, blob_len, path.len) catch return null;
        if (blob_len > CACHE_MAX_PATH_BYTES) return null;
    }
    if (blob_len > std.math.maxInt(u32)) return null;

    const blob = std.heap.c_allocator.alloc(u8, blob_len) catch return null;
    var keep_blob = false;
    defer if (!keep_blob) std.heap.c_allocator.free(blob);
    const paths = std.heap.c_allocator.alloc(CachedPath, paths_in.len) catch return null;

    var offset: usize = 0;
    for (paths_in, 0..) |path, index| {
        @memcpy(blob[offset..][0..path.len], path);
        paths[index] = .{ .offset = @intCast(offset), .len = @intCast(path.len) };
        offset += path.len;
    }
    keep_blob = true;
    return .{ .blob = blob, .paths = paths };
}

fn buildCachedDirectories(
    workspace_root: []const u8,
    directories_in: []const CapturedDirectory,
) ?[]CachedDirectory {
    if (directories_in.len > CACHE_MAX_DIRECTORIES) return null;
    var directory_bytes: usize = 0;
    for (directories_in) |directory| {
        directory_bytes = std.math.add(usize, directory_bytes, directory.path.len) catch return null;
        if (directory_bytes > CACHE_MAX_DIRECTORY_BYTES) return null;
    }

    const directories = std.heap.c_allocator.alloc(CachedDirectory, directories_in.len) catch return null;
    var initialized: usize = 0;
    var keep = false;
    defer if (!keep) {
        for (directories[0..initialized]) |directory| std.heap.c_allocator.free(directory.path);
        std.heap.c_allocator.free(directories);
    };

    var root_buf: [512]u8 = undefined;
    if (workspace_root.len >= root_buf.len) return null;
    @memcpy(root_buf[0..workspace_root.len], workspace_root);
    root_buf[workspace_root.len] = 0;
    const root_fd = open(&root_buf, O_RDONLY);
    if (root_fd < 0) return null;
    defer _ = close(root_fd);
    if (!cacheFilesystemSupported(root_fd)) return null;

    for (directories_in, 0..) |captured, index| {
        const path_copy = std.heap.c_allocator.dupeZ(u8, captured.path) catch return null;
        directories[index].path = path_copy;
        initialized += 1;
        const rc = if (captured.path.len == 0)
            c.fstat(root_fd, &directories[index].expected)
        else
            c.fstatat(root_fd, captured.path.ptr, &directories[index].expected, c.AT_SYMLINK_NOFOLLOW);
        if (rc != 0 or !sameDirectoryStamp(captured.before, directories[index].expected)) return null;
    }
    keep = true;
    return directories;
}

fn buildSnapshot(
    workspace_root: []const u8,
    paths_in: []const []const u8,
    directories_in: []const CapturedDirectory,
) ?BuiltSnapshot {
    const built_paths = buildCachedPaths(paths_in) orelse return null;
    const directories = buildCachedDirectories(workspace_root, directories_in) orelse {
        std.heap.c_allocator.free(built_paths.blob);
        std.heap.c_allocator.free(built_paths.paths);
        return null;
    };
    return .{ .blob = built_paths.blob, .paths = built_paths.paths, .directories = directories };
}

pub fn clearSnapshotCache() void {
    const cache = getSnapshotCache();
    cache.mu.lock();
    defer cache.mu.unlock();
    cache.clearLocked();
}

pub const CacheObservation = struct {
    hit: bool,
    validation_ns: u64,
};

pub fn lastCacheObservation() CacheObservation {
    return .{
        .hit = last_cache_hit.load(.acquire),
        .validation_ns = last_cache_validation_ns.load(.acquire),
    };
}

pub const WalkObservation = struct {
    directories: u64,
    getdirentries_calls: u64,
    dirent_bytes: u64,
    entries_seen: u64,
};

pub fn lastWalkObservation() WalkObservation {
    return .{
        .directories = last_walk_directories.load(.acquire),
        .getdirentries_calls = last_walk_syscalls.load(.acquire),
        .dirent_bytes = last_walk_dirent_bytes.load(.acquire),
        .entries_seen = last_walk_entries.load(.acquire),
    };
}

pub const SnapshotStats = struct {
    valid: bool = false,
    paths: usize = 0,
    directories: usize = 0,
    path_bytes: usize = 0,
    retained_bytes: usize = 0,
    incomplete: bool = false,
};

pub fn snapshotStats() SnapshotStats {
    const cache = getSnapshotCache();
    cache.mu.lock();
    defer cache.mu.unlock();
    if (!cache.valid) return .{};
    const paths = cache.paths orelse return .{};
    const directories = cache.directories orelse return .{};
    const blob = cache.blob orelse return .{};
    var directory_path_bytes: usize = 0;
    for (directories) |directory| directory_path_bytes += directory.path.len + 1;
    return .{
        .valid = true,
        .paths = paths.len,
        .directories = directories.len,
        .path_bytes = blob.len,
        .retained_bytes = blob.len +
            paths.len * @sizeOf(CachedPath) +
            directories.len * @sizeOf(CachedDirectory) +
            directory_path_bytes,
        .incomplete = cache.incomplete,
    };
}

pub const StockSnapshot = opaque {};

const StockSnapshotState = struct {
    key: CacheKey,
    directories: []CachedDirectory,
    owns_directories: bool = true,
};

fn stockSnapshotState(snapshot: *StockSnapshot) *StockSnapshotState {
    return @ptrCast(@alignCast(snapshot));
}

pub fn beginStockSnapshot(
    workspace_root: []const u8,
    ignored_names: []const []const u8,
    ignored_paths: ?*const std.StringHashMapUnmanaged(void),
    target_files: bool,
    include_hidden: bool,
    candidate_cap: usize,
    max_relative_path_bytes: usize,
    stop_requested: ?*std.atomic.Value(bool),
) Error!?*StockSnapshot {
    if (ignored_paths != null) return null;
    const no_cache = std.c.getenv("FX_COMPANION_NO_CACHE");
    if (no_cache != null and no_cache.?[0] != 0) return null;
    const key = makeCacheKey(
        workspace_root,
        ignored_names,
        target_files,
        include_hidden,
        candidate_cap,
        max_relative_path_bytes,
    ) orelse return null;

    var captured: std.ArrayListUnmanaged(CapturedDirectory) = .empty;
    defer drainValidationDirectories(&captured);
    var no_paths: std.ArrayList([]const u8) = .empty;
    defer no_paths.deinit(std.heap.c_allocator);
    var ignored_overlong: usize = 0;
    const incomplete = try walkPathsUncached(
        std.heap.c_allocator,
        workspace_root,
        ignored_names,
        ignored_paths,
        true,
        include_hidden,
        std.math.maxInt(usize),
        max_relative_path_bytes,
        stop_requested,
        &no_paths,
        &ignored_overlong,
        &captured,
        true,
    );
    if (incomplete) return null;
    const directories = buildCachedDirectories(workspace_root, captured.items) orelse return null;
    const state = std.heap.c_allocator.create(StockSnapshotState) catch {
        freeCachedDirectories(directories);
        return error.OutOfMemory;
    };
    state.* = .{ .key = key, .directories = directories };
    return @ptrCast(state);
}

pub fn discardStockSnapshot(snapshot: *StockSnapshot) void {
    const state = stockSnapshotState(snapshot);
    if (state.owns_directories) freeCachedDirectories(state.directories);
    std.heap.c_allocator.destroy(state);
}

pub fn finishStockSnapshot(
    snapshot: *StockSnapshot,
    workspace_root: []const u8,
    stock_paths: []const []const u8,
    skipped_overlong: usize,
) void {
    const state = stockSnapshotState(snapshot);
    if (!validateDirectorySnapshot(state.directories, workspace_root)) return;
    if (stock_paths.len > 1) {
        for (stock_paths[1..], stock_paths[0 .. stock_paths.len - 1]) |current, previous| {
            if (std.mem.lessThan(u8, current, previous)) return;
        }
    }
    const built_paths = buildCachedPaths(stock_paths) orelse return;

    const cache = getSnapshotCache();
    cache.mu.lock();
    defer cache.mu.unlock();
    cache.clearLocked();
    @memcpy(cache.key[0..state.key.len], state.key.bytes[0..state.key.len]);
    cache.key_len = state.key.len;
    cache.blob = built_paths.blob;
    cache.paths = built_paths.paths;
    cache.directories = state.directories;
    cache.incomplete = true;
    cache.overlong = skipped_overlong;
    cache.valid = true;
    state.owns_directories = false;
}

fn isHiddenName(name: []const u8) bool {
    return name.len > 1 and name[0] == '.';
}

/// True when the accelerated walk will actually engage on this machine.
/// Drives the BOOSTED badge in the UI header.
pub fn active() bool {
    if (comptime builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return false;
    const off = std.c.getenv("FX_NO_COMPANION");
    return off == null or off.?[0] == 0;
}

/// Renders "✦ BOOSTED" with a smooth cyan→violet→magenta per-character
/// truecolor gradient. Returns an empty slice when inactive or the buffer
/// is too small, so callers can append it unconditionally. `buf` must be
/// at least 256 bytes.
pub fn boostedBadge(buf: []u8) []const u8 {
    if (!active()) return buf[0..0];
    const label = "\u{2726} BOOSTED";
    // Count codepoints so multi-byte chars stay under one escape.
    var nchars: usize = 0;
    var pos: usize = 0;
    while (pos < label.len) {
        pos += std.unicode.utf8ByteSequenceLength(label[pos]) catch 1;
        nchars += 1;
    }
    var w: usize = 0;
    var idx: usize = 0;
    var ci: usize = 0;
    while (idx < label.len) : (ci += 1) {
        const cl = std.unicode.utf8ByteSequenceLength(label[idx]) catch 1;
        const ch = label[idx .. idx + cl];
        const t = @as(f64, @floatFromInt(ci)) / @as(f64, @floatFromInt(nchars - 1));
        // three-stop gradient: teal -> violet -> magenta
        const r: usize = @intFromFloat(if (t < 0.5) 64 + t * 2 * 116 else 180 + (t - 0.5) * 2 * 75);
        const g: usize = @intFromFloat(if (t < 0.5) 224 - t * 2 * 104 else 120 - (t - 0.5) * 2 * 40);
        const b: usize = @intFromFloat(200 + t * 55);
        const written = std.fmt.bufPrint(buf[w..], "\x1b[38;2;{d};{d};{d}m", .{ r, g, b }) catch return buf[0..0];
        w += written.len;
        if (w + cl >= buf.len) return buf[0..0];
        @memcpy(buf[w .. w + cl], ch);
        w += cl;
        idx += cl;
    }
    const tail = std.fmt.bufPrint(buf[w..], "\x1b[0m", .{}) catch return buf[0..0];
    w += tail.len;
    // Leading space keeps the badge visually separated from the version label.
    if (w + 1 < buf.len) {
        std.mem.copyBackwards(u8, buf[1 .. w + 1], buf[0..w]);
        buf[0] = ' ';
        w += 1;
    }
    return buf[0..w];
}

// ---------------------------------------------------------------- benchmark

extern "c" fn opendir(path: [*]const u8) ?*anyopaque;
extern "c" fn readdir(dirp: *anyopaque) ?[*]u8;
extern "c" fn closedir(dirp: *anyopaque) c_int;
extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };
fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Adaptive duration formatting: ns below 1 µs, µs below 1 ms, then ms.
fn fmtDur(ns: u64, buf: []u8) []const u8 {
    const f: f64 = @floatFromInt(ns);
    if (ns < 1_000) return std.fmt.bufPrint(buf, "{d:.0} ns", .{f}) catch "?";
    if (ns < 1_000_000) return std.fmt.bufPrint(buf, "{d:.1} \u{00b5}s", .{f / 1e3}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.2} ms", .{f / 1e6}) catch "?";
}

/// Median via insertion sort on a small copy.
fn medianOf(times: []const u64) u64 {
    var tmp: [16]u64 = undefined;
    const n = @min(times.len, tmp.len);
    @memcpy(tmp[0..n], times[0..n]);
    std.mem.sort(u64, tmp[0..n], {}, struct {
        fn lt(_: void, x: u64, y: u64) bool {
            return x < y;
        }
    }.lt);
    return tmp[n / 2];
}

fn minOf(times: []const u64) u64 {
    var m: u64 = std.math.maxInt(u64);
    for (times) |t| m = @min(m, t);
    return m;
}

/// Single-threaded libc readdir DFS used as an independent count-only
/// comparison. It does not allocate or sort paths and is not labeled stock.
fn referenceWalk(
    arena: std.mem.Allocator,
    root: []const u8,
    out_count: *usize,
) !void {
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(arena, try arena.dupeZ(u8, ""));
    defer {
        for (stack.items) |item| arena.free(item);
        stack.deinit(arena);
    }
    var pathbuf: [4096]u8 = undefined;
    while (stack.pop()) |prefix| {
        const plen = if (prefix.len == 0)
            (std.fmt.bufPrintZ(&pathbuf, "{s}", .{root}) catch continue).len
        else
            (std.fmt.bufPrintZ(&pathbuf, "{s}/{s}", .{ root, prefix }) catch continue).len;
        const dp = opendir(pathbuf[0..plen].ptr) orelse continue;
        while (true) {
            const dent = readdir(dp) orelse break;
            const reclen = std.mem.readInt(u16, dent[16..18], .little);
            if (reclen == 0) break;
            const namlen: usize = std.mem.readInt(u16, dent[18..20], .little);
            const dtype = dent[20];
            const name = dent[21 .. 21 + namlen];
            if (name.len == 1 and name[0] == '.') continue;
            if (name.len == 2 and name[0] == '.' and name[1] == '.') continue;
            if (dtype == DT_REG or dtype == DT_LNK) {
                // Count the same regular-file and symlink kinds fx emits.
                out_count.* += 1;
                continue;
            }
            if (dtype != DT_DIR) continue;
            if (isHiddenName(name)) continue;
            if (isIgnoredName(&.{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" }, name)) continue;
            const child = if (prefix.len == 0)
                try arena.dupeZ(u8, name)
            else
                try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ prefix, name }, 0);
            try stack.append(arena, child);
        }
        _ = closedir(dp);
        arena.free(prefix);
    }
}

const BenchmarkPair = struct {
    cold_ns: u64,
    warm_ns: u64,
    validation_ns: u64,
    files: usize,
    walk: WalkObservation,
};

fn benchmarkPair(workspace_root: []const u8) !BenchmarkPair {
    clearSnapshotCache();
    var cold_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer cold_arena.deinit();
    var warm_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer warm_arena.deinit();
    var cold_paths: std.ArrayList([]const u8) = .empty;
    var warm_paths: std.ArrayList([]const u8) = .empty;
    var cold_overlong: usize = 0;
    var warm_overlong: usize = 0;
    var cold_exact = false;
    var warm_exact = false;

    const cold_started = nowNs();
    const cold_incomplete = try walkPaths(
        cold_arena.allocator(),
        workspace_root,
        &.{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" },
        null,
        true,
        false,
        std.math.maxInt(usize),
        4096,
        null,
        &cold_paths,
        &cold_overlong,
        &cold_exact,
        true,
    );
    const cold_ns = nowNs() - cold_started;
    const walk = lastWalkObservation();

    const warm_started = nowNs();
    const warm_incomplete = try walkPaths(
        warm_arena.allocator(),
        workspace_root,
        &.{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" },
        null,
        true,
        false,
        std.math.maxInt(usize),
        4096,
        null,
        &warm_paths,
        &warm_overlong,
        &warm_exact,
        true,
    );
    const warm_ns = nowNs() - warm_started;
    const cache_observation = lastCacheObservation();
    if (!cold_exact or !warm_exact or cold_incomplete != warm_incomplete or
        cold_overlong != warm_overlong or cold_paths.items.len != warm_paths.items.len)
    {
        return error.BenchmarkMismatch;
    }
    if (!cache_observation.hit) return error.CacheUnavailable;
    for (cold_paths.items, warm_paths.items) |cold_path, warm_path| {
        if (!std.mem.eql(u8, cold_path, warm_path)) return error.BenchmarkMismatch;
    }
    return .{
        .cold_ns = cold_ns,
        .warm_ns = warm_ns,
        .validation_ns = cache_observation.validation_ns,
        .files = cold_paths.items.len,
        .walk = walk,
    };
}

/// Profiles cold traversal, warm snapshot validation/materialization, and a
/// count-only single-thread readdir comparison. One pair warms the filesystem;
/// seven fresh-arena timed rounds follow, with alternating measurement order.
pub fn runBenchmark(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, out);
    const w = &aw.writer;
    _ = benchmarkPair(workspace_root) catch |err| {
        try w.print("profile unavailable: {s}\n", .{@errorName(err)});
        out.* = aw.toArrayList();
        return;
    };

    const rounds: usize = 7;
    var cold_times: [rounds]u64 = undefined;
    var warm_times: [rounds]u64 = undefined;
    var validation_times: [rounds]u64 = undefined;
    var materialize_times: [rounds]u64 = undefined;
    var ref_times: [rounds]u64 = undefined;
    var file_count: usize = 0;
    var ref_count: usize = 0;
    var walk: WalkObservation = undefined;
    for (0..rounds) |i| {
        if (i % 2 == 0) {
            var ref_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            ref_count = 0;
            const ref_started = nowNs();
            referenceWalk(ref_arena.allocator(), workspace_root, &ref_count) catch {
                ref_arena.deinit();
                return;
            };
            ref_times[i] = nowNs() - ref_started;
            ref_arena.deinit();
        }
        const pair = benchmarkPair(workspace_root) catch |err| {
            try w.print("profile failed: {s}\n", .{@errorName(err)});
            out.* = aw.toArrayList();
            return;
        };
        cold_times[i] = pair.cold_ns;
        warm_times[i] = pair.warm_ns;
        validation_times[i] = pair.validation_ns;
        materialize_times[i] = pair.warm_ns -| pair.validation_ns;
        file_count = pair.files;
        walk = pair.walk;
        if (i % 2 != 0) {
            var ref_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            ref_count = 0;
            const ref_started = nowNs();
            referenceWalk(ref_arena.allocator(), workspace_root, &ref_count) catch {
                ref_arena.deinit();
                return;
            };
            ref_times[i] = nowNs() - ref_started;
            ref_arena.deinit();
        }
    }

    const cold_med = medianOf(&cold_times);
    const warm_med = medianOf(&warm_times);
    const repeat_speedup = @as(f64, @floatFromInt(cold_med)) /
        @as(f64, @floatFromInt(warm_med));
    const stats = snapshotStats();

    try w.writeAll("fx-companion profile\n\n");
    try w.print("  tree          {s}\n", .{workspace_root});
    try w.writeAll("  method        1 warmup + 7 rounds, fresh arenas, alternating order\n");
    try w.print("  correctness   cold={d} warm={d} readdir={d}{s}\n", .{
        file_count,
        file_count,
        ref_count,
        if (file_count == ref_count) "  byte/count match" else "  MISMATCH",
    });
    var b: [10][48]u8 = undefined;
    try w.print("  serial count  {s} median · {s} best  (libc readdir, count only)\n", .{
        fmtDur(medianOf(&ref_times), &b[0]),
        fmtDur(minOf(&ref_times), &b[1]),
    });
    try w.print("  cold snapshot {s} median · {s} best\n", .{
        fmtDur(cold_med, &b[2]),
        fmtDur(minOf(&cold_times), &b[3]),
    });
    try w.print("  warm snapshot {s} median · {s} best\n", .{
        fmtDur(warm_med, &b[4]),
        fmtDur(minOf(&warm_times), &b[5]),
    });
    try w.print("    validate    {s} median  ({d} fstat/fstatat)\n", .{
        fmtDur(medianOf(&validation_times), &b[6]),
        stats.directories,
    });
    try w.print("    materialize {s} median  ({d} path bytes)\n", .{
        fmtDur(medianOf(&materialize_times), &b[7]),
        stats.path_bytes,
    });
    try w.print("  cold syscalls getdirentries={d} dirent_bytes={d} dirs={d} entries={d}\n", .{
        walk.getdirentries_calls,
        walk.dirent_bytes,
        walk.directories,
        walk.entries_seen,
    });
    try w.print("  cache memory  {d:.2} MiB retained\n", .{
        @as(f64, @floatFromInt(stats.retained_bytes)) / (1024.0 * 1024.0),
    });
    try w.print("  repeat speed  {d:.2}x{s}\n", .{
        repeat_speedup,
        if (repeat_speedup < 1.0) "  (tree too small to benefit)" else "",
    });
    try w.writeAll("\n  Network/model timing is not synthesized: no paid request is made.\n");
    try w.writeAll("  FX_COMPANION_NO_CACHE=1 disables snapshots; FX_NO_COMPANION=1 disables all acceleration.\n");
    out.* = aw.toArrayList();
}

fn isIgnoredName(ignored: []const []const u8, name: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

const State = struct {
    arena: std.mem.Allocator,
    ignored_names: []const []const u8,
    ignored_paths: ?*const std.StringHashMapUnmanaged(void),
    target_files: bool,
    capture_only: bool,
    include_hidden: bool,
    candidate_cap: usize,
    max_rel: usize,
    stop_requested: ?*std.atomic.Value(bool),

    root_fd: c_int,
    paths: *std.ArrayList([]const u8),
    validation_dirs: ?*std.ArrayListUnmanaged(CapturedDirectory),

    mu: PMutex = .{},
    cond: PCond = .{},
    pending: std.ArrayListUnmanaged([:0]u8) = .empty,
    idle: usize = 0,
    done: bool = false,
    count: usize = 0,
    validation_dir_bytes: usize = 0,
    incomplete: bool = false,
    overlong: std.atomic.Value(usize) = .init(0),
    directories_scanned: std.atomic.Value(u64) = .init(0),
    getdirentries_calls: std.atomic.Value(u64) = .init(0),
    dirent_bytes: std.atomic.Value(u64) = .init(0),
    entries_seen: std.atomic.Value(u64) = .init(0),
    stop_now: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn initSync(self: *State) void {
        self.mu.init();
        self.cond.init();
    }
    fn deinitSync(self: *State) void {
        self.mu.deinit();
        self.cond.deinit();
    }

    /// Appends one relative path under the lock, enforcing the candidate
    /// cap exactly like stock (set incomplete, signal stop). Caller built
    /// `rel` in `scratch` (arena-owned copy is made here on success).
    fn appendRel(self: *State, scratch: []const u8) Error!void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count >= self.candidate_cap) {
            self.incomplete = true;
            self.stop_now.store(true, .release);
            self.cond.broadcast();
            return;
        }
        const rel = self.arena.dupe(u8, scratch) catch return error.OutOfMemory;
        self.paths.append(self.arena, rel) catch {
            self.arena.free(rel);
            return error.OutOfMemory;
        };
        self.count += 1;
    }

    fn pushDir(self: *State, child: [:0]u8) void {
        self.mu.lock();
        self.pending.append(std.heap.c_allocator, child) catch {
            std.heap.c_allocator.free(child);
            self.failed.store(true, .release);
            self.stop_now.store(true, .release);
            self.cond.broadcast();
            self.mu.unlock();
            return;
        };
        self.mu.unlock();
        self.cond.signal();
    }

    /// Publishes a terminal worker failure while holding the same mutex used
    /// by condition waiters. Without that lock, a broadcast can land between
    /// a waiter's predicate check and pthread_cond_wait and be lost forever.
    fn failAndWake(self: *State) void {
        self.mu.lock();
        self.failed.store(true, .release);
        self.stop_now.store(true, .release);
        self.cond.broadcast();
        self.mu.unlock();
    }

    fn stopAndWake(self: *State) void {
        self.mu.lock();
        self.stop_now.store(true, .release);
        self.cond.broadcast();
        self.mu.unlock();
    }

    fn recordDirectory(self: *State, prefix: []const u8, dfd: c_int) Error!void {
        const directories = self.validation_dirs orelse return;
        var before: c.struct_stat = undefined;
        if (c.fstat(dfd, &before) != 0) return error.CompanionUnavailable;
        const owned = std.heap.c_allocator.dupeZ(u8, prefix) catch return error.OutOfMemory;
        self.mu.lock();
        defer self.mu.unlock();
        if (directories.items.len >= CACHE_MAX_DIRECTORIES or
            prefix.len + 1 > CACHE_MAX_DIRECTORY_BYTES - self.validation_dir_bytes)
        {
            std.heap.c_allocator.free(owned);
            return error.CompanionUnavailable;
        }
        directories.append(std.heap.c_allocator, .{ .path = owned, .before = before }) catch {
            std.heap.c_allocator.free(owned);
            return error.OutOfMemory;
        };
        self.validation_dir_bytes += prefix.len + 1;
    }
};

/// Parallel walk. Appends root-relative paths to `out_paths` exactly as
/// stock fx would. Returns true when the candidate cap truncated the walk
/// (stock's `incomplete`). `sorted_output` is the public accelerated contract;
/// source-order callers stay on fx's stock walker through the injection hook.
pub fn walkPaths(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    ignored_names: []const []const u8,
    ignored_paths: ?*const std.StringHashMapUnmanaged(void),
    target_files: bool,
    include_hidden: bool,
    candidate_cap: usize,
    max_relative_path_bytes: usize,
    stop_requested: ?*std.atomic.Value(bool),
    out_paths: *std.ArrayList([]const u8),
    out_overlong: *usize,
    out_exact: *bool,
    sorted_output: bool,
) Error!bool {
    out_exact.* = false;
    last_cache_hit.store(false, .release);
    last_cache_validation_ns.store(0, .release);
    if (comptime builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        return error.CompanionUnavailable;
    }
    const no_companion = std.c.getenv("FX_NO_COMPANION");
    if (no_companion != null and no_companion.?[0] != 0) return error.CompanionUnavailable;
    if (workspace_root.len == 0 or workspace_root.len >= 512) return error.CompanionUnavailable;
    if (candidate_cap == 0) return true;

    const no_cache = std.c.getenv("FX_COMPANION_NO_CACHE");
    const cache_allowed = sorted_output and
        ignored_paths == null and
        out_paths.items.len == 0 and
        (no_cache == null or no_cache.?[0] == 0);
    const maybe_key = if (cache_allowed)
        makeCacheKey(
            workspace_root,
            ignored_names,
            target_files,
            include_hidden,
            candidate_cap,
            max_relative_path_bytes,
        )
    else
        null;

    if (maybe_key) |key_value| {
        var key = key_value;
        const cache = getSnapshotCache();
        cache.mu.lock();
        defer cache.mu.unlock();

        if (stop_requested) |stop| {
            if (stop.load(.seq_cst)) return error.Canceled;
        }
        if (cacheKeyMatches(cache, &key)) {
            const validation_started = nowNs();
            const unchanged = validateSnapshot(cache, workspace_root);
            last_cache_validation_ns.store(nowNs() - validation_started, .release);
            if (unchanged) {
                try materializeSnapshot(cache, arena, out_paths, out_overlong);
                if (stop_requested) |stop| {
                    if (stop.load(.seq_cst)) return error.Canceled;
                }
                last_cache_hit.store(true, .release);
                out_exact.* = true;
                return cache.incomplete;
            }
            cache.clearLocked();
        }

        var validation_dirs: std.ArrayListUnmanaged(CapturedDirectory) = .empty;
        defer drainValidationDirectories(&validation_dirs);
        const incomplete = try walkPathsUncached(
            arena,
            workspace_root,
            ignored_names,
            ignored_paths,
            target_files,
            include_hidden,
            candidate_cap,
            max_relative_path_bytes,
            stop_requested,
            out_paths,
            out_overlong,
            &validation_dirs,
            false,
        );
        sortPaths(out_paths.items);
        if (incomplete) return true;

        if (buildSnapshot(workspace_root, out_paths.items, validation_dirs.items)) |built| {
            cache.clearLocked();
            @memcpy(cache.key[0..key.len], key.bytes[0..key.len]);
            cache.key_len = key.len;
            cache.blob = built.blob;
            cache.paths = built.paths;
            cache.directories = built.directories;
            cache.incomplete = false;
            cache.overlong = out_overlong.*;
            cache.valid = true;
        }
        out_exact.* = true;
        return false;
    }

    const incomplete = try walkPathsUncached(
        arena,
        workspace_root,
        ignored_names,
        ignored_paths,
        target_files,
        include_hidden,
        candidate_cap,
        max_relative_path_bytes,
        stop_requested,
        out_paths,
        out_overlong,
        null,
        false,
    );
    if (sorted_output) sortPaths(out_paths.items);
    out_exact.* = sorted_output and !incomplete;
    return incomplete;
}

fn sortPaths(paths: [][]const u8) void {
    std.mem.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

fn drainValidationDirectories(directories: *std.ArrayListUnmanaged(CapturedDirectory)) void {
    for (directories.items) |directory| std.heap.c_allocator.free(directory.path);
    directories.deinit(std.heap.c_allocator);
}

fn walkPathsUncached(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    ignored_names: []const []const u8,
    ignored_paths: ?*const std.StringHashMapUnmanaged(void),
    target_files: bool,
    include_hidden: bool,
    candidate_cap: usize,
    max_relative_path_bytes: usize,
    stop_requested: ?*std.atomic.Value(bool),
    out_paths: *std.ArrayList([]const u8),
    out_overlong: *usize,
    validation_dirs: ?*std.ArrayListUnmanaged(CapturedDirectory),
    capture_only: bool,
) Error!bool {
    if (comptime builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        return error.CompanionUnavailable;
    }
    // Zig 0.16 moved std.posix.getenv behind an Io context; libc getenv is
    // the stable route and fx links libc everywhere.
    const no_companion = std.c.getenv("FX_NO_COMPANION");
    if (no_companion != null and no_companion.?[0] != 0) return error.CompanionUnavailable;
    if (workspace_root.len == 0 or workspace_root.len >= 512) return error.CompanionUnavailable;
    if (candidate_cap == 0) return true;

    const root_z = std.heap.c_allocator.dupeZ(u8, workspace_root) catch return error.CompanionUnavailable;
    defer std.heap.c_allocator.free(root_z);

    const root_fd = open(root_z.ptr, O_RDONLY);
    if (root_fd < 0) return error.CompanionUnavailable;
    defer _ = close(root_fd);

    var st = State{
        .arena = arena,
        .ignored_names = ignored_names,
        .ignored_paths = ignored_paths,
        .target_files = target_files,
        .capture_only = capture_only,
        .include_hidden = include_hidden,
        .candidate_cap = candidate_cap,
        .max_rel = max_relative_path_bytes,
        .stop_requested = stop_requested,
        .root_fd = root_fd,
        .paths = out_paths,
        .validation_dirs = validation_dirs,
    };
    st.initSync();
    defer st.deinitSync();
    defer drainQueue(&st);

    // Seed scan on this thread; queued subtrees go to the pool.
    const seed_buffer = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch return error.CompanionUnavailable;
    defer std.heap.c_allocator.free(seed_buffer);
    scan(&st, root_fd, "", seed_buffer);

    st.mu.lock();
    st.done = st.pending.items.len == 0;
    st.mu.unlock();

    var threads: [WORKERS - 1]std.Thread = undefined;
    var started: usize = 0;
    defer {
        st.mu.lock();
        st.done = true;
        st.cond.broadcast();
        st.mu.unlock();
        for (threads[0..started]) |t| t.join();
    }
    var all_spawned = true;
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, workerMain, .{&st}) catch {
            all_spawned = false;
            break;
        };
        started += 1;
    }
    if (all_spawned) {
        // The main thread is the WORKERS-th pool participant.
        workerMain(&st);
    } else {
        // A spawn failed: shut the partial pool down cleanly, then drain
        // the remaining queue on this thread. Entering pool mode with
        // fewer than WORKERS participants would deadlock the idle count.
        st.mu.lock();
        st.done = true;
        st.cond.broadcast();
        st.mu.unlock();
        for (threads[0..started]) |t| t.join();
        started = 0;
        const wb = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch return error.CompanionUnavailable;
        defer std.heap.c_allocator.free(wb);
        while (true) {
            if (st.stop_now.load(.acquire)) break;
            st.mu.lock();
            const prefix = if (st.pending.items.len > 0) st.pending.pop() else null;
            st.mu.unlock();
            const p = prefix orelse break;
            scan(&st, -1, p, wb);
            std.heap.c_allocator.free(p);
        }
    }
    for (threads[0..started]) |t| t.join();
    started = 0;

    if (stop_requested) |stop| {
        if (stop.load(.seq_cst)) return error.Canceled;
    }
    if (st.failed.load(.acquire)) return error.CompanionUnavailable;
    last_walk_directories.store(st.directories_scanned.load(.monotonic), .release);
    last_walk_syscalls.store(st.getdirentries_calls.load(.monotonic), .release);
    last_walk_dirent_bytes.store(st.dirent_bytes.load(.monotonic), .release);
    last_walk_entries.store(st.entries_seen.load(.monotonic), .release);
    out_overlong.* = st.overlong.load(.monotonic);
    st.mu.lock();
    const incomplete = st.incomplete;
    st.mu.unlock();
    return incomplete;
}

fn workerMain(st: *State) void {
    const buffer = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch {
        st.failAndWake();
        return;
    };
    defer std.heap.c_allocator.free(buffer);
    while (takeJob(st)) |prefix| {
        scan(st, -1, prefix, buffer);
        std.heap.c_allocator.free(prefix);
    }
}

/// Pops one queued prefix; blocks while the queue looks empty unless the
/// whole walk finished (all workers idle simultaneously) or stop was hit.
fn takeJob(st: *State) ?[:0]u8 {
    st.mu.lock();
    defer st.mu.unlock();
    while (true) {
        if (st.stop_now.load(.acquire)) return null;
        if (st.pending.items.len > 0) {
            return st.pending.pop().?;
        }
        st.idle += 1;
        if (st.idle == WORKERS) {
            st.done = true;
            st.cond.broadcast();
            return null;
        }
        st.cond.wait(&st.mu);
        st.idle -= 1;
        if (st.done) return null;
    }
}

/// Scans one directory. dfd < 0 means "open prefix through the walk-lifetime
/// root fd first" (worker path); the seed passes its already-open fd.
/// NEVER resolve against parent fds here: parents close when their own scan
/// ends and the kernel may reuse those numbers (silent wrong-dir opens).
fn scan(st: *State, dfd_in: c_int, prefix: []const u8, buffer: []u8) void {
    var syscall_count: u64 = 0;
    var returned_bytes: u64 = 0;
    var entries_seen: u64 = 0;
    defer {
        _ = st.getdirentries_calls.fetchAdd(syscall_count, .monotonic);
        _ = st.dirent_bytes.fetchAdd(returned_bytes, .monotonic);
        _ = st.entries_seen.fetchAdd(entries_seen, .monotonic);
    }
    var owned = false;
    var dfd = dfd_in;
    if (dfd < 0) {
        dfd = openat(st.root_fd, prefix.ptr, O_RDONLY);
        if (dfd < 0) {
            // Stock opens one component at a time and can traverse a relative
            // path longer than Darwin's single-call PATH_MAX. Fall back so
            // its overlong accounting remains exact rather than dropping the
            // subtree silently. Vanished or inaccessible entries are skipped
            // by stock as well.
            if (c.__error().* == c.ENAMETOOLONG) {
                st.failAndWake();
            }
            return;
        }
        owned = true;
    }
    defer {
        if (owned) _ = close(dfd);
    }
    st.recordDirectory(prefix, dfd) catch {
        st.failAndWake();
        return;
    };
    _ = st.directories_scanned.fetchAdd(1, .monotonic);

    // base must be reinitialized to -1 before EVERY call on modern macOS:
    // the kernel returns the next-entry cookie through it and treats an
    // in-range value as a seek position. A stale 0 made every call after
    // the first restart at entry zero -> single-round walks, empty output.
    var base: i64 = -1;
    while (true) {
        if (stopHit(st)) return;
        syscall_count += 1;
        const n = getdirentries(dfd, buffer.ptr, buffer.len, &base);
        if (n <= 0) break;
        returned_bytes += @intCast(n);
        const end: usize = @intCast(n);
        var p: usize = 0;
        while (p + 8 <= end) {
            // Legacy Darwin dirent layout, verified by hexdump on macOS 27
            // arm64: ino u32 @0, reclen u16 @4, type u8 @6, namlen u8 @7,
            // name @8, record padded to 4.
            const reclen = std.mem.readInt(u16, buffer[p + 4 ..][0..2], .little);
            if (reclen < 8 or p + reclen > end) break;
            const dtype = buffer[p + 6];
            const namlen: usize = buffer[p + 7];
            const valid = namlen > 0 and 8 + namlen <= reclen;
            if (valid) {
                entries_seen += 1;
                const name = buffer[p + 8 ..][0..namlen];
                handleEntry(st, prefix, name, dtype) catch {
                    st.failAndWake();
                    return;
                };
            }
            if (reclen == 0) break;
            p += reclen;
        }
    }
}

fn stopHit(st: *State) bool {
    if (st.stop_now.load(.acquire)) return true;
    if (st.stop_requested) |stop| {
        if (stop.load(.seq_cst)) {
            st.stopAndWake();
            return true;
        }
    }
    return false;
}

fn handleEntry(st: *State, prefix: []const u8, name: []const u8, dtype: u8) Error!void {
    const dot = name.len == 1 and name[0] == '.';
    const dotdot = name.len == 2 and name[0] == '.' and name[1] == '.';
    if (dot or dotdot) return;

    if (dtype != DT_DIR) {
        if (st.capture_only) return;
        // Stock emits regular files and symlinks. Other dirent kinds (FIFO,
        // socket, device, whiteout, unknown) take the switch's `else` arm.
        if (dtype != DT_REG and dtype != DT_LNK) return;
        // Exact-name ignore list only. Hidden files ARE included by stock
        // (the hidden filter applies to directories).
        if (!st.target_files) return;
        if (isIgnoredName(st.ignored_names, name)) return;
        try emitPath(st, prefix, name);
        return;
    }

    // Stock directory rules, in stock order:
    // hidden -> ignored-name -> (later, after join) ignored-paths ->
    // cap -> overlong -> emit(directories target) -> recurse.
    if (!st.include_hidden and isHiddenName(name)) return;
    if (isIgnoredName(st.ignored_names, name)) return;

    const child = try joinPrefix(prefix, name);
    defer std.heap.c_allocator.free(child);

    if (st.ignored_paths) |ig| {
        if (ig.contains(child)) return;
    }
    if (!st.target_files) {
        // directories target: stock order is cap check first (sets
        // incomplete), then overlong count, then emit, then recurse.
        st.mu.lock();
        const full = st.count >= st.candidate_cap;
        if (full) {
            st.incomplete = true;
            st.stop_now.store(true, .release);
            st.cond.broadcast();
        }
        st.mu.unlock();
        if (full) return;
        if (child.len > st.max_rel) {
            _ = st.overlong.fetchAdd(1, .monotonic);
            return;
        }
        try st.appendRel(child);
    }
    if (st.stop_now.load(.acquire)) return;
    const owned_child = std.heap.c_allocator.dupeZ(u8, child) catch return error.OutOfMemory;
    st.pushDir(owned_child);
}

/// Builds and appends one file path with stock cap/overlong rules.
fn emitPath(st: *State, prefix: []const u8, name: []const u8) Error!void {
    // Stock order for files: ignore-name (caller), then CAP check first
    // (sets incomplete and stops the walk), then overlong count, then emit.
    const rel_len = if (prefix.len == 0) name.len else prefix.len + 1 + name.len;
    var scratch: [4096]u8 = undefined;
    st.mu.lock();
    const full = st.count >= st.candidate_cap;
    if (full) {
        st.incomplete = true;
        st.stop_now.store(true, .release);
        st.cond.broadcast();
        st.mu.unlock();
        return;
    }
    st.mu.unlock();
    if (rel_len > st.max_rel or rel_len > scratch.len) {
        _ = st.overlong.fetchAdd(1, .monotonic);
        return;
    }
    if (prefix.len == 0) {
        @memcpy(scratch[0..name.len], name);
    } else {
        @memcpy(scratch[0..prefix.len], prefix);
        scratch[prefix.len] = '/';
        @memcpy(scratch[prefix.len + 1 ..][0..name.len], name);
    }
    try st.appendRel(scratch[0..rel_len]);
}

fn joinPrefix(prefix: []const u8, name: []const u8) Error![:0]u8 {
    // Empty prefix (root level): no separator, else we'd build "/name"
    // and openat(root_fd, "/name") would resolve absolutely and miss.
    const sep: usize = if (prefix.len == 0) 0 else 1;
    const joined = prefix.len + sep + name.len;
    const buf = std.heap.c_allocator.allocSentinel(u8, joined, 0) catch return error.OutOfMemory;
    @memcpy(buf[0..prefix.len], prefix);
    if (sep == 1) buf[prefix.len] = '/';
    @memcpy(buf[prefix.len + sep ..][0..name.len], name);
    return buf;
}

fn drainQueue(st: *State) void {
    st.mu.lock();
    defer st.mu.unlock();
    for (st.pending.items) |item| std.heap.c_allocator.free(item);
    st.pending.deinit(std.heap.c_allocator);
}
