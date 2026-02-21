//! Delay Estimator — cross-correlation based echo path delay detection
//!
//! Estimates the delay between the speaker reference signal and its
//! acoustic echo captured by the microphone. Uses downsampled normalized
//! cross-correlation for efficiency.

const math = @import("std").math;

pub const Config = struct {
    sample_rate: u32 = 16000,
    max_delay_ms: u32 = 500,
    downsample_factor: u32 = 4,
    block_size: usize = 160,
    smoothing: f32 = 0.7,
};

pub const DelayEstimator = struct {
    config: Config,
    max_delay_samples: usize,
    ds_max_delay: usize,
    ds_block: usize,

    // Downsampled ring buffers
    ref_buf: []f32,
    mic_buf: []f32,
    ref_pos: usize,
    mic_pos: usize,
    buf_len: usize,

    // Current estimate
    estimated_delay: i32,
    confidence: f32,
    frames_processed: u32,

    allocator: Allocator,

    const Allocator = @import("std").mem.Allocator;
    const INVALID_DELAY: i32 = -1;

    pub fn init(allocator: Allocator, config: Config) !DelayEstimator {
        const max_delay_samples = config.sample_rate * config.max_delay_ms / 1000;
        const ds_max = max_delay_samples / config.downsample_factor;
        const ds_block = config.block_size / config.downsample_factor;
        // Buffer holds enough history for correlation search
        const buf_len = ds_max + ds_block * 4;

        const ref_buf = try allocator.alloc(f32, buf_len);
        errdefer allocator.free(ref_buf);
        @memset(ref_buf, 0);

        const mic_buf = try allocator.alloc(f32, buf_len);
        errdefer allocator.free(mic_buf);
        @memset(mic_buf, 0);

        return .{
            .config = config,
            .max_delay_samples = max_delay_samples,
            .ds_max_delay = ds_max,
            .ds_block = ds_block,
            .ref_buf = ref_buf,
            .mic_buf = mic_buf,
            .ref_pos = 0,
            .mic_pos = 0,
            .buf_len = buf_len,
            .estimated_delay = INVALID_DELAY,
            .confidence = 0,
            .frames_processed = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DelayEstimator) void {
        self.allocator.free(self.mic_buf);
        self.allocator.free(self.ref_buf);
    }

    /// Feed one block of ref and mic data. Returns updated delay estimate.
    /// Delay is in original (non-downsampled) sample units.
    /// Returns INVALID_DELAY (-1) if no reliable estimate yet.
    pub fn process(self: *DelayEstimator, mic: []const i16, ref: []const i16) i32 {
        const ds = self.config.downsample_factor;
        const bs = @min(mic.len, ref.len);

        // Downsample and push into ring buffers
        var i: usize = 0;
        while (i < bs) : (i += ds) {
            self.ref_buf[self.ref_pos % self.buf_len] = @floatFromInt(ref[i]);
            self.mic_buf[self.mic_pos % self.buf_len] = @floatFromInt(mic[i]);
            self.ref_pos += 1;
            self.mic_pos += 1;
        }

        self.frames_processed += 1;

        // Need enough history before estimating
        if (self.ref_pos < self.ds_max_delay + self.ds_block) {
            return self.estimated_delay;
        }

        // Run cross-correlation every 10 blocks (~100ms)
        if (self.frames_processed % 10 != 0) {
            return self.estimated_delay;
        }

        // Normalized cross-correlation search
        // mic[T] correlates with ref[T - delay], so for candidate delay d,
        // align mic recent window with ref shifted back by d.
        const search_len = self.ds_block * 4;
        var best_corr: f32 = -1.0;
        var best_delay: usize = 0;

        if (self.mic_pos < search_len) return self.estimated_delay;

        // Mic window: most recent search_len samples
        const mic_start = self.mic_pos -| search_len;

        // Compute mic energy
        var mic_energy: f32 = 0;
        for (0..search_len) |j| {
            const v = self.mic_buf[(mic_start +% j) % self.buf_len];
            mic_energy += v * v;
        }
        if (mic_energy < 1.0) return self.estimated_delay;

        // Correlation model: at buffer position k, mic[k]=signal(k*ds+D), ref[k]=signal(k*ds).
        // mic[k] = ref[k + D/ds]. We can't look ahead in ref (not written yet).
        // Instead: ref[k] = mic[k - D/ds]. Look BACK in mic.
        // Equivalently: correlate ref_recent with mic_shifted_back.
        // sum(ref[t] * mic[t - d]) peaks at d = D/ds.
        // mic_start for the ref window, mic shifted back by d.
        const ref_end = self.ref_pos;
        const ref_begin = ref_end -| search_len;
        if (ref_begin < search_len) return self.estimated_delay;

        const max_d = @min(self.ds_max_delay, ref_begin);
        if (max_d == 0) return self.estimated_delay;

        // Compute ref energy
        var ref_energy_val: f32 = 0;
        for (0..search_len) |j| {
            const v = self.ref_buf[(ref_begin + j) % self.buf_len];
            ref_energy_val += v * v;
        }
        if (ref_energy_val < 1.0) return self.estimated_delay;

        for (0..max_d) |d| {
            const mic_begin = ref_begin -| d;

            var corr: f32 = 0;
            var mic_energy_d: f32 = 0;
            for (0..search_len) |j| {
                const r = self.ref_buf[(ref_begin + j) % self.buf_len];
                const m = self.mic_buf[(mic_begin + j) % self.buf_len];
                corr += r * m;
                mic_energy_d += m * m;
            }

            if (mic_energy_d < 1.0) continue;

            const norm_corr = corr / @sqrt(ref_energy_val * mic_energy_d);
            if (norm_corr > best_corr) {
                best_corr = norm_corr;
                best_delay = d;
            }
        }

        // Update with smoothing
        if (best_corr > 0.3) {
            const new_delay: i32 = @intCast(best_delay * self.config.downsample_factor);
            if (self.estimated_delay == INVALID_DELAY) {
                self.estimated_delay = new_delay;
            } else {
                const alpha = self.config.smoothing;
                const curr: f32 = @floatFromInt(self.estimated_delay);
                const smoothed = alpha * curr + (1.0 - alpha) * @as(f32, @floatFromInt(new_delay));
                self.estimated_delay = @intFromFloat(@round(smoothed));
            }
            self.confidence = best_corr;
        }

        return self.estimated_delay;
    }

    pub fn getDelay(self: *const DelayEstimator) i32 {
        return self.estimated_delay;
    }

    pub fn getConfidence(self: *const DelayEstimator) f32 {
        return self.confidence;
    }
};

// ============================================================================
// Tests DE1-DE7
// ============================================================================

const std = @import("std");
const testing = std.testing;

fn generateSine(buf: []i16, freq: f32, amp: f32, sr: u32, offset: usize) void {
    for (buf, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i + offset)) / @as(f32, @floatFromInt(sr));
        s.* = @intFromFloat(@sin(t * freq * 2.0 * math.pi) * amp);
    }
}

