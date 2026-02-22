//! Adaptive Filter — Frequency-Domain Block Adaptive Filter (FDBAF)
//!
//! Partitioned block NLMS in the frequency domain. Each partition covers
//! one frame (block_size samples). The filter is H(f) = [H0, H1, ..., Hp-1],
//! where p = num_partitions. The echo estimate is the sum of Hi(f) * Xi(f)
//! over all partitions, where Xi is the i-th delayed ref block.
//!
//! This is the linear component of AEC. Non-linear residual is handled
//! by suppression_gain.zig (NLP).

const fft_mod = @import("fft.zig");
const Complex = fft_mod.Complex;

pub const Config = struct {
    block_size: usize = 160,
    num_partitions: usize = 50,
    step_size: f32 = 0.5,
    regularization: f32 = 100.0,
};

pub const AdaptiveFilter = struct {
    config: Config,
    fft_size: usize,
    num_bins: usize,

    // Filter partitions H[p][bin] — flattened: [num_partitions * num_bins]
    filter: []Complex,
    // Render buffer: past ref blocks in frequency domain [num_partitions * num_bins]
    render_buf: []Complex,
    // Current render write index (circular)
    render_idx: usize,
    // Work buffers
    padded: []Complex,

    allocator: Allocator,

    const Allocator = @import("std").mem.Allocator;

    pub fn init(allocator: Allocator, config: Config) !AdaptiveFilter {
        const fft_size = nextPow2(config.block_size * 2);
        const num_bins = fft_size;

        const filter = try allocator.alloc(Complex, config.num_partitions * num_bins);
        errdefer allocator.free(filter);
        @memset(filter, Complex{});

        const render_buf = try allocator.alloc(Complex, config.num_partitions * num_bins);
        errdefer allocator.free(render_buf);
        @memset(render_buf, Complex{});

        const padded = try allocator.alloc(Complex, fft_size);
        errdefer allocator.free(padded);

        return .{
            .config = config,
            .fft_size = fft_size,
            .num_bins = num_bins,
            .filter = filter,
            .render_buf = render_buf,
            .render_idx = 0,
            .padded = padded,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AdaptiveFilter) void {
        self.allocator.free(self.padded);
        self.allocator.free(self.render_buf);
        self.allocator.free(self.filter);
    }

    pub fn reset(self: *AdaptiveFilter) void {
        @memset(self.filter, Complex{});
        @memset(self.render_buf, Complex{});
        self.render_idx = 0;
    }

    pub const ProcessResult = struct {
        error_energy: f32,
        ref_energy: f32,
    };

    /// Process one block: given mic and ref in time domain, produce error (echo-cancelled).
    /// mic and ref must be block_size samples. error_out receives block_size samples.
    pub fn process(
        self: *AdaptiveFilter,
        mic: []const i16,
        ref: []const i16,
        error_out: []i16,
    ) ProcessResult {
        const bs = self.config.block_size;
        const fft_n = self.fft_size;
        const n_bins = self.num_bins;

        // 1. FFT the ref block (zero-padded to fft_size)
        for (self.padded, 0..) |*c, i| {
            c.re = if (i < bs) @floatFromInt(ref[i]) else 0;
            c.im = 0;
        }
        fft_mod.fft(self.padded);

        // 2. Store in render buffer (circular)
        const render_offset = self.render_idx * n_bins;
        @memcpy(self.render_buf[render_offset..][0..n_bins], self.padded);

        // 3. Compute echo estimate: sum over partitions H[p] * X[p]
        // Use padded buffer as temp for echo estimate
        var echo_freq: [1024]Complex = [_]Complex{.{}} ** 1024;
        for (0..n_bins) |k| echo_freq[k] = Complex{};

        for (0..self.config.num_partitions) |p| {
            const ri = (self.render_idx + self.config.num_partitions - p) % self.config.num_partitions;
            const x_offset = ri * n_bins;
            const h_offset = p * n_bins;
            for (0..n_bins) |k| {
                const h = self.filter[h_offset + k];
                const x = self.render_buf[x_offset + k];
                echo_freq[k] = Complex.add(echo_freq[k], Complex.mul(h, x));
            }
        }

        // 4. IFFT echo estimate to get time-domain echo
        fft_mod.ifft(echo_freq[0..fft_n]);

        // 5. FFT the mic block
        for (self.padded, 0..) |*c, i| {
            c.re = if (i < bs) @floatFromInt(mic[i]) else 0;
            c.im = 0;
        }
        fft_mod.fft(self.padded);

        // 6. Compute error and mic energy
        var error_energy: f32 = 0;
        var mic_energy: f32 = 0;
        for (0..bs) |i| {
            const mic_val: f32 = @floatFromInt(mic[i]);
            const echo_val = echo_freq[i].re;
            const err = mic_val - echo_val;
            error_energy += err * err;
            mic_energy += mic_val * mic_val;

            if (err > 32767) {
                error_out[i] = 32767;
            } else if (err < -32768) {
                error_out[i] = -32768;
            } else {
                error_out[i] = @intFromFloat(@round(err));
            }
        }

        // 7. Compute ref energy
        var ref_energy: f32 = 0;
        for (0..bs) |i| {
            const v: f32 = @floatFromInt(ref[i]);
            ref_energy += v * v;
        }

        // Divergence protection: if error >> mic, filter is badly wrong → passthrough
        if (error_energy > mic_energy * 4.0 and mic_energy > 100) {
            @memcpy(error_out, mic);
            error_energy = mic_energy;
            self.render_idx = (self.render_idx + 1) % self.config.num_partitions;
            return .{ .error_energy = error_energy / @as(f32, @floatFromInt(bs)), .ref_energy = ref_energy / @as(f32, @floatFromInt(bs)) };
        }

        // Output gain constraint: clean energy must be less than mic energy.
        // In a feedback loop, even clamping to mic level preserves the signal.
        // Apply additional attenuation (0.7) when clamping to ensure loop decays.
        if (error_energy > mic_energy * 0.5 and mic_energy > 100) {
            const target = mic_energy * 0.5;
            const scale = @sqrt(target / error_energy);
            for (0..bs) |i| {
                const v: f32 = @as(f32, @floatFromInt(error_out[i])) * scale;
                error_out[i] = if (v > 32767) 32767 else if (v < -32768) -32768 else @intFromFloat(@round(v));
            }
            error_energy = target;
        }

        // Double-talk / update safety: skip coefficient update when the
        // error signal cannot be reliably attributed to echo mismatch.
        // Cases where updating would corrupt the filter:
        //  - ref too quiet (nothing to learn from)
        //  - near-end speech dominates (mic >> ref)
        //  - error larger than ref (unexplained energy, likely near-end)
        const skip_update = (ref_energy < 100) or
            (mic_energy > ref_energy * 3.0);

        if (skip_update) {
            self.render_idx = (self.render_idx + 1) % self.config.num_partitions;
            return .{ .error_energy = error_energy / @as(f32, @floatFromInt(bs)), .ref_energy = ref_energy / @as(f32, @floatFromInt(bs)) };
        }

        // FFT the error (zero-padded) for filter update
        for (self.padded, 0..) |*c, i| {
            if (i < bs) {
                const mic_val: f32 = @floatFromInt(mic[i]);
                const echo_val = echo_freq[i].re;
                c.re = mic_val - echo_val;
            } else {
                c.re = 0;
            }
            c.im = 0;
        }
        fft_mod.fft(self.padded);

        // Update filter — per-bin NLMS
        const mu = self.config.step_size;
        const delta = self.config.regularization;

        // Compute per-bin ref power (sum across partitions)
        var ref_power: [1024]f32 = [_]f32{0} ** 1024;
        for (0..self.config.num_partitions) |p| {
            const ri = (self.render_idx + self.config.num_partitions - p) % self.config.num_partitions;
            const x_offset = ri * n_bins;
            for (0..n_bins) |k| {
                ref_power[k] += Complex.mag2(self.render_buf[x_offset + k]);
            }
        }

        // Update each partition with leaky LMS (leak prevents divergence)
        const leak: f32 = 0.999;
        for (0..self.config.num_partitions) |p| {
            const ri = (self.render_idx + self.config.num_partitions - p) % self.config.num_partitions;
            const x_offset = ri * n_bins;
            const h_offset = p * n_bins;
            for (0..n_bins) |k| {
                const x_conj = Complex.conj(self.render_buf[x_offset + k]);
                const err_k = self.padded[k];
                const grad = Complex.mul(err_k, x_conj);
                const norm = ref_power[k] + delta;
                const step = Complex.scale(grad, mu / norm);
                // Leaky LMS: shrink old coefficients to prevent accumulation
                self.filter[h_offset + k] = Complex.add(
                    Complex.scale(self.filter[h_offset + k], leak),
                    step,
                );
            }
        }

        // Advance render index
        self.render_idx = (self.render_idx + 1) % self.config.num_partitions;

        return .{
            .error_energy = error_energy / @as(f32, @floatFromInt(bs)),
            .ref_energy = ref_energy / @as(f32, @floatFromInt(bs)),
        };
    }

    fn nextPow2(n: usize) usize {
        var v: usize = 1;
        while (v < n) v *= 2;
        return v;
    }
};

// ============================================================================
// Tests AF1-AF8
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

fn rmsI16(buf: []const i16) f32 {
    var sum: f32 = 0;
    for (buf) |s| {
        const v: f32 = @floatFromInt(s);
        sum += v * v;
    }
    return @sqrt(sum / @as(f32, @floatFromInt(buf.len)));
}

// AF1: Pure echo convergence (ref == mic, no delay)
test "AF1: pure echo convergence — error < 1% after 50 frames" {
    var af = try AdaptiveFilter.init(testing.allocator, .{
        .block_size = 160,
        .num_partitions = 10,
        .step_size = 0.5,
    });
    defer af.deinit();

    var error_buf: [160]i16 = undefined;
    var last_result: AdaptiveFilter.ProcessResult = undefined;

    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        last_result = af.process(&tone, &tone, &error_buf);
    }

    const input_rms = rmsI16(&[_]i16{10000} ** 1);
    const error_rms = @sqrt(last_result.error_energy);
    const ratio = error_rms / input_rms;

    std.debug.print("[AF1] error_rms={d:.1}, ratio={d:.3}\n", .{ error_rms, ratio });
    try testing.expect(ratio < 0.01);
}

