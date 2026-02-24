//! Selector E2E Test
//!
//! Tests Channel and Selector functionality on std platform.

const std = @import("std");
const platform = @import("std_impl");

const Channel = platform.channel.Channel;
const Selector = platform.selector.Selector;

// ============================================================================
// Channel Tests
// ============================================================================

test "Channel basic send/recv" {
    const Ch = Channel(u32, 4);
    var ch = try Ch.init();
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);

    try std.testing.expectEqual(@as(?u32, 1), ch.recv());
    try std.testing.expectEqual(@as(?u32, 2), ch.recv());
    try std.testing.expectEqual(@as(?u32, 3), ch.recv());
}

test "Channel close drains then returns null" {
    const Ch = Channel(u32, 4);
    var ch = try Ch.init();
    defer ch.deinit();

    try ch.send(10);
    try ch.send(20);
    ch.close();

    try std.testing.expectEqual(@as(?u32, 10), ch.recv());
    try std.testing.expectEqual(@as(?u32, 20), ch.recv());
    try std.testing.expectEqual(@as(?u32, null), ch.recv());
}

test "Channel send after close returns error" {
    const Ch = Channel(u32, 4);
    var ch = try Ch.init();
    defer ch.deinit();

    ch.close();

    const result = ch.send(1);
    try std.testing.expectError(error.Closed, result);
}

test "Channel trySend/tryRecv" {
    const Ch = Channel(u32, 2);
    var ch = try Ch.init();
    defer ch.deinit();

    try ch.trySend(1);
    try ch.trySend(2);

    try std.testing.expectError(error.Full, ch.trySend(3));

    try std.testing.expectEqual(@as(?u32, 1), ch.tryRecv());
    try std.testing.expectEqual(@as(?u32, 2), ch.tryRecv());

    try std.testing.expectEqual(@as(?u32, null), ch.tryRecv());
}

test "Channel FIFO order" {
    const Ch = Channel(u32, 8);
    var ch = try Ch.init();
    defer ch.deinit();

    for (0..5) |i| {
        try ch.send(@intCast(i));
    }
    for (0..5) |i| {
        try std.testing.expectEqual(@as(?u32, @intCast(i)), ch.recv());
    }
}

test "Channel cross-thread producer/consumer" {
    const Ch = Channel(u32, 4);
    var ch = try Ch.init();
    defer ch.deinit();

    const count = 100;

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ch) void {
            for (0..count) |i| {
                c.send(@intCast(i)) catch return;
            }
            c.close();
        }
    }.run, .{&ch});

    var sum: u64 = 0;
    var received: u32 = 0;
    while (ch.recv()) |item| {
        sum += item;
        received += 1;
    }

    producer.join();

    try std.testing.expectEqual(@as(u32, count), received);
    try std.testing.expectEqual(@as(u64, 4950), sum);
}

// ============================================================================
// Selector Tests
// ============================================================================

test "Selector init/deinit" {
    const Sel = Selector(4);
    var sel = try Sel.init();
    defer sel.deinit();
}

test "Selector wait empty returns error" {
    const Sel = Selector(4);
    var sel = try Sel.init();
    defer sel.deinit();

    const result = sel.wait(100);
    try std.testing.expectError(error.Empty, result);
}

test "Selector single channel" {
    const Ch = Channel(u32, 4);
    const Sel = Selector(4);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);

    // Send from another thread
    const t = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ch) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            c.send(42) catch {};
        }
    }.run, .{&ch});

    const idx = try sel.wait(1000);
    try std.testing.expectEqual(@as(usize, 0), idx);

    const val = ch.recv();
    try std.testing.expectEqual(@as(?u32, 42), val);

    t.join();
}

test "Selector two channels - first ready" {
    const Ch = Channel(u32, 4);
    const Sel = Selector(4);

    var ch1 = try Ch.init();
    defer ch1.deinit();
    var ch2 = try Ch.init();
    defer ch2.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch1);
    _ = try sel.addRecv(&ch2);

    // Send to ch1 from another thread
    const t = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ch) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            c.send(100) catch {};
        }
    }.run, .{&ch1});

    const idx = try sel.wait(1000);
    try std.testing.expectEqual(@as(usize, 0), idx);

    const val = ch1.recv();
    try std.testing.expectEqual(@as(?u32, 100), val);

    t.join();
}

test "Selector two channels - second ready" {
    const Ch = Channel(u32, 4);
    const Sel = Selector(4);

    var ch1 = try Ch.init();
    defer ch1.deinit();
    var ch2 = try Ch.init();
    defer ch2.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch1);
    _ = try sel.addRecv(&ch2);

    // Send to ch2 from another thread
    const t = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ch) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            c.send(200) catch {};
        }
    }.run, .{&ch2});

    const idx = try sel.wait(1000);
    try std.testing.expectEqual(@as(usize, 1), idx);

    const val = ch2.recv();
    try std.testing.expectEqual(@as(?u32, 200), val);

    t.join();
}

