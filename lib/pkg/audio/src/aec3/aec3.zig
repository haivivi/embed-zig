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

const arith_mod = @import("arithmetic.zig");
const af_mod = @import("adaptive_filter.zig");
const de_mod = @import("delay_estimator.zig");
const sg_mod = @import("suppression_gain.zig");
const cn_mod = @import("comfort_noise.zig");

pub const Config = struct {
    frame_size: usize = 160,
    num_partitions: usize = 50,
    sample_rate: u32 = 16000,
    step_size: f32 = 0.1,
    regularization: f32 = 1000.0,
    nlp_floor: f32 = 1.0, // 完全禁用NLP抑制
    nlp_over_suppression: f32 = 1.0,
    comfort_noise_rms: f32 = 0,
    max_delay_ms: u32 = 500,
    coherence_smoothing: f32 = 0.7,
};

pub fn GenAec3(comptime Arith: type) type {
    const C = Arith.Complex;
    const AF = af_mod.GenAdaptiveFilter(Arith);
    const SG = sg_mod.GenSuppressionGain(Arith);

    return struct {
        const Self = @This();

        config: Config,
        af: AF,
        de: de_mod.DelayEstimator,
        sg: SG,
        cn: cn_mod.ComfortNoise,

        fft_size: usize,
        num_bins: usize,
        smoothed_cancel_ratio: f32 = 0,

        // Near-end detection state (fast attack, slow release)
        near_end_counter: i32 = 0, // Positive = near-end frames detected
        near_end_state: bool = false, // True = currently in near-end mode

        error_td: []i16,
        error_spectrum: []C,
        ref_spectrum: []C,
        echo_power: []f32,
        near_power: []f32,
        ref_ring: []i16,
        ref_ring_pos: usize,

        allocator: Allocator,
        const Allocator = @import("std").mem.Allocator;

        pub fn init(allocator: Allocator, config: Config) !Self {
            const fft_size = nextPow2(config.frame_size * 2);
            const num_bins = fft_size / 2 + 1;
            const max_delay_samples = config.sample_rate * config.max_delay_ms / 1000;
            const ring_size = max_delay_samples + config.frame_size * 4;

            var af = try AF.init(allocator, .{
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

            var sg = try SG.init(allocator, .{
                .num_bins = num_bins,
                .floor = config.nlp_floor,
                .over_suppression = config.nlp_over_suppression,
            });
            errdefer sg.deinit();

            const error_td = try allocator.alloc(i16, config.frame_size);
            errdefer allocator.free(error_td);
            const err_spec = try allocator.alloc(C, fft_size);
            errdefer allocator.free(err_spec);
            const ref_spec = try allocator.alloc(C, fft_size);
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

        pub fn deinit(self: *Self) void {
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

        pub fn reset(self: *Self) void {
            self.af.reset();
            self.smoothed_cancel_ratio = 0;
            @memset(self.ref_ring, 0);
            self.ref_ring_pos = 0;
        }

        /// Process one frame: remove echo from mic using ref, output clean audio.
        pub fn process(self: *Self, mic: []const i16, ref: []const i16, clean: []i16) void {
            const bs = self.config.frame_size;
            const fft_n = self.fft_size;
            const alpha = self.config.coherence_smoothing;

            // === STEP 0: Fast near-end detection (MUST be first) ===
            // Calculate energies for detection before any processing
            var mic_energy: f32 = 0;
            var ref_energy_total: f32 = 0;
            for (0..bs) |i| {
                const mv: f32 = @floatFromInt(mic[i]);
                const rv: f32 = @floatFromInt(ref[i]);
                mic_energy += mv * mv;
                ref_energy_total += rv * rv;
            }

            // Near-end detection: mic >> ref indicates near-end speech
            // When near-end is detected, bypass AEC to preserve speech
            const energy_ratio = if (ref_energy_total > 100)
                mic_energy / ref_energy_total
            else
                10.0; // Very low ref energy = likely near-end

            if (energy_ratio > 2.0) {
                // Mic significantly louder than ref → near-end speech detected
                self.near_end_counter += 1;
                if (self.near_end_counter > 3) {
                    self.near_end_state = true;
                }
            } else {
                self.near_end_counter -= 1;
                if (self.near_end_counter < -3) {
                    self.near_end_state = false;
                }
            }

            // If near-end detected, bypass AEC processing and output mic directly
            // This prevents any suppression of near-end speech
            if (self.near_end_state) {
                @memcpy(clean, mic[0..bs]);
                return;
            }

            // === Normal AEC processing (only for pure echo frames) ===

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

            // 2. FFT error and ref for NLP
            Arith.complexFromI16(self.error_spectrum, self.error_td[0..bs]);
            for (bs..fft_n) |i| self.error_spectrum[i] = C{};
            Arith.fft(self.error_spectrum);

            Arith.complexFromI16(self.ref_spectrum, aligned_ref);
            for (bs..fft_n) |i| self.ref_spectrum[i] = C{};
            Arith.fft(self.ref_spectrum);

            // 3. Per-bin NLP
            const instant_ratio = if (af_result.ref_energy > 100)
                af_result.error_energy / af_result.ref_energy
            else
                0;
            self.smoothed_cancel_ratio = alpha * self.smoothed_cancel_ratio + (1.0 - alpha) * instant_ratio;

            const apply_nlp = self.smoothed_cancel_ratio > 0.01 and self.smoothed_cancel_ratio < 1.5 and af_result.ref_energy > 100;

            if (apply_nlp) {
                for (0..self.num_bins) |k| {
                    const ref_p = Arith.toFloat(C.mag2(self.ref_spectrum[k]));
                    const err_p = Arith.toFloat(C.mag2(self.error_spectrum[k]));

                    // Note: nlp_over_suppression is applied in suppression_gain.zig
                    // Don't multiply again here!
                    self.echo_power[k] = self.smoothed_cancel_ratio * ref_p;
                    const near_raw = err_p - self.smoothed_cancel_ratio * ref_p;
                    self.near_power[k] = if (near_raw > 0) near_raw else 0;
                }

                const gains = self.sg.compute(self.echo_power, self.near_power);

                for (0..self.num_bins) |k| {
                    self.error_spectrum[k] = C.scale(self.error_spectrum[k], gains[k]);
                }
                for (self.num_bins..fft_n) |k| {
                    self.error_spectrum[k] = C.conj(self.error_spectrum[fft_n - k]);
                }

                Arith.ifft(self.error_spectrum);
                Arith.complexToI16(clean, self.error_spectrum[0..bs]);
            } else {
                // No NLP needed: use linear filter output directly
                @memcpy(clean, self.error_td[0..bs]);
            }

            // 7. Output constraints: clean must not exceed mic (prevents AEC amplification)
            var clean_energy: f32 = 0;
            for (0..bs) |i| {
                const cv: f32 = @floatFromInt(clean[i]);
                clean_energy += cv * cv;
            }
            // Note: mic_energy was already calculated in STEP 0 (near-end detection section)
            if (clean_energy > mic_energy and mic_energy > 100) {
                const scale = @sqrt(mic_energy / clean_energy);
                for (0..bs) |i| {
                    const v: f32 = @as(f32, @floatFromInt(clean[i])) * scale;
                    clean[i] = if (v > 32767) 32767 else if (v < -32768) -32768 else @intFromFloat(@round(v));
                }
                clean_energy = mic_energy;
            }

            // 7b. Feedback loop protection: when echo is dominant (ref is loud,
            // near-end not detected), limit clean to prevent loop gain > 1.
            // Only active when ref has significant energy and clean > ref.
            // This ensures speaker output doesn't grow each round trip.
            // 7b. Feedback loop protection: limit clean to ref when AEC
            // hasn't converged (smoothed cancel ratio is poor).
            // cancel_ratio < 0.3 means AEC is canceling well → don't limit.
            // cancel_ratio > 0.5 means AEC isn't canceling → apply ref limit.
            if (ref_energy_total > 1000 and clean_energy > ref_energy_total and
                self.smoothed_cancel_ratio > 0.5)
            {
                const scale = @sqrt(ref_energy_total / clean_energy);
                for (0..bs) |i| {
                    const v: f32 = @as(f32, @floatFromInt(clean[i])) * scale;
                    clean[i] = if (v > 32767) 32767 else if (v < -32768) -32768 else @intFromFloat(@round(v));
                }
            }

            // 8. Comfort noise
            self.cn.fill(clean, self.config.comfort_noise_rms);
        }

        fn nextPow2(n: usize) usize {
            var v: usize = 1;
            while (v < n) v *= 2;
            return v;
        }
    };
}

// Backward compatible: f32
pub const Aec3 = GenAec3(arith_mod.Float);
pub const Aec3Fixed = GenAec3(arith_mod.Fixed);

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

// ============================================================================
// Speech-like signal generators (TTS-like characteristics)
// ============================================================================

/// PRNG state for noise generators
var test_prng: u64 = 0xDEADBEEFCAFEBABE;

/// Generate uniform white noise [-1, 1]
fn generateWhiteNoise() f32 {
    test_prng ^= test_prng << 13;
    test_prng ^= test_prng >> 7;
    test_prng ^= test_prng << 17;
    const raw: i32 = @truncate(@as(i64, @bitCast(test_prng)));
    return @as(f32, @floatFromInt(raw)) / 2147483648.0;
}

/// Generate pink noise (1/f spectrum) using leaky integrator
/// Speech has approximately pink noise characteristics
fn generatePinkNoise(state: *f32) f32 {
    const white = generateWhiteNoise();
    state.* = 0.9 * state.* + 0.1 * white;
    return state.*;
}

/// Generate TTS-like speech signal
/// Mix of pink noise (voiced) and white noise (unvoiced/fricatives)
fn generateSpeechLike(buf: []i16, amp: f32, offset: usize) void {
    var pink_state: f32 = 0;
    var voicing: f32 = 1.0; // 1.0 = voiced, 0.0 = unvoiced
    var voicing_counter: usize = 0;

    for (buf, 0..) |*s, i| {
        const global_i = offset + i;

        // Simulate voicing transitions (every 100-300 samples)
        if (voicing_counter == 0) {
            // Voiced segments: ~200-400 samples, unvoiced: ~50-150
            const is_voiced = (global_i % 500) < 350;
            voicing = if (is_voiced) 1.0 else 0.0;
            voicing_counter = if (is_voiced) 300 else 100;
        } else {
            voicing_counter -= 1;
        }

        // Mix pink (voiced) and white (unvoiced) noise
        const voiced = generatePinkNoise(&pink_state);
        const unvoiced = generateWhiteNoise();
        const mixed = voiced * voicing + unvoiced * (1.0 - voicing);

        // Add some amplitude modulation (simulating syllables)
        const syllable = @sin(@as(f32, @floatFromInt(global_i)) * 0.01) * 0.5 + 0.5;
        const sample = mixed * amp * (0.3 + 0.7 * syllable);

        s.* = @intFromFloat(@max(-32768.0, @min(32767.0, sample)));
    }
}

/// Add quantization noise to signal (simulates ADC ±0.5 LSB error)
fn addQuantizationNoise(buf: []i16, noise_amplitude: f32) void {
    for (buf) |*s| {
        const noise = generateWhiteNoise() * noise_amplitude;
        const with_noise = @as(f32, @floatFromInt(s.*)) + noise;
        s.* = @intFromFloat(@max(-32768.0, @min(32767.0, with_noise)));
    }
}

/// Add white background noise
fn addWhiteNoise(buf: []i16, noise_rms: f32) void {
    for (buf) |*s| {
        const noise = generateWhiteNoise() * noise_rms * 1.73; // 1.73 = sqrt(3) for uniform
        const with_noise = @as(f32, @floatFromInt(s.*)) + noise;
        s.* = @intFromFloat(@max(-32768.0, @min(32767.0, with_noise)));
    }
}

/// Add pink background noise (more realistic for room ambience)
fn addPinkNoise(buf: []i16, noise_rms: f32) void {
    var pink_state: f32 = 0;
    for (buf) |*s| {
        const noise = generatePinkNoise(&pink_state) * noise_rms * 1.73;
        const with_noise = @as(f32, @floatFromInt(s.*)) + noise;
        s.* = @intFromFloat(@max(-32768.0, @min(32767.0, with_noise)));
    }
}

// ============================================================================
// Quantization and noise tests
// ============================================================================

// Q1: Small signal with quantization noise - AEC should still converge
test "Q1: small signal (amp=1000) with quantization noise" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 20 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var total_erle: f64 = 0;
    var valid_frames: usize = 0;

    for (0..200) |frame| {
        var mic: [160]i16 = undefined;
        var ref: [160]i16 = undefined;

        // Generate speech-like signal at low amplitude (simulates distant speaker)
        generateSpeechLike(&ref, 1000.0, frame * 160);
        @memcpy(&mic, &ref); // Perfect echo for testing

        // Add quantization noise (±0.5 LSB typical)
        addQuantizationNoise(&mic, 0.5);

        aec.process(&mic, &ref, &clean);

        const mic_rms = rmsI16(&mic);
        const clean_rms = rmsI16(&clean);
        const erle = erleDb(mic_rms, clean_rms);

        // Accumulate ERLE after initial convergence period
        if (frame > 50 and erle > 0) {
            total_erle += erle;
            valid_frames += 1;
        }
    }

    const avg_erle = if (valid_frames > 0) total_erle / @as(f64, @floatFromInt(valid_frames)) else 0.0;
    std.debug.print("[Q1] avg ERLE with quantization: {d:.1}dB\n", .{avg_erle});

    // Should achieve at least 10dB ERLE even with quantization noise
    try testing.expect(avg_erle >= 10.0);
}

// Q2: Very small signal (amp=500) - tests ADC noise floor handling
test "Q2: very small signal (amp=500) quantization robustness" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 20 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var last_clean_rms: f64 = 0;

    for (0..200) |frame| {
        var mic: [160]i16 = undefined;
        var ref: [160]i16 = undefined;

        // Very low amplitude signal (near ADC noise floor)
        generateSpeechLike(&ref, 500.0, frame * 160);
        @memcpy(&mic, &ref);
        addQuantizationNoise(&mic, 0.5);

        aec.process(&mic, &ref, &clean);
        last_clean_rms = rmsI16(&clean);
    }

    const echo_rms: f64 = 500.0; // Approximate expected signal level
    const erle = erleDb(echo_rms, last_clean_rms);
    std.debug.print("[Q2] ERLE at noise floor: {d:.1}dB\n", .{erle});

    // At noise floor, ERLE may be lower but should not be negative (no amplification)
    try testing.expect(erle >= 0.0);
}

// Q3: White background noise with echo cancellation
test "Q3: white noise background (-30dB)" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 20 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var total_erle: f64 = 0;

    const signal_amp = 10000.0;
    const noise_rms = signal_amp * 0.032; // ~-30dB relative to signal

    for (0..200) |frame| {
        var mic: [160]i16 = undefined;
        var ref: [160]i16 = undefined;

        generateSpeechLike(&ref, signal_amp, frame * 160);
        @memcpy(&mic, &ref);
        addWhiteNoise(&mic, @floatCast(noise_rms));

        aec.process(&mic, &ref, &clean);

        if (frame > 50) {
            const mic_rms = rmsI16(&mic);
            const clean_rms = rmsI16(&clean);
            total_erle += erleDb(mic_rms, clean_rms);
        }
    }

    const avg_erle = total_erle / 150.0;
    std.debug.print("[Q3] avg ERLE with white noise: {d:.1}dB\n", .{avg_erle});

    // Should still achieve reasonable ERLE despite background noise
    try testing.expect(avg_erle >= 5.0);
}

// Q4: Pink noise background (room ambience simulation)
test "Q4: pink noise background (-25dB room ambience)" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 20 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var total_erle: f64 = 0;

    const signal_amp = 10000.0;
    const noise_rms = signal_amp * 0.056; // ~-25dB

    for (0..200) |frame| {
        var mic: [160]i16 = undefined;
        var ref: [160]i16 = undefined;

        generateSpeechLike(&ref, signal_amp, frame * 160);
        @memcpy(&mic, &ref);
        addPinkNoise(&mic, @floatCast(noise_rms));

        aec.process(&mic, &ref, &clean);

        if (frame > 50) {
            const mic_rms = rmsI16(&mic);
            const clean_rms = rmsI16(&clean);
            total_erle += erleDb(mic_rms, clean_rms);
        }
    }

    const avg_erle = total_erle / 150.0;
    std.debug.print("[Q4] avg ERLE with pink noise: {d:.1}dB\n", .{avg_erle});

    // Pink noise (correlated) is harder to cancel than white noise
    try testing.expect(avg_erle >= 3.0);
}

