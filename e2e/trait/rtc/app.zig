//! e2e: hal/rtc — Verify RTC reader (uptime monotonic, nowMs)
//!
//! Tests:
//!   1. RTC driver init/deinit without crash
//!   2. uptime() returns monotonically increasing values
//!   3. nowMs() returns null or valid epoch (if synced)

const hal = @import("hal");
const platform = @import("platform.zig");
const log = platform.log;
const time = platform.time;

fn runTests() !void {
    log.info("[e2e] START: hal/rtc", .{});

    const RtcReader = hal.rtc.reader.from(platform.rtc_spec);
    const RtcDriver = RtcReader.DriverType;

    // Test 1: init/deinit
    var driver = RtcDriver.init() catch |err| {
        log.err("[e2e] FAIL: hal/rtc/init — driver init failed: {}", .{err});
        return error.RtcInitFailed;
    };
    defer driver.deinit();

    var reader = RtcReader.init(&driver);
    log.info("[e2e] PASS: hal/rtc/init", .{});

    // Test 2: uptime monotonic
    {
        const t1 = reader.uptime();
        time.sleepMs(10);
        const t2 = reader.uptime();

        if (t2 <= t1) {
            log.err("[e2e] FAIL: hal/rtc/uptime — not monotonic: t1={}, t2={}", .{ t1, t2 });
            return error.UptimeNotMonotonic;
        }
        log.info("[e2e] PASS: hal/rtc/uptime — delta={}ms", .{t2 - t1});
    }

    // Test 3: now() returns null (no NTP sync) or valid epoch
    {
        const ts = reader.now();
        if (ts) |t| {
            const epoch = t.toEpoch();
            // If synced, epoch should be > 2020-01-01 (1577836800)
            if (epoch < 1577836800) {
                log.err("[e2e] FAIL: hal/rtc/now — epoch too small: {}", .{epoch});
                return error.RtcEpochInvalid;
            }
            log.info("[e2e] PASS: hal/rtc/now — epoch={}", .{epoch});
        } else {
            log.info("[e2e] PASS: hal/rtc/now — null (not synced, expected)", .{});
        }
    }

    log.info("[e2e] PASS: hal/rtc", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: hal/rtc — {}", .{err});
    };
}

test "e2e: hal/rtc" {
    try runTests();
}
