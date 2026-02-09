//! BLE GATT Duplex Throughput Test — Host API + GATT Server
//!
//! Server registers a GATT service with notify + write characteristics.
//! Client connects, enables notifications, then both flood simultaneously:
//!   Server → Client: GATT Notifications
//!   Client → Server: ATT Write Without Response
//!
//! Role auto-detected by BD_ADDR.

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
const gatt = bluetooth.gatt_server;

const EspRt = idf.runtime;
const WG = waitgroup.WaitGroup(EspRt);
const HciDriver = esp.impl.hci.HciDriver;

// ============================================================================
// GATT Service Definition (comptime)
// ============================================================================

/// Custom throughput test service
const SVC_UUID: u16 = 0xFFE0;
/// Write characteristic (client → server)
const CHR_WRITE_UUID: u16 = 0xFFE1;
/// Notify characteristic (server → client)
const CHR_NOTIFY_UUID: u16 = 0xFFE2;

const service_table = &[_]gatt.ServiceDef{
    gatt.Service(SVC_UUID, &[_]gatt.CharDef{
        gatt.Char(CHR_WRITE_UUID, .{ .write_without_response = true }),
        gatt.Char(CHR_NOTIFY_UUID, .{ .read = true, .notify = true }),
    }),
};

const BleHost = bluetooth.Host(EspRt, HciDriver, service_table);
const GattType = gatt.GattServer(service_table);

/// Comptime-resolved ATT handles
const WRITE_VALUE_HANDLE = GattType.getValueHandle(SVC_UUID, CHR_WRITE_UUID);
const NOTIFY_VALUE_HANDLE = GattType.getValueHandle(SVC_UUID, CHR_NOTIFY_UUID);
// CCCD handle is always notify_value_handle + 1
const NOTIFY_CCCD_HANDLE = NOTIFY_VALUE_HANDLE + 1;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// ============================================================================
// Constants
// ============================================================================

const ADV_NAME = "ZigBLE";
const ROUND_DURATION_MS: u64 = 10_000;
const STATS_INTERVAL_MS: u64 = 1_000;
const PAYLOAD_SIZE: u32 = 244; // fits in one ACL fragment (251 - 4 L2CAP - 3 ATT)

// ============================================================================
// Shared stats
// ============================================================================

var rx_bytes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var rx_packets: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ============================================================================
// GATT Write Handler (called async by Host for each Write Command)
// ============================================================================

fn writeHandler(req: *gatt.Request, w: *gatt.ResponseWriter) void {
    _ = w;
    // Count incoming write bytes (server RX)
    _ = rx_bytes.fetchAdd(@intCast(req.data.len), .monotonic);
    _ = rx_packets.fetchAdd(1, .monotonic);
}

/// Notification received callback (client RX)
fn notificationCallback(_: u16, _: u16, data: []const u8) void {
    _ = rx_bytes.fetchAdd(@intCast(data.len), .monotonic);
    _ = rx_packets.fetchAdd(1, .monotonic);
}

// ============================================================================
// TX Flood: send notifications (server) or write commands (client)
// ============================================================================

const FloodCtx = struct {
    host: *BleHost,
    conn_handle: u16,
    cancel: cancellation.CancellationToken,
    tx_bytes: std.atomic.Value(u32),
    tx_packets: std.atomic.Value(u32),
    use_notify: bool, // true = server sends notifications, false = client sends write cmd
};

fn txFloodTask(raw_ctx: ?*anyopaque) void {
    const ctx: *FloodCtx = @ptrCast(@alignCast(raw_ctx));

    var payload: [PAYLOAD_SIZE]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    while (!ctx.cancel.isCancelled()) {
        if (ctx.use_notify) {
            // Server: send GATT notification
            ctx.host.notify(ctx.conn_handle, NOTIFY_VALUE_HANDLE, &payload) catch break;
        } else {
            // Client: send ATT Write Without Response
            var att_pdu: [3 + PAYLOAD_SIZE]u8 = undefined;
            att_pdu[0] = @intFromEnum(att.Opcode.write_command);
            std.mem.writeInt(u16, att_pdu[1..3], WRITE_VALUE_HANDLE, .little);
            @memcpy(att_pdu[3..][0..PAYLOAD_SIZE], &payload);
            ctx.host.sendData(ctx.conn_handle, l2cap.CID_ATT, &att_pdu) catch break;
        }
        _ = ctx.tx_bytes.fetchAdd(PAYLOAD_SIZE, .monotonic);
        _ = ctx.tx_packets.fetchAdd(1, .monotonic);
    }
}

// ============================================================================
// Server
// ============================================================================

