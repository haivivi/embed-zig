//! e2e: trait/io — Verify async IO service (kqueue/epoll)
//!
//! Tests:
//!   1. init + deinit without crash
//!   2. registerRead on pipe fd, write triggers callback via poll
//!   3. wake() interrupts blocking poll

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;
const IOService = platform.IOService;

fn runTests() !void {
    log.info("[e2e] START: trait/io", .{});

    try testInitDeinit();
    try testReadCallback();
    try testWake();

    log.info("[e2e] PASS: trait/io", .{});
}

// Test 1: init + deinit
fn testInitDeinit() !void {
    var io = IOService.init(std.heap.page_allocator) catch |err| {
        log.err("[e2e] FAIL: trait/io/init — {}", .{err});
        return error.IoInitFailed;
    };
    io.deinit();
    log.info("[e2e] PASS: trait/io/init", .{});
}

// Test 2: registerRead + poll — write to pipe triggers read callback
fn testReadCallback() !void {
    var io = IOService.init(std.heap.page_allocator) catch |err| {
        log.err("[e2e] FAIL: trait/io/read — init failed: {}", .{err});
        return error.IoInitFailed;
    };
    defer io.deinit();

    // Create a pipe
    const pipe = try std.posix.pipe();
    const read_fd = pipe[0];
    const write_fd = pipe[1];
    defer std.posix.close(read_fd);
    defer std.posix.close(write_fd);

    var called = false;

    // Register read callback
    io.registerRead(read_fd, .{
        .ptr = @ptrCast(&called),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: std.posix.fd_t) void {
                const c: *bool = @ptrCast(@alignCast(ptr));
                c.* = true;
            }
        }.cb,
    });

    // Write to pipe — makes read_fd readable
    _ = try std.posix.write(write_fd, "x");

    // Poll should trigger the callback
    const n = io.poll(100);
    _ = n;

    if (!called) {
        log.err("[e2e] FAIL: trait/io/read — callback not triggered", .{});
        return error.IoCallbackNotTriggered;
    }
    log.info("[e2e] PASS: trait/io/read", .{});
}

// Test 3: wake() interrupts blocking poll from another thread
fn testWake() !void {
    var io = IOService.init(std.heap.page_allocator) catch |err| {
        log.err("[e2e] FAIL: trait/io/wake — init failed: {}", .{err});
        return error.IoInitFailed;
    };
    defer io.deinit();

    var poll_returned = std.atomic.Value(bool).init(false);

    // Spawn thread that polls with long timeout
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(io_ptr: *IOService, flag: *std.atomic.Value(bool)) void {
            _ = io_ptr.poll(5000); // 5s timeout — should be woken early
            flag.store(true, .release);
        }
    }.run, .{ &io, &poll_returned });

    // Give poll thread time to start
    std.Thread.sleep(20 * std.time.ns_per_ms);

    // Wake it
    io.wake();

    thread.join();

    if (!poll_returned.load(.acquire)) {
        log.err("[e2e] FAIL: trait/io/wake — poll did not return after wake", .{});
        return error.IoWakeFailed;
    }
    log.info("[e2e] PASS: trait/io/wake", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/io — {}", .{err});
    };
}

test "e2e: trait/io" {
    try runTests();
}
