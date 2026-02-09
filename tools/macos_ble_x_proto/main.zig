//! macOS BLE X-Proto Throughput Test
//!
//! Tests READ_X / WRITE_X chunked transfer between macOS and ESP32.
//!
//!   --server  macOS as peripheral, ESP32 connects as client
//!   --client  macOS connects to ESP32 running ble_x_proto_test server
//!
//! Uses CoreBluetooth (cb module) + x_proto protocol.
//! Service 0xCC00 / Char 0xCC01 (same as ESP32 ble_x_proto_test).

const std = @import("std");
const cb = @import("cb");
const x_proto = @import("x_proto");
const chunk = x_proto.chunk;

const SVC = "CC00";
const CHR = "CC01";
const TARGET_NAME = "XProto";
const TEST_DATA_SIZE = 900 * 1024;
const TEST_MTU: u16 = 247;

// ============================================================================
// RX Queue — single-threaded, callbacks fire during runLoopOnce
// ============================================================================

const RxQueue = struct {
    const Entry = struct {
        data: [512]u8 = undefined,
        len: usize = 0,
    };
    const CAP = 64;

    entries: [CAP]Entry = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn push(self: *RxQueue, data: [*c]const u8, len: u16) void {
        if (self.count >= CAP) return; // full — drop (x_proto will retransmit)
        const n: usize = @min(len, 512);
        @memcpy(self.entries[self.head].data[0..n], data[0..n]);
        self.entries[self.head].len = n;
        self.head = (self.head + 1) % CAP;
        self.count += 1;
    }

    fn pop(self: *RxQueue) ?Entry {
        if (self.count == 0) return null;
        const entry = self.entries[self.tail];
        self.tail = (self.tail + 1) % CAP;
        self.count -= 1;
        return entry;
    }
};

// ============================================================================
// CoreBluetooth Transport for x_proto
// ============================================================================

// CbTransport removed — use ServerTransport / ClientTransport directly

const ServerTransport = struct {
    rx: RxQueue = .{},

    pub fn send(_: *ServerTransport, data: []const u8) !void {
        // CoreBluetooth transmit queue can fill up. Retry with run loop pump.
        var retries: u32 = 0;
        while (retries < 5000) : (retries += 1) {
            cb.Peripheral.notify(SVC, CHR, data) catch {
                cb.runLoopOnce(1); // pump events → frees transmit queue
                continue;
            };
            return;
        }
        return error.SendFailed;
    }

    pub fn recv(self: *ServerTransport, buf: []u8, timeout_ms: u32) !?usize {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            cb.runLoopOnce(1);
            if (self.rx.pop()) |entry| {
                const n = @min(entry.len, buf.len);
                @memcpy(buf[0..n], entry.data[0..n]);
                return n;
            }
        }
        return null;
    }
};

const ClientTransport = struct {
    rx: RxQueue = .{},

    pub fn send(_: *ClientTransport, data: []const u8) !void {
        cb.Central.writeNoResponse(SVC, CHR, data) catch return error.SendFailed;
    }

    pub fn recv(self: *ClientTransport, buf: []u8, timeout_ms: u32) !?usize {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            cb.runLoopOnce(1);
            if (self.rx.pop()) |entry| {
                const n = @min(entry.len, buf.len);
                @memcpy(buf[0..n], entry.data[0..n]);
                return n;
            }
        }
        return null;
    }
};

// ============================================================================
// Global state + callbacks
// ============================================================================

var g_server_transport: ?*ServerTransport = null;
var g_client_transport: ?*ClientTransport = null;
var g_connected = false;
var g_subscribed = false;
var g_device_found = false;
var g_target_uuid: [64]u8 = undefined;
var g_target_uuid_len: usize = 0;

fn onWrite(_: [*c]const u8, _: [*c]const u8, data: [*c]const u8, len: u16) callconv(.c) void {
    if (g_server_transport) |t| t.rx.push(data, len);
}

