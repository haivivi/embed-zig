//! BLE Advertise/Scan Interop Test — Cross-platform
//!
//! Tests BLE radio interop between two different boards.
//! Role is determined by board type:
//!   - BK7258: Advertiser (sends ADV_IND with name "BK7258-Zig")
//!   - ESP32-S3: Scanner (listens for advertisements, reports found devices)
//!
//! Both use raw HCI commands — no host stack needed.

const std = @import("std");
const bluetooth = @import("bluetooth");

const hci_cmds = bluetooth.hci.commands;
const hci_events = bluetooth.hci.events;
const hci = bluetooth.hci;

const platform = @import("platform.zig");
const log = platform.log;
const time = platform.time;
const ble = platform.ble;
const ROLE = platform.role;

// ============================================================================
// HCI helpers (shared)
// ============================================================================

fn sendCmd(cmd: []const u8) bool {
    _ = ble.send(cmd) catch |err| {
        log.err("HCI send failed: {}", .{err});
        return false;
    };
    return true;
}

fn waitResp(buf: []u8) ?usize {
    if (!ble.waitForData(3000)) {
        log.err("HCI timeout", .{});
        return null;
    }
    const n = ble.recv(buf) catch |err| {
        log.err("HCI recv failed: {}", .{err});
        return null;
    };
    return n;
}

fn sendAndCheck(cmd: []const u8, expected_opcode: u16) bool {
    if (!sendCmd(cmd)) return false;
    var resp: [256]u8 = undefined;
    const n = waitResp(&resp) orelse return false;
    if (n < 1 or resp[0] != 0x04) return false;

    const event = hci_events.decode(resp[1..n]) orelse return false;
    switch (event) {
        .command_complete => |cc| {
            if (cc.opcode != expected_opcode) {
                log.err("Wrong opcode: 0x{X:0>4} (expected 0x{X:0>4})", .{ cc.opcode, expected_opcode });
                return false;
            }
            if (!cc.status.isSuccess()) {
                log.err("Command status: 0x{X:0>2}", .{@intFromEnum(cc.status)});
                return false;
            }
            return true;
        },
        else => {
            log.warn("Unexpected event (not CommandComplete)", .{});
            return false;
        },
    }
}

// ============================================================================
// Advertiser (BK7258)
// ============================================================================

fn runAdvertiser() void {
    log.info("=== ROLE: ADVERTISER ===", .{});
    var buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;

    // 1. HCI Reset
    log.info("HCI Reset...", .{});
    if (!sendAndCheck(hci_cmds.reset(&buf), hci_cmds.RESET)) return;
    time.sleepMs(100);

    // 2. Set advertising parameters (fast interval for quick discovery)
    log.info("Set Adv Params...", .{});
    if (!sendAndCheck(hci_cmds.leSetAdvParams(&buf, .{
        .interval_min = 0x0020, // 20ms
        .interval_max = 0x0040, // 40ms
        .adv_type = .adv_ind,
    }), hci_cmds.LE_SET_ADV_PARAMS)) return;

    // 3. Set advertising data: [Flags] + [Complete Local Name]
    log.info("Set Adv Data...", .{});
    const name = "BK7258-Zig";
    var adv_data: [31]u8 = .{0} ** 31;
    adv_data[0] = 0x02; // Length
    adv_data[1] = 0x01; // AD Type: Flags
    adv_data[2] = 0x06; // LE General + BR/EDR Not Supported
    adv_data[3] = @intCast(1 + name.len); // Length
    adv_data[4] = 0x09; // AD Type: Complete Local Name
    @memcpy(adv_data[5..][0..name.len], name);
    const adv_len: usize = 5 + name.len;

    if (!sendAndCheck(hci_cmds.leSetAdvData(&buf, adv_data[0..adv_len]), hci_cmds.LE_SET_ADV_DATA)) return;

    // 4. Enable advertising
    log.info("Enable Advertising...", .{});
    if (!sendAndCheck(hci_cmds.leSetAdvEnable(&buf, true), hci_cmds.LE_SET_ADV_ENABLE)) return;

    log.info("Advertising started! Name: \"{s}\"", .{name});
    log.info("Waiting for scanner to find us (30s)...", .{});

    // Keep alive for 30 seconds
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        time.sleepMs(1000);
        // Check for any incoming events (e.g., connection request)
        var resp: [256]u8 = undefined;
        const n = ble.recv(&resp) catch continue;
        if (n > 1 and resp[0] == 0x04) {
            if (hci_events.decode(resp[1..n])) |event| {
                switch (event) {
                    .le_connection_complete => |cc| {
                        log.info("Connection! handle=0x{X:0>4}", .{cc.conn_handle});
                    },
                    else => {},
                }
            }
        }
    }

    // Disable advertising
    _ = sendAndCheck(hci_cmds.leSetAdvEnable(&buf, false), hci_cmds.LE_SET_ADV_ENABLE);
    log.info("Advertising stopped.", .{});
}

