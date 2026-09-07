//! fx-companion: accelerated workspace traversal for Apple Silicon.
//!
//! Drop-in replacement for the inner loop of walkWorkspacePaths on
//! macOS/arm64. Same directory-read syscall family as stock (getdirentries,
//! which std.Io.Dir.Iterator drives through readdir), but with measured,
//! workload-aware per-worker buffers and a bounded hardware-aware pool instead of a
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
extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn opendir(path: [*]const u8) ?*anyopaque;
extern "c" fn readdir(dirp: *anyopaque) ?[*]u8;
extern "c" fn closedir(dirp: *anyopaque) c_int;
extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
extern "c" fn sysctlbyname(
    name: [*:0]const u8,
    oldp: ?*anyopaque,
    oldlenp: *usize,
    newp: ?*anyopaque,
    newlen: usize,
) c_int;
// Fixed-arity libc call; safe to hand-declare. The silent-noop variadic
// trap applies only to fcntl-style varargs functions.
extern "c" fn getdirentries(fd: c_int, buf: [*]u8, nbytes: usize, basep: *i64) isize;

const Timespec = extern struct { sec: isize, nsec: isize };

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var performance_core_cache: std.atomic.Value(u32) = .init(0);

/// Returns macOS's performance-core count when the topology sysctl exists.
/// Encoded atomic cache: 0=unqueried, 1=unavailable, N+1=core count N.
/// Failure is performance-only; traversal falls back to a logical-CPU policy.
fn performanceCoreCount() ?usize {
    if (comptime builtin.os.tag != .macos) return null;
    const cached = performance_core_cache.load(.acquire);
    if (cached != 0) return if (cached == 1) null else cached - 1;

    var value: c_int = 0;
    var size: usize = @sizeOf(c_int);
    const rc = sysctlbyname(
        "hw.perflevel0.physicalcpu",
        @ptrCast(&value),
        &size,
        null,
        0,
    );
    const encoded: u32 = if (rc == 0 and size == @sizeOf(c_int) and value > 0)
        @as(u32, @intCast(value)) + 1
    else
        1;
    performance_core_cache.store(encoded, .release);
    return if (encoded == 1) null else encoded - 1;
}

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
const MAX_WORKERS: usize = 16;
const CACHE_KEY_BYTES: usize = 2048;
const MAX_CACHE_VALIDATE_WORKERS: usize = 8;
const CACHE_MAX_PATHS: usize = 1_000_000;
const CACHE_MAX_DIRECTORIES: usize = 100_000;
const CACHE_MAX_PATH_BYTES: usize = 128 * 1024 * 1024;
const CACHE_MAX_DIRECTORY_BYTES: usize = 64 * 1024 * 1024;
/// Default fx cap. A parallel walk cannot preserve stock's first-N source
/// order, so cache misses at or below this cap skip the pool and snapshot
/// stock's result instead of paying for a discarded traversal.
const STOCK_FIRST_CAP: usize = 100_000;
const DISK_CACHE_MAGIC: u32 = 0x31435846;
const DISK_CACHE_VERSION: u32 = 2;
const CACHE_ABI_TAG = "fx-companion-cache-v2";
/// Replaced by inject_hook.py with SHA-256(workspace_files.zig) before any
/// patching. Cache keys therefore stop matching automatically when upstream's
/// workspace semantics change, even if the on-disk schema itself did not.
const UPSTREAM_FINGERPRINT = "FXC_UPSTREAM_FINGERPRINT_UNSET";
const DISK_CACHE_MAX_BYTES: usize = 256 * 1024 * 1024;
const DISK_CACHE_MAX_ENTRIES: usize = 256;
var disk_tmp_counter: std.atomic.Value(u64) = .init(0);

const TraversalPolicy = struct {
    participants: usize,
    buffer_bytes: usize,
    validation_workers: usize,

    const large_buffer: usize = 128 * 1024;
    const xlarge_buffer: usize = 256 * 1024;

    /// 128 KiB was the stable production-path choice for the root scan; once
    /// it reveals breadth, workers can move to the 256 KiB moderate-fanout tier.
    fn seedBufferBytes() usize {
        return large_buffer;
    }

    /// Conservative Apple-Silicon scaling derived from the M2 worker/buffer
    /// sweep. Very wide roots saturate quickly, while moderate fan-out such as
    /// Homebrew still benefits from more overlap. Never exceed the work exposed
    /// by the seed scan. A single queued child stays serial to avoid thread
    /// overhead on deep/narrow trees.
    fn forWalk(
        logical_cpus_raw: usize,
        performance_cores: ?usize,
        pending_after_seed: usize,
    ) TraversalPolicy {
        const logical_cpus = @max(logical_cpus_raw, 1);
        const very_wide = pending_after_seed >= 64;
        const complex_moderate = pending_after_seed >= 8 and !very_wide;
        const fallback_hardware_target = @max(1, (logical_cpus + 1) / 2);
        const hardware_target = @min(
            @min(MAX_WORKERS, 8),
            @max(1, performance_cores orelse fallback_hardware_target),
        );
        const participants = if (pending_after_seed <= 1)
            1
        else
            @max(1, @min(hardware_target, pending_after_seed + 1));
        const buffer_bytes = if (participants == 1)
            large_buffer
        else if (complex_moderate)
            xlarge_buffer
        else
            large_buffer;
        return .{
            .participants = participants,
            .buffer_bytes = buffer_bytes,
            .validation_workers = 1,
        };
    }

    /// Metadata validation is a different workload: on the measured M2,
    /// eight fstat/fstatat lanes won on a 15k-directory Homebrew snapshot.
    /// Keep the existing directory-count guard while expressing it through the
    /// same hardware policy and retaining the sequential fast path for tiny sets.
    fn forValidation(logical_cpus_raw: usize, directory_count: usize) TraversalPolicy {
        const logical_cpus = @max(logical_cpus_raw, 1);
        const lanes = if (directory_count <= 32)
            1
        else
            @max(1, @min(@min(logical_cpus, MAX_CACHE_VALIDATE_WORKERS), (directory_count + 31) / 32));
        return .{
            .participants = 1,
            .buffer_bytes = seedBufferBytes(),
            .validation_workers = lanes,
        };
    }
};

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
        3, // recursive cache semantic version
        @intFromBool(target_files),
        @intFromBool(include_hidden),
    };
    if (!key.append(CACHE_ABI_TAG) or
        !key.append(UPSTREAM_FINGERPRINT) or
        !key.append(&flags) or
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
    lanes: usize,
    changed: std.atomic.Value(bool) = .init(false),
};

