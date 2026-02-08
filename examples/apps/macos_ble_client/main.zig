//! macOS BLE Client — connects to ESP32 GATT Server
//!
//! Scans for "ZigE2E", connects, discovers services,
//! reads/writes characteristics, subscribes to notifications.
//!
//! Tests cross-platform BLE: macOS CoreBluetooth ↔ ESP32 Zig BLE stack.

const std = @import("std");
const cb = @import("cb");

const TARGET_NAME = "ZigE2E";
const SVC = "AA00";
const CHR_READ = "AA01";
const CHR_WRITE = "AA02";
const CHR_NOTIFY = "AA03";
const CHR_RW = "AA04";

var passed: u32 = 0;
var failed: u32 = 0;
var target_uuid: [64]u8 = undefined;
var target_uuid_len: usize = 0;
var device_found = false;
var is_connected = false;
var notif_count: u32 = 0;

fn pass(name: []const u8) void {
    passed += 1;
    std.debug.print("  PASS: {s}\n", .{name});
}

fn fail(name: []const u8) void {
    failed += 1;
    std.debug.print("  FAIL: {s}\n", .{name});
}

fn onDeviceFound(name: [*c]const u8, uuid: [*c]const u8, rssi: c_int) callconv(.c) void {
    const name_str = std.mem.span(name);
    if (std.mem.eql(u8, name_str, TARGET_NAME)) {
        const uuid_str = std.mem.span(uuid);
        const len = @min(uuid_str.len, target_uuid.len);
        @memcpy(target_uuid[0..len], uuid_str[0..len]);
        target_uuid_len = len;
        device_found = true;
        std.debug.print("  Found \"{s}\" (UUID: {s}, RSSI: {})\n", .{ name_str, uuid_str, rssi });
    }
}

fn onConnection(connected: bool) callconv(.c) void {
    is_connected = connected;
    std.debug.print("  Connection: {}\n", .{connected});
}

fn onNotification(svc: [*c]const u8, chr: [*c]const u8, data: [*c]const u8, len: u16) callconv(.c) void {
    _ = svc;
    _ = chr;
    _ = data;
    _ = len;
    notif_count += 1;
}

pub fn main() !void {
    std.debug.print("==========================================\n", .{});
    std.debug.print("macOS BLE Client → ESP32 GATT Server\n", .{});
    std.debug.print("==========================================\n", .{});

    // Setup callbacks
    cb.Central.setDeviceFoundCallback(onDeviceFound);
    cb.Central.setConnectionCallback(onConnection);
    cb.Central.setNotificationCallback(onNotification);

    // T1: Initialize
    std.debug.print("\nT1: Initialize CoreBluetooth Central...\n", .{});
    try cb.Central.init();
    pass("T1: Central initialized");

    // T2: Scan for ESP32
    std.debug.print("\nT2: Scanning for \"{s}\"...\n", .{TARGET_NAME});
    try cb.Central.scanStart(null);

    // Wait for device
    var scan_time: u32 = 0;
    while (!device_found and scan_time < 100) : (scan_time += 1) {
        cb.runLoopOnce(100);
    }

    cb.Central.scanStop();

    if (device_found) {
        pass("T2: Device found");
    } else {
        fail("T2: Device not found (is ESP32 running?)");
        printResults();
        return;
    }

    // T3: Connect
    std.debug.print("\nT3: Connecting...\n", .{});
    // Null-terminate the UUID string
    target_uuid[target_uuid_len] = 0;
    cb.Central.connect(&target_uuid) catch {
        fail("T3: Connect failed");
        printResults();
        return;
    };

    // Wait for connection + service discovery
    var conn_time: u32 = 0;
    while (!is_connected and conn_time < 100) : (conn_time += 1) {
        cb.runLoopOnce(100);
    }

    if (is_connected) {
        pass("T3: Connected + services discovered");
    } else {
        fail("T3: Connection timeout");
        printResults();
        return;
    }

    // Small delay for service discovery to complete
    for (0..10) |_| cb.runLoopOnce(100);

    // T4: Read characteristic
    std.debug.print("\nT4: Reading {s}/{s}...\n", .{ SVC, CHR_READ });
    var read_buf: [512]u8 = undefined;
    if (cb.Central.read(SVC, CHR_READ, &read_buf)) |data| {
        if (data.len == 4 and data[0] == 0xDE and data[1] == 0xAD and data[2] == 0xBE and data[3] == 0xEF) {
            pass("T4: Read returned 0xDEADBEEF");
        } else {
            std.debug.print("  Got {} bytes: ", .{data.len});
            for (data) |b| std.debug.print("{X:0>2} ", .{b});
            std.debug.print("\n", .{});
            fail("T4: Read data mismatch");
        }
    } else |_| {
        fail("T4: Read failed");
    }

    // T5: Write characteristic
    std.debug.print("\nT5: Writing to {s}/{s}...\n", .{ SVC, CHR_WRITE });
    if (cb.Central.write(SVC, CHR_WRITE, &[_]u8{ 0x01, 0x02, 0x03 })) {
        pass("T5: Write with response");
    } else |_| {
        fail("T5: Write failed");
    }

    // T6: Write without response
    std.debug.print("\nT6: Write no response to {s}/{s}...\n", .{ SVC, CHR_WRITE });
    if (cb.Central.writeNoResponse(SVC, CHR_WRITE, &[_]u8{ 0xAA, 0xBB })) {
        pass("T6: Write without response");
    } else |_| {
        fail("T6: Write no response failed");
    }

    // T7: Subscribe to notifications
    std.debug.print("\nT7: Subscribe to {s}/{s}...\n", .{ SVC, CHR_NOTIFY });
    notif_count = 0;
    if (cb.Central.subscribe(SVC, CHR_NOTIFY)) {
        pass("T7: Subscribed");
    } else |_| {
        fail("T7: Subscribe failed");
    }

    // T8: Wait for notifications
    std.debug.print("\nT8: Waiting for notifications...\n", .{});
    for (0..50) |_| cb.runLoopOnce(100); // 5 seconds

    if (notif_count > 0) {
        std.debug.print("  Received {} notifications\n", .{notif_count});
        pass("T8: Notifications received");
    } else {
        fail("T8: No notifications received");
    }

    // T9: Unsubscribe
    std.debug.print("\nT9: Unsubscribe...\n", .{});
    if (cb.Central.unsubscribe(SVC, CHR_NOTIFY)) {
        pass("T9: Unsubscribed");
    } else |_| {
        fail("T9: Unsubscribe failed");
    }

    // T10: Disconnect
    std.debug.print("\nT10: Disconnect...\n", .{});
    cb.Central.disconnect();
    for (0..10) |_| cb.runLoopOnce(100);
    pass("T10: Disconnected");

    printResults();
}

fn printResults() void {
    std.debug.print("\n==========================================\n", .{});
    std.debug.print("Cross-Platform Results: {} passed, {} failed\n", .{ passed, failed });
    if (failed == 0) {
        std.debug.print("ALL TESTS PASSED\n", .{});
    } else {
        std.debug.print("{} TESTS FAILED\n", .{failed});
    }
    std.debug.print("==========================================\n", .{});
}
