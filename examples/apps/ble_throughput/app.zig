//! BLE Full-Duplex Throughput Test
//!
//! Two ESP32-S3 devices: Server (peripheral) + Client (central).
//! After GAP connection, both simultaneously flood data and measure throughput.
//!
//! Role selection by MAC address prefix:
//!   98:88:E0:11:xx:xx → Server (peripheral, advertises "ZigBLE")
//!   98:88:E0:16:xx:xx → Client (central, scans + connects)
//!
//! Test flow:
//! 1. GAP connection at 7.5ms interval
//! 2. Negotiate: DLE 251, MTU 512 (via ATT Exchange MTU)
//! 3. Round 1: 10s full-duplex flood at 1M PHY
//! 4. PHY upgrade to 2M
//! 5. Round 2: 10s full-duplex flood at 2M PHY
//! 6. Print comparison summary

const std = @import("std");
const esp = @import("esp");
const bluetooth = @import("bluetooth");
const cancellation = @import("cancellation");
const waitgroup = @import("waitgroup");

const idf = esp.idf;
const bt = idf.bt;
const heap = idf.heap;
const hci_cmds = bluetooth.hci.commands;
const hci_events = bluetooth.hci.events;
const hci = bluetooth.hci;
const gap = bluetooth.gap;
const att = bluetooth.att;
const l2cap = bluetooth.l2cap;
const acl = bluetooth.hci.acl;

const EspRt = idf.runtime;
const WG = waitgroup.WaitGroup(EspRt);

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// ============================================================================
// Constants
// ============================================================================

/// Advertising name
const ADV_NAME = "ZigBLE";

/// ATT handle for throughput data (hardcoded, no GATT discovery needed)
const THROUGHPUT_HANDLE: u16 = 0x0001;

/// ATT MTU to negotiate
const TARGET_MTU: u16 = 512;

/// DLE parameters
const DLE_TX_OCTETS: u16 = 251;
const DLE_TX_TIME: u16 = 2120;

/// Payload size per ATT PDU: MTU - 3 (ATT header: opcode + handle)
const ATT_PAYLOAD_SIZE = TARGET_MTU - 3;

/// Initial ACL buffer slots (from LE Read Buffer Size — we got 12 in smoke test)
const INITIAL_ACL_SLOTS: u32 = 12;

/// Duration of each throughput round (milliseconds)
const ROUND_DURATION_MS: u64 = 10_000;

/// Stats reporting interval (milliseconds)
const STATS_INTERVAL_MS: u64 = 1_000;

// ============================================================================
// Role Detection
// ============================================================================

const BleRole = enum {
    server, // peripheral, 98:88:E0:11:xx:xx
    client, // central, 98:88:E0:16:xx:xx
};

fn detectRole() !BleRole {
    // Read BD_ADDR via HCI
    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    const cmd = hci_cmds.encode(&cmd_buf, hci_cmds.READ_BD_ADDR, &.{});

    _ = bt.send(cmd) catch return error.SendFailed;
    if (!bt.waitForData(2000)) return error.Timeout;

    var resp_buf: [256]u8 = undefined;
    const n = bt.recv(&resp_buf) catch return error.RecvFailed;
    if (n < 1 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) return error.BadResponse;

    const evt = hci_events.decode(resp_buf[1..n]) orelse return error.DecodeFailed;
    switch (evt) {
        .command_complete => |cc| {
            if (!cc.status.isSuccess() or cc.return_params.len < 6) return error.CommandFailed;
            const addr = cc.return_params[0..6];

            log.info("BD_ADDR: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
                addr[5], addr[4], addr[3], addr[2], addr[1], addr[0],
            });

            // BD_ADDR from HCI is little-endian:
            //   addr[0..6] = [52, 5C, 11, E0, 88, 98] for 98:88:E0:11:5C:52
            // Check byte at index 2 to distinguish devices:
            //   0x11 → 98:88:E0:11:xx:xx → Server
            //   0x16 → 98:88:E0:16:xx:xx → Client
            if (addr[2] == 0x11) {
                return .server;
            } else {
                return .client;
            }
        },
        else => return error.WrongEvent,
    }
}

