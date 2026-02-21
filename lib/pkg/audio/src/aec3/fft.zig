//! FFT — radix-2 Cooley-Tukey FFT/IFFT for audio processing
//!
//! Pure Zig, no std dependency (freestanding compatible).
//! Operates on i16 PCM input, complex f32 frequency domain output.
//!
//! Supports power-of-2 sizes: 128, 256, 512, 1024.

const math = @import("std").math;

pub const Complex = struct {
    re: f32 = 0,
    im: f32 = 0,

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub fn conj(a: Complex) Complex {
        return .{ .re = a.re, .im = -a.im };
    }

    pub fn mag2(a: Complex) f32 {
        return a.re * a.re + a.im * a.im;
    }

    pub fn scale(a: Complex, s: f32) Complex {
        return .{ .re = a.re * s, .im = a.im * s };
    }
};

/// In-place radix-2 decimation-in-time FFT.
/// `buf` must be power-of-2 length.
pub fn fft(buf: []Complex) void {
    const n = buf.len;
    if (n <= 1) return;

    // Bit-reversal permutation
    bitReverse(buf);

    // Butterfly stages
    var stage_len: usize = 2;
    while (stage_len <= n) : (stage_len *= 2) {
        const half = stage_len / 2;
        const angle_step: f32 = -2.0 * math.pi / @as(f32, @floatFromInt(stage_len));

        var k: usize = 0;
        while (k < n) : (k += stage_len) {
            for (0..half) |j| {
                const angle = angle_step * @as(f32, @floatFromInt(j));
                const twiddle = Complex{
                    .re = @cos(angle),
                    .im = @sin(angle),
                };
                const even = buf[k + j];
                const odd = Complex.mul(twiddle, buf[k + j + half]);
                buf[k + j] = Complex.add(even, odd);
                buf[k + j + half] = Complex.sub(even, odd);
            }
        }
    }
}

/// In-place inverse FFT. Result is scaled by 1/N.
pub fn ifft(buf: []Complex) void {
    const n = buf.len;

    // Conjugate
    for (buf) |*c| c.im = -c.im;

    // Forward FFT
    fft(buf);

    // Conjugate and scale by 1/N
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(n));
    for (buf) |*c| {
        c.im = -c.im;
        c.re *= inv_n;
        c.im *= inv_n;
    }
}

/// Convert i16 PCM to complex (real part only).
pub fn fromI16(output: []Complex, input: []const i16) void {
    for (output, 0..) |*c, i| {
        c.re = if (i < input.len) @floatFromInt(input[i]) else 0;
        c.im = 0;
    }
}

/// Convert complex to i16 PCM (take real part, round and clamp).
pub fn toI16(output: []i16, input: []const Complex) void {
    for (output, 0..) |*s, i| {
        if (i < input.len) {
            const v = @round(input[i].re);
            if (v > 32767) {
                s.* = 32767;
            } else if (v < -32768) {
                s.* = -32768;
            } else {
                s.* = @intFromFloat(v);
            }
        } else {
            s.* = 0;
        }
    }
}

/// Apply Hann window in-place.
pub fn hannWindow(buf: []Complex) void {
    const n: f32 = @floatFromInt(buf.len);
    for (buf, 0..) |*c, i| {
        const t: f32 = @floatFromInt(i);
        const w = 0.5 * (1.0 - @cos(2.0 * math.pi * t / n));
        c.re *= w;
        c.im *= w;
    }
}

/// Compute power in dB for a frequency bin.
pub fn binPowerDb(c: Complex) f32 {
    const mag2_val = Complex.mag2(c);
    if (mag2_val < 1e-10) return -100.0;
    return 10.0 * @log10(mag2_val);
}

// ============================================================================
// Internal
// ============================================================================

fn bitReverse(buf: []Complex) void {
    const n = buf.len;
    var j: usize = 0;
    for (1..n) |i| {
        var bit: usize = n >> 1;
        while (j & bit != 0) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            const tmp = buf[i];
            buf[i] = buf[j];
            buf[j] = tmp;
        }
    }
}

// ============================================================================
// Tests: F1-F8
// ============================================================================

const testing = @import("std").testing;

fn generateSineComplex(buf: []Complex, freq: f32, amplitude: f32, sample_rate: f32) void {
    for (buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / sample_rate;
        c.re = @sin(t * freq * 2.0 * math.pi) * amplitude;
        c.im = 0;
    }
}

fn findPeakBin(buf: []const Complex) usize {
    var max_mag: f32 = 0;
    var max_idx: usize = 0;
    // Only search positive frequencies (1..N/2)
    for (1..buf.len / 2) |i| {
        const mag = Complex.mag2(buf[i]);
        if (mag > max_mag) {
            max_mag = mag;
            max_idx = i;
        }
    }
    return max_idx;
}

// F1: Single frequency FFT peak detection
test "F1: single frequency FFT peak detection" {
    const N = 256;
    var buf: [N]Complex = undefined;
    generateSineComplex(&buf, 440.0, 10000.0, 16000.0);

    fft(&buf);

    const expected_bin = @as(usize, @intFromFloat(@round(440.0 * @as(f32, N) / 16000.0)));
    const peak_bin = findPeakBin(&buf);

    try testing.expectEqual(expected_bin, peak_bin);
}

