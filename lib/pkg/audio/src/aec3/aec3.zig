//! AEC3 — Pure Zig Acoustic Echo Cancellation
//!
//! Complete pipeline: FFT → adaptive filter → NLP → comfort noise → IFFT.
//! Replaces SpeexDSP AEC with dramatically better speech-segment ERLE.
//!
//! ## Usage
//!
//! ```zig
//! var aec = try Aec3.init(allocator, .{});
//! defer aec.deinit();
//!
//! aec.process(&mic_frame, &ref_frame, &clean_frame);
//! ```

const fft_mod = @import("fft.zig");
const af_mod = @import("adaptive_filter.zig");
const sg_mod = @import("suppression_gain.zig");
const cn_mod = @import("comfort_noise.zig");

const Complex = fft_mod.Complex;

pub const Config = struct {
    frame_size: usize = 160,
    num_partitions: usize = 50,
    sample_rate: u32 = 16000,
    step_size: f32 = 0.5,
    regularization: f32 = 100.0,
    nlp_floor: f32 = 0.01,
    nlp_over_suppression: f32 = 1.5,
    comfort_noise_rms: f32 = 30.0,
};

pub const Aec3 = struct {
    config: Config,
    af: af_mod.AdaptiveFilter,
    sg: sg_mod.SuppressionGain,
    cn: cn_mod.ComfortNoise,

    fft_size: usize,
    num_bins: usize,

    // Work buffers for NLP
    mic_spectrum: []Complex,
    error_spectrum: []Complex,
    ref_spectrum: []Complex,
    work: []Complex,

    allocator: Allocator,

    const Allocator = @import("std").mem.Allocator;

    pub fn init(allocator: Allocator, config: Config) !Aec3 {
        const fft_size = nextPow2(config.frame_size * 2);
        const num_bins = fft_size / 2 + 1;

        var af = try af_mod.AdaptiveFilter.init(allocator, .{
            .block_size = config.frame_size,
            .num_partitions = config.num_partitions,
            .step_size = config.step_size,
            .regularization = config.regularization,
        });
        errdefer af.deinit();

        var sg = try sg_mod.SuppressionGain.init(allocator, .{
            .num_bins = num_bins,
            .floor = config.nlp_floor,
            .over_suppression = config.nlp_over_suppression,
        });
        errdefer sg.deinit();

        const mic_spec = try allocator.alloc(Complex, fft_size);
        errdefer allocator.free(mic_spec);
        const err_spec = try allocator.alloc(Complex, fft_size);
        errdefer allocator.free(err_spec);
        const ref_spec = try allocator.alloc(Complex, fft_size);
        errdefer allocator.free(ref_spec);
        const work = try allocator.alloc(Complex, fft_size);
        errdefer allocator.free(work);

        return .{
            .config = config,
            .af = af,
            .sg = sg,
            .cn = cn_mod.ComfortNoise.init(.{ .noise_floor_rms = config.comfort_noise_rms }),
            .fft_size = fft_size,
            .num_bins = num_bins,
            .mic_spectrum = mic_spec,
            .error_spectrum = err_spec,
            .ref_spectrum = ref_spec,
            .work = work,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Aec3) void {
        self.allocator.free(self.work);
        self.allocator.free(self.ref_spectrum);
        self.allocator.free(self.error_spectrum);
        self.allocator.free(self.mic_spectrum);
        self.sg.deinit();
        self.af.deinit();
    }

    pub fn reset(self: *Aec3) void {
        self.af.reset();
    }

    /// Process one frame: remove echo from mic using ref, output clean audio.
    pub fn process(self: *Aec3, mic: []const i16, ref: []const i16, clean: []i16) void {
        const bs = self.config.frame_size;
        const fft_n = self.fft_size;

        // 1. Linear adaptive filter: produces error (mic - estimated_echo)
        var error_td: [4096]i16 = [_]i16{0} ** 4096;
        const af_result = self.af.process(mic, ref, error_td[0..bs]);

        // 2. FFT the error signal for NLP
        fft_mod.fromI16(self.error_spectrum, error_td[0..bs]);
        // Zero-pad
        for (bs..fft_n) |i| self.error_spectrum[i] = Complex{};
        fft_mod.fft(self.error_spectrum);

        // 3. FFT the ref signal
        fft_mod.fromI16(self.ref_spectrum, ref);
        for (bs..fft_n) |i| self.ref_spectrum[i] = Complex{};
        fft_mod.fft(self.ref_spectrum);

        // 4. Compute echo and near-end power estimates
        var echo_power: [4096]f32 = [_]f32{0} ** 4096;
        var near_power: [4096]f32 = [_]f32{0} ** 4096;

        for (0..self.num_bins) |k| {
            // Residual echo power ≈ proportional to ref power × filter error ratio
            const ref_p = Complex.mag2(self.ref_spectrum[k]);
            const err_p = Complex.mag2(self.error_spectrum[k]);

            // Simple heuristic: if ref is active and error is high,
            // the error likely contains residual echo
            if (af_result.ref_energy > 100) {
                // Estimate residual echo as fraction of ref power
                // scaled by how much the filter didn't cancel
                const cancel_ratio = if (af_result.ref_energy > 0)
                    af_result.error_energy / af_result.ref_energy
                else
                    0;
                echo_power[k] = ref_p * cancel_ratio;
            }
            near_power[k] = err_p;
        }

        // 5. NLP: compute suppression gains
        _ = self.sg.compute(echo_power[0..self.num_bins], near_power[0..self.num_bins]);

        // 6. Apply gains to error spectrum
        for (0..self.num_bins) |k| {
            self.error_spectrum[k] = Complex.scale(self.error_spectrum[k], self.sg.gains[k]);
        }
        // Mirror for negative frequencies
        for (self.num_bins..fft_n) |k| {
            self.error_spectrum[k] = Complex.conj(self.error_spectrum[fft_n - k]);
        }

        // 7. IFFT → time domain clean signal
        fft_mod.ifft(self.error_spectrum);
        fft_mod.toI16(clean, self.error_spectrum[0..bs]);

        // 8. Comfort noise
        self.cn.fill(clean, self.config.comfort_noise_rms);
    }

    fn nextPow2(n: usize) usize {
        var v: usize = 1;
        while (v < n) v *= 2;
        return v;
    }
};

// ============================================================================
// Tests A1-A10
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

fn goertzel(samples: []const i16, freq: f64, sr: f64) f64 {
    const n: f64 = @floatFromInt(samples.len);
    const k = @round(freq * n / sr);
    const w = 2.0 * math.pi * k / n;
    const coeff = 2.0 * @cos(w);
    var s0: f64 = 0;
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (samples) |s| {
        s0 = @as(f64, @floatFromInt(s)) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

// A1: 440Hz single-tone ERLE >= 30dB
test "A1: single-tone 440Hz ERLE >= 30dB" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
    });
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

    std.debug.print("[A1] echo={d:.0}, clean={d:.1}, ERLE={d:.1}dB\n", .{ echo_rms, last_clean_rms, erle });
    try testing.expect(erle >= 30.0);
}

