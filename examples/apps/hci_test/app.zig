//! HCI Smoke Test — Cross-platform
//!
//! Verifies the HCI transport chain end-to-end on real hardware:
//!   Zig → platform HCI driver → BLE controller → response back
//!
//! Test sequence:
//! 1. Init BLE controller
//! 2. Send HCI Reset → verify Command Complete
//! 3. Send LE Read Buffer Size → print ACL buffer params
//! 4. Send Read BD_ADDR → print device Bluetooth address
//! 5. Set Event Mask + LE Event Mask
//! 6. Read Local Version info

const std = @import("std");
const bluetooth = @import("bluetooth");

const hci_cmds = bluetooth.hci.commands;
const hci_events = bluetooth.hci.events;
const hci = bluetooth.hci;

const platform = @import("platform.zig");
const log = platform.log;
const time = platform.time;
const ble = platform.ble;

// ============================================================================
// HCI helpers
// ============================================================================

/// Send an HCI command and wait for the response event
fn sendCommand(cmd: []const u8, resp_buf: []u8) !usize {
    // Send command
    const sent = ble.send(cmd) catch |err| {
        log.err("HCI send failed: {}", .{err});
        return error.SendFailed;
    };
    log.info("  TX: {} bytes", .{sent});

    // Wait for response (up to 2 seconds)
    if (!ble.waitForData(2000)) {
        log.err("  RX: timeout (no response in 2s)", .{});
        return error.Timeout;
    }

    // Read response
    const n = ble.recv(resp_buf) catch |err| {
        log.err("  RX: recv failed: {}", .{err});
        return error.RecvFailed;
    };
    log.info("  RX: {} bytes", .{n});

    return n;
}

/// Decode a Command Complete event and return the status + return params
fn expectCommandComplete(data: []const u8, expected_opcode: u16) !hci_events.CommandComplete {
    if (data.len < 1) return error.TooShort;

    // First byte is the packet indicator (0x04 = event)
    if (data[0] != @intFromEnum(hci.PacketType.event)) {
        log.err("  Expected event indicator (0x04), got 0x{X:0>2}", .{data[0]});
        return error.NotEvent;
    }

    // Decode event (skip indicator byte)
    const event = hci_events.decode(data[1..]) orelse {
        log.err("  Failed to decode event", .{});
        return error.DecodeFailed;
    };

    switch (event) {
        .command_complete => |cc| {
            if (cc.opcode != expected_opcode) {
                log.err("  Wrong opcode: expected 0x{X:0>4}, got 0x{X:0>4}", .{ expected_opcode, cc.opcode });
                return error.WrongOpcode;
            }
            return cc;
        },
        else => {
            log.err("  Expected Command Complete, got different event", .{});
            return error.WrongEvent;
        },
    }
}

// ============================================================================
// Test Functions
// ============================================================================

fn testHciReset() !void {
    log.info("--- Test 1: HCI Reset ---", .{});

    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    const cmd = hci_cmds.reset(&cmd_buf);

    var resp_buf: [256]u8 = undefined;
    const n = try sendCommand(cmd, &resp_buf);

    const cc = try expectCommandComplete(resp_buf[0..n], hci_cmds.RESET);

    if (cc.status.isSuccess()) {
        log.info("  HCI Reset: OK (status=0x00)", .{});
    } else {
        log.err("  HCI Reset: FAILED (status=0x{X:0>2})", .{@intFromEnum(cc.status)});
        return error.ResetFailed;
    }
}

fn testLeReadBufferSize() !void {
    log.info("--- Test 2: LE Read Buffer Size ---", .{});

    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    const cmd = hci_cmds.encode(&cmd_buf, hci_cmds.LE_READ_BUFFER_SIZE, &.{});

    var resp_buf: [256]u8 = undefined;
    const n = try sendCommand(cmd, &resp_buf);

    const cc = try expectCommandComplete(resp_buf[0..n], hci_cmds.LE_READ_BUFFER_SIZE);

    if (!cc.status.isSuccess()) {
        log.err("  LE Read Buffer Size: FAILED (status=0x{X:0>2})", .{@intFromEnum(cc.status)});
        return error.CommandFailed;
    }

    if (cc.return_params.len >= 3) {
        const acl_len = std.mem.readInt(u16, cc.return_params[0..2], .little);
        const acl_num = cc.return_params[2];
        log.info("  LE Buffer Size: ACL_len={}, ACL_num={}", .{ acl_len, acl_num });
    } else {
        log.warn("  LE Buffer Size: no return params (len={})", .{cc.return_params.len});
    }
}

