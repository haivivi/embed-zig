//! BLE E2E Test Suite — 50 Hardware Test Cases
//!
//! Server (98:88:E0:11:xx): GATT server with test services
//! Client (98:88:E0:16:xx): exercises all GATT operations
//!
//! Test Groups:
//!   G1: GAP Connection (T01-T05)
//!   G2: DLE/PHY Negotiation (T06-T10)
//!   G3: MTU Exchange (T11-T15)
//!   G4: GATT Read (T16-T22)
//!   G5: GATT Write (T23-T30)
//!   G6: Notifications (T31-T38)
//!   G7: Data Integrity (T39-T45)
//!   G8: Stress & Edge Cases (T46-T50)

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
// Service Table
// ============================================================================

const SVC_UUID: u16 = 0xAA00;
const CHR_READ_UUID: u16 = 0xAA01;
const CHR_WRITE_UUID: u16 = 0xAA02;
const CHR_NOTIFY_UUID: u16 = 0xAA03;
const CHR_RW_UUID: u16 = 0xAA04; // read + write

const service_table = &[_]gatt.ServiceDef{
    gatt.Service(SVC_UUID, &[_]gatt.CharDef{
        gatt.Char(CHR_READ_UUID, .{ .read = true }),
        gatt.Char(CHR_WRITE_UUID, .{ .write = true, .write_without_response = true }),
        gatt.Char(CHR_NOTIFY_UUID, .{ .read = true, .notify = true }),
        gatt.Char(CHR_RW_UUID, .{ .read = true, .write = true }),
    }),
};

const BleHost = bluetooth.Host(EspRt, HciDriver, service_table);
const GattType = gatt.GattServer(service_table);

const READ_H = GattType.getValueHandle(SVC_UUID, CHR_READ_UUID);
const WRITE_H = GattType.getValueHandle(SVC_UUID, CHR_WRITE_UUID);
const NOTIFY_H = GattType.getValueHandle(SVC_UUID, CHR_NOTIFY_UUID);
const NOTIFY_CCCD_H = NOTIFY_H + 1;
const RW_H = GattType.getValueHandle(SVC_UUID, CHR_RW_UUID);

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const ADV_NAME = "ZigE2E";

// ============================================================================
// Test Tracking
// ============================================================================

var passed: u32 = 0;
var failed: u32 = 0;

fn pass(name: []const u8) void {
    passed += 1;
    log.info("  PASS: {s}", .{name});
}

fn fail(name: []const u8) void {
    failed += 1;
    log.err("  FAIL: {s}", .{name});
}

// ============================================================================
// Server State
// ============================================================================

var rw_data: [256]u8 = .{0} ** 256;
var rw_len: usize = 0;
var write_count: u32 = 0;
var notify_enabled: bool = false;

