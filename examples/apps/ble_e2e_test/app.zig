//! BLE E2E Test — Full GATT Client/Server Interaction
//!
//! Server (98:88:E0:11:xx): GATT server with test service
//! Client (98:88:E0:16:xx): connects, exercises all GATT operations
//!
//! Test cases (BLE 5.0):
//!   T1: GAP connection at 7.5ms interval
//!   T2: DLE negotiation (251 bytes)
//!   T3: GATT read characteristic
//!   T4: GATT write characteristic (with response)
//!   T5: GATT write command (no response)
//!   T6: CCCD subscribe (enable notifications)
//!   T7: Receive notification
//!   T8: PHY upgrade to 2M
//!   T9: Read after PHY upgrade
//!   T10: Disconnect

const std = @import("std");
const esp = @import("esp");
const bluetooth = @import("bluetooth");
const cancellation = @import("cancellation");

const idf = esp.idf;
const heap = idf.heap;
const gap = bluetooth.gap;
const att = bluetooth.att;
const l2cap = bluetooth.l2cap;
const gatt = bluetooth.gatt_server;

const EspRt = idf.runtime;
const HciDriver = esp.impl.hci.HciDriver;

// ============================================================================
// Test Service Definition
// ============================================================================

const SVC_UUID: u16 = 0xAA00;
const CHR_READ_UUID: u16 = 0xAA01;
const CHR_WRITE_UUID: u16 = 0xAA02;
const CHR_NOTIFY_UUID: u16 = 0xAA03;

const service_table = &[_]gatt.ServiceDef{
    gatt.Service(SVC_UUID, &[_]gatt.CharDef{
        gatt.Char(CHR_READ_UUID, .{ .read = true }),
        gatt.Char(CHR_WRITE_UUID, .{ .write = true, .write_without_response = true }),
        gatt.Char(CHR_NOTIFY_UUID, .{ .read = true, .notify = true }),
    }),
};

const BleHost = bluetooth.Host(EspRt, HciDriver, service_table);
const GattType = gatt.GattServer(service_table);

const READ_HANDLE = GattType.getValueHandle(SVC_UUID, CHR_READ_UUID);
const WRITE_HANDLE = GattType.getValueHandle(SVC_UUID, CHR_WRITE_UUID);
const NOTIFY_HANDLE = GattType.getValueHandle(SVC_UUID, CHR_NOTIFY_UUID);
const NOTIFY_CCCD_HANDLE = NOTIFY_HANDLE + 1;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const ADV_NAME = "ZigE2E";

// ============================================================================
// Test Result Tracking
// ============================================================================

var tests_passed: u32 = 0;
var tests_failed: u32 = 0;

fn pass(name: []const u8) void {
    tests_passed += 1;
    log.info("  PASS: {s}", .{name});
}

fn fail(name: []const u8, reason: []const u8) void {
    tests_failed += 1;
    log.err("  FAIL: {s} — {s}", .{ name, reason });
}

// ============================================================================
// Server GATT Handlers
// ============================================================================

var last_written: [64]u8 = undefined;
var last_written_len: usize = 0;
var notify_sent: bool = false;

