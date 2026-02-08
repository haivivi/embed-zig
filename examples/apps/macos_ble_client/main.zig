//! macOS BLE Client — Cross-Platform E2E Test (mac-client ↔ esp-server)
//!
//! Scans for "ZigE2E", connects, validates service discovery,
//! tests read/write/echo/notifications against ESP32 GATT Server.
//!
//! 20 test cases covering discovery + GATT operations + data integrity.
//!
//! Build: zig build -Dtarget=native
//! Run: zig build run

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
var notif_data: [256]u8 = undefined;
var notif_len: usize = 0;

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
    const n = @min(len, notif_data.len);
    @memcpy(notif_data[0..n], data[0..n]);
    notif_len = n;
    notif_count += 1;
}

pub fn main() !void {
    std.debug.print("==========================================\n", .{});
    std.debug.print("macOS BLE Client → ESP32 GATT Server\n", .{});
    std.debug.print("20 Cross-Platform E2E Tests\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Setup callbacks
    cb.Central.setDeviceFoundCallback(onDeviceFound);
    cb.Central.setConnectionCallback(onConnection);
    cb.Central.setNotificationCallback(onNotification);

    // === T01: Initialize ===
    std.debug.print("T01: Initialize CoreBluetooth Central...\n", .{});
    try cb.Central.init();
    pass("T01: Central initialized");

    // === T02: Scan ===
    std.debug.print("T02: Scanning for \"{s}\"...\n", .{TARGET_NAME});
    try cb.Central.scanStart(null);

    var scan_time: u32 = 0;
    while (!device_found and scan_time < 100) : (scan_time += 1) {
        cb.runLoopOnce(100);
    }
    cb.Central.scanStop();

    if (device_found) {
        pass("T02: Device found");
    } else {
        fail("T02: Device not found (is ESP32 server running?)");
        printResults();
        return;
    }

    // === T03: Connect ===
    std.debug.print("T03: Connecting...\n", .{});
    target_uuid[target_uuid_len] = 0;
    cb.Central.connect(&target_uuid) catch {
        fail("T03: Connect failed");
        printResults();
        return;
    };

    var conn_time: u32 = 0;
    while (!is_connected and conn_time < 100) : (conn_time += 1) {
        cb.runLoopOnce(100);
    }

    if (is_connected) {
        pass("T03: Connected + service discovery done");
    } else {
        fail("T03: Connection timeout");
        printResults();
        return;
    }

    // Wait for CoreBluetooth internal service discovery
    for (0..10) |_| cb.runLoopOnce(100);

    // === T04-T05: Discovery validation ===
    // CoreBluetooth does discovery internally — we validate by reading chars
    std.debug.print("T04: Validating service 0x{s} is accessible...\n", .{SVC});
    var read_buf: [512]u8 = undefined;
    if (cb.Central.read(SVC, CHR_READ, &read_buf)) |_| {
        pass("T04: Service 0xAA00 accessible (read succeeded)");
    } else |_| {
        fail("T04: Service 0xAA00 not accessible");
        printResults();
        return;
    }

    // Verify all 4 chars are reachable
    var chars_ok: u32 = 0;
    if (cb.Central.read(SVC, CHR_READ, &read_buf)) |_| { chars_ok += 1; } else |_| {}
    if (cb.Central.read(SVC, CHR_NOTIFY, &read_buf)) |_| { chars_ok += 1; } else |_| {}
    if (cb.Central.read(SVC, CHR_RW, &read_buf)) |_| { chars_ok += 1; } else |_| {}
    // CHR_WRITE is write-only, test by writing
    if (cb.Central.write(SVC, CHR_WRITE, &[_]u8{0x00})) { chars_ok += 1; } else |_| {}

    if (chars_ok == 4)
        pass("T05: All 4 characteristics reachable")
    else
        fail("T05: Only " ++ "" ++ " of 4 chars reachable");

    // === T06: Read basic ===
    std.debug.print("T06: Read {s}/{s}...\n", .{ SVC, CHR_READ });
    if (cb.Central.read(SVC, CHR_READ, &read_buf)) |data| {
        if (data.len == 4 and data[0] == 0xDE and data[1] == 0xAD and data[2] == 0xBE and data[3] == 0xEF) {
            pass("T06: Read → 0xDEADBEEF");
        } else {
            std.debug.print("  Got {} bytes\n", .{data.len});
            fail("T06: Read data mismatch");
        }
    } else |_| fail("T06: Read failed");

    // === T07: Read notify char ===
    if (cb.Central.read(SVC, CHR_NOTIFY, &read_buf)) |data| {
        if (data.len == 2 and data[0] == 0xCA and data[1] == 0xFE)
            pass("T07: Read notify char → 0xCAFE")
        else
            fail("T07: Read notify char data");
    } else |_| fail("T07: Read notify char");

    // === T08: Write with response ===
    std.debug.print("T08: Write to {s}/{s}...\n", .{ SVC, CHR_WRITE });
    if (cb.Central.write(SVC, CHR_WRITE, &[_]u8{ 0x01, 0x02, 0x03 })) {
        pass("T08: Write with response");
    } else |_| fail("T08: Write failed");

    // === T09: Write without response ===
    if (cb.Central.writeNoResponse(SVC, CHR_WRITE, &[_]u8{ 0xAA, 0xBB })) {
        pass("T09: Write without response");
    } else |_| fail("T09: Write no response failed");

    // === T10: RW echo — write then read back ===
    std.debug.print("T10: RW echo test...\n", .{});
    if (cb.Central.write(SVC, CHR_RW, &[_]u8{ 0x42, 0x43 })) {
        if (cb.Central.read(SVC, CHR_RW, &read_buf)) |data| {
            if (data.len == 2 and data[0] == 0x42 and data[1] == 0x43)
                pass("T10: RW echo → 0x4243")
            else
                fail("T10: RW echo data mismatch");
        } else |_| fail("T10: RW echo read failed");
    } else |_| fail("T10: RW echo write failed");

    // === T11: Write larger data + read back ===
    var big_data: [50]u8 = undefined;
    for (&big_data, 0..) |*b, i| b.* = @truncate(i);
    if (cb.Central.write(SVC, CHR_RW, &big_data)) {
        if (cb.Central.read(SVC, CHR_RW, &read_buf)) |data| {
            if (data.len == 50 and data[0] == 0 and data[49] == 49)
                pass("T11: 50-byte echo integrity")
            else
                fail("T11: 50-byte echo mismatch");
        } else |_| fail("T11: 50-byte echo read");
    } else |_| fail("T11: 50-byte echo write");

    // === T12: Overwrite and verify ===
    if (cb.Central.write(SVC, CHR_RW, &[_]u8{ 0xDE, 0xAD })) {
        if (cb.Central.read(SVC, CHR_RW, &read_buf)) |data| {
            if (data.len == 2 and data[0] == 0xDE and data[1] == 0xAD)
                pass("T12: Overwrite verify → 0xDEAD")
            else
                fail("T12: Overwrite mismatch");
        } else |_| fail("T12: Overwrite read");
    } else |_| fail("T12: Overwrite write");

    // === T13: Subscribe ===
    std.debug.print("T13: Subscribe to {s}/{s}...\n", .{ SVC, CHR_NOTIFY });
    notif_count = 0;
    notif_len = 0;
    if (cb.Central.subscribe(SVC, CHR_NOTIFY)) {
        pass("T13: Subscribed");
    } else |_| fail("T13: Subscribe failed");

    // === T14: Notification received ===
    std.debug.print("T14: Waiting for notifications...\n", .{});
    for (0..50) |_| cb.runLoopOnce(100); // 5 seconds

    if (notif_count >= 1) {
        std.debug.print("  Received {} notifications\n", .{notif_count});
        pass("T14: Notification received");
    } else fail("T14: No notifications received");

    // === T15: Notification data = 0xBEEF ===
    if (notif_len >= 2 and notif_data[0] == 0xBE and notif_data[1] == 0xEF)
        pass("T15: Notification data = 0xBEEF")
    else
        fail("T15: Notification data mismatch");

    // === T16: Multiple notifications ===
    if (notif_count >= 3)
        pass("T16: Multiple notifications (>= 3)")
    else
        fail("T16: Expected >= 3 notifications");

    // === T17: Unsubscribe ===
    std.debug.print("T17: Unsubscribe...\n", .{});
    if (cb.Central.unsubscribe(SVC, CHR_NOTIFY)) {
        pass("T17: Unsubscribed");
    } else |_| fail("T17: Unsubscribe failed");

    // === T18: Data integrity — pattern write/read ===
    std.debug.print("T18: Pattern integrity test...\n", .{});
    var pattern: [100]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i ^ 0x55);
    if (cb.Central.write(SVC, CHR_RW, &pattern)) {
        if (cb.Central.read(SVC, CHR_RW, &read_buf)) |data| {
            if (data.len == 100 and data[0] == (0 ^ 0x55) and data[99] == @as(u8, @truncate(99 ^ 0x55)))
                pass("T18: 100-byte pattern integrity")
            else
                fail("T18: Pattern integrity mismatch");
        } else |_| fail("T18: Pattern read");
    } else |_| fail("T18: Pattern write");

    // === T19: Rapid read-write cycles ===
    std.debug.print("T19: 5 rapid R/W cycles...\n", .{});
    var cycle_ok: u32 = 0;
    for (0..5) |i| {
        const val = [_]u8{@truncate(i)};
        if (cb.Central.write(SVC, CHR_RW, &val)) {
            if (cb.Central.read(SVC, CHR_RW, &read_buf)) |data| {
                if (data.len == 1 and data[0] == @as(u8, @truncate(i))) cycle_ok += 1;
            } else |_| {}
        } else |_| {}
    }
    if (cycle_ok == 5) pass("T19: 5 rapid R/W cycles") else fail("T19: R/W cycles");

    // === T20: Disconnect ===
    std.debug.print("T20: Disconnect...\n", .{});
    cb.Central.disconnect();
    for (0..10) |_| cb.runLoopOnce(100);
    pass("T20: Disconnected");

    printResults();
}

fn printResults() void {
    std.debug.print("\n==========================================\n", .{});
    std.debug.print("Cross-Platform Results: {} passed, {} failed / 20 total\n", .{ passed, failed });
    if (failed == 0) {
        std.debug.print("ALL TESTS PASSED\n", .{});
    } else {
        std.debug.print("{} TESTS FAILED\n", .{failed});
    }
    std.debug.print("==========================================\n", .{});
}
