const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("sal", .{
        .root_source_file = b.path("src/sal.zig"),
        .target = target,
        .optimize = optimize,
    });
}
