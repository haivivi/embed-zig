//! macOS BLE Benchmark — Cross-Platform Throughput Test
//!
//! Measures GATT throughput between macOS and ESP32.
//! Supports two modes:
//!   --server: Advertise GATT service, send notifications, receive writes
//!   --client: Connect to "ZigBLE", send writes, receive notifications
//!
//! Service 0xFFE0 (same as ESP32 ble_throughput):
//!   0xFFE1: Write Without Response (client → server)
//!   0xFFE2: Notify (server → client)
//!
//! Usage:
//!   zig build run -- --server   # mac-server ↔ esp-client
//!   zig build run -- --client   # mac-client ↔ esp-server
//!
//! Memory usage is reported at the end.

const std = @import("std");
const cb = @import("cb");

const SVC = "FFE0";
const CHR_WRITE = "FFE1";
const CHR_NOTIFY = "FFE2";
const TARGET_NAME = "ZigBLE";
const ROUND_SECS: u64 = 10;
const PAYLOAD_SIZE: usize = 244;

// ============================================================================
// Stats
// ============================================================================

var tx_bytes: u64 = 0;
var tx_packets: u64 = 0;
var rx_bytes: u64 = 0;
var rx_packets: u64 = 0;

var device_found = false;
var is_connected = false;
var target_uuid: [64]u8 = undefined;
var target_uuid_len: usize = 0;
var notify_enabled = false;

// ============================================================================
// Memory tracking
// ============================================================================

fn getMemoryUsageMB() f64 {
    // macOS: use resident set size from mach API (rough estimate from process info)
    // Fallback: use Zig's page allocator tracking
    return 0; // will be measured via /usr/bin/ps
}

fn printMemoryReport(role: []const u8) void {
    std.debug.print("\n--- Memory Report ({s}) ---\n", .{role});
    // getrusage(RUSAGE_SELF=0) returns rusage directly in Zig 0.15
    const usage = std.posix.getrusage(0); // RUSAGE_SELF
    // ru_maxrss on macOS is in bytes
    const rss_kb = @as(u64, @intCast(usage.maxrss)) / 1024;
    std.debug.print("Peak RSS: {} KB ({d:.2} MB)\n", .{ rss_kb, @as(f64, @floatFromInt(rss_kb)) / 1024.0 });
}

// ============================================================================
// Callbacks
// ============================================================================

fn onDeviceFound(name: [*c]const u8, uuid: [*c]const u8, _: c_int) callconv(.c) void {
    const name_str = std.mem.span(name);
    if (std.mem.eql(u8, name_str, TARGET_NAME)) {
        const uuid_str = std.mem.span(uuid);
        const len = @min(uuid_str.len, target_uuid.len);
        @memcpy(target_uuid[0..len], uuid_str[0..len]);
        target_uuid_len = len;
        device_found = true;
        std.debug.print("Found \"{s}\" (UUID: {s})\n", .{ name_str, uuid_str });
    }
}

fn onConnection(connected: bool) callconv(.c) void {
    is_connected = connected;
    std.debug.print("[conn] {}\n", .{connected});
}

fn onNotification(_: [*c]const u8, _: [*c]const u8, _: [*c]const u8, len: u16) callconv(.c) void {
    rx_bytes += len;
    rx_packets += 1;
}

fn onWrite(_: [*c]const u8, _: [*c]const u8, _: [*c]const u8, len: u16) callconv(.c) void {
    rx_bytes += len;
    rx_packets += 1;
}

fn onSubscribe(_: [*c]const u8, chr: [*c]const u8, subscribed: bool) callconv(.c) void {
    const chr_str = std.mem.span(chr);
    if (std.mem.eql(u8, chr_str, CHR_NOTIFY)) {
        notify_enabled = subscribed;
        std.debug.print("[subscribe] notify={}\n", .{subscribed});
    }
}

// ============================================================================
// Server Mode
// ============================================================================

