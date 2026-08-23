// statetool: ZeroCopyState proof-of-concept client.
//
// Subcommands:
//   statetool put <key> <text...>   write text into the shared region and
//                                   ask the daemon to attach + verify
//   statetool get <key>             attach directly (no daemon) and print
//   statetool bench <key> <bytes>   measure hand-off cost: shm put+epoch
//                                   read vs fork/exec+pipe round trip
//
// The point of `put` then `get` as separate processes: the second process
// reads state written by the first with no serialization, no socket/pipe
// copy, and no daemon involvement in the read path - both processes see
// the same physical pages.

const std = @import("std");
const c = @import("machc.zig");
const zcs = @import("zcs.zig");

const pollc = @cImport({
    @cInclude("poll.h");
});
// fcntl(2) is variadic; a hand-written fixed-arity extern decl compiles but
// silently fails to apply F_SETFL flags on this toolchain (arm64 macOS,
// Zig 0.16): it returns 0 while O_NONBLOCK never takes effect. Route every
// fcntl call through the true C prototype instead.
const fcntlc = @cImport({
    @cInclude("fcntl.h");
});

const SERVICE_NAME = "dev.fx.companion";
const MSG_STATE_PUT: u32 = 4;

const StateRequest = extern struct {
    hdr: c.mach_msg_header_t,
    key: [48]u8,
    capacity: u64 = zcs.DEFAULT_CAPACITY,
    /// Exact payload bytes that follow the struct. Wire padding after the
    /// payload is NOT part of the payload.
    payload_len: u64 = 0,
};

const StateReply = extern struct {
    hdr: c.mach_msg_header_t,
    status: u32,
    _pad: u32,
    epoch: u64,
    length: u64,
    // The kernel appends a 52-byte audit trailer on receive; without this
    // pad the receive buffer is smaller than the delivered message and
    // mach_msg fails with MACH_RCV_MSG (trailer space required).
    trailer_pad: [128]u8 = [_]u8{0} ** 128,
};

fn usage() void {
    std.debug.print(
        "usage: statetool put <key> <payload> | get <key> | bench <key> <bytes>\n",
        .{},
    );
}

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
const Timespec = extern struct { sec: isize, nsec: isize };
fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
// NOTE: do not hand-declare fcntl here; use fcntlc.fcntl (variadic proto).
extern "c" fn __error() *c_int; // per-thread errno on Darwin
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, opts: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;

const F_GETFL: c_int = 3; // kept for reference; fcntlc.F_GETFL used below
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x0004; // Darwin
const EAGAIN: c_int = 35; // Darwin

fn setNonblock(fd: c_int) void {
    const cur = fcntlc.fcntl(fd, fcntlc.F_GETFL, @as(c_int, 0));
    if (cur < 0) return;
    _ = fcntlc.fcntl(fd, fcntlc.F_SETFL, cur | @as(c_int, fcntlc.O_NONBLOCK));
}

fn lastErrno() c_int {
    return __error().*;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const cmd = args.next() orelse {
        usage();
        return error.BadUsage;
    };

    if (std.mem.eql(u8, cmd, "put")) {
        const key = args.next() orelse return error.BadUsage;
        const payload = args.next() orelse return error.BadUsage;

        var region = try zcs.Region.open(key, zcs.DEFAULT_CAPACITY);
        defer region.detach();
        // Do NOT unlink: the region outlives this process by design.
        try region.put(payload);

        // Ask the daemon to attach to the same object and confirm.
        askDaemonPut(key, payload) catch |e| {
            std.debug.print("daemon attach failed ({s}); local write still valid\n", .{@errorName(e)});
            return;
        };
        std.debug.print("put ok: key={s} len={d} epoch={d} (daemon attached)\n", .{ key, payload.len, region.epoch() });
        return;
    }

    if (std.mem.eql(u8, cmd, "get")) {
        const key = args.next() orelse return error.BadUsage;
        var region = try zcs.Region.open(key, zcs.DEFAULT_CAPACITY);
        defer region.detach();
        var buf: [zcs.DEFAULT_CAPACITY]u8 = undefined;
        const got = (try region.getLockFree(&buf)) orelse {
            std.debug.print("torn read; retry\n", .{});
            return error.TornRead;
        };
        std.debug.print("get ok: epoch={d} len={d} data={s}\n", .{ region.epoch(), got.len, got });
        return;
    }

    if (std.mem.eql(u8, cmd, "bench")) {
        const key = args.next() orelse return error.BadUsage;
        const bytes_str = args.next() orelse "65536";
        const nbytes = try std.fmt.parseInt(usize, bytes_str, 10);
        try benchHandoff(key, nbytes);
        return;
    }

    usage();
    return error.BadUsage;
}

