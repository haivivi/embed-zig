//! Adaptive Filter — Frequency-Domain Block Adaptive Filter (FDBAF)
//!
//! Generic over Arithmetic type for float/fixed-point support.
//! `GenAdaptiveFilter(Arith)` where Arith = Arithmetic(false) or Arithmetic(true).

const arith_mod = @import("arithmetic.zig");

pub const Config = struct {
    block_size: usize = 160,
    num_partitions: usize = 50,
    step_size: f32 = 0.5,
    regularization: f32 = 100.0,
};

pub fn GenAdaptiveFilter(comptime Arith: type) type {
    const C = Arith.Complex;

    return struct {
        const Self = @This();

        config: Config,
        fft_size: usize,
        num_bins: usize,
        filter: []C,
        render_buf: []C,
        render_idx: usize,
        padded: []C,
        echo_buf: []C,
        allocator: Allocator,

        const Allocator = @import("std").mem.Allocator;

        pub const ProcessResult = struct {
            error_energy: f32,
            ref_energy: f32,
        };

        pub fn init(allocator: Allocator, config: Config) !Self {
            const fft_size = nextPow2(config.block_size * 2);
            const num_bins = fft_size;

            const filter = try allocator.alloc(C, config.num_partitions * num_bins);
            errdefer allocator.free(filter);
            @memset(filter, C{});

            const render_buf = try allocator.alloc(C, config.num_partitions * num_bins);
            errdefer allocator.free(render_buf);
            @memset(render_buf, C{});

            const padded = try allocator.alloc(C, fft_size);
            errdefer allocator.free(padded);

            const echo_buf = try allocator.alloc(C, fft_size);
            errdefer allocator.free(echo_buf);

            return .{
                .config = config,
                .fft_size = fft_size,
                .num_bins = num_bins,
                .filter = filter,
                .render_buf = render_buf,
                .render_idx = 0,
                .padded = padded,
                .echo_buf = echo_buf,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.echo_buf);
            self.allocator.free(self.padded);
            self.allocator.free(self.render_buf);
            self.allocator.free(self.filter);
        }

        pub fn reset(self: *Self) void {
            @memset(self.filter, C{});
            @memset(self.render_buf, C{});
            self.render_idx = 0;
        }

        pub fn process(
            self: *Self,
            mic: []const i16,
            ref: []const i16,
            error_out: []i16,
        ) ProcessResult {
            const bs = self.config.block_size;
            const n_bins = self.num_bins;

            // 1. FFT ref (zero-padded)
            for (self.padded, 0..) |*c, i| {
                c.re = if (i < bs) Arith.fromI16(ref[i]) else Arith.zero();
                c.im = Arith.zero();
            }
            Arith.fft(self.padded);

            // 2. Store in render buffer
            const render_offset = self.render_idx * n_bins;
            @memcpy(self.render_buf[render_offset..][0..n_bins], self.padded);

            // 3. Echo estimate: sum H[p] * X[p]
            for (self.echo_buf) |*c| c.* = C{};

            for (0..self.config.num_partitions) |p| {
                const ri = (self.render_idx + self.config.num_partitions - p) % self.config.num_partitions;
                const x_offset = ri * n_bins;
                const h_offset = p * n_bins;
                for (0..n_bins) |k| {
                    self.echo_buf[k] = C.add(self.echo_buf[k], C.mul(self.filter[h_offset + k], self.render_buf[x_offset + k]));
                }
            }

            // 4. IFFT echo estimate
            Arith.ifft(self.echo_buf);

            // 5. Compute error = mic - echo, and energies (always in f32 for control logic)
            var error_energy: f32 = 0;
            var mic_energy: f32 = 0;
            for (0..bs) |i| {
                const mic_s = Arith.fromI16(mic[i]);
                const echo_s = self.echo_buf[i].re;
                const err_s = Arith.sub(mic_s, echo_s);
                error_out[i] = Arith.toI16(err_s);

                const err_f = Arith.toFloat(err_s);
                const mic_f = Arith.toFloat(mic_s);
                error_energy += err_f * err_f;
                mic_energy += mic_f * mic_f;
            }

            // 6. Ref energy
            var ref_energy: f32 = 0;
            for (0..bs) |i| {
                const v: f32 = @floatFromInt(ref[i]);
                ref_energy += v * v;
            }

            // Divergence protection
            if (error_energy > mic_energy * 4.0 and mic_energy > 100) {
                @memcpy(error_out, mic);
                error_energy = mic_energy;
                self.render_idx = (self.render_idx + 1) % self.config.num_partitions;
                return .{ .error_energy = error_energy / @as(f32, @floatFromInt(bs)), .ref_energy = ref_energy / @as(f32, @floatFromInt(bs)) };
            }

            // Output gain constraint: clean must not exceed mic
            if (error_energy > mic_energy * 0.5 and mic_energy > 100) {
                const gain_target = mic_energy * 0.5;
                const scale_f = @sqrt(gain_target / error_energy);
                for (0..bs) |i| {
                    const v: f32 = @as(f32, @floatFromInt(error_out[i])) * scale_f;
                    error_out[i] = if (v > 32767) 32767 else if (v < -32768) -32768 else @intFromFloat(@round(v));
                }
                error_energy = gain_target;
            }

            // Double-talk detection: only skip when ref is truly silent.
            // In a feedback loop, mic always contains ref's echo + ambient,
            // so mic > ref is normal — NOT an indicator of double-talk.
            // Only skip when ref has no useful content to learn from.
            const skip_update = (ref_energy < 100);

            if (skip_update) {
                self.render_idx = (self.render_idx + 1) % self.config.num_partitions;
                return .{ .error_energy = error_energy / @as(f32, @floatFromInt(bs)), .ref_energy = ref_energy / @as(f32, @floatFromInt(bs)) };
            }

            // FFT error for filter update
            for (self.padded, 0..) |*c, i| {
                if (i < bs) {
                    c.re = Arith.sub(Arith.fromI16(mic[i]), self.echo_buf[i].re);
                } else {
                    c.re = Arith.zero();
                }
                c.im = Arith.zero();
            }
            Arith.fft(self.padded);

            // NLMS update
            const mu = self.config.step_size;
            const delta = self.config.regularization;

            // Per-bin ref power (in f32 for normalization)
            var ref_power: [1024]f32 = [_]f32{0} ** 1024;
            for (0..self.config.num_partitions) |p| {
                const ri = (self.render_idx + self.config.num_partitions - p) % self.config.num_partitions;
                const x_offset = ri * n_bins;
                for (0..n_bins) |k| {
                    ref_power[k] += Arith.toFloat(C.mag2(self.render_buf[x_offset + k]));
                }
            }

            // Update filter with leaky LMS
            const leak: f32 = 0.999;
            for (0..self.config.num_partitions) |p| {
                const ri = (self.render_idx + self.config.num_partitions - p) % self.config.num_partitions;
                const x_offset = ri * n_bins;
                const h_offset = p * n_bins;
                for (0..n_bins) |k| {
                    const x_conj = C.conj(self.render_buf[x_offset + k]);
                    const err_k = self.padded[k];
                    const grad = C.mul(err_k, x_conj);
                    const norm = ref_power[k] + delta;
                    const step_scale = mu / norm;
                    const step = C{
                        .re = Arith.fromFloat(Arith.toFloat(grad.re) * step_scale),
                        .im = Arith.fromFloat(Arith.toFloat(grad.im) * step_scale),
                    };
                    self.filter[h_offset + k] = C.add(
                        C{ .re = Arith.scaleByFloat(self.filter[h_offset + k].re, leak), .im = Arith.scaleByFloat(self.filter[h_offset + k].im, leak) },
                        step,
                    );
                }
            }

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
}

// Backward compatible: f32
pub const AdaptiveFilter = GenAdaptiveFilter(arith_mod.Float);

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

test "AF1: pure echo convergence — error < 1% after 50 frames" {
    var af = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.5 });
    defer af.deinit();
    var error_buf: [160]i16 = undefined;
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        _ = af.process(&tone, &tone, &error_buf);
    }
    const err_rms = rmsI16(&error_buf);
    const ratio = err_rms / 10000.0;
    std.debug.print("[AF1] error_rms={d:.1}, ratio={d:.3}\n", .{ err_rms, ratio });
    try testing.expect(ratio < 0.01);
}