fn runServer() !void {
    std.debug.print("=== macOS BLE Benchmark: SERVER ===\n", .{});
    std.debug.print("Service: 0x{s} (same as ESP32 ble_throughput)\n", .{SVC});

    cb.Peripheral.setWriteCallback(onWrite);
    cb.Peripheral.setSubscribeCallback(onSubscribe);
    cb.Peripheral.setConnectionCallback(onConnection);

    try cb.Peripheral.init();
    std.debug.print("CoreBluetooth ready.\n", .{});

    const chr_uuids = [_][*c]const u8{ CHR_WRITE, CHR_NOTIFY };
    const chr_props = [_]u8{
        cb.PROP_WRITE | cb.PROP_WRITE_NO_RSP,
        cb.PROP_READ | cb.PROP_NOTIFY,
    };
    try cb.Peripheral.addService(SVC, &chr_uuids, &chr_props, 2);

    try cb.Peripheral.startAdvertising(TARGET_NAME);
    std.debug.print("Advertising \"{s}\"... waiting for ESP32 client\n\n", .{TARGET_NAME});

    // Wait for connection
    while (!is_connected) cb.runLoopOnce(100);
    std.debug.print("Connected! Waiting for subscribe...\n", .{});

    // Wait for subscribe
    var wait: u32 = 0;
    while (!notify_enabled and wait < 100) : (wait += 1) cb.runLoopOnce(100);

    if (!notify_enabled) {
        std.debug.print("Timeout waiting for subscribe\n", .{});
        return;
    }

    // Benchmark: send notifications
    std.debug.print("\n=== Throughput: Notifications (server→client) + Writes (client→server) ===\n", .{});
    std.debug.print("Duration: {} seconds, payload: {} bytes\n\n", .{ ROUND_SECS, PAYLOAD_SIZE });

    var payload: [PAYLOAD_SIZE]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    tx_bytes = 0;
    tx_packets = 0;
    rx_bytes = 0;
    rx_packets = 0;

    const start = std.time.milliTimestamp();
    var last_print = start;

    while (std.time.milliTimestamp() - start < @as(i64, @intCast(ROUND_SECS * 1000))) {
        // Send notification
        if (notify_enabled) {
            cb.Peripheral.notify(SVC, CHR_NOTIFY, &payload) catch {};
            tx_bytes += PAYLOAD_SIZE;
            tx_packets += 1;
        }

        cb.runLoopOnce(1); // pump events

        const now = std.time.milliTimestamp();
        if (now - last_print >= 1000) {
            const elapsed_s = @as(f64, @floatFromInt(now - start)) / 1000.0;
            const tx_kbs = @as(f64, @floatFromInt(tx_bytes)) / 1024.0 / elapsed_s;
            const rx_kbs = @as(f64, @floatFromInt(rx_bytes)) / 1024.0 / elapsed_s;
            std.debug.print("[{d:.0}s] TX: {d:.1} KB/s ({} pkts) | RX: {d:.1} KB/s ({} pkts)\n", .{
                elapsed_s, tx_kbs, tx_packets, rx_kbs, rx_packets,
            });
            last_print = now;
        }
    }

    const total_s = @as(f64, @floatFromInt(ROUND_SECS));
    std.debug.print("\n--- Server Summary ---\n", .{});
    std.debug.print("TX (notify→client): {d:.1} KB/s ({} bytes, {} pkts)\n", .{
        @as(f64, @floatFromInt(tx_bytes)) / 1024.0 / total_s, tx_bytes, tx_packets,
    });
    std.debug.print("RX (write←client):  {d:.1} KB/s ({} bytes, {} pkts)\n", .{
        @as(f64, @floatFromInt(rx_bytes)) / 1024.0 / total_s, rx_bytes, rx_packets,
    });

    printMemoryReport("server");
}

// ============================================================================
// Client Mode
// ============================================================================

