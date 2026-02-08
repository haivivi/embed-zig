//! BLE Protocol Compliance Tests
//!
//! Comprehensive test suite organized by BLE Core Spec version.
//! Covers all implemented functionality per RFC section.
//!
//! BLE 4.0: HCI (Vol 4 Part E), L2CAP (Vol 3 Part A), ATT (Vol 3 Part F),
//!          GAP (Vol 3 Part C), GATT (Vol 3 Part G)
//! BLE 4.2: DLE (Data Length Extension)
//! BLE 5.0: 2M/Coded PHY
//!
//! Test naming: "BLE X.Y: <layer>: <description>"

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
const host_mod = @import("host/host.zig");

// ============================================================================
// BLE 4.0: HCI — Vol 4 Part E
// ============================================================================

test "BLE 4.0: HCI: packet type indicators (Vol 4 Part A Table 1.1)" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(hci.PacketType.command));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(hci.PacketType.acl_data));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(hci.PacketType.sync_data));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(hci.PacketType.event));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(hci.PacketType.iso_data));
}

test "BLE 4.0: HCI: opcode structure OGF<<10|OCF (Vol 4 Part E 5.4.1)" {
    try std.testing.expectEqual(@as(u16, 0x0C03), commands.RESET); // OGF=3, OCF=3
    try std.testing.expectEqual(@as(u16, 0x0406), commands.DISCONNECT); // OGF=1, OCF=6
    try std.testing.expectEqual(@as(u16, 0x200A), commands.LE_SET_ADV_ENABLE); // OGF=8, OCF=0xA
    try std.testing.expectEqual(@as(u16, 0x200D), commands.LE_CREATE_CONNECTION);
}

test "BLE 4.0: HCI: command packet format [indicator][opcode_lo][opcode_hi][param_len][params]" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.reset(&buf);
    try std.testing.expectEqual(@as(u8, 0x01), pkt[0]); // indicator
    try std.testing.expectEqual(@as(u8, 0x03), pkt[1]); // opcode lo
    try std.testing.expectEqual(@as(u8, 0x0C), pkt[2]); // opcode hi
    try std.testing.expectEqual(@as(u8, 0x00), pkt[3]); // param len = 0
    try std.testing.expectEqual(@as(usize, 4), pkt.len);
}

test "BLE 4.0: HCI: max command param length is 255" {
    try std.testing.expectEqual(@as(usize, 255), commands.MAX_PARAM_LEN);
    try std.testing.expectEqual(@as(usize, 259), commands.MAX_CMD_LEN); // 1+2+1+255
}

test "BLE 4.0: HCI: disconnect command (Vol 4 Part E 7.1.6)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.disconnect(&buf, 0x0040, 0x13);
    try std.testing.expectEqual(@as(usize, 7), pkt.len); // 4 header + 3 params
    try std.testing.expectEqual(@as(u8, 0x13), pkt[6]); // reason
}

test "BLE 4.0: HCI: set event mask (Vol 4 Part E 7.3.1)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.setEventMask(&buf, 0xFF);
    try std.testing.expectEqual(@as(usize, 12), pkt.len); // 4 + 8
}

test "BLE 4.0: HCI: LE set event mask (Vol 4 Part E 7.8.1)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetEventMask(&buf, 0x1F);
    try std.testing.expectEqual(@as(u16, 0x2001), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
}

test "BLE 4.0: HCI: LE read buffer size (Vol 4 Part E 7.8.2)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.encode(&buf, commands.LE_READ_BUFFER_SIZE, &.{});
    try std.testing.expectEqual(@as(u16, 0x2002), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
    try std.testing.expectEqual(@as(u8, 0), pkt[3]); // no params
}

test "BLE 4.0: HCI: read BD_ADDR (Vol 4 Part E 7.4.6)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.encode(&buf, commands.READ_BD_ADDR, &.{});
    try std.testing.expectEqual(@as(u16, 0x1009), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
}

test "BLE 4.0: HCI: status codes (Vol 2 Part D)" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(hci.Status.success));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(hci.Status.unknown_command));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(hci.Status.authentication_failure));
    try std.testing.expectEqual(@as(u8, 0x07), @intFromEnum(hci.Status.memory_exceeded));
    try std.testing.expectEqual(@as(u8, 0x08), @intFromEnum(hci.Status.connection_timeout));
    try std.testing.expectEqual(@as(u8, 0x0C), @intFromEnum(hci.Status.command_disallowed));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(hci.Status.invalid_parameters));
    try std.testing.expectEqual(@as(u8, 0x13), @intFromEnum(hci.Status.remote_terminated));
    try std.testing.expect(hci.Status.success.isSuccess());
    try std.testing.expect(!hci.Status.unknown_command.isSuccess());
}

