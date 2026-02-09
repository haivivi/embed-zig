//! HCI Command Encoding
//!
//! Encodes HCI commands as byte arrays ready for transport.
//! Each command includes the packet indicator (0x01) and follows
//! BT Core Spec Vol 4, Part E, Section 7.
//!
//! ## Packet Format
//!
//! ```
//! [0x01][OpCode_Lo][OpCode_Hi][Param_Len][Parameters...]
//! ```
//!
//! OpCode = (OGF << 10) | OCF

const std = @import("std");
const hci = @import("hci.zig");

// ============================================================================
// OpCode Construction
// ============================================================================

/// Build HCI opcode from OGF and OCF
pub fn opcode(ogf: u6, ocf: u10) u16 {
    return (@as(u16, ogf) << 10) | @as(u16, ocf);
}

// ============================================================================
// OGF Groups (BT Core Spec Vol 4, Part E, Section 7)
// ============================================================================

/// Link Control commands (OGF 0x01)
pub const OGF_LINK_CONTROL: u6 = 0x01;
/// Controller & Baseband commands (OGF 0x03)
pub const OGF_CONTROLLER: u6 = 0x03;
/// Informational Parameters (OGF 0x04)
pub const OGF_INFO: u6 = 0x04;
/// LE Controller commands (OGF 0x08)
pub const OGF_LE: u6 = 0x08;

// ============================================================================
// Common OpCodes
// ============================================================================

/// HCI_Disconnect (OGF 0x01, OCF 0x006)
pub const DISCONNECT = opcode(OGF_LINK_CONTROL, 0x006);
/// HCI_Reset (OGF 0x03, OCF 0x003)
pub const RESET = opcode(OGF_CONTROLLER, 0x003);
/// HCI_Set_Event_Mask (OGF 0x03, OCF 0x001)
pub const SET_EVENT_MASK = opcode(OGF_CONTROLLER, 0x001);
/// HCI_Read_Local_Version_Information (OGF 0x04, OCF 0x001)
pub const READ_LOCAL_VERSION = opcode(OGF_INFO, 0x001);
/// HCI_Read_BD_ADDR (OGF 0x04, OCF 0x009)
pub const READ_BD_ADDR = opcode(OGF_INFO, 0x009);

// ============================================================================
// LE OpCodes (OGF 0x08)
// ============================================================================

/// HCI_LE_Set_Event_Mask (OCF 0x001)
pub const LE_SET_EVENT_MASK = opcode(OGF_LE, 0x001);
/// HCI_LE_Read_Buffer_Size_V1 (OCF 0x002)
pub const LE_READ_BUFFER_SIZE = opcode(OGF_LE, 0x002);
/// HCI_LE_Set_Random_Address (OCF 0x005)
pub const LE_SET_RANDOM_ADDR = opcode(OGF_LE, 0x005);
/// HCI_LE_Set_Advertising_Parameters (OCF 0x006)
pub const LE_SET_ADV_PARAMS = opcode(OGF_LE, 0x006);
/// HCI_LE_Set_Advertising_Data (OCF 0x008)
pub const LE_SET_ADV_DATA = opcode(OGF_LE, 0x008);
/// HCI_LE_Set_Scan_Response_Data (OCF 0x009)
pub const LE_SET_SCAN_RSP_DATA = opcode(OGF_LE, 0x009);
/// HCI_LE_Set_Advertising_Enable (OCF 0x00A)
pub const LE_SET_ADV_ENABLE = opcode(OGF_LE, 0x00A);
/// HCI_LE_Set_Scan_Parameters (OCF 0x00B)
pub const LE_SET_SCAN_PARAMS = opcode(OGF_LE, 0x00B);
/// HCI_LE_Set_Scan_Enable (OCF 0x00C)
pub const LE_SET_SCAN_ENABLE = opcode(OGF_LE, 0x00C);
/// HCI_LE_Create_Connection (OCF 0x00D)
pub const LE_CREATE_CONNECTION = opcode(OGF_LE, 0x00D);
/// HCI_LE_Create_Connection_Cancel (OCF 0x00E)
pub const LE_CREATE_CONNECTION_CANCEL = opcode(OGF_LE, 0x00E);
/// HCI_LE_Set_Data_Length (OCF 0x022)
pub const LE_SET_DATA_LENGTH = opcode(OGF_LE, 0x022);
/// HCI_LE_Read_Default_Data_Length (OCF 0x023)
pub const LE_READ_DEFAULT_DATA_LENGTH = opcode(OGF_LE, 0x023);
/// HCI_LE_Read_PHY (OCF 0x030)
pub const LE_READ_PHY = opcode(OGF_LE, 0x030);
/// HCI_LE_Set_Default_PHY (OCF 0x031)
pub const LE_SET_DEFAULT_PHY = opcode(OGF_LE, 0x031);
/// HCI_LE_Set_PHY (OCF 0x032)
pub const LE_SET_PHY = opcode(OGF_LE, 0x032);