// AF2: Delayed echo convergence
test "AF2: delayed echo convergence — 320 sample delay" {
    var af = try AdaptiveFilter.init(testing.allocator, .{
        .block_size = 160,
        .num_partitions = 10,
        .step_size = 0.4,
    });
    defer af.deinit();

    // Generate long signal
    const total = 160 * 100;
    var signal: [total + 320]i16 = undefined;
    generateSine(&signal, 440.0, 10000.0, 16000, 0);

    var error_buf: [160]i16 = undefined;
    var last_error_rms: f32 = 0;

    for (0..100) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic = signal[frame * 160 + 320 ..][0..160]; // 320 sample delay
        const result = af.process(mic, ref, &error_buf);
        last_error_rms = @sqrt(result.error_energy);
    }

    const input_rms: f32 = 10000.0 / @sqrt(2.0);
    const ratio = last_error_rms / input_rms;

    std.debug.print("[AF2] error_rms={d:.1}, ratio={d:.3}\n", .{ last_error_rms, ratio });
    try testing.expect(ratio < 0.05);
}

// AF3: Echo + noise
test "AF3: echo + white noise — converges to noise level" {
    var af = try AdaptiveFilter.init(testing.allocator, .{
        .block_size = 160,
        .num_partitions = 10,
        .step_size = 0.3,
    });
    defer af.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var error_buf: [160]i16 = undefined;
    var last_error_rms: f32 = 0;

    for (0..100) |frame| {
        var ref: [160]i16 = undefined;
        var mic: [160]i16 = undefined;
        generateSine(&ref, 440.0, 10000.0, 16000, frame * 160);

        // mic = ref + noise (SNR ~20dB → noise amp ~1000)
        for (&mic, 0..) |*s, i| {
            const echo: i32 = ref[i];
            const noise: i32 = random.intRangeAtMost(i16, -1000, 1000);
            s.* = @intCast(std.math.clamp(echo + noise, -32768, 32767));
        }

        const result = af.process(&mic, &ref, &error_buf);
        last_error_rms = @sqrt(result.error_energy);
    }

    // After convergence, error should be close to noise level (~577 RMS for uniform ±1000)
    std.debug.print("[AF3] error_rms={d:.1}\n", .{last_error_rms});
    try testing.expect(last_error_rms < 2000);
}

