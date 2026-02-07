const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const idf_dep = b.dependency("idf", .{
        .target = target,
        .optimize = optimize,
    });
    const trait_dep = b.dependency("trait", .{
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

    // Create the impl module
    _ = b.addModule("impl", .{
        .root_source_file = b.path("src/impl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "idf", .module = idf_dep.module("idf") },
            .{ .name = "trait", .module = trait_dep.module("trait") },
            .{ .name = "hal", .module = hal_dep.module("hal") },
            .{ .name = "drivers", .module = drivers_dep.module("drivers") },
        },
    });
}
