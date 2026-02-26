//! Selector Latency Benchmark

const std = @import("std");
const platform = @import("std_impl");
const Channel = platform.channel.Channel;
const Selector = platform.selector.Selector;

// Helper for API compatibility: std Selector now requires (max_sources, max_events)
// For FreeRTOS platforms, max_events must equal the sum of all channels' queue_set_slots.
fn makeSelector(comptime max_sources: usize, comptime channel_capacity: usize) type {
    const channel_slots = channel_capacity + 1; // data queue + close_notify queue
    return Selector(max_sources, max_sources * channel_slots);
}

test "Selector immediate latency 100 iterations" {
    const Ch = Channel(u64, 4);
    const Sel = makeSelector(2, 4);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);

    var total_latency_ns: i64 = 0;

    for (0..100) |_| {
        sel.reset();
        _ = try sel.addRecv(&ch);

        var ready = std.atomic.Value(bool).init(false);
        var start_send = std.atomic.Value(bool).init(false);

        const t = try std.Thread.spawn(.{}, struct {
            fn run(c: *Ch, r: *std.atomic.Value(bool), s: *std.atomic.Value(bool)) void {
                r.store(true, .release);
                while (!s.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }
                c.send(1) catch {};
            }
        }.run, .{ &ch, &ready, &start_send });

        while (!ready.load(.acquire)) {
            std.atomic.spinLoopHint();
        }

        const send_time: i64 = @intCast(std.time.nanoTimestamp());
        start_send.store(true, .release);

        _ = try sel.wait(1000);
        const recv_time: i64 = @intCast(std.time.nanoTimestamp());

        _ = ch.recv();

        total_latency_ns += recv_time - send_time;
        t.join();
    }

    const avg_latency_ns = @as(f64, @floatFromInt(total_latency_ns)) / 100.0;
    const avg_latency_us = avg_latency_ns / 1000.0;

    std.debug.print("\nSelector immediate wakeup latency: {d:.2} us ({d:.0} ns)\n", .{ avg_latency_us, avg_latency_ns });
}
