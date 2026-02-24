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
const waitgroup_pkg = @import("waitgroup");

const log = platform.log;
const time = platform.time;
const Rt = platform.runtime;
const Channel = platform.channel.Channel;

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
            time.sleepMs(5);
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
    log.info("[e2e] Channel test: initializing...", .{});
    const Ch = Channel(u32, 16);
    var ch = try Ch.init();
    defer ch.deinit();
    log.info("[e2e] Channel test: channel initialized", .{});

    const count: u32 = 3; // Reduced for debugging

    log.info("[e2e] Channel test: spawning producer thread...", .{});
    const thread = try Rt.Thread.spawn(.{}, struct {
        fn run(c: *Ch, n: u32) void {
            log.info("[e2e] [producer] started", .{});
            for (0..n) |i| {
                log.info("[e2e] [producer] sending item {}", .{i});
                c.send(@intCast(i)) catch |err| {
                    log.err("[e2e] [producer] send failed: {}", .{err});
                    break;
                };
                log.info("[e2e] [producer] sent item {}", .{i});
            }
            log.info("[e2e] [producer] closing channel", .{});
            c.close();
            log.info("[e2e] [producer] done", .{});
        }
    }.run, .{ &ch, count });
    thread.detach();
    log.info("[e2e] Channel test: producer thread detached", .{});

    log.info("[e2e] Channel test: starting receive loop...", .{});
    var received: u32 = 0;
    var loop_count: u32 = 0;
    while (ch.recv()) |item| {
        loop_count += 1;
        log.info("[e2e] [consumer] received item {} (loop {})", .{ item, loop_count });
        if (item != received) {
            log.err("[e2e] FAIL: trait/sync/channel — expected {}, got {}", .{ received, item });
            return error.ChannelWrongValue;
        }
        received += 1;

        // Safety limit to prevent infinite loop
        if (loop_count > 100) {
            log.err("[e2e] FAIL: trait/sync/channel — too many iterations", .{});
            return error.ChannelLoopLimit;
        }
    }

    log.info("[e2e] Channel test: receive loop ended, received={}", .{received});
    if (received != count) {
        log.err("[e2e] FAIL: trait/sync/channel — expected {} items, got {}", .{ count, received });
        return error.ChannelWrongCount;
    }
    log.info("[e2e] PASS: trait/sync/channel", .{});
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
pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/sync — {}", .{err});
    };
}

test "e2e: trait/sync" {
    try runTests();
}
