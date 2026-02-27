const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const std_impl_dep = b.dependency("std_impl", .{
        .target = target,
        .optimize = optimize,
    });
    const channel_dep = b.dependency("channel", .{
        .target = target,
        .optimize = optimize,
    });

    const runtime_module = b.createModule(.{
        .root_source_file = std_impl_dep.path("src/impl/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Module
    const audio_module = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_module.addImport("trait", trait_dep.module("trait"));
    audio_module.addImport("channel", channel_dep.module("channel"));

    const test_step = b.step("test", "Run unit tests");

    const test_modules = [_]struct { name: []const u8, file: []const u8, needs_channel: bool }{
        .{ .name = "resampler", .file = "src/resampler.zig", .needs_channel = false },
        .{ .name = "mixer", .file = "src/mixer.zig", .needs_channel = false },
        .{ .name = "drc", .file = "src/drc.zig", .needs_channel = false },
        .{ .name = "engine", .file = "src/engine.zig", .needs_channel = true },
    };

    for (test_modules) |tm| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tm.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addImport("trait", trait_dep.module("trait"));
        t.root_module.addImport("runtime", runtime_module);
        if (tm.needs_channel) {
            t.root_module.addImport("channel", channel_dep.module("channel"));
        }
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
