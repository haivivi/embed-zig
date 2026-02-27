//! Minimal test
const std = @import("std");
const platform = @import("std_impl");
const Channel = platform.channel.Channel;

test "Channel send then tryRecv" {
    std.debug.print("Starting test...\n", .{});
    const Ch = Channel(u32, 4);
    var ch = try Ch.init();
    defer ch.deinit();

    std.debug.print("Sending...\n", .{});
    try ch.send(42);
    std.debug.print("Sent!\n", .{});

    std.debug.print("TryReceiving...\n", .{});
    const val = ch.tryRecv();
    std.debug.print("Received: {any}\n", .{val});

    std.debug.print("Done!\n", .{});
}
