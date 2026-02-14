//! e2e: trait/ble — Verify BLE HCI transport (VHCI on ESP)
//!
//! Tests:
//!   1. BT controller init via VHCI
//!   2. HCI Reset → Command Complete
//!   3. Read BD_ADDR → get device MAC

const platform = @import("platform.zig");
const log = platform.log;
const bt = platform.bt;

fn runTests() !void {
    log.info("[e2e] START: trait/ble", .{});

    // Test 1: Init BT controller
    bt.init() catch |err| {
        log.err("[e2e] FAIL: trait/ble/init — {}", .{err});
        return error.BtInitFailed;
    };
    defer bt.deinit();
    log.info("[e2e] PASS: trait/ble/init", .{});

    // Test 2: HCI Reset (opcode 0x0C03)
    {
        const reset_cmd = [_]u8{ 0x01, 0x03, 0x0C, 0x00 }; // type=cmd, opcode=0x0C03, len=0
        const sent = bt.send(&reset_cmd) catch |err| {
            log.err("[e2e] FAIL: trait/ble/hci_reset — send failed: {}", .{err});
            return error.HciSendFailed;
        };
        if (sent != reset_cmd.len) {
            log.err("[e2e] FAIL: trait/ble/hci_reset — sent {} bytes, expected {}", .{ sent, reset_cmd.len });
            return error.HciSendIncomplete;
        }

        // Wait for Command Complete event
        if (!bt.waitForData(2000)) {
            log.err("[e2e] FAIL: trait/ble/hci_reset — no response in 2s", .{});
            return error.HciTimeout;
        }

        var resp: [64]u8 = undefined;
        const n = bt.recv(&resp) catch |err| {
            log.err("[e2e] FAIL: trait/ble/hci_reset — recv failed: {}", .{err});
            return error.HciRecvFailed;
        };

        // Expect event packet (0x04), Command Complete (0x0E), status=0
        if (n < 4 or resp[0] != 0x04 or resp[1] != 0x0E) {
            log.err("[e2e] FAIL: trait/ble/hci_reset — unexpected response: {} bytes, type=0x{x}", .{ n, resp[0] });
            return error.HciUnexpected;
        }
        // Status is at offset 6 (after indicator, event, len, num_cmds, opcode_lo, opcode_hi)
        if (n >= 7 and resp[6] != 0x00) {
            log.err("[e2e] FAIL: trait/ble/hci_reset — status=0x{x}", .{resp[6]});
            return error.HciResetFailed;
        }
        log.info("[e2e] PASS: trait/ble/hci_reset — Command Complete", .{});
    }

    // Test 3: Read BD_ADDR (opcode 0x1009)
    {
        const read_addr_cmd = [_]u8{ 0x01, 0x09, 0x10, 0x00 }; // type=cmd, opcode=0x1009, len=0
        _ = bt.send(&read_addr_cmd) catch |err| {
            log.err("[e2e] FAIL: trait/ble/bd_addr — send failed: {}", .{err});
            return error.HciSendFailed;
        };

        if (!bt.waitForData(2000)) {
            log.err("[e2e] FAIL: trait/ble/bd_addr — no response in 2s", .{});
            return error.HciTimeout;
        }

        var resp: [64]u8 = undefined;
        const n = bt.recv(&resp) catch |err| {
            log.err("[e2e] FAIL: trait/ble/bd_addr — recv failed: {}", .{err});
            return error.HciRecvFailed;
        };

        // Command Complete for Read BD_ADDR: indicator(1) + event(1) + len(1) + num_cmds(1) + opcode(2) + status(1) + addr(6)
        if (n >= 13 and resp[0] == 0x04 and resp[1] == 0x0E and resp[6] == 0x00) {
            log.info("[e2e] PASS: trait/ble/bd_addr — {x}:{x}:{x}:{x}:{x}:{x}", .{
                resp[12], resp[11], resp[10], resp[9], resp[8], resp[7],
            });
        } else {
            log.err("[e2e] FAIL: trait/ble/bd_addr — bad response: {} bytes", .{n});
            return error.HciBdAddrFailed;
        }
    }

    log.info("[e2e] PASS: trait/ble", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/ble — {}", .{err});
    };
}

test "e2e: trait/ble" {
    // BLE test is ESP-only
    return error.SkipZigTest;
}