fn onNotification(_: [*c]const u8, _: [*c]const u8, data: [*c]const u8, len: u16) callconv(.c) void {
    if (g_client_transport) |t| t.rx.push(data, len);
}

fn onConnection(connected: bool) callconv(.c) void {
    g_connected = connected;
    print("[conn] {}\n", .{connected});
}

fn onSubscribe(_: [*c]const u8, _: [*c]const u8, subscribed: bool) callconv(.c) void {
    g_subscribed = subscribed;
    print("[subscribe] {}\n", .{subscribed});
}

fn onDeviceFound(name: [*c]const u8, uuid: [*c]const u8, rssi: c_int) callconv(.c) void {
    const name_str = std.mem.span(name);
    if (std.mem.eql(u8, name_str, TARGET_NAME)) {
        const uuid_str = std.mem.span(uuid);
        const len = @min(uuid_str.len, g_target_uuid.len);
        @memcpy(g_target_uuid[0..len], uuid_str[0..len]);
        g_target_uuid_len = len;
        g_device_found = true;
        print("Found \"{s}\" (RSSI: {})\n", .{ name_str, rssi });
    }
}

// ============================================================================
// Test data
// ============================================================================

fn generateTestData() ![TEST_DATA_SIZE]u8 {
    var data: [TEST_DATA_SIZE]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    return data;
}

fn verifyData(received: []const u8) bool {
    if (received.len != TEST_DATA_SIZE) return false;
    for (received, 0..) |b, i| {
        if (b != @as(u8, @truncate(i))) return false;
    }
    return true;
}

// ============================================================================
// Inline chunk sender (WriteX client side)
// ============================================================================

fn clientSendChunks(transport: *ClientTransport, data: []const u8) !void {
    const dcs = chunk.dataChunkSize(TEST_MTU);
    const total: u16 = @intCast(chunk.chunksNeeded(data.len, TEST_MTU));
    const mask_len = chunk.Bitmask.requiredBytes(total);

    var sndmask: [chunk.max_mask_bytes]u8 = undefined;
    chunk.Bitmask.initAllSet(sndmask[0..mask_len], total);

    var chunk_buf: [chunk.max_mtu]u8 = undefined;
    var recv_buf: [chunk.max_mtu]u8 = undefined;

    while (true) {
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

            // Pump run loop periodically to allow ACK to arrive
            if (i % 50 == 0) cb.runLoopOnce(0);
        }

        const resp_len = (try transport.recv(&recv_buf, 30_000)) orelse return error.Timeout;
        if (chunk.isAck(recv_buf[0..resp_len])) return;

        chunk.Bitmask.initClear(sndmask[0..mask_len], total);
        var loss_seqs: [260]u16 = undefined;
        const loss_count = chunk.decodeLossList(recv_buf[0..resp_len], &loss_seqs);
        if (loss_count == 0) return error.InvalidResponse;
        print("Retransmitting {} lost chunks\n", .{loss_count});
        for (loss_seqs[0..loss_count]) |seq| {
            if (seq >= 1 and seq <= total) chunk.Bitmask.set(sndmask[0..mask_len], seq);
        }
    }
}

// ============================================================================
// Server Mode (macOS peripheral ↔ ESP32 client)
// ============================================================================

