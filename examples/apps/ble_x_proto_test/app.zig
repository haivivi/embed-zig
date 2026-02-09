//! BLE X-Proto Throughput Test
//!
//! Tests READ_X (Server→Client) and WRITE_X (Client→Server) chunked
//! transfer protocol over BLE, measuring real-world throughput.
//!
//! Flash the same firmware on two ESP32-S3 boards:
//!   - MAC with addr[2]==0x11 → SERVER (peripheral)
//!   - Other MAC → CLIENT (central)
//!
//! Test sequence:
//!   1. Connect + DLE + 2M PHY
//!   2. Server→Client: ReadX sends 900KB, client receives + ACKs
//!   3. Client→Server: client sends 900KB chunks, server WriteX receives

const std = @import("std");
const esp = @import("esp");
const bluetooth = @import("bluetooth");
const x_proto = @import("x_proto");
const channel = @import("channel");
const cancellation = @import("cancellation");
const waitgroup = @import("waitgroup");

const idf = esp.idf;
const heap = idf.heap;
const gap = bluetooth.gap;
const att = bluetooth.att;
const l2cap = bluetooth.l2cap;
const gatt = bluetooth.gatt_server;
const gatt_client = bluetooth.gatt_client;
const chunk = x_proto.chunk;

const EspRt = idf.runtime;
const HciDriver = esp.impl.hci.HciDriver;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// ============================================================================
// GATT Service — single char for bidirectional x_proto
// ============================================================================

const SVC_UUID: u16 = 0xCC00;
const CHR_UUID: u16 = 0xCC01;

const service_table = &[_]gatt.ServiceDef{
    gatt.Service(SVC_UUID, &[_]gatt.CharDef{
        gatt.Char(CHR_UUID, .{ .write = true, .write_without_response = true, .read = true, .notify = true }),
    }),
};

const BleHost = bluetooth.Host(EspRt, HciDriver, service_table);
const GattType = gatt.GattServer(service_table);
const VALUE_HANDLE = GattType.getValueHandle(SVC_UUID, CHR_UUID);
const CCCD_HANDLE = VALUE_HANDLE + 1;

// ============================================================================
// Test Parameters
// ============================================================================

const TEST_DATA_SIZE = 900 * 1024; // 900 KB
const TEST_MTU: u16 = 247; // ATT MTU
const ADV_NAME = "XProto";

// ============================================================================
// BLE Transport — bridges x_proto to BLE Host
// ============================================================================

const BleTransport = struct {
    host: *BleHost,
    conn_handle: u16,
    attr_handle: u16,
    use_notify: bool,
    rx: RxChannel,

    const RxMsg = struct {
        data: [512]u8 = undefined,
        len: usize = 0,
    };
    const RxChannel = channel.Channel(RxMsg, 16, EspRt);

    fn create(host: *BleHost, conn_handle: u16, attr_handle: u16, use_notify: bool) !*BleTransport {
        const t = try heap.psram.create(BleTransport);
        t.* = .{
            .host = host,
            .conn_handle = conn_handle,
            .attr_handle = attr_handle,
            .use_notify = use_notify,
            .rx = RxChannel.init(),
        };
        return t;
    }

    fn destroy(self: *BleTransport) void {
        self.rx.close();
        self.rx.deinit();
        heap.psram.destroy(self);
    }

    pub fn send(self: *BleTransport, data: []const u8) !void {
        if (self.use_notify) {
            self.host.notify(self.conn_handle, self.attr_handle, data) catch
                return error.SendFailed;
        } else {
            self.host.gattWriteCmd(self.conn_handle, self.attr_handle, data) catch
                return error.SendFailed;
        }
    }

    pub fn recv(self: *BleTransport, buf: []u8, timeout_ms: u32) !?usize {
        const deadline = idf.time.nowMs() + timeout_ms;
        while (idf.time.nowMs() < deadline) {
            if (self.rx.tryRecv()) |msg| {
                const n = @min(msg.len, buf.len);
                @memcpy(buf[0..n], msg.data[0..n]);
                return n;
            }
            if (self.rx.isClosed()) return error.Closed;
            idf.time.sleepMs(1);
        }
        return null;
    }

    fn pushData(self: *BleTransport, data: []const u8) void {
        var msg = RxMsg{};
        const n = @min(data.len, msg.data.len);
        @memcpy(msg.data[0..n], data[0..n]);
        msg.len = n;
        self.rx.trySend(msg) catch {};
    }
};

