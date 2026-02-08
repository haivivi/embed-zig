//! BLE Host Coordinator — Async Architecture
//!
//! The "server" — owns loops, queues, state, and dispatch.
//! Bridges the HCI transport (fd) with the protocol layers (L2CAP, ATT, GAP).
//!
//! ## Architecture
//!
//! ```
//! Host(Rt, HciTransport, max_services)
//! ├── readLoop  (task via WaitGroup.go)
//! │   ├── hci.poll(.readable) → hci.read()
//! │   ├── Event packets → GAP state machine → event_queue.send()
//! │   └── ACL packets → L2CAP reassembly → ATT → GATT → tx_queue.send()
//! ├── writeLoop (task via WaitGroup.go)
//! │   ├── tx_queue.recv() (blocking)
//! │   └── hci.poll(.writable) → hci.write()
//! ├── tx_queue:    Channel(TxPacket)   — any thread enqueues, writeLoop drains
//! ├── event_queue: Channel(GapEvent)   — readLoop enqueues, app recvs
//! ├── cancel:      CancellationToken   — shutdown signal for readLoop
//! ├── wg:          WaitGroup           — readLoop + writeLoop lifecycle
//! ├── gap:         Gap                 — state machine (accessed from readLoop)
//! ├── gatt:        GattServer          — attribute database (accessed from readLoop)
//! └── l2cap:       Reassembler         — fragment reassembly (accessed from readLoop)
//! ```
//!
//! ## Thread Safety
//!
//! - readLoop: owns GAP, GATT, L2CAP state (single-writer)
//! - writeLoop: only reads from tx_queue (Channel is thread-safe)
//! - App thread: calls sendData/startAdvertising → tx_queue.send() (thread-safe)
//! - App thread: calls nextEvent → event_queue.recv() (thread-safe)
//!
//! ## Lifecycle
//!
//! ```zig
//! var host = Host(Rt, HciDriver, 16).init(&hci_driver);
//! host.gatt.addService(...);
//! host.gatt.addCharacteristic(...);
//! try host.start(allocator);  // spawns readLoop + writeLoop
//! while (host.nextEvent()) |event| { ... }
//! host.stop();  // cancel + close queues + wait for loops
//! ```

const std = @import("std");
const trait = @import("trait");
const channel = @import("channel");
const waitgroup = @import("waitgroup");
const cancellation = @import("cancellation");

const hci_mod = @import("hci/hci.zig");
const acl_mod = @import("hci/acl.zig");
const commands = @import("hci/commands.zig");
const events_mod = @import("hci/events.zig");
const l2cap_mod = @import("l2cap/l2cap.zig");
const att_mod = @import("att/att.zig");
const gap_mod = @import("gap/gap.zig");
const gatt_server = @import("../gatt_server.zig");

// ============================================================================
// TX Packet (enqueued to tx_queue, dequeued by writeLoop)
// ============================================================================

/// A packet to be written to HCI.
/// Holds a copy of the data (value semantics for channel).
pub const TxPacket = struct {
    data: [259]u8 = undefined, // max: indicator(1) + opcode/handle(2) + len(1/2) + payload(255)
    len: usize = 0,

    pub fn fromSlice(src: []const u8) TxPacket {
        var pkt = TxPacket{};
        const n = @min(src.len, pkt.data.len);
        @memcpy(pkt.data[0..n], src[0..n]);
        pkt.len = n;
        return pkt;
    }

    pub fn slice(self: *const TxPacket) []const u8 {
        return self.data[0..self.len];
    }
};

// ============================================================================
// Host
// ============================================================================