fn runServer(host: *BleHost) void {
    log.info("=== SERVER (Peripheral + GATT) ===", .{});
    log.info("Service: 0x{X:0>4}", .{SVC_UUID});
    log.info("  Write char:  handle={} (0x{X:0>4})", .{ WRITE_VALUE_HANDLE, CHR_WRITE_UUID });
    log.info("  Notify char: handle={} (0x{X:0>4}), CCCD={}", .{ NOTIFY_VALUE_HANDLE, CHR_NOTIFY_UUID, NOTIFY_CCCD_HANDLE });

    // Register write handler
    host.gatt.handle(SVC_UUID, CHR_WRITE_UUID, writeHandler, null);

    const adv_data = [_]u8{ 0x02, 0x01, 0x06 } ++ [_]u8{ ADV_NAME.len + 1, 0x09 } ++ ADV_NAME.*;

    host.startAdvertising(.{
        .interval_min = 0x0020,
        .interval_max = 0x0020,
        .adv_data = &adv_data,
    }) catch {
        log.err("Failed to start advertising", .{});
        return;
    };
    log.info("Advertising \"{s}\"...", .{ADV_NAME});

    while (host.nextEvent()) |event| {
        switch (event) {
            .connected => |info| {
                log.info("Connected! handle=0x{X:0>4}", .{info.conn_handle});
                runConnected(host, info.conn_handle, true); // server sends notifications
                return;
            },
            else => {},
        }
    }
}

