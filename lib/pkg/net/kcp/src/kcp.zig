//! KCP - A Fast and Reliable ARQ Protocol
//!
//! Zig bindings for the KCP C library with packet loss resilience extensions.
//!
//! ## Core
//! - `Kcp`: Thin wrapper around ikcp C library
//! - `Frame`: Multiplexing frame encoding/decoding
//! - `Cmd`: Frame command types
//!
//! ## Packet Loss Resilience
//! - `fec`: Forward Error Correction (XOR parity)
//!
//! ## Usage
//!
//! ```zig
//! const kcp = @import("kcp");
//!
//! // Create KCP instance
//! var k = try kcp.Kcp.init(conv_id, outputCallback, user_data);
//! defer k.deinit();
//! k.setDefaultConfig();
//!
//! // Send/receive
//! _ = k.send(data);
//! k.update(current_ms);
//! const n = k.recv(buffer);
//! ```

const std = @import("std");

pub const fec = @import("fec.zig");
pub const ring_buffer = @import("ring_buffer.zig");
pub const stream_mod = @import("stream.zig");
pub const output_filter = @import("output_filter.zig");

pub const loss_test = @import("loss_test.zig");

pub const Filter = output_filter.Filter;
pub const FilterConfig = output_filter.Config;

pub const RingBuffer = ring_buffer.RingBuffer;
pub const Stream = stream_mod.Stream;
pub const Mux = stream_mod.Mux;
pub const StreamState = stream_mod.StreamState;
pub const StreamError = stream_mod.StreamError;
pub const MuxConfig = stream_mod.MuxConfig;
pub const MuxError = stream_mod.MuxError;
pub const OutputFn = stream_mod.OutputFn;
pub const OnNewStreamFn = stream_mod.OnNewStreamFn;

const c = @cImport({
    @cInclude("ikcp.h");
});

// =============================================================================
// KCP segment header constants (from ikcp.h)
// =============================================================================

/// KCP segment header size (24 bytes):
/// conv(4) + cmd(1) + frg(1) + wnd(2) + ts(4) + sn(4) + una(4) + len(4)
pub const SegmentHeaderSize: usize = 24;

/// KCP command types (from ikcp.h)
pub const IKCP_CMD_PUSH: u8 = 81;
pub const IKCP_CMD_ACK: u8 = 82;
pub const IKCP_CMD_WASK: u8 = 83;
pub const IKCP_CMD_WANS: u8 = 84;

// =============================================================================
// Kcp — Thin wrapper around the C library
// =============================================================================

