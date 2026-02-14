//! e2e: trait/rng — Verify random number generation
//!
//! Tests:
//!   1. fill() produces non-zero output
//!   2. Two consecutive fills produce different output
//!   3. fill() works on various buffer sizes

const platform = @import("platform.zig");
const log = platform.log;
const rng = platform.rng;

fn runTests() !void {
    log.info("[e2e] START: trait/rng", .{});

    // Test 1: fill 32 bytes, verify not all zeros
    {
        var buf: [32]u8 = .{0} ** 32;
        rng.fill(&buf);
        var all_zero = true;
        for (buf) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) {
            log.err("[e2e] FAIL: trait/rng/nonzero — 32 bytes all zero", .{});
            return error.RngAllZero;
        }
        log.info("[e2e] PASS: trait/rng/nonzero", .{});
    }

    // Test 2: two fills produce different output
    {
        var buf1: [32]u8 = undefined;
        var buf2: [32]u8 = undefined;
        rng.fill(&buf1);
        rng.fill(&buf2);
        var same = true;
        for (buf1, buf2) |a, b| {
            if (a != b) {
                same = false;
                break;
            }
        }
        if (same) {
            log.err("[e2e] FAIL: trait/rng/distinct — two fills identical", .{});
            return error.RngNotDistinct;
        }
        log.info("[e2e] PASS: trait/rng/distinct", .{});
    }

    // Test 3: fill works on small (1 byte) and large (256 byte) buffers
    {
        var small: [1]u8 = .{0};
        rng.fill(&small);

        var large: [256]u8 = .{0} ** 256;
        rng.fill(&large);
        var all_zero = true;
        for (large) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) {
            log.err("[e2e] FAIL: trait/rng/sizes — 256 bytes all zero", .{});
            return error.RngAllZero;
        }
        log.info("[e2e] PASS: trait/rng/sizes", .{});
    }

    log.info("[e2e] PASS: trait/rng", .{});
}

pub fn entry(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/rng — {}", .{err});
    };
}

test "e2e: trait/rng" {
    try runTests();
}