// ============================================================================
// HCI Helpers (direct HCI for init, before Host starts)
// ============================================================================

/// Send an HCI command and wait for the matching Command Complete/Status response.
/// Drains any non-matching events from the queue.
fn hciSendAndWait(cmd: []const u8, resp_buf: []u8) !usize {
    const expected_opcode = @as(u16, cmd[1]) | (@as(u16, cmd[2]) << 8);

    _ = bt.send(cmd) catch |err| {
        log.err("HCI send failed: {}", .{err});
        return error.SendFailed;
    };

    // Wait for matching response (drain non-matching events)
    const deadline = idf.time.nowMs() + 3000;
    while (idf.time.nowMs() < deadline) {
        if (!bt.waitForData(500)) continue;

        const n = bt.recv(resp_buf) catch continue;
        if (n < 2 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) continue;

        const evt = hci_events.decode(resp_buf[1..n]) orelse continue;
        switch (evt) {
            .command_complete => |cc| {
                if (cc.opcode == expected_opcode) return n;
                // Not our command — log and continue
            },
            .command_status => |cs| {
                if (cs.opcode == expected_opcode) return n;
            },
            else => {}, // Other events (e.g., connection) — ignore for now
        }
    }

    log.err("HCI response timeout for cmd 0x{X:0>4}", .{expected_opcode});
    return error.Timeout;
}

// ============================================================================
// Server Role (Peripheral)
// ============================================================================

fn runServer() void {
    log.info("=== SERVER (Peripheral) ===", .{});

    // Build advertising data
    const flags = [_]u8{ 0x02, 0x01, 0x06 }; // LE General Discoverable + BR/EDR Not Supported
    const name_ad = [_]u8{ ADV_NAME.len + 1, 0x09 } ++ ADV_NAME.*;
    const adv_data = flags ++ name_ad;

    // Start advertising via raw HCI (before we have a Host)
    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    var resp_buf: [256]u8 = undefined;

    // Set advertising parameters (fast: 20ms interval for quick discovery)
    {
        const cmd = hci_cmds.leSetAdvParams(&cmd_buf, .{
            .interval_min = 0x0020, // 20ms
            .interval_max = 0x0020,
            .adv_type = .adv_ind,
        });
        _ = hciSendAndWait(cmd, &resp_buf) catch {
            log.err("Failed to set adv params", .{});
            return;
        };
    }

    // Set advertising data
    {
        const cmd = hci_cmds.leSetAdvData(&cmd_buf, &adv_data);
        _ = hciSendAndWait(cmd, &resp_buf) catch {
            log.err("Failed to set adv data", .{});
            return;
        };
    }

    // Enable advertising
    {
        const cmd = hci_cmds.leSetAdvEnable(&cmd_buf, true);
        _ = hciSendAndWait(cmd, &resp_buf) catch {
            log.err("Failed to enable advertising", .{});
            return;
        };
    }

    log.info("Advertising started: \"{s}\"", .{ADV_NAME});
    log.info("Waiting for connection...", .{});

    // Wait for LE Connection Complete event
    var conn_handle: u16 = 0;
    while (true) {
        if (!bt.waitForData(5000)) {
            log.info("Still advertising...", .{});
            continue;
        }

        const n = bt.recv(&resp_buf) catch continue;
        if (n < 2 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) continue;

        const evt = hci_events.decode(resp_buf[1..n]) orelse continue;
        switch (evt) {
            .le_connection_complete => |lc| {
                if (lc.status.isSuccess()) {
                    conn_handle = lc.conn_handle;
                    log.info("Connected! handle=0x{X:0>4}, interval={}, role={}", .{
                        lc.conn_handle,
                        lc.conn_interval,
                        lc.role,
                    });
                    break;
                } else {
                    log.err("Connection failed: status=0x{X:0>2}", .{@intFromEnum(lc.status)});
                }
            },
            else => {},
        }
    }

    // Negotiate DLE
    negotiateDle(conn_handle);

    // Run throughput test
    runThroughputTest(conn_handle, "1M PHY");

    // Upgrade to 2M PHY
    if (upgradePhy(conn_handle)) {
        idf.time.sleepMs(500); // Let PHY settle
        runThroughputTest(conn_handle, "2M PHY");
    }

    log.info("=== SERVER DONE ===", .{});
}

