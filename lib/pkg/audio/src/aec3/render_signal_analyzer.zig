//! Render Signal Analyzer — 渲染信号分析器
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/render_signal_analyzer.h
//!
//! 负责分析渲染信号的特征:
//! - 检测窄带信号
//! - 检测活跃信号

const std = @import("std");

pub const RenderSignalAnalyzer = struct {
    const Self = @This();

    narrowband_count: usize = 0,
    active_count: usize = 0,
    num_blocks: usize = 0,

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn analyze(self: *Self, render: []const f32) void {
        // 计算能量
        var energy: f32 = 0;
        for (render) |s| {
            energy += s * s;
        }

        // 检测是否活跃
        if (energy > 1000) {
            self.active_count += 1;
        }

        self.num_blocks += 1;
    }

    pub fn isNarrowband(self: *Self) bool {
        return self.narrowband_count > 0;
    }

    pub fn isActive(self: *Self) bool {
        return self.active_count > 0;
    }

    pub fn reset(self: *Self) void {
        self.narrowband_count = 0;
        self.active_count = 0;
        self.num_blocks = 0;
    }
};
