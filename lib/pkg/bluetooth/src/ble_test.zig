//! BLE Protocol Compliance Tests
//!
//! Organized by BLE Core Spec version:
//!   BLE 4.0: HCI, L2CAP, ATT, GAP, GATT basics
//!   BLE 4.2: DLE (Data Length Extension), LE Secure Connections
//!   BLE 5.0: 2M PHY, Extended Advertising
//!
//! Test naming: "BLE X.Y: <layer>: <test description>"

const std = @import("std");
const hci = @import("host/hci/hci.zig");
const commands = @import("host/hci/commands.zig");
const events = @import("host/hci/events.zig");
const acl = @import("host/hci/acl.zig");
const l2cap = @import("host/l2cap/l2cap.zig");
const att = @import("host/att/att.zig");
const gap = @import("host/gap/gap.zig");
const gatt = @import("gatt_server.zig");
const gatt_client = @import("gatt_client.zig");

// ============================================================================
// BLE 4.0: HCI Layer
// ============================================================================

test "BLE 4.0: HCI: packet type indicator values match spec" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(hci.PacketType.command));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(hci.PacketType.acl_data));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(hci.PacketType.sync_data));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(hci.PacketType.event));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(hci.PacketType.iso_data));
}

test "BLE 4.0: HCI: disconnect command encoding" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.disconnect(&buf, 0x0040, 0x13);
    try std.testing.expectEqual(@as(u8, 0x01), pkt[0]); // command indicator
    try std.testing.expectEqual(@as(u8, 0x06), pkt[1]); // opcode lo (0x0406)
    try std.testing.expectEqual(@as(u8, 0x04), pkt[2]); // opcode hi
    try std.testing.expectEqual(@as(u8, 0x03), pkt[3]); // param len
    try std.testing.expectEqual(@as(u8, 0x40), pkt[4]); // handle lo
    try std.testing.expectEqual(@as(u8, 0x13), pkt[6]); // reason
}

test "BLE 4.0: HCI: event mask encoding" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.setEventMask(&buf, 0xFF);
    try std.testing.expectEqual(@as(usize, 12), pkt.len); // 4 header + 8 mask
    try std.testing.expectEqual(@as(u8, 0xFF), pkt[4]); // first byte of mask
    try std.testing.expectEqual(@as(u8, 0x00), pkt[5]); // rest zeros
}

test "BLE 4.0: HCI: status codes match spec" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(hci.Status.success));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(hci.Status.authentication_failure));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(hci.Status.invalid_parameters));
    try std.testing.expect(hci.Status.success.isSuccess());
    try std.testing.expect(!hci.Status.authentication_failure.isSuccess());
}

test "BLE 4.0: HCI: decode Disconnection Complete event" {
    const raw = [_]u8{
        0x05, // Disconnection Complete
        0x04, // param len
        0x00, // status: success
        0x40, 0x00, // handle: 0x0040
        0x13, // reason: Remote User Terminated
    };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .disconnection_complete => |dc| {
            try std.testing.expect(dc.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x0040), dc.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x13), dc.reason);
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: Number of Completed Packets event" {
    const raw = [_]u8{
        0x13, // Number of Completed Packets
        0x05, // param len
        0x01, // num handles
        0x40, 0x00, // handle
        0x05, 0x00, // count = 5
    };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .num_completed_packets => |ncp| {
            try std.testing.expectEqual(@as(u8, 1), ncp.num_handles);
            const count = std.mem.readInt(u16, ncp.data[2..4], .little);
            try std.testing.expectEqual(@as(u16, 5), count);
        },
        else => unreachable,
    }
}

// ============================================================================
// BLE 4.0: ACL Layer
// ============================================================================

test "BLE 4.0: ACL: PB flag first auto-flush for LE" {
    var buf: [acl.MAX_PACKET_LEN]u8 = undefined;
    const pkt = acl.encode(&buf, 0x0040, .first_auto_flush, "test");
    const hdr = acl.parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(acl.PBFlag.first_auto_flush, hdr.pb_flag);
    try std.testing.expectEqual(acl.BCFlag.point_to_point, hdr.bc_flag);
}

