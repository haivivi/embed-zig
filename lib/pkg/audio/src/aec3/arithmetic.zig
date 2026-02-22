//! Arithmetic abstraction layer for AEC3.
//!
//! `Arithmetic(false)` = f32 floating-point (desktop/server)
//! `Arithmetic(true)`  = i32 Q15 fixed-point (embedded/MCU)
//!
//! All AEC3 modules use `Arith.mul`, `Arith.Complex`, `Arith.fft`, etc.
//! No if-else in algorithm code.

const math = @import("std").math;
const fft_mod = @import("fft.zig");

pub fn Arithmetic(comptime use_fixed: bool) type {
    const S = if (use_fixed) i32 else f32;

    return struct {
        pub const Scalar = S;
        pub const Complex = fft_mod.GenComplex(S);
        pub const is_fixed = use_fixed;

        // ============================================================
        // Scalar operations
        // ============================================================

        pub inline fn zero() S {
            return if (use_fixed) 0 else 0.0;
        }

        pub inline fn one() S {
            return if (use_fixed) Q15_ONE else 1.0;
        }

        pub inline fn fromFloat(v: f32) S {
            if (use_fixed) return @intFromFloat(v);
            return v;
        }

        pub inline fn toFloat(v: S) f32 {
            if (use_fixed) return @floatFromInt(v);
            return v;
        }

        pub inline fn fromI16(v: i16) S {
            if (use_fixed) return @as(i32, v);
            return @floatFromInt(v);
        }

        pub inline fn toI16(v: S) i16 {
            if (use_fixed) {
                return if (v > 32767) 32767 else if (v < -32768) -32768 else @intCast(v);
            }
            const r = @round(v);
            return if (r > 32767) 32767 else if (r < -32768) -32768 else @intFromFloat(r);
        }

        pub inline fn add(a: S, b: S) S {
            if (use_fixed) return q15Sat(@as(i64, a) + b);
            return a + b;
        }

        pub inline fn sub(a: S, b: S) S {
            if (use_fixed) return q15Sat(@as(i64, a) - b);
            return a - b;
        }

        pub inline fn mul(a: S, b: S) S {
            if (use_fixed) return q15Mul(a, b);
            return a * b;
        }

        pub inline fn div(a: S, b: S) S {
            if (use_fixed) {
                if (b == 0) return 0;
                return @intCast(@divTrunc(@as(i64, a) << Q15_SHIFT, @as(i64, b)));
            }
            return a / b;
        }

        pub inline fn sqrt(v: S) S {
            if (use_fixed) {
                if (v <= 0) return 0;
                return @intFromFloat(@sqrt(@as(f32, @floatFromInt(v))));
            }
            return @sqrt(v);
        }

        pub inline fn abs(v: S) S {
            if (use_fixed) return if (v < 0) -v else v;
            return @abs(v);
        }

        pub inline fn neg(v: S) S {
            if (use_fixed) return -v;
            return -v;
        }

        /// a > b
        pub inline fn gt(a: S, b: S) bool {
            return a > b;
        }

        /// Scale scalar by f32 factor (for control logic like leak, step_size)
        pub inline fn scaleByFloat(v: S, factor: f32) S {
            if (use_fixed) {
                return @intFromFloat(@as(f32, @floatFromInt(v)) * factor);
            }
            return v * factor;
        }

        // ============================================================
        // FFT operations
        // ============================================================

        pub inline fn fft(buf: []Complex) void {
            fft_mod.genFft(S, buf);
        }

        pub inline fn ifft(buf: []Complex) void {
            fft_mod.genIfft(S, buf);
        }

        pub inline fn complexFromI16(output: []Complex, input: []const i16) void {
            fft_mod.genFromI16(S, output, input);
        }

        pub inline fn complexToI16(output: []i16, input: []const Complex) void {
            fft_mod.genToI16(S, output, input);
        }

        // ============================================================
        // Q15 internals
        // ============================================================

        const Q15_SHIFT = 15;
        const Q15_ONE: i32 = 1 << Q15_SHIFT;

        fn q15Mul(a: i32, b: i32) i32 {
            return @intCast((@as(i64, a) * @as(i64, b)) >> Q15_SHIFT);
        }

        fn q15Sat(v: i64) i32 {
            return if (v > math.maxInt(i32))
                math.maxInt(i32)
            else if (v < math.minInt(i32))
                math.minInt(i32)
            else
                @intCast(v);
        }
    };
}

// Default: f32
pub const Float = Arithmetic(false);
pub const Fixed = Arithmetic(true);

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "Float arithmetic basics" {
    const A = Float;
    try testing.expectEqual(@as(f32, 3.0), A.add(1.0, 2.0));
    try testing.expectEqual(@as(f32, 6.0), A.mul(2.0, 3.0));
    try testing.expectEqual(@as(f32, 2.0), A.div(6.0, 3.0));
    try testing.expectEqual(@as(f32, 3.0), A.sqrt(9.0));
    try testing.expectEqual(@as(f32, 100.0), A.fromFloat(100.0));
    try testing.expectEqual(@as(i16, 100), A.toI16(100.0));
}

test "Fixed arithmetic basics" {
    const A = Fixed;
    try testing.expectEqual(@as(i32, 3), A.add(1, 2));
    // Q15 mul: 32768 * 32768 >> 15 = 32768 (1.0 * 1.0 = 1.0)
    try testing.expectEqual(@as(i32, 32768), A.mul(32768, 32768));
    // 2 * 3 in raw i32 (not Q15 fractions): q15Mul(2, 3) = 6 >> 15 = 0
    // For small values, use raw integers as sample values, not Q15 fractions
    try testing.expectEqual(@as(i32, 100), A.fromI16(100));
    try testing.expectEqual(@as(i16, 100), A.toI16(100));
}

test "Fixed Q15 multiply precision" {
    const A = Fixed;
    // 0.5 in Q15 = 16384, 0.5 * 0.5 = 0.25 = 8192
    const half = A.fromFloat(16384.0);
    const quarter = A.mul(half, half);
    // q15Mul(16384, 16384) = (16384 * 16384) >> 15 = 268435456 >> 15 = 8192
    try testing.expectEqual(@as(i32, 8192), quarter);
}

test "Float Complex FFT roundtrip" {
    const A = Float;
    var buf: [256]A.Complex = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @sin(t * 440.0 * 2.0 * @import("std").math.pi) * 10000.0;
        c.im = 0;
    }
    var orig: [256]A.Complex = undefined;
    @memcpy(&orig, &buf);
    A.fft(&buf);
    A.ifft(&buf);
    var max_err: f32 = 0;
    for (buf, orig) |b, o| {
        const e = @abs(b.re - o.re);
        if (e > max_err) max_err = e;
    }
    try testing.expect(max_err < 1.0);
}

test "Fixed Complex FFT roundtrip" {
    const A = Fixed;
    var buf: [256]A.Complex = undefined;
    for (&buf, 0..) |*c, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        c.re = @intFromFloat(@sin(t * 440.0 * 2.0 * @import("std").math.pi) * 10000.0);
        c.im = 0;
    }
    var orig: [256]i32 = undefined;
    for (&orig, buf) |*o, b| o.* = b.re;
    A.fft(&buf);
    A.ifft(&buf);
    var max_err: i32 = 0;
    for (buf, orig) |b, o| {
        const e: i32 = @intCast(@abs(@as(i64, b.re) - o));
        if (e > max_err) max_err = e;
    }
    try testing.expect(max_err < 2000);
}