// ============================================================================
// PHY types
// ============================================================================

pub const Phy = struct {
    pub const @"1M": u8 = 0x01;
    pub const @"2M": u8 = 0x02;
    pub const coded: u8 = 0x03;
};

// ============================================================================
// Max command packet size
// ============================================================================

/// Max HCI command parameter length (255 bytes per spec)
pub const MAX_PARAM_LEN = 255;

/// Max complete command packet: indicator(1) + opcode(2) + len(1) + params(255)
pub const MAX_CMD_LEN = 1 + 2 + 1 + MAX_PARAM_LEN;

// ============================================================================
// Command Encoding
// ============================================================================

/// Encode an HCI command packet into a buffer.
///
/// Returns a slice of the encoded packet within `buf`.
/// Format: [0x01][opcode_lo][opcode_hi][param_len][params...]
pub fn encode(buf: *[MAX_CMD_LEN]u8, op: u16, params: []const u8) []const u8 {
    std.debug.assert(params.len <= MAX_PARAM_LEN);
    buf[0] = @intFromEnum(hci.PacketType.command);
    buf[1] = @truncate(op);
    buf[2] = @truncate(op >> 8);
    buf[3] = @intCast(params.len);
    if (params.len > 0) {
        @memcpy(buf[4..][0..params.len], params);
    }
    return buf[0 .. 4 + params.len];
}

// ============================================================================
// Pre-built Commands (convenience)
// ============================================================================

/// HCI_Reset — no parameters
pub fn reset(buf: *[MAX_CMD_LEN]u8) []const u8 {
    return encode(buf, RESET, &.{});
}

/// HCI_Set_Event_Mask — 8-byte mask
pub fn setEventMask(buf: *[MAX_CMD_LEN]u8, mask: u64) []const u8 {
    const params = std.mem.asBytes(&std.mem.nativeToLittle(u64, mask));
    return encode(buf, SET_EVENT_MASK, params);
}

/// HCI_LE_Set_Event_Mask — 8-byte mask
pub fn leSetEventMask(buf: *[MAX_CMD_LEN]u8, mask: u64) []const u8 {
    const params = std.mem.asBytes(&std.mem.nativeToLittle(u64, mask));
    return encode(buf, LE_SET_EVENT_MASK, params);
}

/// HCI_LE_Set_Advertising_Enable
pub fn leSetAdvEnable(buf: *[MAX_CMD_LEN]u8, enable: bool) []const u8 {
    return encode(buf, LE_SET_ADV_ENABLE, &.{@intFromBool(enable)});
}

/// HCI_LE_Set_Scan_Enable
pub fn leSetScanEnable(buf: *[MAX_CMD_LEN]u8, enable: bool, filter_duplicates: bool) []const u8 {
    return encode(buf, LE_SET_SCAN_ENABLE, &.{
        @intFromBool(enable),
        @intFromBool(filter_duplicates),
    });
}

/// HCI_LE_Set_Advertising_Parameters
pub const AdvParams = struct {
    /// Minimum advertising interval (units of 0.625ms, range: 0x0020-0x4000)
    interval_min: u16 = 0x0800, // 1.28s
    /// Maximum advertising interval
    interval_max: u16 = 0x0800,
    /// Advertising type
    adv_type: AdvType = .adv_ind,
    /// Own address type
    own_addr_type: hci.AddrType = .public,
    /// Peer address type (for directed advertising)
    peer_addr_type: hci.AddrType = .public,
    /// Peer address (for directed advertising)
    peer_addr: hci.BdAddr = .{ 0, 0, 0, 0, 0, 0 },
    /// Advertising channel map (bit 0=ch37, bit 1=ch38, bit 2=ch39)
    channel_map: u8 = 0x07, // All channels
    /// Advertising filter policy
    filter_policy: u8 = 0x00,
};