test "BLE 4.0: ACL: continuing fragment flag" {
    var buf: [acl.MAX_PACKET_LEN]u8 = undefined;
    const pkt = acl.encode(&buf, 0x0040, .continuing, "data");
    const hdr = acl.parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(acl.PBFlag.continuing, hdr.pb_flag);
}

test "BLE 4.0: ACL: connection handle 12-bit mask" {
    var buf: [acl.MAX_PACKET_LEN]u8 = undefined;
    const pkt = acl.encode(&buf, 0x0FFF, .first_auto_flush, "x");
    const hdr = acl.parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0FFF), hdr.conn_handle);
}

// ============================================================================
// BLE 4.0: L2CAP Layer
// ============================================================================

test "BLE 4.0: L2CAP: fixed channel IDs per spec" {
    try std.testing.expectEqual(@as(u16, 0x0004), l2cap.CID_ATT);
    try std.testing.expectEqual(@as(u16, 0x0005), l2cap.CID_LE_SIGNALING);
    try std.testing.expectEqual(@as(u16, 0x0006), l2cap.CID_SMP);
}

test "BLE 4.0: L2CAP: empty SDU reassembly" {
    var reasm = l2cap.Reassembler{};
    // L2CAP frame with 0-length payload
    const data = [_]u8{
        0x00, 0x00, // L2CAP length: 0
        0x04, 0x00, // CID: ATT
    };
    const hdr = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = 4,
    };
    const sdu = reasm.feed(hdr, &data) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), sdu.data.len);
    try std.testing.expectEqual(l2cap.CID_ATT, sdu.cid);
}

test "BLE 4.0: L2CAP: discard continuing without first" {
    var reasm = l2cap.Reassembler{};
    const data = [_]u8{ 0xAA, 0xBB };
    const hdr = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .continuing,
        .bc_flag = .point_to_point,
        .data_len = 2,
    };
    // Should return null — no first fragment received
    try std.testing.expect(reasm.feed(hdr, &data) == null);
}

// ============================================================================
// BLE 4.0: ATT Layer
// ============================================================================

test "BLE 4.0: ATT: default MTU is 23" {
    try std.testing.expectEqual(@as(u16, 23), att.DEFAULT_MTU);
}

test "BLE 4.0: ATT: opcode values match spec" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(att.Opcode.error_response));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(att.Opcode.exchange_mtu_request));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(att.Opcode.read_request));
    try std.testing.expectEqual(@as(u8, 0x0B), @intFromEnum(att.Opcode.read_response));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(att.Opcode.write_request));
    try std.testing.expectEqual(@as(u8, 0x13), @intFromEnum(att.Opcode.write_response));
    try std.testing.expectEqual(@as(u8, 0x1B), @intFromEnum(att.Opcode.handle_value_notification));
    try std.testing.expectEqual(@as(u8, 0x1D), @intFromEnum(att.Opcode.handle_value_indication));
    try std.testing.expectEqual(@as(u8, 0x1E), @intFromEnum(att.Opcode.handle_value_confirmation));
    try std.testing.expectEqual(@as(u8, 0x52), @intFromEnum(att.Opcode.write_command));
}

test "BLE 4.0: ATT: error codes match spec" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(att.ErrorCode.invalid_handle));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(att.ErrorCode.read_not_permitted));
    try std.testing.expectEqual(@as(u8, 0x06), @intFromEnum(att.ErrorCode.request_not_supported));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(att.ErrorCode.attribute_not_found));
    try std.testing.expectEqual(@as(u8, 0x0D), @intFromEnum(att.ErrorCode.invalid_attribute_value_length));
}

test "BLE 4.0: ATT: GATT UUID values" {
    try std.testing.expectEqual(@as(u16, 0x2800), att.GATT_PRIMARY_SERVICE_UUID);
    try std.testing.expectEqual(@as(u16, 0x2803), att.GATT_CHARACTERISTIC_UUID);
    try std.testing.expectEqual(@as(u16, 0x2902), att.GATT_CLIENT_CHAR_CONFIG_UUID);
}

