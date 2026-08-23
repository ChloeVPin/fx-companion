//! getattrlistbulk-based traversal using sys/attr.h via @cImport.
//!
//! Record layout (verified by hexdump on macOS 27 / arm64, WITHOUT
//! ATTR_CMN_ERROR in the request - see makeAttrlist):
//!   +0x00 u32 entry_length          stride to next record
//!   +0x04 attribute_set_t (20 B)
//!   +0x18 attrreference_t NAME {i32 dataoffset (rel. to +0x18); u32 length}
//!   +0x20 u32 objtype               1 = vreg, 2 = vdir
//!   +0x24 u64 fileid                packed tight, no pad
//!   +0x2C u64 datalen               files only
//!   name blob inline at +0x18+off; record padded to 8.
//!
//! Traversal: work-stealing directory queue. The root is walked by the main
//! thread; discovered subdirectories are handed off to a fixed worker pool,
//! each worker walking its own subtree independently. Counts are combined
//! with atomics. This mirrors the dumac finding that concurrency on top of
//! bulk syscalls is the dominant lever once attributes ride along.

const std = @import("std");
const shared = @import("fts_walk.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/attr.h");
    @cInclude("unistd.h");
    // Zig 0.16 gutted std.Thread sync primitives; pthreads are the stable
    // path on Darwin and we already link libc.
    @cInclude("pthread.h");
});

/// getdirentries(2): the same directory-read syscall fx's own walker uses
/// (std.Io.Dir.Iterator drives it via POSIX readdir). Fixed arity, NOT
/// variadic - safe to hand-declare (the fcntl trap does not apply).
/// The public symbol is deprecated in headers but still exported; the
/// extern declaration here bypasses header deprecation.
extern "c" fn getdirentries(fd: c_int, buf: [*]u8, nbytes: usize, basep: *i64) isize;
const DT_DIR: u8 = 4; // stable dirent d_type value

extern "c" fn __error() *c_int;
fn curErrno() c_int {
    return __error().*;
}