/// Send MSG_STATE_PUT with an inline payload; the daemon attaches to the
/// same shm object and writes independently, proving shared visibility.
fn askDaemonPut(key: []const u8, payload: []const u8) !void {
    var port: c.mach_port_t = c.MACH_PORT_NULL;
    if (c.bootstrap_look_up(c.bootstrap_port, SERVICE_NAME, &port) != c.KERN_SUCCESS)
        return error.NoDaemon;

    var msg_buf: [@sizeOf(StateRequest) + 4096]u8 align(8) = undefined;
    @memset(&msg_buf, 0);
    const req: *StateRequest = @ptrCast(@alignCast(&msg_buf));
    const klen = @min(key.len, req.key.len - 1);
    @memcpy(req.key[0..klen], key[0..klen]);
    req.capacity = zcs.DEFAULT_CAPACITY;
    const plen = @min(payload.len, msg_buf.len - @sizeOf(StateRequest));
    @memcpy(msg_buf[@sizeOf(StateRequest)..][0..plen], payload[0..plen]);
    // Mach message sizes are 4-byte multiples; pad the tail.
    const wire_len = std.mem.alignForward(usize, @sizeOf(StateRequest) + plen, 4);
    req.payload_len = plen;

    req.hdr = .{
        .msgh_bits = c.MACH_MSG_TYPE_COPY_SEND | (@as(u32, c.MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8),
        .msgh_size = @intCast(wire_len),
        .msgh_remote_port = port,
        .msgh_local_port = c.MACH_PORT_NULL,
        .msgh_voucher_port = 0,
        .msgh_id = @bitCast(MSG_STATE_PUT),
    };

    var reply_port: c.mach_port_t = c.MACH_PORT_NULL;
    const alloc_kr = machPortAllocate(&reply_port);
    if (alloc_kr != c.KERN_SUCCESS) return error.PortAllocFailed;
    defer _ = c.mach_port_deallocate(c.mach_task_self(), reply_port);
    // The reply-port right must ride IN the message (local_port slot with a
    // send-once right) for the daemon to answer.
    req.hdr.msgh_local_port = reply_port;

    const sent = c.mach_msg(&req.hdr, c.MACH_SEND_MSG, req.hdr.msgh_size, 0, c.MACH_PORT_NULL, 0, c.MACH_PORT_NULL);
    if (sent != c.KERN_SUCCESS) {
        std.debug.print("mach send failed kr=0x{x}\n", .{@as(u32, @bitCast(sent))});
        return error.SendFailed;
    }

    var reply: StateReply = undefined;
    reply.hdr.msgh_local_port = reply_port;
    const got = c.mach_msg(&reply.hdr, c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT, 0, @sizeOf(StateReply), reply_port, 5_000, c.MACH_PORT_NULL);
    if (got != c.KERN_SUCCESS) return error.ReceiveFailed;
    if (reply.status != 0) return error.DaemonRejected;
}

extern "c" fn mach_port_allocate(task: c.mach_port_t, right: c_int, name: *c.mach_port_t) c.kern_return_t;
fn machPortAllocate(out: *c.mach_port_t) c.kern_return_t {
    return mach_port_allocate(c.mach_task_self(), MACH_PORT_RIGHT_RECEIVE_SHIM, out);
}
const MACH_PORT_RIGHT_RECEIVE_SHIM: c_int = 1;

/// The Week 4 proof: compare two hand-off mechanisms for one blob.
///   A. ZeroCopyState: writer puts into shm; reader attaches lock-free-reads.
///      Cost = memcpy into pages + epoch/CRC check on read.
///   B. fork/exec + pipe: spawn a child that echoes the blob back through a
///      pipe (the classic tool-process pattern: fork/exec + serialize +
///      kernel pipe copy x2).
fn benchHandoff(key: []const u8, nbytes: usize) !void {
    const runs = 5;
    var gpa_state = std.heap.DebugAllocator(.{}){};
    const alloc = gpa_state.allocator();

    const blob = try alloc.alloc(u8, nbytes);
    defer alloc.free(blob);
    for (blob, 0..) |*b, i| b.* = @truncate(i *% 2654435761 +% 7);

    var times_a: [32]u64 = undefined;
    var sum_ok: usize = 0;

    // Warm the region once so both sides map resident pages, then unlink:
    // each timed iteration creates a fresh region at exactly nbytes.
    zcs.unlinkKey(key);
    {
        var r = try zcs.Region.open(key, @max(nbytes, 4096));
        try r.put(blob);
        r.detach();
        r.unlink();
    }

    // A-fast: no-CRC put + lock-free no-CRC get (the shipped fast path).
    for (0..runs) |i| {
        var r = try zcs.Region.open(key, @max(nbytes, 4096));
        defer r.detach();
        const t0 = nowNs();
        try r.putNoCrc(blob); // fast path: no CRC over the payload
        const dst = try alloc.alloc(u8, nbytes);
        defer alloc.free(dst);
        const got = (try r.getLockFreeNoCrc(dst)) orelse return error.TornRead;
        if (got.len == nbytes and std.mem.eql(u8, got, blob)) sum_ok += 1;
        times_a[i] = nowNs() - t0;
    }

    // A-crc: CRC-checked put + lock-free get with CRC verify (integrity
    // cost paid twice per blob: once on write, once on read).
    var times_ac: [32]u64 = undefined;
    var sum_ok_crc: usize = 0;
    for (0..runs) |i| {
        var r = try zcs.Region.open(key, @max(nbytes, 4096));
        defer r.detach();
        const t0 = nowNs();
        try r.put(blob);
        const dst = try alloc.alloc(u8, nbytes);
        defer alloc.free(dst);
        const got = (try r.getLockFree(dst)) orelse return error.TornRead;
        if (got.len == nbytes and std.mem.eql(u8, got, blob)) sum_ok_crc += 1;
        times_ac[i] = nowNs() - t0;
    }

    // B: fork a child that reads N bytes from a pipe and writes them back.
    // The parent's pipe fds are O_NONBLOCK and driven by poll(), so no
    // write() can ever block past what the kernel accepts: this loop cannot
    // deadlock regardless of payload size (the earlier blocking-fd version
    // deadlocked at 1 MB when both 64 KB pipes filled).
    var times_b: [32]u64 = undefined;
    const self_path = "/bin/cat"; // cat as the child "tool": reads stdin -> stdout
    const cat_argv = [_:null]?[*:0]const u8{ self_path, null };
    for (0..runs) |slot| {
        var p2c: [2]c_int = undefined;
        var c2p: [2]c_int = undefined;
        if (pipe(&p2c) != 0 or pipe(&c2p) != 0) return error.PipeFailed;
        setNonblock(p2c[1]); // parent write side
        setNonblock(c2p[0]); // parent read side
        const t0 = nowNs();
        const pid = fork();
        if (pid == 0) {
            // Child keeps blocking fds; it is a plain `cat` copy loop.
            _ = dup2(p2c[0], 0);
            _ = dup2(c2p[1], 1);
            _ = close(p2c[0]);
            _ = close(p2c[1]);
            _ = close(c2p[0]);
            _ = close(c2p[1]);
            _ = execv(self_path, &cat_argv);
            _exit(127);
        }
        _ = close(p2c[0]);
        _ = close(c2p[1]);
        var off: usize = 0;
        var got: usize = 0;
        var w_open = true; // parent still has bytes to write
        var pfd: [2]pollc.pollfd = undefined;
        while (got < nbytes) {
            const want_w = w_open and off < nbytes;
            // Always pass 2 fds; fd=-1 entries are ignored by poll(2).
            pfd[0] = .{ .fd = if (want_w) p2c[1] else -1, .events = pollc.POLLOUT, .revents = 0 };
            pfd[1] = .{ .fd = c2p[0], .events = pollc.POLLIN, .revents = 0 };
            const nready = pollc.poll(&pfd, 2, -1);
            if (nready <= 0) break;
            if (want_w and (pfd[0].revents & @as(c_short, pollc.POLLOUT | pollc.POLLERR | pollc.POLLHUP)) != 0) {
                // Non-blocking: write whatever the pipe accepts now.
                const wr = write(p2c[1], blob.ptr + off, @min(nbytes - off, 65536));
                if (wr < 0) {
                    // EAGAIN: pipe full; poll again next round. Any other
                    // error means the child is gone - stop writing.
                    if (lastErrno() != EAGAIN) w_open = false;
                } else {
                    off += @intCast(wr);
                    if (off >= nbytes) {
                        w_open = false;
                        _ = close(p2c[1]); // EOF to child
                    }
                }
            }
            if ((pfd[1].revents & @as(c_short, pollc.POLLIN | pollc.POLLERR | pollc.POLLHUP)) != 0) {
                const rd = read(c2p[0], blob.ptr + got, @min(nbytes - got, 65536));
                if (rd < 0 and lastErrno() == EAGAIN) continue; // drained for now
                if (rd <= 0) break;
                got += @intCast(rd);
            }
        }
        _ = close(p2c[1]);
        _ = close(c2p[0]);
        var st: c_int = 0;
        _ = waitpid(pid, &st, 0);
        times_b[slot] = nowNs() - t0;
    }

    std.mem.sort(u64, times_a[0..runs], {}, std.sort.asc(u64));
    std.mem.sort(u64, times_ac[0..runs], {}, std.sort.asc(u64));
    std.mem.sort(u64, times_b[0..runs], {}, std.sort.asc(u64));
    std.debug.print("hand-off {d} bytes, {d} runs, verified noCrc {d}/{d}, crc {d}/{d}\n", .{ nbytes, runs, sum_ok, runs, sum_ok_crc, runs });
    std.debug.print("A zerocopy-state (put+lockfree-get): median {d} us\n", .{times_a[runs / 2] / 1000});
    const speedup = @as(f64, @floatFromInt(times_b[runs / 2])) / @as(f64, @floatFromInt(@max(1, times_a[runs / 2])));
    if (times_ac[runs / 2] > 0) {
        std.debug.print("A zerocopy-state CRC (put+crc-get):  median {d} us\n", .{times_ac[runs / 2] / 1000});
    }
    std.debug.print("B fork/exec+pipe (cat echo):         median {d} us\n", .{times_b[runs / 2] / 1000});
    std.debug.print("speedup A-nocrc vs B: {d:.1}x | A-crc vs B: {d:.1}x\n", .{ speedup, @as(f64, @floatFromInt(times_b[runs / 2])) / @as(f64, @floatFromInt(@max(1, times_ac[runs / 2]))) });
    // Cleanup so a later run at a different size does not inherit capacity.
    zcs.unlinkKey(key);
}
