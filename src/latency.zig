// latency: measure round-trip time to fx-companiond via MSG_PING.

const std = @import("std");
const c = @import("machc.zig");

const SERVICE_NAME = "dev.fx.companion";
const MSG_PING: u32 = 1;
const MSG_STAT: u32 = 2;
const SAMPLES = 101;

const Request = extern struct {
    hdr: c.mach_msg_header_t,
};

const Reply = extern struct {
    hdr: c.mach_msg_header_t,
    payload: [96]u8 align(8),
    // Room for the kernel-appended trailer (audit trailer is 52 bytes).
    trailer_pad: [128]u8 = [_]u8{0} ** 128,
};

/// One synchronous request/reply. Returns elapsed ns; fills payload with the
/// daemon's reply text (NUL-padded) when non-null.
fn roundTrip(port: c.mach_port_t, msg_id: u32, payload_out: ?*[96]u8) !u64 {
    var reply_port: c.mach_port_t = c.MACH_PORT_NULL;
    // Allocate a receive right; the send side grants it back as send-once.
    const alloc_kr = machPortAllocate(&reply_port);
    if (alloc_kr != c.KERN_SUCCESS) return error.PortAllocFailed;
    defer _ = c.mach_port_deallocate(c.mach_task_self(), reply_port);

    var req: Request = undefined;
    req.hdr = .{
        .msgh_bits = c.MACH_MSG_TYPE_COPY_SEND | (@as(u32, c.MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8),
        .msgh_size = @sizeOf(Request),
        .msgh_remote_port = port,
        .msgh_local_port = reply_port,
        .msgh_voucher_port = 0,
        .msgh_id = @bitCast(msg_id),
    };

    const t0 = c.nowNs();
    const sent = c.mach_msg(
        &req.hdr,
        c.MACH_SEND_MSG,
        @sizeOf(Request),
        0,
        c.MACH_PORT_NULL,
        0,
        c.MACH_PORT_NULL,
    );
    if (sent != c.KERN_SUCCESS) return error.SendFailed;

    var reply: Reply = undefined;
    const got = c.mach_msg(
        &reply.hdr,
        c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT,
        0,
        @sizeOf(Reply),
        reply_port,
        5_000, // milliseconds
        c.MACH_PORT_NULL,
    );
    const elapsed = c.nowNs() - t0;
    if (got != c.KERN_SUCCESS) {
        std.debug.print("receive failed kr={x} (0x1004000c=RcvTooLarge, 0x10000004=RcvTimedOut)\n", .{@as(u32, @bitCast(got))});
        return error.ReceiveFailed;
    }
    // msgh_size covers body only; trailer is appended beyond it.
    if (reply.hdr.msgh_id != @as(c_int, @intCast(msg_id))) return error.BadReply;
    if (payload_out) |out| {
        @memset(out, 0);
        const n = @min(out.len, reply.payload.len);
        @memcpy(out[0..n], reply.payload[0..n]);
    }
    return elapsed;
}

fn pingOnce(port: c.mach_port_t) !u64 {
    var payload: [96]u8 = undefined;
    const elapsed = try roundTrip(port, MSG_PING, &payload);
    if (!std.mem.eql(u8, payload[0..4], "pong")) return error.BadReply;
    return elapsed;
}

// Local shim so we do not depend on a header detail for port allocation.
extern "c" fn mach_port_allocate(task: c.mach_port_t, right: c_int, name: *c.mach_port_t) c.kern_return_t;

fn machPortAllocate(out: *c.mach_port_t) c.kern_return_t {
    const MACH_PORT_RIGHT_RECEIVE: c_int = 1;
    return mach_port_allocate(c.mach_task_self(), MACH_PORT_RIGHT_RECEIVE, out);
}

pub fn main() !void {
    var port: c.mach_port_t = c.MACH_PORT_NULL;
    const t0 = c.nowNs();
    const looked = c.bootstrap_look_up(c.bootstrap_port, SERVICE_NAME, &port);
    const lookup_ns = c.nowNs() - t0;
    if (looked != c.KERN_SUCCESS) {
        std.debug.print("daemon '{s}' not reachable. Start it first:\n", .{SERVICE_NAME});
        std.debug.print("  cp com.chloevpin.fx-companiond.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.chloevpin.fx-companiond.plist\n", .{});
        return error.NoDaemon;
    }
    std.debug.print("bootstrap lookup : {d:>8.1} us\n", .{@as(f64, @floatFromInt(lookup_ns)) / 1000.0});

    const first = try pingOnce(port);
    std.debug.print("first round trip : {d:>8.1} us   (may include lazy daemon spawn)\n", .{
        @as(f64, @floatFromInt(first)) / 1000.0,
    });

    var samples: [SAMPLES]u64 = undefined;
    for (&samples) |*s| s.* = try pingOnce(port);
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const p50 = samples[SAMPLES / 2];
    const p99 = samples[(SAMPLES * 99) / 100];
    std.debug.print("round trip p50   : {d:>8.1} us\n", .{@as(f64, @floatFromInt(p50)) / 1000.0});
    std.debug.print("round trip p99   : {d:>8.1} us   (n={d})\n", .{
        @as(f64, @floatFromInt(p99)) / 1000.0, SAMPLES,
    });

    // Daemon self-reported init time closes the <5 ms cold-start budget.
    var payload: [96]u8 = undefined;
    const stat_ns = try roundTrip(port, MSG_STAT, &payload);
    std.debug.print("daemon stat      : {s}   ({d:.1} us)\n", .{
        std.mem.sliceTo(&payload, 0),
        @as(f64, @floatFromInt(stat_ns)) / 1000.0,
    });
}