// ============================================================================
// Scanner (ESP32-S3)
// ============================================================================

fn runScanner() void {
    log.info("=== ROLE: SCANNER ===", .{});
    var buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;

    // 1. HCI Reset
    log.info("HCI Reset...", .{});
    if (!sendAndCheck(hci_cmds.reset(&buf), hci_cmds.RESET)) return;
    time.sleepMs(100);

    // 2. Set LE Event Mask (enable advertising report events)
    log.info("Set LE Event Mask...", .{});
    if (!sendAndCheck(hci_cmds.leSetEventMask(&buf, 0x000000000000001F), hci_cmds.LE_SET_EVENT_MASK)) return;

    // 3. Set scan parameters (active scan, fast interval)
    log.info("Set Scan Params...", .{});
    if (!sendAndCheck(hci_cmds.leSetScanParams(&buf, .{
        .scan_type = 0x01, // Active
        .interval = 0x0010, // 10ms
        .window = 0x0010, // 10ms (continuous)
    }), hci_cmds.LE_SET_SCAN_PARAMS)) return;

    // 4. Enable scanning
    log.info("Enable Scanning...", .{});
    if (!sendAndCheck(hci_cmds.leSetScanEnable(&buf, true, false), hci_cmds.LE_SET_SCAN_ENABLE)) return;

    log.info("Scanning for BLE devices (15s)...", .{});

    var found_target = false;
    var device_count: u32 = 0;
    const scan_start = time.nowMs();

    while (time.nowMs() - scan_start < 15000) {
        var resp: [256]u8 = undefined;
        if (!ble.waitForData(500)) continue;

        const n = ble.recv(&resp) catch continue;
        if (n < 2 or resp[0] != 0x04) continue;

        const event = hci_events.decode(resp[1..n]) orelse continue;
        switch (event) {
            .le_advertising_report => |report| {
                // Parse the first report
                if (hci_events.parseAdvReport(report.data)) |adv| {
                    device_count += 1;

                    // Search for name in AD structures
                    var name_buf: [32]u8 = .{0} ** 32;
                    var name_len: usize = 0;
                    var pos: usize = 0;
                    while (pos + 1 < adv.data.len) {
                        const ad_len = adv.data[pos];
                        if (ad_len == 0) break;
                        if (pos + 1 + ad_len > adv.data.len) break;
                        const ad_type = adv.data[pos + 1];
                        if (ad_type == 0x09 or ad_type == 0x08) {
                            name_len = @min(ad_len - 1, 31);
                            @memcpy(name_buf[0..name_len], adv.data[pos + 2 ..][0..name_len]);
                        }
                        pos += 1 + ad_len;
                    }

                    if (name_len > 0) {
                        log.info("  [{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}] RSSI={} \"{s}\"", .{
                            adv.addr[5], adv.addr[4], adv.addr[3], adv.addr[2], adv.addr[1], adv.addr[0],
                            adv.rssi,
                            name_buf[0..name_len],
                        });

                        if (std.mem.eql(u8, name_buf[0..name_len], "BK7258-Zig")) {
                            found_target = true;
                            log.info("  >>> FOUND TARGET: BK7258-Zig! <<<", .{});
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Disable scanning
    _ = sendAndCheck(hci_cmds.leSetScanEnable(&buf, false, false), hci_cmds.LE_SET_SCAN_ENABLE);

    log.info("", .{});
    log.info("Scan complete. {} advertisements received.", .{device_count});
    if (found_target) {
        log.info("PASS: BK7258-Zig found!", .{});
    } else {
        log.err("FAIL: BK7258-Zig NOT found", .{});
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("BLE Advertise/Scan Interop Test", .{});
    log.info("Role: {s}", .{@tagName(ROLE)});
    log.info("==========================================", .{});

    log.info("Initializing BLE...", .{});
    ble.init() catch |err| {
        log.err("BLE init failed: {}", .{err});
        return;
    };

    time.sleepMs(200);

    switch (ROLE) {
        .advertiser => runAdvertiser(),
        .scanner => runScanner(),
    }

    log.info("==========================================", .{});
    log.info("Test complete.", .{});
    log.info("==========================================", .{});

    while (platform.isRunning()) {
        time.sleepMs(5000);
    }
}
