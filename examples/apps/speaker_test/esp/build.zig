const std = @import("std");

pub const BoardType = enum {
    korvo2_v3,
    lichuang_szp,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection
    const board = b.option(BoardType, "board", "Target board") orelse .korvo2_v3;

    // Get dependencies
    const esp_dep = b.dependency("esp", .{
        .target = target,
        .optimize = optimize,
    });

    const hal_dep = b.dependency("hal", .{
        .target = target,
        .optimize = optimize,
    });

    const drivers_dep = b.dependency("drivers", .{
        .target = target,
        .optimize = optimize,
    });

    // Build options for board selection
    const board_options = b.addOptions();
    board_options.addOption(BoardType, "board", board);

    // Create app module
    const app_module = b.addModule("app", .{
        .root_source_file = b.path("../app.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    app_module.addImport("esp", esp_dep.module("esp"));
    app_module.addImport("hal", hal_dep.module("hal"));
    app_module.addImport("drivers", drivers_dep.module("drivers"));
    app_module.addOptions("build_options", board_options);
}
