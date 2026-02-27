const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("speexdsp", .{
        .root_source_file = b.path("speexdsp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add include paths for SpeexDSP C headers.
    // In Bazel builds these come from the downloaded @speexdsp repository.
    // For zig build, provide include paths via speexdsp_src lazy dependency or symlink.
    if (b.lazyDependency("speexdsp_src", .{})) |dep| {
        mod.addIncludePath(dep.path("include"));
    }
    mod.addIncludePath(b.path(".")); // config.h
    mod.link_libc = true;
}
