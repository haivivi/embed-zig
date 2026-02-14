//! OutputFilter - Packet loss resilience wrappers for KCP output.
//!
//! Wraps KCP's raw output callback with two orthogonal strategies:
//!
//! 1. **Redundant ACK**: Detects ACK-only packets (small, critical for window
//!    advancement) and sends them multiple times. ACK packets are ~24 bytes
//!    each, so the overhead is negligible.
//!
//! 2. **FEC**: Groups data packets and adds XOR parity for single-loss recovery
//!    per group. Overhead is 1/N (e.g., N=3 → 33%).
//!
//! These can be combined: redundant ACK handles ACK loss, FEC handles data loss.

const std = @import("std");
const kcp_mod = @import("kcp.zig");
const fec_mod = @import("fec.zig");

/// Configuration for the output filter.
pub const Config = struct {
    /// Number of times to send ACK-only packets (1 = no redundancy, 3 recommended).
    ack_repeat: u8 = 1,
    /// FEC group size (0 = disabled, 3-5 recommended). Generates 1 parity per N data packets.
    fec_group_size: u8 = 0,
};

/// An output callback wrapper that applies redundant ACK and/or FEC.
///
/// Usage:
///   1. Create a Filter with the desired config and the real output callback
///   2. Pass Filter.kcpOutputCallback as the KCP output function
///   3. Set the Filter pointer as the KCP user data
pub const Filter = struct {
    config: Config,
    real_output: *const fn ([]const u8, ?*anyopaque) void,
    real_user_data: ?*anyopaque,
    fec_encoder: ?fec_mod.Encoder,

    pub fn init(
        config: Config,
        real_output: *const fn ([]const u8, ?*anyopaque) void,
        real_user_data: ?*anyopaque,
    ) Filter {
        const fec_enc = if (config.fec_group_size > 1)
            fec_mod.Encoder.init(config.fec_group_size, real_output, real_user_data)
        else
            null;

        return .{
            .config = config,
            .real_output = real_output,
            .real_user_data = real_user_data,
            .fec_encoder = fec_enc,
        };
    }

    /// Process an output packet from KCP.
    pub fn send(self: *Filter, data: []const u8) void {
        const is_ack = kcp_mod.Kcp.isAckOnly(data);

        if (is_ack and self.config.ack_repeat > 1) {
            // Redundant ACK: send multiple copies directly (bypass FEC)
            for (0..self.config.ack_repeat) |_| {
                self.real_output(data, self.real_user_data);
            }
            return;
        }

        if (self.fec_encoder) |*enc| {
            // FEC: buffer for parity generation
            enc.addPacket(data);
        } else {
            // Pass through
            self.real_output(data, self.real_user_data);
        }
    }

    /// Flush any partial FEC group.
    pub fn flush(self: *Filter) void {
        if (self.fec_encoder) |*enc| {
            enc.flushPartial();
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Filter passthrough (no redundancy, no FEC)" {
    const Ctx = struct {
        var count: usize = 0;
        fn output(_: []const u8, _: ?*anyopaque) void {
            count += 1;
        }
    };
    Ctx.count = 0;

    var filter = Filter.init(.{}, Ctx.output, null);
    filter.send("test data");
    filter.send("more data");
    try std.testing.expectEqual(@as(usize, 2), Ctx.count);
}

test "Filter redundant ACK sends multiple copies" {
    const Ctx = struct {
        var count: usize = 0;
        fn output(_: []const u8, _: ?*anyopaque) void {
            count += 1;
        }
    };
    Ctx.count = 0;

    var filter = Filter.init(.{ .ack_repeat = 3 }, Ctx.output, null);

    // Craft an ACK-only packet (cmd=82 at offset 4, no data)
    var ack_pkt: [kcp_mod.SegmentHeaderSize]u8 = .{0} ** kcp_mod.SegmentHeaderSize;
    ack_pkt[4] = kcp_mod.IKCP_CMD_ACK;

    filter.send(&ack_pkt);
    try std.testing.expectEqual(@as(usize, 3), Ctx.count); // 3 copies

    // Non-ACK packet should be sent once
    var data_pkt: [kcp_mod.SegmentHeaderSize + 10]u8 = .{0} ** (kcp_mod.SegmentHeaderSize + 10);
    data_pkt[4] = kcp_mod.IKCP_CMD_PUSH;
    std.mem.writeInt(u32, data_pkt[20..24], 10, .little); // seg len = 10

    Ctx.count = 0;
    filter.send(&data_pkt);
    try std.testing.expectEqual(@as(usize, 1), Ctx.count);
}

test "Filter FEC wraps data packets" {
    const Ctx = struct {
        var count: usize = 0;
        fn output(_: []const u8, _: ?*anyopaque) void {
            count += 1;
        }
    };
    Ctx.count = 0;

    var filter = Filter.init(.{ .fec_group_size = 3 }, Ctx.output, null);

    // Send 3 data packets → FEC should emit 4 (3 data + 1 parity)
    filter.send("pkt1");
    filter.send("pkt2");
    filter.send("pkt3");

    try std.testing.expectEqual(@as(usize, 4), Ctx.count);
}
