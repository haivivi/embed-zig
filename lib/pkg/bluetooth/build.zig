const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const channel_dep = b.dependency("channel", .{
        .target = target,
        .optimize = optimize,
    });
    const waitgroup_dep = b.dependency("waitgroup", .{
        .target = target,
        .optimize = optimize,
    });
    const cancellation_dep = b.dependency("cancellation", .{
        .target = target,
        .optimize = optimize,
    });
    const std_impl_dep = b.dependency("std_impl", .{
        .target = target,
        .optimize = optimize,
    });

    // Module
    const bluetooth_mod = b.addModule("bluetooth", .{
        .root_source_file = b.path("src/bluetooth.zig"),
        .target = target,
        .optimize = optimize,
    });
    bluetooth_mod.addImport("trait", trait_dep.module("trait"));
    bluetooth_mod.addImport("channel", channel_dep.module("channel"));
    bluetooth_mod.addImport("waitgroup", waitgroup_dep.module("waitgroup"));
    bluetooth_mod.addImport("cancellation", cancellation_dep.module("cancellation"));

    // Unit tests (also needs runtime for test Rt)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bluetooth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    tests.root_module.addImport("channel", channel_dep.module("channel"));
    tests.root_module.addImport("waitgroup", waitgroup_dep.module("waitgroup"));
    tests.root_module.addImport("cancellation", cancellation_dep.module("cancellation"));
    tests.root_module.addImport("runtime", b.createModule(.{
        .root_source_file = std_impl_dep.path("src/impl/runtime.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
