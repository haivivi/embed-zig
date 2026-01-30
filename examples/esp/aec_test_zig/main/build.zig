const std = @import("std");

pub fn build(b: *std.Build) void {
    // Get target and optimize from command line
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("aec_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Get include directories from environment (set by CMake)
    const include_dirs_str = std.process.getEnvVarOwned(b.allocator, "INCLUDE_DIRS") catch "";
    defer if (include_dirs_str.len > 0) b.allocator.free(include_dirs_str);

    // Add include directories (semicolon-separated)
    var iter = std.mem.tokenizeAny(u8, include_dirs_str, ";");
    while (iter.next()) |dir| {
        root_module.addSystemIncludePath(.{ .cwd_relative = dir });
    }

    // Create static library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "main_zig",
        .root_module = root_module,
    });

    // Install
    b.installArtifact(lib);
}