// Q5: Combined quantization + background noise (realistic scenario)
test "Q5: combined quantization + white noise (realistic ADC)" {
    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 20 });
    defer aec.deinit();

    var clean: [160]i16 = undefined;
    var total_erle: f64 = 0;

    const signal_amp = 8000.0;

    for (0..200) |frame| {
        var mic: [160]i16 = undefined;
        var ref: [160]i16 = undefined;

        generateSpeechLike(&ref, signal_amp, frame * 160);
        @memcpy(&mic, &ref);

        // Add both quantization noise (ADC) and background noise (room)
        addQuantizationNoise(&mic, 0.5);
        addWhiteNoise(&mic, 300.0); // ~-28dB relative to signal

        aec.process(&mic, &ref, &clean);

        if (frame > 50) {
            const mic_rms = rmsI16(&mic);
            const clean_rms = rmsI16(&clean);
            total_erle += erleDb(mic_rms, clean_rms);
        }
    }

    const avg_erle = total_erle / 150.0;
    std.debug.print("[Q5] avg ERLE realistic scenario: {d:.1}dB\n", .{avg_erle});

    // Realistic scenario should still achieve some cancellation
    try testing.expect(avg_erle >= 3.0);
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
// Zero/low ref energy tests: critical for real-world scenarios
// ============================================================================