test "BLE 4.0: HCI: decode Command Complete (Vol 4 Part E 7.7.14)" {
    const raw = [_]u8{ 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .command_complete => |cc| {
            try std.testing.expectEqual(@as(u8, 1), cc.num_cmd_packets);
            try std.testing.expectEqual(@as(u16, 0x0C03), cc.opcode);
            try std.testing.expect(cc.status.isSuccess());
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode Command Complete with return params" {
    // LE Read Buffer Size response
    const raw = [_]u8{ 0x0E, 0x07, 0x01, 0x02, 0x20, 0x00, 0xFB, 0x00, 12 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .command_complete => |cc| {
            try std.testing.expectEqual(@as(u16, 0x2002), cc.opcode);
            try std.testing.expectEqual(@as(usize, 3), cc.return_params.len);
            try std.testing.expectEqual(@as(u16, 251), std.mem.readInt(u16, cc.return_params[0..2], .little));
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode Command Status (Vol 4 Part E 7.7.15)" {
    const raw = [_]u8{ 0x0F, 0x04, 0x00, 0x01, 0x0D, 0x20 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .command_status => |cs| {
            try std.testing.expect(cs.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x200D), cs.opcode);
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode Command Status failure" {
    const raw = [_]u8{ 0x0F, 0x04, 0x0C, 0x01, 0x0D, 0x20 }; // status=command_disallowed
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .command_status => |cs| {
            try std.testing.expect(!cs.status.isSuccess());
            try std.testing.expectEqual(hci.Status.command_disallowed, cs.status);
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode Disconnection Complete (Vol 4 Part E 7.7.5)" {
    const raw = [_]u8{ 0x05, 0x04, 0x00, 0x40, 0x00, 0x13 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .disconnection_complete => |dc| {
            try std.testing.expectEqual(@as(u16, 0x0040), dc.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x13), dc.reason);
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode Number of Completed Packets (Vol 4 Part E 7.7.19)" {
    const raw = [_]u8{ 0x13, 0x05, 0x01, 0x40, 0x00, 0x05, 0x00 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .num_completed_packets => |ncp| {
            try std.testing.expectEqual(@as(u8, 1), ncp.num_handles);
            try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, ncp.data[2..4], .little));
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: NCP with multiple handles" {
    const raw = [_]u8{ 0x13, 0x09, 0x02, 0x40, 0x00, 0x03, 0x00, 0x41, 0x00, 0x02, 0x00 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .num_completed_packets => |ncp| {
            try std.testing.expectEqual(@as(u8, 2), ncp.num_handles);
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode LE Connection Complete (Vol 4 Part E 7.7.65.1)" {
    const raw = [_]u8{ 0x3E, 0x13, 0x01, 0x00, 0x40, 0x00, 0x01, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x18, 0x00, 0x00, 0x00, 0xC8, 0x00, 0x00 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_connection_complete => |lc| {
            try std.testing.expect(lc.status.isSuccess());
            try std.testing.expectEqual(@as(u16, 0x0040), lc.conn_handle);
            try std.testing.expectEqual(@as(u8, 0x01), lc.role); // peripheral
            try std.testing.expectEqual(hci.AddrType.random, lc.peer_addr_type);
            try std.testing.expectEqual(@as(u16, 0x0018), lc.conn_interval);
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode LE Connection Complete failure" {
    const raw = [_]u8{ 0x3E, 0x13, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_connection_complete => |lc| {
            try std.testing.expect(!lc.status.isSuccess());
            try std.testing.expectEqual(hci.Status.connection_timeout, lc.status);
        },
        else => unreachable,
    }
}

test "BLE 4.0: HCI: decode unknown event code" {
    const raw = [_]u8{ 0xFF, 0x02, 0xAA, 0xBB };
    const evt = events.decode(&raw) orelse unreachable;
    try std.testing.expect(std.meta.activeTag(evt) == .unknown);
}

test "BLE 4.0: HCI: decode too-short data returns null" {
    try std.testing.expect(events.decode(&[_]u8{0x0E}) == null); // 1 byte
    try std.testing.expect(events.decode(&[_]u8{}) == null); // 0 bytes
}

test "BLE 4.0: HCI: LE advertising report parsing" {
    const raw = [_]u8{ 0x00, 0x00, 0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98, 0x03, 0x02, 0x01, 0x06, 0xC0 };
    const report = events.parseAdvReport(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x00), report.event_type); // ADV_IND
    try std.testing.expectEqual(hci.AddrType.public, report.addr_type);
    try std.testing.expectEqual(@as(usize, 3), report.data.len);
    try std.testing.expectEqual(@as(i8, -64), report.rssi);
}

test "BLE 4.0: HCI: LE advertising report too short" {
    const raw = [_]u8{ 0x00, 0x00, 0x50, 0x5C }; // 4 bytes < 10 minimum
    try std.testing.expect(events.parseAdvReport(&raw) == null);
}

// ============================================================================
// BLE 4.0: ACL — Vol 4 Part E 5.4.2
// ============================================================================

test "BLE 4.0: ACL: packet format [indicator][handle+flags(2)][length(2)][data]" {
    var buf: [acl.MAX_PACKET_LEN]u8 = undefined;
    const pkt = acl.encode(&buf, 0x0040, .first_auto_flush, "hello");
    try std.testing.expectEqual(@as(u8, 0x02), pkt[0]); // ACL indicator
    try std.testing.expectEqual(@as(usize, 10), pkt.len); // 1+4+5
}

test "BLE 4.0: ACL: PB flag values (Vol 4 Part E 5.4.2)" {
    try std.testing.expectEqual(@as(u2, 0b00), @intFromEnum(acl.PBFlag.first_non_auto_flush));
    try std.testing.expectEqual(@as(u2, 0b01), @intFromEnum(acl.PBFlag.continuing));
    try std.testing.expectEqual(@as(u2, 0b10), @intFromEnum(acl.PBFlag.first_auto_flush));
}

test "BLE 4.0: ACL: connection handle 12-bit mask" {
    var buf: [acl.MAX_PACKET_LEN]u8 = undefined;
    const pkt = acl.encode(&buf, 0x0FFF, .first_auto_flush, "x");
    const hdr = acl.parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0FFF), hdr.conn_handle);
}

test "BLE 4.0: ACL: parse header with correct data_len" {
    const raw = [_]u8{ 0x40, 0x20, 0x05, 0x00, 'h', 'e', 'l', 'l', 'o' };
    const hdr = acl.parseHeader(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0040), hdr.conn_handle);
    try std.testing.expectEqual(@as(u16, 5), hdr.data_len);
    try std.testing.expectEqual(acl.PBFlag.first_auto_flush, hdr.pb_flag);
}

test "BLE 4.0: ACL: parse too-short header returns null" {
    try std.testing.expect(acl.parseHeader(&[_]u8{ 0x40, 0x20, 0x05 }) == null); // 3 bytes < 4
}

test "BLE 4.0: ACL: payload extraction" {
    const raw = [_]u8{ 0x40, 0x20, 0x03, 0x00, 0xAA, 0xBB, 0xCC };
    const pl = acl.payload(&raw) orelse unreachable;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, pl);
}

test "BLE 4.0: ACL: round-trip encode/parse preserves data" {
    var buf: [acl.MAX_PACKET_LEN]u8 = undefined;
    const original = "BLE test data 1234567890";
    const pkt = acl.encode(&buf, 0x0001, .first_auto_flush, original);
    const hdr = acl.parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0001), hdr.conn_handle);
    const pl = acl.payload(pkt[1..]) orelse unreachable;
    try std.testing.expectEqualStrings(original, pl);
}

test "BLE 4.0: ACL: LE default data length is 27" {
    try std.testing.expectEqual(@as(u16, 27), acl.LE_DEFAULT_DATA_LEN);
}

test "BLE 4.0: ACL: LE max data length is 251" {
    try std.testing.expectEqual(@as(u16, 251), acl.LE_MAX_DATA_LEN);
}

// ============================================================================
// BLE 4.0: L2CAP — Vol 3 Part A
// ============================================================================

test "BLE 4.0: L2CAP: fixed CIDs (Vol 3 Part A 2.1)" {
    try std.testing.expectEqual(@as(u16, 0x0004), l2cap.CID_ATT);
    try std.testing.expectEqual(@as(u16, 0x0005), l2cap.CID_LE_SIGNALING);
    try std.testing.expectEqual(@as(u16, 0x0006), l2cap.CID_SMP);
}

test "BLE 4.0: L2CAP: header is 4 bytes [length(2)][CID(2)]" {
    try std.testing.expectEqual(@as(usize, 4), l2cap.HEADER_LEN);
}

test "BLE 4.0: L2CAP: parse header" {
    const data = [_]u8{ 0x05, 0x00, 0x04, 0x00, 'h', 'e', 'l', 'l', 'o' };
    const hdr = l2cap.parseHeader(&data) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 5), hdr.length);
    try std.testing.expectEqual(l2cap.CID_ATT, hdr.cid);
}

test "BLE 4.0: L2CAP: reassemble single fragment" {
    var reasm = l2cap.Reassembler{};
    const data = [_]u8{ 0x03, 0x00, 0x04, 0x00, 0xAA, 0xBB, 0xCC };
    const hdr = acl.AclHeader{ .conn_handle = 0x0040, .pb_flag = .first_auto_flush, .bc_flag = .point_to_point, .data_len = 7 };
    const sdu = reasm.feed(hdr, &data) orelse unreachable;
    try std.testing.expectEqual(l2cap.CID_ATT, sdu.cid);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, sdu.data);
}

test "BLE 4.0: L2CAP: reassemble two fragments" {
    var reasm = l2cap.Reassembler{};
    const frag1 = [_]u8{ 0x04, 0x00, 0x04, 0x00, 0x01, 0x02 };
    const hdr1 = acl.AclHeader{ .conn_handle = 0x0040, .pb_flag = .first_auto_flush, .bc_flag = .point_to_point, .data_len = 6 };
    try std.testing.expect(reasm.feed(hdr1, &frag1) == null);

    const frag2 = [_]u8{ 0x03, 0x04 };
    const hdr2 = acl.AclHeader{ .conn_handle = 0x0040, .pb_flag = .continuing, .bc_flag = .point_to_point, .data_len = 2 };
    const sdu = reasm.feed(hdr2, &frag2) orelse unreachable;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, sdu.data);
}

