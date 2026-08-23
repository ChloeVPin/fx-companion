// fx-companiond: on-demand Mach service daemon.
//
// RPCs (msgh_id):
//   MSG_PING (1): reply payload "pong" - used for round-trip latency.
//   MSG_STAT (2): reply JSON-ish text with uptime and request count.
//
// Security model: every connection is validated before any work happens.
// The kernel stamps each received message with an unforgeable audit-token
// trailer; we require the peer euid to match ours and log pid/pidversion so
// a recycled pid cannot silently impersonate an earlier client.

const std = @import("std");
const c = @import("machc.zig");
const walklib = @import("walklib");

const SERVICE_NAME = "dev.fx.companion";
const MSG_PING: u32 = 1;
const MSG_STAT: u32 = 2;
/// Traversal RPC: request carries a NUL-padded root path; reply carries
/// entry/byte counts plus the walk's own elapsed time. Heavy work stays in
/// the daemon per PLAN section 4.
const MSG_WALK: u32 = 3;

const RECV_BUFFER_SIZE = 4096;

var start_ns: u64 = 0;
var requests: u64 = 0;
/// Self-timed main-entry -> bootstrap_check_in complete, in microseconds.
/// Exposed via MSG_STAT so the cold-start budget is measurable end to end.
var init_us: u64 = 0;

const Reply = extern struct {
    hdr: c.mach_msg_header_t,
    payload: [96]u8 align(8),
};

/// Client -> daemon body for MSG_WALK. Inline (no OOL) keeps the wire simple;
/// 512 bytes matches the walkers' internal path buffers.
const WalkRequest = extern struct {
    hdr: c.mach_msg_header_t,
    root: [512]u8,
};

/// Daemon -> client body for MSG_WALK.
const WalkReply = extern struct {
    hdr: c.mach_msg_header_t,
    /// 0 = ok, 1 = path too long, 2 = out of memory, 3 = open failed,
    /// 4 = ok but truncated (fixed dir table filled; counts are lower
    /// bounds), 5 = another walk in flight, retry shortly
    status: u32,
    _pad: u32 = 0,
    entries: u64,
    bytes_sum: u64,
    elapsed_ns: u64,
};

/// Walks run off the main receive loop so one blocked open() (macOS TCC
/// consent on a protected folder can block indefinitely) never wedges the
/// service. At most one walk runs at a time; concurrent requests get an
/// immediate busy status instead of queuing.
var walk_busy: u8 = 0;

/// Validate the peer behind a just-received message via its audit trailer.
/// The trailer is stamped by the kernel from the sender's task, so userspace
/// cannot forge it. Returns peer pid when accepted, null when rejected.
fn validatePeer(hdr: *const c.mach_msg_header_t) ?struct { pid: i32, pidversion: i32 } {
    const msg_size = hdr.msgh_size;
    // Simple-message trailers start right after the body, 4-byte aligned.
    const off = std.mem.alignForward(u32, msg_size, 4);
    if (@as(usize, off) + @sizeOf(c.mach_msg_audit_trailer_t) > RECV_BUFFER_SIZE) return null;

    const base: [*]const u8 = @ptrCast(hdr);
    const trailer: *const c.mach_msg_audit_trailer_t = @ptrCast(@alignCast(base + off));
    if (trailer.msgh_trailer_type != c.MACH_MSG_TRAILER_FORMAT_0) return null;
    if (trailer.msgh_trailer_size != @sizeOf(c.mach_msg_audit_trailer_t)) return null;
    // msgh_size covers the body only; the kernel appends the trailer after it,
    // so there is no upper-bound relation between msg_size and trailer_size.

    // Same-user policy for a user LaunchAgent.
    // audit_token_t layout: auid euid egid ruid rgid pid asid pidversion
    if (trailer.msgh_audit.val[1] != @as(u32, @bitCast(c.geteuid()))) return null;
    return .{
        .pid = @bitCast(trailer.msgh_audit.val[5]),
        .pidversion = @bitCast(trailer.msgh_audit.val[7]),
    };
}