// A5: Sweep ERLE >= 10dB
test "A5: sweep 200→4000Hz ERLE >= 10dB" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
    });
    defer aec.deinit();

    var clean: [160]i16 = undefined;

    // Run 100 frames of sweep (mic == ref, pure echo)
    for (0..100) |frame| {
        var ref: [160]i16 = undefined;
        const freq = 200.0 + @as(f32, @floatFromInt(frame)) * 38.0;
        generateSine(&ref, freq, 10000.0, 16000, frame * 160);
        aec.process(&ref, &ref, &clean);
    }

    const echo_rms: f64 = 10000.0 / @sqrt(2.0);
    const clean_rms = rmsI16(&clean);
    const erle = erleDb(echo_rms, clean_rms);

    std.debug.print("[A5] sweep: echo={d:.0}, clean={d:.1}, ERLE={d:.1}dB\n", .{ echo_rms, clean_rms, erle });
    try testing.expect(erle >= 10.0);
}

// A6: TTS-like speech ERLE >= 15dB (simulated with multi-tone)
test "A6: speech-like signal ERLE >= 15dB" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
    });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var total_echo_energy: f64 = 0;
    var total_clean_energy: f64 = 0;

    // Simulate speech: alternating bursts of different frequencies + silence
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
            @memset(&ref, 0); // silence between "words"
        }

        aec.process(&ref, &ref, &clean);

        // Measure only non-silent frames (last 50 frames, converged)
        if (frame >= 150 and phase < 15) {
            total_echo_energy += rmsI16(&ref) * rmsI16(&ref);
            total_clean_energy += rmsI16(&clean) * rmsI16(&clean);
        }
    }

    if (total_echo_energy > 0 and total_clean_energy > 0) {
        const echo_rms = @sqrt(total_echo_energy);
        const clean_rms = @sqrt(total_clean_energy);
        const erle = erleDb(echo_rms, clean_rms);
        std.debug.print("[A6] speech: ERLE={d:.1}dB\n", .{erle});
        try testing.expect(erle >= 15.0);
    }
}

// A7: Double-talk — near-end preserved
test "A7: double-talk preserves near-end" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
    });
    defer aec.deinit();

    var clean: [160]i16 = undefined;

    // Pre-converge on 440Hz
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        aec.process(&tone, &tone, &clean);
    }

    // Now: ref=440Hz, mic=440Hz+880Hz (double-talk)
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

    // Clean should have significant energy (near-end 880Hz preserved)
    const clean_rms = rmsI16(&clean);
    std.debug.print("[A7] double-talk clean_rms={d:.1}\n", .{clean_rms});
    try testing.expect(clean_rms > 2000);
}

// A10: Long-running stability — 60 seconds, no crash/leak
test "A10: 60-second stability" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
    });
    defer aec.deinit();

    var clean: [160]i16 = undefined;

    // 60 seconds = 6000 frames at 16kHz/160
    for (0..6000) |frame| {
        var ref: [160]i16 = undefined;
        var mic: [160]i16 = undefined;
        const freq = 200.0 + @as(f32, @floatFromInt(frame % 100)) * 40.0;
        generateSine(&ref, freq, 8000.0, 16000, frame * 160);
        generateSine(&mic, freq, 6400.0, 16000, frame * 160); // 0.8x echo

        aec.process(&mic, &ref, &clean);
    }

    // Just verify no crash and clean output is reasonable
    const clean_rms = rmsI16(&clean);
    std.debug.print("[A10] 60s stability: final clean_rms={d:.1}\n", .{clean_rms});
    try testing.expect(clean_rms < 10000);
}
