//! Suppression Gain — Non-Linear Processor (NLP)
//!
//! Generic over Arithmetic type. Computes per-bin Wiener-like gains.

const math = @import("std").math;
const arith_mod = @import("arithmetic.zig");

pub const Config = struct {
    num_bins: usize = 81,
    floor: f32 = 0.01,
    smoothing: f32 = 0.7,
    over_suppression: f32 = 1.5,
};

pub fn GenSuppressionGain(comptime Arith: type) type {
    const S = Arith.Scalar;

    return struct {
        const Self = @This();

        config: Config,
        gains: []S,
        smoothed_echo: []f32,
        smoothed_near: []f32,
        allocator: Allocator,

        const Allocator = @import("std").mem.Allocator;

        pub fn init(allocator: Allocator, config: Config) !Self {
            const gains = try allocator.alloc(S, config.num_bins);
            errdefer allocator.free(gains);
            for (gains) |*g| g.* = Arith.one();

            const se = try allocator.alloc(f32, config.num_bins);
            errdefer allocator.free(se);
            @memset(se, 0);

            const sn = try allocator.alloc(f32, config.num_bins);
            errdefer allocator.free(sn);
            @memset(sn, 0);

            return .{
                .config = config,
                .gains = gains,
                .smoothed_echo = se,
                .smoothed_near = sn,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.smoothed_near);
            self.allocator.free(self.smoothed_echo);
            self.allocator.free(self.gains);
        }

        pub fn compute(
            self: *Self,
            echo_power: []const f32,
            near_power: []const f32,
        ) []const S {
            const alpha = self.config.smoothing;
            const floor = self.config.floor;
            const over = self.config.over_suppression;
            const n = @min(self.config.num_bins, @min(echo_power.len, near_power.len));

            for (0..n) |k| {
                self.smoothed_echo[k] = alpha * self.smoothed_echo[k] + (1.0 - alpha) * echo_power[k];
                self.smoothed_near[k] = alpha * self.smoothed_near[k] + (1.0 - alpha) * near_power[k];

                const echo = self.smoothed_echo[k] * over;
                const near = self.smoothed_near[k];

                if (echo + near < 1e-10) {
                    self.gains[k] = Arith.one();
                } else {
                    var g = near / (near + echo);
                    if (g < floor) g = floor;
                    self.gains[k] = Arith.fromFloat(g);
                }
            }

            return self.gains[0..n];
        }
    };
}

// Backward compatible
pub const SuppressionGain = GenSuppressionGain(arith_mod.Float);

// ============================================================================
// Tests SG1-SG6
// ============================================================================

const testing = @import("std").testing;

test "SG1: pure echo — full suppression" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 4, .floor = 0.01, .smoothing = 0.0 });
    defer sg.deinit();
    const echo = [_]f32{ 1000, 2000, 3000, 4000 };
    const near = [_]f32{ 0, 0, 0, 0 };
    const gains = sg.compute(&echo, &near);
    for (gains) |g| try testing.expect(g <= 0.02);
}

test "SG2: pure near-end — no suppression" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 4, .floor = 0.01, .smoothing = 0.0 });
    defer sg.deinit();
    const echo = [_]f32{ 0, 0, 0, 0 };
    const near = [_]f32{ 1000, 2000, 3000, 4000 };
    const gains = sg.compute(&echo, &near);
    for (gains) |g| try testing.expect(g > 0.98);
}

test "SG3: mixed — low freq suppressed, high freq preserved" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 4, .floor = 0.01, .smoothing = 0.0, .over_suppression = 1.0 });
    defer sg.deinit();
    const echo = [_]f32{ 1000, 500, 100, 0 };
    const near = [_]f32{ 100, 500, 1000, 1000 };
    const gains = sg.compute(&echo, &near);
    try testing.expect(gains[0] < gains[3]);
}

test "SG4: floor value prevents complete silence" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 2, .floor = 0.1, .smoothing = 0.0 });
    defer sg.deinit();
    const echo = [_]f32{ 10000, 10000 };
    const near = [_]f32{ 0, 0 };
    const gains = sg.compute(&echo, &near);
    for (gains) |g| try testing.expect(g >= 0.09);
}

test "SG5: zero input — gain = 1.0" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 2 });
    defer sg.deinit();
    const echo = [_]f32{ 0, 0 };
    const near = [_]f32{ 0, 0 };
    const gains = sg.compute(&echo, &near);
    for (gains) |g| try testing.expect(g >= 0.99);
}

test "SG6: smooth transition — gain rises as echo decreases" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 1, .floor = 0.01, .smoothing = 0.5 });
    defer sg.deinit();
    const high_echo = [_]f32{1000};
    const low_echo = [_]f32{10};
    const near = [_]f32{500};
    _ = sg.compute(&high_echo, &near);
    const g1 = sg.compute(&high_echo, &near)[0];
    _ = sg.compute(&low_echo, &near);
    _ = sg.compute(&low_echo, &near);
    const g2 = sg.compute(&low_echo, &near)[0];
    try testing.expect(g2 > g1);
}
