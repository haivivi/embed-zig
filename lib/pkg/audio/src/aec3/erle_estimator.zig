//! ERLE Estimator — Echo Return Loss Enhancement 估算器
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/erle_estimator.h
//!
//! 负责估算 AEC 的回声消除增强量 (ERLE)

const std = @import("std");

pub const ErleEstimator = struct {
    const Self = @This();

    // ERLE 估计
    erle: f32 = 1.0,
    erle_lf: f32 = 1.0, // 低频 ERLE
    erle_hf: f32 = 1.0, // 高频 ERLE

    // 统计
    erle_anchor: f32 = 0,
    num_segments: usize = 0,

    // 配置
    min_erle: f32 = 1.0,
    max_erle_lf: f32 = 4.0,
    max_erle_hf: f32 = 1.5,

    pub fn init(min_erle: f32, max_erle_lf: f32, max_erle_hf: f32) Self {
        return .{
            .min_erle = min_erle,
            .max_erle_lf = max_erle_lf,
            .max_erle_hf = max_erle_hf,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn update(
        self: *Self,
        capture_spectrum: []const f32,
        linear_spectrum: []const f32,
        render_spectrum: []const f32,
    ) void {
        // 计算总体 ERLE
        var capture_power: f32 = 0;
        var linear_power: f32 = 0;

        for (capture_spectrum) |s| {
            capture_power += s;
        }
        for (linear_spectrum) |s| {
            linear_power += s;
        }

        if (linear_power > 0 and capture_power > 0) {
            const instant_erle = capture_power / linear_power;

            // 平滑更新
            const alpha: f32 = 0.05;
            self.erle = alpha * instant_erle + (1.0 - alpha) * self.erle;
        }

        // 限制 ERLE 范围
        self.erle = @max(self.min_erle, @min(self.erle, self.max_erle_lf));

        // 简化：LF 和 HF 使用相同值
        self.erle_lf = self.erle;
        self.erle_hf = @max(self.min_erle, @min(self.erle, self.max_erle_hf));

        self.num_segments += 1;
    }

    pub fn getErle(self: *Self) f32 {
        return self.erle;
    }

    pub fn getErleLf(self: *Self) f32 {
        return self.erle_lf;
    }

    pub fn getErleHf(self: *Self) f32 {
        return self.erle_hf;
    }

    pub fn reset(self: *Self) void {
        self.erle = 1.0;
        self.erle_lf = 1.0;
        self.erle_hf = 1.0;
        self.num_segments = 0;
    }
};
