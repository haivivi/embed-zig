//! WebRTC AEC3 Zig 实现
//! 1:1 复刻 WebRTC AEC3 (Acoustic Echo Canceller 3)
//!
//! 原始 C++ 代码: https://github.com/ewan-xu/AEC3
//! WebRTC 源码: https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/
//!
//! 特性:
//! - 频域块自适应滤波 (FDBAF)
//! - 双滤波器架构 (Main + Shadow)
//! - 动态延迟估计与对齐
//! - 非线性处理 (NLP) 与舒适噪声生成
//! - 近端语音检测与保护
//! - 【关键】双精度支持: f32 (PC) + Fixed Q15 (ESP32)
//!
//! ⚠️ 定点数不是优化，是 ESP32 的基本要求！
//! ESP32 无硬件 FPU，软浮点比定点慢 50-100 倍，无法满足 4ms 处理 deadline。

const std = @import("std");

// ============================================================================
// 公共导出
// ============================================================================

/// 核心常量
pub const common = @import("common.zig");

/// FFT 数据结构
pub const fft_data = @import("fft_data.zig");
pub const FftData = fft_data.FftData;

/// AEC3 FFT 包装器
pub const aec3_fft = @import("aec3_fft.zig");
pub const Aec3Fft = aec3_fft.Aec3Fft;

/// Ooura FFT 实现
pub const ooura_fft = @import("ooura_fft.zig");

/// 自适应 FIR 滤波器
pub const adaptive_fir_filter = @import("adaptive_fir_filter.zig");
pub const AdaptiveFirFilter = adaptive_fir_filter.AdaptiveFirFilter;

// ============================================================================
// 【新增】双精度系统 (关键!)
// ============================================================================

/// 双精度系统 - 一份代码，编译期生成两个版本
/// Float32: PC/Server 使用 f32 内部计算
/// FixedQ15: ESP32/MCU 使用定点计算 (无 FPU 要求)
pub const precision = @import("precision/precision.zig");

/// f32 精度定义
pub const Float32 = precision.Float32;

/// Q15 定点精度定义
pub const FixedQ15 = precision.FixedQ15;

/// 精度类型枚举
pub const PrecisionType = precision.PrecisionType;
pub const PrecisionConfig = precision.PrecisionConfig;

/// 默认精度选择 (根据目标平台自动)
/// - PC/Server: Float32
/// - ESP32/MCU: FixedQ15
pub const defaultPrecision = precision.defaultPrecision;

/// AEC3 comptime 泛型 (推荐)
/// 使用: EchoCanceller3(.Float32) 或 EchoCanceller3(.FixedQ15)
pub const EchoCanceller3 = precision.EchoCanceller3;

/// f32 版本便捷别名
pub const EchoCanceller3F32 = precision.EchoCanceller3F32;

/// 定点版本便捷别名
pub const EchoCanceller3Fixed = precision.EchoCanceller3Fixed;

/// 双精度比较工具
pub const DualPrecisionUtils = precision.DualPrecisionUtils;

// ============================================================================
// 版本信息
// ============================================================================

pub const version = "0.1.0";
pub const webrtc_version = "M108";  // 基于的 WebRTC 版本

// ============================================================================
// 配置结构
// ============================================================================

/// AEC3 配置参数
/// 1:1 对应 /tmp/AEC3/api/echo_canceller3_config.h
pub const EchoCanceller3Config = struct {
    /// 采样率 (16/32/48 kHz)
    sample_rate_hz: u32 = 16000,
    
    /// 远端通道数
    num_render_channels: usize = 1,
    
    /// 近端通道数
    num_capture_channels: usize = 1,
    
    /// 主滤波器长度 (分区数)
    /// 每个分区 64 样本 @ 16kHz
    /// 12 分区 = 48ms, 32 分区 = 128ms
    main_filter_length_blocks: usize = 12,
    
    /// 阴影滤波器长度
    shadow_filter_length_blocks: usize = 8,
    
    /// 滤波器大小调整持续时间 (块数)
    size_change_duration_blocks: usize = 10,
    
    /// NLP 地板值 (最小抑制增益)
    /// 0.00001 = -50dB
    nlp_floor: f32 = 0.00001,
    
    /// 回声路径延迟头部空间 (分区数)
    /// 用于处理延迟估计误差
    delay_headroom_blocks: usize = 4,
    
    /// 最大延迟 (毫秒)
    max_delay_ms: u32 = 500,
    
    /// 是否启用舒适噪声
    enable_comfort_noise: bool = true,
    
    /// 舒适噪声生成器增益
    comfort_noise_gain: f32 = 1.0,
    
    /// 自适应滤波器步长
    /// 较大的值收敛快但不稳定
    step_size_main: f32 = 0.5,
    step_size_shadow: f32 = 0.8,
    
    /// 正则化因子 (防止除零)
    regularization: f32 = 1e-10,
    
    /// 近端检测阈值
    near_end_threshold: f32 = 0.5,
    
    /// 近端检测挂起时间 (块数)
    near_end_hangover_blocks: usize = 5,
};

