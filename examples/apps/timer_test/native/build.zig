const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{ .target = target, .optimize = optimize });
    const hal_dep = b.dependency("hal", .{ .target = target, .optimize = optimize });
    const std_impl_dep = b.dependency("std_impl", .{ .target = target, .optimize = optimize });
    const timer_dep = b.dependency("timer", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "timer_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("trait", trait_dep.module("trait"));
    exe.root_module.addImport("hal", hal_dep.module("hal"));
    exe.root_module.addImport("timer", timer_dep.module("timer"));
    // Import runtime directly (avoids opus dependency via full std_impl)
    exe.root_module.addImport("runtime", b.createModule(.{
        .root_source_file = std_impl_dep.path("src/impl/runtime.zig"),
        .target = target,
        .optimize = optimize,
    }));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the timer test");
    run_step.dependOn(&run_cmd.step);
}
