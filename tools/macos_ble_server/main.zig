//! macOS BLE GATT Server — Cross-Platform E2E Test Server
//!
//! Uses CoreBluetooth to advertise a GATT service identical to ESP32 server.
//! Compatible with both ESP32 client and macOS client test suites.
//!
//! Service 0xAA00:
//!   CHR_READ   0xAA01 (Read)       → returns 0xDEADBEEF
//!   CHR_WRITE  0xAA02 (Write/WNR)  → accepts any data
//!   CHR_NOTIFY 0xAA03 (Read/Notify) → returns 0xCAFE, notifies 0xBEEF
//!   CHR_RW     0xAA04 (Read/Write)  → echo buffer (write → read back)
//!
//! Build: zig build -Dtarget=native
//! Run: zig build run

const std = @import("std");
const cb = @import("cb");

const SVC_UUID = "AA00";
const CHR_READ_UUID = "AA01";
const CHR_WRITE_UUID = "AA02";
const CHR_NOTIFY_UUID = "AA03";
const CHR_RW_UUID = "AA04";

// ============================================================================
// State
// ============================================================================

var connected = false;
var notify_enabled = false;
var tick: u32 = 0;

// RW echo buffer (matches ESP32 server behavior)
var rw_data: [256]u8 = .{0} ** 256;
var rw_len: usize = 0;

// ============================================================================
// Callbacks
// ============================================================================

fn onRead(
    _: [*c]const u8,
    chr: [*c]const u8,
    out: [*c]u8,
    out_len: *u16,
    max_len: u16,
) callconv(.c) void {
    const chr_str = std.mem.span(chr);

    if (std.mem.eql(u8, chr_str, CHR_READ_UUID)) {
        // Same as ESP32: return 0xDEADBEEF
        const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        @memcpy(out[0..4], &data);
        out_len.* = 4;
        std.debug.print("[read] {s} → 0xDEADBEEF\n", .{chr_str});
    } else if (std.mem.eql(u8, chr_str, CHR_NOTIFY_UUID)) {
        // Same as ESP32: return 0xCAFE
        const data = [_]u8{ 0xCA, 0xFE };
        @memcpy(out[0..2], &data);
        out_len.* = 2;
        std.debug.print("[read] {s} → 0xCAFE\n", .{chr_str});
    } else if (std.mem.eql(u8, chr_str, CHR_RW_UUID)) {
        // Echo buffer — same as ESP32 rwHandler
        const n: u16 = @intCast(@min(rw_len, max_len));
        if (n > 0) @memcpy(out[0..n], rw_data[0..n]);
        out_len.* = n;
        std.debug.print("[read] {s} → {} bytes\n", .{ chr_str, n });
    } else {
        out_len.* = 0;
    }
}

fn onWrite(
    _: [*c]const u8,
    chr: [*c]const u8,
    data: [*c]const u8,
    len: u16,
) callconv(.c) void {
    const chr_str = std.mem.span(chr);

    if (std.mem.eql(u8, chr_str, CHR_RW_UUID)) {
        // Echo buffer — same as ESP32 rwHandler
        const n = @min(len, rw_data.len);
        @memcpy(rw_data[0..n], data[0..n]);
        rw_len = n;
        std.debug.print("[write] {s} ← {} bytes (echo stored)\n", .{ chr_str, n });
    } else {
        std.debug.print("[write] {s} ← {} bytes: ", .{ chr_str, len });
        for (0..@min(len, 16)) |i| {
            std.debug.print("{X:0>2} ", .{data[i]});
        }
        if (len > 16) std.debug.print("...", .{});
        std.debug.print("\n", .{});
    }
}

fn onSubscribe(
    _: [*c]const u8,
    chr: [*c]const u8,
    subscribed: bool,
) callconv(.c) void {
    const chr_str = std.mem.span(chr);
    std.debug.print("[subscribe] {s} → {}\n", .{ chr_str, subscribed });
    if (std.mem.eql(u8, chr_str, CHR_NOTIFY_UUID)) {
        notify_enabled = subscribed;
    }
}

fn onConnection(is_connected: bool) callconv(.c) void {
    connected = is_connected;
    std.debug.print("[connection] {}\n", .{is_connected});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("==========================================\n", .{});
    std.debug.print("macOS BLE GATT Server (CrossPlatform E2E)\n", .{});
    std.debug.print("==========================================\n", .{});
    std.debug.print("Service: 0x{s}\n", .{SVC_UUID});
    std.debug.print("  {s}: Read → 0xDEADBEEF\n", .{CHR_READ_UUID});
    std.debug.print("  {s}: Write/WNR\n", .{CHR_WRITE_UUID});
    std.debug.print("  {s}: Read/Notify → 0xCAFE / notifies 0xBEEF\n", .{CHR_NOTIFY_UUID});
    std.debug.print("  {s}: Read/Write → echo buffer\n", .{CHR_RW_UUID});
    std.debug.print("==========================================\n\n", .{});

    // Set callbacks
    cb.Peripheral.setReadCallback(onRead);
    cb.Peripheral.setWriteCallback(onWrite);
    cb.Peripheral.setSubscribeCallback(onSubscribe);
    cb.Peripheral.setConnectionCallback(onConnection);

    // Initialize
    std.debug.print("Initializing CoreBluetooth...\n", .{});
    try cb.Peripheral.init();
    std.debug.print("CoreBluetooth ready.\n", .{});

    // Add service — 4 characteristics (same as ESP32 server)
    const chr_uuids = [_][*c]const u8{ CHR_READ_UUID, CHR_WRITE_UUID, CHR_NOTIFY_UUID, CHR_RW_UUID };
    const chr_props = [_]u8{
        cb.PROP_READ,
        cb.PROP_WRITE | cb.PROP_WRITE_NO_RSP,
        cb.PROP_READ | cb.PROP_NOTIFY,
        cb.PROP_READ | cb.PROP_WRITE,
    };
    try cb.Peripheral.addService(SVC_UUID, &chr_uuids, &chr_props, 4);
    std.debug.print("Service added with 4 characteristics.\n", .{});

    // Start advertising
    try cb.Peripheral.startAdvertising("ZigE2E");
    std.debug.print("Advertising as \"ZigE2E\"...\n", .{});
    std.debug.print("Waiting for connections...\n\n", .{});

    // Main loop
    while (true) {
        cb.runLoopOnce(100);

        // Send notifications if subscribed — same data as ESP32: 0xBEEF
        if (notify_enabled) {
            tick += 1;
            if (tick % 5 == 0) { // Every ~500ms
                const data = [_]u8{ 0xBE, 0xEF };
                cb.Peripheral.notify(SVC_UUID, CHR_NOTIFY_UUID, &data) catch {};
            }
        }
    }
}
