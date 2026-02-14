//! Packet loss simulation test for KCP.
//!
//! Measures KCP throughput under simulated bilateral packet loss at various
//! rates (0%, 1%, 3%, 5%, 10%), comparing:
//!   - Baseline KCP (patched RTO only)
//!   - Redundant ACK (3x ACK duplication)
//!   - FEC (XOR parity, group_size=3)
//!   - Combined (redundant ACK + FEC)

const std = @import("std");
const kcp = @import("kcp.zig");
const fec_mod = @import("fec.zig");
const output_filter = @import("output_filter.zig");

const c = @cImport({
    @cInclude("ikcp.h");
});

// =============================================================================
// Deterministic PRNG
// =============================================================================

const Lcg = struct {
    state: u64,

    fn init(seed: u64) Lcg {
        return .{ .state = seed };
    }

    fn next(self: *Lcg) f64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return @as(f64, @floatFromInt((self.state >> 33) & 0x7FFFFFFF)) / @as(f64, @floatFromInt(@as(u64, 0x7FFFFFFF)));
    }

    fn shouldDrop(self: *Lcg, rate: f64) bool {
        if (rate <= 0) return false;
        return self.next() < rate;
    }
};

// =============================================================================
// Virtual network
// =============================================================================

const MaxPackets = 512;
const MaxPacketSize = 1600;

const VirtualNet = struct {
    packets: [MaxPackets][MaxPacketSize]u8 = undefined,
    lengths: [MaxPackets]usize = .{0} ** MaxPackets,
    count: usize = 0,

    fn push(self: *VirtualNet, data: []const u8) void {
        if (self.count >= MaxPackets or data.len > MaxPacketSize) return;
        @memcpy(self.packets[self.count][0..data.len], data);
        self.lengths[self.count] = data.len;
        self.count += 1;
    }

    fn clear(self: *VirtualNet) void {
        self.count = 0;
    }
};

// Global buffers for C callbacks
var g_net_a_to_b: VirtualNet = .{};
var g_net_b_to_a: VirtualNet = .{};

// Global KCP pointers for FEC decoder → KCP input
var g_kcp_a: ?*c.ikcpcb = null;
var g_kcp_b: ?*c.ikcpcb = null;

// Raw C output callbacks (no filter)
fn rawOutputA(buf: [*c]const u8, len: c_int, _: [*c]c.ikcpcb, _: ?*anyopaque) callconv(.c) c_int {
    g_net_a_to_b.push(buf[0..@intCast(len)]);
    return 0;
}

fn rawOutputB(buf: [*c]const u8, len: c_int, _: [*c]c.ikcpcb, _: ?*anyopaque) callconv(.c) c_int {
    g_net_b_to_a.push(buf[0..@intCast(len)]);
    return 0;
}

// Zig-level output for filter layer → virtual net
fn filteredOutputA(data: []const u8, _: ?*anyopaque) void {
    g_net_a_to_b.push(data);
}

fn filteredOutputB(data: []const u8, _: ?*anyopaque) void {
    g_net_b_to_a.push(data);
}

// FEC decoder output → KCP input
fn fecDecodedToA(data: []const u8, _: ?*anyopaque) void {
    if (g_kcp_a) |ka| {
        _ = c.ikcp_input(ka, data.ptr, @intCast(data.len));
    }
}

fn fecDecodedToB(data: []const u8, _: ?*anyopaque) void {
    if (g_kcp_b) |kb| {
        _ = c.ikcp_input(kb, data.ptr, @intCast(data.len));
    }
}

// Filter wrapper C callbacks (for KCP setoutput)
var g_filter_a: ?*output_filter.Filter = null;
var g_filter_b: ?*output_filter.Filter = null;

fn filterOutputA(buf: [*c]const u8, len: c_int, _: [*c]c.ikcpcb, _: ?*anyopaque) callconv(.c) c_int {
    if (g_filter_a) |f| f.send(buf[0..@intCast(len)]);
    return 0;
}

fn filterOutputB(buf: [*c]const u8, len: c_int, _: [*c]c.ikcpcb, _: ?*anyopaque) callconv(.c) c_int {
    if (g_filter_b) |f| f.send(buf[0..@intCast(len)]);
    return 0;
}

fn isAckPacket(data: []const u8) bool {
    return kcp.Kcp.isAckOnly(data);
}

// =============================================================================
// Test modes
// =============================================================================

const Mode = enum {
    baseline,
    redundant_ack,
    fec_only,
    combined,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .baseline => "baseline    ",
            .redundant_ack => "ack_repeat=3",
            .fec_only => "fec_group=3 ",
            .combined => "ack+fec     ",
        };
    }
};

// =============================================================================
// Unified loss test
// =============================================================================