test "BLE 4.0: L2CAP: empty SDU" {
    var reasm = l2cap.Reassembler{};
    const data = [_]u8{ 0x00, 0x00, 0x04, 0x00 };
    const hdr = acl.AclHeader{ .conn_handle = 0x0040, .pb_flag = .first_auto_flush, .bc_flag = .point_to_point, .data_len = 4 };
    const sdu = reasm.feed(hdr, &data) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), sdu.data.len);
}

test "BLE 4.0: L2CAP: discard orphan continuation fragment" {
    var reasm = l2cap.Reassembler{};
    const hdr = acl.AclHeader{ .conn_handle = 0x0040, .pb_flag = .continuing, .bc_flag = .point_to_point, .data_len = 2 };
    try std.testing.expect(reasm.feed(hdr, &[_]u8{ 0xAA, 0xBB }) == null);
}

test "BLE 4.0: L2CAP: fragment iterator single fragment" {
    var sdu_buf: [acl.LE_MAX_DATA_LEN + l2cap.HEADER_LEN]u8 = undefined;
    var iter = l2cap.fragmentIterator(&sdu_buf, &[_]u8{ 0x01, 0x02, 0x03 }, l2cap.CID_ATT, 0x0040, 27);
    const frag = iter.next() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x02), frag[0]); // ACL indicator
    try std.testing.expect(iter.next() == null); // only one fragment
}

test "BLE 4.0: L2CAP: connection handle preserved in SDU" {
    var reasm = l2cap.Reassembler{};
    const data = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0xFF };
    const hdr = acl.AclHeader{ .conn_handle = 0x0123, .pb_flag = .first_auto_flush, .bc_flag = .point_to_point, .data_len = 5 };
    const sdu = reasm.feed(hdr, &data) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0123), sdu.conn_handle);
}

test "BLE 4.0: L2CAP: reassembler reset after complete SDU" {
    var reasm = l2cap.Reassembler{};
    const data = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0xAA };
    const hdr = acl.AclHeader{ .conn_handle = 0x0040, .pb_flag = .first_auto_flush, .bc_flag = .point_to_point, .data_len = 5 };
    _ = reasm.feed(hdr, &data) orelse unreachable;

    // Second SDU should work independently
    const data2 = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0xBB };
    const sdu2 = reasm.feed(hdr, &data2) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0xBB), sdu2.data[0]);
}

// ============================================================================
// BLE 4.0: ATT — Vol 3 Part F
// ============================================================================

test "BLE 4.0: ATT: default MTU is 23 (Vol 3 Part F 3.2.8)" {
    try std.testing.expectEqual(@as(u16, 23), att.DEFAULT_MTU);
}

test "BLE 4.0: ATT: max MTU is 517 (Vol 3 Part F 3.2.9)" {
    try std.testing.expectEqual(@as(u16, 517), att.MAX_MTU);
}

test "BLE 4.0: ATT: opcode values (Vol 3 Part F 3.4)" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(att.Opcode.error_response));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(att.Opcode.exchange_mtu_request));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(att.Opcode.exchange_mtu_response));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(att.Opcode.find_information_request));
    try std.testing.expectEqual(@as(u8, 0x08), @intFromEnum(att.Opcode.read_by_type_request));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(att.Opcode.read_request));
    try std.testing.expectEqual(@as(u8, 0x0B), @intFromEnum(att.Opcode.read_response));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(att.Opcode.read_by_group_type_request));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(att.Opcode.write_request));
    try std.testing.expectEqual(@as(u8, 0x52), @intFromEnum(att.Opcode.write_command));
    try std.testing.expectEqual(@as(u8, 0x1B), @intFromEnum(att.Opcode.handle_value_notification));
    try std.testing.expectEqual(@as(u8, 0x1D), @intFromEnum(att.Opcode.handle_value_indication));
    try std.testing.expectEqual(@as(u8, 0x1E), @intFromEnum(att.Opcode.handle_value_confirmation));
}