fn runDelayTest(allocator: std.mem.Allocator, delay_samples: usize, config: Config) !i32 {
    var de = try DelayEstimator.init(allocator, config);
    defer de.deinit();

    const total = config.block_size * 200;
    const signal_len = total + delay_samples + config.block_size;
    const signal = try allocator.alloc(i16, signal_len);
    defer allocator.free(signal);

    // Use broadband noise-like signal (better for correlation than pure sine)
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();
    for (signal) |*s| {
        s.* = random.intRangeAtMost(i16, -10000, 10000);
    }

    for (0..200) |frame| {
        const ref_start = frame * config.block_size;
        const mic_start = ref_start + delay_samples;
        if (mic_start + config.block_size > signal_len) break;
        const ref = signal[ref_start..][0..config.block_size];
        const mic = signal[mic_start..][0..config.block_size];
        _ = de.process(mic, ref);
    }

    return de.getDelay();
}

// DE1: Zero delay
test "DE1: zero delay detection" {
    const delay = try runDelayTest(testing.allocator, 0, .{});
    std.debug.print("[DE1] estimated={d}\n", .{delay});
    try testing.expect(delay >= -4 and delay <= 16);
}

// DE2: Exact delay 320 samples
test "DE2: delay 320 samples (20ms)" {
    const delay = try runDelayTest(testing.allocator, 320, .{});
    std.debug.print("[DE2] estimated={d} (expected 320)\n", .{delay});
    try testing.expect(delay >= 304 and delay <= 336);
}

// DE3: Large delay 4800 samples (300ms)
test "DE3: large delay 4800 samples (300ms)" {
    const delay = try runDelayTest(testing.allocator, 4800, .{
        .max_delay_ms = 500,
        .block_size = 160,
    });
    std.debug.print("[DE3] estimated={d} (expected 4800)\n", .{delay});
    try testing.expect(delay >= 4700 and delay <= 4900);
}