// Thin pthread shims. Darwin's pthread objects are opaque; PTHREAD_MUTEX_INITIALIZER
// semantics are provided by pthread_mutex_init with default attrs at runtime.
const PMutex = struct {
    inner: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
    init_done: bool = false,

    fn ensureInit(self: *PMutex) void {
        if (!self.init_done) {
            var attr: c.pthread_mutexattr_t = std.mem.zeroes(c.pthread_mutexattr_t);
            _ = c.pthread_mutexattr_init(&attr);
            _ = c.pthread_mutex_init(&self.inner, &attr);
            _ = c.pthread_mutexattr_destroy(&attr);
            self.init_done = true;
        }
    }

    fn lock(self: *PMutex) void {
        self.ensureInit();
        _ = c.pthread_mutex_lock(&self.inner);
    }
    fn unlock(self: *PMutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

const PCond = struct {
    inner: c.pthread_cond_t = std.mem.zeroes(c.pthread_cond_t),
    init_done: bool = false,

    fn ensureInit(self: *PCond) void {
        if (!self.init_done) {
            var attr: c.pthread_condattr_t = std.mem.zeroes(c.pthread_condattr_t);
            _ = c.pthread_condattr_init(&attr);
            _ = c.pthread_cond_init(&self.inner, &attr);
            _ = c.pthread_condattr_destroy(&attr);
            self.init_done = true;
        }
    }

    fn signal(self: *PCond) void {
        _ = c.pthread_cond_signal(&self.inner);
    }
    fn broadcast(self: *PCond) void {
        _ = c.pthread_cond_broadcast(&self.inner);
    }
    fn wait(self: *PCond, mu: *PMutex) void {
        mu.ensureInit();
        self.ensureInit();
        _ = c.pthread_cond_wait(&self.inner, &mu.inner);
    }
};

pub const WalkOut = shared.WalkOut;

pub const WORKERS = 8;
var workers_override: ?usize = null;

/// Testing/benchmark hook: override the worker count for the next walk.
/// Clamped to [1, WORKERS]: the thread stack below is sized for the
/// compiled-in maximum, and sweeps show no gains past 8 workers anyway.
pub fn setWorkers(n: usize) void {
    workers_override = if (n == 0) null else @min(n, WORKERS);
}

fn activeWorkers() usize {
    return workers_override orelse WORKERS;
}
const BUF_SIZE: usize = 128 * 1024; // healeycodes found this optimal

fn makeAttrlist(sum_sizes: bool) c.attrlist {
    // ATTR_CMN_ERROR is deliberately NOT requested: on current macOS it makes
    // getattrlistbulk reject mixed common+file requests with EINVAL in the
    // per-entry error slot, zeroing the file-group fields (datalen). The
    // returned-attrs bitmap is checked instead.
    //
    // Names mode (sum_sizes=false) also drops FILEID and DATALENGTH: every
    // requested group costs bytes per entry inside the 128 KB buffer, and
    // skipping them packs more entries per syscall. OBJTYPE must stay - it
    // drives recursion.
    return .{
        .bitmapcount = c.ATTR_BIT_MAP_COUNT,
        .reserved = 0,
        .commonattr = if (sum_sizes)
            c.ATTR_CMN_RETURNED_ATTRS |
                c.ATTR_CMN_NAME |
                c.ATTR_CMN_OBJTYPE |
                c.ATTR_CMN_FILEID
        else
            c.ATTR_CMN_RETURNED_ATTRS |
                c.ATTR_CMN_NAME |
                c.ATTR_CMN_OBJTYPE,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = if (sum_sizes) c.ATTR_FILE_DATALENGTH else 0,
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

/// A queued directory: the PARENT's open dirfd plus the child name and the
/// child's relative path. The consumer opens the child via openat at pop
/// time, so queued jobs hold no fds of their own.
/// A queued directory job. Carries the ROOT-RELATIVE path only; the fd is
/// opened at pop time through the walk's root dirfd, which stays valid for
/// the whole walk. Resolving against arbitrary parent fds is unsafe: a
/// parent fd may be closed once its own scan ends, and the kernel is free
/// to reuse that number for an unrelated file, turning openat into a
/// silent wrong-directory read.
const DirJob = struct {
    /// Opened at pop time; owned by the job until the worker closes it.
    dfd: c_int = -1,
    /// Root-relative, NUL-terminated: it is passed straight to openat(2).
    /// A non-terminated buffer only works while a zero byte happens to sit
    /// behind it - heap-layout luck, the source of phantom ENOENT drops.
    prefix: [:0]u8,
};

/// Shared state across workers. Each field is either written before threads
/// start, or updated only through its own atomic.
const WalkState = struct {
    attrs: c.attrlist,
    sum_sizes: bool,
    /// false = getattrlistbulk records, true = getdirentries(2) dirents
    /// (fx's own syscall). Switched per walk; the queue machinery is shared.
    use_gde: bool = false,
    /// Root dirfd, held open for the whole walk. Recovery path reopens
    /// lost parents through it (see takeDir).
    root_fd: c_int = -1,

    entries: std.atomic.Value(u64),
    bytes_sum: std.atomic.Value(u64),
    truncated: std.atomic.Value(u32), // bool as u32 for atomic RMW simplicity

    /// Work queue: deferred directory opens. Jobs carry the root-relative
    /// path; the fd is opened via openat(root_fd, path) at pop time. Queued
    /// jobs hold no fds, so simultaneously open fds stay bounded by
    /// activeWorkers()+1 regardless of tree shape or queue depth.
    mu: PMutex = .{},
    pending: std.ArrayListUnmanaged(DirJob) = .empty,
    idle_workers: usize = 0,
    done: bool = false,
    cond: PCond = .{},

    /// Queue one child directory by its root-relative path. Dups the
    /// string; holds no fd. Never blocks.
    fn pushDir(self: *WalkState, prefix: []const u8) void {
        const pdup = std.heap.c_allocator.dupeZ(u8, prefix) catch {
            self.truncated.store(1, .monotonic);
            return;
        };
        self.mu.lock();
        defer self.mu.unlock();
        self.pending.append(std.heap.c_allocator, .{ .prefix = pdup }) catch {
            std.heap.c_allocator.free(pdup);
            self.truncated.store(1, .monotonic);
        };
        self.cond.signal();
    }

    /// Pop one queued job and open it through the root dirfd. The returned
    /// job owns the fresh fd plus the path string. Returns null when the
    /// whole walk is done.
    fn takeDir(self: *WalkState) ?DirJob {
        const active_workers = activeWorkers();
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.pending.items.len > 0) {
                const q = self.pending.pop().?;
                // Open through the immortal root fd. prefix is root-relative
                // AND NUL-terminated (pushDirPath guarantees both), so this
                // is a well-defined C-string open every single time.
                const cdfd = c.openat(self.root_fd, q.prefix.ptr, c.O_RDONLY | c.O_NONBLOCK, @as(c_uint, 0));
                if (cdfd < 0) {
                    // Genuinely vanished between listing and opening:
                    // flag it, never pretend the walk was complete.
                    std.debug.print("[open-fail] errno={d} prefix={s}\n", .{ curErrno(), q.prefix });
                    self.truncated.store(1, .monotonic);
                    std.heap.c_allocator.free(q.prefix);
                    continue;
                }
                return .{ .dfd = cdfd, .prefix = q.prefix };
            }
            // Queue empty: wait until another worker pushes or all workers
            // are idle here simultaneously (= walk finished).
            self.idle_workers += 1;
            if (self.idle_workers == active_workers) {
                self.done = true;
                self.cond.broadcast();
                return null;
            }
            // NOTE: WORKERS counts every thread that calls takeDir(),
            // including the main thread's workerMain pass. Spawning
            // WORKERS-1 threads + main = WORKERS participants, so the
            // idle count reaching WORKERS really does mean quiescence.
            self.cond.wait(&self.mu);
            self.idle_workers -= 1;
            if (self.done) return null;
        }
    }
};

/// One bulk pass over an already-open directory fd. Consumes `dfd`.
/// Child directories are NOT opened here: (parent fd, name) pairs are
/// queued and the popper opens them, keeping in-flight fds bounded by the
/// worker count instead of the queue depth.
fn scanOneDirFd(st: *WalkState, dfd: c_int, prefix: []const u8, buffer: []u8) void {
    defer _ = c.close(dfd);
    scanOneDirNoClose(st, dfd, prefix, buffer);
}

/// Queue one child directory, building its root-relative path. Shared by
/// both backends. Dups the string; holds no fd.
fn pushDirPath(st: *WalkState, name: []const u8, prefix: []const u8) void {
    const child_prefix = if (prefix.len == 0)
        std.heap.c_allocator.dupeZ(u8, name) catch return
    else
        std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}/{s}", .{ prefix, name }, 0) catch return;
    st.pushDir(child_prefix);
}

/// getattrlistbulk record pass (bulk backend inner loop).
fn scanBulk(st: *WalkState, dfd: c_int, prefix: []const u8, buffer: []u8, local_entries: *u64, local_bytes: *u64) void {
    while (true) {
        const n = c.getattrlistbulk(dfd, @constCast(@ptrCast(&st.attrs)), buffer.ptr, buffer.len, 0);
        if (n <= 0) break;

        var p: usize = 0;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            const rec = buffer.ptr + p;
            const entry_len = rdU32(rec);
            if (entry_len == 0 or p + entry_len > buffer.len) break;

            const ref_addr = p + 0x18;
            const off = rdI32(rec + 0x18);
            const ln = rdU32(rec + 0x1C);
            const obj_type = rdU32(rec + 0x20);
            const datalen = rdU64(rec + 0x2C);

            var name2: []const u8 = "";
            if (ln > 0) {
                const nb_i = @as(i64, @intCast(ref_addr)) + off;
                if (nb_i >= 0 and nb_i + ln <= buffer.len) {
                    const nb: usize = @intCast(nb_i);
                    const span = @min(ln - 1, buffer.len - nb);
                    const nul = std.mem.indexOfScalar(u8, buffer[nb..][0..span], 0) orelse span;
                    name2 = buffer[nb..][0..nul];
                }
            }

            const is_dot = name2.len == 1 and name2[0] == '.';
            const is_dotdot = name2.len == 2 and name2[0] == '.' and name2[1] == '.';
            if (name2.len > 0 and !is_dot and !is_dotdot) {
                local_entries.* += 1;
                if (obj_type == 1 and st.sum_sizes and datalen > 0) {
                    local_bytes.* += datalen;
                } else if (obj_type == 2) {
                    pushDirPath(st, name2, prefix);
                }
            }

            p += entry_len;
        }
    }
}

