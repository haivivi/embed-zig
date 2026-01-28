//! Mic Test Server - Build Configuration
//!
//! TCP server that receives audio from ESP device and plays it via PortAudio.
//! PortAudio is built from source for cross-platform support.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build PortAudio from source
    const portaudio_src = b.dependency("portaudio_src", .{});
    const portaudio_lib = buildPortAudio(b, target, optimize, portaudio_src);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add PortAudio include path for @cImport
    root_module.addIncludePath(portaudio_src.path("include"));

    // Link the PortAudio static library
    root_module.linkLibrary(portaudio_lib);

    // Link platform frameworks (macOS)
    if (target.result.os.tag == .macos) {
        root_module.linkFramework("CoreAudio", .{});
        root_module.linkFramework("AudioToolbox", .{});
        root_module.linkFramework("AudioUnit", .{});
        root_module.linkFramework("CoreFoundation", .{});
        root_module.linkFramework("CoreServices", .{});
    }

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

fn buildPortAudio(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    portaudio_src: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const lib_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    lib_module.addIncludePath(portaudio_src.path("include"));
    lib_module.addIncludePath(portaudio_src.path("src/common"));
    lib_module.addIncludePath(portaudio_src.path("src/os/unix"));

    // Common source files
    const common_sources = [_][]const u8{
        "src/common/pa_allocation.c",
        "src/common/pa_converters.c",
        "src/common/pa_cpuload.c",
        "src/common/pa_debugprint.c",
        "src/common/pa_dither.c",
        "src/common/pa_front.c",
        "src/common/pa_process.c",
        "src/common/pa_ringbuffer.c",
        "src/common/pa_stream.c",
        "src/common/pa_trace.c",
    };

    const os = target.result.os.tag;
    const pa_flag: []const []const u8 = if (os == .macos) &.{"-DPA_USE_COREAUDIO=1"} else &.{"-DPA_USE_ALSA=1"};

    for (common_sources) |src| {
        lib_module.addCSourceFile(.{
            .file = portaudio_src.path(src),
            .flags = pa_flag,
        });
    }

    // Platform-specific sources
    if (os == .macos) {
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/os/unix/pa_unix_hostapis.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/os/unix/pa_unix_util.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/hostapi/coreaudio/pa_mac_core.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/hostapi/coreaudio/pa_mac_core_utilities.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/hostapi/coreaudio/pa_mac_core_blocking.c"), .flags = pa_flag });
        lib_module.addIncludePath(portaudio_src.path("src/hostapi/coreaudio"));
    } else if (os == .linux) {
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/os/unix/pa_unix_hostapis.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/os/unix/pa_unix_util.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_src.path("src/hostapi/alsa/pa_linux_alsa.c"), .flags = pa_flag });
        lib_module.linkSystemLibrary("asound", .{});
        lib_module.linkSystemLibrary("pthread", .{});
    }
    // Note: Windows is not currently supported. PRs welcome to add WASAPI/DirectSound backend.

    return b.addLibrary(.{
        .linkage = .static,
        .name = "portaudio",
        .root_module = lib_module,
    });
}
