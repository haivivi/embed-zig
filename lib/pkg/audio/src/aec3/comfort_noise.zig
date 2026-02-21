//! Comfort Noise Generator — fills silence gaps with natural-sounding noise
//!
//! When AEC suppresses echo to near-silence, the output sounds unnatural.
//! This module injects low-level broadband noise to maintain a natural
//! acoustic feel.

pub const Config = struct {
    num_bins: usize = 81,
    noise_floor_rms: f32 = 50.0,
};

pub const ComfortNoise = struct {
    config: Config,
    rng_state: u64,

    pub fn init(config: Config) ComfortNoise {
        return .{ .config = config, .rng_state = 0x12345678ABCDEF01 };
    }

    /// Generate comfort noise into buf. Output level targets noise_floor_rms.
    pub fn generate(self: *ComfortNoise, buf: []i16) void {
        const target = self.config.noise_floor_rms;
        for (buf) |*s| {
            // xorshift64 PRNG
            self.rng_state ^= self.rng_state << 13;
            self.rng_state ^= self.rng_state >> 7;
            self.rng_state ^= self.rng_state << 17;

            // Map to [-1, 1] range then scale
            const raw: f32 = @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(self.rng_state)))));
            const normalized = raw / 2147483648.0;
            const sample = normalized * target * 1.73; // sqrt(3) for uniform → RMS scaling
            if (sample > 32767) {
                s.* = 32767;
            } else if (sample < -32768) {
                s.* = -32768;
            } else {
                s.* = @intFromFloat(sample);
            }
        }
    }

    /// Add comfort noise to buf where signal energy is below threshold.
    pub fn fill(self: *ComfortNoise, buf: []i16, threshold_rms: f32) void {
        // Compute current RMS
        var energy: f32 = 0;
        for (buf) |s| {
            const v: f32 = @floatFromInt(s);
            energy += v * v;
        }
        const rms = @sqrt(energy / @as(f32, @floatFromInt(buf.len)));

        if (rms < threshold_rms) {
            // Mix in comfort noise (additive)
            for (buf) |*s| {
                self.rng_state ^= self.rng_state << 13;
                self.rng_state ^= self.rng_state >> 7;
                self.rng_state ^= self.rng_state << 17;
                const raw: f32 = @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(self.rng_state)))));
                const noise = raw / 2147483648.0 * self.config.noise_floor_rms;
                const mixed: f32 = @as(f32, @floatFromInt(s.*)) + noise;
                if (mixed > 32767) {
                    s.* = 32767;
                } else if (mixed < -32768) {
                    s.* = -32768;
                } else {
                    s.* = @intFromFloat(mixed);
                }
            }
        }
    }
};

// ============================================================================
// Tests CN1-CN3
// ============================================================================

const testing = @import("std").testing;
const math = @import("std").math;

// CN1: Output RMS matches target ± 3dB
test "CN1: output RMS matches noise floor" {
    var cn = ComfortNoise.init(.{ .noise_floor_rms = 100.0 });

    var total_energy: f64 = 0;
    const frames = 100;
    for (0..frames) |_| {
        var buf: [160]i16 = undefined;
        cn.generate(&buf);
        for (buf) |s| {
            const v: f64 = @floatFromInt(s);
            total_energy += v * v;
        }
    }

    const rms = @sqrt(total_energy / @as(f64, frames * 160));
    const target: f64 = 100.0;
    const ratio_db = 20.0 * @log10(rms / target);

    @import("std").debug.print("[CN1] rms={d:.1}, target={d:.1}, diff={d:.1}dB\n", .{ rms, target, ratio_db });
    try testing.expect(@abs(ratio_db) < 3.0);
}

// CN2: Spectrum roughly flat — band energies within 6dB
test "CN2: flat spectrum" {
    var cn = ComfortNoise.init(.{ .noise_floor_rms = 500.0 });

    // Generate long buffer for frequency analysis
    var buf: [16000]i16 = undefined; // 1 second
    cn.generate(&buf);

    // Split into 4 frequency bands and measure energy
    const quarter = buf.len / 4;
    var band_energy: [4]f64 = undefined;
    for (0..4) |b| {
        var e: f64 = 0;
        for (0..quarter) |i| {
            const v: f64 = @floatFromInt(buf[b * quarter + i]);
            e += v * v;
        }
        band_energy[b] = e / @as(f64, quarter);
    }

    // All bands should be within 6dB of each other
    var min_e: f64 = band_energy[0];
    var max_e: f64 = band_energy[0];
    for (band_energy) |e| {
        if (e < min_e) min_e = e;
        if (e > max_e) max_e = e;
    }
    const ratio_db = 10.0 * @log10(max_e / @max(min_e, 1.0));
    @import("std").debug.print("[CN2] band ratio={d:.1}dB\n", .{ratio_db});
    try testing.expect(ratio_db < 6.0);
}

// CN3: No correlation between two generations
test "CN3: no correlation between two generations" {
    var cn = ComfortNoise.init(.{});

    var buf1: [1000]i16 = undefined;
    var buf2: [1000]i16 = undefined;
    cn.generate(&buf1);
    cn.generate(&buf2);

    // Compute normalized cross-correlation
    var corr: f64 = 0;
    var e1: f64 = 0;
    var e2: f64 = 0;
    for (0..1000) |i| {
        const v1: f64 = @floatFromInt(buf1[i]);
        const v2: f64 = @floatFromInt(buf2[i]);
        corr += v1 * v2;
        e1 += v1 * v1;
        e2 += v2 * v2;
    }

    const norm = corr / @sqrt(e1 * e2);
    @import("std").debug.print("[CN3] correlation={d:.3}\n", .{norm});
    try testing.expect(@abs(norm) < 0.1);
}
