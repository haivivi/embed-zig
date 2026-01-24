const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the esp module
    const esp_module = b.addModule("esp", .{
        .root_source_file = b.path("src/idf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add ESP deps to the module itself
    addEspDeps(b, esp_module) catch {};
}

/// Add all ESP-IDF include paths and dependencies to a module
pub fn addEspDeps(b: *std.Build, module: *std.Build.Module) !void {
    // 1. From INCLUDE_DIRS env var (set by CMake)
    const include_dirs = std.process.getEnvVarOwned(b.allocator, "INCLUDE_DIRS") catch "";
    if (include_dirs.len > 0) {
        defer b.allocator.free(include_dirs);
        var it = std.mem.tokenizeAny(u8, include_dirs, ";");
        while (it.next()) |dir| {
            module.addIncludePath(.{ .cwd_relative = dir });
        }
    }

    // 2. From IDF_PATH env var
    const idf_path = std.process.getEnvVarOwned(b.allocator, "IDF_PATH") catch "";
    if (idf_path.len > 0) {
        defer b.allocator.free(idf_path);
        try addIdfComponentIncludes(b, module, idf_path);
    }

    // 3. Toolchain includes (auto-detect version)
    const home_dir = std.process.getEnvVarOwned(b.allocator, "HOME") catch "";
    if (home_dir.len > 0) {
        defer b.allocator.free(home_dir);
        addToolchainIncludes(b, module, home_dir);
    }
}

fn addIdfComponentIncludes(b: *std.Build, module: *std.Build.Module, idf_path: []const u8) !void {
    const comp = b.pathJoin(&.{ idf_path, "components" });
    var dir = std.fs.cwd().openDir(comp, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (std.mem.eql(u8, std.fs.path.extension(entry.basename), ".h")) {
            if (std.fs.path.dirname(entry.path)) |parent| {
                module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ comp, parent }) });
            }
        }
    }
}

fn addToolchainIncludes(b: *std.Build, module: *std.Build.Module, home_dir: []const u8) void {
    const arch = module.resolved_target.?.result.cpu.arch;
    const archtools = b.fmt("{s}-esp-elf", .{@tagName(arch)});
    const tools_base = b.pathJoin(&.{ home_dir, ".espressif", "tools", archtools });

    // Find toolchain version dynamically
    var tools_dir = std.fs.cwd().openDir(tools_base, .{ .iterate = true }) catch return;
    defer tools_dir.close();

    var version: ?[]const u8 = null;
    var it = tools_dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "esp-")) {
            version = b.dupe(entry.name);
            break;
        }
    }

    const ver = version orelse return;

    module.addIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ tools_base, ver, archtools, "include" }),
    });
    module.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ tools_base, ver, archtools, archtools, "sys-include" }),
    });
    module.addIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ tools_base, ver, archtools, archtools, "include" }),
    });
}
