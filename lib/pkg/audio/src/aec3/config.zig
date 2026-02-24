//! WebRTC AEC3 配置结构 (简化版)
//! 基于 /tmp/AEC3/api/echo_canceller3_config.h

const std = @import("std");

pub const Config = struct {
    pub const Filter = struct {
        /// 主滤波器分区数 (默认 13)
        main_length_blocks: usize = 13,
        /// 主滤波器收敛泄漏因子
        main_leakage_converged: f32 = 0.00005,
        /// 主滤波器发散泄漏因子
        main_leakage_diverged: f32 = 0.05,
        /// 误差下限
        main_error_floor: f32 = 0.001,
        /// 误差上限
        main_error_ceil: f32 = 2.0,
        /// 噪声门限
        main_noise_gate: f32 = 20075344.0,

        /// 阴影滤波器分区数 (默认 13)
        shadow_length_blocks: usize = 13,
        /// 阴影滤波器更新率
        shadow_rate: f32 = 0.7,
        /// 阴影滤波器噪声门限
        shadow_noise_gate: f32 = 20075344.0,

        /// 初始状态滤波器长度
        initial_length_blocks: usize = 12,
    };

    pub const Delay = struct {
        /// 默认延迟 (块数)
        default_delay: usize = 5,
        /// 下采样因子
        down_sampling_factor: usize = 4,
        /// 匹配滤波器数量
        num_filters: usize = 5,
        /// 延迟头部空间 (样本数)
        delay_headroom_samples: usize = 32,
        /// 延迟估计平滑因子
        delay_estimate_smoothing: f32 = 0.7,
    };

    pub const Erle = struct {
        /// 最小 ERLE
        min: f32 = 1.0,
        /// 低频最大 ERLE
        max_l: f32 = 4.0,
        /// 高频最大 ERLE
        max_h: f32 = 1.5,
        /// 起始检测
        onset_detection: bool = true,
    };

    pub const Suppressor = struct {
        /// 近端平均块数
        nearend_average_blocks: usize = 4,
        /// 低频透明阈值
        mask_lf_enr_transparent: f32 = 0.3,
        /// 低频抑制阈值
        mask_lf_enr_suppress: f32 = 0.4,
        /// 高频透明阈值
        mask_hf_enr_transparent: f32 = 0.07,
        /// 高频抑制阈值
        mask_hf_enr_suppress: f32 = 0.1,
    };

    /// 滤波器配置
    filter: Filter = .{},
    /// 延迟配置
    delay: Delay = .{},
    /// ERLE 配置
    erle: Erle = .{},
    /// 抑制器配置
    suppressor: Suppressor = .{},

    /// 采样率
    sample_rate_hz: i32 = 16000,
    /// 帧大小 (10ms = 160 样本 @ 16kHz)
    frame_size: usize = 160,
    /// 块大小 (4ms = 64 样本)
    block_size: usize = 64,
};

pub fn createDefaultConfig() Config {
    return .{};
}