// ============================================================================
// Client Role (Central)
// ============================================================================

fn runClient() void {
    log.info("=== CLIENT (Central) ===", .{});

    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    var resp_buf: [256]u8 = undefined;

    // Set scan parameters
    {
        const cmd = hci_cmds.leSetScanParams(&cmd_buf, .{
            .scan_type = 0x01, // active
            .interval = 0x0010, // 10ms
            .window = 0x0010, // 10ms (continuous)
        });
        const n = hciSendAndWait(cmd, &resp_buf) catch {
            log.err("Failed to set scan params", .{});
            return;
        };
        log.info("Scan params response: {} bytes", .{n});
    }

    // Small delay to ensure controller processed params
    idf.time.sleepMs(10);

    // Enable scanning
    {
        const cmd = hci_cmds.leSetScanEnable(&cmd_buf, true, true);
        const n = hciSendAndWait(cmd, &resp_buf) catch {
            log.err("Failed to enable scanning", .{});
            return;
        };
        log.info("Scan enable response: {} bytes", .{n});
    }

    log.info("Scanning for \"{s}\"...", .{ADV_NAME});

    // Scan for target device
    var target_addr: hci.BdAddr = undefined;
    var target_addr_type: hci.AddrType = .public;
    var found = false;

    while (!found) {
        if (!bt.waitForData(5000)) {
            log.info("Still scanning...", .{});
            continue;
        }

        const n = bt.recv(&resp_buf) catch continue;
        if (n < 2 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) continue;

        const evt = hci_events.decode(resp_buf[1..n]) orelse continue;
        switch (evt) {
            .le_advertising_report => |ar| {
                if (hci_events.parseAdvReport(ar.data)) |report| {
                    // Check if name matches
                    if (containsName(report.data, ADV_NAME)) {
                        target_addr = report.addr;
                        target_addr_type = report.addr_type;
                        found = true;
                        log.info("Found \"{s}\" at {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2} (RSSI: {})", .{
                            ADV_NAME,
                            report.addr[5], report.addr[4], report.addr[3],
                            report.addr[2], report.addr[1], report.addr[0],
                            report.rssi,
                        });
                    }
                }
            },
            else => {},
        }
    }

    // Stop scanning
    {
        const cmd = hci_cmds.leSetScanEnable(&cmd_buf, false, false);
        _ = hciSendAndWait(cmd, &resp_buf) catch {};
    }

    // Create connection (2-phase: Command Status → LE Connection Complete)
    log.info("Connecting to {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}...", .{
        target_addr[5], target_addr[4], target_addr[3],
        target_addr[2], target_addr[1], target_addr[0],
    });
    {
        const cmd = hci_cmds.leCreateConnection(&cmd_buf, .{
            .peer_addr_type = target_addr_type,
            .peer_addr = target_addr,
            .conn_interval_min = 0x0006, // 7.5ms
            .conn_interval_max = 0x0006,
        });
        _ = bt.send(cmd) catch {
            log.err("Failed to send create connection", .{});
            return;
        };
    }

    // Phase 1: wait for Command Status (acknowledges the command)
    {
        const deadline = idf.time.nowMs() + 3000;
        var got_status = false;
        while (idf.time.nowMs() < deadline and !got_status) {
            if (!bt.waitForData(500)) continue;
            const n = bt.recv(&resp_buf) catch continue;
            if (n < 2 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) continue;
            const evt = hci_events.decode(resp_buf[1..n]) orelse continue;
            switch (evt) {
                .command_status => |cs| {
                    if (cs.opcode == hci_cmds.LE_CREATE_CONNECTION) {
                        if (cs.status.isSuccess()) {
                            log.info("Connection initiated (Command Status OK)", .{});
                            got_status = true;
                        } else {
                            log.err("Create Connection rejected: status=0x{X:0>2}", .{@intFromEnum(cs.status)});
                            return;
                        }
                    }
                },
                else => {},
            }
        }
        if (!got_status) {
            log.err("Command Status timeout for LE Create Connection", .{});
            return;
        }
    }

    // Phase 2: wait for LE Connection Complete event
    var conn_handle: u16 = 0;
    {
        const deadline = idf.time.nowMs() + 10000;
        while (idf.time.nowMs() < deadline) {
            if (!bt.waitForData(500)) continue;
            const n = bt.recv(&resp_buf) catch continue;
            if (n < 2 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) continue;
            const evt = hci_events.decode(resp_buf[1..n]) orelse continue;
            switch (evt) {
                .le_connection_complete => |lc| {
                    if (lc.status.isSuccess()) {
                        conn_handle = lc.conn_handle;
                        log.info("Connected! handle=0x{X:0>4}, interval={}, role={}", .{
                            lc.conn_handle,
                            lc.conn_interval,
                            lc.role,
                        });
                        break;
                    } else {
                        log.err("Connection failed: status=0x{X:0>2}", .{@intFromEnum(lc.status)});
                        return;
                    }
                },
                else => {},
            }
        }
        if (conn_handle == 0) {
            log.err("LE Connection Complete timeout", .{});
            return;
        }
    }

    // Negotiate DLE
    negotiateDle(conn_handle);

    // Run throughput test
    runThroughputTest(conn_handle, "1M PHY");

    // Upgrade to 2M PHY
    if (upgradePhy(conn_handle)) {
        idf.time.sleepMs(500);
        runThroughputTest(conn_handle, "2M PHY");
    }

    log.info("=== CLIENT DONE ===", .{});
}

