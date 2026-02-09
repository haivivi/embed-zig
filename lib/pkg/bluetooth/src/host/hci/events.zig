//! HCI Event Decoding
//!
//! Decode HCI events received from the controller.
//! Pure data parsing — no I/O, no state.
//!
//! ## Event Packet Format (BT Core Spec Vol 4, Part E, Section 7.7)
//!
//! ```
//! [0x04][Event_Code][Param_Len][Parameters...]
//! ```

const std = @import("std");
const hci = @import("hci.zig");

// ============================================================================
// Event Codes
// ============================================================================

pub const EventCode = enum(u8) {
    /// Disconnection Complete
    disconnection_complete = 0x05,
    /// Command Complete
    command_complete = 0x0E,
    /// Command Status
    command_status = 0x0F,
    /// Hardware Error
    hardware_error = 0x10,
    /// Number of Completed Packets
    num_completed_packets = 0x13,
    /// LE Meta Event (contains sub-event code)
    le_meta = 0x3E,
    _,
};

/// LE Sub-event codes (inside LE Meta Event)
pub const LeSubevent = enum(u8) {
    /// LE Connection Complete
    connection_complete = 0x01,
    /// LE Advertising Report
    advertising_report = 0x02,
    /// LE Connection Update Complete
    connection_update_complete = 0x03,
    /// LE Read Remote Features Complete
    read_remote_features_complete = 0x04,
    /// LE Long Term Key Request
    long_term_key_request = 0x05,
    /// LE Data Length Change
    data_length_change = 0x07,
    /// LE Enhanced Connection Complete (v2)
    enhanced_connection_complete = 0x0A,
    /// LE PHY Update Complete
    phy_update_complete = 0x0C,
    _,
};

// ============================================================================
// Decoded Event Types
// ============================================================================

/// Decoded HCI event
pub const Event = union(enum) {
    /// Command Complete: controller finished processing a command
    command_complete: CommandComplete,
    /// Command Status: controller acknowledged a command
    command_status: CommandStatus,
    /// Disconnection Complete
    disconnection_complete: DisconnectionComplete,
    /// Number of Completed Packets (flow control)
    num_completed_packets: NumCompletedPackets,
    /// LE Connection Complete
    le_connection_complete: LeConnectionComplete,
    /// LE Advertising Report
    le_advertising_report: LeAdvertisingReport,
    /// LE Connection Update Complete
    le_connection_update_complete: LeConnectionUpdateComplete,
    /// LE Data Length Change
    le_data_length_change: LeDataLengthChange,
    /// LE PHY Update Complete
    le_phy_update_complete: LePhyUpdateComplete,
    /// Unknown or unsupported event
    unknown: UnknownEvent,
};

pub const CommandComplete = struct {
    num_cmd_packets: u8,
    opcode: u16,
    status: hci.Status,
    /// Return parameters (after status byte)
    return_params: []const u8,
};

pub const CommandStatus = struct {
    status: hci.Status,
    num_cmd_packets: u8,
    opcode: u16,
};

pub const DisconnectionComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    reason: u8,
};

pub const NumCompletedPackets = struct {
    num_handles: u8,
    /// Raw parameter data: [handle_lo, handle_hi, count_lo, count_hi] * num_handles
    data: []const u8,
};

pub const LeConnectionComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    role: u8,
    peer_addr_type: hci.AddrType,
    peer_addr: hci.BdAddr,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const LeAdvertisingReport = struct {
    num_reports: u8,
    /// Raw report data (variable length, parse with parseAdvReport)
    data: []const u8,
};

/// Parsed single advertising report
pub const AdvReport = struct {
    /// Event type: 0=ADV_IND, 1=ADV_DIRECT_IND, 2=ADV_SCAN_IND, 3=ADV_NONCONN_IND, 4=SCAN_RSP
    event_type: u8,
    /// Advertiser address type
    addr_type: hci.AddrType,
    /// Advertiser address
    addr: hci.BdAddr,
    /// AD structures data
    data: []const u8,
    /// RSSI in dBm (127 = not available)
    rssi: i8,
};

