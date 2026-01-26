const std = @import("std");
const esp = @import("esp");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get esp dependency (still needed for WiFi init and logging)
    const esp_dep = b.dependency("esp", .{
        .target = target,
        .optimize = optimize,
    });

    // Get http dependency
    const http_dep = b.dependency("http", .{
        .target = target,
        .optimize = optimize,
    });

    // Get dns dependency
    const dns_dep = b.dependency("dns", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add esp module (for WiFi and logging only)
    root_module.addImport("esp", esp_dep.module("esp"));
    // Add http module
    root_module.addImport("http", http_dep.module("http"));
    // Add dns module
    root_module.addImport("dns", dns_dep.module("dns"));

    const lib = b.addLibrary(.{
        .name = "main_zig",
        .linkage = .static,
        .root_module = root_module,
    });

    esp.addEspDeps(b, root_module) catch {
        @panic("Failed to add ESP dependencies");
    };
    b.installArtifact(lib);
}