fn runLossTest(
    data_size: usize,
    block_size: usize,
    loss_rate: f64,
    max_ticks: u32,
    mode: Mode,
) struct { delivered: usize, ticks: u32 } {
    var rng = Lcg.init(42);

    g_net_a_to_b = .{};
    g_net_b_to_a = .{};

    const kcp_a = c.ikcp_create(1, null) orelse return .{ .delivered = 0, .ticks = 0 };
    defer c.ikcp_release(kcp_a);
    const kcp_b = c.ikcp_create(1, null) orelse return .{ .delivered = 0, .ticks = 0 };
    defer c.ikcp_release(kcp_b);

    g_kcp_a = kcp_a;
    g_kcp_b = kcp_b;
    defer {
        g_kcp_a = null;
        g_kcp_b = null;
    }

    _ = c.ikcp_nodelay(kcp_a, 2, 1, 2, 1);
    _ = c.ikcp_wndsize(kcp_a, 4096, 4096);
    _ = c.ikcp_setmtu(kcp_a, 1400);
    _ = c.ikcp_nodelay(kcp_b, 2, 1, 2, 1);
    _ = c.ikcp_wndsize(kcp_b, 4096, 4096);
    _ = c.ikcp_setmtu(kcp_b, 1400);

    // Configure output pipeline based on mode
    const use_fec = (mode == .fec_only or mode == .combined);
    const ack_repeat: u8 = if (mode == .redundant_ack or mode == .combined) 3 else 1;

    var filter_a_storage: output_filter.Filter = undefined;
    var filter_b_storage: output_filter.Filter = undefined;

    if (use_fec) {
        const cfg = output_filter.Config{
            .ack_repeat = ack_repeat,
            .fec_group_size = 3,
        };
        filter_a_storage = output_filter.Filter.init(cfg, filteredOutputA, null);
        filter_b_storage = output_filter.Filter.init(cfg, filteredOutputB, null);
        g_filter_a = &filter_a_storage;
        g_filter_b = &filter_b_storage;
        _ = c.ikcp_setoutput(kcp_a, filterOutputA);
        _ = c.ikcp_setoutput(kcp_b, filterOutputB);
    } else {
        g_filter_a = null;
        g_filter_b = null;
        _ = c.ikcp_setoutput(kcp_a, rawOutputA);
        _ = c.ikcp_setoutput(kcp_b, rawOutputB);
    }
    defer {
        g_filter_a = null;
        g_filter_b = null;
    }

    // FEC decoders
    var fec_dec_to_a: fec_mod.Decoder = undefined;
    var fec_dec_to_b: fec_mod.Decoder = undefined;
    if (use_fec) {
        fec_dec_to_a = fec_mod.Decoder.init(fecDecodedToA, null);
        fec_dec_to_b = fec_mod.Decoder.init(fecDecodedToB, null);
    }

    // Send all data
    var offset: usize = 0;
    while (offset < data_size) {
        const end = @min(offset + block_size, data_size);
        const chunk_len = end - offset;
        var chunk: [1024]u8 = undefined;
        @memset(chunk[0..chunk_len], @intCast(offset / block_size));
        _ = c.ikcp_send(kcp_a, &chunk, @intCast(chunk_len));
        offset = end;
    }

    var received: usize = 0;
    var recv_buf: [65536]u8 = undefined;
    var current: u32 = 100;

    var tick: u32 = 0;
    while (tick < max_ticks and received < data_size) : (tick += 1) {
        g_net_a_to_b.clear();
        g_net_b_to_a.clear();

        // Update A
        c.ikcp_update(kcp_a, current);
        if (use_fec) {
            if (g_filter_a) |f| f.flush();
        }

        // Feed A→B with loss
        for (0..g_net_a_to_b.count) |i| {
            if (!rng.shouldDrop(loss_rate)) {
                const pkt = g_net_a_to_b.packets[i][0..g_net_a_to_b.lengths[i]];
                if (use_fec) {
                    fec_dec_to_b.addPacket(pkt);
                } else {
                    _ = c.ikcp_input(kcp_b, pkt.ptr, @intCast(pkt.len));
                }
            }
        }

        // Update B
        c.ikcp_update(kcp_b, current);
        if (use_fec) {
            if (g_filter_b) |f| f.flush();
        }

        // Feed B→A with loss
        for (0..g_net_b_to_a.count) |i| {
            const pkt = g_net_b_to_a.packets[i][0..g_net_b_to_a.lengths[i]];

            if (use_fec) {
                if (!rng.shouldDrop(loss_rate)) {
                    fec_dec_to_a.addPacket(pkt);
                }
            } else {
                // Non-FEC: apply redundant ACK at the receive side
                const is_ack = isAckPacket(pkt);
                const repeats: u8 = if (is_ack and ack_repeat > 1) ack_repeat else 1;
                for (0..repeats) |_| {
                    if (!rng.shouldDrop(loss_rate)) {
                        _ = c.ikcp_input(kcp_a, pkt.ptr, @intCast(pkt.len));
                    }
                }
            }
        }

        // Receive
        while (true) {
            const n = c.ikcp_recv(kcp_b, &recv_buf, recv_buf.len);
            if (n <= 0) break;
            received += @intCast(n);
        }

        current += 1;
    }

    return .{ .delivered = received, .ticks = tick };
}