// ============================================================================
// Callback Glue (globals for GATT write handler + notification callback)
// ============================================================================

var g_server_transport: ?*BleTransport = null;
var g_client_transport: ?*BleTransport = null;

fn writeHandler(req: *gatt.Request, w: *gatt.ResponseWriter) void {
    if (req.op == .write) w.ok();
    if (g_server_transport) |t| t.pushData(req.data);
}

fn onNotification(_: u16, _: u16, data: []const u8) void {
    if (g_client_transport) |t| t.pushData(data);
}

// ============================================================================
// Test Data
// ============================================================================

fn generateTestData() ![]u8 {
    const data = try heap.psram.alloc(u8, TEST_DATA_SIZE);
    for (data, 0..) |*b, i| {
        b.* = @truncate(i);
    }
    return data;
}

fn verifyData(received: []const u8, expected_len: usize) bool {
    if (received.len != expected_len) return false;
    for (received, 0..) |b, i| {
        if (b != @as(u8, @truncate(i))) return false;
    }
    return true;
}

// ============================================================================
// Server: ReadX Test (Server → Client)
// ============================================================================

fn testServerReadX(host: *BleHost, conn: u16) void {
    log.info("", .{});
    log.info("=== Test 1: ReadX (Server → Client) ===", .{});

    const data = generateTestData() catch {
        log.err("Failed to allocate test data", .{});
        return;
    };
    defer heap.psram.free(data);

    log.info("Data: {} KB, MTU: {}, chunks: {}", .{
        TEST_DATA_SIZE / 1024,
        TEST_MTU,
        chunk.chunksNeeded(data.len, TEST_MTU),
    });

    const transport = BleTransport.create(host, conn, VALUE_HANDLE, true) catch {
        log.err("Transport create failed", .{});
        return;
    };
    defer transport.destroy();
    g_server_transport = transport;
    defer {
        g_server_transport = null;
    }

    log.info("Waiting for client start magic...", .{});
    const start = idf.time.nowMs();

    var rx = x_proto.ReadX(BleTransport).init(transport, data, .{
        .mtu = TEST_MTU,
        .send_redundancy = 1,
        .start_timeout_ms = 30_000,
        .ack_timeout_ms = 30_000,
    });
    rx.run() catch |err| {
        log.err("ReadX failed: {}", .{err});
        return;
    };

    const elapsed = idf.time.nowMs() - start;
    const kbs = if (elapsed > 0) @as(f32, @floatFromInt(TEST_DATA_SIZE)) / 1024.0 / (@as(f32, @floatFromInt(elapsed)) / 1000.0) else 0;
    log.info("ReadX DONE: {} KB in {} ms = {d:.1} KB/s", .{
        TEST_DATA_SIZE / 1024, elapsed, kbs,
    });
}

// ============================================================================
// Server: WriteX Test (Client → Server)
// ============================================================================

fn testServerWriteX(host: *BleHost, conn: u16) void {
    log.info("", .{});
    log.info("=== Test 2: WriteX (Client → Server) ===", .{});

    const recv_buf = heap.psram.alloc(u8, TEST_DATA_SIZE + 4096) catch {
        log.err("Failed to allocate receive buffer", .{});
        return;
    };
    defer heap.psram.free(recv_buf);

    const transport = BleTransport.create(host, conn, VALUE_HANDLE, true) catch {
        log.err("Transport create failed", .{});
        return;
    };
    defer transport.destroy();
    g_server_transport = transport;
    defer {
        g_server_transport = null;
    }

    log.info("Waiting for client chunks...", .{});
    const start = idf.time.nowMs();

    var wx = x_proto.WriteX(BleTransport).init(transport, recv_buf, .{
        .mtu = TEST_MTU,
        .timeout_ms = 10_000,
        .max_retries = 10,
    });
    const result = wx.run() catch |err| {
        log.err("WriteX failed: {}", .{err});
        return;
    };

    const elapsed = idf.time.nowMs() - start;
    const data_len = result.data.len;
    const kbs = if (elapsed > 0) @as(f32, @floatFromInt(data_len)) / 1024.0 / (@as(f32, @floatFromInt(elapsed)) / 1000.0) else 0;
    log.info("WriteX DONE: {} KB in {} ms = {d:.1} KB/s", .{
        data_len / 1024, elapsed, kbs,
    });

    if (verifyData(result.data, TEST_DATA_SIZE)) {
        log.info("Data integrity: PASS", .{});
    } else {
        log.err("Data integrity: FAIL (got {} bytes, expected {})", .{ data_len, TEST_DATA_SIZE });
    }
}