/// getdirentries(2) pass: fx's own syscall with a big buffer per worker.
/// d_type drives recursion without a single stat; names mode only.
fn scanGde(st: *WalkState, dfd: c_int, prefix: []const u8, buffer: []u8, local_entries: *u64, local_bytes: *u64) void {
    _ = local_bytes; // getdirentries carries no sizes; names mode only
    var base: i64 = 0;
    while (true) {
        const n = getdirentries(dfd, buffer.ptr, buffer.len, &base);
        if (n <= 0) break;
        var p: usize = 0;
        const end: usize = @intCast(n);
        while (p + 8 <= end) {
            // Darwin legacy dirent as returned by getdirentries(2),
            // verified by hexdump on macOS 27 / arm64:
            //   d_ino u32 @0, d_reclen u16 @4, d_type u8 @6,
            //   d_namlen u8 @7, d_name @8, record padded to 4.
            // (Not the Linux layout, and not struct dirent's field order.)
            const reclen = std.mem.readInt(u16, buffer[p + 4 ..][0..2], .little);
            if (reclen < 8 or p + reclen > end) break;
            const dtype = buffer[p + 6];
            const namlen: usize = buffer[p + 7];
            if (namlen == 0 or 8 + namlen > reclen) break;
            const name2 = buffer[p + 8 ..][0..namlen];

            const is_dot = name2.len == 1 and name2[0] == '.';
            const is_dotdot = name2.len == 2 and name2[0] == '.' and name2[1] == '.';
            if (!is_dot and !is_dotdot) {
                local_entries.* += 1;
                if (dtype == DT_DIR) pushDirPath(st, name2, prefix);
            }
            p += reclen;
        }
    }
}

