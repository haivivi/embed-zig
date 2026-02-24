//! AEC State — AEC 状态管理
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/aec_state.h
//!
//! 负责:
//! - 滤波器状态跟踪
//! - 收敛检测
//! - 质量指标计算

const std = @import("std");
const config_mod = @import("config.zig");

pub fn GenAecState(comptime Arith: type) type {
    return struct {
        const Self = @This();

        config: config_mod.Config,

        // 滤波器状态
        filter_converged: bool = false,
        filter_diverged: bool = false,
        initial_state: bool = true,

        // 能量统计
        nearend_energy: f32 = 0,
        echo_energy: f32 = 0,
        residual_echo_energy: f32 = 0,

        // ERLE 估计
        erle: f32 = 1.0,
        erle_unreliable: bool = false,

        // 计数器
        blocks_since_last_speech: usize = 0,
        num_blocks: usize = 0,

        const BLOCK_SIZE = 64;

        pub fn init(config: config_mod.Config) Self {
            return .{
                .config = config,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn update(
            self: *Self,
            capture: []const f32,
            linear_output: []const f32,
            render: []const f32,
        ) void {
            // 计算能量
            var capture_energy: f32 = 0;
            var linear_energy: f32 = 0;
            var render_energy: f32 = 0;

            for (capture) |s| {
                capture_energy += s * s;
            }
            for (linear_output) |s| {
                linear_energy += s * s;
            }
            for (render) |s| {
                render_energy += s * s;
            }

            self.nearend_energy = capture_energy;
            self.echo_energy = render_energy;
            self.residual_echo_energy = linear_energy;

            // 更新 ERLE
            if (linear_energy > 0 and capture_energy > 0) {
                self.erle = capture_energy / linear_energy;
            }

            // 检查收敛状态
            self.num_blocks += 1;
            if (self.num_blocks > 250) { // 1秒后
                self.initial_state = false;
            }

            // 检测远端语音
            if (render_energy < 100) {
                self.blocks_since_last_speech += 1;
            } else {
                self.blocks_since_last_speech = 0;
            }
        }

        pub fn getEchoReturnLoss(self: *Self) f32 {
            if (self.echo_energy > 0) {
                return self.nearend_energy / self.echo_energy;
            }
            return 1.0;
        }

        pub fn getEchoReturnLossEnhancement(self: *Self) f32 {
            return self.erle;
        }

        pub fn getResidualEchoReturnLoss(self: *Self) f32 {
            if (self.residual_echo_energy > 0) {
                return self.nearend_energy / self.residual_echo_energy;
            }
            return 1.0;
        }

        pub fn isConverged(self: *Self) bool {
            return self.filter_converged;
        }

        pub fn isDiverged(self: *Self) bool {
            return self.filter_diverged;
        }

        pub fn isInitialState(self: *Self) bool {
            return self.initial_state;
        }
    };
}

/// f32 版本
pub const AecStateF32 = GenAecState(struct {
    pub const Scalar = f32;
    pub const Complex = struct { re: f32, im: f32 };
    pub const is_fixed = false;
});

/// 默认版本
pub const AecState = AecStateF32;
