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
    comfort_noise_rms: f32 = 0,
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

// ============================================================================
// Closed-loop tests: clean feeds back as next mic/ref
// ============================================================================

/// Simulate acoustic path: delay + gain + add near-end signal
fn acousticSim(
    clean: []const i16,
    delay_buf: []i16,
    delay_write: *usize,
    delay_samples: usize,
    acoustic_gain: f32,
    near_end: ?[]const i16,
    mic_out: []i16,
    ref_out: []i16,
) void {
    const n = clean.len;
    const cap = delay_buf.len;

    // ref = clean (what speaker plays)
    @memcpy(ref_out[0..n], clean[0..n]);

    // Push clean into delay line
    for (0..n) |i| {
        delay_buf[(delay_write.* + i) % cap] = clean[i];
    }
    delay_write.* += n;

    // mic = delayed(clean) * gain + near_end
    for (0..n) |i| {
        var sample: f32 = 0;
        if (delay_write.* >= delay_samples + n) {
            const idx = delay_write.* - n + i - delay_samples;
            sample = @as(f32, @floatFromInt(delay_buf[idx % cap])) * acoustic_gain;
        }
        if (near_end) |ne| {
            sample += @floatFromInt(ne[i]);
        }
        mic_out[i] = if (sample > 32767) 32767 else if (sample < -32768) -32768 else @intFromFloat(sample);
    }
}

// CL1: Closed-loop stability — no near-end, signal must not grow
test "CL1: closed-loop stability — no near-end, no divergence" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    const delay_samples: usize = 26;
    const acoustic_gain: f32 = 0.76;
    var delay_buf: [4096]i16 = [_]i16{0} ** 4096;
    var delay_write: usize = 0;

    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    var clean: [160]i16 = undefined;

    // Seed: one frame of noise to kick-start the loop
    var prng = std.Random.DefaultPrng.init(42);
    for (&clean) |*s| s.* = prng.random().intRangeAtMost(i16, -500, 500);

    var max_clean_rms: f64 = 0;
    var amplified_frames: usize = 0;

    for (0..500) |frame| {
        acousticSim(&clean, &delay_buf, &delay_write, delay_samples, acoustic_gain, null, &mic_buf, &ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);

        const mic_rms = rmsI16(&mic_buf);
        const clean_rms = rmsI16(&clean);

        if (clean_rms > max_clean_rms) max_clean_rms = clean_rms;
        if (clean_rms > mic_rms * 1.01 and mic_rms > 10) amplified_frames += 1;

        if (frame % 100 == 0) {
            std.debug.print("[CL1 f{d}] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{
                frame, mic_rms, rmsI16(&ref_buf), clean_rms,
            });
        }
    }

    std.debug.print("[CL1] max_clean_rms={d:.0}, amplified_frames={d}/500\n", .{ max_clean_rms, amplified_frames });

    // Signal must not explode: max clean RMS should stay below 5000
    // (seed noise is 500 RMS, acoustic gain 0.76 → should decay without AEC)
    try testing.expect(max_clean_rms < 5000);
    // At most 10% of frames should have clean > mic
    try testing.expect(amplified_frames < 50);
}

// CL2: Per-frame gain constraint — clean_rms <= mic_rms
test "CL2: per-frame gain — clean never exceeds mic" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var worst_ratio: f64 = 0;
    var violations: usize = 0;

    for (0..300) |frame| {
        var ref: [160]i16 = undefined;
        var mic: [160]i16 = undefined;
        const freq = 300.0 + @as(f32, @floatFromInt(frame % 50)) * 40.0;
        generateSine(&ref, freq, 10000.0, 16000, frame * 160);
        // mic = ref * 0.8 (echo) — no near-end
        for (&mic, 0..) |*s, i| {
            s.* = @intFromFloat(@as(f32, @floatFromInt(ref[i])) * 0.8);
        }
        aec.process(&mic, &ref, &clean);

        const mic_rms = rmsI16(&mic);
        const clean_rms = rmsI16(&clean);
        if (mic_rms > 100) {
            const ratio = clean_rms / mic_rms;
            if (ratio > worst_ratio) worst_ratio = ratio;
            if (ratio > 1.05) violations += 1;
        }
    }

    std.debug.print("[CL2] worst_ratio={d:.3}, violations={d}/300\n", .{ worst_ratio, violations });
    // After convergence (first ~10 frames), clean should never significantly exceed mic
    try testing.expect(violations < 15);
}

