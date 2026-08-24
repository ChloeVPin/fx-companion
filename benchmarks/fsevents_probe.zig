//! Measures synchronous FSEvents flush latency and verifies that a directory
//! mutation is visible before FSEventStreamFlushSync returns.
const std = @import("std");

const FSEventStream = opaque {};
const FSEventStreamRef = *FSEventStream;
const ConstFSEventStreamRef = *const FSEventStream;
const FSEventStreamEventFlags = u32;
const FSEventStreamEventId = u64;
const FSEventStreamCallback = *const fn (
    ConstFSEventStreamRef,
    ?*anyopaque,
    usize,
    ?*anyopaque,
    [*]const FSEventStreamEventFlags,
    [*]const FSEventStreamEventId,
) callconv(.c) void;
const FSEventStreamContext = extern struct {
    version: isize,
    info: ?*anyopaque,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
};

extern "c" var kCFTypeArrayCallBacks: u8;
extern "c" fn CFStringCreateWithFileSystemRepresentation(
    allocator: ?*const anyopaque,
    buffer: [*:0]const u8,
) ?*const anyopaque;
extern "c" fn CFArrayCreate(
    allocator: ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    count: isize,
    callbacks: *const anyopaque,
) ?*const anyopaque;
extern "c" fn CFRelease(value: *const anyopaque) void;
extern "c" fn FSEventStreamCreate(
    allocator: ?*const anyopaque,
    callback: FSEventStreamCallback,
    context: ?*FSEventStreamContext,
    paths: *const anyopaque,
    since_when: FSEventStreamEventId,
    latency: f64,
    flags: u32,
) ?FSEventStreamRef;
extern "c" fn FSEventStreamSetDispatchQueue(stream: FSEventStreamRef, queue: ?*anyopaque) void;
extern "c" fn FSEventStreamStart(stream: FSEventStreamRef) u8;
extern "c" fn FSEventStreamFlushSync(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamStop(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamRelease(stream: FSEventStreamRef) void;
extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) ?*anyopaque;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn usleep(microseconds: c_uint) c_int;

const event_id_since_now = std.math.maxInt(FSEventStreamEventId);
const create_flag_no_defer: u32 = 0x00000002;
const create_flag_watch_root: u32 = 0x00000004;
const create_flag_file_events: u32 = 0x00000010;
const dispatch_queue_priority_default: isize = 0;
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_EXCL: c_int = 0x0800;

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn eventCallback(
    _: ConstFSEventStreamRef,
    info: ?*anyopaque,
    _: usize,
    _: ?*anyopaque,
    _: [*]const FSEventStreamEventFlags,
    _: [*]const FSEventStreamEventId,
) callconv(.c) void {
    const dirty: *std.atomic.Value(bool) = @ptrCast(@alignCast(info.?));
    dirty.store(true, .release);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const rounds = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 7;

    const root_z = try std.heap.c_allocator.dupeZ(u8, root);
    defer std.heap.c_allocator.free(root_z);
    const root_cf = CFStringCreateWithFileSystemRepresentation(null, root_z.ptr) orelse
        return error.CreateStringFailed;
    defer CFRelease(root_cf);
    var values = [_]?*const anyopaque{root_cf};
    const paths = CFArrayCreate(null, &values, @intCast(values.len), &kCFTypeArrayCallBacks) orelse
        return error.CreateArrayFailed;
    defer CFRelease(paths);

    var dirty: std.atomic.Value(bool) = .init(false);
    var context: FSEventStreamContext = .{
        .version = 0,
        .info = &dirty,
        .retain = null,
        .release = null,
        .copy_description = null,
    };
    const stream = FSEventStreamCreate(
        null,
        eventCallback,
        &context,
        paths,
        event_id_since_now,
        0.0,
        create_flag_no_defer | create_flag_watch_root | create_flag_file_events,
    ) orelse return error.CreateStreamFailed;
    defer FSEventStreamRelease(stream);

    const queue = dispatch_get_global_queue(dispatch_queue_priority_default, 0);
    FSEventStreamSetDispatchQueue(stream, queue);
    defer FSEventStreamInvalidate(stream);
    if (FSEventStreamStart(stream) == 0) return error.StartStreamFailed;
    defer FSEventStreamStop(stream);

    FSEventStreamFlushSync(stream);
    dirty.store(false, .release);

    var samples: [31]u64 = undefined;
    if (rounds == 0 or rounds > samples.len) return error.InvalidRounds;
    for (0..rounds) |round| {
        const started = nowNs();
        FSEventStreamFlushSync(stream);
        samples[round] = nowNs() - started;
        if (dirty.swap(false, .acq_rel)) return error.UnexpectedEvent;
    }

    var mutation_path: [1024]u8 = undefined;
    const mutation_z = try std.fmt.bufPrintZ(&mutation_path, "{s}/.fxc-fsevents-probe", .{root});
    const fd = open(mutation_z.ptr, O_WRONLY | O_CREAT | O_EXCL, @as(c_uint, 0o600));
    if (fd < 0) return error.CreateMutationFailed;
    _ = close(fd);
    defer _ = unlink(mutation_z.ptr);

    const mutation_started = nowNs();
    var detected = false;
    var polls: usize = 0;
    while (polls < 500) : (polls += 1) {
        FSEventStreamFlushSync(stream);
        if (dirty.swap(false, .acq_rel)) {
            detected = true;
            break;
        }
        _ = usleep(1000);
    }
    const mutation_ns = nowNs() - mutation_started;
    if (!detected) return error.MissedMutation;

    std.mem.sort(u64, samples[0..rounds], {}, std.sort.asc(u64));
    std.debug.print("clean_flush median={d:.3}ms best={d:.3}ms rounds={d}\n", .{
        @as(f64, @floatFromInt(samples[rounds / 2])) / 1_000_000.0,
        @as(f64, @floatFromInt(samples[0])) / 1_000_000.0,
        rounds,
    });
    std.debug.print("mutation_detection={d:.3}ms polls={d} detected=true\n", .{
        @as(f64, @floatFromInt(mutation_ns)) / 1_000_000.0,
        polls + 1,
    });
}
