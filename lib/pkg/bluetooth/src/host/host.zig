//! BLE Host Coordinator — Async Architecture with HCI ACL Flow Control
//!
//! The "server" — owns loops, queues, state, and dispatch.
//! Bridges the HCI transport (fd) with the protocol layers (L2CAP, ATT, GAP).
//!
//! ## Architecture
//!
//! ```
//! Host(Rt, HciTransport, service_table)
//! ├── readLoop  (task via WaitGroup.go)
//! │   ├── hci.poll(.readable) → hci.read()
//! │   ├── NCP events → acl_credits.release() (flow control)
//! │   ├── Other events → GAP state machine → event_queue.send()
//! │   └── ACL packets → L2CAP reassembly → ATT → GATT → tx_queue.send()
//! ├── writeLoop (task via WaitGroup.go)
//! │   ├── tx_queue.recv() (blocking)
//! │   ├── acl_credits.acquire() (blocks if 0 credits — HCI flow control)
//! │   └── hci.write()
//! ├── tx_queue:     Channel(TxPacket)   — any thread enqueues, writeLoop drains
//! ├── event_queue:  Channel(GapEvent)   — readLoop enqueues, app recvs
//! ├── acl_credits:  AclCredits          — counting semaphore for HCI flow control
//! ├── cancel:       CancellationToken   — shutdown signal for readLoop
//! ├── wg:           WaitGroup           — readLoop + writeLoop lifecycle
//! ├── gap:          Gap                 — state machine (accessed from readLoop)
//! ├── gatt:         GattServer          — attribute database (accessed from readLoop)
//! └── l2cap:        Reassembler         — fragment reassembly (accessed from readLoop)
//! ```
//!
//! ## HCI ACL Flow Control
//!
//! The controller has a limited number of ACL buffer slots (typically 12).
//! We MUST NOT send more ACL packets than available slots. The flow:
//!
//! 1. start() reads LE_Read_Buffer_Size → acl_credits = Total_Num_LE_ACL_Data_Packets
//! 2. writeLoop: before each hci.write(), acl_credits.acquire() (blocks if 0)
//! 3. readLoop: on Number_of_Completed_Packets event, acl_credits.release(count)
//!
//! HCI commands (GAP commands) do NOT consume ACL credits — only ACL data packets do.
//! The writeLoop distinguishes between command packets (0x01) and ACL data (0x02).
//!
//! ## Lifecycle
//!
//! ```zig
//! var host = Host(Rt, HciDriver, &my_services).init(&hci_driver, allocator);
//! host.gatt.addService(...);
//! try host.start(opts);  // HCI Reset + Read Buffer Size + spawn loops
//! while (host.nextEvent()) |event| { ... }
//! host.stop();
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
// TX Packet
// ============================================================================

pub const TxPacket = struct {
    data: [259]u8 = undefined,
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

    /// Is this an ACL data packet (indicator 0x02)?
    /// ACL packets consume ACL credits. Commands (0x01) do not.
    pub fn isAclData(self: *const TxPacket) bool {
        return self.len > 0 and self.data[0] == @intFromEnum(hci_mod.PacketType.acl_data);
    }
};

// ============================================================================
// ACL Credits — counting semaphore for HCI flow control
// ============================================================================

/// Counting semaphore built from Mutex + Condition.
/// Used to track available ACL buffer slots in the controller.
fn AclCredits(comptime Rt: type) type {
    return struct {
        const Self = @This();

        mutex: Rt.Mutex,
        cond: Rt.Condition,
        count: u32,
        closed: bool,

        pub fn init(initial: u32) Self {
            return .{
                .mutex = Rt.Mutex.init(),
                .cond = Rt.Condition.init(),
                .count = initial,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        /// Acquire one credit (blocks if count == 0).
        /// Returns false if closed (shutdown).
        pub fn acquire(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0 and !self.closed) {
                self.cond.wait(&self.mutex);
            }

            if (self.closed) return false;

            self.count -= 1;
            return true;
        }

        /// Release `n` credits (called when NCP event received).
        pub fn release(self: *Self, n: u32) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.count += n;
            // Wake writeLoop if it was waiting
            if (n > 0) self.cond.broadcast();
        }

        /// Close the semaphore (wake all waiters for shutdown).
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;
            self.cond.broadcast();
        }

        /// Get current count (diagnostic).
        pub fn getCount(self: *Self) u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }
    };
}

