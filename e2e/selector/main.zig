//! Selector E2E Test — Cross-platform selector functionality
//!
//! This test validates the selector functionality across all platforms:
//! - std (macOS/Linux): kqueue/epoll
//! - ESP32: FreeRTOS xQueueSet
//! - BK7258: FreeRTOS xQueueSet

const std = @import("std");
const platform = @import("std_impl");

const Channel = platform.channel.Channel;
const Selector = platform.selector.Selector;

// ============================================================================
// Selector Tests
// ============================================================================

test "Selector single channel ready" {
    // S1.1: Single channel ready
    const Ch = Channel(u32, 4);
    const Sel = Selector(2, 8);

    var ch = try Ch.init();
    defer ch.deinit();
    var sel = try Sel.init();
    defer sel.deinit();

    const idx = try sel.addRecv(&ch);
    try std.testing.expectEqual(@as(usize, 0), idx);

    // Send after selector setup
    try ch.send(42);

    const ready = try sel.wait(1000);
    try std.testing.expectEqual(@as(usize, 0), ready);
    try std.testing.expectEqual(@as(?u32, 42), ch.recv());
}

test "Selector first of two channels ready" {
    // S1.2: First of two channels ready
    const Ch = Channel(u32, 4);
    const Sel = Selector(3, 12);

    var ch1 = try Ch.init();
    defer ch1.deinit();
    var ch2 = try Ch.init();
    defer ch2.deinit();
    var sel = try Sel.init();
    defer sel.deinit();

    const idx1 = try sel.addRecv(&ch1);
    const idx2 = try sel.addRecv(&ch2);
    try std.testing.expectEqual(@as(usize, 0), idx1);
    try std.testing.expectEqual(@as(usize, 1), idx2);

    try ch1.send(100);

    const ready = try sel.wait(1000);
    try std.testing.expectEqual(@as(usize, 0), ready);
}

test "Selector second of two channels ready" {
    // S1.3: Second of two channels ready
    const Ch = Channel(u32, 4);
    const Sel = Selector(3, 12);

    var ch1 = try Ch.init();
    defer ch1.deinit();
    var ch2 = try Ch.init();
    defer ch2.deinit();
    var sel = try Sel.init();
    defer sel.deinit();

    const idx1 = try sel.addRecv(&ch1);
    const idx2 = try sel.addRecv(&ch2);
    _ = idx1;
    _ = idx2;

    try ch2.send(200);

    const ready = try sel.wait(1000);
    try std.testing.expectEqual(@as(usize, 1), ready);
}

test "Selector timeout" {
    // S1.6: Timeout before channel ready
    const Ch = Channel(u32, 4);
    const Sel = Selector(2, 8);

    var ch = try Ch.init();
    defer ch.deinit();
    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);
    const timeout_idx = try sel.addTimeout(50);

    const start = std.time.milliTimestamp();
    const ready = try sel.wait(null);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expectEqual(timeout_idx, ready);
    try std.testing.expect(elapsed >= 40); // Allow some tolerance
}

test "Selector empty returns error" {
    // S3.1: Empty selector wait returns error
    const Sel = Selector(2, 8);

    var sel = try Sel.init();
    defer sel.deinit();

    const result = sel.wait(10);
    try std.testing.expectError(error.Empty, result);
}

test "Selector close wakes up selector" {
    // S2.3: Closed channel wakes up selector
    const Ch = Channel(u32, 4);
    const Sel = Selector(2, 8);

    var ch = try Ch.init();
    defer ch.deinit();
    var sel = try Sel.init();
    defer sel.deinit();

    const idx = try sel.addRecv(&ch);
    _ = idx;

    // Close channel without sending
    ch.close();

    // Selector should return immediately (channel is closed)
    const start = std.time.milliTimestamp();
    const ready = sel.wait(500) catch 2; // 2 is max_sources
    const elapsed = std.time.milliTimestamp() - start;

    // Should return quickly (< 100ms) because close wakes selector
    try std.testing.expect(elapsed < 100);
    _ = ready;
}

test "Selector channel with pre-existing data" {
    // S2.2: Channel with pre-existing data
    const Ch = Channel(u32, 4);
    const Sel = Selector(2, 8);

    var ch = try Ch.init();
    defer ch.deinit();

    // Send before adding to selector
    try ch.send(999);

    var sel = try Sel.init();
    defer sel.deinit();

    const idx = try sel.addRecv(&ch);
    _ = idx;

    // Should return immediately because data already exists
    const start = std.time.milliTimestamp();
    const ready = try sel.wait(1000);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expectEqual(@as(usize, 0), ready);
    try std.testing.expect(elapsed < 50); // Should be immediate
}

// Helper constant
const max_sources = 2;