fn validateCacheLane(context: *CacheValidationContext, lane: usize) void {
    var index = lane;
    while (index < context.directories.len) : (index += context.lanes) {
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
    if (directories.len <= 32) return validateCacheSequential(root_fd, directories);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const lanes = TraversalPolicy.forValidation(cpu_count, directories.len).validation_workers;
    if (lanes == 1) return validateCacheSequential(root_fd, directories);
    var context = CacheValidationContext{ .root_fd = root_fd, .directories = directories, .lanes = lanes };
    var threads: [MAX_CACHE_VALIDATE_WORKERS - 1]std.Thread = undefined;
    var started: usize = 0;
    var spawn_failed = false;
    for (threads[0 .. lanes - 1], 1..) |*thread, lane| {
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
        if (rc != 0) return null;
        const had_before = captured.before.st_ino != 0 or captured.before.st_dev != 0;
        if (had_before and !sameDirectoryStamp(captured.before, directories[index].expected)) return null;
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

const DirectoryStamp = extern struct {
    dev: u64,
    ino: u64,
    mode: u32,
    _pad: u32 = 0,
    mtime_sec: i64,
    mtime_nsec: i64,
    ctime_sec: i64,
    ctime_nsec: i64,
};

fn stampFromStat(st: c.struct_stat) DirectoryStamp {
    return .{
        .dev = @intCast(st.st_dev),
        .ino = st.st_ino,
        .mode = st.st_mode,
        .mtime_sec = st.st_mtimespec.tv_sec,
        .mtime_nsec = st.st_mtimespec.tv_nsec,
        .ctime_sec = st.st_ctimespec.tv_sec,
        .ctime_nsec = st.st_ctimespec.tv_nsec,
    };
}

fn statFromStamp(stamp: DirectoryStamp) c.struct_stat {
    var st: c.struct_stat = std.mem.zeroes(c.struct_stat);
    st.st_dev = @intCast(stamp.dev);
    st.st_ino = stamp.ino;
    st.st_mode = @intCast(stamp.mode);
    st.st_mtimespec.tv_sec = stamp.mtime_sec;
    st.st_mtimespec.tv_nsec = stamp.mtime_nsec;
    st.st_ctimespec.tv_sec = stamp.ctime_sec;
    st.st_ctimespec.tv_nsec = stamp.ctime_nsec;
    return st;
}

fn companionHomeDir(buf: []u8) ?[:0]u8 {
    if (std.c.getenv("FX_COMPANION_HOME")) |configured| {
        const len = std.mem.len(configured);
        if (len == 0 or len + 1 > buf.len) return null;
        @memcpy(buf[0..len], configured[0..len]);
        buf[len] = 0;
        return buf[0..len :0];
    }
    const home = std.c.getenv("HOME") orelse return null;
    const home_len = std.mem.len(home);
    if (home_len == 0 or home_len + 32 >= buf.len) return null;
    const written = std.fmt.bufPrintZ(buf, "{s}/.fx-companion", .{home[0..home_len]}) catch return null;
    return buf[0..written.len :0];
}

fn snapshotDirZ(buf: []u8) ?[:0]u8 {
    var home_buf: [512]u8 = undefined;
    const home = companionHomeDir(&home_buf) orelse return null;
    if (home.len + 16 >= buf.len) return null;
    const written = std.fmt.bufPrintZ(buf, "{s}/snapshots", .{home}) catch return null;
    return buf[0..written.len :0];
}

fn ensureSnapshotDir() bool {
    var home_buf: [512]u8 = undefined;
    const home = companionHomeDir(&home_buf) orelse return false;
    _ = mkdir(home.ptr, 0o700);
    var snap_buf: [512]u8 = undefined;
    const snap = snapshotDirZ(&snap_buf) orelse return false;
    _ = mkdir(snap.ptr, 0o700);
    return true;
}

fn diskSnapshotPath(key: []const u8, buf: []u8) ?[:0]u8 {
    var snap_buf: [512]u8 = undefined;
    const dir = snapshotDirZ(&snap_buf) orelse return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    const hex = "0123456789abcdef";
    var name: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        name[i * 2] = hex[byte >> 4];
        name[i * 2 + 1] = hex[byte & 0xf];
    }
    if (dir.len + 1 + name.len + 1 >= buf.len) return null;
    const written = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch return null;
    return buf[0..written.len :0];
}

const DiskSnapshotMeta = struct {
    name: [64]u8,
    size: usize,
    mtime_sec: i64,
    live: bool = true,
};

fn isSnapshotName(name: []const u8) bool {
    if (name.len != 64) return false;
    for (name) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    }
    return true;
}

/// Opportunistic bounded-LRU pruning. Snapshot filenames are content-key
/// digests, so unlinking an old entry is always safe: a concurrent reader
/// keeps its fd and a future request simply rebuilds the entry.
fn pruneDiskSnapshots() void {
    var dir_buf: [512]u8 = undefined;
    const dir_path = snapshotDirZ(&dir_buf) orelse return;
    const dp = opendir(dir_path.ptr) orelse return;
    defer _ = closedir(dp);

    var entries: [512]DiskSnapshotMeta = undefined;
    var count: usize = 0;
    var total: usize = 0;
    while (true) {
        const dent = readdir(dp) orelse break;
        const namlen: usize = std.mem.readInt(u16, dent[18..20], .little);
        if (namlen == 0) continue;
        const name = dent[21 .. 21 + namlen];
        if (!isSnapshotName(name)) continue;
        var full: [768]u8 = undefined;
        const path = std.fmt.bufPrintZ(&full, "{s}/{s}", .{ dir_path, name }) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(path.ptr, &st) != 0 or (st.st_mode & 0o170000) != 0o100000) continue;
        const file_size: usize = @intCast(@max(st.st_size, 0));
        if (count == entries.len) {
            _ = unlink(path.ptr);
            continue;
        }
        @memcpy(entries[count].name[0..], name);
        entries[count].size = file_size;
        entries[count].mtime_sec = st.st_mtimespec.tv_sec;
        entries[count].live = true;
        count += 1;
        total = std.math.add(usize, total, file_size) catch std.math.maxInt(usize);
    }

    var live_count = count;
    while (live_count > DISK_CACHE_MAX_ENTRIES or total > DISK_CACHE_MAX_BYTES) {
        var oldest: ?usize = null;
        for (entries[0..count], 0..) |entry, index| {
            if (!entry.live) continue;
            if (oldest == null or entry.mtime_sec < entries[oldest.?].mtime_sec) oldest = index;
        }
        const index = oldest orelse break;
        var full: [768]u8 = undefined;
        const path = std.fmt.bufPrintZ(&full, "{s}/{s}", .{ dir_path, entries[index].name[0..] }) catch break;
        if (unlink(path.ptr) == 0) {
            total -|= entries[index].size;
            live_count -= 1;
        }
        entries[index].live = false;
    }
}

