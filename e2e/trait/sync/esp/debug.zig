//! ESP32 Channel Debug Test
const std = @import("std");
const idf = @import("idf");

const Channel = @import("impl").channel.Channel;

pub fn run(_: anytype) void {
    idf.log.info("=== Channel Debug Test ===", .{});

    // Test 1: Basic init/deinit
    idf.log.info("Test 1: init/deinit", .{});
    {
        const Ch = Channel(u32, 4);
        var ch = Ch.init() catch |err| {
            idf.log.err("init failed: {}", .{err});
            return;
        };
        ch.deinit();
        idf.log.info("  PASS: init/deinit", .{});
    }

    // Test 2: Single thread send/recv (no threading)
    idf.log.info("Test 2: single thread send/recv", .{});
    {
        const Ch = Channel(u32, 4);
        var ch = Ch.init() catch unreachable;
        defer ch.deinit();

        // Send some items
        ch.send(1) catch unreachable;
        ch.send(2) catch unreachable;
        ch.send(3) catch unreachable;
        idf.log.info("  Sent 3 items", .{});

        // Receive them
        const v1 = ch.recv();
        idf.log.info("  Received: {}", .{v1.?});

        const v2 = ch.recv();
        idf.log.info("  Received: {}", .{v2.?});

        const v3 = ch.recv();
        idf.log.info("  Received: {}", .{v3.?});

        idf.log.info("  PASS: single thread", .{});
    }

    // Test 3: Close test
    idf.log.info("Test 3: close test", .{});
    {
        const Ch = Channel(u32, 4);
        var ch = Ch.init() catch unreachable;
        defer ch.deinit();

        ch.send(42) catch unreachable;
        ch.close();
        idf.log.info("  Sent 1 item and closed", .{});

        // Should still be able to recv
        const v = ch.recv();
        if (v == 42) {
            idf.log.info("  Received: {} (correct)", .{v.?});
        } else {
            idf.log.err("  FAIL: expected 42, got {}", .{v});
            return;
        }

        // Next recv should return null
        const v2 = ch.recv();
        if (v2 == null) {
            idf.log.info("  PASS: recv after close returns null", .{});
        } else {
            idf.log.err("  FAIL: expected null, got {}", .{v2});
            return;
        }
    }

    // Test 4: Multi-thread (original test)
    idf.log.info("Test 4: multi-thread", .{});
    {
        const Ch = Channel(u32, 16);
        var ch = Ch.init() catch unreachable;
        defer ch.deinit();

        idf.log.info("  Creating producer thread...", .{});

        // Create producer thread
        const thread = idf.runtime.Thread.spawn(.{}, struct {
            fn run(c: *Ch) void {
                idf.log.info("  [producer] started", .{});

                for (0..5) |i| {
                    idf.log.info("  [producer] sending {}", .{i});
                    c.send(@intCast(i)) catch |err| {
                        idf.log.err("  [producer] send failed: {}", .{err});
                        return;
                    };
                    idf.log.info("  [producer] sent {}", .{i});
                }

                idf.log.info("  [producer] closing channel", .{});
                c.close();
                idf.log.info("  [producer] done", .{});
            }
        }.run, .{&ch}) catch |err| {
            idf.log.err("  spawn failed: {}", .{err});
            return;
        };

        idf.log.info("  Thread created, detaching...", .{});
        thread.detach();

        idf.log.info("  Receiving...", .{});
        var received: u32 = 0;
        var count: u32 = 0;

        while (ch.recv()) |item| {
            idf.log.info("  [consumer] received: {}", .{item});
            count += 1;
            if (item != received) {
                idf.log.err("  FAIL: expected {}, got {}", .{ received, item });
                return;
            }
            received += 1;

            // Safety limit
            if (count > 10) {
                idf.log.err("  FAIL: too many items", .{});
                return;
            }
        }

        idf.log.info("  Total received: {}", .{count});
        if (count == 5) {
            idf.log.info("  PASS: multi-thread", .{});
        } else {
            idf.log.err("  FAIL: expected 5 items, got {}", .{count});
        }
    }

    idf.log.info("=== All tests complete ===", .{});
}