// ============================================================================
// Client: ReadX Receiver (receive data from server)
// ============================================================================

fn testClientReadX(host: *BleHost, conn: u16, remote_value_handle: u16) void {
    log.info("", .{});
    log.info("=== Test 1: ReadX Client (receive from server) ===", .{});

    const recv_buf = heap.psram.alloc(u8, TEST_DATA_SIZE + 4096) catch {
        log.err("Failed to allocate receive buffer", .{});
        return;
    };
    defer heap.psram.free(recv_buf);

    const transport = BleTransport.create(host, conn, remote_value_handle, false) catch {
        log.err("Transport create failed", .{});
        return;
    };
    defer transport.destroy();
    g_client_transport = transport;
    defer {
        g_client_transport = null;
    }

    // Send start magic to trigger server's ReadX
    log.info("Sending start magic...", .{});
    transport.send(&chunk.start_magic) catch {
        log.err("Failed to send start magic", .{});
        return;
    };

    // Receive chunks using WriteX (protocol is symmetric after start magic)
    const start = idf.time.nowMs();

    var wx = x_proto.WriteX(BleTransport).init(transport, recv_buf, .{
        .mtu = TEST_MTU,
        .timeout_ms = 10_000,
        .max_retries = 10,
    });
    const result = wx.run() catch |err| {
        log.err("ReadX client failed: {}", .{err});
        return;
    };

    const elapsed = idf.time.nowMs() - start;
    const data_len = result.data.len;
    const kbs = if (elapsed > 0) @as(f32, @floatFromInt(data_len)) / 1024.0 / (@as(f32, @floatFromInt(elapsed)) / 1000.0) else 0;
    log.info("ReadX Client DONE: {} KB in {} ms = {d:.1} KB/s", .{
        data_len / 1024, elapsed, kbs,
    });

    if (verifyData(result.data, TEST_DATA_SIZE)) {
        log.info("Data integrity: PASS", .{});
    } else {
        log.err("Data integrity: FAIL (got {} bytes, expected {})", .{ data_len, TEST_DATA_SIZE });
    }
}

// ============================================================================
// Client: WriteX Sender (send data to server)
// ============================================================================

fn testClientWriteX(host: *BleHost, conn: u16, remote_value_handle: u16) void {
    log.info("", .{});
    log.info("=== Test 2: WriteX Client (send to server) ===", .{});

    const data = generateTestData() catch {
        log.err("Failed to allocate test data", .{});
        return;
    };
    defer heap.psram.free(data);

    log.info("Data: {} KB, MTU: {}, chunks: {}", .{
        TEST_DATA_SIZE / 1024,
        TEST_MTU,
        chunk.chunksNeeded(data.len, TEST_MTU),
    });

    const transport = BleTransport.create(host, conn, remote_value_handle, false) catch {
        log.err("Transport create failed", .{});
        return;
    };
    defer transport.destroy();
    g_client_transport = transport;
    defer {
        g_client_transport = null;
    }

    const start = idf.time.nowMs();
    clientSendChunks(transport, data) catch |err| {
        log.err("WriteX client failed: {}", .{err});
        return;
    };

    const elapsed = idf.time.nowMs() - start;
    const kbs = if (elapsed > 0) @as(f32, @floatFromInt(TEST_DATA_SIZE)) / 1024.0 / (@as(f32, @floatFromInt(elapsed)) / 1000.0) else 0;
    log.info("WriteX Client DONE: {} KB in {} ms = {d:.1} KB/s", .{
        TEST_DATA_SIZE / 1024, elapsed, kbs,
    });
}

