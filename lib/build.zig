const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main documentation module that re-exports both libraries
    _ = b.addModule("embed-zig", .{
        .root_source_file = b.path("docs.zig"),
        .target = target,
        .optimize = optimize,
    });
}
