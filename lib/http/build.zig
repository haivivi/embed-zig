const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the http module
    _ = b.addModule("http", .{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Note: sal dependency is injected by the consumer
    // because sal needs platform-specific socket implementation
}
