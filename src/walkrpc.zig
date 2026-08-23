// walkrpc: ask fx-companiond to walk a directory tree (MSG_WALK).
//
// The daemon does the traversal with its getattrlistbulk walker; this client
// only ships the root path and prints the structured counts reply. A local
// in-process walk of the same tree is also run via walklib so the RPC's
// counts can be cross-checked against the verified walker.

const std = @import("std");
const c = @import("machc.zig");
const walklib = @import("walklib");

const SERVICE_NAME = "dev.fx.companion";
const MSG_WALK: u32 = 3;

const Request = extern struct {
    hdr: c.mach_msg_header_t,
    root: [512]u8,
};

const Reply = extern struct {
    hdr: c.mach_msg_header_t,
    status: u32,
    _pad: u32,
    entries: u64,
    bytes_sum: u64,
    elapsed_ns: u64,
    // Room for the kernel-appended audit trailer (52 bytes).
    trailer_pad: [128]u8 = [_]u8{0} ** 128,
};

fn printUsage() void {
    std.debug.print("usage: walkrpc <root-path>\n", .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv[0]
    const root_arg = args.next() orelse {
        printUsage();
        return error.MissingRoot;
    };
    if (args.next() != null) {
        printUsage();
        return error.TooManyArgs;
    }

    var port: c.mach_port_t = c.MACH_PORT_NULL;
    const looked = c.bootstrap_look_up(c.bootstrap_port, SERVICE_NAME, &port);
    if (looked != c.KERN_SUCCESS) {
        std.debug.print("daemon '{s}' not reachable. Load the LaunchAgent first:\n", .{SERVICE_NAME});
        return error.NoDaemon;
    }

    var req = Request{
        .hdr = undefined,
        .root = [_]u8{0} ** 512,
    };
    if (root_arg.len >= req.root.len) return error.PathTooLong;
    @memcpy(req.root[0..root_arg.len], root_arg);
    req.hdr = .{
        .msgh_bits = c.MACH_MSG_TYPE_COPY_SEND | (@as(u32, c.MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8),
        .msgh_size = @sizeOf(Request),
        .msgh_remote_port = port,
        // Reply port is allocated below and inserted into the header slot.
        .msgh_local_port = c.MACH_PORT_NULL,
        .msgh_voucher_port = 0,
        .msgh_id = @bitCast(MSG_WALK),
    };

    var reply_port: c.mach_port_t = c.MACH_PORT_NULL;
    const alloc_kr = machPortAllocate(&reply_port);
    if (alloc_kr != c.KERN_SUCCESS) return error.PortAllocFailed;
    defer _ = c.mach_port_deallocate(c.mach_task_self(), reply_port);
    req.hdr.msgh_local_port = reply_port;

    var reply: Reply = undefined;
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
    if (sent != c.KERN_SUCCESS) {
        std.debug.print("send failed kr={x}\n", .{@as(u32, @bitCast(sent))});
        return error.SendFailed;
    }
    const got = c.mach_msg(
        &reply.hdr,
        c.MACH_RCV_MSG | c.MACH_RCV_TIMEOUT,
        0,
        @sizeOf(Reply),
        reply_port,
        60_000, // walks can take a while on big trees
        c.MACH_PORT_NULL,
    );
    const roundtrip_ns = c.nowNs() - t0;
    if (got != c.KERN_SUCCESS) {
        std.debug.print("receive failed kr={x} (0x10000004=RcvTimedOut)\n", .{@as(u32, @bitCast(got))});
        return error.ReceiveFailed;
    }
    if (reply.hdr.msgh_id != @as(c_int, @intCast(MSG_WALK))) return error.BadReply;

    switch (reply.status) {
        0 => {
            std.debug.print("daemon walk ok   : {d} entries, {d} bytes\n", .{ reply.entries, reply.bytes_sum });
            std.debug.print("daemon walk time : {d:.1} ms\n", .{@as(f64, @floatFromInt(reply.elapsed_ns)) / 1e6});
            std.debug.print("rpc round trip   : {d:.1} ms\n", .{@as(f64, @floatFromInt(roundtrip_ns)) / 1e6});

            // Cross-check against the same walker run locally.
            const local = try walklib.walkAttrs(root_arg);
            std.debug.print("local walker     : {d} entries, {d} bytes ({s})\n", .{
                local.entries, local.bytes_sum,
                if (local.entries == reply.entries and local.bytes_sum == reply.bytes_sum) "MATCH" else "MISMATCH",
            });
        },
        1 => return error.PathTooLong,
        2 => return error.Oom,
        4 => {
            std.debug.print("daemon walk TRUNCATED (dir table cap): {d} entries, {d} bytes (lower bounds)\n", .{ reply.entries, reply.bytes_sum });
            std.debug.print("daemon walk time : {d:.1} ms\n", .{@as(f64, @floatFromInt(reply.elapsed_ns)) / 1e6});
        },
        5 => return error.DaemonBusy,
        else => return error.WalkFailed,
    }
}

// Local shim so we do not depend on a header detail for port allocation.
extern "c" fn mach_port_allocate(task: c.mach_port_t, right: c_int, name: *c.mach_port_t) c.kern_return_t;

fn machPortAllocate(out: *c.mach_port_t) c.kern_return_t {
    const MACH_PORT_RIGHT_RECEIVE: c_int = 1;
    return mach_port_allocate(c.mach_task_self(), MACH_PORT_RIGHT_RECEIVE, out);
}