// F2: Multi-frequency FFT
test "F2: multi-frequency FFT — two peaks" {
    const N = 256;
    var buf: [N]Complex = undefined;

    // 440Hz + 880Hz
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @sin(t * 440.0 * 2.0 * math.pi) * 5000.0 +
            @sin(t * 880.0 * 2.0 * math.pi) * 5000.0;
        c.im = 0;
    }

    fft(&buf);

    const bin_440 = @as(usize, @intFromFloat(@round(440.0 * @as(f32, N) / 16000.0)));
    const bin_880 = @as(usize, @intFromFloat(@round(880.0 * @as(f32, N) / 16000.0)));

    const power_440 = Complex.mag2(buf[bin_440]);
    const power_880 = Complex.mag2(buf[bin_880]);

    // Both should have significant power
    try testing.expect(power_440 > 1e6);
    try testing.expect(power_880 > 1e6);

    // Other bins should be much lower (check a random non-peak bin)
    const mid_bin = (bin_440 + bin_880) / 2;
    const power_mid = Complex.mag2(buf[mid_bin]);
    try testing.expect(power_440 > power_mid * 100);
}

// F3: DC signal
test "F3: DC signal — all energy in bin 0" {
    const N = 256;
    var buf: [N]Complex = undefined;
    for (&buf) |*c| {
        c.re = 1000.0;
        c.im = 0;
    }

    fft(&buf);

    // bin[0] should be N * 1000
    const expected_dc: f32 = @as(f32, N) * 1000.0;
    try testing.expect(@abs(buf[0].re - expected_dc) < 1.0);
    try testing.expect(@abs(buf[0].im) < 1.0);

    // Other bins should be ~0
    for (1..N) |i| {
        try testing.expect(Complex.mag2(buf[i]) < 1.0);
    }
}

// F4: FFT → IFFT roundtrip precision < 1 LSB
test "F4: FFT → IFFT roundtrip precision" {
    const N = 256;
    var buf: [N]Complex = undefined;
    var original: [N]f32 = undefined;

    // Random-ish signal (deterministic)
    for (&buf, 0..) |*c, i| {
        const val: f32 = @floatFromInt(@as(i16, @intCast(@rem(@as(i32, @intCast(i)) * 7 + 13, 200) - 100)) * 100);
        c.re = val;
        c.im = 0;
        original[i] = val;
    }

    fft(&buf);
    ifft(&buf);

    // Check roundtrip error < 1.0 per sample
    for (0..N) |i| {
        const err = @abs(buf[i].re - original[i]);
        try testing.expect(err < 1.0);
        try testing.expect(@abs(buf[i].im) < 1.0);
    }
}

// F5: Zero signal
test "F5: zero signal — all bins zero" {
    const N = 256;
    var buf = [_]Complex{.{}} ** N;

    fft(&buf);

    for (buf) |c| {
        try testing.expect(@abs(c.re) < 1e-6);
        try testing.expect(@abs(c.im) < 1e-6);
    }
}

// F6: Parseval's theorem — time domain energy == frequency domain energy
test "F6: Parseval theorem" {
    const N = 256;
    var buf: [N]Complex = undefined;
    generateSineComplex(&buf, 440.0, 10000.0, 16000.0);

    // Time domain energy
    var time_energy: f64 = 0;
    for (buf) |c| {
        time_energy += @as(f64, c.re) * @as(f64, c.re);
    }

    fft(&buf);

    // Frequency domain energy (Parseval: sum |X[k]|² / N = sum |x[n]|²)
    var freq_energy: f64 = 0;
    for (buf) |c| {
        freq_energy += @as(f64, Complex.mag2(c));
    }
    freq_energy /= @as(f64, N);

    const ratio = time_energy / freq_energy;
    try testing.expect(ratio > 0.999 and ratio < 1.001);
}

// F7: Hann window — main lobe correct, sidelobes < -30dB
test "F7: Hann window sidelobes" {
    const N = 256;
    var buf: [N]Complex = undefined;
    generateSineComplex(&buf, 440.0, 10000.0, 16000.0);

    hannWindow(&buf);
    fft(&buf);

    const peak_bin = findPeakBin(&buf);
    const peak_power = binPowerDb(buf[peak_bin]);

    // Check sidelobes (bins far from peak) are < -30dB relative to peak
    var sidelobe_ok = true;
    for (1..N / 2) |i| {
        const dist = if (i > peak_bin) i - peak_bin else peak_bin - i;
        if (dist > 5) { // far from main lobe
            const power = binPowerDb(buf[i]);
            if (power > peak_power - 30.0) {
                sidelobe_ok = false;
                break;
            }
        }
    }
    try testing.expect(sidelobe_ok);
}

// F8: Different FFT lengths — 128, 256, 512, 1024
test "F8: different FFT lengths all work" {
    inline for ([_]usize{ 128, 256, 512, 1024 }) |N| {
        var buf: [N]Complex = undefined;
        generateSineComplex(&buf, 440.0, 10000.0, 16000.0);

        var original: [N]f32 = undefined;
        for (&original, 0..) |*v, i| v.* = buf[i].re;

        fft(&buf);
        ifft(&buf);

        for (0..N) |i| {
            const err = @abs(buf[i].re - original[i]);
            try testing.expect(err < 1.0);
        }
    }
}
