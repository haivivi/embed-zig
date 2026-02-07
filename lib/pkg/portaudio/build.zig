//! PortAudio library - cross-platform audio I/O
//!
//! Builds PortAudio from source and provides Zig bindings.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = buildPortAudio(b, target, optimize);
    b.installArtifact(lib);

    // Also expose the Zig module
    _ = b.addModule("portaudio", .{
        .root_source_file = b.path("src/portaudio.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn buildPortAudio(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const portaudio_dep = b.dependency("portaudio_src", .{});

    // Create a module for the C library
    const lib_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const pa_include = portaudio_dep.path("include");

    lib_module.addIncludePath(pa_include);
    lib_module.addIncludePath(portaudio_dep.path("src/common"));
    lib_module.addIncludePath(portaudio_dep.path("src/os/unix"));

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
            .file = portaudio_dep.path(src),
            .flags = pa_flag,
        });
    }

    // Platform-specific sources
    if (os == .macos) {
        // macOS CoreAudio backend
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/os/unix/pa_unix_hostapis.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/os/unix/pa_unix_util.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/hostapi/coreaudio/pa_mac_core.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/hostapi/coreaudio/pa_mac_core_utilities.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/hostapi/coreaudio/pa_mac_core_blocking.c"), .flags = pa_flag });

        lib_module.addIncludePath(portaudio_dep.path("src/hostapi/coreaudio"));
        lib_module.linkFramework("CoreAudio", .{});
        lib_module.linkFramework("AudioToolbox", .{});
        lib_module.linkFramework("AudioUnit", .{});
        lib_module.linkFramework("CoreFoundation", .{});
        lib_module.linkFramework("CoreServices", .{});
    } else if (os == .linux) {
        // Linux ALSA backend
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/os/unix/pa_unix_hostapis.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/os/unix/pa_unix_util.c"), .flags = pa_flag });
        lib_module.addCSourceFile(.{ .file = portaudio_dep.path("src/hostapi/alsa/pa_linux_alsa.c"), .flags = pa_flag });

        lib_module.linkSystemLibrary("asound", .{});
        lib_module.linkSystemLibrary("pthread", .{});
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "portaudio",
        .root_module = lib_module,
    });

    return lib;
}

/// Create a module that links against PortAudio (for use as dependency)
pub fn module(dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const b = dep.builder;
    const lib = buildPortAudio(b, target, optimize);
    const portaudio_dep = b.dependency("portaudio_src", .{});

    const mod = b.createModule(.{
        .root_source_file = dep.path("src/portaudio.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addIncludePath(portaudio_dep.path("include"));
    mod.linkLibrary(lib);

    return mod;
}