test "BLE 4.0: ATT: error codes (Vol 3 Part F 3.4.1.1)" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(att.ErrorCode.invalid_handle));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(att.ErrorCode.read_not_permitted));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(att.ErrorCode.write_not_permitted));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(att.ErrorCode.invalid_pdu));
    try std.testing.expectEqual(@as(u8, 0x06), @intFromEnum(att.ErrorCode.request_not_supported));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(att.ErrorCode.attribute_not_found));
    try std.testing.expectEqual(@as(u8, 0x0D), @intFromEnum(att.ErrorCode.invalid_attribute_value_length));
}

test "BLE 4.0: ATT: GATT UUID values (Vol 3 Part G 3)" {
    try std.testing.expectEqual(@as(u16, 0x2800), att.GATT_PRIMARY_SERVICE_UUID);
    try std.testing.expectEqual(@as(u16, 0x2801), att.GATT_SECONDARY_SERVICE_UUID);
    try std.testing.expectEqual(@as(u16, 0x2803), att.GATT_CHARACTERISTIC_UUID);
    try std.testing.expectEqual(@as(u16, 0x2902), att.GATT_CLIENT_CHAR_CONFIG_UUID);
}

test "BLE 4.0: ATT: UUID 16-bit" {
    const uuid = att.UUID.from16(0x2800);
    try std.testing.expectEqual(@as(usize, 2), uuid.byteLen());
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), uuid.writeTo(&buf));
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x28), buf[1]);
}

test "BLE 4.0: ATT: UUID 128-bit" {
    const bytes = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const uuid = att.UUID.from128(bytes);
    try std.testing.expectEqual(@as(usize, 16), uuid.byteLen());
}

test "BLE 4.0: ATT: UUID equality" {
    try std.testing.expect(att.UUID.from16(0x2800).eql(att.UUID.from16(0x2800)));
    try std.testing.expect(!att.UUID.from16(0x2800).eql(att.UUID.from16(0x2801)));
    try std.testing.expect(!att.UUID.from16(0x2800).eql(att.UUID.from128(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })));
}

test "BLE 4.0: ATT: UUID readFrom" {
    const buf16 = [_]u8{ 0x00, 0x28 };
    const uuid16 = att.UUID.readFrom(&buf16, 2) orelse unreachable;
    try std.testing.expect(uuid16.eql(att.UUID.from16(0x2800)));

    try std.testing.expect(att.UUID.readFrom(&buf16, 3) == null); // wrong len
}

test "BLE 4.0: ATT: encode Error Response (Vol 3 Part F 3.4.1.1)" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeErrorResponse(&buf, .read_request, 0x0010, .attribute_not_found);
    try std.testing.expectEqual(@as(usize, 5), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x01), pdu[0]);
    try std.testing.expectEqual(@as(u8, 0x0A), pdu[1]); // req opcode
    try std.testing.expectEqual(@as(u8, 0x0A), pdu[4]); // error code
}

test "BLE 4.0: ATT: encode Read Response" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeReadResponse(&buf, "test");
    try std.testing.expectEqual(@as(u8, 0x0B), pdu[0]);
    try std.testing.expectEqualStrings("test", pdu[1..5]);
}

test "BLE 4.0: ATT: encode Write Response is exactly 1 byte" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeWriteResponse(&buf);
    try std.testing.expectEqual(@as(usize, 1), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x13), pdu[0]);
}

test "BLE 4.0: ATT: encode MTU Response" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeMtuResponse(&buf, 512);
    try std.testing.expectEqual(@as(u8, 0x03), pdu[0]);
    try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, pdu[1..3], .little));
}

test "BLE 4.0: ATT: encode Notification (Vol 3 Part F 3.4.7.1)" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeNotification(&buf, 0x0015, "data");
    try std.testing.expectEqual(@as(u8, 0x1B), pdu[0]);
    try std.testing.expectEqual(@as(u16, 0x0015), std.mem.readInt(u16, pdu[1..3], .little));
}

test "BLE 4.0: ATT: encode Indication (Vol 3 Part F 3.4.7.2)" {
    var buf: [att.MAX_PDU_LEN]u8 = undefined;
    const pdu = att.encodeIndication(&buf, 0x0015, "test");
    try std.testing.expectEqual(@as(u8, 0x1D), pdu[0]);
}