/// KCP control block wrapper.
///
/// Provides a safe Zig interface to the ikcp C library. The output callback
/// is invoked whenever KCP needs to send a packet to the lower layer (UDP).
pub const Kcp = struct {
    kcp: *c.ikcpcb,
    output_fn: ?*const fn ([]const u8, ?*anyopaque) void,
    user_data: ?*anyopaque,

    /// Create a stack-allocated KCP instance.
    ///
    /// After calling init(), you MUST call setUserPtr() on a stable pointer
    /// (e.g., after moving to heap or embedding in a struct) before any
    /// output callback can fire.
    ///
    /// Prefer create() for heap allocation with automatic user pointer setup.
    pub fn init(conv: u32, output_fn: ?*const fn ([]const u8, ?*anyopaque) void, user_data: ?*anyopaque) !Kcp {
        var self = Kcp{
            .kcp = undefined,
            .output_fn = output_fn,
            .user_data = user_data,
        };

        const kcp_ptr = c.ikcp_create(conv, null) orelse return error.KcpCreateFailed;
        self.kcp = kcp_ptr;

        _ = c.ikcp_setoutput(kcp_ptr, kcpOutputCallback);

        return self;
    }

    /// Create a heap-allocated KCP instance with user pointer automatically set.
    ///
    /// This is the preferred factory function as it ensures correct initialization
    /// in one step — the output callback will work immediately.
    pub fn create(allocator: std.mem.Allocator, conv: u32, output_fn: ?*const fn ([]const u8, ?*anyopaque) void, user_data: ?*anyopaque) !*Kcp {
        const self = try allocator.create(Kcp);
        errdefer allocator.destroy(self);

        self.* = Kcp{
            .kcp = undefined,
            .output_fn = output_fn,
            .user_data = user_data,
        };

        const kcp_ptr = c.ikcp_create(conv, null) orelse return error.KcpCreateFailed;
        self.kcp = kcp_ptr;

        _ = c.ikcp_setoutput(kcp_ptr, kcpOutputCallback);
        self.kcp.*.user = @ptrCast(self);

        return self;
    }

    /// Set the user pointer for callbacks. Must be called after init() if
    /// the callback needs to access this Kcp instance.
    ///
    /// Not needed if using create() factory function.
    pub fn setUserPtr(self: *Kcp) void {
        self.kcp.*.user = @ptrCast(self);
    }

    /// Release the KCP control block.
    pub fn deinit(self: *Kcp) void {
        c.ikcp_release(self.kcp);
        self.* = undefined;
    }

    /// Set nodelay mode for fast transmission.
    ///
    /// - nodelay: 0 = disable, 1 = enable, 2 = aggressive (fixed RTO increment)
    /// - interval: Internal update interval in ms (1-100ms recommended)
    /// - resend: Fast resend trigger (0 = disable, 2 = recommended)
    /// - nc: Disable congestion control (0 = enable, 1 = disable)
    pub fn setNodelay(self: *Kcp, nodelay: i32, interval: i32, resend: i32, nc: i32) void {
        _ = c.ikcp_nodelay(self.kcp, nodelay, interval, resend, nc);
    }

    /// Set send and receive window sizes.
    pub fn setWndSize(self: *Kcp, sndwnd: i32, rcvwnd: i32) void {
        _ = c.ikcp_wndsize(self.kcp, sndwnd, rcvwnd);
    }

    /// Set MTU (Maximum Transmission Unit).
    pub fn setMtu(self: *Kcp, mtu: i32) void {
        _ = c.ikcp_setmtu(self.kcp, mtu);
    }

    /// Apply default fast mode configuration.
    ///
    /// Settings: nodelay=2 (aggressive RTO), interval=1ms, resend=2 (fast retransmit
    /// on 2 dup acks), nc=1 (no congestion window), wnd=4096, mtu=1400.
    pub fn setDefaultConfig(self: *Kcp) void {
        self.setNodelay(2, 1, 2, 1);
        self.setWndSize(4096, 4096);
        self.setMtu(1400);
    }

    /// Send data through KCP (upper layer send).
    /// Returns number of bytes queued, or negative on error.
    pub fn send(self: *Kcp, data: []const u8) i32 {
        return c.ikcp_send(self.kcp, data.ptr, @intCast(data.len));
    }

    /// Receive data from KCP (upper layer recv).
    /// Returns number of bytes received, or negative if no data available.
    pub fn recv(self: *Kcp, buffer: []u8) i32 {
        return c.ikcp_recv(self.kcp, buffer.ptr, @intCast(buffer.len));
    }

    /// Input data from lower layer (e.g., UDP).
    /// Returns 0 on success, negative on error.
    pub fn input(self: *Kcp, data: []const u8) i32 {
        return c.ikcp_input(self.kcp, data.ptr, @intCast(data.len));
    }

    /// Update KCP state. Must be called periodically.
    /// current: Current time in milliseconds.
    pub fn update(self: *Kcp, current: u32) void {
        c.ikcp_update(self.kcp, current);
    }

    /// Check when to call update next.
    /// Returns next update time in milliseconds.
    pub fn check(self: *Kcp, current: u32) u32 {
        return c.ikcp_check(self.kcp, current);
    }

    /// Flush pending data immediately.
    pub fn flush(self: *Kcp) void {
        c.ikcp_flush(self.kcp);
    }

    /// Get number of packets waiting to be sent.
    pub fn waitSnd(self: *Kcp) i32 {
        return c.ikcp_waitsnd(self.kcp);
    }

    /// Peek at the size of the next available message.
    /// Returns size in bytes, or negative if no message available.
    pub fn peekSize(self: *Kcp) i32 {
        return c.ikcp_peeksize(self.kcp);
    }

    /// Get the connection ID.
    pub fn getConv(self: *const Kcp) u32 {
        return self.kcp.*.conv;
    }

    /// Check if output data is an ACK-only packet.
    ///
    /// Inspects KCP segment headers to determine if all segments in the packet
    /// are ACK commands. Used by loss resilience layers to apply redundant ACK.
    pub fn isAckOnly(data: []const u8) bool {
        var offset: usize = 0;
        while (offset + SegmentHeaderSize <= data.len) {
            const cmd = data[offset + 4]; // cmd is at byte offset 4
            if (cmd != IKCP_CMD_ACK) return false;
            // Read segment data length (little-endian u32 at offset 20)
            const seg_len = std.mem.readInt(u32, data[offset + 20 ..][0..4], .little);
            offset += SegmentHeaderSize + seg_len;
        }
        return offset > 0;
    }

    /// KCP output callback (called by C library).
    fn kcpOutputCallback(buf: [*c]const u8, len: c_int, _: [*c]c.ikcpcb, user: ?*anyopaque) callconv(.c) c_int {
        if (user) |u| {
            const self: *Kcp = @ptrCast(@alignCast(u));
            if (self.output_fn) |output| {
                const data = buf[0..@intCast(len)];
                output(data, self.user_data);
            }
        }
        return 0;
    }
};

