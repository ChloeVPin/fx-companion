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
pub fn setWorkers(n: usize) void {
    workers_override = n;
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
const DirJob = struct {
    // Queued form: parent fd + name (no fds held while queued).
    parent_dfd: c_int = -1,
    name: []u8 = "",
    // Popped form handed to the worker: own fd + path.
    dfd: c_int = -1,
    prefix: []u8,
};

/// Shared state across workers. Each field is either written before threads
/// start, or updated only through its own atomic.
const WalkState = struct {
    attrs: c.attrlist,
    sum_sizes: bool,

    entries: std.atomic.Value(u64),
    bytes_sum: std.atomic.Value(u64),
    truncated: std.atomic.Value(u32), // bool as u32 for atomic RMW simplicity

    /// Work queue: deferred directory opens. Jobs carry the PARENT dirfd plus
    /// the child name; the fd is duped via openat at pop time. Queued jobs
    /// therefore hold no fds of their own - the number of simultaneously
    /// open fds is bounded by activeWorkers()+1 regardless of tree shape,
    /// which keeps us safe under any RLIMIT_NOFILE (a queue of open fds
    /// silently dropped subtrees under launchd's default limit).
    mu: PMutex = .{},
    pending: std.ArrayListUnmanaged(DirJob) = .empty,
    idle_workers: usize = 0,
    done: bool = false,
    cond: PCond = .{},

    /// Queue one child directory as (parent fd, name, path). Dups both
    /// strings; holds no fd. Never blocks.
    fn pushDir(self: *WalkState, parent_dfd: c_int, name: []const u8, prefix: []const u8) void {
        const ndup = std.heap.c_allocator.dupe(u8, name) catch {
            self.truncated.store(1, .monotonic);
            return;
        };
        const pdup: []u8 = std.heap.c_allocator.dupe(u8, prefix) catch {
            std.heap.c_allocator.free(ndup);
            self.truncated.store(1, .monotonic);
            return;
        };
        self.mu.lock();
        defer self.mu.unlock();
        self.pending.append(std.heap.c_allocator, .{ .parent_dfd = parent_dfd, .name = ndup, .prefix = pdup }) catch {
            std.heap.c_allocator.free(ndup);
            std.heap.c_allocator.free(pdup);
            self.truncated.store(1, .monotonic);
        };
        self.cond.signal();
    }

    /// Pop one queued directory and OPEN it via openat against the parent
    /// fd. The returned job owns the fresh fd plus the path string. Returns
    /// null when the whole walk is done.
    fn takeDir(self: *WalkState) ?DirJob {
        const active_workers = activeWorkers();
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.pending.items.len > 0) {
                const q = self.pending.pop().?;
                const cdfd = c.openat(q.parent_dfd, @ptrCast(q.name.ptr), c.O_RDONLY | c.O_NONBLOCK, @as(c_uint, 0));
                std.heap.c_allocator.free(q.name);
                if (cdfd < 0) {
                    // Child vanished or is unopenable; skip, keep draining.
                    if (q.prefix.len > 0) std.heap.c_allocator.free(q.prefix);
                    continue;
                }
                return .{ .parent_dfd = q.parent_dfd, .name = "", .dfd = cdfd, .prefix = q.prefix };
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

/// Same as scanOneDirFd but the caller keeps ownership of `dfd` (seed scan:
/// queued jobs still need the root fd as their openat parent).
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
                local_entries += 1;
                if (obj_type == 1 and st.sum_sizes and datalen > 0) {
                    local_bytes += datalen;
                } else if (obj_type == 2) {
                    // DEFER the child's open: queue (parent fd, name). Only
                    // workers popping jobs hold open fds, so total in-flight
                    // fds = activeWorkers + seed, independent of tree width.
                    // (Opening eagerly parked one fd per queued job and hit
                    // RLIMIT_NOFILE at ~250 dirs on wide trees.)
                    const child_prefix = if (prefix.len == 0)
                        std.heap.c_allocator.dupe(u8, name2) catch null
                    else
                        std.fmt.allocPrint(std.heap.c_allocator, "{s}/{s}", .{ prefix, name2 }) catch null;
                    if (child_prefix) |cp| {
                        st.pushDir(dfd, name2, cp);
                        std.heap.c_allocator.free(cp);
                    } else {
                        st.truncated.store(1, .monotonic);
                    }
                }
            }

            p += entry_len;
        }
    }
}



fn workerMain(st: *WalkState) void {
    // Reusable 128 KB bulk buffer for this worker's whole lifetime.
    const buffer = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch return;
    defer std.heap.c_allocator.free(buffer);

    while (st.takeDir()) |job| {
        // scanOneDirFd closes job.dfd; we free the path string after.
        scanOneDirFd(st, job.dfd, job.prefix, buffer);
        if (job.prefix.len > 0) std.heap.c_allocator.free(job.prefix);
    }
}

pub fn walkNames(root: []const u8) !WalkOut {
    return walkCommon(root, false);
}

pub fn walkAttrs(root: []const u8) !WalkOut {
    return walkCommon(root, true);
}

pub fn walkCommon(root: []const u8, sum_sizes: bool) !WalkOut {
    if (root.len >= 512) return error.PathTooLong;
    var root_buf: [512]u8 = undefined;
    @memcpy(root_buf[0..root.len], root);
    root_buf[root.len] = 0;
    const root_z: [*:0]const u8 = @ptrCast(&root_buf);

    var st = WalkState{
        .attrs = makeAttrlist(sum_sizes),
        .sum_sizes = sum_sizes,
        .entries = std.atomic.Value(u64).init(0),
        .bytes_sum = std.atomic.Value(u64).init(0),
        .truncated = std.atomic.Value(u32).init(0),
    };

    // Seed: open the root and scan it on this thread. The root fd must stay
    // OPEN until the whole walk drains: queued jobs reference it as their
    // parent for openat. Closed after all workers join, below.
    const root_fd = c.open(@ptrCast(root_z), c.O_RDONLY | c.O_NONBLOCK);
    if (root_fd < 0) return error.FtsOpenFailed;
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
    _ = c.close(root_fd); // queued jobs all popped; no openat parents left
    st.mu.lock();
    defer st.mu.unlock();
    for (st.pending.items) |item| {
        std.heap.c_allocator.free(item.name);
        if (item.prefix.len > 0) std.heap.c_allocator.free(item.prefix);
    }
    st.pending.deinit(std.heap.c_allocator);

    return .{
        .entries = st.entries.load(.monotonic),
        .bytes_sum = st.bytes_sum.load(.monotonic),
        .truncated = st.truncated.load(.monotonic) != 0,
    };
}