test "BLE 4.0: ATT: decode Exchange MTU Request" {
    const pdu = att.decodePdu(&[_]u8{ 0x02, 0x00, 0x02 }) orelse unreachable;
    switch (pdu) {
        .exchange_mtu_request => |req| try std.testing.expectEqual(@as(u16, 512), req.client_mtu),
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Read Request" {
    const pdu = att.decodePdu(&[_]u8{ 0x0A, 0x15, 0x00 }) orelse unreachable;
    switch (pdu) {
        .read_request => |rr| try std.testing.expectEqual(@as(u16, 0x0015), rr.handle),
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Write Request with data" {
    const pdu = att.decodePdu(&[_]u8{ 0x12, 0x15, 0x00, 0xAA, 0xBB }) orelse unreachable;
    switch (pdu) {
        .write_request => |wr| {
            try std.testing.expectEqual(@as(u16, 0x0015), wr.handle);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, wr.value);
        },
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Write Command" {
    const pdu = att.decodePdu(&[_]u8{ 0x52, 0x15, 0x00, 0xCC }) orelse unreachable;
    switch (pdu) {
        .write_command => |wc| {
            try std.testing.expectEqual(@as(u16, 0x0015), wc.handle);
            try std.testing.expectEqual(@as(u8, 0xCC), wc.value[0]);
        },
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Find Information Request" {
    const pdu = att.decodePdu(&[_]u8{ 0x04, 0x01, 0x00, 0xFF, 0xFF }) orelse unreachable;
    switch (pdu) {
        .find_information_request => |fi| {
            try std.testing.expectEqual(@as(u16, 1), fi.start_handle);
            try std.testing.expectEqual(@as(u16, 0xFFFF), fi.end_handle);
        },
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Read By Group Type Request" {
    const pdu = att.decodePdu(&[_]u8{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 }) orelse unreachable;
    switch (pdu) {
        .read_by_group_type_request => |req| {
            try std.testing.expect(req.uuid.eql(att.UUID.from16(0x2800)));
        },
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Read By Type Request" {
    const pdu = att.decodePdu(&[_]u8{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x03, 0x28 }) orelse unreachable;
    switch (pdu) {
        .read_by_type_request => |req| {
            try std.testing.expect(req.uuid.eql(att.UUID.from16(0x2803)));
        },
        else => unreachable,
    }
}

test "BLE 4.0: ATT: decode Handle Value Confirmation" {
    const pdu = att.decodePdu(&[_]u8{0x1E}) orelse unreachable;
    try std.testing.expect(std.meta.activeTag(pdu) == .handle_value_confirmation);
}

test "BLE 4.0: ATT: decode too-short PDU returns null" {
    try std.testing.expect(att.decodePdu(&[_]u8{}) == null);
}

test "BLE 4.0: ATT: CharProps packed layout is 1 byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(att.CharProps));
    const rw: att.CharProps = .{ .read = true, .write = true };
    try std.testing.expect(rw.read);
    try std.testing.expect(rw.write);
    try std.testing.expect(!rw.notify);
}

test "BLE 4.0: ATT: attribute database find by handle" {
    var db = att.AttributeDb(4){};
    _ = try db.add(.{ .handle = 1, .att_type = att.UUID.from16(0x2800), .value = &.{}, .permissions = .{ .readable = true } });
    _ = try db.add(.{ .handle = 5, .att_type = att.UUID.from16(0x2803), .value = &.{}, .permissions = .{ .readable = true } });

    try std.testing.expect(db.findByHandle(1) != null);
    try std.testing.expect(db.findByHandle(5) != null);
    try std.testing.expect(db.findByHandle(3) == null);
}

// ============================================================================
// BLE 4.0: GAP — Vol 3 Part C
// ============================================================================

test "BLE 4.0: GAP: advertising params encoding (Vol 4 Part E 7.8.5)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetAdvParams(&buf, .{
        .interval_min = 0x0020,
        .interval_max = 0x0040,
        .adv_type = .adv_ind,
    });
    try std.testing.expectEqual(@as(usize, 19), pkt.len); // 4 + 15 params
}

test "BLE 4.0: GAP: advertising data encoding (Vol 4 Part E 7.8.7)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetAdvData(&buf, &[_]u8{ 0x02, 0x01, 0x06 });
    try std.testing.expectEqual(@as(usize, 36), pkt.len); // 4 + 32 (padded)
    try std.testing.expectEqual(@as(u8, 3), pkt[4]); // data len
}

test "BLE 4.0: GAP: scan response data encoding" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetScanRspData(&buf, &[_]u8{ 0x05, 0x09, 'T', 'e', 's', 't' });
    try std.testing.expectEqual(@as(u8, 6), pkt[4]); // data len
}

test "BLE 4.0: GAP: scan enable encoding (Vol 4 Part E 7.8.11)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetScanEnable(&buf, true, true);
    try std.testing.expectEqual(@as(u8, 0x01), pkt[4]); // enable
    try std.testing.expectEqual(@as(u8, 0x01), pkt[5]); // filter dups
}

test "BLE 4.0: GAP: scan params encoding (Vol 4 Part E 7.8.10)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetScanParams(&buf, .{ .scan_type = 0x01 });
    try std.testing.expectEqual(@as(usize, 11), pkt.len); // 4 + 7
}

test "BLE 4.0: GAP: create connection encoding (Vol 4 Part E 7.8.12)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leCreateConnection(&buf, .{ .peer_addr = .{ 0x50, 0x5C, 0x11, 0xE0, 0x88, 0x98 } });
    try std.testing.expectEqual(@as(usize, 29), pkt.len); // 4 + 25
}

test "BLE 4.0: GAP: state machine idle->adv->connected" {
    var g = gap.Gap.init();
    try std.testing.expectEqual(gap.State.idle, g.state);

    try g.startAdvertising(.{});
    try std.testing.expectEqual(gap.State.advertising, g.state);

    g.handleEvent(.{ .le_connection_complete = .{
        .status = .success, .conn_handle = 1, .role = 1,
        .peer_addr_type = .public, .peer_addr = .{ 0, 0, 0, 0, 0, 0 },
        .conn_interval = 6, .conn_latency = 0, .supervision_timeout = 200,
    } });
    try std.testing.expectEqual(gap.State.connected, g.state);
}

test "BLE 4.0: GAP: state machine idle->scan->connecting->connected" {
    var g = gap.Gap.init();
    try g.startScanning(.{});
    try std.testing.expectEqual(gap.State.scanning, g.state);

    try g.connect(.{ 0, 0, 0, 0, 0, 0 }, .public, .{});
    try std.testing.expectEqual(gap.State.connecting, g.state);

    g.handleEvent(.{ .le_connection_complete = .{
        .status = .success, .conn_handle = 1, .role = 0,
        .peer_addr_type = .public, .peer_addr = .{ 0, 0, 0, 0, 0, 0 },
        .conn_interval = 6, .conn_latency = 0, .supervision_timeout = 200,
    } });
    try std.testing.expectEqual(gap.State.connected, g.state);
}

test "BLE 4.0: GAP: disconnect returns to idle" {
    var g = gap.Gap.init();
    g.state = .connected;
    g.conn_handle = 1;
    g.handleEvent(.{ .disconnection_complete = .{ .status = .success, .conn_handle = 1, .reason = 0x13 } });
    try std.testing.expectEqual(gap.State.idle, g.state);
    try std.testing.expect(g.conn_handle == null);
}

test "BLE 4.0: GAP: connection failure returns to idle" {
    var g = gap.Gap.init();
    g.state = .connecting;
    g.handleEvent(.{ .le_connection_complete = .{
        .status = .connection_timeout, .conn_handle = 0, .role = 0,
        .peer_addr_type = .public, .peer_addr = .{ 0, 0, 0, 0, 0, 0 },
        .conn_interval = 0, .conn_latency = 0, .supervision_timeout = 0,
    } });
    try std.testing.expectEqual(gap.State.idle, g.state);
}

