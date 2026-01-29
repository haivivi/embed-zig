const std = @import("std");
const esp = @import("esp");

pub const BoardType = @import("app").BoardType;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Board selection option
    const board = b.option(BoardType, "board", "Target board") orelse .esp32s3_devkit;

    // Get app dependency (passes board option through)
    const app_dep = b.dependency("app", .{
        .target = target,
        .optimize = optimize,
        .board = board,
    });

    // Get esp dependency
    const esp_dep = b.dependency("esp", .{
        .target = target,
        .optimize = optimize,
    });

    // Root module (entry point)
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("esp", esp_dep.module("esp"));
    root_module.addImport("app", app_dep.module("app"));

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
