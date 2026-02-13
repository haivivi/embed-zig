//! NTP Integration Test - Tests NTP queries on host
//!
//! Run with: zig build run-test

const std = @import("std");
const ntp = @import("src/ntp.zig");
const std_impl = @import("std_impl");

const print = std.debug.print;

/// Use std_impl socket (implements trait.socket interface)
const Socket = std_impl.socket.Socket;

const Client = ntp.Client(Socket);

/// Get current monotonic time in milliseconds
fn nowMs() u64 {
    return @intCast(@divFloor(std.time.nanoTimestamp(), 1_000_000));
}

pub fn main() !void {
    print("\n=== NTP Integration Test ===\n\n", .{});

    const servers = [_]struct {
        name: []const u8,
        addr: [4]u8,
    }{
        .{ .name = "Cloudflare (time.cloudflare.com)", .addr = ntp.Servers.cloudflare },
        .{ .name = "Aliyun (ntp.aliyun.com)", .addr = ntp.Servers.aliyun },
        .{ .name = "Google (time.google.com)", .addr = ntp.Servers.google },
    };

    for (servers) |server| {
        print("--- Testing {s} ({d}.{d}.{d}.{d}) ---\n", .{
            server.name,
            server.addr[0],
            server.addr[1],
            server.addr[2],
            server.addr[3],
        });

        var client = Client{
            .server = server.addr,
            .timeout_ms = 5000,
        };

        // Record T1 (local time before query)
        const t1 = nowMs();
        const t1_signed: i64 = @intCast(t1);

        if (client.query(t1_signed)) |resp| {
            // Record T4 (local time after query)
            const t4 = nowMs();
            const t4_signed: i64 = @intCast(t4);

            // Calculate offset: ((T2 - T1) + (T3 - T4)) / 2
            const offset = @divFloor(
                (resp.receive_time_ms - t1_signed) + (resp.transmit_time_ms - t4_signed),
                2,
            );

            // Calculate round-trip delay: (T4 - T1) - (T3 - T2)
            const rtt = (t4_signed - t1_signed) - (resp.transmit_time_ms - resp.receive_time_ms);

            // Current time = T4 + offset
            const current_time_ms = t4_signed + offset;

            var time_buf: [32]u8 = undefined;
            const formatted = ntp.formatTime(current_time_ms, &time_buf);

            print("  Stratum: {d}\n", .{resp.stratum});
            print("  T2 (receive):  {d} ms\n", .{resp.receive_time_ms});
            print("  T3 (transmit): {d} ms\n", .{resp.transmit_time_ms});
            print("  Round-trip:    {d} ms\n", .{rtt});
            print("  Offset:        {d} ms\n", .{offset});
            print("  Current time:  {s}\n", .{formatted});
            print("  Epoch ms:      {d}\n", .{current_time_ms});
        } else |err| {
            print("  ERROR: {}\n", .{err});
        }

        print("\n", .{});
    }

    // Simple API test
    print("--- Simple API Test (getTime) ---\n", .{});
    {
        var client = Client{
            .server = ntp.Servers.cloudflare,
            .timeout_ms = 5000,
        };

        const local_time: i64 = @intCast(nowMs());
        if (client.getTime(local_time)) |time_ms| {
            var time_buf: [32]u8 = undefined;
            const formatted = ntp.formatTime(time_ms, &time_buf);
            print("  Server time: {s}\n", .{formatted});
            print("  Epoch ms:    {d}\n", .{time_ms});
        } else |err| {
            print("  ERROR: {}\n", .{err});
        }
    }

    print("\n=== All Tests Complete ===\n", .{});
}