/// Inline WriteX client: send all chunks, wait for ACK/loss-list, retransmit.
fn clientSendChunks(transport: *BleTransport, data: []const u8) !void {
    const dcs = chunk.dataChunkSize(TEST_MTU);
    const total_usize = chunk.chunksNeeded(data.len, TEST_MTU);
    const total: u16 = @intCast(total_usize);
    const mask_len = chunk.Bitmask.requiredBytes(total);

    var sndmask: [chunk.max_mask_bytes]u8 = undefined;
    chunk.Bitmask.initAllSet(sndmask[0..mask_len], total);

    var chunk_buf: [chunk.max_mtu]u8 = undefined;
    var recv_buf: [chunk.max_mtu]u8 = undefined;

    while (true) {
        // Send all marked chunks
        var i: u16 = 0;
        while (i < total) : (i += 1) {
            const seq: u16 = i + 1;
            if (!chunk.Bitmask.isSet(sndmask[0..mask_len], seq)) continue;

            const hdr = (chunk.Header{ .total = total, .seq = seq }).encode();
            @memcpy(chunk_buf[0..chunk.header_size], &hdr);

            const offset: usize = @as(usize, i) * dcs;
            const remaining = data.len - offset;
            const payload_len: usize = @min(remaining, dcs);
            @memcpy(
                chunk_buf[chunk.header_size .. chunk.header_size + payload_len],
                data[offset .. offset + payload_len],
            );

            try transport.send(chunk_buf[0 .. chunk.header_size + payload_len]);
        }

        // Wait for ACK or loss list from server
        const resp_len = (try transport.recv(&recv_buf, 30_000)) orelse return error.Timeout;

        if (chunk.isAck(recv_buf[0..resp_len])) return; // Done!

        // Parse loss list, mark for retransmission
        chunk.Bitmask.initClear(sndmask[0..mask_len], total);
        var loss_seqs: [260]u16 = undefined;
        const loss_count = chunk.decodeLossList(recv_buf[0..resp_len], &loss_seqs);
        if (loss_count == 0) return error.InvalidResponse;

        log.info("Retransmitting {} lost chunks", .{loss_count});
        for (loss_seqs[0..loss_count]) |seq| {
            if (seq >= 1 and seq <= total) {
                chunk.Bitmask.set(sndmask[0..mask_len], seq);
            }
        }
    }
}

// ============================================================================
// Helpers
// ============================================================================

// ============================================================================
// GATT Service Discovery (for cross-platform: ESP client → Mac/ESP server)
// ============================================================================

const DiscoveredHandles = struct {
    value: u16,
    cccd: u16,
};

fn discoverHandles(host: *BleHost, conn: u16) ?DiscoveredHandles {
    // Discover services
    var services: [8]gatt_client.DiscoveredService = undefined;
    const svc_count = host.discoverServices(conn, &services) catch |err| {
        log.err("discoverServices: {}", .{err});
        return null;
    };
    log.info("Discovered {} services", .{svc_count});

    // Find our service (0xCC00)
    var target_svc: ?gatt_client.DiscoveredService = null;
    for (services[0..svc_count]) |svc| {
        log.info("  SVC: 0x{X:0>4}-0x{X:0>4}", .{ svc.start_handle, svc.end_handle });
        if (svc.uuid.eql(att.UUID.from16(SVC_UUID))) target_svc = svc;
    }
    const svc = target_svc orelse {
        log.err("Service 0x{X:0>4} not found", .{SVC_UUID});
        return null;
    };

    // Discover characteristics
    var chars: [8]gatt_client.DiscoveredCharacteristic = undefined;
    const char_count = host.discoverCharacteristics(conn, svc.start_handle, svc.end_handle, &chars) catch |err| {
        log.err("discoverCharacteristics: {}", .{err});
        return null;
    };
    log.info("Discovered {} chars", .{char_count});

    var value_handle: u16 = 0;
    for (chars[0..char_count]) |c| {
        log.info("  CHR: val=0x{X:0>4}", .{c.value_handle});
        if (c.uuid.eql(att.UUID.from16(CHR_UUID))) value_handle = c.value_handle;
    }

    if (value_handle == 0) {
        log.err("Char 0x{X:0>4} not found", .{CHR_UUID});
        return null;
    }

    // Discover CCCD descriptor
    var cccd_handle: u16 = 0;
    {
        const desc_start = value_handle + 1;
        const desc_end = svc.end_handle;
        if (desc_start <= desc_end) {
            var descs: [8]gatt_client.DiscoveredDescriptor = undefined;
            const desc_count = host.discoverDescriptors(conn, desc_start, desc_end, &descs) catch 0;
            for (descs[0..desc_count]) |d| {
                if (d.uuid.eql(att.UUID.from16(0x2902))) cccd_handle = d.handle;
            }
        }
    }

    if (cccd_handle == 0) {
        // Fallback: CCCD is typically value_handle + 1
        cccd_handle = value_handle + 1;
        log.info("CCCD not found via discovery, using fallback: 0x{X:0>4}", .{cccd_handle});
    }

    return .{ .value = value_handle, .cccd = cccd_handle };
}

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
        if (host.tryNextEvent()) |evt| {
            switch (evt) {
                .data_length_changed => |dl| log.info("DLE: TX={}/{} RX={}/{}", .{
                    dl.max_tx_octets, dl.max_tx_time, dl.max_rx_octets, dl.max_rx_time,
                }),
                .phy_updated => |pu| log.info("PHY updated: TX={} RX={}", .{ pu.tx_phy, pu.rx_phy }),
                else => {},
            }
        } else {
            idf.time.sleepMs(10);
        }
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("BLE X-Proto Throughput Test", .{});
    log.info("Data: {} KB, MTU: {}", .{ TEST_DATA_SIZE / 1024, TEST_MTU });
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

    host.start(.{ .stack_size = 8192, .priority = 20, .allocator = heap.psram }) catch |err| {
        log.err("Host start failed: {}", .{err});
        return;
    };
    defer host.stop();

    const addr = host.getBdAddr();
    log.info("BD_ADDR: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        addr[5], addr[4], addr[3], addr[2], addr[1], addr[0],
    });

    const is_server = addr[2] == 0x11;
    log.info("Role: {s}", .{if (is_server) "SERVER" else "CLIENT"});

    if (is_server) {
        runServer(&host);
    } else {
        runClient(&host);
    }

    log.info("", .{});
    log.info("=== ALL TESTS COMPLETE ===", .{});
    while (true) idf.time.sleepMs(5000);
}