test "BLE 4.0: GAP: advertising stopped event on connection" {
    var g = gap.Gap.init();
    try g.startAdvertising(.{});
    while (g.nextCommand()) |_| {}

    g.handleEvent(.{ .le_connection_complete = .{
        .status = .success, .conn_handle = 1, .role = 1,
        .peer_addr_type = .public, .peer_addr = .{ 0, 0, 0, 0, 0, 0 },
        .conn_interval = 6, .conn_latency = 0, .supervision_timeout = 200,
    } });

    const evt1 = g.pollEvent() orelse unreachable;
    try std.testing.expect(std.meta.activeTag(evt1) == .advertising_stopped);
    const evt2 = g.pollEvent() orelse unreachable;
    try std.testing.expect(std.meta.activeTag(evt2) == .connected);
}

test "BLE 4.0: GAP: mutual exclusion of states" {
    var g = gap.Gap.init();
    try g.startAdvertising(.{});
    try std.testing.expectError(error.InvalidState, g.startScanning(.{}));
    try std.testing.expectError(error.InvalidState, g.disconnect(0, 0x13));
    try g.stopAdvertising();

    try g.startScanning(.{});
    try std.testing.expectError(error.InvalidState, g.startAdvertising(.{}));
    try std.testing.expectError(error.InvalidState, g.disconnect(0, 0x13));
}

// ============================================================================
// BLE 4.0: GATT Server — Vol 3 Part G
// ============================================================================

test "BLE 4.0: GATT: comptime service table attr count" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{
            gatt.Char(0x2A37, .{ .read = true, .notify = true }),
            gatt.Char(0x2A38, .{ .read = true }),
        }),
    });
    try std.testing.expectEqual(@as(usize, 2), S.char_count);
    // svc_decl(1) + chr_decl(1) + chr_val(1) + cccd(1) + chr_decl(1) + chr_val(1) = 6
    try std.testing.expectEqual(@as(usize, 6), S.attr_count);
}

test "BLE 4.0: GATT: handle assignment sequential starting at 1" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true }) }),
    });
    try std.testing.expectEqual(@as(u16, 3), S.getValueHandle(0x180D, 0x2A37));
}

test "BLE 4.0: GATT: multi-service handle assignment" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true }) }), // 1,2,3
        gatt.Service(0xFFE0, &.{ gatt.Char(0xFFE1, .{ .write = true }) }), // 4,5,6
    });
    try std.testing.expectEqual(@as(u16, 3), S.getValueHandle(0x180D, 0x2A37));
    try std.testing.expectEqual(@as(u16, 6), S.getValueHandle(0xFFE0, 0xFFE1));
}

test "BLE 4.0: GATT: CCCD adds one handle for notify char" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{
            gatt.Char(0x2A37, .{ .read = true, .notify = true }), // decl=2, val=3, cccd=4
            gatt.Char(0x2A38, .{ .read = true }),                  // decl=5, val=6
        }),
    });
    try std.testing.expectEqual(@as(u16, 3), S.getValueHandle(0x180D, 0x2A37));
    try std.testing.expectEqual(@as(u16, 6), S.getValueHandle(0x180D, 0x2A38));
}

test "BLE 4.0: GATT: read dispatch calls handler" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true }) }),
    });
    var server = S.init();
    server.handle(0x180D, 0x2A37, struct {
        pub fn serve(_: *gatt.Request, w: *gatt.ResponseWriter) void {
            w.write(&[_]u8{ 0xDE, 0xAD });
        }
    }.serve, null);

    var req: [3]u8 = undefined;
    req[0] = 0x0A;
    std.mem.writeInt(u16, req[1..3], S.getValueHandle(0x180D, 0x2A37), .little);
    var resp: [att.MAX_PDU_LEN]u8 = undefined;
    const r = server.handlePdu(0x40, &req, &resp) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x0B), r[0]); // Read Response
    try std.testing.expectEqual(@as(u8, 0xDE), r[1]);
}

test "BLE 4.0: GATT: write dispatch calls handler" {
    const S = gatt.GattServer(&.{
        gatt.Service(0xFFE0, &.{ gatt.Char(0xFFE1, .{ .write = true }) }),
    });
    var server = S.init();
    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(_: *gatt.Request, w: *gatt.ResponseWriter) void { w.ok(); }
    }.serve, null);

    var req: [5]u8 = undefined;
    req[0] = 0x12;
    std.mem.writeInt(u16, req[1..3], S.getValueHandle(0xFFE0, 0xFFE1), .little);
    req[3] = 0xAA;
    req[4] = 0xBB;
    var resp: [att.MAX_PDU_LEN]u8 = undefined;
    const r = server.handlePdu(0x40, &req, &resp) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x13), r[0]); // Write Response
}

test "BLE 4.0: GATT: MTU exchange response" {
    const S = gatt.GattServer(&.{ gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true }) }) });
    var server = S.init();

    var req: [3]u8 = undefined;
    req[0] = 0x02;
    std.mem.writeInt(u16, req[1..3], 247, .little);
    var resp: [att.MAX_PDU_LEN]u8 = undefined;
    const r = server.handlePdu(0x40, &req, &resp) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x03), r[0]); // MTU Response
    try std.testing.expectEqual(@as(u16, 247), server.mtu);
}

test "BLE 4.0: GATT: CCCD write enables notify" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true, .notify = true }) }),
    });
    var server = S.init();
    try std.testing.expect(!server.isNotifyEnabled(0x180D, 0x2A37));

    // Write CCCD = 0x0001
    const cccd_handle = S.getValueHandle(0x180D, 0x2A37) + 1;
    var req: [5]u8 = undefined;
    req[0] = 0x12;
    std.mem.writeInt(u16, req[1..3], cccd_handle, .little);
    req[3] = 0x01;
    req[4] = 0x00;
    var resp: [att.MAX_PDU_LEN]u8 = undefined;
    _ = server.handlePdu(0x40, &req, &resp);

    try std.testing.expect(server.isNotifyEnabled(0x180D, 0x2A37));
}