test "BLE 4.0: ATT: UUID 128-bit equality" {
    const uuid128_a = att.UUID.from128(.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 });
    const uuid128_b = att.UUID.from128(.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 });
    const uuid128_c = att.UUID.from128(.{ 0xFF, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 });
    try std.testing.expect(uuid128_a.eql(uuid128_b));
    try std.testing.expect(!uuid128_a.eql(uuid128_c));
    try std.testing.expectEqual(@as(usize, 16), uuid128_a.byteLen());
}

test "BLE 4.0: ATT: decode Find Information Request" {
    const data = [_]u8{ 0x04, 0x01, 0x00, 0xFF, 0xFF };
    const pdu = att.decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .find_information_request => |fi| {
            try std.testing.expectEqual(@as(u16, 0x0001), fi.start_handle);
            try std.testing.expectEqual(@as(u16, 0xFFFF), fi.end_handle);
        },
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Handle Value Confirmation" {
    const data = [_]u8{0x1E};
    const pdu = att.decodePdu(&data) orelse unreachable;
    try std.testing.expect(std.meta.activeTag(pdu) == .handle_value_confirmation);
}

test "BLE 4.0: ATT: encode Write Response is 1 byte" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeWriteResponse(&buf);
    try std.testing.expectEqual(@as(usize, 1), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x13), pdu[0]);
}

test "BLE 4.0: ATT: encode Indication" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeIndication(&buf, 0x0015, "test");
    try std.testing.expectEqual(@as(u8, 0x1D), pdu[0]); // Indication opcode
    try std.testing.expectEqual(@as(u16, 0x0015), std.mem.readInt(u16, pdu[1..3], .little));
    try std.testing.expectEqualStrings("test", pdu[3..7]);
}

// ============================================================================
// BLE 4.0: GAP Layer
// ============================================================================

test "BLE 4.0: GAP: advertising type values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(commands.AdvType.adv_ind));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(commands.AdvType.adv_scan_ind));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(commands.AdvType.adv_nonconn_ind));
}

test "BLE 4.0: GAP: state machine transitions" {
    var g = gap.Gap.init();

    // idle → advertising → idle
    try g.startAdvertising(.{});
    try std.testing.expectEqual(gap.State.advertising, g.state);
    try g.stopAdvertising();
    try std.testing.expectEqual(gap.State.idle, g.state);

    // idle → scanning → idle
    try g.startScanning(.{});
    try std.testing.expectEqual(gap.State.scanning, g.state);
    try g.stopScanning();
    try std.testing.expectEqual(gap.State.idle, g.state);
}

test "BLE 4.0: GAP: cannot scan while advertising" {
    var g = gap.Gap.init();
    try g.startAdvertising(.{});
    try std.testing.expectError(error.InvalidState, g.startScanning(.{}));
}

test "BLE 4.0: GAP: cannot advertise while scanning" {
    var g = gap.Gap.init();
    try g.startScanning(.{});
    try std.testing.expectError(error.InvalidState, g.startAdvertising(.{}));
}

// ============================================================================
// BLE 4.0: GATT Server
// ============================================================================

test "BLE 4.0: GATT: comptime handle assignment is sequential" {
    const TestServer = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{
            gatt.Char(0x2A37, .{ .read = true, .notify = true }),
        }),
    });

    // Service decl=1, char decl=2, char value=3, CCCD=4
    const value_handle = TestServer.getValueHandle(0x180D, 0x2A37);
    try std.testing.expectEqual(@as(u16, 3), value_handle);
    // CCCD = value + 1 = 4
}

