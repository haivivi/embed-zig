//! e2e: trait/sync — Verify Mutex, Condition, Thread.spawn, Channel, WaitGroup
//!
//! Tests:
//!   1. Mutex lock/unlock without deadlock
//!   2. Condition signal wakes waiting thread
//!   3. Thread.spawn + detach fires a task
//!   4. Channel send/recv across threads
//!   5. WaitGroup tracks task completion
//!
//! This file is IDENTICAL for all platforms.

const std = @import("std");
const platform = @import("platform.zig");
const channel_pkg = @import("channel");
const waitgroup_pkg = @import("waitgroup");

const log = platform.log;
const time = platform.time;
const Rt = platform.runtime;

fn runTests() !void {
    log.info("[e2e] START: trait/sync", .{});

    try testMutex();
    try testCondition();
    try testSpawn();
    try testChannel();
    try testWaitGroup();

    log.info("[e2e] PASS: trait/sync", .{});
}

// Test 1: Mutex lock/unlock works without deadlock
fn testMutex() !void {
    var mutex = Rt.Mutex.init();
    defer mutex.deinit();

    mutex.lock();
    mutex.unlock();

    // Lock again to verify reusability
    mutex.lock();
    mutex.unlock();

    log.info("[e2e] PASS: trait/sync/mutex", .{});
}

// Test 2: Condition signal wakes a waiting thread
fn testCondition() !void {
    var mutex = Rt.Mutex.init();
    defer mutex.deinit();
    var cond = Rt.Condition.init();
    defer cond.deinit();

    var ready: bool = false;

    const thread = try Rt.Thread.spawn(.{}, struct {
        fn run(m: *Rt.Mutex, c: *Rt.Condition, r: *bool) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            m.lock();
            r.* = true;
            c.signal();
            m.unlock();
        }
    }.run, .{ &mutex, &cond, &ready });
    thread.detach();

    mutex.lock();
    while (!ready) {
        cond.wait(&mutex);
    }
    mutex.unlock();

    if (!ready) {
        log.err("[e2e] FAIL: trait/sync/condition — not signaled", .{});
        return error.ConditionNotSignaled;
    }
    log.info("[e2e] PASS: trait/sync/condition", .{});
}

// Test 3: Thread.spawn + detach fires a task that runs to completion
fn testSpawn() !void {
    var done = std.atomic.Value(bool).init(false);

    const thread = try Rt.Thread.spawn(.{}, struct {
        fn run(d: *std.atomic.Value(bool)) void {
            d.store(true, .release);
        }
    }.run, .{&done});
    thread.detach();

    // Wait up to 500ms for the task
    var waited: u32 = 0;
    while (!done.load(.acquire) and waited < 500) {
        time.sleepMs(5);
        waited += 5;
    }

    if (!done.load(.acquire)) {
        log.err("[e2e] FAIL: trait/sync/spawn — task did not complete in 500ms", .{});
        return error.SpawnTaskTimeout;
    }
    log.info("[e2e] PASS: trait/sync/spawn — completed in ~{}ms", .{waited});
}

// Test 4: Channel send/recv across producer-consumer threads
fn testChannel() !void {
    const Ch = channel_pkg.Channel(u32, 16, Rt);
    var ch = Ch.init();
    defer ch.deinit();

    const count: u32 = 10;

    const thread = try Rt.Thread.spawn(.{}, struct {
        fn run(c: *Ch, n: u32) void {
            for (0..n) |i| {
                c.send(@intCast(i)) catch break;
            }
            c.close();
        }
    }.run, .{ &ch, count });
    thread.detach();

    // Consumer: recv all
    var received: u32 = 0;
    while (ch.recv()) |_| {
        received += 1;
    }

    if (received != count) {
        log.err("[e2e] FAIL: trait/sync/channel — expected {} items, got {}", .{ count, received });
        return error.ChannelCountMismatch;
    }
    log.info("[e2e] PASS: trait/sync/channel — {}/{} items transferred", .{ received, count });
}

// Test 5: WaitGroup waits for all spawned tasks
fn testWaitGroup() !void {
    const WG = waitgroup_pkg.WaitGroup(Rt);
    var wg = WG.init();
    defer wg.deinit();

    var counter = std.atomic.Value(u32).init(0);

    for (0..3) |_| {
        try wg.go(struct {
            fn run(c: *std.atomic.Value(u32)) void {
                _ = c.fetchAdd(1, .release);
            }
        }.run, .{&counter});
    }

    wg.wait();

    const final = counter.load(.acquire);
    if (final != 3) {
        log.err("[e2e] FAIL: trait/sync/waitgroup — expected 3, got {}", .{final});
        return error.WaitGroupCountMismatch;
    }
    log.info("[e2e] PASS: trait/sync/waitgroup — 3/3 tasks completed", .{});
}

// ESP entry
pub fn entry(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/sync — {}", .{err});
    };
}

test "e2e: trait/sync" {
    try runTests();
}