test "BLE 4.0: GATT: CCCD write disables notify" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true, .notify = true }) }),
    });
    var server = S.init();

    // Enable then disable
    const cccd_handle = S.getValueHandle(0x180D, 0x2A37) + 1;
    var req: [5]u8 = undefined;
    req[0] = 0x12;
    std.mem.writeInt(u16, req[1..3], cccd_handle, .little);
    var resp: [att.MAX_PDU_LEN]u8 = undefined;

    req[3] = 0x01;
    req[4] = 0x00;
    _ = server.handlePdu(0x40, &req, &resp);
    try std.testing.expect(server.isNotifyEnabled(0x180D, 0x2A37));

    req[3] = 0x00;
    req[4] = 0x00;
    _ = server.handlePdu(0x40, &req, &resp);
    try std.testing.expect(!server.isNotifyEnabled(0x180D, 0x2A37));
}

test "BLE 4.0: GATT: service discovery via Read By Group Type" {
    const S = gatt.GattServer(&.{
        gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true }) }),
        gatt.Service(0xFFE0, &.{ gatt.Char(0xFFE1, .{ .write = true }) }),
    });
    var server = S.init();

    var req: [7]u8 = undefined;
    req[0] = 0x10;
    std.mem.writeInt(u16, req[1..3], 0x0001, .little);
    std.mem.writeInt(u16, req[3..5], 0xFFFF, .little);
    std.mem.writeInt(u16, req[5..7], 0x2800, .little);

    var resp: [att.MAX_PDU_LEN]u8 = undefined;
    const r = server.handlePdu(0x40, &req, &resp) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x11), r[0]); // Read By Group Type Response
    try std.testing.expectEqual(@as(u8, 6), r[1]); // entry len = 2+2+2
    try std.testing.expect(r.len >= 8); // at least one entry
}

test "BLE 4.0: GATT: unsupported opcode returns error" {
    const S = gatt.GattServer(&.{ gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true }) }) });
    var server = S.init();

    var req: [5]u8 = .{ 0x0E, 0x03, 0x00, 0x04, 0x00 }; // Read Multiple (unsupported)
    var resp: [att.MAX_PDU_LEN]u8 = undefined;
    const r = server.handlePdu(0x40, &req, &resp) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), r[0]); // Error Response
}

test "BLE 4.0: GATT: read unknown handle returns attribute not found" {
    const S = gatt.GattServer(&.{ gatt.Service(0x180D, &.{ gatt.Char(0x2A37, .{ .read = true }) }) });
    var server = S.init();

    var req: [3]u8 = undefined;
    req[0] = 0x0A;
    std.mem.writeInt(u16, req[1..3], 0xFF, .little); // nonexistent handle
    var resp: [att.MAX_PDU_LEN]u8 = undefined;
    const r = server.handlePdu(0x40, &req, &resp) orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x01), r[0]); // Error Response
    try std.testing.expectEqual(@as(u8, 0x0A), r[4]); // Attribute Not Found
}

// ============================================================================
// BLE 4.0: GATT Client Types
// ============================================================================

test "BLE 4.0: GATT Client: AttResponse from Read Response" {
    const resp = gatt_client.AttResponse.fromPdu(&[_]u8{ 0x0B, 0xAA, 0xBB, 0xCC });
    try std.testing.expectEqual(att.Opcode.read_response, resp.opcode);
    try std.testing.expect(!resp.isError());
    try std.testing.expectEqual(@as(usize, 3), resp.len);
}

test "BLE 4.0: GATT Client: AttResponse from Error Response" {
    const resp = gatt_client.AttResponse.fromPdu(&[_]u8{ 0x01, 0x0A, 0x15, 0x00, 0x0A });
    try std.testing.expect(resp.isError());
    try std.testing.expectEqual(att.ErrorCode.attribute_not_found, resp.err.?);
}

test "BLE 4.0: GATT Client: AttResponse from Write Response" {
    const resp = gatt_client.AttResponse.fromPdu(&[_]u8{0x13});
    try std.testing.expectEqual(att.Opcode.write_response, resp.opcode);
    try std.testing.expect(!resp.isError());
    try std.testing.expectEqual(@as(usize, 0), resp.len);
}

test "BLE 4.0: GATT Client: AttResponse from MTU Response" {
    const resp = gatt_client.AttResponse.fromPdu(&[_]u8{ 0x03, 0x00, 0x02 });
    try std.testing.expectEqual(att.Opcode.exchange_mtu_response, resp.opcode);
    try std.testing.expect(!resp.isError());
    try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, resp.data[0..2], .little));
}

test "BLE 4.0: GATT Client: AttResponse from empty PDU" {
    const resp = gatt_client.AttResponse.fromPdu(&[_]u8{});
    try std.testing.expectEqual(att.Opcode.error_response, resp.opcode);
    try std.testing.expectEqual(@as(usize, 0), resp.len);
}

// ============================================================================
// BLE 4.0: Host — TxPacket
// ============================================================================

test "BLE 4.0: Host: TxPacket isCommand for HCI command" {
    const pkt = host_mod.TxPacket.fromSlice(&[_]u8{ 0x01, 0x03, 0x0C, 0x00 });
    try std.testing.expect(pkt.isCommand());
    try std.testing.expect(!pkt.isAclData());
}

test "BLE 4.0: Host: TxPacket isAclData for ACL data" {
    const pkt = host_mod.TxPacket.fromSlice(&[_]u8{ 0x02, 0x40, 0x20, 0x07, 0x00 });
    try std.testing.expect(!pkt.isCommand());
    try std.testing.expect(pkt.isAclData());
}

test "BLE 4.0: Host: TxPacket fromSlice preserves data" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    const pkt = host_mod.TxPacket.fromSlice(&data);
    try std.testing.expectEqual(@as(usize, 5), pkt.len);
    try std.testing.expectEqualSlices(u8, &data, pkt.slice());
}

// ============================================================================
// BLE 4.2: DLE — Vol 6 Part B 4.5.10
// ============================================================================

test "BLE 4.2: DLE: Set Data Length command (Vol 4 Part E 7.8.33)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetDataLength(&buf, 0x0040, 251, 2120);
    try std.testing.expectEqual(@as(u16, 0x2022), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
    try std.testing.expectEqual(@as(u8, 6), pkt[3]);
}

