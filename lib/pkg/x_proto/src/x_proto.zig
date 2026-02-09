//! x_proto — BLE READ_X / WRITE_X Chunked Transfer Protocol
//!
//! A reliable chunked transfer protocol for BLE GATT characteristics.
//! Supports sending and receiving large data blocks over MTU-limited
//! BLE connections with loss detection and retransmission.
//!
//! ## Protocol Overview
//!
//! Two protocols work over a single GATT characteristic:
//!
//! - **READ_X** (Server → Client): Server sends data in chunks via notify/indicate.
//!   Client acknowledges or reports lost chunks for retransmission.
//!
//! - **WRITE_X** (Client → Server): Client writes data in chunks.
//!   Server tracks received chunks and requests retransmission of lost ones.
//!
//! ## Transport Interface
//!
//! Both `ReadX` and `WriteX` are generic over a `Transport` type that must provide:
//!
//! ```zig
//! fn send(self: *Transport, data: []const u8) !void
//! fn recv(self: *Transport, buf: []u8, timeout_ms: u32) !?usize
//! ```
//!
//! ## Example
//!
//! ```zig
//! const x_proto = @import("x_proto");
//!
//! // READ_X: Server sends data to client
//! var rx = x_proto.ReadX(MyTransport).init(&transport, data, .{ .mtu = 247 });
//! try rx.run();
//!
//! // WRITE_X: Server receives data from client
//! var buf: [4096]u8 = undefined;
//! var wx = x_proto.WriteX(MyTransport).init(&transport, &buf, .{ .mtu = 247 });
//! const result = try wx.run();
//! // result.data contains the received bytes
//! ```

// Re-export sub-modules
pub const chunk = @import("chunk.zig");
pub const read_x = @import("read_x.zig");
pub const write_x = @import("write_x.zig");

// Convenience aliases
pub fn ReadX(comptime Transport: type) type {
    return read_x.ReadX(Transport);
}

pub fn WriteX(comptime Transport: type) type {
    return write_x.WriteX(Transport);
}

// Re-export key types and constants
pub const Header = chunk.Header;
pub const Bitmask = chunk.Bitmask;
pub const start_magic = chunk.start_magic;
pub const ack_signal = chunk.ack_signal;
pub const dataChunkSize = chunk.dataChunkSize;
pub const chunksNeeded = chunk.chunksNeeded;

// ============================================================================
// Tests — pull in all sub-module tests
// ============================================================================

test {
    _ = chunk;
    _ = read_x;
    _ = write_x;
}

const std = @import("std");

// ============================================================================
// Mock Transport for Testing
// ============================================================================

/// A test transport that records sent messages and replays scripted responses.
/// Used for deterministic protocol testing without threads or real I/O.
const MockTransport = struct {
    const max_sent_data: usize = 16384;
    const max_sent_entries: usize = 256;
    const max_recv_entries: usize = 64;
    const max_recv_data: usize = 4096;

    // -- Sent data storage --
    sent_data: [max_sent_data]u8 = undefined,
    sent_lens: [max_sent_entries]usize = undefined,
    sent_count: usize = 0,
    sent_data_size: usize = 0,

    // -- Recv script storage --
    recv_items: [max_recv_entries]RecvItem = undefined,
    recv_count: usize = 0,
    recv_idx: usize = 0,
    recv_data_buf: [max_recv_data]u8 = undefined,
    recv_data_offset: usize = 0,

    const RecvItem = struct {
        offset: usize,
        len: usize,
        is_timeout: bool,
    };

    pub fn send(self: *MockTransport, data: []const u8) error{Overflow}!void {
        if (self.sent_count >= max_sent_entries) return error.Overflow;
        if (self.sent_data_size + data.len > max_sent_data) return error.Overflow;
        @memcpy(self.sent_data[self.sent_data_size .. self.sent_data_size + data.len], data);
        self.sent_lens[self.sent_count] = data.len;
        self.sent_count += 1;
        self.sent_data_size += data.len;
    }

    pub fn recv(self: *MockTransport, buf: []u8, timeout_ms: u32) error{Overflow}!?usize {
        _ = timeout_ms;
        if (self.recv_idx >= self.recv_count) return null;
        const item = self.recv_items[self.recv_idx];
        self.recv_idx += 1;
        if (item.is_timeout) return null;
        if (item.len > buf.len) return error.Overflow;
        @memcpy(buf[0..item.len], self.recv_data_buf[item.offset .. item.offset + item.len]);
        return item.len;
    }

    // ---- Test setup helpers ----

    fn scriptRecv(self: *MockTransport, data: []const u8) void {
        self.recv_items[self.recv_count] = .{
            .offset = self.recv_data_offset,
            .len = data.len,
            .is_timeout = false,
        };
        @memcpy(
            self.recv_data_buf[self.recv_data_offset .. self.recv_data_offset + data.len],
            data,
        );
        self.recv_data_offset += data.len;
        self.recv_count += 1;
    }

    fn scriptTimeout(self: *MockTransport) void {
        self.recv_items[self.recv_count] = .{ .offset = 0, .len = 0, .is_timeout = true };
        self.recv_count += 1;
    }

    fn getSent(self: *const MockTransport, idx: usize) []const u8 {
        var offset: usize = 0;
        for (self.sent_lens[0..idx]) |l| {
            offset += l;
        }
        return self.sent_data[offset .. offset + self.sent_lens[idx]];
    }
};

