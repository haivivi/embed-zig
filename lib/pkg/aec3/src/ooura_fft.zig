//! Ooura FFT 实现 - Zig 移植
//! 原始 C 代码: http://www.kurims.kyoto-u.ac.jp/~ooura/fft.html
//!
//! 这是针对 128 点实数 FFT 的专用实现

const std = @import("std");
const common = @import("common.zig");

// ============================================================================
// 内部常量
// ============================================================================

/// FFT 长度
const N: usize = common.kFftLength; // 128
const NBY2: usize = common.kFftLengthBy2; // 64

/// 正弦/余弦表 (预计算)
/// 使用静态数据避免运行时计算
const sintbl: [N + NBY4]f32 = initSintbl();

/// C 代码中的 sintbl 大小
const NBY4: usize = N / 4; // 32

/// 初始化正弦表 (编译期计算)
fn initSintbl() [N + NBY4]f32 {
    var tbl: [N + NBY4]f32 = undefined;
    for (0..N + NBY4) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, N);
        tbl[i] = @sin(angle);
    }
    return tbl;
}

// ============================================================================
// 核心 FFT 函数
// ============================================================================

/// 128 点实数 FFT
/// 输入/输出格式: [0], [1], [2], ..., [127] (实数时间域)
/// 输出格式: [re[0]], [re[64]], [re[1]], [im[1]], ..., [re[63]], [im[63]]
pub fn rdft(a: *[N]f32) void {
    // 首先进行复数 FFT
    cdft(a);
    
    // 后处理: 将复数 FFT 输出转换为实数 FFT 输出
    // 这是 RDft 的最后阶段
    const wpi: f32 = -@sin(2.0 * std.math.pi / @as(f32, N));
    const wpr: f32 = -@cos(2.0 * std.math.pi / @as(f32, N));
    var wr: f32 = 1.0;
    var wi: f32 = 0.0;
    
    var m1: usize = NBY2 - 1;
    var m2: usize = NBY2 + 1;
    
    while (m1 >= 1) : ({
        m1 -= 1;
        m2 += 1;
    }) {
        const j1 = m1 + m1;
        const j2 = j1 + 1;
        const j3 = m2 + m2;
        const j4 = j3 + 1;
        
        const a1 = a[j1];
        const a2 = a[j2];
        const a3 = a[j3];
        const a4 = a[j4];
        
        a[j1] = a1 + a3;
        a[j2] = a2 - a4;
        a[j3] = wr * (a2 + a4) - wi * (a1 - a3);
        a[j4] = wr * (a1 - a3) + wi * (a2 + a4);
        
        const wtemp = wr;
        wr = wr * wpr - wi * wpi;
        wi = wi * wpr + wtemp * wpi;
    }
    
    // 处理 DC 和 Nyquist
    const x = a[0];
    const y = a[1];
    a[0] = x + y;
    a[1] = x - y;
}

/// 128 点逆实数 FFT
pub fn irdft(a: *[N]f32) void {
    // 前处理: 将实数 FFT 输入转换为复数 FFT 输入
    a[0] *= 0.5;
    a[1] *= 0.5;
    
    const wpi: f32 = @sin(2.0 * std.math.pi / @as(f32, N));
    const wpr: f32 = @cos(2.0 * std.math.pi / @as(f32, N));
    var wr: f32 = 1.0;
    var wi: f32 = 0.0;
    
    var m1: usize = NBY2 - 1;
    var m2: usize = NBY2 + 1;
    
    while (m1 >= 1) : ({
        m1 -= 1;
        m2 += 1;
    }) {
        const j1 = m1 + m1;
        const j2 = j1 + 1;
        const j3 = m2 + m2;
        const j4 = j3 + 1;
        
        const a1 = a[j1] - a[j3];
        const a2 = a[j2] + a[j4];
        _ = a[j1] + a[j3]; // a3 - not used in this implementation
        _ = a[j4] - a[j2]; // a4 - not used in this implementation
        
        a[j1] = 0.5 * a1;
        a[j2] = 0.5 * a2;
        a[j3] = 0.5 * (wr * a2 + wi * a1);
        a[j4] = 0.5 * (wr * a1 - wi * a2);
        
        const wtemp = wr;
        wr = wr * wpr - wi * wpi;
        wi = wi * wpr + wtemp * wpi;
    }
    
    // 逆复数 FFT
    icdft(a);
    
    // 缩放
    const scale: f32 = 2.0 / @as(f32, N);
    for (0..N) |i| {
        a[i] *= scale;
    }
}

