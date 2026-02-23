//! AEC3 专用的 FFT 包装器
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/aec3_fft.h

const std = @import("std");
const common = @import("common.zig");
const fft_data = @import("fft_data.zig");
const ooura_fft = @import("ooura_fft.zig");

const FftData = fft_data.FftData;
const Aec3OouraFft = ooura_fft.Aec3OouraFft;

// ============================================================================
// AEC3 FFT 包装器
// ============================================================================

pub const Aec3Fft = struct {
    const Self = @This();
    
    /// 窗函数类型
    pub const Window = enum {
        kRectangular,  // 矩形窗 (无窗)
        kHanning,      // Hanning 窗
        kSqrtHanning,  // 平方根 Hanning 窗 (用于合成)
    };
    
    ooura_fft_impl: Aec3OouraFft,
    
    /// 创建默认 FFT 实例
    pub fn init() Self {
        return .{
            .ooura_fft_impl = Aec3OouraFft{},
        };
    }
    
    /// 计算 FFT
    /// 注意: 输入和输出都会被修改
    pub fn fft(self: Self, x: *[common.kFftLength]f32, X: *FftData) void {
        self.ooura_fft_impl.fft(x);
        X.copyFromPackedArray(x);
    }
    
    /// 计算逆 FFT
    pub fn ifft(self: Self, X: *const FftData, x: *[common.kFftLength]f32) void {
        var temp: [common.kFftLength]f32 = undefined;
        X.copyToPackedArray(&temp);
        self.ooura_fft_impl.inverseFft(&temp);
        @memcpy(x, &temp);
    }
    
    /// 零填充 FFT (用于初始块处理)
    /// x: 64 样本输入
    /// window: 窗函数类型
    /// X: 输出 FFT 数据
    pub fn zeroPaddedFft(
        self: Self,
        x: []const f32,
        window: Window,
        X: *FftData,
    ) void {
        std.debug.assert(x.len <= common.kFftLengthBy2);
        
        // 创建 128 点缓冲区
        var buffer: [common.kFftLength]f32 = undefined;
        
        // 前半部分填充零
        @memset(buffer[0..common.kFftLengthBy2], 0);
        
        // 后半部分填充输入信号 (加窗)
        switch (window) {
            .kRectangular => {
                @memcpy(buffer[common.kFftLengthBy2..][0..x.len], x);
                if (x.len < common.kFftLengthBy2) {
                    @memset(buffer[common.kFftLengthBy2 + x.len..], 0);
                }
            },
            .kHanning => {
                applyHanningWindow(x, buffer[common.kFftLengthBy2..]);
            },
            .kSqrtHanning => {
                applySqrtHanningWindow(x, buffer[common.kFftLengthBy2..]);
            },
        }
        
        // FFT
        self.fft(&buffer, X);
    }
    
    /// 填充 FFT (重叠保存法)
    /// x: 64 样本新输入
    /// x_old: 64 样本旧输入
    /// window: 窗函数类型
    /// X: 输出 FFT 数据
    pub fn paddedFft(
        self: Self,
        x: []const f32,
        x_old: []const f32,
        window: Window,
        X: *FftData,
    ) void {
        std.debug.assert(x.len == common.kFftLengthBy2);
        std.debug.assert(x_old.len == common.kFftLengthBy2);
        
        // 创建 128 点缓冲区: [x_old; x]
        var buffer: [common.kFftLength]f32 = undefined;
        
        // 前半部分是旧数据
        @memcpy(buffer[0..common.kFftLengthBy2], x_old);
        
        // 后半部分是新数据
        @memcpy(buffer[common.kFftLengthBy2..], x);
        
        // 应用窗函数
        switch (window) {
            .kHanning => {
                applyHanningWindowToBothHalves(&buffer);
            },
            .kSqrtHanning => {
                applySqrtHanningWindowToBothHalves(&buffer);
            },
            .kRectangular => {
                // 不应用窗函数
            },
        }
        
        // FFT
        self.fft(&buffer, X);
    }
    
    /// 重叠保存法的 IFFT 后处理
    /// X: 频域数据
    /// x: 时域输出 (64 样本)
    /// x_old: 用于重叠保存的前一个时域输出 (会被更新)
    pub fn ifftAndOverlapSave(
        self: Self,
        X: *const FftData,
        x: *[common.kBlockSize]f32,
        x_old: *[common.kFftLengthBy2]f32,
    ) void {
        var buffer: [common.kFftLength]f32 = undefined;
        
        // IFFT
        self.ifft(X, &buffer);
        
        // 重叠保存: 取后半部分
        @memcpy(x, buffer[common.kFftLengthBy2..][0..common.kBlockSize]);
        
        // 保存当前前半部分用于下一次
        @memcpy(x_old, buffer[0..common.kFftLengthBy2]);
    }
};

// ============================================================================
// 窗函数实现
// ============================================================================

fn applyHanningWindow(input: []const f32, output: []f32) void {
    const Nf: f32 = @floatFromInt(input.len);
    for (input, 0..) |s, i| {
        const idx: f32 = @floatFromInt(i);
        const window: f32 = 0.5 - 0.5 * @cos(2.0 * std.math.pi * idx / Nf);
        output[i] = s * window;
    }
}