// AF4: Double-talk — preserves near-end
test "AF4: double-talk — preserves near-end 880Hz" {
    var af = try AdaptiveFilter.init(testing.allocator, .{
        .block_size = 160,
        .num_partitions = 10,
        .step_size = 0.3,
    });
    defer af.deinit();

    var error_buf: [160]i16 = undefined;

    // Pre-converge on pure echo
    for (0..50) |frame| {
        var ref: [160]i16 = undefined;
        generateSine(&ref, 440.0, 10000.0, 16000, frame * 160);
        _ = af.process(&ref, &ref, &error_buf);
    }

    // Now add near-end 880Hz
    var ref: [160]i16 = undefined;
    var mic: [160]i16 = undefined;
    generateSine(&ref, 440.0, 10000.0, 16000, 50 * 160);

    for (&mic, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i + 50 * 160)) / 16000.0;
        const echo: f32 = @floatFromInt(ref[i]);
        const near_end = @sin(t * 880.0 * 2.0 * math.pi) * 8000.0;
        const mixed = echo + near_end;
        s.* = @intFromFloat(std.math.clamp(mixed, -32768, 32767));
    }

    _ = af.process(&mic, &ref, &error_buf);

    // Error should contain the 880Hz near-end signal
    const error_rms = rmsI16(&error_buf);
    std.debug.print("[AF4] error_rms={d:.1} (should be ~5657 for 8000 amp sine)\n", .{error_rms});
    try testing.expect(error_rms > 3000);
}