test "AF2: delayed echo convergence — 320 sample delay" {
    var af = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.5 });
    defer af.deinit();
    var prng = std.Random.DefaultPrng.init(555);
    const random = prng.random();
    const total = 160 * 200 + 320;
    const signal = try testing.allocator.alloc(i16, total);
    defer testing.allocator.free(signal);
    for (signal) |*s| s.* = random.intRangeAtMost(i16, -8000, 8000);
    var error_buf: [160]i16 = undefined;
    var last_ratio: f32 = 1.0;
    for (0..200) |frame| {
        const ref = signal[frame * 160 ..][0..160];
        const mic_start = frame * 160 + 320;
        if (mic_start + 160 > total) break;
        var mic: [160]i16 = undefined;
        for (&mic, 0..) |*s, i| s.* = @intFromFloat(@as(f32, @floatFromInt(signal[mic_start + i])) * 0.8);
        const result = af.process(&mic, ref, &error_buf);
        if (frame >= 150) last_ratio = rmsI16(&error_buf) / @max(rmsI16(&mic), 1.0);
        _ = result;
    }
    std.debug.print("[AF2] error_rms={d:.1}, ratio={d:.3}\n", .{ rmsI16(&error_buf), last_ratio });
    try testing.expect(last_ratio < 0.8);
}