fn testReadBdAddr() !void {
    log.info("--- Test 3: Read BD_ADDR ---", .{});

    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    const cmd = hci_cmds.encode(&cmd_buf, hci_cmds.READ_BD_ADDR, &.{});

    var resp_buf: [256]u8 = undefined;
    const n = try sendCommand(cmd, &resp_buf);

    const cc = try expectCommandComplete(resp_buf[0..n], hci_cmds.READ_BD_ADDR);

    if (!cc.status.isSuccess()) {
        log.err("  Read BD_ADDR: FAILED (status=0x{X:0>2})", .{@intFromEnum(cc.status)});
        return error.CommandFailed;
    }

    if (cc.return_params.len >= 6) {
        const addr = cc.return_params[0..6];
        log.info("  BD_ADDR: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
            addr[5], addr[4], addr[3], addr[2], addr[1], addr[0],
        });
    } else {
        log.warn("  BD_ADDR: no return params (len={})", .{cc.return_params.len});
    }
}

fn testSetEventMask() !void {
    log.info("--- Test 4: Set Event Mask ---", .{});

    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    const cmd = hci_cmds.setEventMask(&cmd_buf, 0x3DBFF807FFFBFFFF);

    var resp_buf: [256]u8 = undefined;
    const n = try sendCommand(cmd, &resp_buf);

    const cc = try expectCommandComplete(resp_buf[0..n], hci_cmds.SET_EVENT_MASK);

    if (cc.status.isSuccess()) {
        log.info("  Set Event Mask: OK", .{});
    } else {
        log.err("  Set Event Mask: FAILED (status=0x{X:0>2})", .{@intFromEnum(cc.status)});
    }
}

fn testLeSetEventMask() !void {
    log.info("--- Test 5: LE Set Event Mask ---", .{});

    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    const cmd = hci_cmds.leSetEventMask(&cmd_buf, 0x000000000000001F);

    var resp_buf: [256]u8 = undefined;
    const n = try sendCommand(cmd, &resp_buf);

    const cc = try expectCommandComplete(resp_buf[0..n], hci_cmds.LE_SET_EVENT_MASK);

    if (cc.status.isSuccess()) {
        log.info("  LE Set Event Mask: OK", .{});
    } else {
        log.err("  LE Set Event Mask: FAILED (status=0x{X:0>2})", .{@intFromEnum(cc.status)});
    }
}

fn testReadLocalVersion() !void {
    log.info("--- Test 6: Read Local Version ---", .{});

    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    const cmd = hci_cmds.encode(&cmd_buf, hci_cmds.READ_LOCAL_VERSION, &.{});

    var resp_buf: [256]u8 = undefined;
    const n = try sendCommand(cmd, &resp_buf);

    const cc = try expectCommandComplete(resp_buf[0..n], hci_cmds.READ_LOCAL_VERSION);

    if (!cc.status.isSuccess()) {
        log.err("  Read Local Version: FAILED (status=0x{X:0>2})", .{@intFromEnum(cc.status)});
        return error.CommandFailed;
    }

    if (cc.return_params.len >= 8) {
        const hci_ver = cc.return_params[0];
        const hci_rev = std.mem.readInt(u16, cc.return_params[1..3], .little);
        const lmp_ver = cc.return_params[3];
        const manufacturer = std.mem.readInt(u16, cc.return_params[4..6], .little);
        const lmp_sub = std.mem.readInt(u16, cc.return_params[6..8], .little);
        log.info("  HCI Version: {} (rev {})", .{ hci_ver, hci_rev });
        log.info("  LMP Version: {} (sub {})", .{ lmp_ver, lmp_sub });
        log.info("  Manufacturer: 0x{X:0>4}", .{manufacturer});
    }
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("HCI Smoke Test", .{});
    log.info("==========================================", .{});

    // Initialize BLE controller
    log.info("", .{});
    log.info("Initializing BLE controller...", .{});
    ble.init() catch |err| {
        log.err("BLE controller init failed: {}", .{err});
        return;
    };
    log.info("BLE controller initialized OK", .{});

    // Give controller a moment to settle
    time.sleepMs(100);

    // Run tests
    log.info("", .{});
    var passed: u8 = 0;
    var failed: u8 = 0;

    inline for (.{
        .{ "HCI Reset", testHciReset },
        .{ "LE Read Buffer Size", testLeReadBufferSize },
        .{ "Read BD_ADDR", testReadBdAddr },
        .{ "Set Event Mask", testSetEventMask },
        .{ "LE Set Event Mask", testLeSetEventMask },
        .{ "Read Local Version", testReadLocalVersion },
    }) |entry| {
        if (entry[1]()) {
            passed += 1;
        } else |err| {
            log.err("{s}: FAILED ({any})", .{ entry[0], err });
            failed += 1;
        }
    }

    // Summary
    log.info("", .{});
    log.info("==========================================", .{});
    if (failed == 0) {
        log.info("HCI Smoke Test PASSED ({}/{})", .{ passed, passed + failed });
    } else {
        log.err("HCI Smoke Test: {}/{} passed, {} FAILED", .{ passed, passed + failed, failed });
    }
    log.info("==========================================", .{});

    // Keep alive
    while (platform.isRunning()) {
        time.sleepMs(5000);
    }
}