// ============================================================================
// Shared: DLE Negotiation
// ============================================================================

fn negotiateDle(conn_handle: u16) void {
    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
    var resp_buf: [256]u8 = undefined;

    const cmd = hci_cmds.leSetDataLength(&cmd_buf, conn_handle, DLE_TX_OCTETS, DLE_TX_TIME);
    _ = hciSendAndWait(cmd, &resp_buf) catch {
        log.warn("DLE negotiation failed", .{});
        return;
    };

    // Wait for Data Length Change event
    const deadline = idf.time.nowMs() + 2000;
    while (idf.time.nowMs() < deadline) {
        if (!bt.waitForData(100)) continue;
        const n = bt.recv(&resp_buf) catch continue;
        if (n < 2 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) continue;
        const evt = hci_events.decode(resp_buf[1..n]) orelse continue;
        switch (evt) {
            .le_data_length_change => |dl| {
                log.info("DLE: TX={} bytes/{}us, RX={} bytes/{}us", .{
                    dl.max_tx_octets, dl.max_tx_time,
                    dl.max_rx_octets, dl.max_rx_time,
                });
                return;
            },
            else => {},
        }
    }
    log.warn("DLE change event timeout", .{});
}

// ============================================================================
// Shared: PHY Upgrade
// ============================================================================

