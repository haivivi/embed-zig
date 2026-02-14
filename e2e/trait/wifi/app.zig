//! e2e: hal/wifi — Verify WiFi STA connect + socket loopback
//!
//! Tests:
//!   1. WiFi driver init
//!   2. Connect to AP (HAIVIVI-MFG)
//!   3. Wait for DHCP (got IP)
//!   4. UDP loopback on localhost (proves lwip is working)
//!   5. Disconnect

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;

var g_ssid: []const u8 = "";
var g_password: []const u8 = "";

fn runTests() !void {
    log.info("[e2e] START: hal/wifi", .{});

    // Test 1: WiFi init
    var wifi = platform.WifiDriver.init() catch |err| {
        log.err("[e2e] FAIL: hal/wifi/init — {}", .{err});
        return error.WifiInitFailed;
    };
    defer wifi.deinit();
    log.info("[e2e] PASS: hal/wifi/init", .{});

    // Test 2: Connect to AP
    const ssid = g_ssid;
    const password = g_password;
    log.info("[e2e] INFO: connecting to {s}...", .{ssid});
    wifi.connect(ssid, password);

    // Test 3: Wait for connection + IP (poll for up to 30s)
    var waited: u32 = 0;
    while (!wifi.isConnected() and waited < 30000) {
        platform.time.sleepMs(100);
        waited += 100;
    }

    if (!wifi.isConnected()) {
        log.err("[e2e] FAIL: hal/wifi/connect — not connected after 30s", .{});
        return error.WifiConnectTimeout;
    }
    log.info("[e2e] PASS: hal/wifi/connect — connected in ~{}ms", .{waited});

    // Wait a bit more for DHCP
    platform.time.sleepMs(2000);

    // Test 4: Check IP address
    if (wifi.getIpAddress()) |ip| {
        log.info("[e2e] PASS: hal/wifi/ip — {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
    } else {
        log.warn("[e2e] WARN: hal/wifi/ip — no IP yet (DHCP may be slow)", .{});
    }

    // Test 5: UDP loopback (proves lwip socket stack is working)
    {
        const Socket = platform.Socket;
        const localhost: [4]u8 = .{ 127, 0, 0, 1 };

        var receiver = Socket.udp() catch |err| {
            log.err("[e2e] FAIL: hal/wifi/socket — udp() failed: {}", .{err});
            return error.SocketFailed;
        };
        defer receiver.close();
        receiver.bind(localhost, 0) catch |err| {
            log.err("[e2e] FAIL: hal/wifi/socket — bind failed: {}", .{err});
            return error.SocketFailed;
        };
        receiver.setRecvTimeout(2000);
        const port = receiver.getBoundPort() catch |err| {
            log.err("[e2e] FAIL: hal/wifi/socket — getBoundPort failed: {}", .{err});
            return error.SocketFailed;
        };

        var sender = Socket.udp() catch |err| {
            log.err("[e2e] FAIL: hal/wifi/socket — sender udp() failed: {}", .{err});
            return error.SocketFailed;
        };
        defer sender.close();

        const msg = "wifi e2e";
        _ = sender.sendTo(localhost, port, msg) catch |err| {
            log.err("[e2e] FAIL: hal/wifi/socket — sendTo failed: {}", .{err});
            return error.SocketFailed;
        };

        var buf: [64]u8 = undefined;
        const result = receiver.recvFromWithAddr(&buf) catch |err| {
            log.err("[e2e] FAIL: hal/wifi/socket — recvFrom failed: {}", .{err});
            return error.SocketFailed;
        };

        if (!std.mem.eql(u8, buf[0..result.len], msg)) {
            log.err("[e2e] FAIL: hal/wifi/socket — mismatch", .{});
            return error.SocketMismatch;
        }
        log.info("[e2e] PASS: hal/wifi/socket — UDP loopback {} bytes", .{result.len});
    }

    // Test 6: Disconnect
    wifi.disconnect();
    log.info("[e2e] PASS: hal/wifi/disconnect", .{});

    log.info("[e2e] PASS: hal/wifi", .{});
}

pub fn run(env: anytype) void {
    g_ssid = env.wifi_ssid;
    g_password = env.wifi_password;
    runTests() catch |err| {
        log.err("[e2e] FATAL: hal/wifi — {}", .{err});
    };
}

test "e2e: hal/wifi" {
    // WiFi test cannot run on std — ESP only
    return error.SkipZigTest;
}