fn deleteDiskSnapshot(key: []const u8) void {
    var path_buf: [768]u8 = undefined;
    const path = diskSnapshotPath(key, &path_buf) orelse return;
    _ = unlink(path.ptr);
}

fn diskSnapshotExists(key: []const u8) bool {
    var path_buf: [768]u8 = undefined;
    const path = diskSnapshotPath(key, &path_buf) orelse return false;
    var st: c.struct_stat = undefined;
    return c.stat(path.ptr, &st) == 0 and (st.st_mode & 0o170000) == 0o100000;
}

/// Coalesced single-buffer persist: same on-disk format as before, but one
/// large write instead of 12 + 3*N small write() syscalls (300k+ calls for
/// 100k directories). Takes plain slices so callers can persist without
/// holding the snapshot-cache lock.
fn persistDiskSnapshotStaged(
    key: []const u8,
    blob: []const u8,
    paths: []const CachedPath,
    directories: []const CachedDirectory,
    incomplete: bool,
    overlong: usize,
) void {
    if (key.len > CACHE_KEY_BYTES) return;
    if (paths.len > CACHE_MAX_PATHS) return;
    if (blob.len > CACHE_MAX_PATH_BYTES) return;
    if (directories.len > CACHE_MAX_DIRECTORIES) return;
    if (blob.len > std.math.maxInt(u32)) return;
    if (!ensureSnapshotDir()) return;
    var path_buf: [768]u8 = undefined;
    const path = diskSnapshotPath(key, &path_buf) orelse return;
    var tmp_buf: [820]u8 = undefined;
    const tmp_seq = disk_tmp_counter.fetchAdd(1, .monotonic);
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp.{d}.{d}", .{ path, c.getpid(), tmp_seq }) catch return;

    // Total: payload plus a trailing SHA-256 digest. The digest makes partial,
    // torn, and maliciously modified cache files fail closed before decoding.
    var total: usize = 4 + 4 + 4 + key.len + 1 + 8 + 4 + 4 + blob.len + paths.len * 8 + 4 + 32;
    for (directories) |directory| {
        total = std.math.add(usize, total, 4 + directory.path.len + @sizeOf(DirectoryStamp)) catch return;
    }
    const buf = std.heap.c_allocator.alloc(u8, total) catch return;
    defer std.heap.c_allocator.free(buf);
    var off: usize = 0;
    const put = struct {
        fn bytes(dst: []u8, o: *usize, src: []const u8) void {
            @memcpy(dst[o.*..][0..src.len], src);
            o.* += src.len;
        }
    }.bytes;
    put(buf, &off, std.mem.asBytes(&DISK_CACHE_MAGIC));
    put(buf, &off, std.mem.asBytes(&DISK_CACHE_VERSION));
    const key_len: u32 = @intCast(key.len);
    put(buf, &off, std.mem.asBytes(&key_len));
    put(buf, &off, key);
    const incomplete_u8: u8 = @intFromBool(incomplete);
    put(buf, &off, std.mem.asBytes(&incomplete_u8));
    const overlong_u64: u64 = @intCast(overlong);
    put(buf, &off, std.mem.asBytes(&overlong_u64));
    const path_count: u32 = @intCast(paths.len);
    put(buf, &off, std.mem.asBytes(&path_count));
    const blob_len: u32 = @intCast(blob.len);
    put(buf, &off, std.mem.asBytes(&blob_len));
    put(buf, &off, blob);
    put(buf, &off, std.mem.sliceAsBytes(paths));
    const dir_count: u32 = @intCast(directories.len);
    put(buf, &off, std.mem.asBytes(&dir_count));
    for (directories) |directory| {
        const path_len: u32 = @intCast(directory.path.len);
        put(buf, &off, std.mem.asBytes(&path_len));
        put(buf, &off, directory.path);
        const stamp = stampFromStat(directory.expected);
        put(buf, &off, std.mem.asBytes(&stamp));
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buf[0..off], &digest, .{});
    put(buf, &off, &digest);
    std.debug.assert(off == total);

    const fd = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o600));
    if (fd < 0) return;
    var ok = false;
    defer {
        _ = close(fd);
        if (!ok) _ = unlink(tmp.ptr);
    }
    var written: usize = 0;
    while (written < buf.len) {
        const n = write(fd, buf.ptr + written, buf.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    if (rename(tmp.ptr, path.ptr) != 0) return;
    ok = true;
    pruneDiskSnapshots();
}

const StagedSnapshot = struct {
    blob: []u8,
    paths: []CachedPath,
    directories: []CachedDirectory,
    incomplete: bool,
    overlong: usize,
};

fn freeStagedSnapshot(staged: *StagedSnapshot) void {
    for (staged.directories) |directory| std.heap.c_allocator.free(directory.path);
    std.heap.c_allocator.free(staged.directories);
    std.heap.c_allocator.free(staged.paths);
    std.heap.c_allocator.free(staged.blob);
    staged.* = undefined;
}

fn installStagedSnapshot(
    cache: *SnapshotCache,
    key: *const CacheKey,
    staged: *const StagedSnapshot,
) void {
    cache.clearLocked();
    @memcpy(cache.key[0..key.len], key.bytes[0..key.len]);
    cache.key_len = key.len;
    cache.blob = staged.blob;
    cache.paths = staged.paths;
    cache.directories = staged.directories;
    cache.incomplete = staged.incomplete;
    cache.overlong = staged.overlong;
    cache.valid = true;
}

/// Single-read staged load: same on-disk format, but one large read instead
/// of N small read() syscalls, decoded from memory with identical cap and
/// bounds checks. Touches no shared cache state, so callers can load and
/// validate without holding the snapshot-cache lock.
fn loadDiskSnapshotStaged(key: *const CacheKey) ?StagedSnapshot {
    var path_buf: [768]u8 = undefined;
    const path = diskSnapshotPath(key.bytes[0..key.len], &path_buf) orelse return null;
    const fd = open(path.ptr, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);

    var fst: c.struct_stat = undefined;
    if (c.fstat(fd, &fst) != 0) return null;
    const file_size: usize = @intCast(@max(fst.st_size, 0));
    // Lower bound: fixed header + key. Upper bound: worst-case caps
    // (~550 MiB) with headroom; rejects corrupt huge sizes before alloc.
    const min_size: usize = 4 + 4 + 4 + key.len + 1 + 8 + 4 + 4 + 32;
    const max_size: usize = 640 * 1024 * 1024;
    if (file_size < min_size or file_size > max_size) return null;
    const file = std.heap.c_allocator.alloc(u8, file_size) catch return null;
    defer std.heap.c_allocator.free(file);
    var got: usize = 0;
    while (got < file.len) {
        const n = read(fd, file.ptr + got, file.len - got);
        if (n <= 0) return null;
        got += @intCast(n);
    }

    if (file.len < 32) return null;
    const payload = file[0 .. file.len - 32];
    var expected_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &expected_digest, .{});
    if (!std.mem.eql(u8, &expected_digest, file[file.len - 32 ..])) return null;

    var off: usize = 0;
    const take = struct {
        fn bytes(src: []const u8, o: *usize, dst: []u8) bool {
            if (dst.len > src.len - o.*) return false;
            @memcpy(dst, src[o.*..][0..dst.len]);
            o.* += dst.len;
            return true;
        }
    }.bytes;
    var magic: u32 = 0;
    var version: u32 = 0;
    var key_len: u32 = 0;
    if (!take(payload, &off, std.mem.asBytes(&magic)) or magic != DISK_CACHE_MAGIC) return null;
    if (!take(payload, &off, std.mem.asBytes(&version)) or version != DISK_CACHE_VERSION) return null;
    if (!take(payload, &off, std.mem.asBytes(&key_len)) or key_len != key.len or key_len > CACHE_KEY_BYTES) return null;
    if (key_len > payload.len - off) return null;
    if (!std.mem.eql(u8, payload[off..][0..key_len], key.bytes[0..key.len])) return null;
    off += key_len;
    var incomplete: u8 = 0;
    var overlong: u64 = 0;
    var path_count: u32 = 0;
    var blob_len: u32 = 0;
    if (!take(payload, &off, std.mem.asBytes(&incomplete))) return null;
    if (!take(payload, &off, std.mem.asBytes(&overlong))) return null;
    if (!take(payload, &off, std.mem.asBytes(&path_count))) return null;
    if (!take(payload, &off, std.mem.asBytes(&blob_len))) return null;
    if (path_count > CACHE_MAX_PATHS or blob_len > CACHE_MAX_PATH_BYTES) return null;
    if (blob_len > payload.len - off) return null;
    const blob = std.heap.c_allocator.alloc(u8, blob_len) catch return null;
    errdefer std.heap.c_allocator.free(blob);
    @memcpy(blob, payload[off..][0..blob_len]);
    off += blob_len;
    const paths_byte_len = @as(usize, path_count) * @sizeOf(CachedPath);
    if (paths_byte_len > payload.len - off) {
        std.heap.c_allocator.free(blob);
        return null;
    }
    const paths = std.heap.c_allocator.alloc(CachedPath, path_count) catch {
        std.heap.c_allocator.free(blob);
        return null;
    };
    errdefer std.heap.c_allocator.free(paths);
    @memcpy(std.mem.sliceAsBytes(paths), payload[off..][0..paths_byte_len]);
    off += paths_byte_len;
    var dir_count: u32 = 0;
    if (!take(payload, &off, std.mem.asBytes(&dir_count)) or dir_count > CACHE_MAX_DIRECTORIES) {
        std.heap.c_allocator.free(blob);
        std.heap.c_allocator.free(paths);
        return null;
    }
    const directories = std.heap.c_allocator.alloc(CachedDirectory, dir_count) catch {
        std.heap.c_allocator.free(blob);
        std.heap.c_allocator.free(paths);
        return null;
    };
    var initialized: usize = 0;
    var failed = false;
    while (initialized < dir_count) {
        var path_len: u32 = 0;
        if (!take(payload, &off, std.mem.asBytes(&path_len)) or path_len > 4096) {
            failed = true;
            break;
        }
        if (path_len > payload.len - off or @sizeOf(DirectoryStamp) > payload.len - off - path_len) {
            failed = true;
            break;
        }
        const dir_path = std.heap.c_allocator.allocSentinel(u8, path_len, 0) catch {
            failed = true;
            break;
        };
        @memcpy(dir_path[0..path_len], payload[off..][0..path_len]);
        off += path_len;
        var stamp: DirectoryStamp = undefined;
        @memcpy(std.mem.asBytes(&stamp), payload[off..][0..@sizeOf(DirectoryStamp)]);
        off += @sizeOf(DirectoryStamp);
        directories[initialized] = .{ .path = dir_path, .expected = statFromStamp(stamp) };
        initialized += 1;
    }
    if (failed) {
        for (directories[0..initialized]) |directory| std.heap.c_allocator.free(directory.path);
        std.heap.c_allocator.free(directories);
        std.heap.c_allocator.free(blob);
        std.heap.c_allocator.free(paths);
        return null;
    }
    if (off != payload.len) {
        for (directories[0..initialized]) |directory| std.heap.c_allocator.free(directory.path);
        std.heap.c_allocator.free(directories);
        std.heap.c_allocator.free(blob);
        std.heap.c_allocator.free(paths);
        return null;
    }

    return .{
        .blob = blob,
        .paths = paths,
        .directories = directories,
        .incomplete = incomplete != 0,
        .overlong = @intCast(overlong),
    };
}

