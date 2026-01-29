const std = @import("std");
const idf_build = @import("idf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const dns_dep = b.dependency("dns", .{
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

    // Create the esp module (re-exports idf and impl)
    const esp_module = b.addModule("esp", .{
        .root_source_file = b.path("src/esp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dns", .module = dns_dep.module("dns") },
            .{ .name = "idf", .module = idf_dep.module("idf") },
            .{ .name = "impl", .module = impl_dep.module("impl") },
            .{ .name = "trait", .module = trait_dep.module("trait") },
            .{ .name = "hal", .module = hal_dep.module("hal") },
        },
    });

    // Add ESP deps to the module itself (reuse from idf package)
    idf_build.addEspDeps(b, esp_module) catch |err| {
        std.log.warn("Failed to add ESP dependencies: {}", .{err});
    };
}
