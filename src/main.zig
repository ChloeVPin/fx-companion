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

const SERVICE_NAME = "dev.fx.companion";
const MSG_PING: u32 = 1;
const MSG_STAT: u32 = 2;

const RECV_BUFFER_SIZE = 4096;

var start_ns: u64 = 0;
var requests: u64 = 0;

const Reply = extern struct {
    hdr: c.mach_msg_header_t,
    payload: [96]u8 align(8),
};

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
            const s = std.fmt.bufPrint(&buf, "{{\"uptime_s\":{d},\"requests\":{d}}}", .{
                (c.nowNs() - start_ns) / 1_000_000_000,
                requests,
            }) catch "{\"error\":\"fmt\"}";
            sendReply(hdr.msgh_remote_port, MSG_STAT, s);
        },
        else => {},
    }
    std.debug.print("[fx-companiond] served pid={d} version={d}\n", .{ peer.pid, peer.pidversion });
}

pub fn main() !void {
    start_ns = c.nowNs();

    var server_port: c.mach_port_t = c.MACH_PORT_NULL;

    const kr = c.bootstrap_check_in(c.bootstrap_port, SERVICE_NAME, &server_port);
    if (kr != c.KERN_SUCCESS) {
        std.debug.print("[fx-companiond] bootstrap_check_in failed kr={x}\n", .{@as(u32, @bitCast(kr))});
        return error.BootstrapFailed;
    }

    std.debug.print("[fx-companiond] serving '{s}' pid={d} euid={d}\n", .{
        SERVICE_NAME, c.getpid(), c.geteuid(),
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