/// Helper: build a chunk packet (header + payload) into a buffer.
fn buildChunkPacket(buf: []u8, total: u16, seq: u16, payload: []const u8) []u8 {
    const hdr = (chunk.Header{ .total = total, .seq = seq }).encode();
    @memcpy(buf[0..chunk.header_size], &hdr);
    @memcpy(buf[chunk.header_size .. chunk.header_size + payload.len], payload);
    return buf[0 .. chunk.header_size + payload.len];
}

// ============================================================================
// ReadX Tests
// ============================================================================

test "ReadX: basic transfer with immediate ACK" {
    var mock = MockTransport{};
    mock.scriptRecv(&chunk.start_magic);
    mock.scriptRecv(&chunk.ack_signal);

    const data = "Hello, BLE World!";
    var rx = ReadX(MockTransport).init(&mock, data, .{
        .mtu = 50,
        .send_redundancy = 1,
    });
    try rx.run();

    // Verify correct number of chunks sent
    const dcs = chunk.dataChunkSize(50);
    const expected_chunks = chunk.chunksNeeded(data.len, 50);
    try std.testing.expectEqual(expected_chunks, mock.sent_count);

    // Verify first chunk header
    const first_sent = mock.getSent(0);
    const hdr = chunk.Header.decode(first_sent[0..chunk.header_size]);
    try std.testing.expectEqual(@as(u16, @intCast(expected_chunks)), hdr.total);
    try std.testing.expectEqual(@as(u16, 1), hdr.seq);

    // Verify first chunk payload
    const expected_payload_len = @min(data.len, dcs);
    try std.testing.expectEqualSlices(
        u8,
        data[0..expected_payload_len],
        first_sent[chunk.header_size..],
    );
}