/// Fixed-Float 量化配置
pub const FixedFloatConfig = struct {
    /// 反量化策略 (i16 -> f32)
    pub const DequantizeStrategy = enum {
        precise,    // value / 32768.0
        fast,       // value * 0.000030517578125
    };
    
    /// 量化策略 (f32 -> i16)
    pub const QuantizeStrategy = enum {
        precise,    // round(value * 32768.0)
        fast,       // truncate(value * 32768.0)
        dithered,   // + triangular noise
    };
    
    dequantize: DequantizeStrategy = .precise,
    quantize: QuantizeStrategy = .precise,
    dither_amplitude: f32 = 1.0,
};

// ============================================================================
// 工具函数
// ============================================================================

/// Fixed-Float 转换器
/// 提供 i16 <-> f32 的转换功能
pub fn FixedFloat(comptime config: FixedFloatConfig) type {
    return struct {
        const Self = @This();
        
        const scale_up: f32 = 32768.0;
        const scale_down: f32 = 1.0 / 32768.0;
        
        /// i16 -> f32
        pub inline fn dequantize(i: i16) f32 {
            return @as(f32, @floatFromInt(i)) * scale_down;
        }
        
        /// f32 -> i16
        pub inline fn quantize(f: f32) i16 {
            return switch (config.quantize) {
                .precise => quantizePrecise(f),
                .fast => quantizeFast(f),
                .dithered => quantizeDithered(f),
            };
        }
        
        inline fn quantizePrecise(f: f32) i16 {
            const scaled = f * scale_up;
            const rounded = @round(scaled);
            // 限幅到 i16 范围 [-32768, 32767]
            const clamped = std.math.clamp(rounded, -32768.0, 32767.0);
            return @intFromFloat(clamped);
        }
        
        inline fn quantizeFast(f: f32) i16 {
            const scaled = f * scale_up;
            const clamped = std.math.clamp(scaled, -32768.0, 32767.0);
            return @intFromFloat(clamped);  // truncate
        }
        
        inline fn quantizeDithered(f: f32) i16 {
            // 简单三角抖动: (rand1 - rand2) * amplitude * delta
            const dither = generateTriangularDither();
            const scaled = (f + dither) * scale_up;
            const rounded = @round(scaled);
            const clamped = std.math.clamp(rounded, -32768.0, 32767.0);
            return @intFromFloat(clamped);
        }
        
        fn generateTriangularDither() f32 {
            // 简化的三角抖动 (不使用 PRNG，使用固定模式)
            // 实际应用中应使用 std.Random 或更好的 PRNG
            return 0.0;  // 暂时禁用抖动
        }
        
        /// 批量转换
        pub fn dequantizeSlice(input: []const i16, output: []f32) void {
            std.debug.assert(input.len == output.len);
            for (input, output) |in, *out| {
                out.* = dequantize(in);
            }
        }
        
        pub fn quantizeSlice(input: []const f32, output: []i16) void {
            std.debug.assert(input.len == output.len);
            for (input, output) |in, *out| {
                out.* = quantize(in);
            }
        }
    };
}

/// 计算 ERLE (Echo Return Loss Enhancement)
pub fn computeERLE(
    mic_signal: []const f32,
    clean_signal: []const f32,
) f32 {
    std.debug.assert(mic_signal.len == clean_signal.len);
    
    var mic_power: f32 = 0;
    var clean_power: f32 = 0;
    
    for (mic_signal, clean_signal) |m, c| {
        mic_power += m * m;
        clean_power += c * c;
    }
    
    if (clean_power < 1e-10) {
        return 0;
    }
    
    const erle = mic_power / clean_power;
    return 10.0 * @log10(erle);
}

