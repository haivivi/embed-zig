//! Selector benchmark binary (manual)

const std = @import("std");
const platform = @import("std_impl");

const Channel = platform.channel.Channel;
const Selector = platform.selector.Selector;

fn benchmarkChannelThroughput(message_count: usize) !void {
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
    const throughput = @as(f64, @floatFromInt(message_count)) / elapsed_s / 1e6;

    std.debug.print("Channel throughput: {d} messages in {d:.3}s = {d:.2} M msg/s\n", .{
        message_count,
        elapsed_s,
        throughput,
    });
    std.debug.print("Received count: {d}\n", .{received});
}

fn benchmarkSelectorWakeup(iterations: usize) !void {
    const Ch = Channel(u64, 4);
    const Sel = Selector(2);

    var ch = try Ch.init();
    defer ch.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch);

    var total_latency_ns: i64 = 0;

    for (0..iterations) |_| {
        const send_time: i64 = @intCast(std.time.nanoTimestamp());

        const t = try std.Thread.spawn(.{}, struct {
            fn run(c: *Ch) void {
                c.send(1) catch {};
            }
        }.run, .{&ch});

        _ = try sel.wait(1000);
        const recv_time: i64 = @intCast(std.time.nanoTimestamp());
        _ = ch.recv();

        total_latency_ns += recv_time - send_time;
        t.join();
    }

    const avg_latency_us = @as(f64, @floatFromInt(total_latency_ns)) /
        @as(f64, @floatFromInt(iterations)) / 1000.0;
    std.debug.print("Selector average wakeup latency: {d:.2} us\n", .{avg_latency_us});
}

pub fn main() !void {
    std.debug.print("selector benchmark start\n", .{});

    try benchmarkChannelThroughput(1_000_000);
    try benchmarkSelectorWakeup(1000);

    std.debug.print("selector benchmark done\n", .{});
}