fn upgradePhy(conn_handle: u16) bool {
    log.info("Requesting 2M PHY upgrade...", .{});
    var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;

    // Request 2M PHY for both TX and RX
    const cmd = hci_cmds.leSetPhy(&cmd_buf, conn_handle, 0x00, 0x02, 0x02, 0x0000);
    _ = bt.send(cmd) catch {
        log.err("Failed to send PHY request", .{});
        return false;
    };

    // Wait for PHY Update Complete event
    var resp_buf: [256]u8 = undefined;
    const deadline = idf.time.nowMs() + 5000;
    while (idf.time.nowMs() < deadline) {
        if (!bt.waitForData(100)) continue;
        const n = bt.recv(&resp_buf) catch continue;
        if (n < 2 or resp_buf[0] != @intFromEnum(hci.PacketType.event)) continue;
        const evt = hci_events.decode(resp_buf[1..n]) orelse continue;
        switch (evt) {
            .le_phy_update_complete => |pu| {
                if (pu.status.isSuccess()) {
                    const phy_name = switch (pu.tx_phy) {
                        1 => "1M",
                        2 => "2M",
                        3 => "Coded",
                        else => "Unknown",
                    };
                    log.info("PHY updated: TX={s}, RX={s}", .{
                        phy_name,
                        switch (pu.rx_phy) {
                            1 => "1M",
                            2 => "2M",
                            3 => "Coded",
                            else => "Unknown",
                        },
                    });
                    return true;
                } else {
                    log.err("PHY update failed: status=0x{X:0>2}", .{@intFromEnum(pu.status)});
                    return false;
                }
            },
            else => {},
        }
    }
    log.err("PHY update timeout", .{});
    return false;
}

// ============================================================================
// Shared: Throughput Test
// ============================================================================

// ============================================================================
// Throughput Test Context (shared between TX and RX tasks)
// ============================================================================

const ThroughputCtx = struct {
    conn_handle: u16,
    cancel: cancellation.CancellationToken,

    // TX stats (written by TX task, read by main) — u32 for Xtensa atomic support
    tx_bytes: std.atomic.Value(u32),
    tx_packets: std.atomic.Value(u32),

    // RX stats (written by RX task, read by main)
    rx_bytes: std.atomic.Value(u32),
    rx_packets: std.atomic.Value(u32),

    // HCI ACL flow control: available buffer slots in controller
    // Initialized from LE_Read_Buffer_Size (typically 12)
    // TX task decrements per ACL fragment sent
    // RX task increments when Number_of_Completed_Packets event received
    acl_slots: std.atomic.Value(u32),

    // NCP events received (diagnostic)
    ncp_events: std.atomic.Value(u32),

    // Pre-built ACL fragments for TX
    acl_pkts: [4][acl.MAX_PACKET_LEN]u8,
    acl_lens: [4]usize,
    num_frags: usize,

    fn init(conn_handle: u16, initial_acl_slots: u32) ThroughputCtx {
        var ctx = ThroughputCtx{
            .conn_handle = conn_handle,
            .cancel = cancellation.CancellationToken.init(),
            .tx_bytes = std.atomic.Value(u32).init(0),
            .tx_packets = std.atomic.Value(u32).init(0),
            .rx_bytes = std.atomic.Value(u32).init(0),
            .rx_packets = std.atomic.Value(u32).init(0),
            .acl_slots = std.atomic.Value(u32).init(initial_acl_slots),
            .ncp_events = std.atomic.Value(u32).init(0),
            .acl_pkts = undefined,
            .acl_lens = undefined,
            .num_frags = 0,
        };

        // Build ATT Write Without Response PDU
        var att_pdu: [att.MAX_PDU_LEN]u8 = undefined;
        att_pdu[0] = @intFromEnum(att.Opcode.write_command);
        std.mem.writeInt(u16, att_pdu[1..3], THROUGHPUT_HANDLE, .little);
        const att_pdu_len = 3 + ATT_PAYLOAD_SIZE;
        // Fill payload with pattern
        for (3..att_pdu_len) |i| {
            att_pdu[i] = @truncate(i);
        }

        // Build L2CAP frame
        var l2cap_pkt: [520]u8 = undefined;
        std.mem.writeInt(u16, l2cap_pkt[0..2], @intCast(att_pdu_len), .little);
        std.mem.writeInt(u16, l2cap_pkt[2..4], l2cap.CID_ATT, .little);
        @memcpy(l2cap_pkt[4..][0..att_pdu_len], att_pdu[0..att_pdu_len]);
        const l2cap_total = 4 + att_pdu_len;

        // Fragment into ACL packets
        var offset: usize = 0;
        var first = true;
        while (offset < l2cap_total) {
            const chunk_len = @min(l2cap_total - offset, DLE_TX_OCTETS);
            const pb_flag: acl.PBFlag = if (first) .first_auto_flush else .continuing;
            const frag = acl.encode(
                &ctx.acl_pkts[ctx.num_frags],
                conn_handle,
                pb_flag,
                l2cap_pkt[offset..][0..chunk_len],
            );
            ctx.acl_lens[ctx.num_frags] = frag.len;
            ctx.num_frags += 1;
            offset += chunk_len;
            first = false;
        }

        return ctx;
    }
};