fn wipeDiskSnapshots() void {
    var snap_buf: [512]u8 = undefined;
    const dir_path = snapshotDirZ(&snap_buf) orelse return;
    const dp = opendir(dir_path.ptr) orelse return;
    defer _ = closedir(dp);
    while (true) {
        const dent = readdir(dp) orelse break;
        const namlen: usize = std.mem.readInt(u16, dent[18..20], .little);
        if (namlen == 0) continue;
        const name = dent[21 .. 21 + namlen];
        if (name[0] == '.') continue;
        var full: [768]u8 = undefined;
        const joined = std.fmt.bufPrintZ(&full, "{s}/{s}", .{ dir_path, name }) catch continue;
        _ = unlink(joined.ptr);
    }
}

pub fn clearSnapshotCache() void {
    const cache = getSnapshotCache();
    cache.mu.lock();
    cache.clearLocked();
    cache.mu.unlock();
    const git = getGitCache();
    git.mu.lock();
    git.clearLocked();
    git.mu.unlock();
    wipeDiskSnapshots();
}

var git_cache: SnapshotCache = .{};
var git_cache_init: std.atomic.Value(u8) = .init(0);

fn getGitCache() *SnapshotCache {
    while (true) {
        switch (git_cache_init.load(.acquire)) {
            0 => {
                if (git_cache_init.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                    git_cache.mu.init();
                    git_cache_init.store(2, .release);
                    return &git_cache;
                }
            },
            1 => std.atomic.spinLoopHint(),
            2 => return &git_cache,
            else => unreachable,
        }
    }
}

