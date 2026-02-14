//! e2e: trait/spawner — Verify Thread.spawn, join, detach
//!
//! Tests:
//!   1. spawn + join: thread runs to completion, result visible after join
//!   2. spawn + detach: fire-and-forget task completes
//!   3. spawn multiple + join all

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;
const Rt = platform.runtime;

fn runTests() !void {
    log.info("[e2e] START: trait/spawner", .{});

    try testSpawnJoin();
    try testSpawnDetach();
    try testMultipleJoin();

    log.info("[e2e] PASS: trait/spawner", .{});
}

// Test 1: spawn + join — thread writes value, join waits for completion
fn testSpawnJoin() !void {
    var result = std.atomic.Value(i32).init(0);

    const thread = try Rt.Thread.spawn(.{}, struct {
        fn run(r: *std.atomic.Value(i32)) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            r.store(42, .release);
        }
    }.run, .{&result});

    thread.join();

    const val = result.load(.acquire);
    if (val != 42) {
        log.err("[e2e] FAIL: trait/spawner/join — expected 42, got {}", .{val});
        return error.JoinValueMismatch;
    }
    log.info("[e2e] PASS: trait/spawner/join", .{});
}

// Test 2: spawn + detach — fire-and-forget, poll for completion
fn testSpawnDetach() !void {
    var done = std.atomic.Value(bool).init(false);

    const thread = try Rt.Thread.spawn(.{}, struct {
        fn run(d: *std.atomic.Value(bool)) void {
            d.store(true, .release);
        }
    }.run, .{&done});
    thread.detach();

    var waited: u32 = 0;
    while (!done.load(.acquire) and waited < 500) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
        waited += 5;
    }

    if (!done.load(.acquire)) {
        log.err("[e2e] FAIL: trait/spawner/detach — not completed in 500ms", .{});
        return error.DetachTimeout;
    }
    log.info("[e2e] PASS: trait/spawner/detach", .{});
}

// Test 3: spawn 3 threads, join all, verify all completed
fn testMultipleJoin() !void {
    var counters: [3]std.atomic.Value(u32) = .{
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
    };

    var threads: [3]Rt.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try Rt.Thread.spawn(.{}, struct {
            fn run(ctrs: *[3]std.atomic.Value(u32), idx: usize) void {
                _ = ctrs[idx].fetchAdd(1, .release);
            }
        }.run, .{ &counters, i });
    }

    for (&threads) |*t| {
        t.join();
    }

    for (counters, 0..) |c, i| {
        const val = c.load(.acquire);
        if (val != 1) {
            log.err("[e2e] FAIL: trait/spawner/multi — thread {} counter={}", .{ i, val });
            return error.MultiJoinMismatch;
        }
    }
    log.info("[e2e] PASS: trait/spawner/multi — 3/3 joined", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/spawner — {}", .{err});
    };
}

test "e2e: trait/spawner" {
    try runTests();
}
