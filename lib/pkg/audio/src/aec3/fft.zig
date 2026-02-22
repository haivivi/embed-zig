//! FFT — radix-2 Cooley-Tukey FFT/IFFT for audio processing
//!
//! Parameterized for float (f32) or fixed-point (i32 Q15) arithmetic.
//! `use_fixed=false` → f32 floating-point (desktop/server)
//! `use_fixed=true`  → i32 Q15 fixed-point (embedded/MCU)

const math = @import("std").math;

// ============================================================================
// Q15 fixed-point arithmetic
// ============================================================================

const Q15_SHIFT = 15;
const Q15_ONE: i32 = 1 << Q15_SHIFT;

fn q15Mul(a: i32, b: i32) i32 {
    return @intCast((@as(i64, a) * @as(i64, b)) >> Q15_SHIFT);
}

fn q15Sat(v: i64) i32 {
    return if (v > math.maxInt(i32)) math.maxInt(i32) else if (v < math.minInt(i32)) math.minInt(i32) else @intCast(v);
}

// ============================================================================
// Generic Complex type
// ============================================================================

pub fn GenComplex(comptime S: type) type {
    const is_fixed = (S == i32);

    return struct {
        re: S = if (is_fixed) @as(i32, 0) else @as(f32, 0),
        im: S = if (is_fixed) @as(i32, 0) else @as(f32, 0),

        const Self = @This();

        pub fn add(a: Self, b: Self) Self {
            if (is_fixed) {
                return .{
                    .re = q15Sat(@as(i64, a.re) + b.re),
                    .im = q15Sat(@as(i64, a.im) + b.im),
                };
            }
            return .{ .re = a.re + b.re, .im = a.im + b.im };
        }

        pub fn sub(a: Self, b: Self) Self {
            if (is_fixed) {
                return .{
                    .re = q15Sat(@as(i64, a.re) - b.re),
                    .im = q15Sat(@as(i64, a.im) - b.im),
                };
            }
            return .{ .re = a.re - b.re, .im = a.im - b.im };
        }

        pub fn mul(a: Self, b: Self) Self {
            if (is_fixed) {
                return .{
                    .re = q15Sat(@as(i64, q15Mul(a.re, b.re)) - q15Mul(a.im, b.im)),
                    .im = q15Sat(@as(i64, q15Mul(a.re, b.im)) + q15Mul(a.im, b.re)),
                };
            }
            return .{
                .re = a.re * b.re - a.im * b.im,
                .im = a.re * b.im + a.im * b.re,
            };
        }

        pub fn conj(a: Self) Self {
            return .{ .re = a.re, .im = if (is_fixed) -a.im else -a.im };
        }

        pub fn mag2(a: Self) S {
            if (is_fixed) {
                return q15Sat(@as(i64, q15Mul(a.re, a.re)) + q15Mul(a.im, a.im));
            }
            return a.re * a.re + a.im * a.im;
        }

        pub fn scale(a: Self, s: S) Self {
            if (is_fixed) {
                return .{ .re = q15Mul(a.re, s), .im = q15Mul(a.im, s) };
            }
            return .{ .re = a.re * s, .im = a.im * s };
        }
    };
}

// Default: f32 Complex (backward compatible)
pub const Complex = GenComplex(f32);

// ============================================================================
// Generic FFT operations
// ============================================================================

pub fn genFft(comptime S: type, buf: []GenComplex(S)) void {
    const C = GenComplex(S);
    const is_fixed = (S == i32);
    const n = buf.len;
    if (n <= 1) return;

    genBitReverse(S, buf);

    var stage_len: usize = 2;
    while (stage_len <= n) : (stage_len *= 2) {
        const half = stage_len / 2;
        var k: usize = 0;
        while (k < n) : (k += stage_len) {
            for (0..half) |j| {
                const tw = genTwiddle(S, j, stage_len);
                const even = buf[k + j];
                const odd = C.mul(tw, buf[k + j + half]);
                if (is_fixed) {
                    buf[k + j] = .{
                        .re = q15Sat((@as(i64, even.re) + odd.re) >> 1),
                        .im = q15Sat((@as(i64, even.im) + odd.im) >> 1),
                    };
                    buf[k + j + half] = .{
                        .re = q15Sat((@as(i64, even.re) - odd.re) >> 1),
                        .im = q15Sat((@as(i64, even.im) - odd.im) >> 1),
                    };
                } else {
                    buf[k + j] = C.add(even, odd);
                    buf[k + j + half] = C.sub(even, odd);
                }
            }
        }
    }
}