// ============================================================================
// TX Task — runs in its own FreeRTOS task
// ============================================================================

fn txTaskFn(raw_ctx: ?*anyopaque) void {
    const ctx: *ThroughputCtx = @ptrCast(@alignCast(raw_ctx));

    while (!ctx.cancel.isCancelled()) {
        // Send all fragments of one PDU
        var ok = true;
        for (0..ctx.num_frags) |i| {
            // HCI ACL flow control: wait until controller has free buffer slots
            while (ctx.acl_slots.load(.acquire) == 0 and !ctx.cancel.isCancelled()) {
                idf.rtos.delayMs(1); // Yield, wait for NCP event to free slots
            }
            if (ctx.cancel.isCancelled()) break;

            // Also check VHCI transport readiness
            while (!bt.canSend() and !ctx.cancel.isCancelled()) {
                idf.rtos.delayMs(0);
            }
            if (ctx.cancel.isCancelled()) break;

            _ = bt.send(ctx.acl_pkts[i][0..ctx.acl_lens[i]]) catch {
                ok = false;
                break;
            };

            // Decrement available ACL slots (one slot per ACL fragment)
            _ = ctx.acl_slots.fetchSub(1, .release);
        }

        if (ok) {
            _ = ctx.tx_bytes.fetchAdd(ATT_PAYLOAD_SIZE, .monotonic);
            _ = ctx.tx_packets.fetchAdd(1, .monotonic);
        }
    }
}

// ============================================================================
// RX Task — runs in its own FreeRTOS task
// ============================================================================

fn rxTaskFn(raw_ctx: ?*anyopaque) void {
    const ctx: *ThroughputCtx = @ptrCast(@alignCast(raw_ctx));
    var resp_buf: [512]u8 = undefined;

    while (!ctx.cancel.isCancelled()) {
        // Block until data arrives (100ms timeout to check cancel)
        if (!bt.waitForData(100)) continue;

        // Drain all available packets
        while (bt.hasData()) {
            const n = bt.recv(&resp_buf) catch break;
            if (n == 0) break;

            if (resp_buf[0] == @intFromEnum(hci.PacketType.acl_data) and n > 1) {
                // ACL data from remote peer
                if (acl.parseHeader(resp_buf[1..n])) |acl_hdr| {
                    _ = ctx.rx_bytes.fetchAdd(acl_hdr.data_len, .monotonic);
                    _ = ctx.rx_packets.fetchAdd(1, .monotonic);
                }
            } else if (resp_buf[0] == @intFromEnum(hci.PacketType.event) and n > 1) {
                // HCI event — check for Number_of_Completed_Packets
                if (hci_events.decode(resp_buf[1..n])) |evt| {
                    switch (evt) {
                        .num_completed_packets => |ncp| {
                            // Parse completed packet counts and free ACL slots
                            // Format: [num_handles(1)][handle(2)+count(2)] * num_handles
                            var total_completed: u32 = 0;
                            var offset: usize = 0;
                            var remaining = ncp.num_handles;
                            while (remaining > 0 and offset + 4 <= ncp.data.len) : (remaining -= 1) {
                                // Skip handle (2 bytes), read count (2 bytes)
                                const count = std.mem.readInt(u16, ncp.data[offset + 2 ..][0..2], .little);
                                total_completed += count;
                                offset += 4;
                            }
                            if (total_completed > 0) {
                                _ = ctx.acl_slots.fetchAdd(total_completed, .release);
                                _ = ctx.ncp_events.fetchAdd(1, .monotonic);
                            }
                        },
                        else => {}, // Other events silently consumed
                    }
                }
            }
        }
    }
}

