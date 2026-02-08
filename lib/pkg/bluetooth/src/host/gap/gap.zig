//! GAP — Generic Access Profile
//!
//! BLE advertising, scanning, and connection state machine.
//! Generates HCI commands and processes HCI events.
//!
//! GAP does not directly perform I/O — it generates command packets
//! and processes event packets. The Host coordinator is responsible
//! for the actual transport.
//!
//! ## State Machine
//!
//! ```
//! ┌──────────┐  startAdvertising()  ┌──────────────┐
//! │  Idle    │ ──────────────────→ │  Advertising  │
//! │          │ ←────────────────── │               │
//! └──────────┘  stopAdvertising()   └──────┬───────┘
//!       │                                  │ LE Connection Complete
//!       │ connect()                        ↓
//!       │         ┌──────────────┐  ┌──────────────┐
//!       └───────→ │  Connecting  │→ │  Connected   │
//!                 └──────────────┘  └──────────────┘
//!                                         │ Disconnection Complete
//!                                         ↓
//!                                   ┌──────────┐
//!                                   │  Idle    │
//!                                   └──────────┘
//! ```

const std = @import("std");
const hci = @import("../hci/hci.zig");
const commands = @import("../hci/commands.zig");
const events = @import("../hci/events.zig");

// ============================================================================
// Types
// ============================================================================

/// GAP state
pub const State = enum {
    idle,
    advertising,
    scanning,
    connecting,
    connected,
};

/// GAP event (delivered to app layer)
pub const GapEvent = union(enum) {
    /// Advertising started successfully
    advertising_started: void,
    /// Advertising stopped
    advertising_stopped: void,
    /// A peer connected to us (peripheral role)
    connected: ConnectionInfo,
    /// A peer disconnected
    disconnected: DisconnectionInfo,
    /// Connection attempt failed
    connection_failed: hci.Status,
};

/// Connection info from LE Connection Complete event
pub const ConnectionInfo = struct {
    conn_handle: u16,
    role: Role,
    peer_addr_type: hci.AddrType,
    peer_addr: hci.BdAddr,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const DisconnectionInfo = struct {
    conn_handle: u16,
    reason: u8,
};

pub const Role = enum(u8) {
    central = 0x00,
    peripheral = 0x01,
};

/// Advertising configuration
pub const AdvConfig = struct {
    /// Advertising interval (units of 0.625ms, range: 0x0020-0x4000)
    interval_min: u16 = 0x0800, // 1.28s
    interval_max: u16 = 0x0800,
    /// Advertising type
    adv_type: commands.AdvType = .adv_ind,
    /// Own address type
    own_addr_type: hci.AddrType = .public,
    /// Advertising data (max 31 bytes)
    adv_data: []const u8 = &.{},
    /// Scan response data (max 31 bytes)
    scan_rsp_data: []const u8 = &.{},
    /// Channel map (bit 0=ch37, bit 1=ch38, bit 2=ch39)
    channel_map: u8 = 0x07,
};

// ============================================================================
// Command Queue Entry
// ============================================================================

/// A pending HCI command to be sent by the Host
pub const PendingCommand = struct {
    data: [commands.MAX_CMD_LEN]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const PendingCommand) []const u8 {
        return self.data[0..self.len];
    }
};

// ============================================================================
// GAP State Machine
// ============================================================================

