//! BLE Full-Duplex Throughput Test — Host API
//!
//! Two ESP32-S3 devices: Server (peripheral) + Client (central).
//! Uses bluetooth.Host with HCI ACL flow control.
//!
//! Role auto-detected by BD_ADDR:
//!   98:88:E0:11:xx:xx → Server (peripheral, advertises "ZigBLE")
//!   98:88:E0:16:xx:xx → Client (central, scans + connects)

const std = @import("std");
const esp = @import("esp");
const bluetooth = @import("bluetooth");
const cancellation = @import("cancellation");
const waitgroup = @import("waitgroup");

const idf = esp.idf;
const heap = idf.heap;
const gap = bluetooth.gap;
const att = bluetooth.att;
const l2cap = bluetooth.l2cap;
const hci = bluetooth.hci;

const EspRt = idf.runtime;
const WG = waitgroup.WaitGroup(EspRt);
const HciDriver = esp.impl.hci.HciDriver;
const BleHost = bluetooth.Host(EspRt, HciDriver, 4);

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// ============================================================================
// Constants
// ============================================================================

const ADV_NAME = "ZigBLE";
const THROUGHPUT_HANDLE: u16 = 0x0001;
const ROUND_DURATION_MS: u64 = 10_000;
const STATS_INTERVAL_MS: u64 = 1_000;

// ============================================================================
// TX Flood Task
// ============================================================================

const FloodCtx = struct {
    host: *BleHost,
    conn_handle: u16,
    cancel: cancellation.CancellationToken,
    tx_bytes: std.atomic.Value(u32),
    tx_packets: std.atomic.Value(u32),

    fn init(host: *BleHost, conn_handle: u16) FloodCtx {
        return .{
            .host = host,
            .conn_handle = conn_handle,
            .cancel = cancellation.CancellationToken.init(),
            .tx_bytes = std.atomic.Value(u32).init(0),
            .tx_packets = std.atomic.Value(u32).init(0),
        };
    }
};

fn txFloodTask(raw_ctx: ?*anyopaque) void {
    const ctx: *FloodCtx = @ptrCast(@alignCast(raw_ctx));

    // Payload: ATT Write Without Response, fits in one ACL fragment (251 - 4 L2CAP header = 247 - 3 ATT header = 244)
    const payload_size: u32 = 244;
    var att_pdu: [247]u8 = undefined;
    att_pdu[0] = @intFromEnum(att.Opcode.write_command);
    std.mem.writeInt(u16, att_pdu[1..3], THROUGHPUT_HANDLE, .little);
    for (3..3 + payload_size) |i| {
        att_pdu[i] = @truncate(i);
    }

    while (!ctx.cancel.isCancelled()) {
        // host.sendData → L2CAP fragment → tx_queue → writeLoop → acl_credits.acquire → hci.write
        ctx.host.sendData(ctx.conn_handle, l2cap.CID_ATT, att_pdu[0 .. 3 + payload_size]) catch break;
        _ = ctx.tx_bytes.fetchAdd(payload_size, .monotonic);
        _ = ctx.tx_packets.fetchAdd(1, .monotonic);
    }
}

// ============================================================================
// Server (Peripheral)
// ============================================================================

fn runServer(host: *BleHost) void {
    log.info("=== SERVER (Peripheral) ===", .{});

    const adv_data = [_]u8{
        0x02, 0x01, 0x06,
    } ++ [_]u8{ ADV_NAME.len + 1, 0x09 } ++ ADV_NAME.*;

    host.startAdvertising(.{
        .interval_min = 0x0020,
        .interval_max = 0x0020,
        .adv_data = &adv_data,
    }) catch {
        log.err("Failed to start advertising", .{});
        return;
    };
    log.info("Advertising \"{s}\"...", .{ADV_NAME});

    // Wait for connection event
    while (host.nextEvent()) |event| {
        switch (event) {
            .connected => |info| {
                log.info("Connected! handle=0x{X:0>4}, interval={}", .{ info.conn_handle, info.conn_interval });
                // Server: don't initiate PHY upgrade (client does it)
                runConnected(host, info.conn_handle, false);
                return;
            },
            .advertising_stopped => log.info("Advertising stopped", .{}),
            else => {},
        }
    }
}