/// Parse the first advertising report from raw LE Advertising Report data.
///
/// Input: raw data after num_reports byte. Format per report:
/// [event_type(1)][addr_type(1)][addr(6)][data_len(1)][data(N)][rssi(1)]
pub fn parseAdvReport(raw: []const u8) ?AdvReport {
    if (raw.len < 10) return null; // minimum: 1+1+6+1+0+1 = 10
    const event_type = raw[0];
    const addr_type: hci.AddrType = @enumFromInt(raw[1]);
    const addr: hci.BdAddr = raw[2..8].*;
    const data_len: usize = raw[8];
    if (raw.len < 9 + data_len + 1) return null;
    const data = raw[9..][0..data_len];
    const rssi: i8 = @bitCast(raw[9 + data_len]);
    return .{
        .event_type = event_type,
        .addr_type = addr_type,
        .addr = addr,
        .data = data,
        .rssi = rssi,
    };
}

pub const LeConnectionUpdateComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const LeDataLengthChange = struct {
    conn_handle: u16,
    max_tx_octets: u16,
    max_tx_time: u16,
    max_rx_octets: u16,
    max_rx_time: u16,
};

pub const LePhyUpdateComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    /// TX PHY: 1=1M, 2=2M, 3=Coded
    tx_phy: u8,
    /// RX PHY: 1=1M, 2=2M, 3=Coded
    rx_phy: u8,
};

pub const UnknownEvent = struct {
    event_code: u8,
    params: []const u8,
};

// ============================================================================
// Decoding
// ============================================================================

/// Decode an HCI event from raw bytes.
///
/// Input `data` should start with the event code (byte after 0x04 indicator).
/// That is: data = [Event_Code][Param_Len][Parameters...]
///
/// Returns null if the data is too short to parse.
pub fn decode(data: []const u8) ?Event {
    if (data.len < 2) return null;

    const event_code: EventCode = @enumFromInt(data[0]);
    const param_len = data[1];

    if (data.len < @as(usize, 2) + param_len) return null;
    const params = data[2..][0..param_len];

    return switch (event_code) {
        .command_complete => decodeCommandComplete(params),
        .command_status => decodeCommandStatus(params),
        .disconnection_complete => decodeDisconnectionComplete(params),
        .num_completed_packets => decodeNumCompletedPackets(params),
        .le_meta => decodeLeMetaEvent(params),
        else => .{ .unknown = .{
            .event_code = data[0],
            .params = params,
        } },
    };
}

fn decodeCommandComplete(params: []const u8) ?Event {
    if (params.len < 4) return null;
    return .{ .command_complete = .{
        .num_cmd_packets = params[0],
        .opcode = std.mem.readInt(u16, params[1..3], .little),
        .status = @enumFromInt(params[3]),
        .return_params = if (params.len > 4) params[4..] else &.{},
    } };
}

fn decodeCommandStatus(params: []const u8) ?Event {
    if (params.len < 4) return null;
    return .{ .command_status = .{
        .status = @enumFromInt(params[0]),
        .num_cmd_packets = params[1],
        .opcode = std.mem.readInt(u16, params[2..4], .little),
    } };
}

fn decodeDisconnectionComplete(params: []const u8) ?Event {
    if (params.len < 4) return null;
    return .{ .disconnection_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .reason = params[3],
    } };
}

fn decodeNumCompletedPackets(params: []const u8) ?Event {
    if (params.len < 1) return null;
    return .{ .num_completed_packets = .{
        .num_handles = params[0],
        .data = if (params.len > 1) params[1..] else &.{},
    } };
}