test "ReadX: transfer with retransmission" {
    var mock = MockTransport{};
    mock.scriptRecv(&chunk.start_magic);

    // Client reports seq 2 as lost
    var loss_buf: [2]u8 = undefined;
    _ = chunk.encodeLossList(&.{2}, &loss_buf);
    mock.scriptRecv(&loss_buf);

    // Client ACKs after retransmit
    mock.scriptRecv(&chunk.ack_signal);

    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop";
    const mtu: u16 = 30;
    var rx = ReadX(MockTransport).init(&mock, data, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try rx.run();

    const total = chunk.chunksNeeded(data.len, mtu);
    // First round: all chunks + retransmit round: 1 chunk
    try std.testing.expectEqual(total + 1, mock.sent_count);

    // Verify retransmitted chunk is seq 2
    const retransmit = mock.getSent(total);
    const hdr = chunk.Header.decode(retransmit[0..chunk.header_size]);
    try std.testing.expectEqual(@as(u16, 2), hdr.seq);
}

test "ReadX: send redundancy sends each chunk N times" {
    var mock = MockTransport{};
    mock.scriptRecv(&chunk.start_magic);
    mock.scriptRecv(&chunk.ack_signal);

    const data = "Short";
    var rx = ReadX(MockTransport).init(&mock, data, .{
        .mtu = 50,
        .send_redundancy = 3,
    });
    try rx.run();

    // 1 chunk × 3 redundancy = 3 sends
    try std.testing.expectEqual(@as(usize, 3), mock.sent_count);

    // All 3 should be identical
    const first = mock.getSent(0);
    const second = mock.getSent(1);
    const third = mock.getSent(2);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqualSlices(u8, first, third);
}

test "ReadX: timeout waiting for start magic" {
    var mock = MockTransport{};
    mock.scriptTimeout();

    const data = "test";
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.Timeout, rx.run());
}

test "ReadX: invalid start magic" {
    var mock = MockTransport{};
    mock.scriptRecv(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });

    const data = "test";
    var rx = ReadX(MockTransport).init(&mock, data, .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.InvalidStartMagic, rx.run());
}

test "ReadX: empty data returns error" {
    var mock = MockTransport{};
    var rx = ReadX(MockTransport).init(&mock, "", .{ .mtu = 50, .send_redundancy = 1 });
    try std.testing.expectError(error.EmptyData, rx.run());
}

// ============================================================================
// WriteX Tests
// ============================================================================

test "WriteX: basic receive with immediate ACK" {
    const mtu: u16 = 50;
    const dcs = chunk.dataChunkSize(mtu);
    const data = "Hello from client! This is chunked data.";
    const total: u16 = @intCast(chunk.chunksNeeded(data.len, mtu));

    var mock = MockTransport{};

    // Script: client sends all chunks in order
    var i: u16 = 0;
    while (i < total) : (i += 1) {
        var pkt: [chunk.max_mtu]u8 = undefined;
        const seq: u16 = i + 1;
        const offset: usize = @as(usize, i) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);

    // Verify ACK was sent
    try std.testing.expectEqual(@as(usize, 1), mock.sent_count);
    try std.testing.expectEqualSlices(u8, &chunk.ack_signal, mock.getSent(0));
}