// ============================================================================
// Client (Central)
// ============================================================================

fn runClient(host: *BleHost) void {
    log.info("=== CLIENT (Central) ===", .{});

    host.startScanning(.{}) catch {
        log.err("Failed to start scanning", .{});
        return;
    };
    log.info("Scanning for \"{s}\"...", .{ADV_NAME});

    while (host.nextEvent()) |event| {
        switch (event) {
            .device_found => |report| {
                if (containsName(report.data, ADV_NAME)) {
                    log.info("Found \"{s}\" (RSSI: {})", .{ ADV_NAME, report.rssi });
                    host.connect(report.addr, report.addr_type, .{
                        .interval_min = 0x0006,
                        .interval_max = 0x0006,
                    }) catch {
                        log.err("Failed to initiate connection", .{});
                        return;
                    };
                }
            },
            .connected => |info| {
                log.info("Connected! handle=0x{X:0>4}, interval={}", .{ info.conn_handle, info.conn_interval });
                // Client initiates PHY upgrade
                runConnected(host, info.conn_handle, true);
                return;
            },
            .connection_failed => |status| {
                log.err("Connection failed: 0x{X:0>2}", .{@intFromEnum(status)});
                return;
            },
            else => {},
        }
    }
}

// ============================================================================
// Connected: DLE + Throughput + PHY upgrade
// ============================================================================

fn runConnected(host: *BleHost, conn_handle: u16, initiate_phy: bool) void {
    // DLE negotiation
    host.requestDataLength(conn_handle, 251, 2120) catch {};
    _ = drainEventsUntil(host, 2000, .data_length_changed);

    // Round 1: 1M PHY
    runRound(host, conn_handle, "1M PHY");

    // PHY upgrade (only one side)
    if (initiate_phy) {
        host.requestPhyUpdate(conn_handle, 0x02, 0x02) catch {};
    }
    if (drainEventsUntil(host, 5000, .phy_updated)) {
        idf.time.sleepMs(200);
        runRound(host, conn_handle, "2M PHY");
    } else {
        log.warn("PHY update not received, skipping 2M round", .{});
    }
}

const EventTag = std.meta.Tag(gap.GapEvent);

fn drainEventsUntil(host: *BleHost, timeout_ms: u64, target: EventTag) bool {
    const deadline = idf.time.nowMs() + timeout_ms;
    while (idf.time.nowMs() < deadline) {
        if (host.tryNextEvent()) |evt| {
            const tag = std.meta.activeTag(evt);
            // Log interesting events
            switch (evt) {
                .data_length_changed => |dl| log.info("DLE: TX={}/{}us RX={}/{}us", .{
                    dl.max_tx_octets, dl.max_tx_time, dl.max_rx_octets, dl.max_rx_time,
                }),
                .phy_updated => |pu| log.info("PHY: TX={s} RX={s}", .{
                    phyName(pu.tx_phy), phyName(pu.rx_phy),
                }),
                else => {},
            }
            if (tag == target) return true;
        } else {
            idf.time.sleepMs(10);
        }
    }
    return false;
}

// ============================================================================
// Throughput Round
// ============================================================================

