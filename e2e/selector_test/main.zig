//! Selector E2E Test
//!
//! Tests Channel and Selector functionality on std platform.

const std = @import("std");
const platform = @import("std_impl");

const Channel = platform.channel.Channel;
const Selector = platform.selector.Selector;

// Helper for API compatibility: std Selector now requires (max_sources, max_events)
// On std platform, max_events is ignored, but kept for API compatibility with FreeRTOS
fn makeSelector(comptime max_sources: usize) type {
    return Selector(max_sources, max_sources * 4);
}

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
    const Sel = makeSelector(4);
    var sel = try Sel.init();
    defer sel.deinit();
}

test "Selector wait empty returns error" {
    const Sel = makeSelector(4);
    var sel = try Sel.init();
    defer sel.deinit();

    const result = sel.wait(100);
    try std.testing.expectError(error.Empty, result);
}

test "Selector single channel" {
    const Ch = Channel(u32, 4);
    const Sel = makeSelector(4);

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
    const Sel = makeSelector(4);

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
    const Sel = makeSelector(4);

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
    const Sel = makeSelector(4);

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

test "Selector addTimeout registers dedicated timeout index" {
    const Ch = Channel(u32, 4);
    const Sel = makeSelector(4);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);
    const timeout_idx = try sel.addTimeout(20);

    const idx = try sel.wait(null);
    try std.testing.expectEqual(timeout_idx, idx);
}

test "Selector close wakes waiter" {
    const Ch = Channel(u32, 4);
    const Sel = makeSelector(4);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    const ch_idx = try sel.addRecv(&ch);

    const t = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ch) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            c.close();
        }
    }.run, .{&ch});

    const idx = try sel.wait(1000);
    try std.testing.expectEqual(ch_idx, idx);
    try std.testing.expectEqual(@as(?u32, null), ch.recv());

    t.join();
}

test "Selector sees pre-existing data immediately" {
    const Ch = Channel(u32, 4);
    const Sel = makeSelector(4);

    var ch = try Ch.init();
    defer ch.deinit();

    try ch.send(77);

    var sel = try Sel.init();
    defer sel.deinit();

    const ch_idx = try sel.addRecv(&ch);

    const start = std.time.milliTimestamp();
    const idx = try sel.wait(1000);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expectEqual(ch_idx, idx);
    try std.testing.expect(elapsed < 10);
    try std.testing.expectEqual(@as(?u32, 77), ch.recv());
}
