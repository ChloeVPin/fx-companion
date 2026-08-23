const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared traversal library: getattrlistbulk walker, used by both the
    // daemon (walk RPC) and the benchmark. Needs libc for open/close.
    const walklib_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/bulk_walk.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // fx-companiond daemon
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    daemon_mod.addImport("walklib", walklib_mod);
    const daemon = b.addExecutable(.{
        .name = "fx-companiond",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon);

    // latency client
    const latency_mod = b.createModule(.{
        .root_source_file = b.path("src/latency.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const latency = b.addExecutable(.{
        .name = "latency",
        .root_module = latency_mod,
    });
    b.installArtifact(latency);

    // walkrpc client: ask the daemon to walk a directory tree.
    const walkrpc_mod = b.createModule(.{
        .root_source_file = b.path("src/walkrpc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    walkrpc_mod.addImport("walklib", walklib_mod);
    const walkrpc = b.addExecutable(.{
        .name = "walkrpc",
        .root_module = walkrpc_mod,
    });
    b.installArtifact(walkrpc);

    // traversal benchmark (Zig + one C source for the fts wrapper)
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/traversal_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addCSourceFile(.{
        .file = b.path("benchmarks/fts_walk.c"),
        .flags = &.{ "-O2", "-Wall" },
    });
    const bench = b.addExecutable(.{
        .name = "traversal_bench",
        .root_module = bench_mod,
    });

    const install_bench = b.addInstallArtifact(bench, .{});
    b.getInstallStep().dependOn(&install_bench.step);

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the traversal shootout");
    bench_step.dependOn(&run_bench.step);

    // fx gate bench: fx-replica walk vs daemon walk on the same tree.
    const gate_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/fx_gate_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gate_mod.addCSourceFile(.{
        .file = b.path("benchmarks/fts_walk.c"),
        .flags = &.{ "-O2", "-Wall" },
    });
    const gate = b.addExecutable(.{
        .name = "fx_gate_bench",
        .root_module = gate_mod,
    });
    const install_gate = b.addInstallArtifact(gate, .{});
    b.getInstallStep().dependOn(&install_gate.step);

    const unit_tests = b.addTest(.{ .root_module = daemon_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
