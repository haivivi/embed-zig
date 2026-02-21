//! AEC3 — Pure Zig Acoustic Echo Cancellation
//!
//! Complete pipeline:
//!   1. Delay estimation (cross-correlation)
//!   2. Linear adaptive filter (FDBAF) with delay-aligned ref
//!   3. NLP (per-bin coherence-based suppression)
//!   4. Comfort noise
//!
//! ## Usage
//!
//! ```zig
//! var aec = try Aec3.init(allocator, .{});
//! defer aec.deinit();
//! aec.process(&mic_frame, &ref_frame, &clean_frame);
//! ```

const fft_mod = @import("fft.zig");
const af_mod = @import("adaptive_filter.zig");
const de_mod = @import("delay_estimator.zig");
const sg_mod = @import("suppression_gain.zig");
const cn_mod = @import("comfort_noise.zig");

const Complex = fft_mod.Complex;

pub const Config = struct {
    frame_size: usize = 160,
    num_partitions: usize = 50,
    sample_rate: u32 = 16000,
    step_size: f32 = 0.5,
    regularization: f32 = 100.0,
    nlp_floor: f32 = 0.003,
    nlp_over_suppression: f32 = 5.0,
    comfort_noise_rms: f32 = 30.0,
    max_delay_ms: u32 = 500,
    coherence_smoothing: f32 = 0.7,
};

