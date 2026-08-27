//! Production-path engagement probe for fx-companion.
//!
//! Copied to `src/fx_companion_engagement.zig` in an injected fx tree.
//! Times workspace_files.discover with production defaults (git-primary)
//! versus force_fallback+sorted recursive walk. No model request.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");
const workspace_files = @import("core/workspace/workspace_files.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn hasGit(root: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const joined = std.fmt.bufPrintZ(&buf, "{s}/.git", .{root}) catch return false;
    return access(joined.ptr, 0) == 0;
}

const Sample = struct {
    ns: u64,
    source: workspace_files.Source,
    paths: usize,
    incomplete: bool,
    cache_hit: bool,
    companion_syscalls: u64,
    hash: u64,
};

fn pathHash(files: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (files) |path| {
        hasher.update(std.mem.asBytes(&path.len));
        hasher.update(path);
    }
    return hasher.final();
}

fn sampleDiscover(root: []const u8, options: workspace_files.Options) !Sample {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    workspace_files.companion_enabled = true;
    const started = nowNs();
    const result = try workspace_files.discover(arena.allocator(), root, options);
    const elapsed = nowNs() - started;
    const obs = companion.lastCacheObservation();
    const walk = companion.lastWalkObservation();
    return .{
        .ns = elapsed,
        .source = result.source,
        .paths = result.files.len,
        .incomplete = result.incomplete,
        .cache_hit = obs.hit,
        .companion_syscalls = walk.getdirentries_calls,
        .hash = pathHash(result.files),
    };
}

fn companionLabel(sample: Sample, sorted: bool, fallback: bool, cap: usize) []const u8 {
    if (comptime @import("builtin").os.tag != .macos or @import("builtin").cpu.arch != .aarch64)
        return "skipped:platform";
    const off = std.c.getenv("FX_NO_COMPANION");
    if (off != null and off.?[0] != 0) return "skipped:kill-switch";
    if (cap == 0) return "skipped:cap=0";
    if (sample.source == .git and !fallback) {
        if (sample.cache_hit) return "hit";
        return "miss";
    }
    if (!sorted) return "skipped:unsorted";
    if (sample.cache_hit) return "hit";
    if (sample.companion_syscalls == 0 and sample.source == .recursive)
        return "miss";
    if (sample.source == .recursive) return "miss";
    return "skipped:unknown";
}

fn printSample(label: []const u8, sample: Sample, sorted: bool, fallback: bool, cap: usize) void {
    std.debug.print(
        "  {s: <28} source={s: <9} companion={s: <22} paths={d} incomplete={} ns={d} ms={d:.3}\n",
        .{
            label,
            @tagName(sample.source),
            companionLabel(sample, sorted, fallback, cap),
            sample.paths,
            sample.incomplete,
            sample.ns,
            ms(sample.ns),
        },
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;

    std.debug.print("engagement probe\n", .{});
    std.debug.print("tree={s}\n", .{root});
    std.debug.print("git_dir={s}\n", .{if (hasGit(root)) "yes" else "no"});
    std.debug.print("companion_active={}\n", .{companion.active()});
    std.debug.print("no_model_request=true\n", .{});

    const cap = workspace_files.default_candidate_cap;

    // Production defaults: git-primary, unsorted.
    companion.clearSnapshotCache();
    const prod1 = try sampleDiscover(root, .{});
    printSample("prod/default-1", prod1, false, false, cap);
    const prod2 = try sampleDiscover(root, .{});
    printSample("prod/default-2", prod2, false, false, cap);

    // Production but sorted (glob/file-index style) still git-primary unless fallback.
    companion.clearSnapshotCache();
    const sorted_git1 = try sampleDiscover(root, .{ .sort_paths = true });
    printSample("prod/sorted-1", sorted_git1, true, false, cap);
    const sorted_git2 = try sampleDiscover(root, .{ .sort_paths = true });
    printSample("prod/sorted-2", sorted_git2, true, false, cap);

    // Recursive fallback — the path our benches measure.
    companion.clearSnapshotCache();
    const rec1 = try sampleDiscover(root, .{ .force_fallback = true, .sort_paths = true });
    printSample("fallback/sorted-cold", rec1, true, true, cap);
    const rec2 = try sampleDiscover(root, .{ .force_fallback = true, .sort_paths = true });
    printSample("fallback/sorted-warm", rec2, true, true, cap);
    if (rec1.hash != rec2.hash or rec1.paths != rec2.paths) return error.FallbackHashMismatch;

    companion.clearSnapshotCache();
    const unsorted_fb = try sampleDiscover(root, .{ .force_fallback = true, .sort_paths = false });
    printSample("fallback/unsorted", unsorted_fb, false, true, cap);

    if (prod1.source == .git) {
        if (prod1.hash != prod2.hash or prod1.paths != prod2.paths) return error.GitListHashMismatch;
        std.debug.print("git_list_equivalence=PASS paths={d} hash_match=true\n", .{prod1.paths});
        std.debug.print("git_list_speedup={d:.1}x cold_ms={d:.3} warm_ms={d:.3}\n", .{
            ms(prod1.ns) / ms(@max(prod2.ns, 1)),
            ms(prod1.ns),
            ms(prod2.ns),
        });
    }

    std.debug.print("ENGAGEMENT_OK\n", .{});
}