fn runServer(host: *BleHost) void {
    host.gatt.handle(SVC_UUID, CHR_UUID, writeHandler, null);

    const adv_data = [_]u8{ 0x02, 0x01, 0x06 } ++ [_]u8{ ADV_NAME.len + 1, 0x09 } ++ ADV_NAME.*;
    host.startAdvertising(.{
        .interval_min = 0x0020,
        .interval_max = 0x0020,
        .adv_data = &adv_data,
    }) catch {
        log.err("Advertising failed", .{});
        return;
    };
    log.info("Advertising \"{s}\"...", .{ADV_NAME});

    // Wait for connection
    while (host.nextEvent()) |event| {
        switch (event) {
            .connected => |info| {
                log.info("Connected! handle=0x{X:0>4}", .{info.conn_handle});

                // Negotiate DLE
                host.requestDataLength(info.conn_handle, 251, 2120) catch {};
                drain(host, 2000);

                // Test 1: ReadX (Server→Client)
                testServerReadX(host, info.conn_handle);

                // Pause between tests
                idf.time.sleepMs(3000);

                // Test 2: WriteX (Client→Server)
                testServerWriteX(host, info.conn_handle);
                return;
            },
            else => {},
        }
    }
}

fn runClient(host: *BleHost) void {
    host.setNotificationCallback(onNotification);

    host.startScanning(.{}) catch {
        log.err("Scanning failed", .{});
        return;
    };
    log.info("Scanning for \"{s}\"...", .{ADV_NAME});

    while (host.nextEvent()) |event| {
        switch (event) {
            .device_found => |report| {
                if (containsName(report.data, ADV_NAME)) {
                    log.info("Found server!", .{});
                    host.connect(report.addr, report.addr_type, .{
                        .interval_min = 0x0006,
                        .interval_max = 0x0006,
                    }) catch {
                        log.err("Connect failed", .{});
                        return;
                    };
                }
            },
            .connected => |info| {
                log.info("Connected! handle=0x{X:0>4}", .{info.conn_handle});

                // Negotiate DLE + 2M PHY
                host.requestDataLength(info.conn_handle, 251, 2120) catch {};
                drain(host, 1000);
                host.requestPhyUpdate(info.conn_handle, 0x02, 0x02) catch {};
                drain(host, 2000);

                // Discover remote GATT handles (needed for cross-platform: ESP↔Mac)
                const handles = discoverHandles(host, info.conn_handle) orelse {
                    log.err("Service discovery failed", .{});
                    return;
                };
                log.info("Discovered: value=0x{X:0>4} cccd=0x{X:0>4}", .{ handles.value, handles.cccd });

                // Subscribe to notifications using discovered CCCD handle
                host.gattSubscribe(info.conn_handle, handles.cccd) catch {};
                idf.time.sleepMs(500);

                // Test 1: ReadX Client (receive from server)
                testClientReadX(host, info.conn_handle, handles.value);

                // Pause between tests
                idf.time.sleepMs(3000);

                // Test 2: WriteX Client (send to server)
                testClientWriteX(host, info.conn_handle, handles.value);
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
