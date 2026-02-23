//! 频域自适应 FIR 滤波器
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/adaptive_fir_filter.h

const std = @import("std");
const common = @import("common.zig");
const fft_data = @import("fft_data.zig");
const aec3_fft = @import("aec3_fft.zig");

const FftData = fft_data.FftData;
const Aec3Fft = aec3_fft.Aec3Fft;

// ============================================================================
// 自适应 FIR 滤波器
// ============================================================================

pub const AdaptiveFirFilter = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    
    // FFT 实例 (用于约束滤波器)
    fft: Aec3Fft,
    
    // 滤波器系数 H[p][ch] 其中 p 是分区，ch 是通道
    // 每个分区包含一个完整的 FftData (频域表示)
    H: []FftData,
    
    // 最大分区数
    max_size_partitions: usize,
    
    // 当前分区数
    current_size_partitions: usize,
    
    // 目标分区数 (用于动态调整)
    target_size_partitions: usize,
    old_target_size_partitions: usize,
    
    // 分区数调整相关
    size_change_duration_blocks: usize,
    one_by_size_change_duration_blocks: f32,
    size_change_counter: i32 = 0,
    
    // 约束循环计数器
    partition_to_constrain: usize = 0,
    
    // 渲染通道数
    num_render_channels: usize,
    
    /// 创建自适应滤波器
    pub fn init(
        allocator: std.mem.Allocator,
        max_size_partitions: usize,
        initial_size_partitions: usize,
        size_change_duration_blocks: usize,
        num_render_channels: usize,
    ) !Self {
        std.debug.assert(initial_size_partitions <= max_size_partitions);
        
        // 分配滤波器系数内存
        // H 有 max_size_partitions 个 FftData
        const H = try allocator.alloc(FftData, max_size_partitions);
        
        // 初始化为零
        for (H) |*h| {
            h.clear();
        }
        
        return .{
            .allocator = allocator,
            .fft = Aec3Fft.init(),
            .H = H,
            .max_size_partitions = max_size_partitions,
            .current_size_partitions = initial_size_partitions,
            .target_size_partitions = initial_size_partitions,
            .old_target_size_partitions = initial_size_partitions,
            .size_change_duration_blocks = @intCast(size_change_duration_blocks),
            .one_by_size_change_duration_blocks = 1.0 / @as(f32, @floatFromInt(size_change_duration_blocks)),
            .num_render_channels = num_render_channels,
        };
    }
    
    /// 释放资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.H);
    }
    
    /// 滤波操作
    /// render_buffer: 渲染信号缓冲区 (包含多个分区的 FFT 数据)
    /// S: 输出频域结果 (频域滤波器输出)
    pub fn filter(
        self: *const Self,
        render_buffer: []const FftData,  // [num_partitions]FftData
        S: *FftData,
    ) void {
        S.clear();
        
        // 频域卷积: S = sum(H[p] * X[p])
        for (0..self.current_size_partitions) |p| {
            const h = &self.H[p];
            const x = &render_buffer[p];
            
            for (0..common.kFftLengthBy2Plus1) |k| {
                // 复数乘法: h * x
                const re = h.re[k] * x.re[k] - h.im[k] * x.im[k];
                const im = h.re[k] * x.im[k] + h.im[k] * x.re[k];
                S.re[k] += re;
                S.im[k] += im;
            }
        }
    }
    
    /// 自适应更新 (NLMS)
    /// render_buffer: 渲染信号缓冲区
    /// G: 频域误差 * 共轭(步长) (来自 update gain 计算)
    pub fn adapt(
        self: *Self,
        render_buffer: []const FftData,
        G: *const FftData,
    ) void {
        // 标准 NLMS 更新: H_new = H + G
        // 其中 G = step_size * conj(X) * E / (|X|^2 + epsilon)
        
        for (0..self.current_size_partitions) |p| {
            const x = &render_buffer[p];
            const h = &self.H[p];
            
            for (0..common.kFftLengthBy2Plus1) |k| {
                // G[k] 已经包含了 step_size / power
                // H[k] += conj(X[k]) * G[k] (这里 G 已经是处理过的)
                h.re[k] += x.re[k] * G.re[k] + x.im[k] * G.im[k];
                h.im[k] += x.re[k] * G.im[k] - x.im[k] * G.re[k];
            }
        }
        
        // 周期性约束 (每 N 次更新一次，这里简化为每次约束一个分区)
        self.constrainOnePartition();
        
        // 更新滤波器大小
        self.updateSize();
    }
    
    /// 自适应更新并更新冲激响应
    pub fn adaptAndUpdateImpulseResponse(
        self: *Self,
        render_buffer: []const FftData,
        G: *const FftData,
        impulse_response: []f32,
    ) void {
        self.adapt(render_buffer, G);
        self.constrainOnePartitionAndUpdate(impulse_response);
    }
    
    /// 设置滤波器大小
    pub fn setSizePartitions(self: *Self, size: usize, immediate_effect: bool) void {
        if (size > self.max_size_partitions) {
            return;
        }
        
        self.target_size_partitions = size;
        
        if (immediate_effect) {
            self.current_size_partitions = size;
            self.target_size_partitions = size;
            self.old_target_size_partitions = size;
            self.size_change_counter = 0;
            
            // 如果缩小，清零被移除的分区
            if (size < self.current_size_partitions) {
                for (size..self.current_size_partitions) |p| {
                    self.H[p].clear();
                }
            }
        }
    }
    
    /// 处理回声路径变化
    pub fn handleEchoPathChange(self: *Self) void {
        // 重置滤波器以快速适应新的回声路径
        // 保守策略: 逐步减小滤波器大小到初始值
        self.setSizePartitions(4, false);
        self.size_change_counter = 0;
    }
    
    /// 缩放滤波器
    pub fn scaleFilter(self: *Self, factor: f32) void {
        for (0..self.current_size_partitions) |p| {
            self.H[p].scale(factor);
        }
    }
    
    /// 计算滤波器频率响应
    pub fn computeFrequencyResponse(
        self: *const Self,
        H2: *[common.kFftLengthBy2Plus1]f32,
    ) void {
        @memset(H2, 0);
        
        for (0..self.current_size_partitions) |p| {
            for (0..common.kFftLengthBy2Plus1) |k| {
                H2[k] += self.H[p].re[k] * self.H[p].re[k]
                      + self.H[p].im[k] * self.H[p].im[k];
            }
        }
    }
    
    /// 获取最大滤波器大小
    pub fn maxFilterSizePartitions(self: *const Self) usize {
        return self.max_size_partitions;
    }
    
    /// 获取当前滤波器大小
    pub fn sizePartitions(self: *const Self) usize {
        return self.current_size_partitions;
    }
    
    /// 获取滤波器系数 (用于调试/测试)
    pub fn getFilter(self: *const Self) []const FftData {
        return self.H;
    }
    
    /// 设置滤波器系数 (用于测试/初始化)
    pub fn setFilter(self: *Self, num_partitions: usize, H: []const FftData) void {
        const n = @min(num_partitions, self.max_size_partitions);
        for (0..n) |p| {
            self.H[p].assign(&H[p]);
        }
        self.current_size_partitions = n;
    }
    
    // 内部方法: 约束一个分区
    fn constrainOnePartition(self: *Self) void {
        if (self.partition_to_constrain >= self.current_size_partitions) {
            self.partition_to_constrain = 0;
        }
        
        // 频域约束: 确保时域响应是因果的
        // 将 128 点频域数据转换为 128 点时域
        var temp_buffer: [common.kFftLength]f32 = undefined;
        self.H[self.partition_to_constrain].copyToPackedArray(&temp_buffer);
        
        // IFFT 得到时域响应
        var fft_data_mut: [common.kFftLength]f32 = undefined;
        @memcpy(&fft_data_mut, &temp_buffer);
        self.fft.ooura_fft_impl.inverseFft(&fft_data_mut);
        
        // 约束: 将后 64 点清零 (循环卷积 → 线性卷积)
        @memset(fft_data_mut[common.kFftLengthBy2..], 0);
        
        // 重新 FFT
        self.fft.ooura_fft_impl.fft(&fft_data_mut);
        self.H[self.partition_to_constrain].copyFromPackedArray(&fft_data_mut);
        
        // 更新约束计数器
        self.partition_to_constrain += 1;
        if (self.partition_to_constrain >= self.current_size_partitions) {
            self.partition_to_constrain = 0;
        }
    }
    
    // 内部方法: 约束并更新冲激响应
    fn constrainOnePartitionAndUpdate(self: *Self, impulse_response: []f32) void {
        if (self.partition_to_constrain >= self.current_size_partitions) {
            self.partition_to_constrain = 0;
        }
        
        const p = self.partition_to_constrain;
        
        // 频域约束
        var temp_buffer: [common.kFftLength]f32 = undefined;
        self.H[p].copyToPackedArray(&temp_buffer);
        
        var fft_data_mut: [common.kFftLength]f32 = undefined;
        @memcpy(&fft_data_mut, &temp_buffer);
        self.fft.ooura_fft_impl.inverseFft(&fft_data_mut);
        
        // 更新冲激响应 (前 64 点)
        const offset = p * common.kFftLengthBy2;
        if (offset + common.kFftLengthBy2 <= impulse_response.len) {
            for (0..common.kFftLengthBy2) |i| {
                impulse_response[offset + i] = fft_data_mut[i];
            }
        }
        
        // 约束
        @memset(fft_data_mut[common.kFftLengthBy2..], 0);
        
        // 重新 FFT
        self.fft.ooura_fft_impl.fft(&fft_data_mut);
        self.H[p].copyFromPackedArray(&fft_data_mut);
        
        // 更新计数器
        self.partition_to_constrain += 1;
        if (self.partition_to_constrain >= self.current_size_partitions) {
            self.partition_to_constrain = 0;
        }
    }
    
    // 内部方法: 更新滤波器大小
    fn updateSize(self: *Self) void {
        if (self.target_size_partitions == self.current_size_partitions) {
            return;
        }
        
        if (self.target_size_partitions != self.old_target_size_partitions) {
            // 目标改变，重新开始调整
            self.size_change_counter = self.size_change_duration_blocks;
            self.old_target_size_partitions = self.target_size_partitions;
        }
        
        if (self.size_change_counter > 0) {
            self.size_change_counter -= 1;
            
            // 逐步调整大小
            if (self.target_size_partitions > self.current_size_partitions) {
                self.current_size_partitions += 1;
            } else if (self.target_size_partitions < self.current_size_partitions) {
                // 缩小: 清零被移除的分区
                self.current_size_partitions -= 1;
                self.H[self.current_size_partitions].clear();
            }
        } else {
            // 完成调整
            self.current_size_partitions = self.target_size_partitions;
        }
    }
};