fn runServer() !void {
    print("=== macOS X-Proto Server (Peripheral) ===\n", .{});

    cb.Peripheral.setWriteCallback(onWrite);
    cb.Peripheral.setSubscribeCallback(onSubscribe);
    cb.Peripheral.setConnectionCallback(onConnection);

    try cb.Peripheral.init();

    const chr_uuids = [_][*c]const u8{CHR};
    const chr_props = [_]u8{cb.PROP_WRITE | cb.PROP_WRITE_NO_RSP | cb.PROP_READ | cb.PROP_NOTIFY};
    try cb.Peripheral.addService(SVC, &chr_uuids, &chr_props, 1);

    try cb.Peripheral.startAdvertising(TARGET_NAME);
    print("Advertising \"{s}\"... waiting for ESP32 client\n", .{TARGET_NAME});

    // In CoreBluetooth Peripheral mode, connection is implicit.
    // Wait for subscribe (implies connection established).
    while (!g_subscribed) cb.runLoopOnce(100);
    print("Client connected + subscribed!\n\n", .{});

    // Test 1: ReadX (Server → Client)
    {
        print("=== Test 1: ReadX (Server → Client) ===\n", .{});
        const data = generateTestData() catch unreachable;
        print("Data: {} KB, MTU: {}, chunks: {}\n", .{
            TEST_DATA_SIZE / 1024, TEST_MTU, chunk.chunksNeeded(data.len, TEST_MTU),
        });

        var transport = ServerTransport{};
        g_server_transport = &transport;
        defer {
            g_server_transport = null;
        }

        print("Waiting for start magic...\n", .{});
        const start = std.time.milliTimestamp();

        var rx = x_proto.ReadX(ServerTransport).init(&transport, &data, .{
            .mtu = TEST_MTU,
            .send_redundancy = 1,
            .start_timeout_ms = 60_000,
            .ack_timeout_ms = 60_000,
        });
        rx.run() catch |err| {
            print("ReadX FAILED: {}\n", .{err});
            return;
        };

        const elapsed = std.time.milliTimestamp() - start;
        const kbs = @as(f64, @floatFromInt(TEST_DATA_SIZE)) / 1024.0 / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
        print("ReadX DONE: {} KB in {} ms = {d:.1} KB/s\n\n", .{
            TEST_DATA_SIZE / 1024, elapsed, kbs,
        });
    }

    // Pause
    print("Pausing 3s before next test...\n", .{});
    for (0..30) |_| cb.runLoopOnce(100);

    // Test 2: WriteX (Client → Server)
    {
        print("=== Test 2: WriteX (Client → Server) ===\n", .{});
        var recv_buf: [TEST_DATA_SIZE + 4096]u8 = undefined;

        var transport = ServerTransport{};
        g_server_transport = &transport;
        defer {
            g_server_transport = null;
        }

        print("Waiting for client chunks...\n", .{});
        const start = std.time.milliTimestamp();

        var wx = x_proto.WriteX(ServerTransport).init(&transport, &recv_buf, .{
            .mtu = TEST_MTU,
            .timeout_ms = 30_000,
            .max_retries = 10,
        });
        const result = wx.run() catch |err| {
            print("WriteX FAILED: {}\n", .{err});
            return;
        };

        const elapsed = std.time.milliTimestamp() - start;
        const data_len = result.data.len;
        const kbs = @as(f64, @floatFromInt(data_len)) / 1024.0 / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
        print("WriteX DONE: {} KB in {} ms = {d:.1} KB/s\n", .{
            data_len / 1024, elapsed, kbs,
        });
        if (verifyData(result.data))
            print("Data integrity: PASS\n", .{})
        else
            print("Data integrity: FAIL (got {} bytes)\n", .{data_len});
    }
}

// ============================================================================
// Client Mode (macOS central ↔ ESP32 server)
// ============================================================================

