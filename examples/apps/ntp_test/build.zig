const std = @import("std");

/// Supported board types
pub const BoardType = enum {
    esp32s3_devkit,
    korvo2_v3,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection option
    const board = b.option(BoardType, "board", "Target board") orelse .esp32s3_devkit;

    // Get dependencies
    const hal_dep = b.dependency("hal", .{ .target = target, .optimize = optimize });
    const esp_dep = b.dependency("esp", .{ .target = target, .optimize = optimize });
    const ntp_dep = b.dependency("ntp", .{ .target = target, .optimize = optimize });

    // Build options
    const board_options = b.addOptions();
    board_options.addOption(BoardType, "board", board);

    // App module
    const app_module = b.addModule("app", .{
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    app_module.addImport("hal", hal_dep.module("hal"));
    app_module.addImport("esp", esp_dep.module("esp"));
    app_module.addImport("ntp", ntp_dep.module("ntp"));
    app_module.addOptions("build_options", board_options);
}
