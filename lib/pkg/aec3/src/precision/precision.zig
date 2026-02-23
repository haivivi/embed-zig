/// AEC3 双精度系统顶层泛型
/// 提供 comptime 精度选择和 AEC3 泛型实现
const std = @import("std");
const builtin = @import("builtin");

pub const float32 = @import("float32.zig");
pub const fixed_q15 = @import("fixed_q15.zig");

pub const Float32 = float32.Float32;
pub const FixedQ15 = fixed_q15.FixedQ15;

/// 精度类型枚举
pub const PrecisionType = enum {
    Float32,
    FixedQ15,
};

/// 精度选择配置
pub const PrecisionConfig = union(PrecisionType) {
    Float32: void,
    FixedQ15: void,
};

/// 根据目标平台自动选择默认精度
/// - PC/Server: Float32 (硬件 FPU 支持)
/// - ESP32/MCU: FixedQ15 (无 FPU，软浮点太慢)
pub inline fn defaultPrecision() PrecisionConfig {
    return switch (builtin.target.cpu.arch) {
        .xtensa, .arm, .thumb => .FixedQ15,
        else => .Float32,
    };
}

/// 获取精度类型的相关信息
pub fn PrecisionInfo(comptime p: PrecisionConfig) type {
    return switch (p) {
        .Float32 => struct {
            pub const name = "Float32";
            pub const sample_type = f32;
            pub const has_fpu = true;
            pub const is_fixed_point = false;
            pub const Implementation = Float32;
        },
        .FixedQ15 => struct {
            pub const name = "FixedQ15";
            pub const sample_type = i16;
            pub const has_fpu = false;
            pub const is_fixed_point = true;
            pub const Implementation = FixedQ15;
        },
    };
}

/// AEC3 comptime 泛型
/// 一份代码，编译期生成两个版本
pub fn EchoCanceller3(comptime precision: PrecisionConfig) type {
    const P = switch (precision) {
        .Float32 => Float32,
        .FixedQ15 => FixedQ15,
    };

    return struct {
        const Self = @This();
        const Precision = P;

        // 配置参数
        sample_rate: u32,
        num_render_channels: usize,
        num_capture_channels: usize,

        // FFT 实例
        fft: P.Fft,

        // 自适应滤波器
        adaptive_filter: P.AdaptiveFilter,

        pub const Config = struct {
            sample_rate: u32 = 16000,
            num_render_channels: usize = 1,
            num_capture_channels: usize = 1,
        };

        pub fn init(config: Config) Self {
            return .{
                .sample_rate = config.sample_rate,
                .num_render_channels = config.num_render_channels,
                .num_capture_channels = config.num_capture_channels,
                .fft = P.Fft.init(),
                .adaptive_filter = P.AdaptiveFilter.init(),
            };
        }

        /// 处理一帧音频
        /// input: 麦克风输入 (包含近端语音 + 回声)
        /// reference: 远端参考信号
        /// output: 处理后的干净信号
        pub fn process(
            self: *Self,
            input: []const P.Sample,
            reference: []const P.Sample,
            output: []P.Sample,
        ) !void {
            _ = self;
            _ = reference;  // TODO: 将在完整 AEC3 实现中使用
            // 参数校验
            if (input.len != output.len) return error.BufferSizeMismatch;
            if (input.len == 0) return error.EmptyBuffer;

            // TODO: 完整 AEC3 处理流程
            // 1. 分块处理
            // 2. FFT 变换
            // 3. 自适应滤波
            // 4. 回声消除
            // 5. IFFT 输出

            // 暂时直接拷贝 (pass-through)
            for (input, 0..) |s, i| {
                output[i] = s;
            }
        }

        /// 获取当前 ERLE (回声回波损耗增强)
        pub fn getERLE(self: *Self) f32 {
            _ = self;
            return 0.0; // TODO
        }

        /// 获取收敛状态
        pub fn isConverged(self: *Self) bool {
            _ = self;
            return false; // TODO
        }
    };
}