/// Extract the conversation ID from a raw KCP packet.
pub fn getConvFromPacket(data: []const u8) u32 {
    if (data.len < 4) return 0;
    return std.mem.readInt(u32, data[0..4], .little);
}

// =============================================================================
// Frame — Multiplexing frame encoding/decoding
// =============================================================================

/// Frame command types for stream multiplexing.
pub const Cmd = enum(u8) {
    syn = 0x01, // Stream open
    fin = 0x02, // Stream close
    psh = 0x03, // Data
    nop = 0x04, // Keepalive

    pub fn fromByte(byte: u8) ?Cmd {
        return switch (byte) {
            0x01 => .syn,
            0x02 => .fin,
            0x03 => .psh,
            0x04 => .nop,
            else => null,
        };
    }
};

/// Frame header size: cmd(1) + stream_id(4) + length(2) = 7 bytes.
pub const FrameHeaderSize: usize = 7;

/// Maximum payload size per frame.
pub const MaxPayloadSize: usize = 65535;

/// A multiplexed stream frame.
///
/// Frames are the unit of multiplexing: each frame carries a command (SYN, FIN,
/// PSH, NOP) for a specific stream_id, plus an optional payload.
pub const Frame = struct {
    cmd: Cmd,
    stream_id: u32,
    payload: []const u8,

    /// Encode frame into a pre-allocated buffer.
    pub fn encode(self: *const Frame, buffer: []u8) ![]u8 {
        const total_len = FrameHeaderSize + self.payload.len;
        if (buffer.len < total_len) return error.BufferTooSmall;
        if (self.payload.len > MaxPayloadSize) return error.PayloadTooLarge;

        buffer[0] = @intFromEnum(self.cmd);
        std.mem.writeInt(u32, buffer[1..5], self.stream_id, .little);
        std.mem.writeInt(u16, buffer[5..7], @intCast(self.payload.len), .little);

        if (self.payload.len > 0) {
            @memcpy(buffer[FrameHeaderSize..][0..self.payload.len], self.payload);
        }

        return buffer[0..total_len];
    }

    /// Encode frame and return heap-allocated slice.
    pub fn encodeAlloc(self: *const Frame, allocator: std.mem.Allocator) ![]u8 {
        const total_len = FrameHeaderSize + self.payload.len;
        const buffer = try allocator.alloc(u8, total_len);
        errdefer allocator.free(buffer);
        _ = try self.encode(buffer);
        return buffer;
    }

    /// Decode a frame from a byte slice.
    pub fn decode(data: []const u8) !Frame {
        if (data.len < FrameHeaderSize) return error.FrameTooShort;

        const cmd = Cmd.fromByte(data[0]) orelse return error.InvalidCmd;
        const stream_id = std.mem.readInt(u32, data[1..5], .little);
        const payload_len = std.mem.readInt(u16, data[5..7], .little);

        if (data.len < FrameHeaderSize + payload_len) return error.FrameTooShort;

        return Frame{
            .cmd = cmd,
            .stream_id = stream_id,
            .payload = data[FrameHeaderSize..][0..payload_len],
        };
    }

    /// Decode only the header, returning cmd, stream_id, and payload length.
    pub fn decodeHeader(data: []const u8) !struct { cmd: Cmd, stream_id: u32, payload_len: u16 } {
        if (data.len < FrameHeaderSize) return error.FrameTooShort;

        const cmd = Cmd.fromByte(data[0]) orelse return error.InvalidCmd;
        const stream_id = std.mem.readInt(u32, data[1..5], .little);
        const payload_len = std.mem.readInt(u16, data[5..7], .little);

        return .{
            .cmd = cmd,
            .stream_id = stream_id,
            .payload_len = payload_len,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

// Dummy output callback for tests that discard data.
fn dummyOutput(_: [*c]const u8, _: c_int, _: [*c]c.ikcpcb, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

test "Kcp basic init and config" {
    var kcp_inst = try Kcp.init(123, null, null);
    defer kcp_inst.deinit();

    kcp_inst.setUserPtr();
    kcp_inst.setDefaultConfig();

    try std.testing.expectEqual(@as(u32, 123), kcp_inst.getConv());
    try std.testing.expectEqual(@as(i32, 0), kcp_inst.waitSnd());
}

test "Kcp two instances independent" {
    var kcp_a = try Kcp.init(1, null, null);
    defer kcp_a.deinit();

    var kcp_b = try Kcp.init(1, null, null);
    defer kcp_b.deinit();

    kcp_a.setDefaultConfig();
    kcp_b.setDefaultConfig();

    try std.testing.expectEqual(@as(i32, 0), kcp_a.waitSnd());
    try std.testing.expectEqual(@as(i32, 0), kcp_b.waitSnd());
}

test "Kcp send queues data" {
    var kcp_a = try Kcp.init(1, null, null);
    defer kcp_a.deinit();
    kcp_a.setUserPtr();
    kcp_a.setNodelay(1, 10, 2, 1);
    kcp_a.setWndSize(128, 128);

    const data = "hello world from kcp";
    const send_ret = kcp_a.send(data);
    try std.testing.expect(send_ret >= 0);

    // Verify data was queued (without flushing)
    try std.testing.expect(kcp_a.waitSnd() > 0);
}

test "Kcp update flushes data" {
    // Use heap allocation so the Kcp pointer is stable for the output callback
    const allocator = std.testing.allocator;
    const kcp_a = try Kcp.create(allocator, 1, null, null);
    defer {
        kcp_a.deinit();
        allocator.destroy(kcp_a);
    }
    kcp_a.setNodelay(1, 10, 2, 1);
    kcp_a.setWndSize(128, 128);

    const data = "hello world from kcp";
    const send_ret = kcp_a.send(data);
    try std.testing.expect(send_ret >= 0);
    try std.testing.expect(kcp_a.waitSnd() > 0);

    // update() triggers flush which outputs packets
    kcp_a.update(100);
}

// Static buffer for roundtrip test output capture.
var roundtrip_buf: [8192]u8 = undefined;
var roundtrip_len: usize = 0;

fn roundtripOutput(buf: [*c]const u8, len: c_int, _: [*c]c.ikcpcb, _: ?*anyopaque) callconv(.c) c_int {
    const size: usize = @intCast(len);
    if (roundtrip_len + size <= roundtrip_buf.len) {
        @memcpy(roundtrip_buf[roundtrip_len..][0..size], buf[0..size]);
        roundtrip_len += size;
    }
    return 0;
}

test "Kcp full roundtrip A→B" {
    roundtrip_len = 0;

    const kcp_a = c.ikcp_create(1, null);
    defer c.ikcp_release(kcp_a);
    const kcp_b = c.ikcp_create(1, null);
    defer c.ikcp_release(kcp_b);

    _ = c.ikcp_nodelay(kcp_a, 1, 10, 2, 1);
    _ = c.ikcp_wndsize(kcp_a, 256, 256);
    _ = c.ikcp_nodelay(kcp_b, 1, 10, 2, 1);
    _ = c.ikcp_wndsize(kcp_b, 256, 256);

    _ = c.ikcp_setoutput(kcp_a, roundtripOutput);
    _ = c.ikcp_setoutput(kcp_b, dummyOutput);

    const data = "hello from A to B!";
    const send_ret = c.ikcp_send(kcp_a, data.ptr, @intCast(data.len));
    try std.testing.expect(send_ret >= 0);

    // update() internally calls flush()
    c.ikcp_update(kcp_a, 100);
    try std.testing.expect(roundtrip_len > 0);

    const input_ret = c.ikcp_input(kcp_b, &roundtrip_buf, @intCast(roundtrip_len));
    try std.testing.expect(input_ret >= 0);

    c.ikcp_update(kcp_b, 100);

    var recv_buf: [1024]u8 = undefined;
    const recv_ret = c.ikcp_recv(kcp_b, &recv_buf, recv_buf.len);
    try std.testing.expect(recv_ret > 0);

    const received = recv_buf[0..@intCast(recv_ret)];
    try std.testing.expectEqualStrings(data, received);
}

test "Kcp isAckOnly detection" {
    // Craft a fake ACK-only packet: one segment with cmd=82 (ACK), no data
    var buf: [SegmentHeaderSize]u8 = .{0} ** SegmentHeaderSize;
    buf[4] = IKCP_CMD_ACK; // cmd byte
    // seg_len at offset 20..24 is already 0 (no payload)
    try std.testing.expect(Kcp.isAckOnly(&buf));

    // Change cmd to PUSH — should not be ACK-only
    buf[4] = IKCP_CMD_PUSH;
    try std.testing.expect(!Kcp.isAckOnly(&buf));

    // Empty data — should not be ACK-only
    try std.testing.expect(!Kcp.isAckOnly(&[_]u8{}));
}

test "Frame encode decode roundtrip" {
    const allocator = std.testing.allocator;

    const frame = Frame{
        .cmd = .psh,
        .stream_id = 42,
        .payload = "hello",
    };

    const encoded = try frame.encodeAlloc(allocator);
    defer allocator.free(encoded);

    const decoded = try Frame.decode(encoded);

    try std.testing.expectEqual(Cmd.psh, decoded.cmd);
    try std.testing.expectEqual(@as(u32, 42), decoded.stream_id);
    try std.testing.expectEqualStrings("hello", decoded.payload);
}

test "Frame header decode" {
    var buffer: [7]u8 = undefined;
    const frame = Frame{
        .cmd = .syn,
        .stream_id = 100,
        .payload = "",
    };

    _ = try frame.encode(&buffer);
    const header = try Frame.decodeHeader(&buffer);

    try std.testing.expectEqual(Cmd.syn, header.cmd);
    try std.testing.expectEqual(@as(u32, 100), header.stream_id);
    try std.testing.expectEqual(@as(u16, 0), header.payload_len);
}

test "Frame decode too short" {
    const short = [_]u8{ 0x01, 0x02 };
    try std.testing.expectError(error.FrameTooShort, Frame.decode(&short));
}

test "Frame decode invalid cmd" {
    var buf: [7]u8 = .{0} ** 7;
    buf[0] = 0xFF; // invalid command
    try std.testing.expectError(error.InvalidCmd, Frame.decode(&buf));
}

test "Cmd fromByte" {
    try std.testing.expectEqual(Cmd.syn, Cmd.fromByte(0x01).?);
    try std.testing.expectEqual(Cmd.fin, Cmd.fromByte(0x02).?);
    try std.testing.expectEqual(Cmd.psh, Cmd.fromByte(0x03).?);
    try std.testing.expectEqual(Cmd.nop, Cmd.fromByte(0x04).?);
    try std.testing.expect(Cmd.fromByte(0x05) == null);
    try std.testing.expect(Cmd.fromByte(0x00) == null);
    try std.testing.expect(Cmd.fromByte(0xFF) == null);
}

test "getConvFromPacket" {
    // Little-endian conv=12345 (0x3039)
    var pkt: [SegmentHeaderSize]u8 = .{0} ** SegmentHeaderSize;
    std.mem.writeInt(u32, pkt[0..4], 12345, .little);
    try std.testing.expectEqual(@as(u32, 12345), getConvFromPacket(&pkt));

    // Too short
    try std.testing.expectEqual(@as(u32, 0), getConvFromPacket(&[_]u8{ 1, 2 }));
}

// Force test discovery in all sub-modules
comptime {
    _ = fec;
    _ = ring_buffer;
    _ = stream_mod;
    _ = output_filter;
    _ = loss_test;
}
