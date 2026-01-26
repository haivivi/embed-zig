const std = @import("std");

const esp = @import("esp");

pub const BoardType = enum {
    esp32s3_devkit,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection
    const board = b.option(BoardType, "board", "Target board") orelse .esp32s3_devkit;

    const esp_dep = b.dependency("esp", .{
        .target = target,
        .optimize = optimize,
    });

    const hal_dep = b.dependency("hal", .{
        .target = target,
        .optimize = optimize,
    });

    // Build options for board selection
    const board_options = b.addOptions();
    board_options.addOption(BoardType, "board", board);

    // Apps module (platform-independent application code)
    const apps_module = b.createModule(.{
        .root_source_file = b.path("../../../../apps/nvs_storage/app.zig"),
    });

    // Platform module (board selection and HAL spec)
    const platform_module = b.createModule(.{
        .root_source_file = b.path("../../../../apps/nvs_storage/platform.zig"),
    });
    platform_module.addOptions("build_options", board_options);
    platform_module.addImport("hal", hal_dep.module("hal"));
    platform_module.addImport("esp", esp_dep.module("esp"));

    // Apps needs platform and hal
    apps_module.addImport("platform", platform_module);
    apps_module.addImport("hal", hal_dep.module("hal"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    root_module.addImport("esp", esp_dep.module("esp"));
    root_module.addImport("app", apps_module);

    const lib = b.addLibrary(.{
        .name = "main_zig",
        .linkage = .static,
        .root_module = root_module,
    });

    esp.addEspDeps(b, root_module) catch {
        @panic("Failed to add ESP dependencies");
    };

    root_module.addIncludePath(b.path("include"));
    b.installArtifact(lib);
}