pub const AdvType = enum(u8) {
    /// Connectable undirected (ADV_IND)
    adv_ind = 0x00,
    /// Connectable high duty cycle directed (ADV_DIRECT_IND high)
    adv_direct_ind_high = 0x01,
    /// Scannable undirected (ADV_SCAN_IND)
    adv_scan_ind = 0x02,
    /// Non-connectable undirected (ADV_NONCONN_IND)
    adv_nonconn_ind = 0x03,
    /// Connectable low duty cycle directed (ADV_DIRECT_IND low)
    adv_direct_ind_low = 0x04,
};

pub fn leSetAdvParams(buf: *[MAX_CMD_LEN]u8, params: AdvParams) []const u8 {
    var p: [15]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], params.interval_min, .little);
    std.mem.writeInt(u16, p[2..4], params.interval_max, .little);
    p[4] = @intFromEnum(params.adv_type);
    p[5] = @intFromEnum(params.own_addr_type);
    p[6] = @intFromEnum(params.peer_addr_type);
    @memcpy(p[7..13], &params.peer_addr);
    p[13] = params.channel_map;
    p[14] = params.filter_policy;
    return encode(buf, LE_SET_ADV_PARAMS, &p);
}

/// HCI_LE_Set_Advertising_Data (max 31 bytes)
pub fn leSetAdvData(buf: *[MAX_CMD_LEN]u8, data: []const u8) []const u8 {
    std.debug.assert(data.len <= 31);
    var p: [32]u8 = std.mem.zeroes([32]u8);
    p[0] = @intCast(data.len);
    @memcpy(p[1..][0..data.len], data);
    return encode(buf, LE_SET_ADV_DATA, &p);
}

/// HCI_LE_Set_Scan_Response_Data (max 31 bytes)
pub fn leSetScanRspData(buf: *[MAX_CMD_LEN]u8, data: []const u8) []const u8 {
    std.debug.assert(data.len <= 31);
    var p: [32]u8 = std.mem.zeroes([32]u8);
    p[0] = @intCast(data.len);
    @memcpy(p[1..][0..data.len], data);
    return encode(buf, LE_SET_SCAN_RSP_DATA, &p);
}

/// HCI_Disconnect
pub fn disconnect(buf: *[MAX_CMD_LEN]u8, conn_handle: u16, reason: u8) []const u8 {
    var p: [3]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], conn_handle, .little);
    p[2] = reason;
    return encode(buf, DISCONNECT, &p);
}

// ============================================================================
// Central Role Commands
// ============================================================================

/// HCI_LE_Set_Scan_Parameters
pub const ScanParams = struct {
    /// 0x00 = passive, 0x01 = active
    scan_type: u8 = 0x01,
    /// Scan interval (units of 0.625ms, range: 0x0004-0x4000)
    interval: u16 = 0x0010, // 10ms
    /// Scan window (units of 0.625ms, range: 0x0004-0x4000)
    window: u16 = 0x0010, // 10ms (= interval → continuous scanning)
    /// Own address type
    own_addr_type: hci.AddrType = .public,
    /// Scanning filter policy (0x00 = accept all)
    filter_policy: u8 = 0x00,
};

pub fn leSetScanParams(buf: *[MAX_CMD_LEN]u8, params: ScanParams) []const u8 {
    var p: [7]u8 = undefined;
    p[0] = params.scan_type;
    std.mem.writeInt(u16, p[1..3], params.interval, .little);
    std.mem.writeInt(u16, p[3..5], params.window, .little);
    p[5] = @intFromEnum(params.own_addr_type);
    p[6] = params.filter_policy;
    return encode(buf, LE_SET_SCAN_PARAMS, &p);
}

/// HCI_LE_Create_Connection
pub const CreateConnParams = struct {
    /// Scan interval for connection (units of 0.625ms)
    scan_interval: u16 = 0x0010, // 10ms
    /// Scan window for connection (units of 0.625ms)
    scan_window: u16 = 0x0010, // 10ms
    /// Filter policy: 0 = use peer_addr, 1 = use filter accept list
    filter_policy: u8 = 0x00,
    /// Peer address type
    peer_addr_type: hci.AddrType = .public,
    /// Peer address
    peer_addr: hci.BdAddr = .{ 0, 0, 0, 0, 0, 0 },
    /// Own address type
    own_addr_type: hci.AddrType = .public,
    /// Connection interval min (units of 1.25ms, range: 0x0006-0x0C80)
    conn_interval_min: u16 = 0x0006, // 7.5ms
    /// Connection interval max (units of 1.25ms)
    conn_interval_max: u16 = 0x0006, // 7.5ms
    /// Connection latency (number of connection events to skip)
    conn_latency: u16 = 0x0000,
    /// Supervision timeout (units of 10ms, range: 0x000A-0x0C80)
    supervision_timeout: u16 = 0x00C8, // 2000ms
    /// Minimum CE length (units of 0.625ms)
    min_ce_length: u16 = 0x0000,
    /// Maximum CE length (units of 0.625ms)
    max_ce_length: u16 = 0x0000,
};

