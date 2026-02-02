//! NTP Time Sync Example
//!
//! Demonstrates NTP time synchronization on ESP32.
//! Connects to WiFi, queries NTP server, and displays synchronized time.

const std = @import("std");
const ntp = @import("ntp");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const BUILD_TAG = "ntp_sync_test_v1";

/// NTP Client using platform socket
const NtpClient = ntp.Client(Board.socket);

/// Application state machine
const AppState = enum {
    connecting,
    connected,
    syncing,
    synced,
    done,
};

/// Run with env from main (contains WiFi credentials)
pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  NTP Time Sync Test", .{});
    log.info("  Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("Connecting to WiFi: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var state: AppState = .connecting;

    while (Board.isRunning()) {
        b.poll();

        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    switch (wifi_event) {
                        .connected => log.info("WiFi connected (waiting for IP...)", .{}),
                        .disconnected => |reason| {
                            log.warn("WiFi disconnected: {}", .{reason});
                            state = .connecting;
                        },
                        .connection_failed => |reason| {
                            log.err("WiFi failed: {}", .{reason});
                            return;
                        },
                        else => {},
                    }
                },
                .net => |net_event| {
                    switch (net_event) {
                        .dhcp_bound, .dhcp_renewed => |info| {
                            var buf: [16]u8 = undefined;
                            const ip_str = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
                                info.ip[0], info.ip[1], info.ip[2], info.ip[3],
                            }) catch "?.?.?.?";
                            log.info("Got IP: {s}", .{ip_str});
                            state = .connected;
                        },
                        .ip_lost => {
                            log.warn("IP lost", .{});
                            state = .connecting;
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        switch (state) {
            .connecting => {},
            .connected => {
                Board.time.sleepMs(500);
                state = .syncing;
            },
            .syncing => {
                testNtpSync();
                state = .synced;
            },
            .synced => {
                log.info("", .{});
                log.info("=== NTP Sync Complete ===", .{});
                state = .done;
            },
            .done => {},
        }

        Board.time.sleepMs(10);
    }
}

/// Test NTP synchronization with race query (concurrent multi-server)
fn testNtpSync() void {
    log.info("", .{});
    log.info("=== NTP Race Query Test ===", .{});
    log.info("Querying multiple servers simultaneously...", .{});

    // Test 1: Global server list (Cloudflare, Google, Aliyun)
    log.info("", .{});
    log.info("--- Race: Global Servers ---", .{});
    log.info("Servers: Cloudflare, Google, Aliyun", .{});
    testRaceQuery(&ntp.ServerLists.global);

    // Test 2: China-optimized server list
    log.info("", .{});
    log.info("--- Race: China Servers ---", .{});
    log.info("Servers: Aliyun, Tencent, NTSC, Cloudflare", .{});
    testRaceQuery(&ntp.ServerLists.china);

    // Test 3: Overseas server list
    log.info("", .{});
    log.info("--- Race: Overseas Servers ---", .{});
    log.info("Servers: Cloudflare, Google x4, Apple", .{});
    testRaceQuery(&ntp.ServerLists.overseas);

    // Test 4: Simple getTimeRace() API
    log.info("", .{});
    log.info("--- Simple getTimeRace() API ---", .{});
    {
        var client = NtpClient{ .timeout_ms = 5000 };
        const local_time: i64 = @intCast(Board.time.getTimeMs());

        if (client.getTimeRace(local_time)) |time_ms| {
            var time_buf: [32]u8 = undefined;
            const formatted = ntp.formatTime(time_ms, &time_buf);
            log.info("Time (first responder): {s}", .{formatted});
        } else |err| {
            log.err("getTimeRace failed: {}", .{err});
        }
    }
}

/// Helper to test race query with a server list
fn testRaceQuery(servers: []const ntp.Ipv4Address) void {
    var client = NtpClient{ .timeout_ms = 5000 };

    // Record T1 (local monotonic time before query)
    const t1 = Board.time.getTimeMs();
    const t1_signed: i64 = @intCast(t1);

    if (client.queryRace(t1_signed, servers)) |resp| {
        // Record T4 (local monotonic time after query)
        const t4 = Board.time.getTimeMs();
        const t4_signed: i64 = @intCast(t4);

        // Calculate offset: ((T2 - T1) + (T3 - T4)) / 2
        const offset = @divFloor(
            (resp.receive_time_ms - t1_signed) + (resp.transmit_time_ms - t4_signed),
            2,
        );

        // Calculate round-trip delay
        const rtt = (t4_signed - t1_signed) - (resp.transmit_time_ms - resp.receive_time_ms);

        // Current time = T4 + offset
        const current_time_ms = t4_signed + offset;

        var time_buf: [32]u8 = undefined;
        const formatted = ntp.formatTime(current_time_ms, &time_buf);

        log.info("Stratum: {d}, RTT: {d} ms", .{ resp.stratum, rtt });
        log.info("Time: {s}", .{formatted});
    } else |err| {
        log.err("Race query failed: {}", .{err});
    }
}