// ============================================================================
// Host
// ============================================================================

pub fn Host(comptime Rt: type, comptime HciTransport: type, comptime service_table: []const gatt_server.ServiceDef) type {
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
        trait.spawner.from(Rt);
    }

    const TX_QUEUE_SIZE = 32;
    const EVENT_QUEUE_SIZE = 16;

    const TxChannel = channel.Channel(TxPacket, TX_QUEUE_SIZE, Rt);
    const EventChannel = channel.Channel(gap_mod.GapEvent, EVENT_QUEUE_SIZE, Rt);
    const Credits = AclCredits(Rt);
    const WG = waitgroup.WaitGroup(Rt);

    return struct {
        const Self = @This();

        // ================================================================
        // Core state
        // ================================================================

        hci: *HciTransport,
        tx_queue: TxChannel,
        event_queue: EventChannel,
        acl_credits: Credits,
        wg: WG,
        cancel: cancellation.CancellationToken,

        // ================================================================
        // Protocol layers (owned by readLoop)
        // ================================================================

        gap: gap_mod.Gap = gap_mod.Gap.init(),
        gatt: gatt_server.GattServer(service_table) = gatt_server.GattServer(service_table).init(),
        reassembler: l2cap_mod.Reassembler = .{},

        // ================================================================
        // Controller info (set during start)
        // ================================================================

        acl_max_len: u16 = 27,  // from LE_Read_Buffer_Size
        acl_max_slots: u16 = 0, // from LE_Read_Buffer_Size
        bd_addr: hci_mod.BdAddr = .{ 0, 0, 0, 0, 0, 0 }, // from Read_BD_ADDR

        // ================================================================
        // Buffers (owned by readLoop)
        // ================================================================

        rx_buf: [512]u8 = undefined,
        att_resp_buf: [att_mod.MAX_PDU_LEN]u8 = undefined,

        // ================================================================
        // Init / Deinit
        // ================================================================

        pub fn init(hci: *HciTransport, allocator: std.mem.Allocator) Self {
            return .{
                .hci = hci,
                .tx_queue = TxChannel.init(),
                .event_queue = EventChannel.init(),
                .acl_credits = Credits.init(0),
                .wg = WG.init(allocator),
                .cancel = cancellation.CancellationToken.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.acl_credits.deinit();
            self.event_queue.deinit();
            self.tx_queue.deinit();
            self.wg.deinit();
        }

        // ================================================================
        // Lifecycle
        // ================================================================

        /// Start the Host.
        ///
        /// Synchronous init sequence:
        /// 1. HCI Reset
        /// 2. LE Read Buffer Size → get acl_max_slots
        /// 3. Set Event Mask (enable NCP + LE events)
        /// 4. LE Set Event Mask (enable connection + PHY + DLE events)
        /// 5. Initialize acl_credits
        /// 6. Spawn readLoop + writeLoop
        pub fn start(self: *Self, opts: Rt.Options) !void {
            // --- 1. HCI Reset ---
            {
                var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
                try self.syncCommand(commands.reset(&cmd_buf));
            }

            // --- 2. LE Read Buffer Size ---
            {
                var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
                const resp = try self.syncCommandWithResponse(
                    commands.encode(&cmd_buf, commands.LE_READ_BUFFER_SIZE, &.{}),
                );
                // Return params: [LE_ACL_Data_Packet_Length(2)][Total_Num(1)]
                if (resp.return_params.len >= 3) {
                    self.acl_max_len = std.mem.readInt(u16, resp.return_params[0..2], .little);
                    self.acl_max_slots = resp.return_params[2];
                }
                if (self.acl_max_slots == 0) self.acl_max_slots = 12; // fallback
            }

            // --- 3. Read BD_ADDR ---
            {
                var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
                const resp = try self.syncCommandWithResponse(
                    commands.encode(&cmd_buf, commands.READ_BD_ADDR, &.{}),
                );
                if (resp.return_params.len >= 6) {
                    self.bd_addr = resp.return_params[0..6].*;
                }
            }

            // --- 4. Set Event Mask (enable NCP + LE Meta + Disconnection) ---
            {
                var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
                try self.syncCommand(commands.setEventMask(&cmd_buf, 0x3DBFF807FFFBFFFF));
            }

            // --- 5. LE Set Event Mask ---
            {
                var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
                try self.syncCommand(commands.leSetEventMask(&cmd_buf, 0x000000000000097F));
            }

            // --- 6. Initialize ACL credits ---
            self.acl_credits = Credits.init(self.acl_max_slots);

            // --- 7. Spawn loops ---
            self.cancel.reset();
            try self.wg.go("ble-read", readLoopEntry, self, opts);
            try self.wg.go("ble-write", writeLoopEntry, self, opts);
        }

        /// Stop the Host.
        pub fn stop(self: *Self) void {
            self.cancel.cancel();
            self.tx_queue.close();
            self.event_queue.close();
            self.acl_credits.close();
            self.wg.wait();
        }

        // ================================================================
        // App API — Peripheral
        // ================================================================

        pub fn startAdvertising(self: *Self, config: gap_mod.AdvConfig) !void {
            try self.gap.startAdvertising(config);
            try self.flushGapCommands();
        }

        pub fn stopAdvertising(self: *Self) !void {
            try self.gap.stopAdvertising();
            try self.flushGapCommands();
        }

        // ================================================================
        // App API — Central
        // ================================================================

        pub fn startScanning(self: *Self, config: gap_mod.ScanConfig) !void {
            try self.gap.startScanning(config);
            try self.flushGapCommands();
        }

        pub fn stopScanning(self: *Self) !void {
            try self.gap.stopScanning();
            try self.flushGapCommands();
        }

        pub fn connect(
            self: *Self,
            peer_addr: hci_mod.BdAddr,
            peer_addr_type: hci_mod.AddrType,
            params: gap_mod.ConnParams,
        ) !void {
            try self.gap.connect(peer_addr, peer_addr_type, params);
            try self.flushGapCommands();
        }

        // ================================================================
        // App API — Connection Management
        // ================================================================

        pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) !void {
            try self.gap.disconnect(conn_handle, reason);
            try self.flushGapCommands();
        }

        pub fn requestDataLength(self: *Self, conn_handle: u16, tx_octets: u16, tx_time: u16) !void {
            try self.gap.requestDataLength(conn_handle, tx_octets, tx_time);
            try self.flushGapCommands();
        }

        pub fn requestPhyUpdate(self: *Self, conn_handle: u16, tx_phys: u8, rx_phys: u8) !void {
            try self.gap.requestPhyUpdate(conn_handle, tx_phys, rx_phys);
            try self.flushGapCommands();
        }

        // ================================================================
        // App API — Data
        // ================================================================

        /// Receive the next GAP event (blocking).
        pub fn nextEvent(self: *Self) ?gap_mod.GapEvent {
            return self.event_queue.recv();
        }

        /// Try to receive a GAP event (non-blocking).
        pub fn tryNextEvent(self: *Self) ?gap_mod.GapEvent {
            return self.event_queue.tryRecv();
        }

        /// Send raw L2CAP data (thread-safe).
        /// Fragments into ACL packets and enqueues to tx_queue.
        /// writeLoop will acquire ACL credits before sending each fragment.
        pub fn sendData(self: *Self, conn_handle: u16, cid: u16, data: []const u8) !void {
            var frag_buf: [acl_mod.LE_MAX_DATA_LEN + l2cap_mod.HEADER_LEN]u8 = undefined;
            var iter = l2cap_mod.fragmentIterator(
                &frag_buf,
                data,
                cid,
                conn_handle,
                self.acl_max_len,
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

        // ================================================================
        // App API — Queries
        // ================================================================

        pub fn getState(self: *const Self) gap_mod.State {
            return self.gap.state;
        }

        pub fn getConnHandle(self: *const Self) ?u16 {
            return self.gap.conn_handle;
        }

        pub fn getAclCredits(self: *Self) u32 {
            return self.acl_credits.getCount();
        }

        pub fn getAclMaxLen(self: *const Self) u16 {
            return self.acl_max_len;
        }

        /// Get the device BD_ADDR (read during start).
        pub fn getBdAddr(self: *const Self) hci_mod.BdAddr {
            return self.bd_addr;
        }

        // ================================================================
        // Internal: synchronous HCI command (used during start())
        // ================================================================

        fn syncCommand(self: *Self, cmd: []const u8) !void {
            _ = try self.syncCommandWithResponse(cmd);
        }

        fn syncCommandWithResponse(self: *Self, cmd: []const u8) !events_mod.CommandComplete {
            _ = self.hci.write(cmd) catch return error.HciError;

            const expected_opcode = @as(u16, cmd[1]) | (@as(u16, cmd[2]) << 8);

            // Wait for matching Command Complete (drain non-matching events)
            var attempts: u32 = 0;
            while (attempts < 50) : (attempts += 1) {
                const ready = self.hci.poll(.{ .readable = true }, 100);
                if (!ready.readable) continue;

                const n = self.hci.read(&self.rx_buf) catch continue;
                if (n < 2 or self.rx_buf[0] != @intFromEnum(hci_mod.PacketType.event)) continue;

                const evt = events_mod.decode(self.rx_buf[1..n]) orelse continue;
                switch (evt) {
                    .command_complete => |cc| {
                        if (cc.opcode == expected_opcode) return cc;
                    },
                    .command_status => |cs| {
                        if (cs.opcode == expected_opcode) {
                            // Command Status is not Command Complete — some commands only return status
                            return error.CommandStatusNotComplete;
                        }
                    },
                    else => {},
                }
            }
            return error.Timeout;
        }

        // ================================================================
        // Internal: flush GAP commands to tx_queue
        // ================================================================

        fn flushGapCommands(self: *Self) !void {
            while (self.gap.nextCommand()) |cmd| {
                self.tx_queue.send(TxPacket.fromSlice(cmd.slice())) catch return error.QueueClosed;
            }
        }

        // ================================================================
        // readLoop
        // ================================================================

        fn readLoopEntry(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.readLoop();
        }

        fn readLoop(self: *Self) void {
            while (!self.cancel.isCancelled()) {
                const ready = self.hci.poll(.{ .readable = true }, 100);
                if (!ready.readable) continue;

                const n = self.hci.read(&self.rx_buf) catch continue;
                if (n == 0) continue;

                const pkt_type: hci_mod.PacketType = @enumFromInt(self.rx_buf[0]);
                const pkt_data = self.rx_buf[1..n];

                switch (pkt_type) {
                    .event => self.handleHciEvent(pkt_data),
                    .acl_data => self.handleAclData(pkt_data),
                    else => {},
                }
            }
        }

        fn handleHciEvent(self: *Self, data: []const u8) void {
            const event = events_mod.decode(data) orelse return;

            switch (event) {
                .num_completed_packets => |ncp| {
                    // HCI flow control: release ACL credits
                    self.handleNcp(ncp);
                    return; // NCP is internal, don't forward to GAP
                },
                else => {},
            }

            // Forward to GAP state machine
            self.gap.handleEvent(event);

            // Flush any commands GAP generated
            self.flushGapCommands() catch {};

            // Deliver GAP events to app
            while (self.gap.pollEvent()) |gap_event| {
                self.event_queue.trySend(gap_event) catch {};
            }
        }

        fn handleNcp(self: *Self, ncp: events_mod.NumCompletedPackets) void {
            var total: u32 = 0;
            var offset: usize = 0;
            var remaining = ncp.num_handles;
            while (remaining > 0 and offset + 4 <= ncp.data.len) : (remaining -= 1) {
                const count = std.mem.readInt(u16, ncp.data[offset + 2 ..][0..2], .little);
                total += count;
                offset += 4;
            }
            if (total > 0) {
                self.acl_credits.release(total);
            }
        }

        fn handleAclData(self: *Self, data: []const u8) void {
            const acl_hdr = acl_mod.parseHeader(data) orelse return;

            const acl_payload_start: usize = acl_mod.HEADER_LEN;
            if (data.len < acl_payload_start + acl_hdr.data_len) return;
            const acl_payload = data[acl_payload_start..][0..acl_hdr.data_len];

            const sdu = self.reassembler.feed(acl_hdr, acl_payload) orelse return;

            switch (sdu.cid) {
                l2cap_mod.CID_ATT => self.handleAttPdu(sdu),
                l2cap_mod.CID_SMP => {},
                l2cap_mod.CID_LE_SIGNALING => {},
                else => {},
            }
        }

        fn handleAttPdu(self: *Self, sdu: l2cap_mod.Sdu) void {
            const response = self.gatt.handlePdu(
                sdu.conn_handle,
                sdu.data,
                &self.att_resp_buf,
            ) orelse return;

            var frag_buf: [acl_mod.LE_MAX_DATA_LEN + l2cap_mod.HEADER_LEN]u8 = undefined;
            var iter = l2cap_mod.fragmentIterator(
                &frag_buf,
                response,
                l2cap_mod.CID_ATT,
                sdu.conn_handle,
                self.acl_max_len,
            );

            while (iter.next()) |frag| {
                self.tx_queue.trySend(TxPacket.fromSlice(frag)) catch {};
            }
        }

        // ================================================================
        // writeLoop — with HCI ACL flow control
        // ================================================================

        fn writeLoopEntry(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.writeLoop();
        }

        fn writeLoop(self: *Self) void {
            while (true) {
                const pkt = self.tx_queue.recv() orelse break;

                // HCI commands (0x01) bypass ACL flow control.
                // Only ACL data packets (0x02) consume credits.
                if (pkt.isAclData()) {
                    if (!self.acl_credits.acquire()) break; // closed = shutdown
                }

                // Wait for HCI writable
                while (!self.cancel.isCancelled()) {
                    const ready = self.hci.poll(.{ .writable = true }, 100);
                    if (ready.writable) break;
                }
                if (self.cancel.isCancelled()) break;

                _ = self.hci.write(pkt.slice()) catch {};
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

// Shared mock HCI for tests
fn MockHci() type {
    return struct {
        const Self = @This();
        const HciError = error{ WouldBlock, HciError };

        const PollFlags = packed struct {
            readable: bool = false,
            writable: bool = false,
            _padding: u6 = 0,
        };

        written_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        rx_queue: [16][64]u8 = undefined,
        rx_lens: [16]usize = [_]usize{0} ** 16,
        rx_head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        rx_tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn read(self: *Self, buf: []u8) HciError!usize {
            const head = self.rx_head.load(.acquire);
            const tail = self.rx_tail.load(.acquire);
            if (head == tail) return error.WouldBlock;

            const idx = tail % 16;
            const n = @min(buf.len, self.rx_lens[idx]);
            @memcpy(buf[0..n], self.rx_queue[idx][0..n]);
            self.rx_tail.store(tail + 1, .release);
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) HciError!usize {
            _ = self.written_count.fetchAdd(1, .acq_rel);
            return buf.len;
        }

        pub fn poll(self: *Self, flags: PollFlags, _: i32) PollFlags {
            return .{
                .readable = flags.readable and (self.rx_head.load(.acquire) != self.rx_tail.load(.acquire)),
                .writable = flags.writable,
            };
        }

        pub fn injectPacket(self: *Self, data: []const u8) void {
            const head = self.rx_head.load(.acquire);
            const idx = head % 16;
            @memcpy(self.rx_queue[idx][0..data.len], data);
            self.rx_lens[idx] = data.len;
            self.rx_head.store(head + 1, .release);
        }

        /// Inject full init sequence responses
        pub fn injectInitSequence(self: *Self) void {
            // 1. HCI Reset Command Complete
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00,
            });
            // 2. LE Read Buffer Size Command Complete (ACL_len=251, num=12)
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E, 0x07, 0x01, 0x02, 0x20, 0x00,
                0xFB, 0x00, 12,
            });
            // 3. Read BD_ADDR Command Complete (addr = 98:88:E0:11:5C:52)
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E, 0x0A, 0x01, 0x09, 0x10, 0x00, // CC for 0x1009, status=0
                0x52, 0x5C, 0x11, 0xE0, 0x88, 0x98, // BD_ADDR (little-endian)
            });
            // 4. Set Event Mask CC
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E, 0x04, 0x01, 0x01, 0x0C, 0x00,
            });
            // 5. LE Set Event Mask CC
            self.injectPacket(&[_]u8{
                @intFromEnum(hci_mod.PacketType.event),
                0x0E, 0x04, 0x01, 0x01, 0x20, 0x00,
            });
        }
    };
}

