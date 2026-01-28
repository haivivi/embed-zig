//! Mic Test Server - Build Configuration
//!
//! TCP server that receives audio from ESP device and plays it via PortAudio.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add Homebrew library paths for PortAudio
    root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    root_module.linkSystemLibrary("portaudio", .{});

    const exe = b.addExecutable(.{
        .name = "mic_server",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the mic test server");
    run_step.dependOn(&run_cmd.step);
}
