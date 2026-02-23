/// Q15 定点精度定义
/// ESP32/MCU 平台使用 Q15 定点进行内部计算
const std = @import("std");

/// Q15 定点精度定义
/// Qm.n 格式: m = 1 (符号位), n = 15 (小数位)
/// 范围: [-1.0, 0.9999695], 精度: 1/32768 ≈ 30.5μV
pub const FixedQ15 = struct {
    // 核心类型
    pub const Sample = i16; // Q15: 1.15
    pub const Accumulator = i32; // Q31: 1.31 (乘法结果)

    // 常量
    pub const kQ15Max: i16 = 32767;
    pub const kQ15Min: i16 = -32768;
    pub const kQ31Max: i32 = 2147483647;
    pub const kQ31Min: i32 = -2147483648;
    pub const kShiftBits: i5 = 15; // Q15 小数位

    // FFT 实现占位符
    pub const Fft = FixedFftQ15;

    // 滤波器实现占位符
    pub const AdaptiveFilter = AdaptiveFilterFixedQ15;

    // 基本运算 (带饱和)
    pub inline fn add(a: i16, b: i16) i16 {
        const sum = @as(i32, a) + @as(i32, b);
        return @intCast(std.math.clamp(sum, kQ15Min, kQ15Max));
    }

    pub inline fn sub(a: i16, b: i16) i16 {
        const diff = @as(i32, a) - @as(i32, b);
        return @intCast(std.math.clamp(diff, kQ15Min, kQ15Max));
    }

    /// 乘法: Q15 * Q15 = Q30 -> 需要右移 15 位回到 Q15
    pub inline fn mul(a: i16, b: i16) i16 {
        const prod = @as(i32, a) * @as(i32, b);
        // 舍入右移: (prod + 2^14) >> 15
        const rounded = (prod + (1 << 14)) >> kShiftBits;
        return @intCast(std.math.clamp(rounded, kQ15Min, kQ15Max));
    }

    /// 乘法累加: Q31 累加，不饱和
    pub inline fn mulAccum(a: i16, b: i16, acc: i32) i32 {
        return acc + @as(i32, a) * @as(i32, b);
    }

    /// 除法: a / b (Q15 / Q15 = Q0 -> 需要扩展)
    pub inline fn div(a: i16, b: i16) i16 {
        if (b == 0) return if (a >= 0) kQ15Max else kQ15Min;
        // 扩展为 Q31 后再除
        const a_ext = @as(i32, a) << kShiftBits;
        const result = @divTrunc(a_ext, @as(i32, b));
        return @intCast(std.math.clamp(result, kQ15Min, kQ15Max));
    }

    /// 缩放: 乘以因子后右移
    pub inline fn scale(value: i16, factor: i16) i16 {
        return mul(value, factor);
    }

    /// 按因子缩放 (int 因子，右移)
    pub inline fn scaleByShift(value: i16, shift: i5) i16 {
        const shifted = if (shift >= 0)
            @as(i32, value) << @intCast(shift)
        else
            @as(i32, value) >> @intCast(-shift);
        return @intCast(std.math.clamp(shifted, kQ15Min, kQ15Max));
    }

    // 能量相关 (Q15 -> Q31)
    pub inline fn energy(re: i16, im: i16) i32 {
        const re_ext = @as(i32, re);
        const im_ext = @as(i32, im);
        return (re_ext * re_ext + im_ext * im_ext);
        // 结果在 Q30，因为 Q15*Q15 = Q30
    }

    /// 幅度近似 (快速实现 - alpha*max + beta*min)
    /// 0.960 * max + 0.397 * min ≈ sqrt(a² + b²)
    /// 系数转换为 Q15: 0.960 * 32768 ≈ 31457, 0.397 * 32768 ≈ 13009
    pub inline fn magnitude(re: i16, im: i16) i16 {
        const a = @as(i32, @abs(re));
        const b = @as(i32, @abs(im));
        const max_val = @max(a, b);
        const min_val = @min(a, b);
        // 31457 * max + 13009 * min >> 15
        const approx = (31457 * max_val + 13009 * min_val) >> 15;
        return @intCast(std.math.clamp(approx, 0, kQ15Max));
    }

    /// 平方根 (定点实现)
    pub inline fn sqrt(x: i32) i16 {
        // 简化版: 线性插值近似
        if (x <= 0) return 0;
        // x 是 Q30 格式 (能量)，需要特殊处理
        // 先归一化到 Q30 [0, 1] 范围
        const lz: u5 = @intCast(@clz(@as(u32, @intCast(x))));
        const normalized = @as(u32, @intCast(x)) << lz;
        // 查表索引
        const idx: u8 = @intCast(normalized >> 23); // 取高8位
        _ = idx;
        // TODO: 完整查表实现
        return 256; // placeholder
    }

    /// log2 近似 (用于 dB 计算)
    /// log2(x) ≈ leading_zeros + fractional
    pub inline fn log2(x: i32) i16 {
        // 简化版: 仅使用整数位
        if (x <= 0) return kQ15Min;
        const lz = @clz(@as(u32, @intCast(x)));
        // 返回 Q15 格式的 log2 近似
        return @intCast((31 - @as(i16, @intCast(lz))) << kShiftBits);
    }

    // 比较
    pub inline fn max(a: i16, b: i16) i16 {
        return @max(a, b);
    }

    pub inline fn min(a: i16, b: i16) i16 {
        return @min(a, b);
    }

    pub inline fn clamp(x: i32, min_val: i32, max_val: i32) i16 {
        return @intCast(std.math.clamp(x, min_val, max_val));
    }

    // 零值检测
    pub inline fn isZero(x: i16) bool {
        return x == 0;
    }

    // 从 f32 转换 (i16 边界转换)
    pub inline fn fromF32(x: f32) i16 {
        const scaled = x * 32768.0;
        return @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
    }

    // 到 f32 转换
    pub inline fn toF32(x: i16) f32 {
        return @as(f32, @floatFromInt(x)) / 32768.0;
    }

    // 从/到 i16 (无需转换)
    pub inline fn fromI16(x: i16) i16 {
        return x;
    }

    pub inline fn toI16(x: i16) i16 {
        return x;
    }

    // Q31 <-> Q15 转换 (用于能量/累加)
    pub inline fn fromQ31(x: i32) i16 {
        // 舍入右移 15 位
        return @intCast(std.math.clamp((x + (1 << 14)) >> kShiftBits, kQ15Min, kQ15Max));
    }

    pub inline fn toQ31(x: i16) i32 {
        return @as(i32, x) << kShiftBits;
    }

    // 内存分配
    pub fn allocSampleArray(allocator: std.mem.Allocator, size: usize) ![]Sample {
        return try allocator.alloc(Sample, size);
    }
};