test "Selector timeout" {
    const Ch = Channel(u32, 4);
    const Sel = Selector(4);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);

    const start = std.time.milliTimestamp();
    const idx = try sel.wait(50); // 50ms timeout
    const elapsed = std.time.milliTimestamp() - start;

    // Should return timeout (max_sources)
    try std.testing.expectEqual(@as(usize, 4), idx);
    try std.testing.expect(elapsed >= 45); // Allow some tolerance
}

// ============================================================================
// Benchmark
// ============================================================================

fn benchmarkChannelThroughput(_: std.mem.Allocator, message_count: usize) !void {
    const Ch = Channel(u64, 1024);

    var ch = try Ch.init();
    defer ch.deinit();

    const start = std.time.nanoTimestamp();

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ch, count: usize) void {
            for (0..count) |i| {
                c.send(@intCast(i)) catch return;
            }
            c.close();
        }
    }.run, .{ &ch, message_count });

    var received: usize = 0;
    while (ch.recv()) |_| {
        received += 1;
    }

    producer.join();

    const elapsed_ns = std.time.nanoTimestamp() - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const throughput = @as(f64, @floatFromInt(message_count)) / elapsed_s / 1e6; // M msg/s

    std.debug.print("\nChannel throughput: {d} messages in {d:.3}s = {d:.2} M msg/s\n", .{
        message_count, elapsed_s, throughput,
    });

    try std.testing.expectEqual(message_count, received);
}

test "Benchmark: Channel throughput 1M messages" {
    try benchmarkChannelThroughput(std.testing.allocator, 1_000_000);
}

test "Benchmark: Channel throughput 10M messages" {
    try benchmarkChannelThroughput(std.testing.allocator, 10_000_000);
}

fn benchmarkSelectorLatencyWithSleep(iterations: usize) !void {
    const Ch = Channel(u64, 4);
    const Sel = Selector(2);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);

    var total_latency_ns: i64 = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const send_time: i64 = @intCast(std.time.nanoTimestamp());

        const t = try std.Thread.spawn(.{}, struct {
            fn run(c: *Ch, st: i64) void {
                _ = st;
                std.Thread.sleep(1 * std.time.ns_per_ms);
                c.send(1) catch {};
            }
        }.run, .{ &ch, send_time });

        _ = try sel.wait(1000);
        const recv_time: i64 = @intCast(std.time.nanoTimestamp());

        _ = ch.recv(); // Consume the message

        total_latency_ns += recv_time - send_time;
        t.join();
    }

    const avg_latency_us = @as(f64, @floatFromInt(total_latency_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;

    std.debug.print("\nSelector average wakeup latency (with 1ms sleep): {d:.2} us\n", .{avg_latency_us});
}

test "Benchmark: Selector latency 100 iterations (with sleep)" {
    try benchmarkSelectorLatencyWithSleep(100);
}

fn benchmarkSelectorLatencyImmediate(iterations: usize) !void {
    const Ch = Channel(u64, 4);
    const Sel = Selector(2);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);

    var total_latency_ns: i64 = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Reset selector for next iteration
        sel.reset();
        _ = try sel.addRecv(&ch);

        // Pre-create thread but wait for signal to send
        var ready = std.atomic.Value(bool).init(false);
        var start_send = std.atomic.Value(bool).init(false);

        const t = try std.Thread.spawn(.{}, struct {
            fn run(c: *Ch, r: *std.atomic.Value(bool), s: *std.atomic.Value(bool)) void {
                r.store(true, .release);
                // Wait for signal to send
                while (!s.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }
                c.send(1) catch {};
            }
        }.run, .{ &ch, &ready, &start_send });

        // Wait for thread to be ready
        while (!ready.load(.acquire)) {
            std.atomic.spinLoopHint();
        }

        // Measure: signal sender then wait on selector
        const send_time: i64 = @intCast(std.time.nanoTimestamp());
        start_send.store(true, .release);

        _ = try sel.wait(1000);
        const recv_time: i64 = @intCast(std.time.nanoTimestamp());

        _ = ch.recv(); // Consume the message

        total_latency_ns += recv_time - send_time;
        t.join();
    }

    const avg_latency_us = @as(f64, @floatFromInt(total_latency_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    const avg_latency_ns = @as(f64, @floatFromInt(total_latency_ns)) / @as(f64, @floatFromInt(iterations));

    std.debug.print("\nSelector average wakeup latency (immediate send): {d:.2} us ({d:.0} ns)\n", .{ avg_latency_us, avg_latency_ns });
}

test "Benchmark: Selector latency 1000 iterations (immediate)" {
    try benchmarkSelectorLatencyImmediate(1000);
}
