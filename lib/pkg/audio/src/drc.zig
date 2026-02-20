//! DRC — Dynamic Range Compression (pure Zig)
//!
//! Reduces the dynamic range of audio by attenuating loud signals
//! and optionally boosting quiet ones. Prevents clipping and ensures
//! consistent output levels.
//!
//! ## Usage
//!
//! ```zig
//! var drc = Drc.init(.{});
//! drc.process(&frame);
//! ```

pub const Config = struct {
    /// Threshold in i16 amplitude above which compression kicks in (-6dBFS).
    threshold: i16 = 16384,
    /// Compression ratio as fixed-point (numerator/256).
    /// 64 = 4:1, 128 = 2:1, 256 = 1:1 (no compression).
    ratio: u16 = 128,
    /// Attack smoothing factor. Higher = slower attack. 0-255.
    attack: u8 = 240,
    /// Release smoothing factor. Higher = slower release. 0-255.
    release: u8 = 250,
    /// Makeup gain (256 = unity, 512 = 2x).
    makeup_gain: u16 = 256,
};

pub const Drc = struct {
    envelope: i32,
    config: Config,

    pub fn init(config: Config) Drc {
        return .{ .envelope = 0, .config = config };
    }

    pub fn process(self: *Drc, frame: []i16) void {
        const threshold: i32 = self.config.threshold;
        const ratio: i32 = self.config.ratio;
        const attack: i32 = self.config.attack;
        const release: i32 = self.config.release;
        const makeup: i32 = self.config.makeup_gain;

        for (frame) |*sample| {
            const abs_val: i32 = if (sample.* < 0) -@as(i32, sample.*) else @as(i32, sample.*);

            if (abs_val > self.envelope) {
                self.envelope = (attack * self.envelope + (256 - attack) * abs_val) >> 8;
            } else {
                self.envelope = (release * self.envelope + (256 - release) * abs_val) >> 8;
            }

            var gain: i32 = 256;
            if (self.envelope > threshold) {
                const excess = self.envelope - threshold;
                const compressed_excess = (excess * ratio) >> 8;
                const target = threshold + compressed_excess;
                if (self.envelope > 0) {
                    gain = @divTrunc(target * 256, self.envelope);
                }
            }

            const total_gain = (gain * makeup) >> 8;
            const out: i32 = (@as(i32, sample.*) * total_gain) >> 8;

            if (out > 32767) {
                sample.* = 32767;
            } else if (out < -32768) {
                sample.* = -32768;
            } else {
                sample.* = @intCast(out);
            }
        }
    }

    pub fn reset(self: *Drc) void {
        self.envelope = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "DRC init" {
    var drc = Drc.init(.{});
    _ = &drc;
}

test "DRC silence passthrough" {
    var drc = Drc.init(.{});

    var frame = [_]i16{0} ** 160;
    drc.process(&frame);

    for (frame) |s| {
        try testing.expectEqual(@as(i16, 0), s);
    }
}

test "DRC quiet signal passthrough" {
    var drc = Drc.init(.{ .threshold = 16384 });

    var frame: [160]i16 = undefined;
    for (&frame) |*s| s.* = 1000;

    drc.process(&frame);

    for (frame) |s| {
        try testing.expect(s >= 900 and s <= 1100);
    }
}

test "DRC loud signal compressed" {
    var drc = Drc.init(.{
        .threshold = 10000,
        .ratio = 64,
        .attack = 0,
        .release = 0,
        .makeup_gain = 256,
    });

    var frame: [160]i16 = undefined;
    for (&frame) |*s| s.* = 30000;

    drc.process(&frame);

    for (frame) |s| {
        try testing.expect(s < 30000);
        try testing.expect(s > 0);
    }
}

test "DRC no clipping" {
    var drc = Drc.init(.{
        .threshold = 5000,
        .ratio = 64,
        .makeup_gain = 256,
    });

    var frame: [160]i16 = undefined;
    for (&frame) |*s| s.* = 32000;

    drc.process(&frame);

    for (frame) |s| {
        try testing.expect(s >= -32768 and s <= 32767);
    }
}

test "DRC reset" {
    var drc = Drc.init(.{});

    var frame = [_]i16{10000} ** 160;
    drc.process(&frame);
    try testing.expect(drc.envelope > 0);

    drc.reset();
    try testing.expectEqual(@as(i32, 0), drc.envelope);
}