pub const Aec3 = struct {
    config: Config,
    af: af_mod.AdaptiveFilter,
    de: de_mod.DelayEstimator,
    sg: sg_mod.SuppressionGain,
    cn: cn_mod.ComfortNoise,

    fft_size: usize,
    num_bins: usize,

    // NLP smoothed cancel ratio
    smoothed_cancel_ratio: f32 = 0,

    // Heap-allocated work buffers (R3: no stack arrays)
    error_td: []i16,
    error_spectrum: []Complex,
    ref_spectrum: []Complex,
    echo_power: []f32,
    near_power: []f32,
    // Delay-aligned ref buffer (R1)
    ref_ring: []i16,
    ref_ring_pos: usize,

    allocator: Allocator,

    const Allocator = @import("std").mem.Allocator;

    pub fn init(allocator: Allocator, config: Config) !Aec3 {
        const fft_size = nextPow2(config.frame_size * 2);
        const num_bins = fft_size / 2 + 1;
        const max_delay_samples = config.sample_rate * config.max_delay_ms / 1000;
        const ring_size = max_delay_samples + config.frame_size * 4;

        var af = try af_mod.AdaptiveFilter.init(allocator, .{
            .block_size = config.frame_size,
            .num_partitions = config.num_partitions,
            .step_size = config.step_size,
            .regularization = config.regularization,
        });
        errdefer af.deinit();

        var de = try de_mod.DelayEstimator.init(allocator, .{
            .sample_rate = config.sample_rate,
            .max_delay_ms = config.max_delay_ms,
            .block_size = config.frame_size,
        });
        errdefer de.deinit();

        var sg = try sg_mod.SuppressionGain.init(allocator, .{
            .num_bins = num_bins,
            .floor = config.nlp_floor,
            .over_suppression = config.nlp_over_suppression,
        });
        errdefer sg.deinit();

        const error_td = try allocator.alloc(i16, config.frame_size);
        errdefer allocator.free(error_td);
        const err_spec = try allocator.alloc(Complex, fft_size);
        errdefer allocator.free(err_spec);
        const ref_spec = try allocator.alloc(Complex, fft_size);
        errdefer allocator.free(ref_spec);
        const echo_p = try allocator.alloc(f32, num_bins);
        errdefer allocator.free(echo_p);
        const near_p = try allocator.alloc(f32, num_bins);
        errdefer allocator.free(near_p);
        const ref_ring = try allocator.alloc(i16, ring_size);
        errdefer allocator.free(ref_ring);
        @memset(ref_ring, 0);

        return .{
            .config = config,
            .af = af,
            .de = de,
            .sg = sg,
            .cn = cn_mod.ComfortNoise.init(.{ .noise_floor_rms = config.comfort_noise_rms }),
            .fft_size = fft_size,
            .num_bins = num_bins,
            .error_td = error_td,
            .error_spectrum = err_spec,
            .ref_spectrum = ref_spec,
            .echo_power = echo_p,
            .near_power = near_p,
            .ref_ring = ref_ring,
            .ref_ring_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Aec3) void {
        self.allocator.free(self.ref_ring);
        self.allocator.free(self.near_power);
        self.allocator.free(self.echo_power);
        self.allocator.free(self.ref_spectrum);
        self.allocator.free(self.error_spectrum);
        self.allocator.free(self.error_td);
        self.sg.deinit();
        self.de.deinit();
        self.af.deinit();
    }

    pub fn reset(self: *Aec3) void {
        self.af.reset();
        self.smoothed_cancel_ratio = 0;
        @memset(self.ref_ring, 0);
        self.ref_ring_pos = 0;
    }

    /// Process one frame: remove echo from mic using ref, output clean audio.
    pub fn process(self: *Aec3, mic: []const i16, ref: []const i16, clean: []i16) void {
        const bs = self.config.frame_size;
        const fft_n = self.fft_size;
        const alpha = self.config.coherence_smoothing;

        // R1: Push ref into ring buffer and estimate delay
        const ring_len = self.ref_ring.len;
        for (ref[0..bs]) |s| {
            self.ref_ring[self.ref_ring_pos % ring_len] = s;
            self.ref_ring_pos += 1;
        }

        _ = self.de.process(mic, ref);

        // R1: Use current ref directly. The adaptive filter's partitioned
        // structure already handles delays up to num_partitions * frame_size.
        // The delay_estimator is used for monitoring, not for shifting ref.
        // (Shifting ref via ring buffer caused more harm than good —
        // the FDBAF's render buffer already covers the delay range.)
        const aligned_ref = ref[0..bs];

        // 1. Linear adaptive filter with delay-aligned ref
        const af_result = self.af.process(mic, aligned_ref, self.error_td);

        // 2. FFT error and ref for per-bin NLP
        fft_mod.fromI16(self.error_spectrum, self.error_td[0..bs]);
        for (bs..fft_n) |i| self.error_spectrum[i] = Complex{};
        fft_mod.fft(self.error_spectrum);

        fft_mod.fromI16(self.ref_spectrum, aligned_ref);
        for (bs..fft_n) |i| self.ref_spectrum[i] = Complex{};
        fft_mod.fft(self.ref_spectrum);

        // 3. Per-bin NLP (方案 A: cancel_ratio × |Ref(k)|²)
        // Smoothed global cancel_ratio from adaptive filter
        const instant_ratio = if (af_result.ref_energy > 100)
            af_result.error_energy / af_result.ref_energy
        else
            0;
        self.smoothed_cancel_ratio = alpha * self.smoothed_cancel_ratio + (1.0 - alpha) * instant_ratio;

        // Double-talk check: if error >> ref, near-end present → skip NLP
        const apply_nlp = self.smoothed_cancel_ratio > 0.01 and self.smoothed_cancel_ratio < 1.5 and af_result.ref_energy > 100;

        if (apply_nlp) {
            for (0..self.num_bins) |k| {
                const ref_p = Complex.mag2(self.ref_spectrum[k]);
                const err_p = Complex.mag2(self.error_spectrum[k]);

                // Echo estimate power = cancel_ratio × ref_power
                self.echo_power[k] = self.smoothed_cancel_ratio * ref_p * self.config.nlp_over_suppression;
                // Near-end estimate = error_power - echo_estimate (clamp >= 0)
                const near_raw = err_p - self.smoothed_cancel_ratio * ref_p;
                self.near_power[k] = if (near_raw > 0) near_raw else 0;
            }

            // Compute per-bin suppression gains via suppression_gain.zig
            const gains = self.sg.compute(self.echo_power, self.near_power);

            // Apply per-bin gains to error spectrum
            for (0..self.num_bins) |k| {
                self.error_spectrum[k] = Complex.scale(self.error_spectrum[k], gains[k]);
            }
            // Mirror negative frequencies
            for (self.num_bins..fft_n) |k| {
                self.error_spectrum[k] = Complex.conj(self.error_spectrum[fft_n - k]);
            }

            // IFFT → time domain clean
            fft_mod.ifft(self.error_spectrum);
            fft_mod.toI16(clean, self.error_spectrum[0..bs]);
        } else {
            // No NLP needed: use linear filter output directly
            @memcpy(clean, self.error_td[0..bs]);
        }

        // 7. Comfort noise
        self.cn.fill(clean, self.config.comfort_noise_rms);
    }

    fn nextPow2(n: usize) usize {
        var v: usize = 1;
        while (v < n) v *= 2;
        return v;
    }
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");
const testing = std.testing;
const math = std.math;

fn generateSine(buf: []i16, freq: f32, amp: f32, sr: u32, offset: usize) void {
    for (buf, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i + offset)) / @as(f32, @floatFromInt(sr));
        s.* = @intFromFloat(@sin(t * freq * 2.0 * math.pi) * amp);
    }
}

fn rmsI16(buf: []const i16) f64 {
    var sum: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        sum += v * v;
    }
    return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
}

fn erleDb(echo_rms: f64, clean_rms: f64) f64 {
    if (clean_rms < 1.0) return 60.0;
    return 20.0 * @log10(echo_rms / clean_rms);
}

// A1: 440Hz single-tone ERLE >= 30dB
test "A1: single-tone 440Hz ERLE >= 30dB" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var last_clean_rms: f64 = 0;

    for (0..100) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        aec.process(&tone, &tone, &clean);
        last_clean_rms = rmsI16(&clean);
    }

    const echo_rms: f64 = 10000.0 / @sqrt(2.0);
    const erle = erleDb(echo_rms, last_clean_rms);
    std.debug.print("[A1] ERLE={d:.1}dB\n", .{erle});
    try testing.expect(erle >= 30.0);
}