/// 定点 FFT 实现占位符
pub const FixedFftQ15 = struct {
    pub fn init() FixedFftQ15 {
        return .{};
    }

    pub fn fft(self: *FixedFftQ15, input: []const i16, output_re: []i16, output_im: []i16) void {
        _ = self;
        _ = input;
        _ = output_re;
        _ = output_im;
        // TODO: 实现定点 FFT
    }
};

/// 定点自适应滤波器占位符
pub const AdaptiveFilterFixedQ15 = struct {
    pub fn init() AdaptiveFilterFixedQ15 {
        return .{};
    }
};

// 测试
test "FixedQ15 basic operations" {
    const P = FixedQ15;

    // 基本运算
    try std.testing.expectEqual(P.add(10000, 20000), 30000);
    try std.testing.expectEqual(P.sub(30000, 10000), 20000);

    // 乘法: Q15 * Q15
    // 0.5 * 0.5 = 0.25 -> 16384 * 16384 = 268435456 -> >>15 = 8192 (0.25 in Q15)
    const mul_result = P.mul(16384, 16384);
    try std.testing.expectApproxEqAbs(P.toF32(mul_result), 0.25, 0.001);

    // 饱和检测
    try std.testing.expectEqual(P.add(20000, 20000), 32767); // 饱和到 max
    try std.testing.expectEqual(P.sub(-20000, 20000), -32768); // 饱和到 min
}

test "FixedQ15 magnitude approximation" {
    const P = FixedQ15;

    // 3-4-5 三角形
    const re = P.fromF32(0.6); // 3/5
    const im = P.fromF32(0.8); // 4/5
    const mag = P.magnitude(re, im);
    // 期望 ~1.0 (Q15 的 32767)
    try std.testing.expect(mag > 30000);
}

test "FixedQ15 type conversion" {
    const P = FixedQ15;

    // f32 -> i16 -> f32
    const original: f32 = 0.5;
    const fixed = P.fromF32(original);
    try std.testing.expectEqual(fixed, 16384);

    const recovered = P.toF32(fixed);
    try std.testing.expectApproxEqAbs(recovered, original, 0.0001);
}

test "FixedQ15 Q31 conversion" {
    const P = FixedQ15;

    // Q15 -> Q31 -> Q15
    const q15: i16 = 16384; // 0.5
    const q31 = P.toQ31(q15);
    try std.testing.expectEqual(q31, 16384 << 15); // 0.5 in Q31

    const back = P.fromQ31(q31);
    try std.testing.expectEqual(back, q15);
}

test "FixedQ15 energy" {
    const P = FixedQ15;

    // 能量: Q15 -> Q30
    const re: i16 = 16384; // 0.5
    const im: i16 = 16384;
    const e = P.energy(re, im); // 0.5^2 + 0.5^2 = 0.5 in Q30
    // 0.5 in Q30 = 0.5 * 2^30 = 536870912
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(e)), 536870912.0, 1000.0);
}