pub fn genIfft(comptime S: type, buf: []GenComplex(S)) void {
    const is_fixed = (S == i32);
    for (buf) |*c| c.im = if (is_fixed) -c.im else -c.im;
    genFft(S, buf);
    if (is_fixed) {
        // genFft already scaled down by N (>>1 per stage). For IFFT we need
        // the result scaled by 1/N total. The conjugate+FFT+conjugate method
        // gives us X[k]/N when FFT doesn't scale, but our FFT scales by 1/N.
        // So after two FFTs we have X[k]/N². Multiply back by N to get X[k]/N.
        const n = buf.len;
        const log2n = @ctz(n);
        for (buf) |*c| {
            c.re = c.re << @intCast(log2n);
            c.im = -(c.im << @intCast(log2n));
        }
    } else {
        const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(buf.len));
        for (buf) |*c| {
            c.im = -c.im;
            c.re *= inv_n;
            c.im *= inv_n;
        }
    }
}

fn genTwiddle(comptime S: type, j: usize, stage_len: usize) GenComplex(S) {
    const angle: f64 = -2.0 * math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(stage_len));
    if (S == i32) {
        return .{
            .re = @intFromFloat(@cos(angle) * @as(f64, Q15_ONE)),
            .im = @intFromFloat(@sin(angle) * @as(f64, Q15_ONE)),
        };
    }
    return .{ .re = @floatCast(@cos(angle)), .im = @floatCast(@sin(angle)) };
}

fn genBitReverse(comptime S: type, buf: []GenComplex(S)) void {
    const n = buf.len;
    var j: usize = 0;
    for (1..n) |i| {
        var bit: usize = n >> 1;
        while (j & bit != 0) { j ^= bit; bit >>= 1; }
        j ^= bit;
        if (i < j) {
            const tmp = buf[i];
            buf[i] = buf[j];
            buf[j] = tmp;
        }
    }
}

pub fn genFromI16(comptime S: type, output: []GenComplex(S), input: []const i16) void {
    for (output, 0..) |*c, i| {
        if (S == i32) {
            c.re = if (i < input.len) @as(i32, input[i]) else 0;
        } else {
            c.re = if (i < input.len) @floatFromInt(input[i]) else 0;
        }
        c.im = if (S == i32) @as(i32, 0) else @as(f32, 0);
    }
}

pub fn genToI16(comptime S: type, output: []i16, input: []const GenComplex(S)) void {
    for (output, 0..) |*s, i| {
        if (i < input.len) {
            if (S == i32) {
                s.* = if (input[i].re > 32767) 32767 else if (input[i].re < -32768) -32768 else @intCast(input[i].re);
            } else {
                const v = @round(input[i].re);
                s.* = if (v > 32767) 32767 else if (v < -32768) -32768 else @intFromFloat(v);
            }
        } else s.* = 0;
    }
}

// ============================================================================
// Default f32 functions (backward compatible)
// ============================================================================

pub fn fft(buf: []Complex) void { genFft(f32, buf); }
pub fn ifft(buf: []Complex) void { genIfft(f32, buf); }
pub fn fromI16(output: []Complex, input: []const i16) void { genFromI16(f32, output, input); }
pub fn toI16(output: []i16, input: []const Complex) void { genToI16(f32, output, input); }

pub fn hannWindow(buf: []Complex) void {
    const n_f: f32 = @floatFromInt(buf.len);
    for (buf, 0..) |*c, i| {
        const t: f32 = @floatFromInt(i);
        const w = 0.5 * (1.0 - @cos(2.0 * math.pi * t / n_f));
        c.re *= w;
        c.im *= w;
    }
}

pub fn binPowerDb(c: Complex) f32 {
    const m = Complex.mag2(c);
    if (m < 1e-10) return -100.0;
    return 10.0 * @log10(m);
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");
const testing = std.testing;

test "F1: single frequency FFT peak detection" {
    var buf: [256]Complex = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @sin(t * 440.0 * 2.0 * math.pi) * 10000.0;
        c.im = 0;
    }
    fft(&buf);
    const expected = 256 * 440 / 16000;
    var max_mag: f32 = 0;
    var peak: usize = 0;
    for (buf[1 .. buf.len / 2], 1..) |c, i| {
        const m = Complex.mag2(c);
        if (m > max_mag) { max_mag = m; peak = i; }
    }
    try testing.expect(peak >= expected - 1 and peak <= expected + 1);
}

test "F1-fixed: single frequency FFT peak detection" {
    const C = GenComplex(i32);
    var buf: [256]C = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @intFromFloat(@sin(t * 440.0 * 2.0 * math.pi) * 10000.0);
        c.im = 0;
    }
    genFft(i32, &buf);
    const expected = 256 * 440 / 16000;
    var max_mag: i32 = 0;
    var peak: usize = 0;
    for (buf[1 .. buf.len / 2], 1..) |c, i| {
        const m = C.mag2(c);
        if (m > max_mag) { max_mag = m; peak = i; }
    }
    try testing.expect(peak >= expected - 1 and peak <= expected + 1);
}

