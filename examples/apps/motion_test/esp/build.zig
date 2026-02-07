const std = @import("std");

/// Supported board types
pub const BoardType = enum {
    lichuang_szp,
    lichuang_gocool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection option
    const board = b.option(BoardType, "board", "Target board") orelse .lichuang_szp;

    // Get dependencies
    const hal_dep = b.dependency("hal", .{ .target = target, .optimize = optimize });
    const esp_dep = b.dependency("esp", .{ .target = target, .optimize = optimize });
    const drivers_dep = b.dependency("drivers", .{ .target = target, .optimize = optimize });
    const motion_dep = b.dependency("motion", .{ .target = target, .optimize = optimize });

    // Board selection as build option
    const board_options = b.addOptions();
    board_options.addOption(BoardType, "board", board);

    // App module
    const app_module = b.addModule("app", .{
        .root_source_file = b.path("../app.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Dependencies
    app_module.addImport("hal", hal_dep.module("hal"));
    app_module.addImport("esp", esp_dep.module("esp"));
    app_module.addImport("drivers", drivers_dep.module("drivers"));
    app_module.addImport("motion", motion_dep.module("motion"));
    app_module.addOptions("build_options", board_options);
}