/// 便捷别名
pub const EchoCanceller3F32 = EchoCanceller3(.Float32);
pub const EchoCanceller3Fixed = EchoCanceller3(.FixedQ15);

/// 双精度比较工具
pub const DualPrecisionUtils = struct {
    /// 计算两个精度版本的 SNR 差异
    pub fn computePrecisionSNR(f32_samples: []const f32, fixed_samples: []const i16) f32 {
        std.debug.assert(f32_samples.len == fixed_samples.len);

        var mse: f64 = 0;
        var signal_power: f64 = 0;

        for (f32_samples, 0..) |f, i| {
            const q = FixedQ15.toF32(fixed_samples[i]);
            const diff = f - q;
            mse += diff * diff;
            signal_power += f * f;
        }

        if (mse < 1e-20) return 100.0; // 无误差

        const snr = 10.0 * std.math.log10(signal_power / mse);
        return @floatCast(snr);
    }

    /// 验证双精度等效性 (SNR > threshold)
    pub fn verifyEquivalence(
        f32_samples: []const f32,
        fixed_samples: []const i16,
        min_snr_db: f32,
    ) !void {
        const snr = computePrecisionSNR(f32_samples, fixed_samples);
        if (snr < min_snr_db) {
            std.log.err("Precision equivalence failed: SNR = {d:.2}dB (threshold: {d:.2}dB)", .{ snr, min_snr_db });
            return error.InsufficientPrecision;
        }
        std.log.info("Precision equivalence passed: SNR = {d:.2}dB", .{snr});
    }
};

// 测试
test "Precision selection" {
    const default = defaultPrecision();

    // 在当前平台应该有一个明确的默认值
    switch (builtin.target.cpu.arch) {
        .xtensa, .arm, .thumb => try std.testing.expectEqual(default, PrecisionConfig.FixedQ15),
        else => try std.testing.expectEqual(default, PrecisionConfig.Float32),
    }
}

test "PrecisionInfo metadata" {
    const f32_info = PrecisionInfo(.Float32);
    try std.testing.expectEqualStrings("Float32", f32_info.name);
    try std.testing.expect(f32_info.has_fpu);
    try std.testing.expect(!f32_info.is_fixed_point);

    const fixed_info = PrecisionInfo(.FixedQ15);
    try std.testing.expectEqualStrings("FixedQ15", fixed_info.name);
    try std.testing.expect(!fixed_info.has_fpu);
    try std.testing.expect(fixed_info.is_fixed_point);
}

test "EchoCanceller3 instantiation" {
    // f32 版本
    const aec_f32 = EchoCanceller3F32.init(.{
        .sample_rate = 16000,
        .num_render_channels = 1,
        .num_capture_channels = 1,
    });
    try std.testing.expectEqual(aec_f32.sample_rate, 16000);

    // Fixed 版本
    const aec_fixed = EchoCanceller3Fixed.init(.{
        .sample_rate = 16000,
    });
    try std.testing.expectEqual(aec_fixed.sample_rate, 16000);
}

test "DualPrecisionUtils SNR computation" {
    const utils = DualPrecisionUtils;

    // 相同信号 -> 高 SNR
    var f32_samples = [_]f32{ 0.5, -0.25, 0.1, -0.8 };
    var fixed_samples = [_]i16{
        FixedQ15.fromF32(0.5),
        FixedQ15.fromF32(-0.25),
        FixedQ15.fromF32(0.1),
        FixedQ15.fromF32(-0.8),
    };

    const snr = utils.computePrecisionSNR(&f32_samples, &fixed_samples);
    // 应该有较高的 SNR (量化噪声很小)
    try std.testing.expect(snr > 40.0);

    // 验证通过
    try utils.verifyEquivalence(&f32_samples, &fixed_samples, 30.0);
}

test "EchoCanceller3 basic process" {
    var aec = EchoCanceller3F32.init(.{ .sample_rate = 16000 });

    var input = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var reference = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var output = [_]f32{ 0, 0, 0, 0 };

    try aec.process(&input, &reference, &output);

    // 目前是 pass-through，输出应该等于输入
    for (input, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(output[i], expected, 0.0001);
    }
}
