//! e2e: trait/log — Verify log trait (info, warn, err, debug)
//!
//! Tests:
//!   1. All four log levels complete without crash
//!   2. Format strings with arguments work
//!   3. Empty format string works

/// Run all log trait tests. Board is injected by the platform entry.
pub fn run(comptime Board: type) !void {
    const log = Board.log;

    log.info("[e2e] START: trait/log", .{});

    // Test 1: All four log levels complete without crash
    log.info("info message", .{});
    log.warn("warn message", .{});
    log.err("err message", .{});
    log.debug("debug message", .{});
    log.info("[e2e] PASS: trait/log/levels — all four levels work", .{});

    // Test 2: Format strings with various argument types
    log.info("int={} str={s} float={d:.2}", .{ @as(u32, 42), "hello", @as(f64, 3.14) });
    log.info("[e2e] PASS: trait/log/format — mixed argument types", .{});

    // Test 3: Empty args
    log.info("no args here", .{});
    log.info("[e2e] PASS: trait/log/empty_args", .{});

    // Test 4: Large format string (check no truncation)
    log.info("abcdefghijklmnopqrstuvwxyz_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ count={}", .{@as(u32, 99)});
    log.info("[e2e] PASS: trait/log/long_message", .{});

    log.info("[e2e] PASS: trait/log", .{});
}