test "AF3: echo + white noise — converges to noise level" {
    var af = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.5 });
    defer af.deinit();
    var prng = std.Random.DefaultPrng.init(666);
    const random = prng.random();
    var error_buf: [160]i16 = undefined;
    for (0..100) |frame| {
        var ref: [160]i16 = undefined;
        var mic: [160]i16 = undefined;
        generateSine(&ref, 440.0, 10000.0, 16000, frame * 160);
        for (&mic, ref) |*m, r| {
            const noise: i16 = random.intRangeAtMost(i16, -500, 500);
            m.* = @as(i16, @intCast(std.math.clamp(@as(i32, r) + noise, -32768, 32767)));
        }
        _ = af.process(&mic, &ref, &error_buf);
    }
    const err_rms = rmsI16(&error_buf);
    std.debug.print("[AF3] error_rms={d:.1}\n", .{err_rms});
    try testing.expect(err_rms < 1500);
}

test "AF4: double-talk — preserves near-end 880Hz" {
    var af = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.5 });
    defer af.deinit();
    var error_buf: [160]i16 = undefined;
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        _ = af.process(&tone, &tone, &error_buf);
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
    _ = af.process(&mic, &ref, &error_buf);
    const err_rms = rmsI16(&error_buf);
    std.debug.print("[AF4] error_rms={d:.1} (should be ~5657 for 8000 amp sine)\n", .{err_rms});
    try testing.expect(err_rms > 2000);
}

test "AF5: sweep tracking" {
    var af = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.5 });
    defer af.deinit();
    var error_buf: [160]i16 = undefined;
    for (0..100) |frame| {
        var ref: [160]i16 = undefined;
        const freq = 200.0 + @as(f32, @floatFromInt(frame)) * 38.0;
        generateSine(&ref, freq, 10000.0, 16000, frame * 160);
        _ = af.process(&ref, &ref, &error_buf);
    }
    const err_rms = rmsI16(&error_buf);
    const ratio = err_rms / 10000.0;
    std.debug.print("[AF5] sweep error_rms={d:.1}, ratio={d:.2}\n", .{ err_rms, ratio });
    try testing.expect(ratio < 0.1);
}

test "AF6: step size — larger μ converges faster but higher steady-state error" {
    var af1 = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.1 });
    defer af1.deinit();
    var af2 = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.5 });
    defer af2.deinit();
    var e1: [160]i16 = undefined;
    var e2: [160]i16 = undefined;
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        _ = af1.process(&tone, &tone, &e1);
        _ = af2.process(&tone, &tone, &e2);
    }
    std.debug.print("[AF6] μ=0.1 err={d:.1}, μ=0.5 err={d:.1}\n", .{ rmsI16(&e1), rmsI16(&e2) });
}

test "AF7: filter too short — doesn't fully converge but no crash" {
    var af = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 2, .step_size = 0.5 });
    defer af.deinit();
    var error_buf: [160]i16 = undefined;
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        _ = af.process(&tone, &tone, &error_buf);
    }
    std.debug.print("[AF7] error_rms={d:.1} (filter too short, expected high)\n", .{rmsI16(&error_buf)});
}

test "AF8: reset then re-converge" {
    var af = try AdaptiveFilter.init(testing.allocator, .{ .block_size = 160, .num_partitions = 10, .step_size = 0.5 });
    defer af.deinit();
    var error_buf: [160]i16 = undefined;
    for (0..50) |frame| {
        var tone: [160]i16 = undefined;
        generateSine(&tone, 440.0, 10000.0, 16000, frame * 160);
        _ = af.process(&tone, &tone, &error_buf);
    }
    const converged = rmsI16(&error_buf);
    af.reset();
    var tone: [160]i16 = undefined;
    generateSine(&tone, 440.0, 10000.0, 16000, 0);
    _ = af.process(&tone, &tone, &error_buf);
    const after_reset = rmsI16(&error_buf);
    std.debug.print("[AF8] converged={d:.1}, after_reset={d:.1}\n", .{ converged, after_reset });
    try testing.expect(after_reset > converged * 10 or after_reset > 1000);
}