test "Host start reads buffer size and initializes credits" {
    const TestRt = @import("runtime");
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = Host(TestRt, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Should have read buffer size
    try std.testing.expectEqual(@as(u16, 251), host.acl_max_len);
    try std.testing.expectEqual(@as(u16, 12), host.acl_max_slots);

    // ACL credits should be initialized
    try std.testing.expectEqual(@as(u32, 12), host.getAclCredits());

    // BD_ADDR should be read
    try std.testing.expectEqual(@as(u8, 0x52), host.bd_addr[0]);
    try std.testing.expectEqual(@as(u8, 0x11), host.bd_addr[2]); // server MAC

    // Commands: Reset + Buffer Size + BD_ADDR + Event Mask + LE Event Mask = 5
    try std.testing.expect(hci_driver.written_count.load(.acquire) >= 5);

    host.stop();
}

test "Host writeLoop respects ACL credits" {
    const TestRt = @import("runtime");
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = Host(TestRt, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const written_before = hci_driver.written_count.load(.acquire);

    // Send data — should consume ACL credits via writeLoop
    try host.sendData(0x0040, l2cap_mod.CID_ATT, "test data");

    // Wait for writeLoop to process
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const written_after = hci_driver.written_count.load(.acquire);
    try std.testing.expect(written_after > written_before);

    // Credits should be consumed (started at 12, sent 1 ACL fragment)
    try std.testing.expect(host.getAclCredits() < 12);

    host.stop();
}

test "Host NCP event releases credits" {
    const TestRt = @import("runtime");
    const Mock = MockHci();

    var hci_driver = Mock{};
    hci_driver.injectInitSequence();

    const TestHost = Host(TestRt, Mock, &.{});
    var host = TestHost.init(&hci_driver, std.testing.allocator);
    defer host.deinit();

    try host.start(.{});
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Send enough data to consume some credits
    try host.sendData(0x0040, l2cap_mod.CID_ATT, "test");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const credits_after_send = host.getAclCredits();

    // Inject NCP event: 1 handle, conn_handle=0x0040, count=5
    hci_driver.injectPacket(&[_]u8{
        @intFromEnum(hci_mod.PacketType.event),
        0x13, // Number of Completed Packets
        0x05, // param len
        0x01, // num handles
        0x40, 0x00, // handle
        0x05, 0x00, // count = 5
    });

    // Wait for readLoop to process
    std.Thread.sleep(200 * std.time.ns_per_ms);

    const credits_after_ncp = host.getAclCredits();
    try std.testing.expect(credits_after_ncp > credits_after_send);

    host.stop();
}