fn decodeLeMetaEvent(params: []const u8) ?Event {
    if (params.len < 1) return null;

    const sub: LeSubevent = @enumFromInt(params[0]);
    const sub_params = if (params.len > 1) params[1..] else &[_]u8{};

    return switch (sub) {
        .connection_complete => decodeLeConnectionComplete(sub_params),
        .advertising_report => .{ .le_advertising_report = .{
            .num_reports = if (sub_params.len > 0) sub_params[0] else 0,
            .data = if (sub_params.len > 1) sub_params[1..] else &.{},
        } },
        .connection_update_complete => decodeLeConnectionUpdateComplete(sub_params),
        .data_length_change => decodeLeDataLengthChange(sub_params),
        .phy_update_complete => decodeLePhyUpdateComplete(sub_params),
        else => .{ .unknown = .{
            .event_code = @intFromEnum(EventCode.le_meta),
            .params = params,
        } },
    };
}

fn decodeLeConnectionComplete(params: []const u8) ?Event {
    if (params.len < 18) return null;
    return .{ .le_connection_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .role = params[3],
        .peer_addr_type = @enumFromInt(params[4]),
        .peer_addr = params[5..11].*,
        .conn_interval = std.mem.readInt(u16, params[11..13], .little),
        .conn_latency = std.mem.readInt(u16, params[13..15], .little),
        .supervision_timeout = std.mem.readInt(u16, params[15..17], .little),
    } };
}

fn decodeLeConnectionUpdateComplete(params: []const u8) ?Event {
    if (params.len < 9) return null;
    return .{ .le_connection_update_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .conn_interval = std.mem.readInt(u16, params[3..5], .little),
        .conn_latency = std.mem.readInt(u16, params[5..7], .little),
        .supervision_timeout = std.mem.readInt(u16, params[7..9], .little),
    } };
}

fn decodeLeDataLengthChange(params: []const u8) ?Event {
    if (params.len < 10) return null;
    return .{ .le_data_length_change = .{
        .conn_handle = std.mem.readInt(u16, params[0..2], .little) & 0x0FFF,
        .max_tx_octets = std.mem.readInt(u16, params[2..4], .little),
        .max_tx_time = std.mem.readInt(u16, params[4..6], .little),
        .max_rx_octets = std.mem.readInt(u16, params[6..8], .little),
        .max_rx_time = std.mem.readInt(u16, params[8..10], .little),
    } };
}

fn decodeLePhyUpdateComplete(params: []const u8) ?Event {
    if (params.len < 5) return null;
    return .{ .le_phy_update_complete = .{
        .status = @enumFromInt(params[0]),
        .conn_handle = std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .tx_phy = params[3],
        .rx_phy = params[4],
    } };
}

// ============================================================================
// Tests
// ============================================================================

test "decode Command Complete for HCI_Reset" {
    // Event: Command Complete, Status: Success, OpCode: HCI_Reset
    const raw = [_]u8{
        0x0E, // Event Code: Command Complete
        0x04, // Parameter Length
        0x01, // Num_HCI_Command_Packets
        0x03, 0x0C, // OpCode: HCI_Reset (0x0C03)
        0x00, // Status: Success
    };

    const evt = decode(&raw) orelse unreachable;
    switch (evt) {
        .command_complete => |cc| {
            try std.testing.expectEqual(@as(u8, 0x01), cc.num_cmd_packets);
            try std.testing.expectEqual(@as(u16, 0x0C03), cc.opcode);
            try std.testing.expect(cc.status.isSuccess());
        },
        else => unreachable,
    }
}

test "decode Command Status" {
    const raw = [_]u8{
        0x0F, // Event Code: Command Status
        0x04, // Parameter Length
        0x00, // Status: Success (pending)
        0x01, // Num_HCI_Command_Packets
        0x0D, 0x20, // OpCode: LE_Create_Connection (0x200D)
    };

    const evt = decode(&raw) orelse unreachable;
    switch (evt) {
        .command_status => |cs| {
            try std.testing.expect(cs.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x200D), cs.opcode);
        },
        else => unreachable,
    }
}