fn appendStatStamp(key: *CacheKey, st: c.struct_stat) bool {
    const stamp = stampFromStat(st);
    return key.append(std.mem.asBytes(&stamp));
}

fn makeGitRawCacheKey(
    workspace_root: []const u8,
    git_executable: []const u8,
    only_untracked: bool,
    include_untracked: bool,
    stdout_limit: usize,
) ?CacheKey {
    var key = CacheKey{};
    const flags = [_]u8{ 4, @intFromBool(only_untracked), @intFromBool(include_untracked) };
    if (!key.append(CACHE_ABI_TAG) or
        !key.append(UPSTREAM_FINGERPRINT) or
        !key.append(&flags) or
        !key.appendU64(workspace_root.len) or
        !key.append(workspace_root) or
        !key.appendU64(git_executable.len) or
        !key.append(git_executable) or
        !key.appendU64(stdout_limit)) return null;

    var git_dir_buf: [768]u8 = undefined;
    const git_dir = std.fmt.bufPrintZ(&git_dir_buf, "{s}/.git", .{workspace_root}) catch return null;
    var git_st: c.struct_stat = undefined;
    if (c.stat(git_dir.ptr, &git_st) != 0) return null;
    if ((git_st.st_mode & 0o170000) != 0o040000) return null; // not a directory
    if (!appendStatStamp(&key, git_st)) return null;

    var head_buf: [800]u8 = undefined;
    const head = std.fmt.bufPrintZ(&head_buf, "{s}/HEAD", .{git_dir}) catch return null;
    var head_st: c.struct_stat = undefined;
    if (c.stat(head.ptr, &head_st) != 0) return null;
    if (!appendStatStamp(&key, head_st)) return null;

    var index_buf: [800]u8 = undefined;
    const index = std.fmt.bufPrintZ(&index_buf, "{s}/index", .{git_dir}) catch return null;
    var index_st: c.struct_stat = undefined;
    if (c.stat(index.ptr, &index_st) != 0) return null;
    if (!appendStatStamp(&key, index_st)) return null;
    return key;
}

fn cacheKeysEqual(left: *const CacheKey, right: *const CacheKey) bool {
    return left.len == right.len and std.mem.eql(u8, left.bytes[0..left.len], right.bytes[0..right.len]);
}

