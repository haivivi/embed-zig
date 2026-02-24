//! Echo Remover — 回声消除核心
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/echo_remover.h
//!
//! 负责:
//! - 线性回声消除 (Subtractor)
//! - 非线性抑制 (Suppression Gain)
//! - 状态管理 (AecState)

const std = @import("std");
const config_mod = @import("config.zig");

pub const EchoPathVariability = struct {
    change: enum { kNone, kNew, kDiverge, kReset },
    gain: f32 = 1.0,
};

pub const DelayEstimate = struct {
    delay: i32 = 0,
    quality: f32 = 0,
};

pub fn GenEchoRemover(comptime Arith: type) type {
    return struct {
        const Self = @This();

        config: config_mod.Config,
        sample_rate: i32,

        pub fn init(allocator: std.mem.Allocator, config: config_mod.Config, sample_rate: i32, num_render_channels: usize, num_capture_channels: usize) !Self {
            _ = allocator;
            _ = num_render_channels;
            _ = num_capture_channels;
            return .{
                .config = config,
                .sample_rate = sample_rate,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn processCapture(
            self: *Self,
            echo_path_variability: EchoPathVariability,
            capture_signal_saturation: bool,
            external_delay: ?DelayEstimate,
            render_buffer: anytype,
            linear_output: ?[]f32,
            capture: []f32,
        ) void {
            _ = echo_path_variability;
            _ = capture_signal_saturation;
            _ = external_delay;
            _ = render_buffer;
            _ = linear_output;
            _ = self;

            // 简化版：直接传递捕获数据
            // 完整版需要调用 Subtractor + SuppressionGain
            for (capture) |*s| {
                s.* = s.*;
            }
        }

        pub fn getMetrics(self: *Self) struct {
            echo_return_loss: f32,
            echo_return_loss_enhancement: f32,
            residual_echo_return_loss: f32,
        } {
            _ = self;
            return .{
                .echo_return_loss = 0,
                .echo_return_loss_enhancement = 0,
                .residual_echo_return_loss = 0,
            };
        }

        pub fn updateEchoLeakageStatus(self: *Self, leakage_detected: bool) void {
            _ = self;
            _ = leakage_detected;
        }
    };
}

/// f32 版本
pub const EchoRemoverF32 = GenEchoRemover(struct {
    pub const Scalar = f32;
    pub const Complex = struct { re: f32, im: f32 };
    pub const is_fixed = false;
});

/// 默认版本
pub const EchoRemover = EchoRemoverF32;
