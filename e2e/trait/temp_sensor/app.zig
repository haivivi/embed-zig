//! e2e: hal/temp_sensor — Verify internal temperature sensor
//!
//! Tests:
//!   1. Driver init/deinit without crash
//!   2. readCelsius returns value in -10 to 80 range

const platform = @import("platform.zig");
const log = platform.log;
const TempDriver = platform.TempDriver;

fn runTests() !void {
    log.info("[e2e] START: hal/temp_sensor", .{});

    // Test 1: init/deinit
    var driver = TempDriver.init() catch |err| {
        log.err("[e2e] FAIL: hal/temp_sensor/init — {}", .{err});
        return error.TempInitFailed;
    };
    defer driver.deinit();
    log.info("[e2e] PASS: hal/temp_sensor/init", .{});

    // Test 2: readCelsius in reasonable range
    {
        const temp = driver.readCelsius() catch |err| {
            log.err("[e2e] FAIL: hal/temp_sensor/read — {}", .{err});
            return error.TempReadFailed;
        };

        // Internal temp should be between -10 and 80 degrees
        const temp_int: i32 = @intFromFloat(temp);
        if (temp < -10.0 or temp > 80.0) {
            log.err("[e2e] FAIL: hal/temp_sensor/range — temp={}C out of range", .{temp_int});
            return error.TempOutOfRange;
        }

        // Read again to verify stability
        const temp2 = driver.readCelsius() catch |err| {
            log.err("[e2e] FAIL: hal/temp_sensor/read2 — {}", .{err});
            return error.TempReadFailed;
        };

        // Two readings should be within 5 degrees of each other
        const diff = if (temp2 > temp) temp2 - temp else temp - temp2;
        if (diff > 5.0) {
            const diff_int: i32 = @intFromFloat(diff);
            log.err("[e2e] FAIL: hal/temp_sensor/stable — readings differ by {}C", .{diff_int});
            return error.TempUnstable;
        }

        log.info("[e2e] PASS: hal/temp_sensor/read — {}C (stable)", .{temp_int});
    }

    log.info("[e2e] PASS: hal/temp_sensor", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: hal/temp_sensor — {}", .{err});
    };
}

test "e2e: hal/temp_sensor" {
    try runTests();
}