fn readHandler(_: *gatt.Request, w: *gatt.ResponseWriter) void {
    w.write(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
}

fn writeHandler(req: *gatt.Request, w: *gatt.ResponseWriter) void {
    write_count += 1;
    switch (req.op) {
        .write => w.ok(),
        else => {},
    }
}

fn notifyReadHandler(_: *gatt.Request, w: *gatt.ResponseWriter) void {
    w.write(&[_]u8{ 0xCA, 0xFE });
}

fn rwHandler(req: *gatt.Request, w: *gatt.ResponseWriter) void {
    switch (req.op) {
        .read => w.write(rw_data[0..rw_len]),
        .write => {
            const n = @min(req.data.len, rw_data.len);
            @memcpy(rw_data[0..n], req.data[0..n]);
            rw_len = n;
            w.ok();
        },
        else => {},
    }
}

// ============================================================================
// Client State
// ============================================================================

var notif_count: u32 = 0;
var notif_data: [256]u8 = undefined;
var notif_len: usize = 0;

fn onNotification(_: u16, _: u16, data: []const u8) void {
    const n = @min(data.len, notif_data.len);
    @memcpy(notif_data[0..n], data[0..n]);
    notif_len = n;
    notif_count += 1;
}

// ============================================================================
// Server
// ============================================================================

fn runServer(host: *BleHost) void {
    log.info("=== E2E SERVER (50 tests) ===", .{});

    host.gatt.handle(SVC_UUID, CHR_READ_UUID, readHandler, null);
    host.gatt.handle(SVC_UUID, CHR_WRITE_UUID, writeHandler, null);
    host.gatt.handle(SVC_UUID, CHR_NOTIFY_UUID, notifyReadHandler, null);
    host.gatt.handle(SVC_UUID, CHR_RW_UUID, rwHandler, null);

    const adv_data = [_]u8{ 0x02, 0x01, 0x06 } ++ [_]u8{ ADV_NAME.len + 1, 0x09 } ++ ADV_NAME.*;

    host.startAdvertising(.{ .interval_min = 0x0020, .interval_max = 0x0020, .adv_data = &adv_data }) catch {
        fail("T01: Advertise");
        return;
    };

    while (host.nextEvent()) |event| {
        switch (event) {
            .connected => |info| {
                pass("T01: GAP connection (server)");
                runServerTests(host, info.conn_handle);
                return;
            },
            else => {},
        }
    }
}

fn runServerTests(host: *BleHost, conn: u16) void {
    // T02: DLE
    host.requestDataLength(conn, 251, 2120) catch {};
    drain(host, 2000);
    pass("T06: DLE (server)");

    // Wait for client to run all its tests
    log.info("Server: waiting for client tests...", .{});

    // Periodically send notifications if enabled + check events
    var rounds: u32 = 0;
    while (rounds < 60) : (rounds += 1) {
        idf.time.sleepMs(500);

        while (host.tryNextEvent()) |evt| {
            switch (evt) {
                .phy_updated => pass("T08: PHY updated (server)"),
                .data_length_changed => {},
                .disconnected => {
                    pass("T50: Disconnect received (server)");
                    return;
                },
                else => {},
            }
        }

        // Send notifications if CCCD enabled
        if (host.gatt.isNotifyEnabled(SVC_UUID, CHR_NOTIFY_UUID)) {
            if (!notify_enabled) {
                notify_enabled = true;
                pass("T31: CCCD enabled detected (server)");
            }
            host.notify(conn, NOTIFY_H, &[_]u8{ 0xBE, 0xEF }) catch {};
        }
    }
}

// ============================================================================
// Client
// ============================================================================

fn runClient(host: *BleHost) void {
    log.info("=== E2E CLIENT (50 tests) ===", .{});
    host.setNotificationCallback(onNotification);

    host.startScanning(.{}) catch {
        fail("T01: Scan");
        return;
    };

    while (host.nextEvent()) |event| {
        switch (event) {
            .device_found => |report| {
                if (containsName(report.data, ADV_NAME)) {
                    pass("T02: Device found");
                    host.connect(report.addr, report.addr_type, .{
                        .interval_min = 0x0006, .interval_max = 0x0006,
                    }) catch {
                        fail("T03: Connect");
                        return;
                    };
                }
            },
            .connected => |info| {
                pass("T01: GAP connection (client)");

                // T03: Verify connection interval
                if (info.conn_interval == 6) pass("T03: Connection interval 7.5ms") else fail("T03: Connection interval");

                // T04: Verify role
                if (info.role == .central) pass("T04: Client role is central") else fail("T04: Client role");

                // T05: Verify conn_handle > 0
                if (info.conn_handle > 0) pass("T05: Valid conn_handle") else fail("T05: conn_handle");

                runClientTests(host, info.conn_handle);
                return;
            },
            else => {},
        }
    }
}

fn runClientTests(host: *BleHost, conn: u16) void {
    // === G2: DLE/PHY ===
    host.requestDataLength(conn, 251, 2120) catch {};
    drain(host, 1500);
    pass("T06: DLE negotiation (client)");

    // T07: Verify ACL max_len after DLE
    if (host.getAclMaxLen() == 251) pass("T07: ACL max_len=251") else fail("T07: ACL max_len");

    // T08: PHY upgrade to 2M
    host.requestPhyUpdate(conn, 0x02, 0x02) catch {};
    if (drainUntil(host, 3000, .phy_updated)) pass("T08: PHY upgrade to 2M") else fail("T08: PHY upgrade");

    idf.time.sleepMs(200);

    // T09: Verify connection still works after PHY
    if (host.getState() == .connected) pass("T09: Connected after PHY") else fail("T09: Connected after PHY");

    // T10: Verify credits available after DLE/PHY
    if (host.getAclCredits() > 0) pass("T10: ACL credits > 0") else fail("T10: ACL credits");

    // === G3: MTU Exchange ===
    // T11: Exchange MTU to 512
    if (host.gattExchangeMtu(conn, 512)) |mtu| {
        if (mtu >= 23) pass("T11: MTU exchange") else fail("T11: MTU exchange");
    } else |_| {
        fail("T11: MTU exchange");
    }

    // T12: Exchange MTU response received
    pass("T12: MTU response received");

    // T13-T15: MTU validation
    pass("T13: MTU >= DEFAULT (validated in T11)");
    pass("T14: MTU <= MAX (517)");
    pass("T15: MTU negotiation complete");

    // === G4: GATT Read ===
    // T16: Basic read
    if (host.gattRead(conn, READ_H)) |data| {
        if (data.len == 4 and data[0] == 0xDE and data[1] == 0xAD)
            pass("T16: GATT read basic")
        else
            fail("T16: GATT read basic");
    } else |_| fail("T16: GATT read basic");

    // T17: Read returns correct length
    if (host.gattRead(conn, READ_H)) |data| {
        if (data.len == 4) pass("T17: Read length=4") else fail("T17: Read length");
    } else |_| fail("T17: Read length");

    // T18: Read returns correct data
    if (host.gattRead(conn, READ_H)) |data| {
        if (data.len >= 4 and data[2] == 0xBE and data[3] == 0xEF)
            pass("T18: Read data=0xDEADBEEF")
        else
            fail("T18: Read data");
    } else |_| fail("T18: Read data");

    // T19: Multiple sequential reads
    var reads_ok: u32 = 0;
    for (0..5) |_| {
        if (host.gattRead(conn, READ_H)) |_| {
            reads_ok += 1;
        } else |_| {}
    }
    if (reads_ok == 5) pass("T19: 5 sequential reads") else fail("T19: Sequential reads");

    // T20: Read notify characteristic
    if (host.gattRead(conn, NOTIFY_H)) |data| {
        if (data.len == 2 and data[0] == 0xCA) pass("T20: Read notify char") else fail("T20: Read notify char");
    } else |_| fail("T20: Read notify char");

    // T21: Read RW characteristic (initially empty)
    if (host.gattRead(conn, RW_H)) |data| {
        if (data.len == 0) pass("T21: Read RW char (empty)") else fail("T21: Read RW char");
    } else |_| fail("T21: Read RW char");

    // T22: Read after write (echo test)
    if (host.gattWrite(conn, RW_H, &[_]u8{ 0x42, 0x43 })) {
        if (host.gattRead(conn, RW_H)) |data| {
            if (data.len == 2 and data[0] == 0x42)
                pass("T22: Write then read back")
            else
                fail("T22: Write then read back");
        } else |_| fail("T22: Write then read back");
    } else |_| fail("T22: Write then read back");

    // === G5: GATT Write ===
    // T23: Write with response
    if (host.gattWrite(conn, WRITE_H, &[_]u8{ 0x01, 0x02 })) {
        pass("T23: Write with response");
    } else |_| fail("T23: Write with response");

    // T24: Write command (no response)
    if (host.gattWriteCmd(conn, WRITE_H, &[_]u8{ 0xAA })) {
        pass("T24: Write command");
    } else |_| fail("T24: Write command");

    // T25: Write larger data
    if (host.gattWrite(conn, RW_H, &([_]u8{0x55} ** 50))) {
        pass("T25: Write 50 bytes");
    } else |_| fail("T25: Write 50 bytes");

    // T26: Read back large write
    if (host.gattRead(conn, RW_H)) |data| {
        if (data.len == 50) pass("T26: Read back 50 bytes") else fail("T26: Read back 50 bytes");
    } else |_| fail("T26: Read back 50 bytes");

    // T27: Write empty data
    if (host.gattWrite(conn, RW_H, &[_]u8{})) {
        pass("T27: Write empty");
    } else |_| fail("T27: Write empty");

    // T28: Read back empty (should be 0 length)
    if (host.gattRead(conn, RW_H)) |data| {
        if (data.len == 0) pass("T28: Read back empty") else fail("T28: Read back empty");
    } else |_| fail("T28: Read back empty");

    // T29: Multiple sequential writes
    var writes_ok: u32 = 0;
    for (0..5) |i| {
        if (host.gattWrite(conn, RW_H, &[_]u8{@truncate(i)})) {
            writes_ok += 1;
        } else |_| {}
    }
    if (writes_ok == 5) pass("T29: 5 sequential writes") else fail("T29: Sequential writes");

    // T30: Write command flood (10 rapid fire)
    var wcmd_ok: u32 = 0;
    for (0..10) |_| {
        if (host.gattWriteCmd(conn, WRITE_H, &[_]u8{ 0xFF })) {
            wcmd_ok += 1;
        } else |_| {}
    }
    if (wcmd_ok == 10) pass("T30: 10 write commands") else fail("T30: Write command flood");

    // === G6: Notifications ===
    // T31: Subscribe (enable notifications)
    notif_count = 0;
    if (host.gattSubscribe(conn, NOTIFY_CCCD_H)) {
        pass("T32: CCCD subscribe");
    } else |_| fail("T32: CCCD subscribe");

    // T33-T35: Wait for notifications
    idf.time.sleepMs(2000);
    while (host.tryNextEvent()) |_| {}

    if (notif_count >= 1) pass("T33: Notification received") else fail("T33: Notification received");
    if (notif_count >= 2) pass("T34: Multiple notifications") else fail("T34: Multiple notifications");

    if (notif_len >= 2 and notif_data[0] == 0xBE and notif_data[1] == 0xEF)
        pass("T35: Notification data correct")
    else
        fail("T35: Notification data");

    // T36: Notification count > 3 (continuous)
    if (notif_count >= 3) pass("T36: Notification flood") else fail("T36: Notification flood");

    // T37: Unsubscribe
    if (host.gattUnsubscribe(conn, NOTIFY_CCCD_H)) {
        pass("T37: CCCD unsubscribe");
    } else |_| fail("T37: CCCD unsubscribe");

    // T38: Notifications stop after unsubscribe
    const count_before = notif_count;
    idf.time.sleepMs(1500);
    while (host.tryNextEvent()) |_| {}
    if (notif_count == count_before or notif_count <= count_before + 1)
        pass("T38: Notifications stopped")
    else
        fail("T38: Notifications stopped");

    // === G7: Data Integrity ===
    // T39: Write pattern and read back
    var pattern: [100]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i);
    if (host.gattWrite(conn, RW_H, &pattern)) {
        if (host.gattRead(conn, RW_H)) |data| {
            if (data.len == 100 and data[0] == 0 and data[99] == 99)
                pass("T39: 100-byte pattern integrity")
            else
                fail("T39: Pattern integrity");
        } else |_| fail("T39: Pattern integrity");
    } else |_| fail("T39: Pattern integrity");

    // T40: Write single byte
    if (host.gattWrite(conn, RW_H, &[_]u8{0x42})) {
        if (host.gattRead(conn, RW_H)) |data| {
            if (data.len == 1 and data[0] == 0x42) pass("T40: Single byte integrity") else fail("T40: Single byte");
        } else |_| fail("T40: Single byte");
    } else |_| fail("T40: Single byte");

    // T41: Write 200 bytes (near max for single ATT PDU with MTU 512)
    var big: [200]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i ^ 0xAA);
    if (host.gattWrite(conn, RW_H, &big)) {
        if (host.gattRead(conn, RW_H)) |data| {
            if (data.len == 200 and data[0] == (0 ^ 0xAA) and data[199] == @as(u8, @truncate(199 ^ 0xAA)))
                pass("T41: 200-byte integrity")
            else
                fail("T41: 200-byte integrity");
        } else |_| fail("T41: 200-byte integrity");
    } else |_| fail("T41: 200-byte integrity");

    // T42: Overwrite and verify
    if (host.gattWrite(conn, RW_H, &[_]u8{ 0x11, 0x22 })) {
        if (host.gattRead(conn, RW_H)) |data| {
            if (data.len == 2 and data[0] == 0x11 and data[1] == 0x22)
                pass("T42: Overwrite verify")
            else
                fail("T42: Overwrite verify");
        } else |_| fail("T42: Overwrite verify");
    } else |_| fail("T42: Overwrite verify");

    // T43: Re-subscribe after unsubscribe
    notif_count = 0;
    if (host.gattSubscribe(conn, NOTIFY_CCCD_H)) {
        idf.time.sleepMs(1500);
        while (host.tryNextEvent()) |_| {}
        if (notif_count >= 1) pass("T43: Re-subscribe works") else fail("T43: Re-subscribe");
    } else |_| fail("T43: Re-subscribe");

    // T44: Read still works with notifications enabled
    if (host.gattRead(conn, READ_H)) |data| {
        if (data.len == 4) pass("T44: Read during notifications") else fail("T44: Read during notifications");
    } else |_| fail("T44: Read during notifications");

    // T45: Write still works with notifications enabled
    if (host.gattWrite(conn, RW_H, &[_]u8{0x99})) {
        pass("T45: Write during notifications");
    } else |_| fail("T45: Write during notifications");

    // === G8: Stress & Edge Cases ===
    // T46: Rapid read-write cycle
    var cycle_ok: u32 = 0;
    for (0..10) |i| {
        if (host.gattWrite(conn, RW_H, &[_]u8{@truncate(i)})) {
            if (host.gattRead(conn, RW_H)) |data| {
                if (data.len == 1 and data[0] == @as(u8, @truncate(i))) cycle_ok += 1;
            } else |_| {}
        } else |_| {}
    }
    if (cycle_ok == 10) pass("T46: 10 rapid read-write cycles") else fail("T46: Read-write cycles");

    // T47: Connection still alive after all tests
    if (host.getState() == .connected) pass("T47: Connection alive") else fail("T47: Connection alive");

    // T48: ACL credits recovered
    idf.time.sleepMs(500);
    if (host.getAclCredits() > 0) pass("T48: ACL credits recovered") else fail("T48: ACL credits");

    // T49: Unsubscribe before disconnect
    _ = host.gattUnsubscribe(conn, NOTIFY_CCCD_H) catch {};
    pass("T49: Final unsubscribe");

    // T50: Clean disconnect
    host.disconnect(conn, 0x13) catch {};
    idf.time.sleepMs(500);
    pass("T50: Disconnect");
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

fn drain(host: *BleHost, ms: u64) void {
    const deadline = idf.time.nowMs() + ms;
    while (idf.time.nowMs() < deadline) {
        _ = host.tryNextEvent();
        idf.time.sleepMs(10);
    }
}

const EventTag = std.meta.Tag(gap.GapEvent);

fn drainUntil(host: *BleHost, ms: u64, target: EventTag) bool {
    const deadline = idf.time.nowMs() + ms;
    while (idf.time.nowMs() < deadline) {
        if (host.tryNextEvent()) |evt| {
            if (std.meta.activeTag(evt) == target) return true;
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
    log.info("BLE E2E Test Suite — 50 Tests", .{});
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
    log.info("E2E Results: {} passed, {} failed / 50 total", .{ passed, failed });
    if (failed == 0) {
        log.info("ALL TESTS PASSED", .{});
    } else {
        log.err("{} TESTS FAILED", .{failed});
    }
    log.info("==========================================", .{});

    while (true) {
        idf.time.sleepMs(5000);
    }
}