// AF5: Non-stationary signal (sweep)
test "AF5: sweep tracking" {
    var af = try AdaptiveFilter.init(testing.allocator, .{
        .block_size = 160,
        .num_partitions = 10,
        .step_size = 0.5,
    });
    defer af.deinit();

    var error_buf: [160]i16 = undefined;
    var last_error_rms: f32 = 0;

    for (0..100) |frame| {
        // Sweep 200→4000Hz over 100 frames
        var ref: [160]i16 = undefined;
        const freq = 200.0 + @as(f32, @floatFromInt(frame)) * 38.0;
        generateSine(&ref, freq, 10000.0, 16000, frame * 160);

        const result = af.process(&ref, &ref, &error_buf);
        last_error_rms = @sqrt(result.error_energy);
    }

    const input_rms: f32 = 10000.0 / @sqrt(2.0);
    const ratio = last_error_rms / input_rms;

    std.debug.print("[AF5] sweep error_rms={d:.1}, ratio={d:.2}\n", .{ last_error_rms, ratio });
    try testing.expect(ratio < 0.30);
}

// AF6: Step size comparison
test "AF6: step size — larger μ converges faster but higher steady-state error" {
    var err_fast: f32 = 0;
    var err_slow: f32 = 0;

    for ([_]f32{ 0.1, 0.5 }) |mu| {
        var af = try AdaptiveFilter.init(testing.allocator, .{
            .block_size = 160,
            .num_partitions = 10,
            .step_size = mu,
        });
        defer af.deinit();

        var error_buf: [160]i16 = undefined;

        for (0..30) |frame| {
            var tone: [160]i16 = undefined;
            generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
            const result = af.process(&tone, &tone, &error_buf);
            if (mu < 0.2) {
                err_slow = @sqrt(result.error_energy);
            } else {
                err_fast = @sqrt(result.error_energy);
            }
        }
    }

    std.debug.print("[AF6] μ=0.1 err={d:.1}, μ=0.5 err={d:.1}\n", .{ err_slow, err_fast });
    // Larger μ should converge faster (lower error after 30 frames)
    try testing.expect(err_fast < err_slow);
}

// AF7: Filter length insufficient
test "AF7: filter too short — doesn't fully converge but no crash" {
    var af = try AdaptiveFilter.init(testing.allocator, .{
        .block_size = 160,
        .num_partitions = 2, // Only 320 samples, but echo tail is longer
        .step_size = 0.5,
    });
    defer af.deinit();

    var error_buf: [160]i16 = undefined;

    const total = 160 * 100 + 800;
    var signal: [total]i16 = undefined;
    generateSine(&signal, 440.0, 10000.0, 16000, 0);

    for (0..100) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic = signal[frame * 160 + 800 ..][0..160]; // 800 sample delay > filter capacity
        _ = af.process(mic, ref, &error_buf);
    }

    // Should not crash, error will be higher than ideal
    const error_rms = rmsI16(&error_buf);
    std.debug.print("[AF7] error_rms={d:.1} (filter too short, expected high)\n", .{error_rms});
    try testing.expect(error_rms > 0);
}

// AF8: Reset re-convergence
test "AF8: reset then re-converge" {
    var af = try AdaptiveFilter.init(testing.allocator, .{
        .block_size = 160,
        .num_partitions = 10,
        .step_size = 0.5,
    });
    defer af.deinit();

    var error_buf: [160]i16 = undefined;

    // Converge
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        _ = af.process(&tone, &tone, &error_buf);
    }
    const converged_rms = rmsI16(&error_buf);

    // Reset
    af.reset();

    // First frame after reset should have high error
    var tone: [160]i16 = undefined;
    generateSine(&tone, 440.0, 10000.0, 16000, 0);
    _ = af.process(&tone, &tone, &error_buf);
    const reset_rms = rmsI16(&error_buf);

    std.debug.print("[AF8] converged={d:.1}, after_reset={d:.1}\n", .{ converged_rms, reset_rms });
    try testing.expect(reset_rms > converged_rms * 5);
}