/// 计算信号功率 (dB)
pub fn computeSignalPower(signal: []const f32) f32 {
    var sum: f32 = 0;
    for (signal) |s| {
        sum += s * s;
    }
    
    const avg = sum / @as(f32, @floatFromInt(signal.len));
    return 10.0 * @log10(avg + 1e-10);
}

/// 计算 RMS (Root Mean Square)
pub fn computeRMS(signal: []const f32) f32 {
    var sum: f32 = 0;
    for (signal) |s| {
        sum += s * s;
    }
    
    const avg = sum / @as(f32, @floatFromInt(signal.len));
    return @sqrt(avg);
}

/// 计算两个信号的 SNR
pub fn computeSNR(
    reference: []const f32,
    signal: []const f32,
) f32 {
    std.debug.assert(reference.len == signal.len);
    
    var signal_power: f32 = 0;
    var noise_power: f32 = 0;
    
    for (reference, signal) |ref, sig| {
        signal_power += ref * ref;
        const diff = ref - sig;
        noise_power += diff * diff;
    }
    
    if (noise_power < 1e-10) {
        return 100.0;  // 上限
    }
    
    const snr = signal_power / noise_power;
    return 10.0 * @log10(snr);
}

// ============================================================================
// 测试
// ============================================================================

test "version" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test "FixedFloat dequantize/quantize" {
    const Q = FixedFloat(.{
        .dequantize = .precise,
        .quantize = .precise,
    });
    
    // 测试 0
    try std.testing.expectEqual(@as(f32, 0.0), Q.dequantize(0));
    try std.testing.expectEqual(@as(i16, 0), Q.quantize(0.0));
    
    // 测试 1
    const f1 = Q.dequantize(32767);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99997), f1, 0.0001);
    
    const int1 = Q.quantize(1.0);
    try std.testing.expectEqual(@as(i16, 32767), int1);
    
    // 测试 -1
    const f2 = Q.dequantize(-32768);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), f2, 0.0001);
}

test "FixedFloat slice operations" {
    const Q = FixedFloat(.{});
    
    var input: [10]f32 = undefined;
    for (0..10) |i| {
        input[i] = @as(f32, @floatFromInt(i)) / 10.0;
    }
    
    var output: [10]i16 = undefined;
    Q.quantizeSlice(&input, &output);
    
    var recovered: [10]f32 = undefined;
    Q.dequantizeSlice(&output, &recovered);
    
    // 验证 roundtrip
    for (0..10) |i| {
        try std.testing.expectApproxEqAbs(input[i], recovered[i], 0.0001);
    }
}

test "computeERLE" {
    // mic = [1, 1, 1, 1], clean = [0.1, 0.1, 0.1, 0.1]
    // mic_power = 4, clean_power = 0.04
    // ERLE = 4/0.04 = 100 = 20 dB
    
    const mic = &[_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const clean = &[_]f32{ 0.1, 0.1, 0.1, 0.1 };
    
    const erle = computeERLE(mic, clean);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), erle, 0.1);
}

test "computeSignalPower" {
    const signal = &[_]f32{ 0.5, 0.5, 0.5, 0.5 };
    const power = computeSignalPower(signal);
    
    // 平均功率 = 0.25, dB = 10*log10(0.25) = -6.02 dB
    try std.testing.expectApproxEqAbs(@as(f32, -6.02), power, 0.1);
}

test "computeRMS" {
    const signal = &[_]f32{ 3.0, 4.0 };
    const rms = computeRMS(signal);
    
    // RMS = sqrt((9+16)/2) = sqrt(12.5) = 3.535
    try std.testing.expectApproxEqAbs(@as(f32, 3.535), rms, 0.01);
}

test "computeSNR" {
    const ref = &[_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const sig = &[_]f32{ 1.01, 0.99, 1.0, 1.0 };  // 有小误差
    
    const snr = computeSNR(ref, sig);
    try std.testing.expect(snr > 30.0);  // SNR 应该很高
}
