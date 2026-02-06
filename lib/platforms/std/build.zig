const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get trait dependency
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the std_sal module
    const std_sal_module = b.addModule("std_sal", .{
        .root_source_file = b.path("src/std.zig"),
        .target = target,
        .optimize = optimize,
    });
    std_sal_module.addImport("trait", trait_dep.module("trait"));

    const test_step = b.step("test", "Run all unit tests");

    // Test socket module (needs trait)
    const socket_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sal/socket.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    socket_tests.root_module.addImport("trait", trait_dep.module("trait"));
    test_step.dependOn(&b.addRunArtifact(socket_tests).step);

    // Test other modules (no dependencies)
    const test_files = [_][]const u8{
        "src/sal/async.zig",
        "src/sal/sync.zig",
        "src/sal/time.zig",
        "src/sal/thread.zig",
    };

    for (test_files) |file| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
