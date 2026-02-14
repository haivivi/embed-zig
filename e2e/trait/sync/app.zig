//! e2e: trait/sync — Verify Mutex, Condition, spawn, Channel, WaitGroup
//!
//! Tests:
//!   1. Mutex lock/unlock without deadlock
//!   2. Condition signal wakes waiting thread
//!   3. spawn fires a detached task
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

    const Ctx = struct {
        m: *Rt.Mutex,
        c: *Rt.Condition,
        r: *bool,
    };
    var ctx = Ctx{ .m = &mutex, .c = &cond, .r = &ready };

    try Rt.spawn("cond_signaler", struct {
        fn task(raw: ?*anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(raw));
            std.Thread.sleep(5 * std.time.ns_per_ms);
            c.m.lock();
            c.r.* = true;
            c.c.signal();
            c.m.unlock();
        }
    }.task, @ptrCast(&ctx), .{});

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

// Test 3: spawn fires a detached task that runs to completion
fn testSpawn() !void {
    var done = std.atomic.Value(bool).init(false);

    try Rt.spawn("spawn_test", struct {
        fn task(raw: ?*anyopaque) void {
            const d: *std.atomic.Value(bool) = @ptrCast(@alignCast(raw));
            d.store(true, .release);
        }
    }.task, @ptrCast(&done), .{});

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

    const ProducerCtx = struct {
        ch: *Ch,
        n: u32,
    };
    var producer_ctx = ProducerCtx{ .ch = &ch, .n = count };

    try Rt.spawn("producer", struct {
        fn task(raw: ?*anyopaque) void {
            const ctx: *ProducerCtx = @ptrCast(@alignCast(raw));
            for (0..ctx.n) |i| {
                ctx.ch.send(@intCast(i)) catch break;
            }
            ctx.ch.close();
        }
    }.task, @ptrCast(&producer_ctx), .{});

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
    var wg = WG.init(std.heap.page_allocator);
    defer wg.deinit();

    var counter = std.atomic.Value(u32).init(0);

    for (0..3) |_| {
        try wg.go("wg_worker", struct {
            fn task(raw: ?*anyopaque) void {
                const c: *std.atomic.Value(u32) = @ptrCast(@alignCast(raw));
                _ = c.fetchAdd(1, .release);
            }
        }.task, @ptrCast(&counter), .{});
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