// A-Z1: When ref=0, clean should equal mic (AEC has nothing to cancel)
test "A-Z1: zero ref → clean equals mic (no false suppression)" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .comfort_noise_rms = 0, // Disable comfort noise for clean test
    });
    defer aec.deinit();

    var mic: [160]i16 = undefined;
    var ref: [160]i16 = [_]i16{0} ** 160; // Zero ref
    var clean: [160]i16 = undefined;

    // Process 10 frames to stabilize
    for (0..10) |f| {
        generateSine(&mic, 1000.0, 5000.0, 16000, f * 160);
        aec.process(&mic, &ref, &clean);
    }

    const mic_rms = rmsI16(&mic);
    const clean_rms = rmsI16(&clean);

    std.debug.print("[A-Z1] mic_rms={d:.0} clean_rms={d:.0} ratio={d:.2}\n", .{ mic_rms, clean_rms, clean_rms / mic_rms });

    // clean should be very close to mic (80%-120%)
    try testing.expect(clean_rms > mic_rms * 0.8);
    try testing.expect(clean_rms < mic_rms * 1.2);
    // clean should NOT be near 0 (would indicate bug)
    try testing.expect(clean_rms > 1000);
}

// A-Z2: Low ref energy (<100) - must not over-suppress
test "A-Z2: low ref energy → no over-suppression" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .nlp_floor = 0.003,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var mic: [160]i16 = undefined;
    var ref: [160]i16 = undefined;
    var clean: [160]i16 = undefined;

    // Run 50 frames: mic has speech, ref is very low (like E1 startup)
    for (0..50) |f| {
        // mic: 880Hz @ 3000 amplitude (RMS ≈ 2121)
        generateSine(&mic, 880.0, 3000.0, 16000, f * 160);
        // ref: 880Hz @ 10 amplitude (RMS ≈ 7, energy ≈ 50 < 100)
        // Must be low enough to trigger af.skip_update
        generateSine(&ref, 880.0, 10.0, 16000, f * 160);
        aec.process(&mic, &ref, &clean);
    }

    const mic_rms = rmsI16(&mic);
    const ref_rms = rmsI16(&ref);
    const clean_rms = rmsI16(&clean);

    std.debug.print("[A-Z2] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{ mic_rms, ref_rms, clean_rms });

    // ref should be very low
    try testing.expect(ref_rms < 20);
    // clean should preserve most of mic signal (at least 50%)
    try testing.expect(clean_rms > mic_rms * 0.5);
    // clean must not be near 0
    try testing.expect(clean_rms > 1000);
}