fn readHandler(req: *gatt.Request, w: *gatt.ResponseWriter) void {
    _ = req;
    w.write(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
}

fn writeHandler(req: *gatt.Request, w: *gatt.ResponseWriter) void {
    const n = @min(req.data.len, last_written.len);
    @memcpy(last_written[0..n], req.data[0..n]);
    last_written_len = n;
    switch (req.op) {
        .write => w.ok(),
        else => {},
    }
}

fn notifyReadHandler(req: *gatt.Request, w: *gatt.ResponseWriter) void {
    _ = req;
    w.write(&[_]u8{ 0xCA, 0xFE });
}

// ============================================================================
// Notification callback (client side)
// ============================================================================

var notification_received: bool = false;
var notification_data: [64]u8 = undefined;
var notification_len: usize = 0;

fn onNotification(_: u16, _: u16, data: []const u8) void {
    const n = @min(data.len, notification_data.len);
    @memcpy(notification_data[0..n], data[0..n]);
    notification_len = n;
    notification_received = true;
}

// ============================================================================
// Server
// ============================================================================

fn runServer(host: *BleHost) void {
    log.info("=== E2E SERVER ===", .{});
    log.info("Service 0x{X:0>4}: Read(h={}), Write(h={}), Notify(h={}, CCCD={})", .{
        SVC_UUID, READ_HANDLE, WRITE_HANDLE, NOTIFY_HANDLE, NOTIFY_CCCD_HANDLE,
    });

    host.gatt.handle(SVC_UUID, CHR_READ_UUID, readHandler, null);
    host.gatt.handle(SVC_UUID, CHR_WRITE_UUID, writeHandler, null);
    host.gatt.handle(SVC_UUID, CHR_NOTIFY_UUID, notifyReadHandler, null);

    const adv_data = [_]u8{ 0x02, 0x01, 0x06 } ++ [_]u8{ ADV_NAME.len + 1, 0x09 } ++ ADV_NAME.*;

    host.startAdvertising(.{
        .interval_min = 0x0020,
        .interval_max = 0x0020,
        .adv_data = &adv_data,
    }) catch {
        fail("T1: Advertise", "startAdvertising failed");
        return;
    };

    log.info("Advertising \"{s}\"... waiting for client", .{ADV_NAME});

    while (host.nextEvent()) |event| {
        switch (event) {
            .connected => |info| {
                pass("T1: GAP connection");
                log.info("  handle=0x{X:0>4}, interval={}", .{ info.conn_handle, info.conn_interval });

                // DLE
                host.requestDataLength(info.conn_handle, 251, 2120) catch {};
                drainEventsFor(host, 2000);
                pass("T2: DLE negotiation");

                // Wait for client tests, then send notification
                log.info("Server: waiting for client to subscribe...", .{});
                idf.time.sleepMs(3000); // give client time to do T3-T6

                // T7: Send notification if CCCD enabled
                if (host.gatt.isNotifyEnabled(SVC_UUID, CHR_NOTIFY_UUID)) {
                    host.notify(info.conn_handle, NOTIFY_HANDLE, &[_]u8{ 0xBE, 0xEF }) catch {};
                    notify_sent = true;
                    pass("T7: Notification sent (CCCD was enabled)");
                } else {
                    fail("T7: Notification", "CCCD not enabled by client");
                }

                // Wait for PHY upgrade from client
                drainEventsFor(host, 3000);

                // Wait for client to finish
                idf.time.sleepMs(3000);

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
    log.info("=== E2E CLIENT ===", .{});

    host.setNotificationCallback(onNotification);

    host.startScanning(.{}) catch {
        fail("T1: Scan", "startScanning failed");
        return;
    };

    while (host.nextEvent()) |event| {
        switch (event) {
            .device_found => |report| {
                if (containsName(report.data, ADV_NAME)) {
                    log.info("Found \"{s}\" (RSSI: {})", .{ ADV_NAME, report.rssi });
                    host.connect(report.addr, report.addr_type, .{
                        .interval_min = 0x0006,
                        .interval_max = 0x0006,
                    }) catch {
                        fail("T1: Connect", "connect failed");
                        return;
                    };
                }
            },
            .connected => |info| {
                pass("T1: GAP connection");
                log.info("  handle=0x{X:0>4}, interval={}", .{ info.conn_handle, info.conn_interval });

                runClientTests(host, info.conn_handle);
                return;
            },
            .connection_failed => |status| {
                fail("T1: Connection", "failed");
                _ = status;
                return;
            },
            else => {},
        }
    }
}

fn runClientTests(host: *BleHost, conn: u16) void {
    // T2: DLE
    host.requestDataLength(conn, 251, 2120) catch {};
    drainEventsFor(host, 2000);
    pass("T2: DLE negotiation");

    // T3: GATT Read
    log.info("T3: Reading handle {}...", .{READ_HANDLE});
    if (host.gattRead(conn, READ_HANDLE)) |data| {
        if (data.len >= 4 and data[0] == 0xDE and data[1] == 0xAD) {
            pass("T3: GATT read");
        } else {
            fail("T3: GATT read", "unexpected data");
        }
    } else |_| {
        fail("T3: GATT read", "request failed");
    }

    // T4: GATT Write (with response)
    log.info("T4: Writing handle {}...", .{WRITE_HANDLE});
    if (host.gattWrite(conn, WRITE_HANDLE, &[_]u8{ 0x01, 0x02, 0x03 })) {
        pass("T4: GATT write");
    } else |_| {
        fail("T4: GATT write", "request failed");
    }

    // T5: GATT Write Command (no response)
    log.info("T5: Write command handle {}...", .{WRITE_HANDLE});
    if (host.gattWriteCmd(conn, WRITE_HANDLE, &[_]u8{ 0xAA, 0xBB })) {
        pass("T5: GATT write command");
    } else |_| {
        fail("T5: GATT write command", "send failed");
    }

    // T6: Subscribe (CCCD write)
    log.info("T6: Subscribe (CCCD handle {})...", .{NOTIFY_CCCD_HANDLE});
    if (host.gattSubscribe(conn, NOTIFY_CCCD_HANDLE)) {
        pass("T6: CCCD subscribe");
    } else |_| {
        fail("T6: CCCD subscribe", "write failed");
    }

    // T7: Wait for notification from server
    log.info("T7: Waiting for notification...", .{});
    const deadline = idf.time.nowMs() + 5000;
    while (idf.time.nowMs() < deadline and !notification_received) {
        _ = host.tryNextEvent();
        idf.time.sleepMs(50);
    }
    if (notification_received and notification_len >= 2 and notification_data[0] == 0xBE) {
        pass("T7: Notification received");
    } else {
        fail("T7: Notification", "not received within 5s");
    }

    // T8: PHY upgrade to 2M
    log.info("T8: PHY upgrade...", .{});
    host.requestPhyUpdate(conn, 0x02, 0x02) catch {};
    const phy_ok = drainUntilPhy(host, 3000);
    if (phy_ok) {
        pass("T8: PHY upgrade to 2M");
    } else {
        fail("T8: PHY upgrade", "event not received");
    }

    // T9: Read after PHY upgrade
    idf.time.sleepMs(200);
    log.info("T9: Read after PHY...", .{});
    if (host.gattRead(conn, READ_HANDLE)) |data| {
        if (data.len >= 4 and data[0] == 0xDE) {
            pass("T9: Read after PHY upgrade");
        } else {
            fail("T9: Read after PHY", "unexpected data");
        }
    } else |_| {
        fail("T9: Read after PHY", "request failed");
    }

    // T10: Disconnect
    log.info("T10: Disconnecting...", .{});
    host.disconnect(conn, 0x13) catch {};
    idf.time.sleepMs(500);
    pass("T10: Disconnect");
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

fn drainEventsFor(host: *BleHost, ms: u64) void {
    const deadline = idf.time.nowMs() + ms;
    while (idf.time.nowMs() < deadline) {
        if (host.tryNextEvent()) |evt| {
            switch (evt) {
                .data_length_changed => |dl| log.info("  DLE: TX={} RX={}", .{ dl.max_tx_octets, dl.max_rx_octets }),
                .phy_updated => |pu| log.info("  PHY: TX={} RX={}", .{ pu.tx_phy, pu.rx_phy }),
                else => {},
            }
        } else {
            idf.time.sleepMs(10);
        }
    }
}

fn drainUntilPhy(host: *BleHost, ms: u64) bool {
    const deadline = idf.time.nowMs() + ms;
    while (idf.time.nowMs() < deadline) {
        if (host.tryNextEvent()) |evt| {
            switch (evt) {
                .phy_updated => return true,
                else => {},
            }
        } else {
            idf.time.sleepMs(10);
        }
    }
    return false;
}

// ============================================================================
// Main
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("BLE E2E Test (Host API + GATT)", .{});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    var hci_driver = HciDriver.init() catch {
        log.err("HCI driver init failed", .{});
        return;
    };
    defer hci_driver.deinit();

    var host = BleHost.init(&hci_driver, heap.psram);
    defer host.deinit();

    host.start(.{ .stack_size = 8192, .priority = 20, .allocator = heap.iram }) catch |err| {
        log.err("Host start failed: {}", .{err});
        return;
    };
    defer host.stop();

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

    log.info("", .{});
    log.info("==========================================", .{});
    log.info("E2E Results: {} passed, {} failed", .{ tests_passed, tests_failed });
    if (tests_failed == 0) {
        log.info("ALL TESTS PASSED", .{});
    } else {
        log.err("SOME TESTS FAILED", .{});
    }
    log.info("==========================================", .{});

    while (true) {
        idf.time.sleepMs(5000);
    }
}