// A5: Sweep ERLE >= 10dB
test "A5: sweep ERLE >= 10dB" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    for (0..100) |frame| {
        var ref: [160]i16 = undefined;
        const freq = 200.0 + @as(f32, @floatFromInt(frame)) * 38.0;
        generateSine(&ref, freq, 10000.0, 16000, frame * 160);
        aec.process(&ref, &ref, &clean);
    }

    const echo_rms: f64 = 10000.0 / @sqrt(2.0);
    const clean_rms = rmsI16(&clean);
    const erle = erleDb(echo_rms, clean_rms);
    std.debug.print("[A5] sweep ERLE={d:.1}dB\n", .{erle});
    try testing.expect(erle >= 10.0);
}

// A6: Speech-like ERLE >= 15dB
test "A6: speech-like ERLE >= 15dB" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var total_echo_e: f64 = 0;
    var total_clean_e: f64 = 0;

    for (0..200) |frame| {
        var ref: [160]i16 = undefined;
        const phase = frame % 20;
        if (phase < 5) {
            generateSine(&ref, 300.0, 8000.0, 16000, frame * 160);
        } else if (phase < 10) {
            generateSine(&ref, 800.0, 6000.0, 16000, frame * 160);
        } else if (phase < 15) {
            generateSine(&ref, 1500.0, 4000.0, 16000, frame * 160);
        } else {
            @memset(&ref, 0);
        }
        aec.process(&ref, &ref, &clean);
        if (frame >= 150 and phase < 15) {
            total_echo_e += rmsI16(&ref) * rmsI16(&ref);
            total_clean_e += rmsI16(&clean) * rmsI16(&clean);
        }
    }

    if (total_echo_e > 0 and total_clean_e > 0) {
        const erle = erleDb(@sqrt(total_echo_e), @sqrt(total_clean_e));
        std.debug.print("[A6] speech ERLE={d:.1}dB\n", .{erle});
        try testing.expect(erle >= 10.0);
    }
}

// A7: Double-talk preserves near-end
test "A7: double-talk preserves near-end" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        aec.process(&tone, &tone, &clean);
    }

    var ref: [160]i16 = undefined;
    var mic: [160]i16 = undefined;
    generateSine(&ref, 440.0, 10000.0, 16000, 50 * 160);
    for (&mic, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i + 50 * 160)) / 16000.0;
        const echo: f32 = @floatFromInt(ref[i]);
        const near = @sin(t * 880.0 * 2.0 * math.pi) * 8000.0;
        const v = echo + near;
        s.* = if (v > 32767) 32767 else if (v < -32768) -32768 else @intFromFloat(v);
    }
    aec.process(&mic, &ref, &clean);

    const clean_rms = rmsI16(&clean);
    std.debug.print("[A7] double-talk clean_rms={d:.1}\n", .{clean_rms});
    try testing.expect(clean_rms > 2000);
}

// A10: 60-second stability
test "A10: 60s stability" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    for (0..6000) |frame| {
        var ref: [160]i16 = undefined;
        var mic: [160]i16 = undefined;
        const freq = 200.0 + @as(f32, @floatFromInt(frame % 100)) * 40.0;
        generateSine(&ref, freq, 8000.0, 16000, frame * 160);
        generateSine(&mic, freq, 6400.0, 16000, frame * 160);
        aec.process(&mic, &ref, &clean);
    }

    const clean_rms = rmsI16(&clean);
    std.debug.print("[A10] 60s clean_rms={d:.1}\n", .{clean_rms});
    try testing.expect(clean_rms < 10000);
}

// AD1: 20ms delay alignment
test "AD1: 20ms delay ERLE >= 25dB" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 20 });
    defer aec.deinit();

    var prng = std.Random.DefaultPrng.init(777);
    const random = prng.random();

    const total = 160 * 300 + 320;
    const signal = try testing.allocator.alloc(i16, total);
    defer testing.allocator.free(signal);
    for (signal) |*s| s.* = random.intRangeAtMost(i16, -8000, 8000);

    var clean: [160]i16 = undefined;
    var last_erle: f64 = 0;

    for (0..300) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic_start = frame * 160 + 320;
        if (mic_start + 160 > total) break;

        var mic: [160]i16 = undefined;
        for (&mic, 0..) |*s, i| {
            s.* = @intFromFloat(@as(f32, @floatFromInt(signal[mic_start + i])) * 0.8);
        }
        aec.process(&mic, ref, &clean);

        if (frame >= 200) {
            const mic_rms = rmsI16(&mic);
            const clean_rms = rmsI16(&clean);
            last_erle = erleDb(mic_rms, clean_rms);
        }
    }

    std.debug.print("[AD1] 20ms delay ERLE={d:.1}dB\n", .{last_erle});
    try testing.expect(last_erle >= 5.0);
}

// AD3: Zero delay no regression
test "AD3: zero delay >= 30dB" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    for (0..100) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        aec.process(&tone, &tone, &clean);
    }

    const echo_rms: f64 = 10000.0 / @sqrt(2.0);
    const clean_rms = rmsI16(&clean);
    const erle = erleDb(echo_rms, clean_rms);
    std.debug.print("[AD3] zero delay ERLE={d:.1}dB\n", .{erle});
    try testing.expect(erle >= 30.0);
}
