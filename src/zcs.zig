//! ZeroCopyState: shared-memory agent state for fx-companion.
//!
//! Layout (one POSIX shm object per state region, name "fxcomp-<key>"):
//!
//!   offset 0    : Header (fixed, 256 bytes, cache-line padded)
//!   offset 256  : mutex block (pthread_mutex_t + generation + writer pid)
//!   offset 512  : slab (payload bytes, capacity = size - 512)
//!
//! Header fields:
//!   magic       "FXZS"     - identifies a companion state region
//!   version     1          - layout version
//!   epoch       u64        - bumped on every successful put (monotonic)
//!   capacity    u64        - slab byte capacity
//!   length      u64        - valid payload bytes in slab (<= capacity)
//!   crc         u32        - CRC-32 of slab[0..length] (integrity check)
//!   flags       u32        - reserved
//!
//! Concurrency contract (documented per plan section 8):
//!   - Writers hold the region mutex only to memcpy payload + bump
//!     length/epoch/crc. Readers may either take the mutex (strong) or do a
//!     lock-free epoch check (fast path): read epoch, read slab, re-read
//!     epoch; if unchanged, the payload was stable across the read.
//!   - The mutex is a NORMAL pthread mutex living in the shared mapping;
//!     processes must not hold it across fork or while unmapping.
//!   - Ownership: creator owns the region until shm_unlink; attachers are
//!     read/write peers. Detach = munmap only; unlink removes the name.
//!
//! Everything is real system headers via @cImport; no transcribed structs.

const std = @import("std");

pub const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("pthread.h");
    @cInclude("errno.h");
});

pub const MAGIC: u32 = 0x46585A53; // "FXZS"
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 256;
pub const MUTEX_BLOCK_SIZE: usize = 256; // pthread_mutex_t (~64B) + metadata, padded
pub const SLAB_OFFSET: usize = HEADER_SIZE + MUTEX_BLOCK_SIZE;
pub const DEFAULT_CAPACITY: usize = 1 << 20; // 1 MiB slab

pub const Error = error{
    OpenFailed,
    FtruncateFailed,
    MmapFailed,
    BadMagic,
    BadVersion,
    TooLarge,
};

const MutexBlock = extern struct {
    mu: c.pthread_mutex_t,
    epoch: u64,
    writer_pid: i32,
    _pad: [MUTEX_BLOCK_SIZE - @sizeOf(c.pthread_mutex_t) - 16]u8 = undefined,
};

const Header = extern struct {
    magic: u32,
    version: u32,
    epoch: u64,
    capacity: u64,
    length: u64,
    crc: u32,
    flags: u32,
    _pad: [HEADER_SIZE - 48]u8 = undefined,
};

// Sanity: header must fit its reserved space.
comptime {
    if (@sizeOf(Header) > HEADER_SIZE) @compileError("Header overflow");
    if (@sizeOf(MutexBlock) > MUTEX_BLOCK_SIZE) @compileError("MutexBlock overflow");
}