/// GAP controller — manages advertising/scanning/connection state.
///
/// Does not perform I/O. Instead:
/// - `startAdvertising()` etc. queue HCI commands into `pending_cmds`
/// - `handleEvent()` processes HCI events and updates state
/// - Host coordinator drains `pending_cmds` and calls `handleEvent()`
pub const Gap = struct {
    const Self = @This();
    const MAX_PENDING = 8;

    state: State = .idle,

    /// Active connections (simplified: single connection for now)
    conn_handle: ?u16 = null,
    conn_info: ?ConnectionInfo = null,

    /// Pending HCI commands to be sent
    pending_cmds: [MAX_PENDING]PendingCommand = undefined,
    pending_count: usize = 0,

    /// Pending GAP events to be delivered to app
    pending_events: [MAX_PENDING]GapEvent = undefined,
    event_count: usize = 0,

    pub fn init() Self {
        return .{};
    }

    // ================================================================
    // High-level API (generates HCI commands)
    // ================================================================

    /// Start BLE advertising with the given configuration.
    ///
    /// Queues the following HCI commands:
    /// 1. LE Set Advertising Parameters
    /// 2. LE Set Advertising Data (if provided)
    /// 3. LE Set Scan Response Data (if provided)
    /// 4. LE Set Advertising Enable
    pub fn startAdvertising(self: *Self, config: AdvConfig) !void {
        if (self.state != .idle) return error.InvalidState;

        // 1. Set advertising parameters
        {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetAdvParams(&buf, .{
                .interval_min = config.interval_min,
                .interval_max = config.interval_max,
                .adv_type = config.adv_type,
                .own_addr_type = config.own_addr_type,
                .channel_map = config.channel_map,
            });
            try self.queueCommand(cmd);
        }

        // 2. Set advertising data
        if (config.adv_data.len > 0) {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetAdvData(&buf, config.adv_data);
            try self.queueCommand(cmd);
        }

        // 3. Set scan response data
        if (config.scan_rsp_data.len > 0) {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetScanRspData(&buf, config.scan_rsp_data);
            try self.queueCommand(cmd);
        }

        // 4. Enable advertising
        {
            var buf: [commands.MAX_CMD_LEN]u8 = undefined;
            const cmd = commands.leSetAdvEnable(&buf, true);
            try self.queueCommand(cmd);
        }

        self.state = .advertising;
    }

    /// Stop BLE advertising.
    pub fn stopAdvertising(self: *Self) !void {
        if (self.state != .advertising) return error.InvalidState;

        var buf: [commands.MAX_CMD_LEN]u8 = undefined;
        const cmd = commands.leSetAdvEnable(&buf, false);
        try self.queueCommand(cmd);
        self.state = .idle;
    }

    /// Disconnect an active connection.
    pub fn disconnect(self: *Self, conn_handle: u16, reason: u8) !void {
        if (self.state != .connected) return error.InvalidState;

        var buf: [commands.MAX_CMD_LEN]u8 = undefined;
        const cmd = commands.disconnect(&buf, conn_handle, reason);
        try self.queueCommand(cmd);
    }

    // ================================================================
    // HCI Event Processing
    // ================================================================

    /// Process an HCI event. Updates GAP state and generates GAP events.
    ///
    /// Called by Host coordinator's readLoop.
    pub fn handleEvent(self: *Self, event: events.Event) void {
        switch (event) {
            .command_complete => |cc| self.handleCommandComplete(cc),
            .command_status => |cs| self.handleCommandStatus(cs),
            .disconnection_complete => |dc| self.handleDisconnection(dc),
            .le_connection_complete => |lc| self.handleConnectionComplete(lc),
            else => {}, // Ignore unknown events
        }
    }

    fn handleCommandComplete(self: *Self, cc: events.CommandComplete) void {
        _ = self;
        // Most command completes are just acknowledgements
        if (!cc.status.isSuccess()) {
            std.log.warn("HCI command 0x{X:0>4} failed: {}", .{ cc.opcode, @intFromEnum(cc.status) });
        }
    }

    fn handleCommandStatus(self: *Self, cs: events.CommandStatus) void {
        if (!cs.status.isSuccess()) {
            // Connection attempt failed
            if (cs.opcode == commands.LE_CREATE_CONNECTION) {
                self.state = .idle;
                self.pushEvent(.{ .connection_failed = cs.status });
            }
        }
    }

    fn handleConnectionComplete(self: *Self, lc: events.LeConnectionComplete) void {
        if (!lc.status.isSuccess()) {
            if (self.state == .connecting) {
                self.state = .idle;
                self.pushEvent(.{ .connection_failed = lc.status });
            }
            return;
        }

        const info = ConnectionInfo{
            .conn_handle = lc.conn_handle,
            .role = @enumFromInt(lc.role),
            .peer_addr_type = lc.peer_addr_type,
            .peer_addr = lc.peer_addr,
            .conn_interval = lc.conn_interval,
            .conn_latency = lc.conn_latency,
            .supervision_timeout = lc.supervision_timeout,
        };

        self.conn_handle = lc.conn_handle;
        self.conn_info = info;

        if (self.state == .advertising) {
            // Peripheral: auto-stop advertising on connection
            self.pushEvent(.{ .advertising_stopped = {} });
        }

        self.state = .connected;
        self.pushEvent(.{ .connected = info });
    }

    fn handleDisconnection(self: *Self, dc: events.DisconnectionComplete) void {
        if (!dc.status.isSuccess()) return;

        if (self.conn_handle) |handle| {
            if (handle == dc.conn_handle) {
                self.conn_handle = null;
                self.conn_info = null;
                self.state = .idle;
                self.pushEvent(.{ .disconnected = .{
                    .conn_handle = dc.conn_handle,
                    .reason = dc.reason,
                } });
            }
        }
    }

    // ================================================================
    // Event / Command Queue
    // ================================================================

    /// Poll the next GAP event (for app consumption)
    pub fn pollEvent(self: *Self) ?GapEvent {
        if (self.event_count == 0) return null;
        const event = self.pending_events[0];
        // Shift remaining
        for (0..self.event_count - 1) |i| {
            self.pending_events[i] = self.pending_events[i + 1];
        }
        self.event_count -= 1;
        return event;
    }

    /// Get the next pending HCI command (for Host to send)
    pub fn nextCommand(self: *Self) ?[]const u8 {
        if (self.pending_count == 0) return null;
        const cmd = self.pending_cmds[0].slice();
        // Shift remaining
        for (0..self.pending_count - 1) |i| {
            self.pending_cmds[i] = self.pending_cmds[i + 1];
        }
        self.pending_count -= 1;
        return cmd;
    }

    fn pushEvent(self: *Self, event: GapEvent) void {
        if (self.event_count >= MAX_PENDING) return; // Drop if full
        self.pending_events[self.event_count] = event;
        self.event_count += 1;
    }

    fn queueCommand(self: *Self, cmd: []const u8) !void {
        if (self.pending_count >= MAX_PENDING) return error.CommandQueueFull;
        var entry = PendingCommand{};
        @memcpy(entry.data[0..cmd.len], cmd);
        entry.len = cmd.len;
        self.pending_cmds[self.pending_count] = entry;
        self.pending_count += 1;
    }

};

