const std = @import("std");

/// Supported board types
pub const BoardType = enum {
    esp32s3_devkit,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection option (required by build system)
    _ = b.option(BoardType, "board", "Target board") orelse .esp32s3_devkit;

    // Get dependencies (required by generated build.zig.zon template)
    const esp_dep = b.dependency("esp", .{ .target = target, .optimize = optimize });
    const hal_dep = b.dependency("hal", .{ .target = target, .optimize = optimize });

    // Simple app module - no HAL dependencies needed for memory tests
    const app_module = b.addModule("app", .{
        .root_source_file = b.path("../app.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add imports (even if unused, keeps build system consistent)
    app_module.addImport("esp", esp_dep.module("esp"));
    app_module.addImport("hal", hal_dep.module("hal"));
}