pub fn leCreateConnection(buf: *[MAX_CMD_LEN]u8, params: CreateConnParams) []const u8 {
    var p: [25]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], params.scan_interval, .little);
    std.mem.writeInt(u16, p[2..4], params.scan_window, .little);
    p[4] = params.filter_policy;
    p[5] = @intFromEnum(params.peer_addr_type);
    @memcpy(p[6..12], &params.peer_addr);
    p[12] = @intFromEnum(params.own_addr_type);
    std.mem.writeInt(u16, p[13..15], params.conn_interval_min, .little);
    std.mem.writeInt(u16, p[15..17], params.conn_interval_max, .little);
    std.mem.writeInt(u16, p[17..19], params.conn_latency, .little);
    std.mem.writeInt(u16, p[19..21], params.supervision_timeout, .little);
    std.mem.writeInt(u16, p[21..23], params.min_ce_length, .little);
    std.mem.writeInt(u16, p[23..25], params.max_ce_length, .little);
    return encode(buf, LE_CREATE_CONNECTION, &p);
}

// ============================================================================
// Performance Tuning Commands (post-connection)
// ============================================================================

/// HCI_LE_Set_Data_Length — enable Data Length Extension (DLE)
pub fn leSetDataLength(
    buf: *[MAX_CMD_LEN]u8,
    conn_handle: u16,
    tx_octets: u16,
    tx_time: u16,
) []const u8 {
    var p: [6]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], conn_handle, .little);
    std.mem.writeInt(u16, p[2..4], tx_octets, .little);
    std.mem.writeInt(u16, p[4..6], tx_time, .little);
    return encode(buf, LE_SET_DATA_LENGTH, &p);
}

/// HCI_LE_Set_PHY — request PHY change on a connection
///
/// tx_phys/rx_phys: bitmask — bit 0 = 1M, bit 1 = 2M, bit 2 = Coded
/// all_phys: bit 0 = no TX preference, bit 1 = no RX preference
/// phy_options: 0 = no preference, 1 = S=2 coding, 2 = S=8 coding (for Coded PHY)
pub fn leSetPhy(
    buf: *[MAX_CMD_LEN]u8,
    conn_handle: u16,
    all_phys: u8,
    tx_phys: u8,
    rx_phys: u8,
    phy_options: u16,
) []const u8 {
    var p: [7]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], conn_handle, .little);
    p[2] = all_phys;
    p[3] = tx_phys;
    p[4] = rx_phys;
    std.mem.writeInt(u16, p[5..7], phy_options, .little);
    return encode(buf, LE_SET_PHY, &p);
}

/// HCI_LE_Set_Default_PHY — set default PHY preferences for new connections
pub fn leSetDefaultPhy(buf: *[MAX_CMD_LEN]u8, all_phys: u8, tx_phys: u8, rx_phys: u8) []const u8 {
    return encode(buf, LE_SET_DEFAULT_PHY, &.{ all_phys, tx_phys, rx_phys });
}

/// HCI_LE_Read_PHY — read current PHY for a connection
pub fn leReadPhy(buf: *[MAX_CMD_LEN]u8, conn_handle: u16) []const u8 {
    var p: [2]u8 = undefined;
    std.mem.writeInt(u16, p[0..2], conn_handle, .little);
    return encode(buf, LE_READ_PHY, &p);
}

// ============================================================================
// Tests
// ============================================================================

test "opcode construction" {
    // HCI_Reset = OGF 0x03, OCF 0x003 = 0x0C03
    try std.testing.expectEqual(@as(u16, 0x0C03), RESET);
    // LE_Set_Adv_Enable = OGF 0x08, OCF 0x00A = 0x200A
    try std.testing.expectEqual(@as(u16, 0x200A), LE_SET_ADV_ENABLE);
}

