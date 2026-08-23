//! Thin extern declarations for the subset of libsystem APIs used here.
//! Hand-written and minimal on purpose; Zig does not ship these headers.

pub const kern_return_t = c_int;
pub const mach_port_t = u32;
pub const integer_t = c_int;
pub const natural_t = c_uint;

pub const MACH_PORT_NULL: mach_port_t = 0;
pub const KERN_SUCCESS: kern_return_t = 0;

// Message bit fields
pub const MACH_MSG_TYPE_COPY_SEND: u32 = 19;
pub const MACH_MSG_TYPE_MOVE_SEND_ONCE: u32 = 18;
pub const MACH_MSG_TYPE_MAKE_SEND_ONCE: u32 = 21;

pub const MACH_SEND_MSG: u32 = 0x00000001;
pub const MACH_RCV_MSG: u32 = 0x00000002;
pub const MACH_RCV_TIMEOUT: u32 = 0x00000100;

/// Receive-option bits 24..27 select which trailer elements the kernel appends
/// (mach/message.h: MACH_RCV_TRAILER_ELEMENTS(x) = ((x)&0xf)<<24).
/// Value 3 = audit trailer (security token + audit_token_t).
pub const MACH_RCV_TRAILER_AUDIT: u32 = 3;
const MACH_RCV_TRAILER_ELEMENTS_SHIFT: u5 = 24;

/// Format 0 is the only trailer format in use.
pub const MACH_MSG_TRAILER_FORMAT_0: u32 = 0;

/// Compose the receive option word for audit-trailer delivery.
pub fn rcvOptsAudit() u32 {
    return MACH_RCV_MSG | (MACH_RCV_TRAILER_AUDIT << MACH_RCV_TRAILER_ELEMENTS_SHIFT);
}

pub const mach_msg_header_t = extern struct {
    msgh_bits: natural_t,
    msgh_size: natural_t,
    msgh_remote_port: mach_port_t,
    msgh_local_port: mach_port_t,
    msgh_voucher_port: natural_t,
    msgh_id: integer_t,
};

pub const security_token_flat_t = extern struct {
    val: [2]natural_t, // [0]=euid [1]=egid
};

pub const audit_token_t = extern struct {
    // auid euid egid ruid rgid pid asid pidversion
    val: [8]natural_t,
};

/// Kernel-stamped trailer received when audit elements are requested.
/// Layout per mach/message.h (static assert size == 52):
/// type(4) size(4) seqno(4) sender(8) audit(32).
pub const mach_msg_audit_trailer_t = extern struct {
    msgh_trailer_type: u32,
    msgh_trailer_size: u32,
    msgh_seqno: natural_t,
    msgh_sender: security_token_flat_t,
    msgh_audit: audit_token_t,
};

pub extern "c" fn mach_msg(
    msg: *anyopaque,
    option: u32,
    send_size: usize,
    rcv_size: usize,
    rcv_name: mach_port_t,
    timeout_ms: u32,
    notify: mach_port_t,
) kern_return_t;

pub extern "c" fn bootstrap_check_in(
    bp: mach_port_t,
    service: [*:0]const u8,
    sp: *mach_port_t,
) kern_return_t;

pub extern "c" fn bootstrap_look_up(
    bp: mach_port_t,
    service: [*:0]const u8,
    sp: *mach_port_t,
) kern_return_t;

pub extern "c" fn mach_port_deallocate(task: mach_port_t, name: mach_port_t) kern_return_t;
pub extern "c" fn mach_task_self() mach_port_t;

/// libsystem global set up before main(); the handle bootstrap_* calls want.
pub extern "c" var bootstrap_port: mach_port_t;

// Identity + clocks via libc (stable across Zig std churn).
pub extern "c" fn getpid() c_int;
pub extern "c" fn geteuid() c_int;

pub const Timespec = extern struct { sec: isize, nsec: isize };
/// Darwin: CLOCK_MONOTONIC_RAW == 4
pub const CLOCK_MONOTONIC_RAW: c_int = 4;
extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

pub fn nowNs() u64 {
    var ts: Timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