test "BLE 4.2: DLE: Data Length Change event (Vol 4 Part E 7.7.65.7)" {
    const raw = [_]u8{ 0x3E, 0x0B, 0x07, 0x40, 0x00, 0xFB, 0x00, 0x48, 0x08, 0xFB, 0x00, 0x48, 0x08 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_data_length_change => |dl| {
            try std.testing.expectEqual(@as(u16, 251), dl.max_tx_octets);
            try std.testing.expectEqual(@as(u16, 2120), dl.max_tx_time);
            try std.testing.expectEqual(@as(u16, 251), dl.max_rx_octets);
        },
        else => unreachable,
    }
}

test "BLE 4.2: DLE: L2CAP reassembly 3 fragments for MTU 512" {
    var reasm = l2cap.Reassembler{};
    var full: [516]u8 = undefined;
    std.mem.writeInt(u16, full[0..2], 512, .little);
    std.mem.writeInt(u16, full[2..4], l2cap.CID_ATT, .little);
    for (4..516) |i| full[i] = @truncate(i);

    // Frag 1: 251 bytes
    const h1 = acl.AclHeader{ .conn_handle = 0x40, .pb_flag = .first_auto_flush, .bc_flag = .point_to_point, .data_len = 251 };
    try std.testing.expect(reasm.feed(h1, full[0..251]) == null);

    // Frag 2: 251 bytes
    const h2 = acl.AclHeader{ .conn_handle = 0x40, .pb_flag = .continuing, .bc_flag = .point_to_point, .data_len = 251 };
    try std.testing.expect(reasm.feed(h2, full[251..502]) == null);

    // Frag 3: 14 bytes → complete
    const h3 = acl.AclHeader{ .conn_handle = 0x40, .pb_flag = .continuing, .bc_flag = .point_to_point, .data_len = 14 };
    const sdu = reasm.feed(h3, full[502..516]) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 512), sdu.data.len);
}

test "BLE 4.2: DLE: fragment iterator with DLE 251" {
    var sdu_buf: [acl.LE_MAX_DATA_LEN + l2cap.HEADER_LEN]u8 = undefined;
    // 100 bytes payload → 104 with L2CAP header → 1 fragment (< 251)
    var iter = l2cap.fragmentIterator(&sdu_buf, &([_]u8{0xAA} ** 100), l2cap.CID_ATT, 0x40, 251);
    try std.testing.expect(iter.next() != null);
    try std.testing.expect(iter.next() == null);
}

test "BLE 4.2: DLE: GAP requestDataLength generates command" {
    var g = gap.Gap.init();
    g.state = .connected;
    g.conn_handle = 0x0040;
    try g.requestDataLength(0x0040, 251, 2120);
    const cmd = g.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x22), cmd.data[1]);
}

// ============================================================================
// BLE 5.0: 2M PHY — Vol 6 Part B 2.2
// ============================================================================

test "BLE 5.0: PHY: Set PHY command (Vol 4 Part E 7.8.49)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetPhy(&buf, 0x0040, 0x00, 0x02, 0x02, 0x0000);
    try std.testing.expectEqual(@as(u16, 0x2032), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
    try std.testing.expectEqual(@as(u8, 7), pkt[3]); // param len
}

test "BLE 5.0: PHY: Set Default PHY (Vol 4 Part E 7.8.48)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leSetDefaultPhy(&buf, 0x00, 0x03, 0x03);
    try std.testing.expectEqual(@as(u16, 0x2031), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
    try std.testing.expectEqual(@as(u8, 0x03), pkt[5]); // tx_phys = 1M+2M
}

test "BLE 5.0: PHY: Read PHY (Vol 4 Part E 7.8.47)" {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const pkt = commands.leReadPhy(&buf, 0x0040);
    try std.testing.expectEqual(@as(u16, 0x2030), @as(u16, pkt[1]) | (@as(u16, pkt[2]) << 8));
}

test "BLE 5.0: PHY: PHY Update Complete event (Vol 4 Part E 7.7.65.12)" {
    const raw = [_]u8{ 0x3E, 0x06, 0x0C, 0x00, 0x40, 0x00, 0x02, 0x02 };
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_phy_update_complete => |pu| {
            try std.testing.expect(pu.status.isSuccess());
            try std.testing.expectEqual(@as(u8, 2), pu.tx_phy); // 2M
            try std.testing.expectEqual(@as(u8, 2), pu.rx_phy);
        },
        else => unreachable,
    }
}

test "BLE 5.0: PHY: PHY Update failure" {
    const raw = [_]u8{ 0x3E, 0x06, 0x0C, 0x23, 0x40, 0x00, 0x01, 0x01 }; // status=0x23
    const evt = events.decode(&raw) orelse unreachable;
    switch (evt) {
        .le_phy_update_complete => |pu| {
            try std.testing.expect(!pu.status.isSuccess());
            try std.testing.expectEqual(@as(u8, 1), pu.tx_phy); // stayed at 1M
        },
        else => unreachable,
    }
}

test "BLE 5.0: GAP: requestPhyUpdate generates command" {
    var g = gap.Gap.init();
    g.state = .connected;
    g.conn_handle = 0x0040;
    try g.requestPhyUpdate(0x0040, 0x02, 0x02);
    const cmd = g.nextCommand() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x32), cmd.data[1]);
}

test "BLE 5.0: GAP: PHY update event forwarded" {
    var g = gap.Gap.init();
    g.state = .connected;
    g.handleEvent(.{ .le_phy_update_complete = .{ .status = .success, .conn_handle = 0x40, .tx_phy = 2, .rx_phy = 2 } });
    const evt = g.pollEvent() orelse unreachable;
    switch (evt) {
        .phy_updated => |pu| {
            try std.testing.expectEqual(@as(u8, 2), pu.tx_phy);
        },
        else => unreachable,
    }
}

test "BLE 5.0: GAP: DLE event forwarded" {
    var g = gap.Gap.init();
    g.state = .connected;
    g.handleEvent(.{ .le_data_length_change = .{
        .conn_handle = 0x40, .max_tx_octets = 251, .max_tx_time = 2120,
        .max_rx_octets = 251, .max_rx_time = 2120,
    } });
    const evt = g.pollEvent() orelse unreachable;
    try std.testing.expect(std.meta.activeTag(evt) == .data_length_changed);
}