fn runRound(host: *BleHost, conn_handle: u16, phy_label: []const u8) void {
    log.info("", .{});
    log.info("=== Throughput: {s} ({} seconds) ===", .{ phy_label, ROUND_DURATION_MS / 1000 });
    log.info("ACL: credits={} max_len={}", .{ host.getAclCredits(), host.getAclMaxLen() });

    // Drain stale events
    while (host.tryNextEvent()) |_| {}

    var flood = FloodCtx.init(host, conn_handle);

    var wg = WG.init(heap.iram);
    defer wg.deinit();

    wg.go("tx-flood", txFloodTask, &flood, .{
        .stack_size = 8192,
        .priority = 18,
        .allocator = heap.iram,
    }) catch {
        log.err("Failed to spawn TX task", .{});
        return;
    };

    // Stats loop
    const start_time = idf.time.nowMs();
    var last_stats = start_time;

    while (idf.time.nowMs() - start_time < ROUND_DURATION_MS) {
        idf.time.sleepMs(100);
        while (host.tryNextEvent()) |_| {} // drain

        const now = idf.time.nowMs();
        if (now - last_stats >= STATS_INTERVAL_MS) {
            const elapsed_s = @as(f32, @floatFromInt(now - start_time)) / 1000.0;
            const tx_b = flood.tx_bytes.load(.monotonic);
            const tx_p = flood.tx_packets.load(.monotonic);
            const credits = host.getAclCredits();
            const tx_kbs = if (elapsed_s > 0) @as(f32, @floatFromInt(tx_b)) / 1024.0 / elapsed_s else 0;
            log.info("[{d:.0}s] TX: {d:.1} KB/s ({} pkts) | credits={}", .{
                elapsed_s, tx_kbs, tx_p, credits,
            });
            last_stats = now;
        }
    }

    flood.cancel.cancel();
    wg.wait();

    const total_s = @as(f32, @floatFromInt(ROUND_DURATION_MS)) / 1000.0;
    const tx_b = flood.tx_bytes.load(.monotonic);
    const tx_p = flood.tx_packets.load(.monotonic);
    log.info("--- {s} Summary ---", .{phy_label});
    log.info("TX: {d:.1} KB/s avg ({} bytes, {} packets)", .{
        @as(f32, @floatFromInt(tx_b)) / 1024.0 / total_s, tx_b, tx_p,
    });
    log.info("", .{});
}

// ============================================================================
// Helpers
// ============================================================================

fn containsName(ad_data: []const u8, name: []const u8) bool {
    var offset: usize = 0;
    while (offset < ad_data.len) {
        if (ad_data[offset] == 0) break;
        const len = ad_data[offset];
        if (offset + 1 + len > ad_data.len) break;
        const ad_type = ad_data[offset + 1];
        if (ad_type == 0x09 or ad_type == 0x08) {
            const ad_name = ad_data[offset + 2 .. offset + 1 + len];
            if (std.mem.eql(u8, ad_name, name)) return true;
        }
        offset += 1 + len;
    }
    return false;
}

fn phyName(phy: u8) []const u8 {
    return switch (phy) {
        1 => "1M",
        2 => "2M",
        3 => "Coded",
        else => "?",
    };
}

// ============================================================================
// Main
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("BLE Throughput Test (Host API)", .{});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    // Create HCI driver (initializes BLE controller via VHCI)
    log.info("Initializing BLE controller...", .{});
    var hci_driver = HciDriver.init() catch {
        log.err("HCI driver init failed", .{});
        return;
    };
    defer hci_driver.deinit();
    log.info("BLE controller OK", .{});

    // Create and start Host
    var host = BleHost.init(&hci_driver, heap.psram);
    defer host.deinit();

    host.start(.{
        .stack_size = 8192,
        .priority = 20,
        .allocator = heap.iram,
    }) catch |err| {
        log.err("Host start failed: {}", .{err});
        return;
    };
    defer host.stop();

    log.info("Host started: ACL slots={} max_len={}", .{ host.acl_max_slots, host.acl_max_len });

    // Detect role from BD_ADDR (read during Host.start)
    const addr = host.getBdAddr();
    log.info("BD_ADDR: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        addr[5], addr[4], addr[3], addr[2], addr[1], addr[0],
    });

    const role: enum { server, client } = if (addr[2] == 0x11) .server else .client;
    log.info("Role: {s}", .{switch (role) {
        .server => "SERVER (Peripheral)",
        .client => "CLIENT (Central)",
    }});
    log.info("", .{});

    switch (role) {
        .server => runServer(&host),
        .client => runClient(&host),
    }

    log.info("=== DONE ===", .{});
    while (true) {
        idf.time.sleepMs(5000);
        log.info("Still alive... uptime={}ms", .{board.uptime()});
    }
}
