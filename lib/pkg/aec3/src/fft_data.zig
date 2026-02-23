//! FFT 数据结构
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/fft_data.h

const std = @import("std");
const common = @import("common.zig");

// ============================================================================
// FftData 结构
// ============================================================================

/// FFT 数据结构，存储复数 FFT 结果
/// 大小为 kFftLengthBy2Plus1 = 65 (包含 DC 和 Nyquist 频率)
pub const FftData = extern struct {
    /// 实部
    re: [common.kFftLengthBy2Plus1]f32,
    /// 虚部
    im: [common.kFftLengthBy2Plus1]f32,

    const Self = @This();

    /// 清空所有数据
    pub fn clear(self: *Self) void {
        @memset(&self.re, 0);
        @memset(&self.im, 0);
    }

    /// 从另一个 FftData 复制
    pub fn assign(self: *Self, src: *const FftData) void {
        @memcpy(&self.re, &src.re);
        @memcpy(&self.im, &src.im);
        // 确保 DC 和 Nyquist 频率的虚部为 0
        self.im[0] = 0;
        self.im[common.kFftLengthBy2] = 0;
    }

    /// 计算功率谱: |X[k]|^2 = re[k]^2 + im[k]^2
    pub fn spectrum(self: *const FftData, buf: []f32) void {
        std.debug.assert(buf.len == common.kFftLengthBy2Plus1);
        for (0..common.kFftLengthBy2Plus1) |k| {
            buf[k] = self.re[k] * self.re[k] + self.im[k] * self.im[k];
        }
    }

    /// 计算功率谱并累加到目标缓冲区
    pub fn spectrumAccumulate(self: *const FftData, buf: []f32) void {
        std.debug.assert(buf.len == common.kFftLengthBy2Plus1);
        for (0..common.kFftLengthBy2Plus1) |k| {
            buf[k] += self.re[k] * self.re[k] + self.im[k] * self.im[k];
        }
    }

    /// 从打包数组复制 (Ooura FFT 格式)
    /// 输入格式: [re[0], re[64], re[1], im[1], re[2], im[2], ..., re[63], im[63]]
    pub fn copyFromPackedArray(self: *Self, v: *const [common.kFftLength]f32) void {
        // DC 分量 (实数)
        self.re[0] = v[0];
        // Nyquist 频率 (实数)
        self.re[common.kFftLengthBy2] = v[1];
        // 虚部在 DC 和 Nyquist 处为 0
        self.im[0] = 0;
        self.im[common.kFftLengthBy2] = 0;

        // 复制剩余频点
        var k: usize = 1;
        var j: usize = 2;
        while (k < common.kFftLengthBy2) : ({
            k += 1;
            j += 2;
        }) {
            self.re[k] = v[j];
            self.im[k] = v[j + 1];
        }
    }

    /// 复制到打包数组 (Ooura FFT 格式)
    pub fn copyToPackedArray(self: *const FftData, v: *[common.kFftLength]f32) void {
        // DC 分量
        v[0] = self.re[0];
        // Nyquist 频率
        v[1] = self.re[common.kFftLengthBy2];

        // 复制剩余频点
        var k: usize = 1;
        var j: usize = 2;
        while (k < common.kFftLengthBy2) : ({
            k += 1;
            j += 2;
        }) {
            v[j] = self.re[k];
            v[j + 1] = self.im[k];
        }
    }

    /// 逐点相加: self = self + other
    pub fn addAssign(self: *Self, other: *const FftData) void {
        for (0..common.kFftLengthBy2Plus1) |k| {
            self.re[k] += other.re[k];
            self.im[k] += other.im[k];
        }
    }

    /// 逐点相减: self = self - other
    pub fn subAssign(self: *Self, other: *const FftData) void {
        for (0..common.kFftLengthBy2Plus1) |k| {
            self.re[k] -= other.re[k];
            self.im[k] -= other.im[k];
        }
    }

    /// 逐点相乘 (复数乘法): self = self * other
    pub fn mulAssign(self: *Self, other: *const FftData) void {
        for (0..common.kFftLengthBy2Plus1) |k| {
            const re = self.re[k] * other.re[k] - self.im[k] * other.im[k];
            const im = self.re[k] * other.im[k] + self.im[k] * other.re[k];
            self.re[k] = re;
            self.im[k] = im;
        }
    }

    /// 逐点乘标量
    pub fn scale(self: *Self, s: f32) void {
        for (0..common.kFftLengthBy2Plus1) |k| {
            self.re[k] *= s;
            self.im[k] *= s;
        }
    }

    /// 计算总能量 (所有频点功率和)
    pub fn totalEnergy(self: *const FftData) f32 {
        var sum: f32 = 0;
        for (0..common.kFftLengthBy2Plus1) |k| {
            sum += self.re[k] * self.re[k] + self.im[k] * self.im[k];
        }
        return sum;
    }

    /// 计算最大频点幅值
    pub fn maxMagnitude(self: *const FftData) f32 {
        var max_mag: f32 = 0;
        for (0..common.kFftLengthBy2Plus1) |k| {
            const mag = std.math.sqrt(self.re[k] * self.re[k] + self.im[k] * self.im[k]);
            max_mag = @max(max_mag, mag);
        }
        return max_mag;
    }
};