/// BLE Host coordinator with async readLoop + writeLoop.
///
/// Generic over:
/// - `Rt`: Runtime type providing Mutex, Condition, Options, spawn
/// - `HciTransport`: HCI driver type (must have read/write/poll)
/// - `max_services`: max GATT services
pub fn Host(comptime Rt: type, comptime HciTransport: type, comptime max_services: usize) type {
    // Validate Runtime at comptime
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
        trait.spawner.from(Rt);
    }

    const TX_QUEUE_SIZE = 16;
    const EVENT_QUEUE_SIZE = 16;

    const TxChannel = channel.Channel(TxPacket, TX_QUEUE_SIZE, Rt);
    const EventChannel = channel.Channel(gap_mod.GapEvent, EVENT_QUEUE_SIZE, Rt);
    const WG = waitgroup.WaitGroup(Rt);

    return struct {
        const Self = @This();

        /// HCI transport driver
        hci: *HciTransport,

        /// TX queue: any thread → writeLoop → hci.write
        tx_queue: TxChannel = TxChannel.init(),

        /// Event queue: readLoop → app
        event_queue: EventChannel = EventChannel.init(),

        /// Task lifecycle management
        wg: WG,

        /// Shutdown signal for readLoop
        cancel: cancellation.CancellationToken = cancellation.CancellationToken.init(),

        /// GAP state machine (owned by readLoop)
        gap: gap_mod.Gap = gap_mod.Gap.init(),

        /// GATT server (owned by readLoop)
        gatt: gatt_server.GattServer(max_services) = gatt_server.GattServer(max_services).init(),

        /// L2CAP reassembler (owned by readLoop)
        reassembler: l2cap_mod.Reassembler = .{},

        /// Read buffer (owned by readLoop)
        rx_buf: [512]u8 = undefined,

        /// ATT response buffer (owned by readLoop)
        att_resp_buf: [att_mod.MAX_PDU_LEN]u8 = undefined,

        /// L2CAP fragment buffer (owned by readLoop for TX responses)
        l2cap_frag_buf: [acl_mod.LE_MAX_DATA_LEN + l2cap_mod.HEADER_LEN]u8 = undefined,

        /// Initialize the Host with an HCI transport driver.
        pub fn init(hci: *HciTransport, allocator: std.mem.Allocator) Self {
            return .{
                .hci = hci,
                .wg = WG.init(allocator),
            };
        }

        /// Release resources.
        pub fn deinit(self: *Self) void {
            self.event_queue.deinit();
            self.tx_queue.deinit();
            self.wg.deinit();
        }

        // ================================================================
        // Lifecycle
        // ================================================================

        /// Start the Host.
        ///
        /// 1. Sends HCI Reset synchronously (before loops start)
        /// 2. Spawns readLoop + writeLoop as separate tasks
        pub fn start(self: *Self, opts: Rt.Options) !void {
            // --- Synchronous init: HCI Reset ---
            var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const reset_cmd = commands.reset(&cmd_buf);
            _ = self.hci.write(reset_cmd) catch return error.HciError;

            // Wait for Command Complete (blocking, before loops start)
            const ready = self.hci.poll(.{ .readable = true }, 2000);
            if (ready.readable) {
                const n = self.hci.read(&self.rx_buf) catch 0;
                if (n > 1 and self.rx_buf[0] == @intFromEnum(hci_mod.PacketType.event)) {
                    if (events_mod.decode(self.rx_buf[1..n])) |evt| {
                        self.gap.handleEvent(evt);
                    }
                }
            }

            // --- Spawn readLoop + writeLoop ---
            self.cancel.reset();

            try self.wg.go("ble-read", readLoopEntry, self, opts);
            try self.wg.go("ble-write", writeLoopEntry, self, opts);
        }

        /// Stop the Host.
        ///
        /// 1. Cancel readLoop (CancellationToken)
        /// 2. Close tx_queue (wakes writeLoop, recv returns null)
        /// 3. Close event_queue (wakes app if blocked on nextEvent)
        /// 4. Wait for both loops to exit
        pub fn stop(self: *Self) void {
            self.cancel.cancel();
            self.tx_queue.close();
            self.event_queue.close();
            self.wg.wait();
        }

        // ================================================================
        // App API (thread-safe, enqueue to channels)
        // ================================================================

        /// Receive the next GAP event (blocking).
        /// Returns null when Host is stopped.
        pub fn nextEvent(self: *Self) ?gap_mod.GapEvent {
            return self.event_queue.recv();
        }

        /// Try to receive a GAP event (non-blocking).
        pub fn tryNextEvent(self: *Self) ?gap_mod.GapEvent {
            return self.event_queue.tryRecv();
        }

        /// Start BLE advertising.
        /// Enqueues HCI commands to tx_queue.
        pub fn startAdvertising(self: *Self, config: gap_mod.AdvConfig) !void {
            try self.gap.startAdvertising(config);
            try self.flushGapCommands();
        }

        /// Stop BLE advertising.
        pub fn stopAdvertising(self: *Self) !void {
            try self.gap.stopAdvertising();
            try self.flushGapCommands();
        }

        /// Disconnect from a peer.
        pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) !void {
            try self.gap.disconnect(conn_handle, reason);
            try self.flushGapCommands();
        }

        /// Send raw L2CAP data (thread-safe).
        /// Fragments into ACL packets and enqueues to tx_queue.
        pub fn sendData(self: *Self, conn_handle: u16, cid: u16, data: []const u8) !void {
            var frag_buf: [acl_mod.LE_MAX_DATA_LEN + l2cap_mod.HEADER_LEN]u8 = undefined;
            var iter = l2cap_mod.fragmentIterator(
                &frag_buf,
                data,
                cid,
                conn_handle,
                acl_mod.LE_DEFAULT_DATA_LEN,
            );

            while (iter.next()) |frag| {
                self.tx_queue.send(TxPacket.fromSlice(frag)) catch return error.QueueClosed;
            }
        }

        /// Send a GATT notification (thread-safe).
        pub fn notify(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) !void {
            var buf: [att_mod.MAX_PDU_LEN]u8 = undefined;
            const pdu = att_mod.encodeNotification(&buf, attr_handle, value);
            try self.sendData(conn_handle, l2cap_mod.CID_ATT, pdu);
        }

        /// Send a GATT indication (thread-safe).
        pub fn indicate(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) !void {
            var buf: [att_mod.MAX_PDU_LEN]u8 = undefined;
            const pdu = att_mod.encodeIndication(&buf, attr_handle, value);
            try self.sendData(conn_handle, l2cap_mod.CID_ATT, pdu);
        }

        /// Get the current GAP state.
        pub fn getState(self: *const Self) gap_mod.State {
            return self.gap.state;
        }

        /// Get the active connection handle (if connected).
        pub fn getConnHandle(self: *const Self) ?u16 {
            return self.gap.conn_handle;
        }

        // ================================================================
        // Internal: flush GAP commands to tx_queue
        // ================================================================

        fn flushGapCommands(self: *Self) !void {
            while (self.gap.nextCommand()) |cmd| {
                self.tx_queue.send(TxPacket.fromSlice(cmd)) catch return error.QueueClosed;
            }
        }

        // ================================================================
        // readLoop — runs in its own task
        // ================================================================

        fn readLoopEntry(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.readLoop();
        }

        fn readLoop(self: *Self) void {
            while (!self.cancel.isCancelled()) {
                // Poll HCI for readable data (100ms timeout to check cancel)
                const ready = self.hci.poll(.{ .readable = true }, 100);
                if (!ready.readable) continue;

                const n = self.hci.read(&self.rx_buf) catch continue;
                if (n == 0) continue;

                const pkt_type: hci_mod.PacketType = @enumFromInt(self.rx_buf[0]);
                const pkt_data = self.rx_buf[1..n];

                switch (pkt_type) {
                    .event => self.handleHciEvent(pkt_data),
                    .acl_data => self.handleAclData(pkt_data),
                    else => {}, // Ignore sync/ISO
                }
            }
        }

        fn handleHciEvent(self: *Self, data: []const u8) void {
            const event = events_mod.decode(data) orelse return;
            self.gap.handleEvent(event);

            // Flush any new GAP commands (e.g., from connection event handling)
            self.flushGapCommands() catch {};

            // Deliver GAP events to app
            while (self.gap.pollEvent()) |gap_event| {
                self.event_queue.trySend(gap_event) catch {};
            }
        }

        fn handleAclData(self: *Self, data: []const u8) void {
            const acl_hdr = acl_mod.parseHeader(data) orelse return;

            const acl_payload_start: usize = acl_mod.HEADER_LEN;
            if (data.len < acl_payload_start + acl_hdr.data_len) return;
            const acl_payload = data[acl_payload_start..][0..acl_hdr.data_len];

            // L2CAP reassembly
            const sdu = self.reassembler.feed(acl_hdr, acl_payload) orelse return;

            // Dispatch by CID
            switch (sdu.cid) {
                l2cap_mod.CID_ATT => self.handleAttPdu(sdu),
                l2cap_mod.CID_SMP => {}, // future
                l2cap_mod.CID_LE_SIGNALING => {}, // future
                else => {},
            }
        }

        fn handleAttPdu(self: *Self, sdu: l2cap_mod.Sdu) void {
            const response = self.gatt.handlePdu(
                sdu.conn_handle,
                sdu.data,
                &self.att_resp_buf,
            ) orelse return;

            // Enqueue ATT response to tx_queue (via L2CAP fragmentation)
            var frag_buf: [acl_mod.LE_MAX_DATA_LEN + l2cap_mod.HEADER_LEN]u8 = undefined;
            var iter = l2cap_mod.fragmentIterator(
                &frag_buf,
                response,
                l2cap_mod.CID_ATT,
                sdu.conn_handle,
                acl_mod.LE_DEFAULT_DATA_LEN,
            );

            while (iter.next()) |frag| {
                self.tx_queue.trySend(TxPacket.fromSlice(frag)) catch {};
            }
        }

        // ================================================================
        // writeLoop — runs in its own task
        // ================================================================

        fn writeLoopEntry(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.writeLoop();
        }

        fn writeLoop(self: *Self) void {
            while (true) {
                // Block until a packet is available (or channel is closed)
                const pkt = self.tx_queue.recv() orelse break;

                // Wait until HCI is writable
                while (!self.cancel.isCancelled()) {
                    const ready = self.hci.poll(.{ .writable = true }, 100);
                    if (ready.writable) break;
                }

                if (self.cancel.isCancelled()) break;

                // Write to HCI
                _ = self.hci.write(pkt.slice()) catch {};
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Host async init and lifecycle" {
    const TestRt = @import("runtime");
    const Ch = channel.Channel;

    // Mock HCI driver
    const MockHci = struct {
        const Self = @This();
        const HciError = error{ WouldBlock, HciError };

        const PollFlags = packed struct {
            readable: bool = false,
            writable: bool = false,
            _padding: u6 = 0,
        };

        written_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        rx_data: [512]u8 = undefined,
        rx_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        readable: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn read(self: *Self, buf: []u8) HciError!usize {
            if (!self.readable.load(.acquire)) return error.WouldBlock;
            const n = @min(buf.len, self.rx_len.load(.acquire));
            @memcpy(buf[0..n], self.rx_data[0..n]);
            self.rx_len.store(0, .release);
            self.readable.store(false, .release);
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) HciError!usize {
            _ = self.written_count.fetchAdd(1, .acq_rel);
            return buf.len;
        }

        pub fn poll(self: *Self, flags: PollFlags, _: i32) PollFlags {
            return .{
                .readable = flags.readable and self.readable.load(.acquire),
                .writable = flags.writable, // always writable
            };
        }

        fn injectResponse(self: *Self, data: []const u8) void {
            @memcpy(self.rx_data[0..data.len], data);
            self.rx_len.store(data.len, .release);
            self.readable.store(true, .release);
        }
    };

    var hci_driver = MockHci{};

    // Prepare HCI Reset Command Complete response
    const reset_response = [_]u8{
        @intFromEnum(hci_mod.PacketType.event),
        0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00,
    };
    hci_driver.injectResponse(&reset_response);

    const TestHost = Host(TestRt, MockHci, 4);
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    // Start should send HCI Reset and spawn loops
    try host.start(.{});

    // Give loops time to start
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // HCI Reset command should have been written
    try std.testing.expect(host.hci.written_count.load(.acquire) >= 1);

    // Stop should cleanly shut down
    host.stop();

    // Verify no events leaked
    try std.testing.expect(host.tryNextEvent() == null);

    // Verify unused channel for send after stop
    _ = Ch(TxPacket, 16, TestRt); // just type check
}

test "Host async TX via sendData" {
    const TestRt = @import("runtime");

    const MockHci = struct {
        const Self = @This();
        const HciError = error{ WouldBlock, HciError };

        const PollFlags = packed struct {
            readable: bool = false,
            writable: bool = false,
            _padding: u6 = 0,
        };

        written_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        rx_data: [512]u8 = undefined,
        rx_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        readable: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn read(self: *Self, buf: []u8) HciError!usize {
            if (!self.readable.load(.acquire)) return error.WouldBlock;
            const n = @min(buf.len, self.rx_len.load(.acquire));
            @memcpy(buf[0..n], self.rx_data[0..n]);
            self.rx_len.store(0, .release);
            self.readable.store(false, .release);
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) HciError!usize {
            _ = self.written_count.fetchAdd(1, .acq_rel);
            return buf.len;
        }

        pub fn poll(self: *Self, flags: PollFlags, _: i32) PollFlags {
            return .{
                .readable = flags.readable and self.readable.load(.acquire),
                .writable = flags.writable,
            };
        }

        fn injectResponse(self: *Self, data: []const u8) void {
            @memcpy(self.rx_data[0..data.len], data);
            self.rx_len.store(data.len, .release);
            self.readable.store(true, .release);
        }
    };

    var hci_driver = MockHci{};

    const reset_response = [_]u8{
        @intFromEnum(hci_mod.PacketType.event),
        0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00,
    };
    hci_driver.injectResponse(&reset_response);

    const TestHost = Host(TestRt, MockHci, 4);
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});

    // Give loops time to start
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const written_before = hci_driver.written_count.load(.acquire);

    // Send data through tx_queue → writeLoop → hci.write
    try host.sendData(0x0040, l2cap_mod.CID_ATT, "hello BLE");

    // Wait for writeLoop to process
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const written_after = hci_driver.written_count.load(.acquire);
    try std.testing.expect(written_after > written_before);

    host.stop();
}