pub const GitRawSnapshot = opaque {};

const GitRawSnapshotState = struct {
    key: CacheKey,
    workspace_root: []u8,
    git_executable: []u8,
    only_untracked: bool,
    include_untracked: bool,
    stdout_limit: usize,
    hit: bool = false,
};

fn gitRawSnapshotState(snapshot: *GitRawSnapshot) *GitRawSnapshotState {
    return @ptrCast(@alignCast(snapshot));
}

fn refreshGitRawKey(state: *const GitRawSnapshotState) ?CacheKey {
    return makeGitRawCacheKey(
        state.workspace_root,
        state.git_executable,
        state.only_untracked,
        state.include_untracked,
        state.stdout_limit,
    );
}

fn envIsSet(name: [*:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return value[0] != 0;
}

pub fn beginGitRawSnapshot(
    workspace_root: []const u8,
    git_executable: []const u8,
    only_untracked: bool,
    include_untracked: bool,
    stdout_limit: usize,
) Error!?*GitRawSnapshot {
    last_cache_hit.store(false, .release);
    if (comptime builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return null;
    const off = std.c.getenv("FX_NO_COMPANION");
    if (off != null and off.?[0] != 0) return null;
    const no_cache = std.c.getenv("FX_COMPANION_NO_CACHE");
    if (no_cache != null and no_cache.?[0] != 0) return null;
    // --others / --cached --others depend on working-tree directory state,
    // .gitignore, info/exclude, and global excludes. Until that entire identity
    // is captured, only cache the tracked `git ls-files --cached -z` primitive.
    if (only_untracked or include_untracked) return null;
    // Alternate repository/index routing changes git ls-files semantics without
    // necessarily changing .git/index. Fail closed instead of trying to mirror
    // Git's full environment-resolution policy in the cache layer.
    if (envIsSet("GIT_INDEX_FILE") or envIsSet("GIT_DIR") or
        envIsSet("GIT_WORK_TREE") or envIsSet("GIT_COMMON_DIR")) return null;
    const key = makeGitRawCacheKey(workspace_root, git_executable, only_untracked, include_untracked, stdout_limit) orelse return null;
    const state = std.heap.c_allocator.create(GitRawSnapshotState) catch return error.OutOfMemory;
    errdefer std.heap.c_allocator.destroy(state);
    const root_copy = std.heap.c_allocator.dupe(u8, workspace_root) catch return error.OutOfMemory;
    errdefer std.heap.c_allocator.free(root_copy);
    const executable_copy = std.heap.c_allocator.dupe(u8, git_executable) catch return error.OutOfMemory;
    state.* = .{
        .key = key,
        .workspace_root = root_copy,
        .git_executable = executable_copy,
        .only_untracked = only_untracked,
        .include_untracked = include_untracked,
        .stdout_limit = stdout_limit,
    };
    return @ptrCast(state);
}

pub fn discardGitRawSnapshot(snapshot: *GitRawSnapshot) void {
    const state = gitRawSnapshotState(snapshot);
    std.heap.c_allocator.free(state.workspace_root);
    std.heap.c_allocator.free(state.git_executable);
    std.heap.c_allocator.destroy(state);
}

fn rawFromCache(cache: *const SnapshotCache, arena: std.mem.Allocator) ?[]u8 {
    const blob = cache.blob orelse return null;
    const paths = cache.paths orelse return null;
    if (paths.len != 1 or paths[0].offset != 0 or paths[0].len != blob.len) return null;
    return arena.dupe(u8, blob) catch null;
}

/// Returns cached raw stdout from git ls-files. Upstream still owns parsing,
/// candidate caps, sorting, source selection, and the empty-result fallback.
/// Identity is checked both before and after materialization to prevent a
/// concurrent index/HEAD mutation from turning a cache hit into stale output.
pub fn takeGitRaw(
    snapshot: *GitRawSnapshot,
    arena: std.mem.Allocator,
    stop_requested: ?*std.atomic.Value(bool),
) ?[]u8 {
    const state = gitRawSnapshotState(snapshot);
    if (stop_requested) |stop| if (stop.load(.seq_cst)) return null;
    const key = &state.key;
    const cache = getGitCache();
    cache.mu.lock();
    if (cacheKeyMatches(cache, key)) {
        if (rawFromCache(cache, arena)) |raw| {
            cache.mu.unlock();
            if (stop_requested) |stop| if (stop.load(.seq_cst)) return null;
            const after = refreshGitRawKey(state) orelse return null;
            if (!cacheKeysEqual(key, &after)) return null;
            state.hit = true;
            last_cache_hit.store(true, .release);
            return raw;
        }
    }
    cache.mu.unlock();

    const had_disk_snapshot = diskSnapshotExists(key.bytes[0..key.len]);
    if (loadDiskSnapshotStaged(key)) |staged_value| {
        var staged = staged_value;
        var installed = false;
        defer if (!installed) freeStagedSnapshot(&staged);
        if (staged.directories.len != 0 or staged.paths.len != 1 or
            staged.paths[0].offset != 0 or staged.paths[0].len != staged.blob.len)
        {
            deleteDiskSnapshot(key.bytes[0..key.len]);
            return null;
        }

        cache.mu.lock();
        installStagedSnapshot(cache, key, &staged);
        installed = true;
        const raw = rawFromCache(cache, arena);
        if (raw == null) {
            cache.clearLocked();
            cache.mu.unlock();
            deleteDiskSnapshot(key.bytes[0..key.len]);
            return null;
        }
        cache.mu.unlock();
        if (stop_requested) |stop| if (stop.load(.seq_cst)) return null;
        const after = refreshGitRawKey(state) orelse return null;
        if (!cacheKeysEqual(key, &after)) return null;
        state.hit = true;
        last_cache_hit.store(true, .release);
        return raw.?;
    }
    if (had_disk_snapshot) deleteDiskSnapshot(key.bytes[0..key.len]);
    return null;
}

/// Publishes raw git stdout only if repository identity is unchanged from the
/// pre-command token captured by beginGitRawSnapshot().
pub fn finishGitRawSnapshot(
    snapshot: *GitRawSnapshot,
    raw: []const u8,
) void {
    const state = gitRawSnapshotState(snapshot);
    if (state.hit or raw.len > state.stdout_limit or raw.len > CACHE_MAX_PATH_BYTES or raw.len > std.math.maxInt(u32)) return;
    const after = refreshGitRawKey(state) orelse return;
    if (!cacheKeysEqual(&state.key, &after)) return;

    const blob = std.heap.c_allocator.dupe(u8, raw) catch return;
    var keep_blob = false;
    defer if (!keep_blob) std.heap.c_allocator.free(blob);
    const paths = std.heap.c_allocator.alloc(CachedPath, 1) catch return;
    var keep_paths = false;
    defer if (!keep_paths) std.heap.c_allocator.free(paths);
    paths[0] = .{ .offset = 0, .len = @intCast(raw.len) };
    const no_directories: []const CachedDirectory = &.{};
    persistDiskSnapshotStaged(
        state.key.bytes[0..state.key.len],
        blob,
        paths,
        no_directories,
        false,
        0,
    );
    const cache = getGitCache();
    cache.mu.lock();
    defer cache.mu.unlock();
    cache.clearLocked();
    @memcpy(cache.key[0..state.key.len], state.key.bytes[0..state.key.len]);
    cache.key_len = state.key.len;
    cache.blob = blob;
    cache.paths = paths;
    cache.directories = null;
    cache.incomplete = false;
    cache.overlong = 0;
    cache.valid = true;
    keep_blob = true;
    keep_paths = true;
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

fn isHiddenName(name: []const u8) bool {
    return name.len > 1 and name[0] == '.';
}

/// True when the accelerator is supported and enabled on this machine.
pub fn active() bool {
    if (comptime builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return false;
    const off = std.c.getenv("FX_NO_COMPANION");
    return off == null or off.?[0] == 0;
}

// Benchmarking and profiling live under benchmarks/ and are never injected into fx.

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
    participants: usize,
    buffer_bytes: usize,

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

        // Fast path under lock: in-memory snapshot validate + materialize.
        // Pointers are only stable while the mutex is held, so this whole
        // sequence stays inside the critical section. Disk IO and cold
        // walks below run unlocked on staged (locally-owned) data.
        cache.mu.lock();
        if (stop_requested) |stop| {
            if (stop.load(.seq_cst)) {
                cache.mu.unlock();
                return error.Canceled;
            }
        }
        if (cacheKeyMatches(cache, &key)) {
            const validation_started = nowNs();
            const unchanged = validateSnapshot(cache, workspace_root);
            last_cache_validation_ns.store(nowNs() - validation_started, .release);
            if (unchanged) {
                try materializeSnapshot(cache, arena, out_paths, out_overlong);
                if (stop_requested) |stop| {
                    if (stop.load(.seq_cst)) {
                        cache.mu.unlock();
                        return error.Canceled;
                    }
                }
                last_cache_hit.store(true, .release);
                out_exact.* = true;
                const hit_incomplete = cache.incomplete;
                cache.mu.unlock();
                return hit_incomplete;
            }
            cache.clearLocked();
        } else {
            // Another thread may hold an unrelated key; leave it alone here.
            // Stale same-key entries are cleared on install paths below.
        }
        cache.mu.unlock();

        // Disk path: load + validate with no shared mutation, then install
        // under a short lock (pointer swap + materialize only).
        const had_disk_snapshot = diskSnapshotExists(key.bytes[0..key.len]);
        if (loadDiskSnapshotStaged(&key)) |staged_value| {
            var staged = staged_value;
            var installed = false;
            errdefer if (!installed) freeStagedSnapshot(&staged);
            const validation_started = nowNs();
            const unchanged = validateDirectorySnapshot(staged.directories, workspace_root);
            last_cache_validation_ns.store(nowNs() - validation_started, .release);
            if (unchanged) {
                cache.mu.lock();
                // Only evict our own key on failure paths; install wins here
                // (staged was validated after any concurrent install).
                cache.clearLocked();
                @memcpy(cache.key[0..key.len], key.bytes[0..key.len]);
                cache.key_len = key.len;
                cache.blob = staged.blob;
                cache.paths = staged.paths;
                cache.directories = staged.directories;
                cache.incomplete = staged.incomplete;
                cache.overlong = staged.overlong;
                cache.valid = true;
                installed = true;
                materializeSnapshot(cache, arena, out_paths, out_overlong) catch |e| {
                    cache.clearLocked();
                    cache.mu.unlock();
                    return e;
                };
                if (stop_requested) |stop| {
                    if (stop.load(.seq_cst)) {
                        cache.mu.unlock();
                        return error.Canceled;
                    }
                }
                last_cache_hit.store(true, .release);
                out_exact.* = true;
                const hit_incomplete = cache.incomplete;
                cache.mu.unlock();
                return hit_incomplete;
            }
            deleteDiskSnapshot(key.bytes[0..key.len]);
            freeStagedSnapshot(&staged);
            installed = true;
            cache.mu.lock();
            if (cacheKeyMatches(cache, &key)) cache.clearLocked();
            cache.mu.unlock();
        } else if (had_disk_snapshot) {
            deleteDiskSnapshot(key.bytes[0..key.len]);
        }
        if (candidate_cap <= STOCK_FIRST_CAP) {
            return true;
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

        // Build + persist with no lock held; install is a short pointer swap.
        if (buildSnapshot(workspace_root, out_paths.items, validation_dirs.items)) |built| {
            const owned = built;
            var installed = false;
            errdefer if (!installed) {
                std.heap.c_allocator.free(owned.blob);
                std.heap.c_allocator.free(owned.paths);
                freeCachedDirectories(owned.directories);
            };
            persistDiskSnapshotStaged(
                key.bytes[0..key.len],
                owned.blob,
                owned.paths,
                owned.directories,
                false,
                out_overlong.*,
            );
            cache.mu.lock();
            cache.clearLocked();
            @memcpy(cache.key[0..key.len], key.bytes[0..key.len]);
            cache.key_len = key.len;
            cache.blob = owned.blob;
            cache.paths = owned.paths;
            cache.directories = owned.directories;
            cache.incomplete = false;
            cache.overlong = out_overlong.*;
            cache.valid = true;
            cache.mu.unlock();
            // Ownership moved to the cache.
            installed = true;
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
        .participants = 1,
        .buffer_bytes = TraversalPolicy.large_buffer,
        .root_fd = root_fd,
        .paths = out_paths,
        .validation_dirs = validation_dirs,
    };
    st.initSync();
    defer st.deinitSync();
    defer drainQueue(&st);

    // Pre-reserve so the per-path appends under the mutex rarely realloc.
    // 4096 pointers (32 KiB) covers small trees entirely and costs nothing
    // measurable on large ones; growth beyond this stays geometric.
    out_paths.ensureUnusedCapacity(arena, 4096) catch {};

    // Seed scan on this thread; queued subtrees reveal enough workload shape
    // to select the measured worker count and buffer size for the rest.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const seed_buffer = std.heap.c_allocator.alloc(u8, TraversalPolicy.seedBufferBytes()) catch return error.CompanionUnavailable;
    defer std.heap.c_allocator.free(seed_buffer);
    scan(&st, root_fd, "", seed_buffer);

    st.mu.lock();
    st.done = st.pending.items.len == 0;
    const seed_only = st.pending.items.len == 0;
    const pending_after_seed = st.pending.items.len;
    st.mu.unlock();

    const policy = TraversalPolicy.forWalk(cpu_count, performanceCoreCount(), pending_after_seed);
    st.participants = policy.participants;
    st.buffer_bytes = policy.buffer_bytes;
    var threads: [MAX_WORKERS - 1]std.Thread = undefined;
    var started: usize = 0;
    defer {
        st.mu.lock();
        st.done = true;
        st.cond.broadcast();
        st.mu.unlock();
        for (threads[0..started]) |t| t.join();
    }
    if (seed_only) {
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
    var all_spawned = true;
    for (threads[0 .. st.participants - 1]) |*t| {
        t.* = std.Thread.spawn(.{}, workerMain, .{&st}) catch {
            all_spawned = false;
            break;
        };
        started += 1;
    }
    if (all_spawned) {
        // The main thread is the final pool participant.
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
        const wb = std.heap.c_allocator.alloc(u8, policy.buffer_bytes) catch return error.CompanionUnavailable;
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
    const buffer = std.heap.c_allocator.alloc(u8, st.buffer_bytes) catch {
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
        if (st.idle == st.participants) {
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
        // Single critical section for cap-check + dupe + append.
        st.mu.lock();
        if (st.count >= st.candidate_cap) {
            st.incomplete = true;
            st.stop_now.store(true, .release);
            st.cond.broadcast();
            st.mu.unlock();
            return;
        }
        if (child.len > st.max_rel) {
            st.mu.unlock();
            _ = st.overlong.fetchAdd(1, .monotonic);
            return;
        }
        const rel = st.arena.dupe(u8, child) catch {
            st.mu.unlock();
            return error.OutOfMemory;
        };
        st.paths.append(st.arena, rel) catch {
            st.arena.free(rel);
            st.mu.unlock();
            return error.OutOfMemory;
        };
        st.count += 1;
        st.mu.unlock();
    }
    if (st.stop_now.load(.acquire)) return;
    const owned_child = std.heap.c_allocator.dupeZ(u8, child) catch return error.OutOfMemory;
    st.pushDir(owned_child);
}

/// Builds and appends one file path with stock cap/overlong rules.
fn emitPath(st: *State, prefix: []const u8, name: []const u8) Error!void {
    // Stock order for files: ignore-name (caller), then CAP check first
    // (sets incomplete and stops the walk), then overlong count, then emit.
    // Single critical section: build the rel in scratch first (no shared
    // state), then cap-check + dupe + append under one lock acquisition.
    const rel_len = if (prefix.len == 0) name.len else prefix.len + 1 + name.len;
    var scratch: [4096]u8 = undefined;
    if (rel_len <= scratch.len) {
        if (prefix.len == 0) {
            @memcpy(scratch[0..name.len], name);
        } else {
            @memcpy(scratch[0..prefix.len], prefix);
            scratch[prefix.len] = '/';
            @memcpy(scratch[prefix.len + 1 ..][0..name.len], name);
        }
    }
    st.mu.lock();
    if (st.count >= st.candidate_cap) {
        st.incomplete = true;
        st.stop_now.store(true, .release);
        st.cond.broadcast();
        st.mu.unlock();
        return;
    }
    if (rel_len > st.max_rel or rel_len > scratch.len) {
        // Cap was checked first (stock order); count overlong without
        // holding the mutex across the atomic.
        st.mu.unlock();
        _ = st.overlong.fetchAdd(1, .monotonic);
        return;
    }
    const rel = st.arena.dupe(u8, scratch[0..rel_len]) catch {
        st.mu.unlock();
        return error.OutOfMemory;
    };
    st.paths.append(st.arena, rel) catch {
        st.arena.free(rel);
        st.mu.unlock();
        return error.OutOfMemory;
    };
    st.count += 1;
    st.mu.unlock();
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