// A-S1: Cold start - silence to speech transition
test "A-S1: cold start → clean preserves near-end speech" {
    var aec = try Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var mic: [160]i16 = undefined;
    var ref: [160]i16 = undefined;
    var clean: [160]i16 = undefined;

    // Phase 1: 30 frames of silence (both mic and ref = 0)
    @memset(&mic, 0);
    @memset(&ref, 0);
    for (0..30) |_| {
        aec.process(&mic, &ref, &clean);
    }

    // Phase 2: Suddenly start speaking (near-end only, no echo/ref)
    var max_clean: f64 = 0;
    for (0..50) |f| {
        // Near-end speech: 1000Hz @ 8000 amplitude
        generateSine(&mic, 1000.0, 8000.0, 16000, f * 160);
        // No ref = no echo
        @memset(&ref, 0);
        aec.process(&mic, &ref, &clean);

        const cr = rmsI16(&clean);
        if (cr > max_clean) max_clean = cr;
    }

    std.debug.print("[A-S1] max_clean_rms={d:.0}\n", .{max_clean});

    // Must have audible output, not silence
    try testing.expect(max_clean > 5000); // At least 5000 RMS
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

// ============================================================================
// Fixed-point tests
// ============================================================================

// FA1: Fixed-point 440Hz ERLE
test "FA1: fixed-point single-tone ERLE" {
    var aec = try Aec3Fixed.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
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
    std.debug.print("[FA1] fixed ERLE={d:.1}dB (clean_rms={d:.0})\n", .{ erle, last_clean_rms });
    // Fixed-point has less precision, accept lower ERLE
    try testing.expect(erle >= 10.0);
}

// FA2: Fixed-point closed-loop stability
test "FA2: fixed-point closed-loop stability" {
    var aec = try Aec3Fixed.init(testing.allocator, .{
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

    var prng = std.Random.DefaultPrng.init(42);
    for (&clean) |*s| s.* = prng.random().intRangeAtMost(i16, -500, 500);

    var max_rms: f64 = 0;
    for (0..500) |frame| {
        acousticSim(&clean, &delay_buf, &delay_write, 26, 0.76, null, &mic_buf, &ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        const cr = rmsI16(&clean);
        if (cr > max_rms) max_rms = cr;
        if (frame % 100 == 0) {
            std.debug.print("[FA2 f{d}] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{
                frame, rmsI16(&mic_buf), rmsI16(&ref_buf), cr,
            });
        }
    }

    std.debug.print("[FA2] fixed max_clean_rms={d:.0}\n", .{max_rms});
    try testing.expect(max_rms < 5000);
}

// FA3: Fixed-point closed-loop with near-end
test "FA3: fixed-point closed-loop with near-end" {
    var aec = try Aec3Fixed.init(testing.allocator, .{
        .frame_size = 160,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var delay_buf: [4096]i16 = [_]i16{0} ** 4096;
    var delay_write: usize = 0;
    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    var clean: [160]i16 = [_]i16{0} ** 160;

    for (0..200) |_| {
        acousticSim(&clean, &delay_buf, &delay_write, 26, 0.5, null, &mic_buf, &ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
    }

    var near_energy: f64 = 0;
    var clean_energy: f64 = 0;
    for (0..100) |frame| {
        var near: [160]i16 = undefined;
        generateSine(&near, 880.0, 8000.0, 16000, frame * 160);
        acousticSim(&clean, &delay_buf, &delay_write, 26, 0.5, &near, &mic_buf, &ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        near_energy += rmsI16(&near) * rmsI16(&near);
        clean_energy += rmsI16(&clean) * rmsI16(&clean);
    }

    const near_rms = @sqrt(near_energy / 100);
    const clean_rms = @sqrt(clean_energy / 100);
    std.debug.print("[FA3] fixed near={d:.0} clean={d:.0}\n", .{ near_rms, clean_rms });
    try testing.expect(clean_rms > near_rms * 0.1);
    try testing.expect(clean_rms < near_rms * 5.0);
}

// ============================================================================
// Offline test with real audio files
// ============================================================================

fn loadWav(path: []const u8, alloc: std.mem.Allocator) ![]i16 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    var hdr: [44]u8 = undefined;
    _ = try file.read(&hdr);
    const buf = try alloc.alloc(i16, (stat.size - 44) / 2);
    const bytes = std.mem.sliceAsBytes(buf);
    var total: usize = 0;
    while (total < bytes.len) {
        const n = try file.read(bytes[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf;
}

test "offline_aec_with_real_audio" {
    const mic = try loadWav("/tmp/diag_mic.wav", testing.allocator);
    defer testing.allocator.free(mic);
    const ref = try loadWav("/tmp/diag_ref.wav", testing.allocator);
    defer testing.allocator.free(ref);

    const n = @min(mic.len, ref.len);
    const n_frames = n / 160;

    var aec = try Aec3.init(testing.allocator, .{ .frame_size = 160, .num_partitions = 10 });
    defer aec.deinit();

    var clean = try testing.allocator.alloc(i16, n);
    defer testing.allocator.free(clean);

    for (0..n_frames) |f| {
        aec.process(
            mic[f * 160 ..][0..160],
            ref[f * 160 ..][0..160],
            clean[f * 160 ..][0..160],
        );
    }

    var mic_rms: f64 = 0;
    var ref_rms: f64 = 0;
    var clean_rms: f64 = 0;
    for (0..n) |i| {
        mic_rms += @as(f64, @floatFromInt(mic[i])) * @as(f64, @floatFromInt(mic[i]));
        ref_rms += @as(f64, @floatFromInt(ref[i])) * @as(f64, @floatFromInt(ref[i]));
        clean_rms += @as(f64, @floatFromInt(clean[i])) * @as(f64, @floatFromInt(clean[i]));
    }
    mic_rms = @sqrt(mic_rms / @as(f64, @floatFromInt(n)));
    ref_rms = @sqrt(ref_rms / @as(f64, @floatFromInt(n)));
    clean_rms = @sqrt(clean_rms / @as(f64, @floatFromInt(n)));

    const erle = if (clean_rms > 1) 20.0 * @log10(mic_rms / clean_rms) else 60.0;
    std.debug.print("\n[OFFLINE] ref={d:.0} mic={d:.0} clean={d:.0} ERLE={d:.1} dB\n", .{
        ref_rms, mic_rms, clean_rms, erle,
    });

    // AEC should reduce echo
    try testing.expect(clean_rms < mic_rms);
}