// DE4: Delay + attenuation (broadband)
test "DE4: delay 320 + attenuation 0.5" {
    var de = try DelayEstimator.init(testing.allocator, .{});
    defer de.deinit();

    var prng = std.Random.DefaultPrng.init(456);
    const random = prng.random();

    const total = 160 * 200 + 320 + 160;
    const signal = try testing.allocator.alloc(i16, total);
    defer testing.allocator.free(signal);
    for (signal) |*s| s.* = random.intRangeAtMost(i16, -10000, 10000);

    for (0..200) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic_start = frame * 160 + 320;
        if (mic_start + 160 > total) break;

        var mic: [160]i16 = undefined;
        for (&mic, 0..) |*s, i| {
            s.* = @intCast(@as(i32, signal[mic_start + i]) >> 1);
        }
        _ = de.process(&mic, ref);
    }

    const delay = de.getDelay();
    std.debug.print("[DE4] estimated={d} (expected 320, attenuated)\n", .{delay});
    try testing.expect(delay >= 304 and delay <= 336);
}

// DE5: Delay + noise (broadband)
test "DE5: delay 320 + noise (SNR=10dB)" {
    var de = try DelayEstimator.init(testing.allocator, .{});
    defer de.deinit();

    var prng = std.Random.DefaultPrng.init(789);
    const random = prng.random();

    const total = 160 * 200 + 320 + 160;
    const signal = try testing.allocator.alloc(i16, total);
    defer testing.allocator.free(signal);
    for (signal) |*s| s.* = random.intRangeAtMost(i16, -10000, 10000);

    for (0..200) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic_start = frame * 160 + 320;
        if (mic_start + 160 > total) break;

        var mic: [160]i16 = undefined;
        for (&mic, 0..) |*s, i| {
            const echo: i32 = signal[mic_start + i];
            const noise: i32 = random.intRangeAtMost(i16, -3000, 3000);
            s.* = @intCast(std.math.clamp(echo + noise, -32768, 32767));
        }
        _ = de.process(&mic, ref);
    }

    const delay = de.getDelay();
    std.debug.print("[DE5] estimated={d} (expected 320, noisy)\n", .{delay});
    try testing.expect(delay >= 288 and delay <= 352);
}

// DE6: Delay jump (broadband)
test "DE6: delay jump from 320 to 640" {
    var de = try DelayEstimator.init(testing.allocator, .{ .smoothing = 0.3 });
    defer de.deinit();

    var prng = std.Random.DefaultPrng.init(321);
    const random = prng.random();

    const total = 160 * 400 + 640 + 160;
    const signal = try testing.allocator.alloc(i16, total);
    defer testing.allocator.free(signal);
    for (signal) |*s| s.* = random.intRangeAtMost(i16, -10000, 10000);

    for (0..200) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic_start = frame * 160 + 320;
        if (mic_start + 160 > total) break;
        const mic = signal[mic_start..][0..160];
        _ = de.process(mic, ref);
    }

    for (200..400) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic_start = frame * 160 + 640;
        if (mic_start + 160 > total) break;
        const mic = signal[mic_start..][0..160];
        _ = de.process(mic, ref);
    }

    const delay = de.getDelay();
    std.debug.print("[DE6] estimated={d} (expected ~640 after jump)\n", .{delay});
    try testing.expect(delay >= 500 and delay <= 700);
}

// DE7: No echo — pure near-end
test "DE7: no echo — near-end only returns INVALID" {
    var de = try DelayEstimator.init(testing.allocator, .{});
    defer de.deinit();

    // Ref = 440Hz, mic = 880Hz (completely different, no echo)
    for (0..100) |frame| {
        var ref: [160]i16 = undefined;
        var mic: [160]i16 = undefined;
        generateSine(&ref, 440.0, 10000.0, 16000, frame * 160);
        generateSine(&mic, 880.0, 8000.0, 16000, frame * 160 + 9999);

        _ = de.process(&mic, &ref);
    }

    // Confidence should be low when signals are uncorrelated
    std.debug.print("[DE7] delay={d}, confidence={d:.2}\n", .{ de.getDelay(), de.getConfidence() });
    // Either invalid or low confidence
    try testing.expect(de.getConfidence() < 0.7 or de.getDelay() == -1);
}