// ============================================================================
// Client
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
                        log.err("Failed to connect", .{});
                        return;
                    };
                }
            },
            .connected => |info| {
                log.info("Connected! handle=0x{X:0>4}", .{info.conn_handle});

                // Register notification callback for RX counting
                host.setNotificationCallback(notificationCallback);

                // Enable notifications by writing CCCD
                log.info("Enabling notifications (CCCD handle={})...", .{NOTIFY_CCCD_HANDLE});
                var cccd_pdu: [5]u8 = undefined;
                cccd_pdu[0] = @intFromEnum(att.Opcode.write_request);
                std.mem.writeInt(u16, cccd_pdu[1..3], NOTIFY_CCCD_HANDLE, .little);
                cccd_pdu[3] = 0x01; // notifications enabled
                cccd_pdu[4] = 0x00;
                host.sendData(info.conn_handle, l2cap.CID_ATT, &cccd_pdu) catch {};

                // Register write handler for RX counting (client also receives write responses)
                host.gatt.handle(SVC_UUID, CHR_WRITE_UUID, writeHandler, null);

                idf.time.sleepMs(200); // let CCCD write complete

                runConnected(host, info.conn_handle, false); // client sends write commands
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
// Connected: DLE + Throughput
// ============================================================================

fn runConnected(host: *BleHost, conn_handle: u16, is_server: bool) void {
    // DLE
    host.requestDataLength(conn_handle, 251, 2120) catch {};
    drainEventsFor(host, 1000);

    // Round 1: 1M PHY
    runRound(host, conn_handle, is_server, "1M PHY");

    // PHY upgrade (only client initiates)
    if (!is_server) {
        host.requestPhyUpdate(conn_handle, 0x02, 0x02) catch {};
    }
    drainEventsFor(host, 2000);

    // Round 2: 2M PHY
    runRound(host, conn_handle, is_server, "2M PHY");
}

fn drainEventsFor(host: *BleHost, ms: u64) void {
    const deadline = idf.time.nowMs() + ms;
    while (idf.time.nowMs() < deadline) {
        if (host.tryNextEvent()) |evt| {
            switch (evt) {
                .data_length_changed => |dl| log.info("DLE: TX={}/{}us RX={}/{}us", .{
                    dl.max_tx_octets, dl.max_tx_time, dl.max_rx_octets, dl.max_rx_time,
                }),
                .phy_updated => |pu| log.info("PHY: TX={s} RX={s}", .{
                    phyName(pu.tx_phy), phyName(pu.rx_phy),
                }),
                else => {},
            }
        } else {
            idf.time.sleepMs(10);
        }
    }
}

// ============================================================================
// Throughput Round
// ============================================================================

fn runRound(host: *BleHost, conn_handle: u16, is_server: bool, phy_label: []const u8) void {
    log.info("", .{});
    log.info("=== GATT Throughput: {s} ({} sec) ===", .{ phy_label, ROUND_DURATION_MS / 1000 });
    log.info("  {s}: TX via {s}, RX via {s}", .{
        if (is_server) "Server" else "Client",
        if (is_server) "Notification" else "Write Cmd",
        if (is_server) "Write Cmd" else "Notification",
    });
    log.info("  ACL credits={}, max_len={}", .{ host.getAclCredits(), host.getAclMaxLen() });

    // Reset RX counters
    rx_bytes.store(0, .monotonic);
    rx_packets.store(0, .monotonic);

    // Drain stale events
    while (host.tryNextEvent()) |_| {}

    var flood = FloodCtx{
        .host = host,
        .conn_handle = conn_handle,
        .cancel = cancellation.CancellationToken.init(),
        .tx_bytes = std.atomic.Value(u32).init(0),
        .tx_packets = std.atomic.Value(u32).init(0),
        .use_notify = is_server,
    };

    var wg = WG.init(heap.psram);
    defer wg.deinit();

    wg.go("tx-flood", txFloodTask, &flood, .{
        .stack_size = 8192,
        .priority = 18,
        .allocator = heap.psram,
    }) catch {
        log.err("Failed to spawn TX task", .{});
        return;
    };

    const start_time = idf.time.nowMs();
    var last_stats = start_time;

    while (idf.time.nowMs() - start_time < ROUND_DURATION_MS) {
        idf.time.sleepMs(100);
        while (host.tryNextEvent()) |_| {}

        const now = idf.time.nowMs();
        if (now - last_stats >= STATS_INTERVAL_MS) {
            const elapsed_s = @as(f32, @floatFromInt(now - start_time)) / 1000.0;
            const tx_b = flood.tx_bytes.load(.monotonic);
            const rx_b = rx_bytes.load(.monotonic);
            const tx_kbs = if (elapsed_s > 0) @as(f32, @floatFromInt(tx_b)) / 1024.0 / elapsed_s else 0;
            const rx_kbs = if (elapsed_s > 0) @as(f32, @floatFromInt(rx_b)) / 1024.0 / elapsed_s else 0;
            log.info("[{d:.0}s] TX: {d:.1} KB/s ({} pkts) | RX: {d:.1} KB/s ({} pkts) | credits={}", .{
                elapsed_s,
                tx_kbs, flood.tx_packets.load(.monotonic),
                rx_kbs, rx_packets.load(.monotonic),
                host.getAclCredits(),
            });
            last_stats = now;
        }
    }

    flood.cancel.cancel();
    wg.wait();

    const total_s = @as(f32, @floatFromInt(ROUND_DURATION_MS)) / 1000.0;
    const tx_b = flood.tx_bytes.load(.monotonic);
    const rx_b = rx_bytes.load(.monotonic);
    log.info("--- {s} Summary ---", .{phy_label});
    log.info("TX: {d:.1} KB/s ({} bytes, {} pkts)", .{
        @as(f32, @floatFromInt(tx_b)) / 1024.0 / total_s, tx_b, flood.tx_packets.load(.monotonic),
    });
    log.info("RX: {d:.1} KB/s ({} bytes, {} pkts)", .{
        @as(f32, @floatFromInt(rx_b)) / 1024.0 / total_s, rx_b, rx_packets.load(.monotonic),
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
        if (ad_data[offset + 1] == 0x09 or ad_data[offset + 1] == 0x08) {
            if (std.mem.eql(u8, ad_data[offset + 2 .. offset + 1 + len], name)) return true;
        }
        offset += 1 + len;
    }
    return false;
}

fn phyName(phy: u8) []const u8 {
    return switch (phy) { 1 => "1M", 2 => "2M", 3 => "Coded", else => "?" };
}

fn printMemoryReport() void {
    log.info("", .{});
    log.info("=== Memory Footprint ===", .{});

    const internal = heap.getInternalStats();
    const psram_stats = heap.getPsramStats();

    log.info("Internal SRAM:", .{});
    log.info("  Total:      {} KB", .{internal.total / 1024});
    log.info("  Free:       {} KB", .{internal.free / 1024});
    log.info("  Used:       {} KB", .{internal.used / 1024});
    log.info("  Min free:   {} KB (peak usage = {} KB)", .{
        internal.min_free / 1024,
        (internal.total - internal.min_free) / 1024,
    });
    log.info("  Largest blk: {} KB", .{internal.largest_block / 1024});

    if (psram_stats.total > 0) {
        log.info("PSRAM:", .{});
        log.info("  Total:      {} KB", .{psram_stats.total / 1024});
        log.info("  Free:       {} KB", .{psram_stats.free / 1024});
        log.info("  Used:       {} KB", .{psram_stats.used / 1024});
        log.info("  Min free:   {} KB (peak usage = {} KB)", .{
            psram_stats.min_free / 1024,
            (psram_stats.total - psram_stats.min_free) / 1024,
        });
    }

    log.info("BLE Stack usage (Internal SRAM): ~{} KB", .{
        (internal.total - internal.min_free) / 1024,
    });
    log.info("========================", .{});
}

// ============================================================================
// Main
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("BLE GATT Duplex Throughput (Host API)", .{});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Initializing BLE controller...", .{});
    var hci_driver = HciDriver.init() catch {
        log.err("HCI driver init failed", .{});
        return;
    };
    defer hci_driver.deinit();

    var host = BleHost.init(&hci_driver, heap.psram);
    defer host.deinit();

    // Use PSRAM for BLE task stacks — saves ~16KB Internal SRAM
    host.start(.{ .stack_size = 8192, .priority = 20, .allocator = heap.psram }) catch |err| {
        log.err("Host start failed: {}", .{err});
        return;
    };
    defer host.stop();

    log.info("Host: ACL slots={} max_len={}", .{ host.acl_max_slots, host.acl_max_len });

    const addr = host.getBdAddr();
    log.info("BD_ADDR: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        addr[5], addr[4], addr[3], addr[2], addr[1], addr[0],
    });

    const role: enum { server, client } = if (addr[2] == 0x11) .server else .client;
    log.info("Role: {s}", .{if (role == .server) "SERVER" else "CLIENT"});
    log.info("", .{});

    switch (role) {
        .server => runServer(&host),
        .client => runClient(&host),
    }

    // Memory report
    printMemoryReport();

    log.info("=== DONE ===", .{});
    while (true) {
        idf.time.sleepMs(5000);
    }
}