fn applySqrtHanningWindow(input: []const f32, output: []f32) void {
    const Nf: f32 = @floatFromInt(input.len);
    for (input, 0..) |s, i| {
        const idx: f32 = @floatFromInt(i);
        const window: f32 = @sqrt(0.5 - 0.5 * @cos(2.0 * std.math.pi * idx / Nf));
        output[i] = s * window;
    }
}

fn applyHanningWindowToBothHalves(buffer: *[common.kFftLength]f32) void {
    const Nf: f32 = common.kFftLength;
    for (0..common.kFftLength) |i| {
        const idx: f32 = @floatFromInt(i);
        const window: f32 = 0.5 - 0.5 * @cos(2.0 * std.math.pi * idx / Nf);
        buffer[i] *= window;
    }
}

fn applySqrtHanningWindowToBothHalves(buffer: *[common.kFftLength]f32) void {
    const Nf: f32 = common.kFftLength;
    for (0..common.kFftLength) |i| {
        const idx: f32 = @floatFromInt(i);
        const window: f32 = @sqrt(0.5 - 0.5 * @cos(2.0 * std.math.pi * idx / Nf));
        buffer[i] *= window;
    }
}

// ============================================================================
// 测试
// ============================================================================

test "Aec3Fft basic fft/ifft" {
    var fft_impl = Aec3Fft.init();
    
    // 测试信号
    var buffer: [common.kFftLength]f32 = undefined;
    for (0..common.kFftLength) |i| {
        buffer[i] = @sin(2.0 * std.math.pi * 5.0 * @as(f32, @floatFromInt(i)) / common.kFftLength);
    }
    
    var original: [common.kFftLength]f32 = undefined;
    @memcpy(&original, &buffer);
    
    var X: FftData = undefined;
    
    // FFT
    fft_impl.fft(&buffer, &X);
    
    // IFFT
    var output: [common.kFftLength]f32 = undefined;
    fft_impl.ifft(&X, &output);
    
    // 验证
    var max_error: f32 = 0;
    for (0..common.kFftLength) |i| {
        max_error = @max(max_error, @abs(output[i] - original[i]));
    }
    
    try std.testing.expect(max_error < 0.0001);
}

test "Aec3Fft zero padded fft" {
    var fft_impl = Aec3Fft.init();
    
    // 64 样本输入
    var input: [common.kBlockSize]f32 = undefined;
    for (0..common.kBlockSize) |i| {
        input[i] = @sin(2.0 * std.math.pi * 3.0 * @as(f32, @floatFromInt(i)) / common.kBlockSize);
    }
    
    var X: FftData = undefined;
    fft_impl.zeroPaddedFft(&input, .kRectangular, &X);
    
    // 验证频谱不为空
    var has_energy = false;
    for (0..common.kFftLengthBy2Plus1) |k| {
        const power = X.re[k] * X.re[k] + X.im[k] * X.im[k];
        if (power > 0.1) {
            has_energy = true;
            break;
        }
    }
    
    try std.testing.expect(has_energy);
}

test "Aec3Fft padded fft with overlap" {
    var fft_impl = Aec3Fft.init();
    
    // 两组 64 样本
    var x_old: [common.kFftLengthBy2]f32 = undefined;
    var x: [common.kFftLengthBy2]f32 = undefined;
    
    for (0..common.kFftLengthBy2) |i| {
        x_old[i] = @floatFromInt(i);
        x[i] = @floatFromInt(i + 64);
    }
    
    var X: FftData = undefined;
    fft_impl.paddedFft(&x, &x_old, .kRectangular, &X);
    
    // 验证频谱
    var total_power: f32 = 0;
    for (0..common.kFftLengthBy2Plus1) |k| {
        total_power += X.re[k] * X.re[k] + X.im[k] * X.im[k];
    }
    
    // 应该有非零能量
    try std.testing.expect(total_power > 0);
}

test "Aec3Fft overlap save" {
    var fft_impl = Aec3Fft.init();
    
    // 创建频域数据 (简单冲激)
    var X: FftData = undefined;
    X.clear();
    X.re[0] = common.kFftLength; // DC 分量
    
    // 输出缓冲区
    var output: [common.kBlockSize]f32 = undefined;
    var x_old: [common.kFftLengthBy2]f32 = undefined;
    @memset(&x_old, 0);
    
    // IFFT + 重叠保存
    fft_impl.ifftAndOverlapSave(&X, &output, &x_old);
    
    // 输出应该全为 1 (因为 DC 分量是 128)
    for (0..common.kBlockSize) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), output[i], 0.001);
    }
}

test "Hanning window" {
    var input: [16]f32 = undefined;
    var output: [16]f32 = undefined;
    
    @memset(&input, 1.0);
    applyHanningWindow(&input, &output);
    
    // 窗的首尾应该接近 0
    try std.testing.expect(output[0] < 0.001);
    try std.testing.expect(output[15] < 0.001);
    
    // 窗的中间应该接近 1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), output[7], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), output[8], 0.01);
}