// ============================================================================
// Tests
// ============================================================================

test "GAP start advertising generates commands" {
    var gap = Gap.init();

    try gap.startAdvertising(.{
        .adv_data = &[_]u8{
            0x02, 0x01, 0x06, // Flags
            0x04, 0x09, 'Z', 'i', 'g', // Name: "Zig"
        },
    });

    try std.testing.expectEqual(State.advertising, gap.state);

    // Should have 3 commands: set params, set adv data, enable
    try std.testing.expectEqual(@as(usize, 3), gap.pending_count);

    // First command: LE Set Advertising Parameters
    const cmd1 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), cmd1[0]); // command indicator

    // Second: LE Set Advertising Data
    const cmd2 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), cmd2[0]);

    // Third: LE Set Advertising Enable
    const cmd3 = gap.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), cmd3[0]);

    // No more
    try std.testing.expect(gap.nextCommand() == null);
}

test "GAP handle LE Connection Complete" {
    var gap = Gap.init();

    try gap.startAdvertising(.{});
    // Drain commands
    while (gap.nextCommand()) |_| {}

    try std.testing.expectEqual(State.advertising, gap.state);

    // Simulate LE Connection Complete event
    gap.handleEvent(.{ .le_connection_complete = .{
        .status = .success,
        .conn_handle = 0x0040,
        .role = 0x01, // peripheral
        .peer_addr_type = .random,
        .peer_addr = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 },
        .conn_interval = 0x0018,
        .conn_latency = 0,
        .supervision_timeout = 0x00C8,
    } });

    try std.testing.expectEqual(State.connected, gap.state);
    try std.testing.expectEqual(@as(?u16, 0x0040), gap.conn_handle);

    // Should have 2 events: advertising_stopped + connected
    const evt1 = gap.pollEvent() orelse unreachable;
    try std.testing.expect(std.meta.activeTag(evt1) == .advertising_stopped);

    const evt2 = gap.pollEvent() orelse unreachable;
    switch (evt2) {
        .connected => |info| {
            try std.testing.expectEqual(@as(u16, 0x0040), info.conn_handle);
            try std.testing.expectEqual(Role.peripheral, info.role);
        },
        else => unreachable,
    }
}

test "GAP handle Disconnection Complete" {
    var gap = Gap.init();

    // Force into connected state
    gap.state = .connected;
    gap.conn_handle = 0x0040;

    // Simulate disconnection
    gap.handleEvent(.{ .disconnection_complete = .{
        .status = .success,
        .conn_handle = 0x0040,
        .reason = 0x13, // Remote User Terminated
    } });

    try std.testing.expectEqual(State.idle, gap.state);
    try std.testing.expect(gap.conn_handle == null);

    const evt = gap.pollEvent() orelse unreachable;
    switch (evt) {
        .disconnected => |info| {
            try std.testing.expectEqual(@as(u16, 0x0040), info.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x13), info.reason);
        },
        else => unreachable,
    }
}

test "GAP state validation" {
    var gap = Gap.init();

    // Can't stop advertising if not advertising
    try std.testing.expectError(error.InvalidState, gap.stopAdvertising());

    // Can't disconnect if not connected
    try std.testing.expectError(error.InvalidState, gap.disconnect(0, 0x13));

    // Can't start advertising while connected
    gap.state = .connected;
    try std.testing.expectError(error.InvalidState, gap.startAdvertising(.{}));
}
