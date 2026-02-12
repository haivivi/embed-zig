const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const dns_dep = b.dependency("net/dns", .{
        .target = target,
        .optimize = optimize,
    });
    const drivers_dep = b.dependency("drivers", .{
        .target = target,
        .optimize = optimize,
    });
    const idf_dep = b.dependency("idf", .{
        .target = target,
        .optimize = optimize,
    });
    const impl_dep = b.dependency("impl", .{
        .target = target,
        .optimize = optimize,
    });
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const hal_dep = b.dependency("hal", .{
        .target = target,
        .optimize = optimize,
    });

    // Get crypto dependency
    const crypto_dep = b.dependency("crypto", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the esp module (re-exports idf and impl)
    const esp_module = b.addModule("esp", .{
        .root_source_file = b.path("src/esp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "net/dns", .module = dns_dep.module("net/dns") },
            .{ .name = "drivers", .module = drivers_dep.module("drivers") },
            .{ .name = "idf", .module = idf_dep.module("idf") },
            .{ .name = "impl", .module = impl_dep.module("impl") },
            .{ .name = "trait", .module = trait_dep.module("trait") },
            .{ .name = "hal", .module = hal_dep.module("hal") },
            .{ .name = "crypto", .module = crypto_dep.module("crypto") },
        },
    });

    // Add ESP deps to the module itself
    addEspDeps(b, esp_module) catch |err| {
        std.log.warn("Failed to add ESP dependencies: {}", .{err});
    };
}

/// Add all ESP-IDF include paths and dependencies to a module.
/// This is a build-time function for adding include paths from ESP-IDF.
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

    // Use a hash map to track added directories and avoid duplicates
    // Note: We must use owned strings because walker reuses its internal buffer
    var added_dirs = std.StringHashMap(void).init(b.allocator);
    defer added_dirs.deinit();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (std.mem.eql(u8, std.fs.path.extension(entry.basename), ".h")) {
            if (std.fs.path.dirname(entry.path)) |parent| {
                // Only add each directory once
                // Must dupe the key since walker reuses its buffer
                const key = b.dupe(parent);
                const gop = try added_dirs.getOrPut(key);
                if (!gop.found_existing) {
                    module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ comp, parent }) });
                }
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