fn sendReply(remote: u32, id: u32, payload: []const u8) void {
    var reply: Reply = undefined;
    @memset(std.mem.asBytes(&reply), 0);
    reply.hdr = .{
        // Replying consumes the send-once right that arrived in the
        // received message's remote-port slot.
        .msgh_bits = c.MACH_MSG_TYPE_MOVE_SEND_ONCE,
        .msgh_size = @sizeOf(Reply),
        .msgh_remote_port = remote,
        .msgh_local_port = c.MACH_PORT_NULL,
        .msgh_voucher_port = 0,
        .msgh_id = @intCast(id),
    };
    const n = @min(payload.len, reply.payload.len);
    @memcpy(reply.payload[0..n], payload[0..n]);
    const sret = c.mach_msg(
        &reply.hdr,
        c.MACH_SEND_MSG,
        @sizeOf(Reply),
        0,
        c.MACH_PORT_NULL,
        0,
        c.MACH_PORT_NULL,
    );
    if (sret != c.KERN_SUCCESS) {
        std.debug.print("[fx-companiond] reply send FAILED kr={x} (3=INVALID_DEST, 13=SEND_ONCE_RIGHT)\n", .{@as(u32, @bitCast(sret))});
    }
}

fn handleConnection(hdr: *c.mach_msg_header_t) void {
    const peer = validatePeer(hdr) orelse {
        std.debug.print("[fx-companiond] connection rejected (foreign uid or malformed trailer)\n", .{});
        return;
    };
    requests += 1;
    switch (hdr.msgh_id) {
        MSG_PING => sendReply(hdr.msgh_remote_port, MSG_PING, "pong"),
        MSG_STAT => {
            var buf: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{{\"uptime_s\":{d},\"requests\":{d},\"init_us\":{d}}}", .{
                (c.nowNs() - start_ns) / 1_000_000_000,
                requests,
                init_us,
            }) catch "{\"error\":\"fmt\"}";
            sendReply(hdr.msgh_remote_port, MSG_STAT, s);
        },
        MSG_WALK => {
            // The request body follows the 24-byte header; the audit trailer
            // sits beyond msgh_size, so a well-formed walk request can never
            // collide with it.
            if (hdr.msgh_size < @sizeOf(WalkRequest)) {
                var bad = WalkReply{
                    .hdr = undefined,
                    .status = 3,
                    .entries = 0,
                    .bytes_sum = 0,
                    .elapsed_ns = 0,
                };
                sendWalkReply(hdr, &bad);
                return;
            }
            const req: *const WalkRequest = @ptrCast(@alignCast(hdr));
            // Bound the scan to the actual message body. The 512-byte field
            // extends past msgh_size into kernel trailer territory; sliceTo
            // without the bound would read (zeroed) trailer bytes and
            // truncate every path to empty.
            const body_end: usize = @min(hdr.msgh_size, @sizeOf(WalkRequest));
            const root = std.mem.sliceTo(req.root[0 .. body_end - @sizeOf(c.mach_msg_header_t)], 0);

            // Copy the path out of the receive buffer: the buffer is reused
            // by the main loop as soon as this handler returns.
            var job = WalkJob{};
            const ncpy = @min(root.len, job.root.len - 1);
            @memcpy(job.root[0..ncpy], root[0..ncpy]);
            job.root_len = ncpy;
            @memcpy(job.reply_to[0..@sizeOf(c.mach_msg_header_t)], std.mem.asBytes(hdr)[0..@sizeOf(c.mach_msg_header_t)]);

            // Claim the single walk slot; a concurrent request is told busy
            // immediately rather than queued behind a possibly blocked walk.
            if (@cmpxchgStrong(u8, &walk_busy, 0, 1, .acq_rel, .monotonic) != null) {
                var busy = WalkReply{
                    .hdr = undefined,
                    .status = 5,
                    .entries = 0,
                    .bytes_sum = 0,
                    .elapsed_ns = 0,
                };
                sendWalkReply(hdr, &busy);
                return;
            }
            const th = std.Thread.spawn(.{}, walkWorker, .{job}) catch {
                @atomicStore(u8, &walk_busy, 0, .release);
                return;
            };
            th.detach();
        },
        else => {},
    }
    std.debug.print("[fx-companiond] served pid={d} version={d}\n", .{ peer.pid, peer.pidversion });
}

/// State handed to the walk worker thread. Owns its copy of the root path
/// and a snapshot of the request header (for the reply-port right).
const WalkJob = struct {
    root: [512]u8 = undefined,
    root_len: usize = 0,
    reply_to: [@sizeOf(c.mach_msg_header_t)]u8 align(8) = undefined,

    fn hdr(self: *const WalkJob) *const c.mach_msg_header_t {
        return @ptrCast(@alignCast(&self.reply_to));
    }
};

fn walkWorker(job: WalkJob) void {
    defer @atomicStore(u8, &walk_busy, 0, .release);
    const t0 = c.nowNs();
    const out = walklib.walkAttrs(job.root[0..job.root_len]) catch |e| {
        var bad = WalkReply{
            .hdr = undefined,
            .status = switch (e) {
                error.PathTooLong => 1,
                error.Oom => 2,
            },
            .entries = 0,
            .bytes_sum = 0,
            .elapsed_ns = c.nowNs() - t0,
        };
        sendWalkReply(job.hdr(), &bad);
        return;
    };
    var ok = WalkReply{
        .hdr = undefined,
        .status = if (out.truncated) 4 else 0,
        .entries = out.entries,
        .bytes_sum = out.bytes_sum,
        .elapsed_ns = c.nowNs() - t0,
    };
    sendWalkReply(job.hdr(), &ok);
}

/// Structured reply for MSG_WALK. Mirrors sendReply but with a typed body.
/// Callers fully initialize `body`; nothing is zeroed here (a memset after
/// field assignment would wipe the reply contents).
fn sendWalkReply(req_hdr: *const c.mach_msg_header_t, body: *WalkReply) void {
    body.hdr = .{
        .msgh_bits = c.MACH_MSG_TYPE_MOVE_SEND_ONCE,
        .msgh_size = @sizeOf(WalkReply),
        .msgh_remote_port = req_hdr.msgh_remote_port,
        .msgh_local_port = c.MACH_PORT_NULL,
        .msgh_voucher_port = 0,
        .msgh_id = MSG_WALK,
    };
    const sret = c.mach_msg(
        &body.hdr,
        c.MACH_SEND_MSG,
        @sizeOf(WalkReply),
        0,
        c.MACH_PORT_NULL,
        0,
        c.MACH_PORT_NULL,
    );
    if (sret != c.KERN_SUCCESS) {
        std.debug.print("[fx-companiond] walk reply send FAILED kr={x}\n", .{@as(u32, @bitCast(sret))});
    }
}

pub fn main() !void {
    const t_entry = c.nowNs();
    start_ns = t_entry;

    var server_port: c.mach_port_t = c.MACH_PORT_NULL;

    const kr = c.bootstrap_check_in(c.bootstrap_port, SERVICE_NAME, &server_port);
    if (kr != c.KERN_SUCCESS) {
        std.debug.print("[fx-companiond] bootstrap_check_in failed kr={x}\n", .{@as(u32, @bitCast(kr))});
        return error.BootstrapFailed;
    }
    init_us = (c.nowNs() - t_entry) / 1000;

    std.debug.print("[fx-companiond] serving '{s}' pid={d} euid={d} init={d}us\n", .{
        SERVICE_NAME, c.getpid(), c.geteuid(), init_us,
    });

    var buffer: [RECV_BUFFER_SIZE]u8 align(8) = undefined;
    while (true) {
        const hdr: *c.mach_msg_header_t = @ptrCast(&buffer);
        const rcv = c.mach_msg(
            hdr,
            c.rcvOptsAudit(),
            0,
            buffer.len,
            server_port,
            0,
            c.MACH_PORT_NULL,
        );
        if (rcv != c.KERN_SUCCESS) continue;
        handleConnection(hdr);
    }
}