test "WriteX: receive with timeout and loss list" {
    const mtu: u16 = 30;
    const dcs = chunk.dataChunkSize(mtu);
    // Ensure exactly 2 chunks: 48 bytes / 24 dcs = 2
    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklm";
    const total: u16 = @intCast(chunk.chunksNeeded(data.len, mtu));
    try std.testing.expect(total >= 2); // sanity check

    var mock = MockTransport{};

    // Send chunk 1 only
    {
        var pkt: [chunk.max_mtu]u8 = undefined;
        const payload_len: usize = @min(data.len, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, 1, data[0..payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    // Timeout → server will send loss list
    mock.scriptTimeout();

    // Client retransmits remaining chunks (2..total)
    var seq: u16 = 2;
    while (seq <= total) : (seq += 1) {
        var pkt: [chunk.max_mtu]u8 = undefined;
        const offset: usize = @as(usize, seq - 1) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    // Verify data integrity
    try std.testing.expectEqualSlices(u8, data, result.data);

    // Verify loss list was sent (first), then ACK (second)
    try std.testing.expect(mock.sent_count >= 2);

    // Loss list should contain missing seqs
    const loss_msg = mock.getSent(0);
    try std.testing.expect(loss_msg.len >= 2);
    var decoded_seqs: [16]u16 = undefined;
    const decoded_count = chunk.decodeLossList(loss_msg, &decoded_seqs);
    try std.testing.expect(decoded_count >= 1);
    try std.testing.expectEqual(@as(u16, 2), decoded_seqs[0]); // seq 2 was missing

    // Last sent should be ACK
    try std.testing.expectEqualSlices(u8, &chunk.ack_signal, mock.getSent(mock.sent_count - 1));
}

test "WriteX: out-of-order chunks" {
    const mtu: u16 = 30;
    const dcs = chunk.dataChunkSize(mtu);
    const data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklm";
    const total: u16 = @intCast(chunk.chunksNeeded(data.len, mtu));

    var mock = MockTransport{};

    // Send chunks in reverse order
    var seq: u16 = total;
    while (seq >= 1) : (seq -= 1) {
        var pkt: [chunk.max_mtu]u8 = undefined;
        const offset: usize = @as(usize, seq - 1) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
        if (seq == 1) break; // avoid underflow
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
}

test "WriteX: timeout gives up after max retries" {
    var mock = MockTransport{};
    // Script: 6 consecutive timeouts (max_retries=5 → gives up on 6th)
    for (0..6) |_| {
        mock.scriptTimeout();
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{
        .mtu = 50,
        .max_retries = 5,
    });
    try std.testing.expectError(error.Timeout, wx.run());
}

test "WriteX: duplicate chunks are handled idempotently" {
    const mtu: u16 = 50;
    const dcs = chunk.dataChunkSize(mtu);
    const data = "Hello duplicate world!";
    const total: u16 = @intCast(chunk.chunksNeeded(data.len, mtu));

    var mock = MockTransport{};

    // Send chunk 1 three times, then remaining chunks
    for (0..3) |_| {
        var pkt: [chunk.max_mtu]u8 = undefined;
        const payload_len: usize = @min(data.len, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, 1, data[0..payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    // Send remaining chunks
    var seq: u16 = 2;
    while (seq <= total) : (seq += 1) {
        var pkt: [chunk.max_mtu]u8 = undefined;
        const offset: usize = @as(usize, seq - 1) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        const pkt_slice = buildChunkPacket(&pkt, total, seq, data[offset .. offset + payload_len]);
        mock.scriptRecv(pkt_slice);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    try std.testing.expectEqualSlices(u8, data, result.data);
}

// ============================================================================
// End-to-End Test
// ============================================================================

test "end-to-end: ReadX chunks → WriteX reassembly" {
    const mtu: u16 = 30;
    const data = "The quick brown fox jumps over the lazy dog. 0123456789!";

    // Step 1: Run ReadX to collect all chunk packets
    var read_mock = MockTransport{};
    read_mock.scriptRecv(&chunk.start_magic);
    read_mock.scriptRecv(&chunk.ack_signal);

    var rx = ReadX(MockTransport).init(&read_mock, data, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try rx.run();

    // Step 2: Feed ReadX's sent chunks into WriteX
    var write_mock = MockTransport{};
    for (0..read_mock.sent_count) |i| {
        const sent = read_mock.getSent(i);
        write_mock.scriptRecv(sent);
    }

    var recv_buf: [2048]u8 = undefined;
    var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
    const result = try wx.run();

    // Step 3: Verify round-trip data integrity
    try std.testing.expectEqualSlices(u8, data, result.data);
}

test "end-to-end: large data with multiple MTU sizes" {
    // Generate test data: 500 bytes
    var data: [500]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    // Test with different MTU sizes
    const mtus = [_]u16{ 23, 30, 50, 100, 247 };
    for (mtus) |mtu| {
        // ReadX
        var read_mock = MockTransport{};
        read_mock.scriptRecv(&chunk.start_magic);
        read_mock.scriptRecv(&chunk.ack_signal);

        var rx = ReadX(MockTransport).init(&read_mock, &data, .{
            .mtu = mtu,
            .send_redundancy = 1,
        });
        try rx.run();

        // WriteX
        var write_mock = MockTransport{};
        for (0..read_mock.sent_count) |i| {
            const sent = read_mock.getSent(i);
            write_mock.scriptRecv(sent);
        }

        var recv_buf: [2048]u8 = undefined;
        var wx = WriteX(MockTransport).init(&write_mock, &recv_buf, .{ .mtu = mtu });
        const result = try wx.run();

        try std.testing.expectEqualSlices(u8, &data, result.data);
    }
}