// ============================================================================
// 辅助函数
// ============================================================================

/// 计算频域滤波器输出 (独立函数)
pub fn applyFilter(
    render_buffer: []const FftData,
    num_partitions: usize,
    H: []const FftData,
    S: *FftData,
) void {
    S.clear();
    
    const n = @min(num_partitions, render_buffer.len, H.len);
    
    for (0..n) |p| {
        const h = &H[p];
        const x = &render_buffer[p];
        
        for (0..common.kFftLengthBy2Plus1) |k| {
            const re = h.re[k] * x.re[k] - h.im[k] * x.im[k];
            const im = h.re[k] * x.im[k] + h.im[k] * x.re[k];
            S.re[k] += re;
            S.im[k] += im;
        }
    }
}

/// 自适应更新分区
pub fn adaptPartitions(
    render_buffer: []const FftData,
    G: *const FftData,
    num_partitions: usize,
    H: []FftData,
) void {
    const n = @min(num_partitions, render_buffer.len, H.len);
    
    for (0..n) |p| {
        const x = &render_buffer[p];
        const h = &H[p];
        
        for (0..common.kFftLengthBy2Plus1) |k| {
            // 复数乘法: conj(X) * G
            h.re[k] += x.re[k] * G.re[k] + x.im[k] * G.im[k];
            h.im[k] += x.re[k] * G.im[k] - x.im[k] * G.re[k];
        }
    }
}