test "BLE 4.0: GATT: multiple services handle assignment" {
    const TestServer = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{
            gatt.Char(0x2A37, .{ .read = true }),
        }),
        gatt.Service(0xFFE0, &.{
            gatt.Char(0xFFE1, .{ .write = true }),
        }),
    });
    // Svc1: decl=1, chr_decl=2, chr_val=3
    // Svc2: decl=4, chr_decl=5, chr_val=6
    try std.testing.expectEqual(@as(u16, 3), TestServer.getValueHandle(0x180D, 0x2A37));
    try std.testing.expectEqual(@as(u16, 6), TestServer.getValueHandle(0xFFE0, 0xFFE1));
}

test "BLE 4.0: GATT: CCCD state tracks enable/disable" {
    const TestServer = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{
            gatt.Char(0x2A37, .{ .read = true, .notify = true }),
        }),
    });

    var server = TestServer.init();
    try std.testing.expect(!server.isNotifyEnabled(0x180D, 0x2A37));

    // Simulate CCCD write (value handle=3, CCCD handle=4)
    var req_buf: [5]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.write_request);
    std.mem.writeInt(u16, req_buf[1..3], 4, .little); // CCCD handle
    req_buf[3] = 0x01; // enable notifications
    req_buf[4] = 0x00;

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    _ = server.handlePdu(0x0040, &req_buf, &resp_buf);

    try std.testing.expect(server.isNotifyEnabled(0x180D, 0x2A37));
}

test "BLE 4.0: GATT: unsupported ATT opcode returns error" {
    const TestServer = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{
            gatt.Char(0x2A37, .{ .read = true }),
        }),
    });
    var server = TestServer.init();

    // Send Read Multiple Request (0x0E) — not implemented
    var req_buf: [5]u8 = undefined;
    req_buf[0] = 0x0E;
    std.mem.writeInt(u16, req_buf[1..3], 3, .little);
    std.mem.writeInt(u16, req_buf[3..5], 4, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), resp[0]); // Error Response
}

// ============================================================================
// BLE 4.0: GATT Client Types
// ============================================================================

test "BLE 4.0: GATT Client: AttResponse from Read Response PDU" {
    const pdu = [_]u8{ 0x0B, 0xAA, 0xBB, 0xCC }; // Read Response
    const resp = gatt_client.AttResponse.fromPdu(&pdu);
    try std.testing.expectEqual(att.Opcode.read_response, resp.opcode);
    try std.testing.expect(!resp.isError());
    try std.testing.expectEqual(@as(usize, 3), resp.len); // payload without opcode
}

test "BLE 4.0: GATT Client: AttResponse from Error Response" {
    const pdu = [_]u8{ 0x01, 0x0A, 0x15, 0x00, 0x0A }; // Error for Read Request, Attribute Not Found
    const resp = gatt_client.AttResponse.fromPdu(&pdu);
    try std.testing.expectEqual(att.Opcode.error_response, resp.opcode);
    try std.testing.expect(resp.isError());
    try std.testing.expectEqual(att.ErrorCode.attribute_not_found, resp.err.?);
}

test "BLE 4.0: GATT Client: AttResponse from Write Response" {
    const pdu = [_]u8{0x13}; // Write Response (no data)
    const resp = gatt_client.AttResponse.fromPdu(&pdu);
    try std.testing.expectEqual(att.Opcode.write_response, resp.opcode);
    try std.testing.expect(!resp.isError());
    try std.testing.expectEqual(@as(usize, 0), resp.len);
}

// ============================================================================
// BLE 4.2: Data Length Extension
// ============================================================================

test "BLE 4.2: DLE: Set Data Length command encoding" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetDataLength(&buf, 0x0040, 251, 2120);
    try std.testing.expectEqual(@as(u16, 0x2022), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
    try std.testing.expectEqual(@as(u8, 6), pkt[3]); // param len
}