/// 复数 FFT (内部使用)
fn cdft(a: *[N]f32) void {
    // 位反转置换
    bitrv2(a);
    
    // 蝴蝶运算
    var w: usize = NBY2;
    var m: usize = 1;
    var p: usize = 0;
    
    while (w >= 2) : ({
        w = w >> 1;
        m = m << 1;
        p = p + 1;
    }) {
        var j1: usize = 0;
        var j2: usize = m;
        
        while (j2 < N) : ({
            j1 = j2;
            j2 = j1 + m;
        }) {
            var i: usize = 0;
            while (i < w) : (i += 1) {
                const j = j1 + i;
                const k = j2 + i;
                const j3 = i << @intCast(p + 1);
                
                const xr = a[j];
                const xi = a[j + 1];
                const yr = a[k];
                const yi = a[k + 1];
                
                const c = sintbl[NBY4 + j3];
                const s = sintbl[j3];
                
                a[j] = xr + yr;
                a[j + 1] = xi + yi;
                a[k] = c * (xr - yr) - s * (xi - yi);
                a[k + 1] = s * (xr - yr) + c * (xi - yi);
            }
        }
    }
}

/// 逆复数 FFT (内部使用)
fn icdft(a: *[N]f32) void {
    // 类似 cdft，但使用共轭
    // 简化为 cdft + 共轭
    
    // 先共轭
    for (0..N) |i| {
        if (i % 2 == 1) {
            a[i] = -a[i];
        }
    }
    
    cdft(a);
    
    // 再共轭
    for (0..N) |i| {
        if (i % 2 == 1) {
            a[i] = -a[i];
        }
    }
}

/// 位反转置换
fn bitrv2(a: *[N]f32) void {
    var j: usize = 0;
    for (0..N - 1) |i| {
        if (i < j) {
            // 交换 a[i] 和 a[j]
            const temp = a[i];
            a[i] = a[j];
            a[j] = temp;
        }
        
        // 位反转递增
        var k: usize = N >> 1;
        while (k <= j) : (k = k >> 1) {
            j -= k;
        }
        j += k;
    }
}

// ============================================================================
// 公共 API (Aec3Fft 包装)
// ============================================================================

/// AEC3 专用的 FFT 包装器
/// 提供 AEC3 需要的特定功能
pub const Aec3OouraFft = struct {
    const Self = @This();
    
    /// 执行 128 点实数 FFT
    /// 输入: 128 个实数样本
    /// 输出: [re[0], re[64], re[1], im[1], ..., re[63], im[63]]
    pub fn fft(_: Self, a: *[N]f32) void {
        rdft(a);
    }
    
    /// 执行 128 点逆实数 FFT
    /// 输入: [re[0], re[64], re[1], im[1], ..., re[63], im[63]]
    /// 输出: 128 个实数样本
    pub fn inverseFft(_: Self, a: *[N]f32) void {
        irdft(a);
    }
};

// ============================================================================
// 测试
// ============================================================================

test "Ooura FFT - impulse response" {
    // 测试冲激响应
    var input: [N]f32 = undefined;
    @memset(&input, 0);
    input[0] = 1.0; // 冲激信号
    
    var fft_impl = Aec3OouraFft{};
    fft_impl.fft(&input);
    
    // 冲激信号的 FFT 应该全是 1 (实部)
    // 输出格式: [re[0], re[64], re[1], im[1], ...]
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), input[0], 0.001); // DC
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), input[1], 0.001); // Nyquist
    
    // re[1..63] 应该接近 1, im[1..63] 应该接近 0
    for (1..NBY2) |k| {
        const re_idx = k * 2;
        const im_idx = k * 2 + 1;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), input[re_idx], 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), input[im_idx], 0.01);
    }
}

test "Ooura FFT - roundtrip" {
    var original: [N]f32 = undefined;
    var fft_buf: [N]f32 = undefined;
    
    // 生成测试信号 (正弦波)
    for (0..N) |i| {
        const freq: f32 = 5.0; // 5 Hz (相对于采样率)
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, N);
        original[i] = @sin(2.0 * std.math.pi * freq * t);
        fft_buf[i] = original[i];
    }
    
    var fft_impl = Aec3OouraFft{};
    
    // FFT
    fft_impl.fft(&fft_buf);
    
    // IFFT
    fft_impl.inverseFft(&fft_buf);
    
    // 验证 roundtrip
    var max_diff: f32 = 0;
    for (0..N) |i| {
        const diff = @abs(fft_buf[i] - original[i]);
        max_diff = @max(max_diff, diff);
    }
    
    // 允许一定的数值误差
    try std.testing.expect(max_diff < 0.0001);
}

test "Ooura FFT - dc signal" {
    var input: [N]f32 = undefined;
    @memset(&input, 2.5); // DC 信号 2.5
    
    var fft_impl = Aec3OouraFft{};
    fft_impl.fft(&input);
    
    // DC 分量 = 2.5 * N = 320
    try std.testing.expectApproxEqAbs(@as(f32, 320.0), input[0], 0.1);
    
    // 其他分量应该为 0
    for (1..N) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), input[i], 0.01);
    }
}
