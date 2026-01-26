const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // HAL module
    const hal_module = b.addModule("hal", .{
        .root_source_file = b.path("src/hal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run HAL unit tests");

    // Test all modules
    const test_files = [_][]const u8{
        "src/hal.zig",
        "src/event.zig",
        "src/button.zig",
        "src/board.zig",
    };

    for (test_files) |file| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    _ = hal_module;
}
