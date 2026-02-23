/// Float32 精度定义
/// PC/Server 平台使用 f32 进行内部计算
const std = @import("std");

/// f32 精度定义
pub const Float32 = struct {
    // 核心类型
    pub const Sample = f32;
    pub const Accumulator = f64;
    pub const ComplexSample = std.math.Complex(f32);

    // FFT 实现占位符
    pub const Fft = OouraFftF32;

    // 滤波器实现占位符
    pub const AdaptiveFilter = AdaptiveFilterF32;

    // 基本运算 (直接映射到硬件 FPU)
    pub inline fn add(a: f32, b: f32) f32 {
        return a + b;
    }

    pub inline fn sub(a: f32, b: f32) f32 {
        return a - b;
    }

    pub inline fn mul(a: f32, b: f32) f32 {
        return a * b;
    }

    pub inline fn mulAccum(a: f32, b: f32, acc: f64) f64 {
        return acc + @as(f64, a) * @as(f64, b);
    }

    pub inline fn div(a: f32, b: f32) f32 {
        return a / b;
    }

    pub inline fn scale(value: f32, factor: f32) f32 {
        return value * factor;
    }

    // 能量相关
    pub inline fn energy(re: f32, im: f32) f32 {
        return re * re + im * im;
    }

    pub inline fn magnitude(re: f32, im: f32) f32 {
        return @sqrt(re * re + im * im);
    }

    // 平方根 (硬件加速)
    pub inline fn sqrt(x: f32) f32 {
        return @sqrt(x);
    }

    // 对数 (软件实现)
    pub inline fn log2(x: f32) f32 {
        return @log2(x);
    }

    // 比较
    pub inline fn max(a: f32, b: f32) f32 {
        return @max(a, b);
    }

    pub inline fn min(a: f32, b: f32) f32 {
        return @min(a, b);
    }

    pub inline fn clamp(x: f32, min_val: f32, max_val: f32) f32 {
        return std.math.clamp(x, min_val, max_val);
    }

    // 零值检测
    pub inline fn isZero(x: f32) bool {
        return x == 0.0;
    }

    // 类型转换 (无需转换，已是 f32)
    pub inline fn fromF32(x: f32) f32 {
        return x;
    }

    pub inline fn toF32(x: f32) f32 {
        return x;
    }

    // 从/到 i16 (边界转换)
    pub inline fn fromI16(x: i16) f32 {
        return @as(f32, @floatFromInt(x)) / 32768.0;
    }

    pub inline fn toI16(x: f32) i16 {
        const scaled = x * 32768.0;
        return @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
    }

    // 内存分配
    pub fn allocSampleArray(allocator: std.mem.Allocator, size: usize) ![]Sample {
        return try allocator.alloc(Sample, size);
    }
};

/// f32 FFT 实现占位符
pub const OouraFftF32 = struct {
    pub fn init() OouraFftF32 {
        return .{};
    }

    pub fn fft(self: *OouraFftF32, input: []const i16, output_re: []f32, output_im: []f32) void {
        _ = self;
        _ = input;
        _ = output_re;
        _ = output_im;
        // TODO: 实现 f32 FFT
    }
};

/// f32 自适应滤波器占位符
pub const AdaptiveFilterF32 = struct {
    pub fn init() AdaptiveFilterF32 {
        return .{};
    }
};

// 测试
test "Float32 basic operations" {
    const P = Float32;

    // 基本运算
    try std.testing.expectApproxEqAbs(P.add(1.0, 2.0), 3.0, 0.0001);
    try std.testing.expectApproxEqAbs(P.sub(3.0, 1.0), 2.0, 0.0001);
    try std.testing.expectApproxEqAbs(P.mul(2.0, 3.0), 6.0, 0.0001);
    try std.testing.expectApproxEqAbs(P.div(6.0, 2.0), 3.0, 0.0001);

    // 能量计算
    const e = P.energy(3.0, 4.0);  // 3^2 + 4^2 = 25
    try std.testing.expectApproxEqAbs(e, 25.0, 0.0001);

    // 幅度计算
    const m = P.magnitude(3.0, 4.0);  // sqrt(25) = 5
    try std.testing.expectApproxEqAbs(m, 5.0, 0.0001);

    // 类型转换
    const from_i16 = P.fromI16(16384);  // 0.5
    try std.testing.expectApproxEqAbs(from_i16, 0.5, 0.0001);

    const to_i16 = P.toI16(0.5);  // 16384
    try std.testing.expectEqual(to_i16, 16384);
}

test "Float32 clamp" {
    const P = Float32;

    try std.testing.expectEqual(P.clamp(1.5, 0.0, 1.0), 1.0);
    try std.testing.expectEqual(P.clamp(-0.5, 0.0, 1.0), 0.0);
    try std.testing.expectEqual(P.clamp(0.5, 0.0, 1.0), 0.5);
}

test "Float32 max/min" {
    const P = Float32;

    try std.testing.expectEqual(P.max(1.0, 2.0), 2.0);
    try std.testing.expectEqual(P.min(1.0, 2.0), 1.0);
}
