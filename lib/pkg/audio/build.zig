const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Audio module (opus + ogg bindings)
    const audio_module = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // When built as part of ESP-IDF (via esp_zig_app), CMake passes include dirs
    // through the INCLUDE_DIRS env var. The audio module needs these to resolve
    // @cImport("opus.h") — opus headers are compiled by cmake and their include
    // path is in INCLUDE_DIRS.
    const include_dirs = std.process.getEnvVarOwned(b.allocator, "INCLUDE_DIRS") catch "";
    if (include_dirs.len > 0) {
        defer b.allocator.free(include_dirs);
        var it = std.mem.tokenizeAny(u8, include_dirs, ";");
        while (it.next()) |dir| {
            audio_module.addIncludePath(.{ .cwd_relative = dir });
        }
    }
}