fn runClient() !void {
    print("=== macOS X-Proto Client (Central) ===\n", .{});

    cb.Central.setDeviceFoundCallback(onDeviceFound);
    cb.Central.setConnectionCallback(onConnection);
    cb.Central.setNotificationCallback(onNotification);

    try cb.Central.init();

    try cb.Central.scanStart(null);
    print("Scanning for \"{s}\"...\n", .{TARGET_NAME});

    var scan_time: u32 = 0;
    while (!g_device_found and scan_time < 200) : (scan_time += 1) cb.runLoopOnce(100);
    cb.Central.scanStop();

    if (!g_device_found) {
        print("ESP32 not found! Is ble_x_proto_test running?\n", .{});
        return;
    }

    g_target_uuid[g_target_uuid_len] = 0;
    cb.Central.connect(&g_target_uuid) catch {
        print("Connect failed\n", .{});
        return;
    };

    var conn_time: u32 = 0;
    while (!g_connected and conn_time < 100) : (conn_time += 1) cb.runLoopOnce(100);
    if (!g_connected) {
        print("Connection timeout\n", .{});
        return;
    }

    // Wait for service discovery
    for (0..20) |_| cb.runLoopOnce(100);

    // Subscribe
    _ = cb.Central.subscribe(SVC, CHR) catch {};
    for (0..10) |_| cb.runLoopOnce(100);
    print("Subscribed to notifications.\n\n", .{});

    // Test 1: ReadX Client (receive from server)
    {
        print("=== Test 1: ReadX Client (receive from server) ===\n", .{});
        var recv_buf: [TEST_DATA_SIZE + 4096]u8 = undefined;

        var transport = ClientTransport{};
        g_client_transport = &transport;
        defer {
            g_client_transport = null;
        }

        print("Sending start magic...\n", .{});
        try transport.send(&chunk.start_magic);

        const start = std.time.milliTimestamp();
        var wx = x_proto.WriteX(ClientTransport).init(&transport, &recv_buf, .{
            .mtu = TEST_MTU,
            .timeout_ms = 30_000,
            .max_retries = 10,
        });
        const result = wx.run() catch |err| {
            print("ReadX client FAILED: {}\n", .{err});
            return;
        };

        const elapsed = std.time.milliTimestamp() - start;
        const data_len = result.data.len;
        const kbs = @as(f64, @floatFromInt(data_len)) / 1024.0 / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
        print("ReadX Client DONE: {} KB in {} ms = {d:.1} KB/s\n", .{
            data_len / 1024, elapsed, kbs,
        });
        if (verifyData(result.data))
            print("Data integrity: PASS\n\n", .{})
        else
            print("Data integrity: FAIL (got {} bytes)\n\n", .{data_len});
    }

    // Pause
    print("Pausing 3s...\n", .{});
    for (0..30) |_| cb.runLoopOnce(100);

    // Test 2: WriteX Client (send to server)
    {
        print("=== Test 2: WriteX Client (send to server) ===\n", .{});
        const data = generateTestData() catch unreachable;
        print("Data: {} KB, MTU: {}, chunks: {}\n", .{
            TEST_DATA_SIZE / 1024, TEST_MTU, chunk.chunksNeeded(data.len, TEST_MTU),
        });

        var transport = ClientTransport{};
        g_client_transport = &transport;
        defer {
            g_client_transport = null;
        }

        const start = std.time.milliTimestamp();
        clientSendChunks(&transport, &data) catch |err| {
            print("WriteX client FAILED: {}\n", .{err});
            return;
        };

        const elapsed = std.time.milliTimestamp() - start;
        const kbs = @as(f64, @floatFromInt(TEST_DATA_SIZE)) / 1024.0 / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
        print("WriteX Client DONE: {} KB in {} ms = {d:.1} KB/s\n", .{
            TEST_DATA_SIZE / 1024, elapsed, kbs,
        });
    }

    // Cleanup
    _ = cb.Central.unsubscribe(SVC, CHR) catch {};
    cb.Central.disconnect();
    for (0..10) |_| cb.runLoopOnce(100);
}

// ============================================================================
// Main
// ============================================================================

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn main() !void {
    print("==========================================\n", .{});
    print("macOS BLE X-Proto Test (CoreBluetooth)\n", .{});
    print("Data: {} KB, MTU: {}\n", .{ TEST_DATA_SIZE / 1024, TEST_MTU });
    print("==========================================\n\n", .{});

    var args = std.process.args();
    _ = args.next();

    const mode = args.next() orelse {
        print("Usage:\n", .{});
        print("  zig build run -- --server   (mac-server ↔ esp-client)\n", .{});
        print("  zig build run -- --client   (mac-client ↔ esp-server)\n", .{});
        return;
    };

    if (std.mem.eql(u8, mode, "--server")) {
        try runServer();
    } else if (std.mem.eql(u8, mode, "--client")) {
        try runClient();
    } else {
        print("Unknown: {s}\nUse --server or --client\n", .{mode});
    }

    print("\n=== DONE ===\n", .{});
}