test "F4: FFT → IFFT roundtrip precision" {
    var buf: [256]Complex = undefined;
    var orig: [256]Complex = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @sin(t * 440.0 * 2.0 * math.pi) * 10000.0;
        c.im = 0;
    }
    @memcpy(&orig, &buf);
    fft(&buf);
    ifft(&buf);
    var max_err: f32 = 0;
    for (buf, orig) |b, o| {
        const e = @abs(b.re - o.re);
        if (e > max_err) max_err = e;
    }
    try testing.expect(max_err < 1.0);
}

test "F4-fixed: FFT → IFFT roundtrip" {
    const C = GenComplex(i32);
    var buf: [256]C = undefined;
    var orig: [256]i32 = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        const v: i32 = @intFromFloat(@sin(t * 440.0 * 2.0 * math.pi) * 10000.0);
        c.re = v;
        c.im = 0;
        orig[i] = v;
    }
    genFft(i32, &buf);
    genIfft(i32, &buf);
    var max_err: i32 = 0;
    for (buf, orig) |b, o| {
        const e = @as(i32, @intCast(@abs(@as(i64, b.re) - o)));
        if (e > max_err) max_err = e;
    }
    // Fixed-point has quantization error, especially with >>1 per stage
    std.debug.print("[F4-fixed] max roundtrip error={d}\n", .{max_err});
    try testing.expect(max_err < 2000);
}

test "F5: zero signal — all bins zero" {
    var buf: [128]Complex = [_]Complex{.{}} ** 128;
    fft(&buf);
    for (buf) |c| try testing.expect(c.re == 0 and c.im == 0);
}

test "F5-fixed: zero signal" {
    const C = GenComplex(i32);
    var buf: [128]C = [_]C{.{}} ** 128;
    genFft(i32, &buf);
    for (buf) |c| try testing.expect(c.re == 0 and c.im == 0);
}

test "F2: multi-frequency FFT — two peaks" {
    var buf: [512]Complex = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @sin(t * 440.0 * 2.0 * math.pi) * 5000.0 + @sin(t * 1000.0 * 2.0 * math.pi) * 5000.0;
        c.im = 0;
    }
    fft(&buf);
    const bin_440 = 512 * 440 / 16000;
    const bin_1000 = 512 * 1000 / 16000;
    const noise_bin = 512 * 2000 / 16000;
    try testing.expect(Complex.mag2(buf[bin_440]) > Complex.mag2(buf[noise_bin]) * 100);
    try testing.expect(Complex.mag2(buf[bin_1000]) > Complex.mag2(buf[noise_bin]) * 100);
}

test "F3: DC signal — all energy in bin 0" {
    var buf: [128]Complex = undefined;
    for (&buf) |*c| { c.re = 1000; c.im = 0; }
    fft(&buf);
    const dc = Complex.mag2(buf[0]);
    var other: f32 = 0;
    for (buf[1..]) |c| { const m = Complex.mag2(c); if (m > other) other = m; }
    try testing.expect(dc > other * 1000);
}

test "F6: Parseval theorem" {
    var buf: [256]Complex = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @sin(t * 440.0 * 2.0 * math.pi) * 10000.0;
        c.im = 0;
    }
    var te: f64 = 0;
    for (buf) |c| te += @as(f64, c.re) * @as(f64, c.re);
    fft(&buf);
    var fe: f64 = 0;
    for (buf) |c| fe += @as(f64, Complex.mag2(c));
    const ratio = fe / te;
    const expected: f64 = @floatFromInt(buf.len);
    try testing.expect(@abs(ratio - expected) < expected * 0.01);
}

test "F7: Hann window sidelobes" {
    var buf: [512]Complex = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @sin(t * 440.0 * 2.0 * math.pi) * 10000.0;
        c.im = 0;
    }
    hannWindow(&buf);
    fft(&buf);
    const peak = Complex.mag2(buf[512 * 440 / 16000]);
    const far = Complex.mag2(buf[512 * 2000 / 16000]);
    try testing.expect(peak > far * 10000);
}

test "F8: different FFT lengths all work" {
    inline for ([_]usize{ 128, 256, 512, 1024 }) |n| {
        var buf: [1024]Complex = [_]Complex{.{}} ** 1024;
        for (0..n) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
            buf[i].re = @sin(t * 440.0 * 2.0 * math.pi) * 5000.0;
        }
        fft(buf[0..n]);
        ifft(buf[0..n]);
    }
}
