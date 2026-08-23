//! getattrlistbulk(2) and related attribute syscalls. Hand-written externs.
//! Constants cross-checked against dumac (healeycodes) and sys/attr.h.

pub const kern_return_t = c_int;

pub const ATTR_BIT_MAP_COUNT: c_uint = 5;

pub const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
pub const ATTR_CMN_NAME: u32 = 0x00000001;
pub const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
pub const ATTR_CMN_ERROR: u32 = 0x20000000;
pub const ATTR_CMN_FILEID: u32 = 0x02000000;
pub const ATTR_FILE_ALLOCSIZE: u32 = 0x00000004;
pub const ATTR_FILE_DATALENGTH: u32 = 0x00000020;

pub const vtype_t = u32;
pub const VNON: vtype_t = 0;
pub const VREG: vtype_t = 1;
pub const VDIR: vtype_t = 2;

pub const attrlist = extern struct {
    bitmapcount: c_uint,
    reserved: c_uint,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
};

pub extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn getattrlistbulk(
    fd: c_int,
    alist: *const attrlist,
    attributeBuffer: *anyopaque,
    bufferSize: usize,
    options: u32,
) c_int;

pub const O_RDONLY: c_int = 0;