test "BLE 4.2: DLE: Data Length Change event" {
    const raw = [_]u8{
        0x3E, 0x0B, 0x07, // LE Meta, Data Length Change
        0x40, 0x00, // handle
        0xFB, 0x00, // max TX octets: 251
        0x48, 0x08, // max TX time: 2120
        0xFB, 0x00, // max RX octets: 251
        0x48, 0x08, // max RX time: 2120
    };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_data_length_change => |dl| {
            try std.testing.expectEqual(@as(u16, 251), dl.max_tx_octets);
            try std.testing.expectEqual(@as(u16, 2120), dl.max_tx_time);
        },
        else => unreachable,
    }
}

test "BLE 4.2: DLE: L2CAP reassembly with 251-byte fragments" {
    var reasm = l2cap.Reassembler{};

    // 100-byte SDU → 104 with L2CAP header, fits in one DLE fragment
    var full: [104]u8 = undefined;
    std.mem.writeInt(u16, full[0..2], 100, .little);
    std.mem.writeInt(u16, full[2..4], l2cap.CID_ATT, .little);
    for (4..104) |i| full[i] = @truncate(i);

    const hdr = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = 104,
    };
    const sdu = reasm.feed(hdr, &full) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 100), sdu.data.len);
}

// ============================================================================
// BLE 5.0: 2M PHY
// ============================================================================

test "BLE 5.0: PHY: Set PHY command for 2M" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetPhy(&buf, 0x0040, 0x00, 0x02, 0x02, 0x0000);
    try std.testing.expectEqual(@as(u16, 0x2032), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
    try std.testing.expectEqual(@as(u8, 0x02), pkt[7]); // tx_phys = 2M
    try std.testing.expectEqual(@as(u8, 0x02), pkt[8]); // rx_phys = 2M
}

test "BLE 5.0: PHY: Set Default PHY command" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetDefaultPhy(&buf, 0x00, 0x02, 0x02);
    try std.testing.expectEqual(@as(u16, 0x2031), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
}

test "BLE 5.0: PHY: PHY Update Complete event" {
    const raw = [_]u8{
        0x3E, 0x06, 0x0C, // LE Meta, PHY Update Complete
        0x00, // status: success
        0x40, 0x00, // handle
        0x02, // TX PHY: 2M
        0x02, // RX PHY: 2M
    };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_phy_update_complete => |pu| {
            try std.testing.expect(pu.status.isSuccess());
            try std.testing.expectEqual(@as(u8, 2), pu.tx_phy);
            try std.testing.expectEqual(@as(u8, 2), pu.rx_phy);
        },
        else => unreachable,
    }
}

test "BLE 5.0: PHY: Read PHY command" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leReadPhy(&buf, 0x0040);
    try std.testing.expectEqual(@as(u16, 0x2030), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
    try std.testing.expectEqual(@as(u8, 2), pkt[3]); // param len
}

test "BLE 5.0: GAP: PHY update request from connected state" {
    var g = gap.Gap.init();
    g.state = .connected;
    g.conn_handle = 0x0040;

    try g.requestPhyUpdate(0x0040, 0x02, 0x02);
    const cmd = g.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x32), cmd.data[1]); // LE_SET_PHY opcode lo
}

test "BLE 5.0: GAP: DLE request from connected state" {
    var g = gap.Gap.init();
    g.state = .connected;
    g.conn_handle = 0x0040;

    try g.requestDataLength(0x0040, 251, 2120);
    const cmd = g.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x22), cmd.data[1]); // LE_SET_DATA_LENGTH opcode lo
}

// ============================================================================
// BLE 4.0: TxPacket type detection
// ============================================================================

test "BLE 4.0: Host: TxPacket identifies command vs ACL" {
    const host_mod = @import("host/host.zig");

    const pkt_cmd = host_mod.TxPacket.fromSlice(&[_]u8{ 0x01, 0x03, 0x0C, 0x00 });
    try std.testing.expect(pkt_cmd.isCommand());
    try std.testing.expect(!pkt_cmd.isAclData());

    const pkt_acl = host_mod.TxPacket.fromSlice(&[_]u8{ 0x02, 0x40, 0x20, 0x07, 0x00 });
    try std.testing.expect(!pkt_acl.isCommand());
    try std.testing.expect(pkt_acl.isAclData());
}
