//! macOS BLE GATT Server Example
//!
//! Uses CoreBluetooth to advertise a GATT service.
//! Test with nRF Connect on your phone.
//!
//! Build: zig build -Dtarget=native
//! Run: zig build run (requires Bluetooth permission on macOS)

const std = @import("std");
const cb = @import("cb");

const SVC_UUID = "AA00";
const CHR_READ_UUID = "AA01";
const CHR_WRITE_UUID = "AA02";
const CHR_NOTIFY_UUID = "AA03";

// ============================================================================
// State
// ============================================================================

var connected = false;
var notify_enabled = false;
var counter: u32 = 0;

// ============================================================================
// Callbacks
// ============================================================================

fn onRead(
    svc: [*c]const u8,
    chr: [*c]const u8,
    out: [*c]u8,
    out_len: *u16,
    max_len: u16,
) callconv(.c) void {
    _ = svc;
    _ = max_len;

    const chr_str = std.mem.span(chr);

    if (std.mem.eql(u8, chr_str, CHR_READ_UUID)) {
        const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        @memcpy(out[0..4], &data);
        out_len.* = 4;
        std.debug.print("[read] {s} → 0xDEADBEEF\n", .{chr_str});
    } else if (std.mem.eql(u8, chr_str, CHR_NOTIFY_UUID)) {
        const data = [_]u8{ 0xCA, 0xFE };
        @memcpy(out[0..2], &data);
        out_len.* = 2;
    } else {
        out_len.* = 0;
    }
}

fn onWrite(
    svc: [*c]const u8,
    chr: [*c]const u8,
    data: [*c]const u8,
    len: u16,
) callconv(.c) void {
    _ = svc;
    const chr_str = std.mem.span(chr);
    std.debug.print("[write] {s} ← {} bytes: ", .{ chr_str, len });
    for (0..@min(len, 16)) |i| {
        std.debug.print("{X:0>2} ", .{data[i]});
    }
    if (len > 16) std.debug.print("...", .{});
    std.debug.print("\n", .{});
}

fn onSubscribe(
    svc: [*c]const u8,
    chr: [*c]const u8,
    subscribed: bool,
) callconv(.c) void {
    _ = svc;
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
    std.debug.print("macOS BLE GATT Server (CoreBluetooth)\n", .{});
    std.debug.print("==========================================\n", .{});

    // Set callbacks
    cb.Peripheral.setReadCallback(onRead);
    cb.Peripheral.setWriteCallback(onWrite);
    cb.Peripheral.setSubscribeCallback(onSubscribe);
    cb.Peripheral.setConnectionCallback(onConnection);

    // Initialize
    std.debug.print("Initializing CoreBluetooth...\n", .{});
    try cb.Peripheral.init();
    std.debug.print("CoreBluetooth ready.\n", .{});

    // Add service
    const chr_uuids = [_][*c]const u8{ CHR_READ_UUID, CHR_WRITE_UUID, CHR_NOTIFY_UUID };
    const chr_props = [_]u8{
        cb.PROP_READ,
        cb.PROP_WRITE | cb.PROP_WRITE_NO_RSP,
        cb.PROP_READ | cb.PROP_NOTIFY,
    };
    try cb.Peripheral.addService(SVC_UUID, &chr_uuids, &chr_props, 3);
    std.debug.print("Service 0x{s} added.\n", .{SVC_UUID});

    // Start advertising
    try cb.Peripheral.startAdvertising("ZigE2E");
    std.debug.print("Advertising as \"ZigE2E\"...\n", .{});
    std.debug.print("ESP32 client or nRF Connect can scan and connect.\n", .{});

    // Main loop
    while (true) {
        cb.runLoopOnce(100);

        // Send notifications if subscribed
        if (notify_enabled) {
            counter += 1;
            if (counter % 10 == 0) { // Every ~1 second
                const data = [_]u8{ @truncate(counter >> 8), @truncate(counter) };
                cb.Peripheral.notify(SVC_UUID, CHR_NOTIFY_UUID, &data) catch {};
                std.debug.print("[notify] counter={}\n", .{counter});
            }
        }
    }
}