/// Same as scanOneDirFd but the caller keeps ownership of `dfd` (seed scan:
/// queued jobs still need the root fd as their openat parent).
/// One directory pass on whichever backend this walk uses; caller keeps
/// ownership of `dfd` (seed scan: queued jobs need it as openat parent).
fn scanOneDirNoClose(st: *WalkState, dfd: c_int, prefix: []const u8, buffer: []u8) void {
    // Local accumulators: one atomic add per directory instead of one RMW
    // per entry. With 409k entries over 8 threads the contended RMWs were
    // a measurable slice of total time.
    var local_entries: u64 = 0;
    var local_bytes: u64 = 0;
    defer {
        if (local_entries > 0) _ = st.entries.fetchAdd(local_entries, .monotonic);
        if (local_bytes > 0) _ = st.bytes_sum.fetchAdd(local_bytes, .monotonic);
    }

    if (st.use_gde) {
        scanGde(st, dfd, prefix, buffer, &local_entries, &local_bytes);
    } else {
        scanBulk(st, dfd, prefix, buffer, &local_entries, &local_bytes);
    }
}

fn workerMain(st: *WalkState) void {
    // Reusable 128 KB bulk buffer for this worker's whole lifetime.
    const buffer = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch return;
    defer std.heap.c_allocator.free(buffer);

    while (st.takeDir()) |job| {
        // scanOneDirFd closes job.dfd; we free the path string after.
        scanOneDirFd(st, job.dfd, job.prefix, buffer);
        std.heap.c_allocator.free(job.prefix);
    }
}

pub fn walkNames(root: []const u8) !WalkOut {
    return walkCommon(root, false);
}

pub fn walkAttrs(root: []const u8) !WalkOut {
    return walkCommon(root, true);
}

/// Names walk on fx's own syscall (getdirentries) instead of bulk records.
pub fn walkNamesGde(root: []const u8) !WalkOut {
    return walkCommonEx(root, false, true);
}

pub fn walkCommon(root: []const u8, sum_sizes: bool) !WalkOut {
    return walkCommonEx(root, sum_sizes, false);
}

pub fn walkCommonEx(root: []const u8, sum_sizes: bool, use_gde: bool) !WalkOut {
    if (root.len >= 512) return error.PathTooLong;
    var root_buf: [512]u8 = undefined;
    @memcpy(root_buf[0..root.len], root);
    root_buf[root.len] = 0;
    const root_z: [*:0]const u8 = @ptrCast(&root_buf);

    var st = WalkState{
        .attrs = makeAttrlist(sum_sizes),
        .sum_sizes = sum_sizes,
        .use_gde = use_gde,
        .root_fd = -1,
        .entries = std.atomic.Value(u64).init(0),
        .bytes_sum = std.atomic.Value(u64).init(0),
        .truncated = std.atomic.Value(u32).init(0),
    };

    // Seed: open the root and scan it on this thread. The root fd must stay
    // OPEN until the whole walk drains: queued jobs reference it as their
    // parent for openat. Closed after all workers join, below.
    const root_fd = c.open(@ptrCast(root_z), c.O_RDONLY | c.O_NONBLOCK);
    if (root_fd < 0) return error.FtsOpenFailed;
    st.root_fd = root_fd;
    const seed_buffer = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch return error.FtsOpenFailed;
    defer std.heap.c_allocator.free(seed_buffer);
    scanOneDirNoClose(&st, root_fd, "", seed_buffer);

    // If the root itself had no subdirectories we are already done.
    if (st.pending.items.len == 0) {
        st.done = true;
    }

    var threads: [WORKERS - 1]std.Thread = undefined;
    const n_extra = activeWorkers() - 1;
    var started: usize = 0;
    errdefer for (threads[0..started]) |t| t.join();
    for (threads[0..n_extra]) |*t| {
        t.* = try std.Thread.spawn(.{}, workerMain, .{&st});
        started += 1;
    }

    // Main thread works too instead of just waiting.
    workerMain(&st);

    for (threads[0..n_extra]) |t| t.join();
    st.mu.lock();
    st.root_fd = -1; // workers are gone; no pop-time opens can race the close
    st.mu.unlock();
    _ = c.close(root_fd); // all jobs popped; nothing references the root fd
    st.mu.lock();
    defer st.mu.unlock();
    for (st.pending.items) |item| {
        std.heap.c_allocator.free(item.prefix);
    }
    st.pending.deinit(std.heap.c_allocator);

    return .{
        .entries = st.entries.load(.monotonic),
        .bytes_sum = st.bytes_sum.load(.monotonic),
        .truncated = st.truncated.load(.monotonic) != 0,
    };
}