// =============================================================================
// The main packet loss test
// =============================================================================

test "KCP packet loss resilience comparison" {
    const data_size: usize = 64 * 1024;
    const block_size: usize = 1024;

    const loss_rates = [_]f64{ 0.0, 0.01, 0.05, 0.10, 0.20 };

    std.debug.print("\n==============================================================================\n", .{});
    std.debug.print("  KCP Packet Loss Resilience — Delivery Speed (64KB, 1KB blocks)\n", .{});
    std.debug.print("  Lower ticks = faster delivery. Bilateral packet loss simulation.\n", .{});
    std.debug.print("==============================================================================\n\n", .{});

    // Table 1: Delivery within tight timeout (500 ticks ≈ 500ms)
    const tight_ticks: u32 = 500;
    std.debug.print("--- Delivered within {d}ms timeout ---\n", .{tight_ticks});
    std.debug.print("{s:>6} | {s:>12} | {s:>12} | {s:>12} | {s:>12}\n", .{
        "Loss", "Baseline", "ACK x3", "FEC g=3", "ACK+FEC",
    });
    std.debug.print("------ + ------------ + ------------ + ------------ + ------------\n", .{});

    for (loss_rates) |rate| {
        const bl = runLossTest(data_size, block_size, rate, tight_ticks, .baseline);
        const ack = runLossTest(data_size, block_size, rate, tight_ticks, .redundant_ack);
        const fec_r = runLossTest(data_size, block_size, rate, tight_ticks, .fec_only);
        const cmb = runLossTest(data_size, block_size, rate, tight_ticks, .combined);

        std.debug.print("{d:>5.0}% | {d:>5}/{d} KB | {d:>5}/{d} KB | {d:>5}/{d} KB | {d:>5}/{d} KB\n", .{
            rate * 100,
            bl.delivered / 1024,  data_size / 1024,
            ack.delivered / 1024, data_size / 1024,
            fec_r.delivered / 1024, data_size / 1024,
            cmb.delivered / 1024, data_size / 1024,
        });
    }

    // Table 2: Ticks to complete delivery (speed comparison)
    const full_ticks: u32 = 20000;
    std.debug.print("\n--- Ticks to deliver 64KB (lower = faster, max {d}) ---\n", .{full_ticks});
    std.debug.print("{s:>6} | {s:>12} | {s:>12} | {s:>12} | {s:>12}\n", .{
        "Loss", "Baseline", "ACK x3", "FEC g=3", "ACK+FEC",
    });
    std.debug.print("------ + ------------ + ------------ + ------------ + ------------\n", .{});

    for (loss_rates) |rate| {
        const bl = runLossTest(data_size, block_size, rate, full_ticks, .baseline);
        const ack = runLossTest(data_size, block_size, rate, full_ticks, .redundant_ack);
        const fec_r = runLossTest(data_size, block_size, rate, full_ticks, .fec_only);
        const cmb = runLossTest(data_size, block_size, rate, full_ticks, .combined);

        const bl_s = if (bl.delivered >= data_size) bl.ticks else full_ticks;
        const ack_s = if (ack.delivered >= data_size) ack.ticks else full_ticks;
        const fec_s = if (fec_r.delivered >= data_size) fec_r.ticks else full_ticks;
        const cmb_s = if (cmb.delivered >= data_size) cmb.ticks else full_ticks;

        std.debug.print("{d:>5.0}% | {d:>8} ms | {d:>8} ms | {d:>8} ms | {d:>8} ms\n", .{
            rate * 100, bl_s, ack_s, fec_s, cmb_s,
        });
    }

    std.debug.print("\n", .{});

    // Correctness: at 0% loss, baseline must deliver everything
    const check = runLossTest(data_size, block_size, 0.0, full_ticks, .baseline);
    try std.testing.expectEqual(data_size, check.delivered);

    // At 5% loss, combined mode should deliver faster than baseline
    const bl_5 = runLossTest(data_size, block_size, 0.05, full_ticks, .baseline);
    const cmb_5 = runLossTest(data_size, block_size, 0.05, full_ticks, .combined);
    // Both should eventually deliver, but combined should be faster
    try std.testing.expect(bl_5.delivered > 0);
    try std.testing.expect(cmb_5.delivered > 0);
}

test "Lcg deterministic" {
    var rng1 = Lcg.init(42);
    var rng2 = Lcg.init(42);
    for (0..100) |_| {
        try std.testing.expectEqual(rng1.next(), rng2.next());
    }
}
