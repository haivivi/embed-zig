//! Block Processor — 块处理器
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/block_processor.h
//!
//! 负责:
//! - 协调 EchoRemover 进行回声消除
//! - 管理渲染缓冲
//! - 管理延迟控制器

const std = @import("std");
const config_mod = @import("config.zig");

pub fn GenBlockProcessor(comptime Arith: type) type {
    return struct {
        const Self = @This();

        config: config_mod.Config,
        sample_rate: i32,
        num_render_channels: usize,
        num_capture_channels: usize,

        render_buffer: []f32,
        render_pos: usize,

        delay_estimate: i32 = 0,

        allocator: std.mem.Allocator,

        const BLOCK_SIZE = 64;

        pub fn init(allocator: std.mem.Allocator, config: config_mod.Config, sample_rate: i32, num_render_channels: usize, num_capture_channels: usize) !Self {
            const buffer_size = config.delay.default_delay * BLOCK_SIZE + 160 * 4;
            const render_buffer = try allocator.alloc(f32, buffer_size);
            @memset(render_buffer, 0);

            return .{
                .config = config,
                .sample_rate = sample_rate,
                .num_render_channels = num_render_channels,
                .num_capture_channels = num_capture_channels,
                .render_buffer = render_buffer,
                .render_pos = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.render_buffer);
        }

        pub fn bufferRender(self: *Self, render: []const f32) void {
            const buf_len = self.render_buffer.len;
            for (render) |s| {
                self.render_buffer[self.render_pos % buf_len] = s;
                self.render_pos += 1;
            }
        }

        pub fn processCapture(
            self: *Self,
            echo_path_gain_change: bool,
            capture_signal_saturation: bool,
            linear_output: ?[]f32,
            capture: []f32,
        ) void {
            _ = echo_path_gain_change;
            _ = capture_signal_saturation;
            _ = linear_output;

            // 简化版：直接传递捕获数据
            // 完整版需要调用 EchoRemover
            _ = self;
            _ = capture;
        }

        pub fn setAudioBufferDelay(self: *Self, delay_ms: i32) void {
            // 将延迟转换为样本数
            self.delay_estimate = (delay_ms * self.sample_rate) / 1000;
        }

        pub fn updateEchoLeakageStatus(self: *Self, leakage_detected: bool) void {
            _ = self;
            _ = leakage_detected;
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
    };
}

/// f32 版本
pub const BlockProcessorF32 = GenBlockProcessor(struct {
    pub const Scalar = f32;
    pub const Complex = struct { re: f32, im: f32 };
    pub const is_fixed = false;
});

/// 默认版本
pub const BlockProcessor = BlockProcessorF32;
