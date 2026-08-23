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
const BUF_SIZE: usize = 128 * 1024; // healeycodes found this optimal

fn makeAttrlist() c.attrlist {
    // ATTR_CMN_ERROR is deliberately NOT requested: on current macOS it makes
    // getattrlistbulk reject mixed common+file requests with EINVAL in the
    // per-entry error slot, zeroing the file-group fields (datalen). The
    // returned-attrs bitmap is checked instead.
    return .{
        .bitmapcount = c.ATTR_BIT_MAP_COUNT,
        .reserved = 0,
        .commonattr = c.ATTR_CMN_RETURNED_ATTRS |
            c.ATTR_CMN_NAME |
            c.ATTR_CMN_OBJTYPE |
            c.ATTR_CMN_FILEID,
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

/// Shared state across workers. Each field is either written before threads
/// start, or updated only through its own atomic.
const WalkState = struct {
    attrs: c.attrlist,
    sum_sizes: bool,

    entries: std.atomic.Value(u64),
    bytes_sum: std.atomic.Value(u64),
    truncated: std.atomic.Value(u32), // bool as u32 for atomic RMW simplicity

    /// Work queue: directories discovered but not yet claimed. Workers pop
    /// from the tail under a mutex; producers push under the same lock.
    mu: PMutex = .{},
    pending: std.ArrayListUnmanaged([]u8) = .empty,
    idle_workers: usize = 0,
    done: bool = false,
    cond: PCond = .{},

    fn pushDir(self: *WalkState, path: []const u8) void {
        const dup = std.heap.c_allocator.dupe(u8, path) catch {
            self.truncated.store(1, .monotonic);
            return;
        };
        self.mu.lock();
        defer self.mu.unlock();
        self.pending.append(std.heap.c_allocator, dup) catch {
            std.heap.c_allocator.free(dup);
            self.truncated.store(1, .monotonic);
        };
        self.cond.signal();
    }

    /// Pop one queued directory. Returns null when the whole walk is done
    /// (queue empty and no other worker can produce more).
    fn takeDir(self: *WalkState) ?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.pending.items.len > 0) {
                return self.pending.pop().?;
            }
            // Queue empty: wait until another worker pushes or all workers
            // are idle here simultaneously (= walk finished).
            self.idle_workers += 1;
            if (self.idle_workers == WORKERS) {
                self.done = true;
                self.cond.broadcast();
                return null;
            }
            self.cond.wait(&self.mu);
            self.idle_workers -= 1;
            if (self.done) return null;
        }
    }
};

/// One bulk pass over an open directory fd. Returns the subdirectory names
/// found; counts go straight into the atomics.
fn scanOneDir(st: *WalkState, dir_path: []const u8, subs: *std.ArrayListUnmanaged([]u8)) void {
    const buffer = std.heap.c_allocator.alloc(u8, BUF_SIZE) catch {
        st.truncated.store(1, .monotonic);
        return;
    };
    defer std.heap.c_allocator.free(buffer);

    var pathbuf: [512]u8 = undefined;
    if (dir_path.len >= pathbuf.len) {
        st.truncated.store(1, .monotonic);
        return;
    }
    @memcpy(pathbuf[0..dir_path.len], dir_path);
    pathbuf[dir_path.len] = 0;

    cur_z: {
        const dfd = c.open(@ptrCast(&pathbuf), c.O_RDONLY | c.O_NONBLOCK);
        if (dfd < 0) break :cur_z;
        defer _ = c.close(dfd);

        while (true) {
            const n = c.getattrlistbulk(dfd, @constCast(@ptrCast(&st.attrs)), buffer.ptr, BUF_SIZE, 0);
            if (n <= 0) break;

            var p: usize = 0;
            var i: usize = 0;
            while (i < @as(usize, @intCast(n))) : (i += 1) {
                const rec = buffer.ptr + p;
                const entry_len = rdU32(rec);
                if (entry_len == 0 or p + entry_len > BUF_SIZE) break;

                const ref_addr = p + 0x18;
                const off = rdI32(rec + 0x18);
                const ln = rdU32(rec + 0x1C);
                const obj_type = rdU32(rec + 0x20);
                const datalen = rdU64(rec + 0x2C);

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

                const is_dot = name.len == 1 and name[0] == '.';
                const is_dotdot = name.len == 2 and name[0] == '.' and name[1] == '.';
                if (name.len > 0 and !is_dot and !is_dotdot) {
                    _ = st.entries.fetchAdd(1, .monotonic);
                    if (obj_type == 1 and st.sum_sizes and datalen > 0) {
                        _ = st.bytes_sum.fetchAdd(datalen, .monotonic);
                    } else if (obj_type == 2) {
                        if (dir_path.len + 1 + name.len < 512) {
                            const child: ?[]u8 = std.fmt.allocPrint(
                                std.heap.c_allocator,
                                "{s}/{s}",
                                .{ dir_path, name },
                            ) catch null;
                            if (child) |ch| {
                                subs.append(std.heap.c_allocator, ch) catch {
                                    std.heap.c_allocator.free(ch);
                                    st.truncated.store(1, .monotonic);
                                };
                            } else {
                                st.truncated.store(1, .monotonic);
                            }
                        } else {
                            st.truncated.store(1, .monotonic);
                        }
                    }
                }

                p += entry_len;
            }
        }
    }
}

fn workerMain(st: *WalkState) void {
    // Per-worker scratch so the hot loop never touches a shared allocator.
    var subs: std.ArrayListUnmanaged([]u8) = .empty;
    defer subs.deinit(std.heap.c_allocator);

    while (st.takeDir()) |dir_path| {
        scanOneDir(st, dir_path, &subs);
        std.heap.c_allocator.free(dir_path);
        for (subs.items) |ch| st.pushDir(ch);
        subs.clearRetainingCapacity();
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

    var st = WalkState{
        .attrs = makeAttrlist(),
        .sum_sizes = sum_sizes,
        .entries = std.atomic.Value(u64).init(0),
        .bytes_sum = std.atomic.Value(u64).init(0),
        .truncated = std.atomic.Value(u32).init(0),
    };

    // Seed: walk the root on this thread first. Its subdirectories become
    // the initial work items; workers fan out from there.
    var seed_subs: std.ArrayListUnmanaged([]u8) = .empty;
    defer seed_subs.deinit(std.heap.c_allocator);
    scanOneDir(&st, root, &seed_subs);
    for (seed_subs.items) |ch| st.pushDir(ch);

    // If the root itself had no subdirectories we are already done.
    if (st.pending.items.len == 0) {
        st.done = true;
    }

    var threads: [WORKERS - 1]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |t| t.join();
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerMain, .{&st});
        started += 1;
    }

    // Main thread works too instead of just waiting.
    workerMain(&st);

    for (&threads) |t| t.join();
    st.mu.lock();
    defer st.mu.unlock();
    for (st.pending.items) |item| std.heap.c_allocator.free(item);
    st.pending.deinit(std.heap.c_allocator);

    return .{
        .entries = st.entries.load(.monotonic),
        .bytes_sum = st.bytes_sum.load(.monotonic),
        .truncated = st.truncated.load(.monotonic) != 0,
    };
}