test "encode HCI Reset" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = reset(&buf);
    try std.testing.expectEqual(@as(usize, 4), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x01), pkt[0]); // command indicator
    try std.testing.expectEqual(@as(u8, 0x03), pkt[1]); // opcode lo
    try std.testing.expectEqual(@as(u8, 0x0C), pkt[2]); // opcode hi
    try std.testing.expectEqual(@as(u8, 0x00), pkt[3]); // param len
}

test "encode LE Set Adv Enable" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = leSetAdvEnable(&buf, true);
    try std.testing.expectEqual(@as(usize, 5), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x01), pkt[0]); // command
    try std.testing.expectEqual(@as(u8, 0x0A), pkt[1]); // opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // opcode hi
    try std.testing.expectEqual(@as(u8, 0x01), pkt[3]); // param len
    try std.testing.expectEqual(@as(u8, 0x01), pkt[4]); // enable=true
}

test "encode LE Set Adv Data" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    // AD: Flags (0x02, 0x01, 0x06) + Complete Local Name "Zig"
    const ad_data = [_]u8{
        0x02, 0x01, 0x06, // Flags: LE General Discoverable + BR/EDR Not Supported
        0x04, 0x09, 'Z', 'i', 'g', // Complete Local Name: "Zig"
    };
    const pkt = leSetAdvData(&buf, &ad_data);
    try std.testing.expectEqual(@as(usize, 4 + 32), pkt.len); // header + 32 bytes (padded)
    try std.testing.expectEqual(@as(u8, 8), pkt[4]); // data length
    try std.testing.expectEqual(@as(u8, 0x02), pkt[5]); // first AD byte
}

test "new opcodes" {
    try std.testing.expectEqual(@as(u16, 0x200B), LE_SET_SCAN_PARAMS);
    try std.testing.expectEqual(@as(u16, 0x200D), LE_CREATE_CONNECTION);
    try std.testing.expectEqual(@as(u16, 0x2022), LE_SET_DATA_LENGTH);
    try std.testing.expectEqual(@as(u16, 0x2030), LE_READ_PHY);
    try std.testing.expectEqual(@as(u16, 0x2031), LE_SET_DEFAULT_PHY);
    try std.testing.expectEqual(@as(u16, 0x2032), LE_SET_PHY);
}

test "encode LE Set Scan Parameters" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = leSetScanParams(&buf, .{});
    try std.testing.expectEqual(@as(usize, 4 + 7), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x0B), pkt[1]); // opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // opcode hi
    try std.testing.expectEqual(@as(u8, 7), pkt[3]); // param len
    try std.testing.expectEqual(@as(u8, 0x01), pkt[4]); // active scan
}

test "encode LE Create Connection" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = leCreateConnection(&buf, .{
        .peer_addr = .{ 0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98 },
        .conn_interval_min = 0x0006,
        .conn_interval_max = 0x0006,
    });
    try std.testing.expectEqual(@as(usize, 4 + 25), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x0D), pkt[1]); // opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // opcode hi
    try std.testing.expectEqual(@as(u8, 25), pkt[3]); // param len
    // Peer addr at offset 4+6=10
    try std.testing.expectEqual(@as(u8, 0x50), pkt[10]);
}

test "encode LE Set Data Length" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = leSetDataLength(&buf, 0x0040, 251, 2120);
    try std.testing.expectEqual(@as(usize, 4 + 6), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x22), pkt[1]); // opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // opcode hi
    // conn_handle
    try std.testing.expectEqual(@as(u8, 0x40), pkt[4]);
    try std.testing.expectEqual(@as(u8, 0x00), pkt[5]);
    // tx_octets = 251 = 0x00FB
    try std.testing.expectEqual(@as(u8, 0xFB), pkt[6]);
    try std.testing.expectEqual(@as(u8, 0x00), pkt[7]);
}

test "encode LE Set PHY for 2M" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    // Request 2M PHY for both TX and RX
    const pkt = leSetPhy(&buf, 0x0040, 0x00, 0x02, 0x02, 0x0000);
    try std.testing.expectEqual(@as(usize, 4 + 7), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x32), pkt[1]); // opcode lo
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]); // opcode hi
    try std.testing.expectEqual(@as(u8, 0x02), pkt[7]); // tx_phys = 2M
    try std.testing.expectEqual(@as(u8, 0x02), pkt[8]); // rx_phys = 2M
}
