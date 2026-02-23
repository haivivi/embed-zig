//! WebRTC AEC3 核心常量定义
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/aec3_common.h

const std = @import("std");

// ============================================================================
// FFT 相关常量
// ============================================================================

/// FFT 半长 (64 点)
pub const kFftLengthBy2 = 64;

/// FFT 半长 + 1 (包含 DC 和 Nyquist 频率)
pub const kFftLengthBy2Plus1 = kFftLengthBy2 + 1; // 65

/// FFT 半长 - 1
pub const kFftLengthBy2Minus1 = kFftLengthBy2 - 1; // 63

/// FFT 全长 (128 点)
pub const kFftLength = 2 * kFftLengthBy2; // 128

/// log2(kFftLengthBy2) = 6
pub const kFftLengthBy2Log2 = 6;

// ============================================================================
// 块处理相关常量
// ============================================================================

/// 块大小 (64 样本 @ 16kHz = 4ms)
pub const kBlockSize = kFftLengthBy2; // 64

/// log2(kBlockSize)
pub const kBlockSizeLog2 = 6;

/// 帧大小 (160 样本 @ 16kHz = 10ms)
pub const kFrameSize = 160;

/// 子帧长度
pub const kSubFrameLength = kFrameSize / 2; // 80

/// 扩展块大小 (用于某些处理)
pub const kExtendedBlockSize = 2 * kFftLengthBy2; // 128

// ============================================================================
// 带宽相关常量
// ============================================================================

/// 最大频带数 (支持 16/32/48 kHz)
pub const kMaxNumBands = 3;

/// 每秒块数 (250 blocks/s @ 16kHz with 64-sample blocks)
pub const kNumBlocksPerSecond = 250;

/// 渲染传输队列大小 (帧数)
pub const kRenderTransferQueueSizeFrames = 100;

// ============================================================================
// 延迟估计相关常量
// ============================================================================

/// 匹配滤波器窗口大小 (子块数)
pub const kMatchedFilterWindowSizeSubBlocks = 32;

/// 匹配滤波器对齐移位大小 (子块数)
pub const kMatchedFilterAlignmentShiftSizeSubBlocks = kMatchedFilterWindowSizeSubBlocks * 3 / 4; // 24

// ============================================================================
// 指标报告相关常量
// ============================================================================

/// 指标报告间隔 (块数) = 10 秒
pub const kMetricsReportingIntervalBlocks = 10 * kNumBlocksPerSecond; // 2500

/// 指标计算块数
pub const kMetricsComputationBlocks = 11;

/// 指标收集块数
pub const kMetricsCollectionBlocks = kMetricsReportingIntervalBlocks - kMetricsComputationBlocks; // 2489

// ============================================================================
// 工具函数
// ============================================================================

/// 根据采样率获取频带数
pub inline fn NumBandsForRate(sample_rate_hz: i32) usize {
    return @intCast(sample_rate_hz / 16000);
}

/// 检查是否为有效的全带采样率
pub inline fn ValidFullBandRate(sample_rate_hz: i32) bool {
    return sample_rate_hz == 16000 or sample_rate_hz == 32000 or sample_rate_hz == 48000;
}

/// 获取时域滤波器长度
pub inline fn GetTimeDomainLength(filter_length_blocks: i32) i32 {
    return filter_length_blocks * kFftLengthBy2;
}

/// 快速近似 log2 (来自 aec3_common.cc)
pub inline fn FastApproxLog2f(v: f32) f32 {
    // 提取浮点数的指数部分
    const bits: u32 = @bitCast(v);
    const exponent: i32 = @as(i32, @intCast((bits >> 23) & 0xFF)) - 127;
    return @floatFromInt(exponent);
}

/// log2 转 dB
pub inline fn Log2TodB(log2_value: f32) f32 {
    // dB = 20 * log10(x) = 20 * log2(x) / log2(10)
    return log2_value * 20.0 / std.math.log2(10.0);
}

// ============================================================================
// 编译期断言 (验证常量)
// ============================================================================

comptime {
    std.debug.assert(1 << kBlockSizeLog2 == kBlockSize);
    std.debug.assert(1 << kFftLengthBy2Log2 == kFftLengthBy2);
    std.debug.assert(NumBandsForRate(16000) == 1);
    std.debug.assert(NumBandsForRate(32000) == 2);
    std.debug.assert(NumBandsForRate(48000) == 3);
    std.debug.assert(ValidFullBandRate(16000));
    std.debug.assert(ValidFullBandRate(32000));
    std.debug.assert(ValidFullBandRate(48000));
    std.debug.assert(!ValidFullBandRate(8000));
}