/// 计算频率响应
pub fn computeFrequencyResponseForFilter(
    num_partitions: usize,
    H: []const FftData,
    H2: *[common.kFftLengthBy2Plus1]f32,
) void {
    @memset(H2, 0);
    
    const n = @min(num_partitions, H.len);
    
    for (0..n) |p| {
        for (0..common.kFftLengthBy2Plus1) |k| {
            H2[k] += H[p].re[k] * H[p].re[k] + H[p].im[k] * H[p].im[k];
        }
    }
}

// ============================================================================
// 测试
// ============================================================================

test "AdaptiveFirFilter init/deinit" {
    const allocator = std.testing.allocator;
    
    var filter = try AdaptiveFirFilter.init(
        allocator,
        32,  // max partitions
        12,  // initial
        10,  // change duration
        1,   // channels
    );
    defer filter.deinit();
    
    try std.testing.expectEqual(@as(usize, 12), filter.sizePartitions());
    try std.testing.expectEqual(@as(usize, 32), filter.maxFilterSizePartitions());
}

test "AdaptiveFirFilter filter operation" {
    const allocator = std.testing.allocator;
    
    var filter = try AdaptiveFirFilter.init(
        allocator,
        8,
        4,
        10,
        1,
    );
    defer filter.deinit();
    
    // 创建模拟渲染缓冲区
    var render_buffer: [4]FftData = undefined;
    for (&render_buffer) |*r| {
        r.clear();
    }
    // 设置一些非零值
    render_buffer[0].re[0] = 1.0;
    
    // 执行滤波
    var S: FftData = undefined;
    S.clear();
    filter.filter(&render_buffer, &S);
    
    // 由于滤波器初始化为零，输出应该为零
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), S.re[0], 0.001);
}

