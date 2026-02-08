//! BLE Host Coordinator
//!
//! The "server" — owns loops, queues, state, and dispatch.
//! Bridges the HCI transport (fd) with the protocol layers (L2CAP, ATT, GAP).
//!
//! ## Architecture
//!
//! ```
//! Host
//! ├── readLoop (poll + read from HCI → dispatch)
//! │   ├── Event packets → GAP state machine
//! │   └── ACL packets → L2CAP reassembly → ATT → GATT dispatch
//! ├── writeLoop (drain tx_queue → write to HCI)
//! │   ├── HCI commands (from GAP)
//! │   └── ACL data (from ATT/GATT, post L2CAP fragmentation)
//! ├── tx_queue: Channel — post-fragmentation HCI packets
//! ├── cancel: CancellationToken — shutdown signal
//! ├── gap: Gap — advertising/connection state machine
//! ├── gatt: GattServer — attribute database + handler dispatch
//! └── l2cap: Reassembler — fragment reassembly
//! ```
//!
//! ## Lifecycle
//!
//! ```zig
//! var host = Host(Rt, HciDriver, 16).init(&hci_driver);
//! // Register GATT services...
//! host.gatt.addService(...);
//! host.gatt.addCharacteristic(...);
//! // Start host (spawns readLoop + writeLoop)
//! try host.start();
//! // ... app runs ...
//! host.stop(); // cancel + wait
//! ```

const std = @import("std");
const hci_mod = @import("hci/hci.zig");
const acl_mod = @import("hci/acl.zig");
const commands = @import("hci/commands.zig");
const events_mod = @import("hci/events.zig");
const l2cap_mod = @import("l2cap/l2cap.zig");
const att_mod = @import("att/att.zig");
const gap_mod = @import("gap/gap.zig");
const gatt_server = @import("../gatt_server.zig");

// ============================================================================
// Host
// ============================================================================

