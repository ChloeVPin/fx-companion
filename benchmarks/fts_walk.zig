//! fts-based traversal via the C helper (fts_walk.c).
//! Historically fastest name-only walk on APFS per tempel.org (2019);
//! re-measured here on current macOS.

const std = @import("std");

pub const WalkOut = struct {
    entries: u64,
    bytes_sum: u64,
};

extern "c" fn fts_walk(
    root: [*:0]const u8,
    sum_sizes: c_int,
    entries: *u64,
    bytes: *u64,
) c_int;

pub fn walkNames(root: []const u8) !WalkOut {
    return walkCommon(root, false);
}

/// Attribute-heavy: sums sizes from the stat buffer fts already fetched
/// internally, so no extra lstat per file is paid here.
pub fn walkAttrs(root: []const u8) !WalkOut {
    return walkCommon(root, true);
}

fn walkCommon(root: []const u8, sum_sizes: bool) !WalkOut {
    var pathbuf: [512]u8 = undefined;
    if (root.len >= pathbuf.len - 1) return error.PathTooLong;
    @memcpy(pathbuf[0..root.len], root);
    pathbuf[root.len] = 0;

    var entries: u64 = 0;
    var bytes: u64 = 0;
    const rc = fts_walk(@ptrCast(&pathbuf), if (sum_sizes) 1 else 0, &entries, &bytes);
    if (rc != 0) return error.FtsOpenFailed;
    return .{ .entries = entries, .bytes_sum = bytes };
}
