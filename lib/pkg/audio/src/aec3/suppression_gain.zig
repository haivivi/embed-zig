//! Suppression Gain — Non-Linear Processor (NLP)
//!
//! Computes per-frequency-band suppression gains based on the ratio
//! of residual echo power to near-end signal power. This is the key
//! module that SpeexDSP lacks — it handles non-linear distortion,
//! multi-path reflections, and filter convergence errors.

const math = @import("std").math;

pub const Config = struct {
    num_bins: usize = 81,
    floor: f32 = 0.01,
    smoothing: f32 = 0.7,
    over_suppression: f32 = 1.5,
};

pub const SuppressionGain = struct {
    config: Config,
    gains: []f32,
    smoothed_echo: []f32,
    smoothed_near: []f32,
    allocator: Allocator,

    const Allocator = @import("std").mem.Allocator;

    pub fn init(allocator: Allocator, config: Config) !SuppressionGain {
        const gains = try allocator.alloc(f32, config.num_bins);
        errdefer allocator.free(gains);
        @memset(gains, 1.0);

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

    pub fn deinit(self: *SuppressionGain) void {
        self.allocator.free(self.smoothed_near);
        self.allocator.free(self.smoothed_echo);
        self.allocator.free(self.gains);
    }

    /// Compute suppression gains given echo and near-end power spectra.
    /// echo_power[k] = estimated residual echo power at bin k
    /// near_power[k] = estimated near-end signal power at bin k
    /// Returns pointer to internal gains array [0..num_bins].
    pub fn compute(
        self: *SuppressionGain,
        echo_power: []const f32,
        near_power: []const f32,
    ) []const f32 {
        const alpha = self.config.smoothing;
        const floor = self.config.floor;
        const over = self.config.over_suppression;
        const n = @min(self.config.num_bins, @min(echo_power.len, near_power.len));

        for (0..n) |k| {
            // Smooth power estimates
            self.smoothed_echo[k] = alpha * self.smoothed_echo[k] + (1.0 - alpha) * echo_power[k];
            self.smoothed_near[k] = alpha * self.smoothed_near[k] + (1.0 - alpha) * near_power[k];

            const echo = self.smoothed_echo[k] * over;
            const near = self.smoothed_near[k];

            // Wiener-like gain: near / (near + echo)
            if (echo + near < 1e-10) {
                self.gains[k] = 1.0;
            } else {
                var g = near / (near + echo);
                if (g < floor) g = floor;
                self.gains[k] = g;
            }
        }

        return self.gains[0..n];
    }

    /// Apply gains to a complex spectrum in-place.
    pub fn apply(self: *const SuppressionGain, spectrum: anytype) void {
        const n = @min(self.config.num_bins, spectrum.len);
        for (0..n) |k| {
            spectrum[k].re *= self.gains[k];
            spectrum[k].im *= self.gains[k];
        }
    }
};

// ============================================================================
// Tests SG1-SG6
// ============================================================================

const testing = @import("std").testing;

// SG1: Pure echo → gain < 0.1
test "SG1: pure echo — full suppression" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 8, .smoothing = 0 });
    defer sg.deinit();

    const echo = [_]f32{ 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000 };
    const near = [_]f32{ 1, 1, 1, 1, 1, 1, 1, 1 };

    const gains = sg.compute(&echo, &near);
    for (gains) |g| {
        try testing.expect(g < 0.1);
    }
}

// SG2: Pure near-end → gain > 0.8
test "SG2: pure near-end — no suppression" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 8, .smoothing = 0 });
    defer sg.deinit();

    const echo = [_]f32{ 1, 1, 1, 1, 1, 1, 1, 1 };
    const near = [_]f32{ 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000 };

    const gains = sg.compute(&echo, &near);
    for (gains) |g| {
        try testing.expect(g > 0.8);
    }
}

// SG3: Mixed — low freq echo, high freq near-end
test "SG3: mixed — low freq suppressed, high freq preserved" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 8, .smoothing = 0 });
    defer sg.deinit();

    // Low bins: echo dominant. High bins: near-end dominant.
    const echo = [_]f32{ 10000, 10000, 10000, 10000, 10, 10, 10, 10 };
    const near = [_]f32{ 10, 10, 10, 10, 10000, 10000, 10000, 10000 };

    const gains = sg.compute(&echo, &near);

    // Low freq: should be suppressed
    for (0..4) |k| {
        try testing.expect(gains[k] < 0.2);
    }
    // High freq: should be preserved
    for (4..8) |k| {
        try testing.expect(gains[k] > 0.7);
    }
}

// SG4: Floor value — gain never goes below floor
test "SG4: floor value prevents complete silence" {
    var sg = try SuppressionGain.init(testing.allocator, .{
        .num_bins = 4,
        .smoothing = 0,
        .floor = 0.05,
    });
    defer sg.deinit();

    const echo = [_]f32{ 1e8, 1e8, 1e8, 1e8 };
    const near = [_]f32{ 0.001, 0.001, 0.001, 0.001 };

    const gains = sg.compute(&echo, &near);
    for (gains) |g| {
        try testing.expect(g >= 0.05);
    }
}

// SG5: Zero input → gain = 1.0
test "SG5: zero input — gain = 1.0" {
    var sg = try SuppressionGain.init(testing.allocator, .{ .num_bins = 4, .smoothing = 0 });
    defer sg.deinit();

    const zero = [_]f32{ 0, 0, 0, 0 };
    const gains = sg.compute(&zero, &zero);
    for (gains) |g| {
        try testing.expectEqual(@as(f32, 1.0), g);
    }
}

// SG6: Smooth transition — echo decreasing, gain rises smoothly
test "SG6: smooth transition — gain rises as echo decreases" {
    var sg = try SuppressionGain.init(testing.allocator, .{
        .num_bins = 1,
        .smoothing = 0.5,
    });
    defer sg.deinit();

    const near = [_]f32{1000};
    var prev_gain: f32 = 0;

    for (0..20) |i| {
        // Echo decreasing over time
        const echo_val = 10000.0 / @as(f32, @floatFromInt(i + 1));
        const echo = [_]f32{echo_val};
        const gains = sg.compute(&echo, &near);
        const g = gains[0];

        if (i > 0) {
            // Gain should be monotonically increasing (echo decreasing)
            try testing.expect(g >= prev_gain - 0.01);
        }
        prev_gain = g;
    }
    // Final gain should be high (echo is now very small)
    try testing.expect(prev_gain > 0.5);
}
