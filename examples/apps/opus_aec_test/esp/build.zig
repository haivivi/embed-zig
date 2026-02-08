const std = @import("std");

/// Supported board types
pub const BoardType = enum {
    lichuang_gocool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const board = b.option(BoardType, "board", "Target board") orelse .lichuang_gocool;

    const esp_dep = b.dependency("esp", .{
        .target = target,
        .optimize = optimize,
    });

    const hal_dep = b.dependency("hal", .{
        .target = target,
        .optimize = optimize,
    });

    const audio_dep = b.dependency("audio", .{
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

    const drivers_dep = b.dependency("drivers", .{
        .target = target,
        .optimize = optimize,
    });

    const board_options = b.addOptions();
    board_options.addOption(BoardType, "board", board);

    const app_module = b.addModule("app", .{
        .root_source_file = b.path("../app.zig"),
        .target = target,
        .optimize = optimize,
    });

    app_module.addImport("esp", esp_dep.module("esp"));
    app_module.addImport("hal", hal_dep.module("hal"));
    app_module.addImport("audio", audio_dep.module("audio"));
    app_module.addImport("channel", channel_dep.module("channel"));
    app_module.addImport("waitgroup", waitgroup_dep.module("waitgroup"));
    app_module.addImport("cancellation", cancellation_dep.module("cancellation"));
    app_module.addImport("drivers", drivers_dep.module("drivers"));
    app_module.addOptions("build_options", board_options);
}
