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
    /// LE Enhanced Connection Complete (v2)
    enhanced_connection_complete = 0x0A,
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
    /// Raw report data (variable length, needs further parsing)
    data: []const u8,
};

pub const LeConnectionUpdateComplete = struct {
    status: hci.Status,
    conn_handle: u16,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
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