test "decode LE Connection Complete" {
    const raw = [_]u8{
        0x3E, // Event Code: LE Meta
        0x13, // Parameter Length: 19
        0x01, // Sub-event: Connection Complete
        0x00, // Status: Success
        0x40, 0x00, // Connection Handle: 0x0040
        0x01, // Role: Peripheral
        0x01, // Peer Address Type: Random
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, // Peer Address
        0x18, 0x00, // Connection Interval: 30ms
        0x00, 0x00, // Connection Latency: 0
        0xC8, 0x00, // Supervision Timeout: 2000ms
        0x00, // Master Clock Accuracy
    };

    const evt = decode(&raw) orelse unreachable;
    switch (evt) {
        .le_connection_complete => |lc| {
            try std.testing.expect(lc.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x0040), lc.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x01), lc.role);
            try std.testing.expectEqual(hci.AddrType.random, lc.peer_addr_type);
            try std.testing.expectEqual(@as(u16, 0x0018), lc.conn_interval);
        },
        else => unreachable,
    }
}

test "decode LE Data Length Change" {
    const raw = [_]u8{
        0x3E, // LE Meta
        0x0B, // Param len: 11
        0x07, // Sub-event: Data Length Change
        0x40, 0x00, // Connection Handle: 0x0040
        0xFB, 0x00, // Max TX Octets: 251
        0x48, 0x08, // Max TX Time: 2120
        0xFB, 0x00, // Max RX Octets: 251
        0x48, 0x08, // Max RX Time: 2120
    };

    const evt = decode(&raw) orelse unreachable;
    switch (evt) {
        .le_data_length_change => |dl| {
            try std.testing.expectEqual(@as(u16, 0x0040), dl.conn_handle);
            try std.testing.expectEqual(@as(u16, 251), dl.max_tx_octets);
            try std.testing.expectEqual(@as(u16, 2120), dl.max_tx_time);
            try std.testing.expectEqual(@as(u16, 251), dl.max_rx_octets);
        },
        else => unreachable,
    }
}

test "decode LE PHY Update Complete" {
    const raw = [_]u8{
        0x3E, // LE Meta
        0x06, // Param len: 6
        0x0C, // Sub-event: PHY Update Complete
        0x00, // Status: Success
        0x40, 0x00, // Connection Handle: 0x0040
        0x02, // TX PHY: 2M
        0x02, // RX PHY: 2M
    };

    const evt = decode(&raw) orelse unreachable;
    switch (evt) {
        .le_phy_update_complete => |pu| {
            try std.testing.expect(pu.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x0040), pu.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x02), pu.tx_phy);
            try std.testing.expectEqual(@as(u8, 0x02), pu.rx_phy);
        },
        else => unreachable,
    }
}

test "parse Advertising Report" {
    // Single ADV_IND report from a device advertising "ZigBLE"
    const raw = [_]u8{
        0x00, // Event type: ADV_IND
        0x00, // Addr type: Public
        0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98, // Address (little-endian)
        0x0B, // Data length: 11
        // AD structures: Flags + Complete Local Name
        0x02, 0x01, 0x06, // Flags (3 bytes)
        0x07, 0x09, 'Z', 'i', 'g', 'B', 'L', 'E', // Name: "ZigBLE" (8 bytes)
        0xC0, // RSSI: -64 dBm
    };

    const report = parseAdvReport(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x00), report.event_type);
    try std.testing.expectEqual(hci.AddrType.public, report.addr_type);
    try std.testing.expectEqual(@as(u8, 0x50), report.addr[0]);
    try std.testing.expectEqual(@as(usize, 11), report.data.len);
    try std.testing.expectEqual(@as(i8, -64), report.rssi);
}

test "decode unknown event" {
    const raw = [_]u8{
        0xFF, // Unknown event code
        0x02, // Parameter Length
        0xAA, 0xBB,
    };

    const evt = decode(&raw) orelse unreachable;
    switch (evt) {
        .unknown => |u| {
            try std.testing.expectEqual(@as(u8, 0xFF), u.event_code);
            try std.testing.expectEqual(@as(usize, 2), u.params.len);
        },
        else => unreachable,
    }
}