/// BLE Host coordinator.
///
/// Generic over:
/// - `HciTransport`: the HCI driver type (must have read/write/poll)
/// - `max_services`: max GATT services
///
/// The Host does NOT depend on a Runtime type — it runs in a single
/// thread with a poll-based event loop. The caller (or a wrapper)
/// can spawn it in a background task if needed.
pub fn Host(comptime HciTransport: type, comptime max_services: usize) type {
    return struct {
        const Self = @This();

        /// HCI transport driver
        hci: *HciTransport,

        /// GAP state machine
        gap: gap_mod.Gap = gap_mod.Gap.init(),

        /// GATT server
        gatt: gatt_server.GattServer(max_services) = gatt_server.GattServer(max_services).init(),

        /// L2CAP reassembler (single connection for now)
        reassembler: l2cap_mod.Reassembler = .{},

        /// Running flag
        running: bool = false,

        /// Read buffer
        rx_buf: [512]u8 = undefined,

        /// ATT response buffer
        att_resp_buf: [att_mod.MAX_PDU_LEN]u8 = undefined,

        /// L2CAP fragment buffer
        l2cap_frag_buf: [acl_mod.LE_MAX_DATA_LEN + l2cap_mod.HEADER_LEN]u8 = undefined,

        /// Initialize the Host with an HCI transport driver.
        pub fn init(hci: *HciTransport) Self {
            return .{ .hci = hci };
        }

        // ================================================================
        // Lifecycle
        // ================================================================

        /// Start the Host.
        ///
        /// Sends HCI Reset and initializes the controller.
        /// After this, call `poll()` in a loop to process events.
        pub fn start(self: *Self) !void {
            // Send HCI Reset
            var cmd_buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const reset_cmd = commands.reset(&cmd_buf);
            _ = self.hci.write(reset_cmd) catch return error.HciError;

            // Wait for Command Complete
            const ready = self.hci.poll(.{ .readable = true }, 1000);
            if (ready.readable) {
                const n = self.hci.read(&self.rx_buf) catch 0;
                if (n > 1 and self.rx_buf[0] == @intFromEnum(hci_mod.PacketType.event)) {
                    // Parse and handle the reset response
                    if (events_mod.decode(self.rx_buf[1..n])) |evt| {
                        self.gap.handleEvent(evt);
                    }
                }
            }

            self.running = true;
        }

        /// Stop the Host.
        pub fn stop(self: *Self) void {
            self.running = false;
        }

        // ================================================================
        // Event Loop (poll-based, single-threaded)
        // ================================================================

        /// Process one iteration of the event loop.
        ///
        /// 1. Drain GAP pending commands → HCI write
        /// 2. Poll HCI for readable → process incoming packets
        /// 3. Return any GAP events
        ///
        /// Call this in a loop from the app or from a spawned task.
        ///
        /// `timeout_ms`:
        /// -  0 — non-blocking
        /// - >0 — wait up to timeout_ms for HCI data
        /// - -1 — block until data arrives
        pub fn poll(self: *Self, timeout_ms: i32) ?gap_mod.GapEvent {
            if (!self.running) return null;

            // 1. Send pending GAP commands
            self.drainGapCommands();

            // 2. Process incoming HCI packets
            self.processIncoming(timeout_ms);

            // 3. Return next GAP event (if any)
            return self.gap.pollEvent();
        }

        // ================================================================
        // Internal: TX path
        // ================================================================

        fn drainGapCommands(self: *Self) void {
            while (self.gap.nextCommand()) |cmd| {
                // Wait until HCI is writable
                const ready = self.hci.poll(.{ .writable = true }, 100);
                if (ready.writable) {
                    _ = self.hci.write(cmd) catch {};
                }
            }
        }

        /// Send L2CAP data (called by GATT response path)
        fn sendL2capData(self: *Self, conn_handle: u16, cid: u16, data: []const u8) void {
            var iter = l2cap_mod.fragmentIterator(
                &self.l2cap_frag_buf,
                data,
                cid,
                conn_handle,
                acl_mod.LE_DEFAULT_DATA_LEN,
            );

            while (iter.next()) |frag| {
                const ready = self.hci.poll(.{ .writable = true }, 100);
                if (ready.writable) {
                    _ = self.hci.write(frag) catch {};
                }
            }
        }

        // ================================================================
        // Internal: RX path
        // ================================================================

        fn processIncoming(self: *Self, timeout_ms: i32) void {
            const ready = self.hci.poll(.{ .readable = true }, timeout_ms);
            if (!ready.readable) return;

            const n = self.hci.read(&self.rx_buf) catch return;
            if (n == 0) return;

            const pkt_type: hci_mod.PacketType = @enumFromInt(self.rx_buf[0]);
            const pkt_data = self.rx_buf[1..n];

            switch (pkt_type) {
                .event => self.handleHciEvent(pkt_data),
                .acl_data => self.handleAclData(pkt_data),
                else => {}, // Ignore sync/ISO for now
            }
        }

        fn handleHciEvent(self: *Self, data: []const u8) void {
            const event = events_mod.decode(data) orelse return;
            self.gap.handleEvent(event);
        }

        fn handleAclData(self: *Self, data: []const u8) void {
            const acl_hdr = acl_mod.parseHeader(data) orelse return;

            const acl_payload_start: usize = acl_mod.HEADER_LEN;
            if (data.len < acl_payload_start + acl_hdr.data_len) return;
            const acl_payload = data[acl_payload_start..][0..acl_hdr.data_len];

            // Feed to L2CAP reassembler
            const sdu = self.reassembler.feed(acl_hdr, acl_payload) orelse return;

            // Dispatch by CID
            switch (sdu.cid) {
                l2cap_mod.CID_ATT => self.handleAttPdu(sdu),
                l2cap_mod.CID_SMP => {}, // SMP: future
                l2cap_mod.CID_LE_SIGNALING => {}, // L2CAP signaling: future
                else => {},
            }
        }

        fn handleAttPdu(self: *Self, sdu: l2cap_mod.Sdu) void {
            const response = self.gatt.handlePdu(
                sdu.conn_handle,
                sdu.data,
                &self.att_resp_buf,
            ) orelse return; // No response needed (write command, confirmation)

            // Send ATT response via L2CAP
            self.sendL2capData(sdu.conn_handle, l2cap_mod.CID_ATT, response);
        }

        // ================================================================
        // High-level API (delegates to GAP/GATT)
        // ================================================================

        /// Start BLE advertising.
        pub fn startAdvertising(self: *Self, config: gap_mod.AdvConfig) !void {
            try self.gap.startAdvertising(config);
            // Immediately drain commands
            self.drainGapCommands();
        }

        /// Stop BLE advertising.
        pub fn stopAdvertising(self: *Self) !void {
            try self.gap.stopAdvertising();
            self.drainGapCommands();
        }

        /// Disconnect from a peer.
        pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) !void {
            try self.gap.disconnect(conn_handle, reason);
            self.drainGapCommands();
        }

        /// Send a GATT notification to a connected peer.
        pub fn notify(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void {
            var buf: [att_mod.MAX_PDU_LEN]u8 = undefined;
            const pdu = att_mod.encodeNotification(&buf, attr_handle, value);
            self.sendL2capData(conn_handle, l2cap_mod.CID_ATT, pdu);
        }

        /// Send a GATT indication to a connected peer.
        pub fn indicate(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8) void {
            var buf: [att_mod.MAX_PDU_LEN]u8 = undefined;
            const pdu = att_mod.encodeIndication(&buf, attr_handle, value);
            self.sendL2capData(conn_handle, l2cap_mod.CID_ATT, pdu);
        }

        /// Get the current GAP state.
        pub fn getState(self: *const Self) gap_mod.State {
            return self.gap.state;
        }

        /// Get the active connection handle (if connected).
        pub fn getConnHandle(self: *const Self) ?u16 {
            return self.gap.conn_handle;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Host init and basic lifecycle" {
    // Mock HCI driver (self-contained, no hal dependency)
    const MockHci = struct {
        const Self = @This();
        const HciError = error{ WouldBlock, HciError };

        const PollFlags = packed struct {
            readable: bool = false,
            writable: bool = false,
            _padding: u6 = 0,
        };

        written: [512]u8 = undefined,
        written_len: usize = 0,
        rx_data: [512]u8 = undefined,
        rx_len: usize = 0,
        readable: bool = false,

        pub fn read(self: *Self, buf: []u8) HciError!usize {
            if (!self.readable) return error.WouldBlock;
            const n = @min(buf.len, self.rx_len);
            @memcpy(buf[0..n], self.rx_data[0..n]);
            self.rx_len = 0;
            self.readable = false;
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) HciError!usize {
            const n = @min(buf.len, self.written.len - self.written_len);
            @memcpy(self.written[self.written_len..][0..n], buf[0..n]);
            self.written_len += n;
            return n;
        }

        pub fn poll(self: *Self, flags: PollFlags, _: i32) PollFlags {
            return .{
                .readable = flags.readable and self.readable,
                .writable = flags.writable,
            };
        }
    };

    var hci_driver = MockHci{};

    // Prepare a Command Complete response for HCI Reset
    const reset_response = [_]u8{
        @intFromEnum(hci_mod.PacketType.event), // indicator
        0x0E, // Command Complete
        0x04, // param len
        0x01, // num packets
        0x03, 0x0C, // opcode: HCI_Reset
        0x00, // status: success
    };
    @memcpy(hci_driver.rx_data[0..reset_response.len], &reset_response);
    hci_driver.rx_len = reset_response.len;
    hci_driver.readable = true;

    const TestHost = Host(MockHci, 4);
    var host = TestHost.init(&hci_driver);
    try host.start();

    try std.testing.expect(host.running);

    // The HCI Reset command should have been written
    try std.testing.expect(hci_driver.written_len > 0);
    try std.testing.expectEqual(@as(u8, 0x01), hci_driver.written[0]); // command indicator

    host.stop();
    try std.testing.expect(!host.running);
}
