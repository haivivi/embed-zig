//! Subtractor — 自适应滤波器管理
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/subtractor.h
//!
//! 负责:
//! - 主滤波器 (Main Filter): 主要的回声消除
//! - 阴影滤波器 (Shadow Filter): 快速收敛
//! - 滤波器更新增益计算

const std = @import("std");
const config_mod = @import("config.zig");
const adaptive_filter_mod = @import("adaptive_filter.zig");

pub const SubtractorOutput = struct {
    main_output: []f32,
    shadow_output: []f32,
    main_error: []f32,
    shadow_error: []f32,
};

pub fn GenSubtractor(comptime Arith: type) type {
    return struct {
        const Self = @This();

        config: config_mod.Config,
        num_capture_channels: usize,

        main_filters: []adaptive_filter_mod.GenAdaptiveFilter(Arith),
        shadow_filters: []adaptive_filter_mod.GenAdaptiveFilter(Arith),

        allocator: std.mem.Allocator,

        const BLOCK_SIZE = 64;

        pub fn init(allocator: std.mem.Allocator, config: config_mod.Config, num_render_channels: usize, num_capture_channels: usize) !Self {
            const main_filters = try allocator.alloc(adaptive_filter_mod.GenAdaptiveFilter(Arith), num_capture_channels);
            errdefer allocator.free(main_filters);

            const shadow_filters = try allocator.alloc(adaptive_filter_mod.GenAdaptiveFilter(Arith), num_capture_channels);
            errdefer allocator.free(shadow_filters);

            for (0..num_capture_channels) |ch| {
                main_filters[ch] = try adaptive_filter_mod.GenAdaptiveFilter(Arith).init(allocator, .{
                    .block_size = BLOCK_SIZE,
                    .num_partitions = config.filter.main_length_blocks,
                    .step_size = 0.5,
                    .regularization = 100.0,
                });

                shadow_filters[ch] = try adaptive_filter_mod.GenAdaptiveFilter(Arith).init(allocator, .{
                    .block_size = BLOCK_SIZE,
                    .num_partitions = config.filter.shadow_length_blocks,
                    .step_size = config.filter.shadow_rate,
                    .regularization = 100.0,
                });
            }

            return .{
                .config = config,
                .num_capture_channels = num_capture_channels,
                .main_filters = main_filters,
                .shadow_filters = shadow_filters,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.main_filters) |*f| f.deinit();
            for (self.shadow_filters) |*f| f.deinit();
            self.allocator.free(self.main_filters);
            self.allocator.free(self.shadow_filters);
        }

        pub fn process(
            self: *Self,
            render_buffer: anytype,
            capture: []f32,
            render_signal_analyzer: anytype,
            aec_state: anytype,
            outputs: []SubtractorOutput,
        ) void {
            _ = render_signal_analyzer;
            _ = aec_state;
            _ = render_buffer;

            // 简化版：对每个捕获通道应用自适应滤波
            for (0..self.num_capture_channels) |ch| {
                if (ch >= outputs.len) break;

                const ref = capture; // 简化：使用同一参考信号
                var filter_err: [BLOCK_SIZE]f32 = undefined;

                _ = self.main_filters[ch].process(ref, capture, &filter_err);
                _ = self.shadow_filters[ch].process(ref, capture, &filter_err);

                // 输出结果
                @memcpy(outputs[ch].main_output, capture);
                @memcpy(outputs[ch].main_error, &filter_err);
            }
        }

        pub fn handleEchoPathChange(self: *Self, echo_path_variability: anytype) void {
            _ = self;
            _ = echo_path_variability;
        }

        pub fn exitInitialState(self: *Self) void {
            _ = self;
        }
    };
}

/// f32 版本
pub const SubtractorF32 = GenSubtractor(struct {
    pub const Scalar = f32;
    pub const Complex = struct { re: f32, im: f32 };
    pub const is_fixed = false;
});

/// 默认版本
pub const Subtractor = SubtractorF32;