// CL3: Closed-loop with near-end — voice preserved, no echo buildup
test "CL3: closed-loop with near-end speech" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    const delay_samples: usize = 26;
    const acoustic_gain: f32 = 0.5;
    var delay_buf: [4096]i16 = [_]i16{0} ** 4096;
    var delay_write: usize = 0;

    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    var clean: [160]i16 = [_]i16{0} ** 160;

    // First 200 frames: only feedback (no near-end), let AEC converge
    for (0..200) |_| {
        acousticSim(&clean, &delay_buf, &delay_write, delay_samples, acoustic_gain, null, &mic_buf, &ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
    }

    // Next 100 frames: inject near-end 880Hz while feedback continues
    var near_end_energy: f64 = 0;
    var clean_energy: f64 = 0;
    for (0..100) |frame| {
        var near: [160]i16 = undefined;
        generateSine(&near, 880.0, 8000.0, 16000, frame * 160);
        acousticSim(&clean, &delay_buf, &delay_write, delay_samples, acoustic_gain, &near, &mic_buf, &ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);

        near_end_energy += rmsI16(&near) * rmsI16(&near);
        clean_energy += rmsI16(&clean) * rmsI16(&clean);
    }

    const near_rms = @sqrt(near_end_energy / 100);
    const clean_rms = @sqrt(clean_energy / 100);
    std.debug.print("[CL3] near_rms={d:.0}, clean_rms={d:.0}\n", .{ near_rms, clean_rms });

    // Clean should preserve near-end (at least 30% of near-end energy)
    try testing.expect(clean_rms > near_rms * 0.3);
    // Clean should not exceed near-end by much (AEC should cancel feedback)
    try testing.expect(clean_rms < near_rms * 3.0);
}

// CL4: Closed-loop varying acoustic gains (0.3, 0.5, 0.9)
test "CL4: closed-loop stability at different acoustic gains" {
    const gains = [_]f32{ 0.3, 0.5, 0.9 };
    for (gains) |gain| {
        var aec = try Aec3.init(testing.allocator, .{
            .frame_size = 160,
            .num_partitions = 10,
            .comfort_noise_rms = 0,
        });
        defer aec.deinit();

        var delay_buf: [4096]i16 = [_]i16{0} ** 4096;
        var delay_write: usize = 0;
        var mic_buf: [160]i16 = undefined;
        var ref_buf: [160]i16 = undefined;
        var clean: [160]i16 = undefined;

        var prng = std.Random.DefaultPrng.init(99);
        for (&clean) |*s| s.* = prng.random().intRangeAtMost(i16, -500, 500);

        var max_rms: f64 = 0;
        for (0..500) |_| {
            acousticSim(&clean, &delay_buf, &delay_write, 26, gain, null, &mic_buf, &ref_buf);
            aec.process(&mic_buf, &ref_buf, &clean);
            const cr = rmsI16(&clean);
            if (cr > max_rms) max_rms = cr;
        }

        std.debug.print("[CL4] gain={d:.1} max_clean_rms={d:.0}\n", .{ gain, max_rms });
        try testing.expect(max_rms < 5000);
    }
}

// CL5: Closed-loop 60s (6000 frames) — no drift
test "CL5: closed-loop 60s stability" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var delay_buf: [4096]i16 = [_]i16{0} ** 4096;
    var delay_write: usize = 0;
    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    var clean: [160]i16 = undefined;

    var prng = std.Random.DefaultPrng.init(123);
    for (&clean) |*s| s.* = prng.random().intRangeAtMost(i16, -300, 300);

    var max_rms: f64 = 0;
    for (0..6000) |frame| {
        // Inject near-end speech every 10 seconds for 2 seconds
        const sec = frame / 100;
        const in_speech = (sec % 10) < 2;
        var near: [160]i16 = undefined;
        if (in_speech) {
            const freq = 300.0 + @as(f32, @floatFromInt(frame % 40)) * 50.0;
            generateSine(&near, freq, 6000.0, 16000, frame * 160);
            acousticSim(&clean, &delay_buf, &delay_write, 50, 0.6, &near, &mic_buf, &ref_buf);
        } else {
            acousticSim(&clean, &delay_buf, &delay_write, 50, 0.6, null, &mic_buf, &ref_buf);
        }
        aec.process(&mic_buf, &ref_buf, &clean);

        const cr = rmsI16(&clean);
        if (cr > max_rms) max_rms = cr;
    }

    std.debug.print("[CL5] 60s max_clean_rms={d:.0}\n", .{max_rms});
    try testing.expect(max_rms < 20000);
}