// ============================================================================
// Throughput Test — spawns TX + RX as separate FreeRTOS tasks
// ============================================================================

fn runThroughputTest(conn_handle: u16, phy_label: []const u8) void {
    log.info("", .{});
    log.info("=== Throughput Test: {s} ({} seconds) ===", .{ phy_label, ROUND_DURATION_MS / 1000 });

    var ctx = ThroughputCtx.init(conn_handle, INITIAL_ACL_SLOTS);
    log.info("TX PDU: {} bytes ATT payload, {} ACL fragments", .{ ATT_PAYLOAD_SIZE, ctx.num_frags });
    log.info("Architecture: TX task + RX task (dual FreeRTOS tasks)", .{});
    log.info("HCI ACL flow control: {} initial slots", .{INITIAL_ACL_SLOTS});

    // Spawn TX and RX tasks via WaitGroup
    var wg = WG.init(heap.iram);
    defer wg.deinit();

    wg.go("ble-tx", txTaskFn, &ctx, .{
        .stack_size = 8192,
        .priority = 18,
        .allocator = heap.iram,
    }) catch {
        log.err("Failed to spawn TX task", .{});
        return;
    };

    wg.go("ble-rx", rxTaskFn, &ctx, .{
        .stack_size = 8192,
        .priority = 19, // RX slightly higher priority than TX
        .allocator = heap.iram,
    }) catch {
        log.err("Failed to spawn RX task", .{});
        ctx.cancel.cancel();
        wg.wait();
        return;
    };

    // Main thread: print stats every second, then stop after duration
    const start_time = idf.time.nowMs();
    var last_stats_time = start_time;

    while (idf.time.nowMs() - start_time < ROUND_DURATION_MS) {
        idf.time.sleepMs(100);

        const now = idf.time.nowMs();
        if (now - last_stats_time >= STATS_INTERVAL_MS) {
            const elapsed_s = @as(f32, @floatFromInt(now - start_time)) / 1000.0;
            const tx_b = ctx.tx_bytes.load(.monotonic);
            const tx_p = ctx.tx_packets.load(.monotonic);
            const rx_b = ctx.rx_bytes.load(.monotonic);
            const rx_p = ctx.rx_packets.load(.monotonic);
            const tx_kbs = if (elapsed_s > 0) @as(f32, @floatFromInt(tx_b)) / 1024.0 / elapsed_s else 0;
            const rx_kbs = if (elapsed_s > 0) @as(f32, @floatFromInt(rx_b)) / 1024.0 / elapsed_s else 0;
            const slots = ctx.acl_slots.load(.monotonic);
            const ncps = ctx.ncp_events.load(.monotonic);
            log.info("[{d:.0}s] TX: {d:.1} KB/s ({} pkts) | RX: {d:.1} KB/s ({} pkts) | slots={} ncp={}", .{
                elapsed_s, tx_kbs, tx_p, rx_kbs, rx_p, slots, ncps,
            });
            last_stats_time = now;
        }
    }

    // Stop tasks
    ctx.cancel.cancel();
    wg.wait();

    // Final summary
    const total_s = @as(f32, @floatFromInt(ROUND_DURATION_MS)) / 1000.0;
    const tx_b = ctx.tx_bytes.load(.monotonic);
    const tx_p = ctx.tx_packets.load(.monotonic);
    const rx_b = ctx.rx_bytes.load(.monotonic);
    const rx_p = ctx.rx_packets.load(.monotonic);
    const final_tx_kbs = @as(f32, @floatFromInt(tx_b)) / 1024.0 / total_s;
    const final_rx_kbs = @as(f32, @floatFromInt(rx_b)) / 1024.0 / total_s;
    log.info("--- {s} Summary ---", .{phy_label});
    log.info("TX: {d:.1} KB/s avg ({} bytes, {} packets)", .{ final_tx_kbs, tx_b, tx_p });
    log.info("RX: {d:.1} KB/s avg ({} bytes, {} packets)", .{ final_rx_kbs, rx_b, rx_p });
    log.info("", .{});
}

