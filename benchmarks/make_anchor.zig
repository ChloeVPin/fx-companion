//! Builds the deterministic directory tree used by product benchmarks.
//! Refuses an existing root; benchmark data is never overwritten.
const std = @import("std");

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_EXCL: c_int = 0x0800;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const directory_count = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 4096;
    const files_per_directory = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 100;
    if (root.len == 0 or root.len > 800) return error.InvalidRoot;

    var path_buf: [1024]u8 = undefined;
    const root_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{root});
    if (mkdir(root_z.ptr, 0o755) != 0) return error.RootAlreadyExistsOrUnavailable;

    for (0..directory_count) |directory| {
        const directory_z = try std.fmt.bufPrintZ(&path_buf, "{s}/d{d:0>4}", .{ root, directory });
        if (mkdir(directory_z.ptr, 0o755) != 0) return error.CreateDirectoryFailed;
        for (0..files_per_directory) |file| {
            const file_z = try std.fmt.bufPrintZ(&path_buf, "{s}/d{d:0>4}/f{d:0>3}", .{ root, directory, file });
            const fd = open(file_z.ptr, O_WRONLY | O_CREAT | O_EXCL, 0o644);
            if (fd < 0) return error.CreateFileFailed;
            _ = close(fd);
        }
    }
    std.debug.print("created root={s} directories={d} files={d}\n", .{
        root,
        directory_count,
        directory_count * files_per_directory,
    });
}
