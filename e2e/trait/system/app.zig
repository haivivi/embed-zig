//! e2e: trait/system — Verify system information queries
//!
//! Tests:
//!   1. getCpuCount() returns >= 1

const platform = @import("platform.zig");
const log = platform.log;
const runtime = platform.runtime;

fn runTests() !void {
    log.info("[e2e] START: trait/system", .{});

    // Test 1: getCpuCount returns at least 1
    {
        const count = runtime.getCpuCount() catch |err| {
            log.err("[e2e] FAIL: trait/system/cpuCount — getCpuCount failed: {}", .{err});
            return error.GetCpuCountFailed;
        };
        if (count < 1) {
            log.err("[e2e] FAIL: trait/system/cpuCount — got 0", .{});
            return error.ZeroCpuCount;
        }
        log.info("[e2e] PASS: trait/system/cpuCount — {} cores", .{count});
    }

    log.info("[e2e] PASS: trait/system", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/system — {}", .{err});
    };
}

test "e2e: trait/system" {
    try runTests();
}