fn runClient() !void {
    std.debug.print("=== macOS BLE Benchmark: CLIENT ===\n", .{});
    std.debug.print("Connecting to \"{s}\" (ESP32 server)\n\n", .{TARGET_NAME});

    cb.Central.setDeviceFoundCallback(onDeviceFound);
    cb.Central.setConnectionCallback(onConnection);
    cb.Central.setNotificationCallback(onNotification);

    try cb.Central.init();
    std.debug.print("CoreBluetooth ready.\n", .{});

    try cb.Central.scanStart(null);
    std.debug.print("Scanning...\n", .{});

    var scan_time: u32 = 0;
    while (!device_found and scan_time < 100) : (scan_time += 1) {
        cb.runLoopOnce(100);
    }
    cb.Central.scanStop();

    if (!device_found) {
        std.debug.print("ESP32 not found! Is ble_throughput running?\n", .{});
        return;
    }

    target_uuid[target_uuid_len] = 0;
    cb.Central.connect(&target_uuid) catch {
        std.debug.print("Connect failed\n", .{});
        return;
    };

    var conn_time: u32 = 0;
    while (!is_connected and conn_time < 100) : (conn_time += 1) {
        cb.runLoopOnce(100);
    }
    if (!is_connected) {
        std.debug.print("Connection timeout\n", .{});
        return;
    }

    // Wait for service discovery
    for (0..20) |_| cb.runLoopOnce(100);

    // Subscribe to notifications
    _ = cb.Central.subscribe(SVC, CHR_NOTIFY) catch {};
    for (0..10) |_| cb.runLoopOnce(100);

    // Benchmark
    std.debug.print("\n=== Throughput: Writes (client→server) + Notifications (server→client) ===\n", .{});
    std.debug.print("Duration: {} seconds, payload: {} bytes\n\n", .{ ROUND_SECS, PAYLOAD_SIZE });

    var payload: [PAYLOAD_SIZE]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    tx_bytes = 0;
    tx_packets = 0;
    rx_bytes = 0;
    rx_packets = 0;

    const start = std.time.milliTimestamp();
    var last_print = start;

    while (std.time.milliTimestamp() - start < @as(i64, @intCast(ROUND_SECS * 1000))) {
        // Send write without response
        cb.Central.writeNoResponse(SVC, CHR_WRITE, &payload) catch {};
        tx_bytes += PAYLOAD_SIZE;
        tx_packets += 1;

        cb.runLoopOnce(1);

        const now = std.time.milliTimestamp();
        if (now - last_print >= 1000) {
            const elapsed_s = @as(f64, @floatFromInt(now - start)) / 1000.0;
            const tx_kbs = @as(f64, @floatFromInt(tx_bytes)) / 1024.0 / elapsed_s;
            const rx_kbs = @as(f64, @floatFromInt(rx_bytes)) / 1024.0 / elapsed_s;
            std.debug.print("[{d:.0}s] TX: {d:.1} KB/s ({} pkts) | RX: {d:.1} KB/s ({} pkts)\n", .{
                elapsed_s, tx_kbs, tx_packets, rx_kbs, rx_packets,
            });
            last_print = now;
        }
    }

    const total_s = @as(f64, @floatFromInt(ROUND_SECS));
    std.debug.print("\n--- Client Summary ---\n", .{});
    std.debug.print("TX (write→server):    {d:.1} KB/s ({} bytes, {} pkts)\n", .{
        @as(f64, @floatFromInt(tx_bytes)) / 1024.0 / total_s, tx_bytes, tx_packets,
    });
    std.debug.print("RX (notify←server):   {d:.1} KB/s ({} bytes, {} pkts)\n", .{
        @as(f64, @floatFromInt(rx_bytes)) / 1024.0 / total_s, rx_bytes, rx_packets,
    });

    // Cleanup
    _ = cb.Central.unsubscribe(SVC, CHR_NOTIFY) catch {};
    cb.Central.disconnect();
    for (0..10) |_| cb.runLoopOnce(100);

    printMemoryReport("client");
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("==========================================\n", .{});
    std.debug.print("macOS BLE Benchmark (CoreBluetooth)\n", .{});
    std.debug.print("==========================================\n\n", .{});

    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    const mode = args.next() orelse {
        std.debug.print("Usage: macos_ble_bench --server|--client\n", .{});
        std.debug.print("  --server  ESP32 client connects to this Mac\n", .{});
        std.debug.print("  --client  This Mac connects to ESP32 server\n", .{});
        return;
    };

    if (std.mem.eql(u8, mode, "--server")) {
        try runServer();
    } else if (std.mem.eql(u8, mode, "--client")) {
        try runClient();
    } else {
        std.debug.print("Unknown mode: {s}\n", .{mode});
        std.debug.print("Usage: macos_ble_bench --server|--client\n", .{});
    }
}