// ============================================================================
// Helpers
// ============================================================================

/// Check if AD structures contain a Complete Local Name matching `name`
fn containsName(ad_data: []const u8, name: []const u8) bool {
    var offset: usize = 0;
    while (offset < ad_data.len) {
        if (ad_data[offset] == 0) break;
        const len = ad_data[offset];
        if (offset + 1 + len > ad_data.len) break;
        const ad_type = ad_data[offset + 1];
        if (ad_type == 0x09 or ad_type == 0x08) { // Complete or Shortened Local Name
            const ad_name = ad_data[offset + 2 .. offset + 1 + len];
            if (std.mem.eql(u8, ad_name, name)) return true;
        }
        offset += 1 + len;
    }
    return false;
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("BLE Full-Duplex Throughput Test", .{});
    log.info("==========================================", .{});
    log.info("Board: {s}", .{Board.meta.id});
    log.info("==========================================", .{});

    // Initialize board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    // Initialize BLE controller
    log.info("Initializing BLE controller (VHCI)...", .{});
    bt.init() catch |err| {
        log.err("BLE controller init failed: {}", .{err});
        return;
    };
    defer bt.deinit();
    log.info("BLE controller initialized OK", .{});
    idf.time.sleepMs(100);

    // HCI Reset
    {
        var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
        var resp_buf: [256]u8 = undefined;
        const cmd = hci_cmds.reset(&cmd_buf);
        _ = hciSendAndWait(cmd, &resp_buf) catch {
            log.err("HCI Reset failed", .{});
            return;
        };
        log.info("HCI Reset: OK", .{});
    }

    // Set Event Masks (enable LE events)
    {
        var cmd_buf: [hci_cmds.MAX_CMD_LEN]u8 = undefined;
        var resp_buf: [256]u8 = undefined;
        // Enable: Disconnection Complete + LE Meta + Num Completed Packets
        _ = hciSendAndWait(hci_cmds.setEventMask(&cmd_buf, 0x3DBFF807FFFBFFFF), &resp_buf) catch {};
        // Enable: Connection Complete + Advertising Report + Connection Update +
        // Data Length Change + PHY Update Complete
        _ = hciSendAndWait(hci_cmds.leSetEventMask(&cmd_buf, 0x000000000000097F), &resp_buf) catch {};
    }

    // Detect role by MAC address
    const role = detectRole() catch |err| {
        log.err("Role detection failed: {}", .{err});
        return;
    };

    log.info("Role: {s}", .{switch (role) {
        .server => "SERVER (Peripheral)",
        .client => "CLIENT (Central)",
    }});
    log.info("", .{});

    switch (role) {
        .server => runServer(),
        .client => runClient(),
    }

    // Keep alive
    while (true) {
        idf.time.sleepMs(5000);
        log.info("Still alive... uptime={}ms", .{board.uptime()});
    }
}