test "AdaptiveFirFilter set and get size" {
    const allocator = std.testing.allocator;
    
    var filter = try AdaptiveFirFilter.init(
        allocator,
        32,
        12,
        10,
        1,
    );
    defer filter.deinit();
    
    try std.testing.expectEqual(@as(usize, 12), filter.sizePartitions());
    
    // 立即改变大小
    filter.setSizePartitions(8, true);
    try std.testing.expectEqual(@as(usize, 8), filter.sizePartitions());
    
    // 设置超过最大大小的应该被忽略
    filter.setSizePartitions(50, true);
    try std.testing.expectEqual(@as(usize, 8), filter.sizePartitions());
}

test "AdaptiveFirFilter scale" {
    const allocator = std.testing.allocator;
    
    var filter = try AdaptiveFirFilter.init(
        allocator,
        8,
        4,
        10,
        1,
    );
    defer filter.deinit();
    
    // 设置滤波器值
    filter.H[0].re[0] = 1.0;
    filter.H[0].im[0] = 2.0;
    
    // 缩放
    filter.scaleFilter(2.0);
    
    // 验证
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), filter.H[0].re[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), filter.H[0].im[0], 0.001);
}

test "AdaptiveFirFilter computeFrequencyResponse" {
    const allocator = std.testing.allocator;
    
    var filter = try AdaptiveFirFilter.init(
        allocator,
        4,
        2,
        10,
        1,
    );
    defer filter.deinit();
    
    // 设置滤波器值
    filter.H[0].re[0] = 1.0;
    filter.H[0].im[0] = 0.0;
    filter.H[1].re[0] = 2.0;
    filter.H[1].im[0] = 0.0;
    
    // 计算频率响应
    var H2: [common.kFftLengthBy2Plus1]f32 = undefined;
    filter.computeFrequencyResponse(&H2);
    
    // |H|^2 = 1^2 + 2^2 = 5
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), H2[0], 0.001);
}

test "computeFrequencyResponseForFilter" {
    var H: [4]FftData = undefined;
    for (&H) |*h| {
        h.clear();
    }
    H[0].re[0] = 1.0;
    H[1].re[0] = 2.0;
    
    var H2: [common.kFftLengthBy2Plus1]f32 = undefined;
    computeFrequencyResponseForFilter(2, &H, &H2);
    
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), H2[0], 0.001);
}

test "applyFilter" {
    var render_buffer: [4]FftData = undefined;
    for (&render_buffer) |*r| {
        r.clear();
    }
    
    // X[0][0] = 1
    render_buffer[0].re[0] = 1.0;
    
    var H: [4]FftData = undefined;
    for (&H) |*h| {
        h.clear();
    }
    // H[0][0] = 2
    H[0].re[0] = 2.0;
    
    var S: FftData = undefined;
    S.clear();
    
    applyFilter(&render_buffer, 2, &H, &S);
    
    // S[0] = H[0] * X[0] = 2 * 1 = 2
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), S.re[0], 0.001);
}
