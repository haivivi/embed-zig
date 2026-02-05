const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Darwin layer - C bindings for system calls (currently empty)
    _ = b.addModule("darwin", .{
        .root_source_file = b.path("src/darwin.zig"),
        .target = target,
        .optimize = optimize,
    });
}