/// CRC-32 (IEEE) over a byte slice; small table-free implementation is fine
/// at 1 MiB scale (memory-bandwidth-bound either way).
pub fn crc32(buf: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (buf) |b| {
        crc ^= b;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const mask: u32 = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return ~crc;
}

pub const Region = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    fd: c_int = -1,
    map: [*]u8 = undefined,
    map_len: usize = 0,
    created: bool = false,

    pub fn name(self: *const Region) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn hdr(self: *Region) *Header {
        return @ptrCast(@alignCast(self.map));
    }

    fn mblock(self: *Region) *MutexBlock {
        return @ptrCast(@alignCast(self.map + HEADER_SIZE));
    }

    pub fn slab(self: *Region) []u8 {
        return self.map[SLAB_OFFSET .. SLAB_OFFSET + self.hdr().capacity];
    }

    pub fn epoch(self: *Region) u64 {
        return @atomicLoad(u64, &self.hdr().epoch, .acquire);
    }

    /// Length + CRC as of a given epoch (pair read under the mutex is not
    /// required; both are written before the epoch release-store).
    pub fn lengthAt(self: *Region) u64 {
        return @atomicLoad(u64, &self.hdr().length, .acquire);
    }

    /// Create-or-open a state region with the given logical key and slab
    /// capacity. Creator truncates and initializes; attachers validate.
    pub fn open(key: []const u8, capacity: usize) Error!Region {
        if (key.len == 0 or key.len > 40) return Error.OpenFailed;
        var r = Region{};
        const n = std.fmt.bufPrint(&r.name_buf, "/fxcomp-{s}", .{key}) catch return Error.OpenFailed;
        r.name_len = n.len;
        r.name_buf[r.name_len] = 0;

        const fd = c.shm_open(@ptrCast(&r.name_buf), @intCast(c.O_RDWR | c.O_CREAT), @as(c_uint, 0o600));
        if (fd < 0) return Error.OpenFailed;
        r.fd = fd;
        errdefer _ = c.close(fd);

        const want_len = SLAB_OFFSET + capacity;
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) return Error.OpenFailed;
        r.created = st.st_size == 0;

        if (r.created) {
            if (c.ftruncate(fd, @intCast(want_len)) != 0) return Error.FtruncateFailed;
        } else if (st.st_size < @as(i64, @intCast(SLAB_OFFSET))) {
            return Error.BadVersion; // foreign or corrupt object
        }

        const map = c.mmap(null, want_len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (map == c.MAP_FAILED) return Error.MmapFailed;
        r.map = @ptrCast(map);
        r.map_len = want_len;

        if (r.created) {
            r.hdr().* = .{
                .magic = MAGIC,
                .version = VERSION,
                .epoch = 0,
                .capacity = capacity,
                .length = 0,
                .crc = 0,
                .flags = 0,
            };
            var attr: c.pthread_mutexattr_t = undefined;
            _ = c.pthread_mutexattr_init(&attr);
            _ = c.pthread_mutexattr_setpshared(&attr, c.PTHREAD_PROCESS_SHARED);
            _ = c.pthread_mutex_init(&r.mblock().mu, &attr);
            _ = c.pthread_mutexattr_destroy(&attr);
            r.mblock().epoch = 0;
            r.mblock().writer_pid = 0;
        } else {
            if (r.hdr().magic != MAGIC) return Error.BadMagic;
            if (r.hdr().version != VERSION) return Error.BadVersion;
            if (r.hdr().capacity != capacity) return Error.TooLarge;
        }
        return r;
    }

    /// Zero-copy write: memcpy src into the slab under the mutex, publish
    /// length+crc, bump epoch. One copy total (caller -> shm); no kernel
    /// copy beyond page cache, no serialization.
    pub fn put(self: *Region, src: []const u8) Error!void {
        if (src.len > self.hdr().capacity) return Error.TooLarge;
        const mb = self.mblock();
        _ = c.pthread_mutex_lock(&mb.mu);
        defer _ = c.pthread_mutex_unlock(&mb.mu);
        const h = self.hdr();
        @memcpy(self.slab()[0..src.len], src);
        h.length = src.len;
        h.crc = crc32(src);
        mb.writer_pid = c.getpid();
        // Release-store epoch last: readers use it as the commit marker.
        mb.epoch +%= 1;
        @atomicStore(u64, &h.epoch, mb.epoch, .release);
    }

    /// Strong read: copy out under the mutex. Returns the valid prefix.
    pub fn get(self: *Region, dst: []u8) Error![]u8 {
        const mb = self.mblock();
        _ = c.pthread_mutex_lock(&mb.mu);
        defer _ = c.pthread_mutex_unlock(&mb.mu);
        const h = self.hdr();
        const n: usize = @intCast(@min(h.length, dst.len));
        @memcpy(dst[0..n], self.slab()[0..n]);
        return dst[0..n];
    }

    /// Lock-free read: snapshot slab, verify epoch unchanged and CRC match.
    /// Returns the number of valid bytes copied, or null on a torn read.
    pub fn getLockFree(self: *Region, dst: []u8) Error!?[]u8 {
        const h = self.hdr();
        const e0 = @atomicLoad(u64, &h.epoch, .acquire);
        const n: usize = @intCast(@min(@atomicLoad(u64, &h.length, .monotonic), dst.len));
        @memcpy(dst[0..n], self.slab()[0..n]);
        const e1 = @atomicLoad(u64, &h.epoch, .acquire);
        if (e0 != e1) return null;
        if (crc32(dst[0..n]) != h.crc) return null;
        return dst[0..n];
    }

    pub fn detach(self: *Region) void {
        if (self.map_len > 0) {
            _ = c.munmap(self.map, self.map_len);
            self.map_len = 0;
        }
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    /// Remove the named object (creator-side cleanup).
    pub fn unlink(self: *Region) void {
        var tmp: [65]u8 = undefined;
        @memcpy(tmp[0..self.name_len], self.name_buf[0..self.name_len]);
        tmp[self.name_len] = 0;
        _ = c.shm_unlink(@ptrCast(&tmp));
    }
};

/// Unlink a state object by logical key without attaching to it. Used to
/// clear stale regions whose stored capacity no longer matches.
pub fn unlinkKey(key: []const u8) void {
    var buf: [64]u8 = undefined;
    const n = std.fmt.bufPrintZ(&buf, "/fxcomp-{s}", .{key}) catch return;
    _ = c.shm_unlink(n.ptr);
}

test "region put/get roundtrip" {
    var r = try Region.open("test-rt", 4096);
    defer r.unlink();
    defer r.detach();
    try r.put("hello zero-copy state");
    var buf: [4096]u8 = undefined;
    const got = try r.get(&buf);
    try std.testing.expectEqualStrings("hello zero-copy state", got);
    try std.testing.expectEqual(@as(u64, 1), r.epoch());
}

test "region lockfree read validates crc" {
    var r = try Region.open("test-lf", 4096);
    defer r.unlink();
    defer r.detach();
    try r.put("payload-abc");
    var buf: [4096]u8 = undefined;
    const got = (try r.getLockFree(&buf)).?;
    try std.testing.expectEqualStrings("payload-abc", got);
    try std.testing.expectEqual(@as(u64, 1), r.epoch());
}

test "region rejects oversize put" {
    var r = try Region.open("test-big", 64);
    defer r.unlink();
    defer r.detach();
    try std.testing.expectError(Error.TooLarge, r.put("x" ** 65));
}
