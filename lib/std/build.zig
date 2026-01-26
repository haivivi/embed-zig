const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the std_sal module
    const std_sal_module = b.addModule("std_sal", .{
        .root_source_file = b.path("src/std.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all unit tests");

    // Test all modules
    const test_files = [_][]const u8{
        "src/std.zig",
        "src/sal/async.zig",
        "src/sal/sync.zig",
        "src/sal/socket.zig",
        "src/sal/time.zig",
        "src/sal/thread.zig",
        "src/sal/tls.zig",
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

    _ = std_sal_module;
}
