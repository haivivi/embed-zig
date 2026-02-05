const std = @import("std");

/// Supported board types
pub const BoardType = enum {
    esp32s3_devkit,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection option
    const board = b.option(BoardType, "board", "Target board") orelse .esp32s3_devkit;

    // Get dependencies
    const hal_dep = b.dependency("hal", .{ .target = target, .optimize = optimize });
    const esp_dep = b.dependency("esp", .{ .target = target, .optimize = optimize });
    const trait_dep = b.dependency("trait", .{ .target = target, .optimize = optimize });
    const tls_dep = b.dependency("tls", .{ .target = target, .optimize = optimize });

    // Build options
    const board_options = b.addOptions();
    board_options.addOption(BoardType, "board", board);

    // App module
    const app_module = b.addModule("app", .{
        .root_source_file = b.path("../app.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    app_module.addImport("hal", hal_dep.module("hal"));
    app_module.addImport("esp", esp_dep.module("esp"));
    app_module.addImport("trait", trait_dep.module("trait"));
    app_module.addImport("tls", tls_dep.module("tls"));
    app_module.addOptions("build_options", board_options);
}