// ============================================================================
// 测试
// ============================================================================

test "FftData clear" {
    var fft_data: FftData = undefined;
    // 填充非零值
    @memset(&fft_data.re, 1.0);
    @memset(&fft_data.im, 1.0);
    
    fft_data.clear();
    
    // 验证所有值为 0
    for (0..common.kFftLengthBy2Plus1) |i| {
        try std.testing.expectEqual(@as(f32, 0), fft_data.re[i]);
        try std.testing.expectEqual(@as(f32, 0), fft_data.im[i]);
    }
}

test "FftData spectrum" {
    var fft_data: FftData = undefined;
    fft_data.clear();
    
    // 设置一个简单信号: re[0] = 1, im[0] = 0
    fft_data.re[0] = 3.0;
    fft_data.im[0] = 4.0;
    
    var spectrum: [common.kFftLengthBy2Plus1]f32 = undefined;
    fft_data.spectrum(&spectrum);
    
    // 功率 = 3^2 + 4^2 = 25
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), spectrum[0], 0.001);
}

test "FftData pack/unpack" {
    var fft_data_var: FftData = undefined;
    fft_data_var.clear();
    
    // 设置测试值
    fft_data_var.re[0] = 1.0; // DC
    fft_data_var.re[common.kFftLengthBy2] = 2.0; // Nyquist
    fft_data_var.re[1] = 3.0;
    fft_data_var.im[1] = 4.0;
    
    var packed_array: [common.kFftLength]f32 = undefined;
    fft_data_var.copyToPackedArray(&packed_array);
    
    // 验证打包格式
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), packed_array[0], 0.001); // DC
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), packed_array[1], 0.001); // Nyquist
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), packed_array[2], 0.001); // re[1]
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), packed_array[3], 0.001); // im[1]
    
    // 解包并验证
    var unpacked: FftData = undefined;
    unpacked.copyFromPackedArray(&packed_array);
    
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), unpacked.re[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), unpacked.re[common.kFftLengthBy2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), unpacked.re[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), unpacked.im[1], 0.001);
}

test "FftData operations" {
    var a: FftData = undefined;
    var b: FftData = undefined;
    
    a.clear();
    b.clear();
    
    // 填充测试数据
    for (0..common.kFftLengthBy2Plus1) |k| {
        a.re[k] = @floatFromInt(k);
        a.im[k] = @floatFromInt(k);
        b.re[k] = @floatFromInt(k + 1);
        b.im[k] = @floatFromInt(k + 1);
    }
    
    // 测试加法
    var c = a;
    c.addAssign(&b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.re[0], 0.001); // 0 + 1
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), c.re[1], 0.001); // 1 + 2
    
    // 测试减法
    var d = a;
    d.subAssign(&b);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), d.re[0], 0.001); // 0 - 1
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), d.re[1], 0.001); // 1 - 2
    
    // 测试缩放
    var e = a;
    e.scale(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), e.re[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), e.re[1], 0.001);
}
