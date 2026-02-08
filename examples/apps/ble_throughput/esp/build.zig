const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const esp_dep = b.dependency("esp", .{ .target = target, .optimize = optimize });
    const hal_dep = b.dependency("hal", .{ .target = target, .optimize = optimize });
    const bluetooth_dep = b.dependency("bluetooth", .{ .target = target, .optimize = optimize });
    const cancellation_dep = b.dependency("cancellation", .{ .target = target, .optimize = optimize });
    const waitgroup_dep = b.dependency("waitgroup", .{ .target = target, .optimize = optimize });

    const app_module = b.addModule("app", .{
        .root_source_file = b.path("../app.zig"),
        .target = target,
        .optimize = optimize,
    });

    app_module.addImport("esp", esp_dep.module("esp"));
    app_module.addImport("hal", hal_dep.module("hal"));
    app_module.addImport("bluetooth", bluetooth_dep.module("bluetooth"));
    app_module.addImport("cancellation", cancellation_dep.module("cancellation"));
    app_module.addImport("waitgroup", waitgroup_dep.module("waitgroup"));
}
