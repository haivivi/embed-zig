//! Matched Filter — 匹配滤波器
//! 1:1 对应 /tmp/AEC3/audio_processing/aec3/matched_filter.h
//!
//! 用于延迟估计的匹配滤波器

const std = @import("std");

pub const MatchedFilter = struct {
    const Self = @This();

    buffer: []f32,
    buffer_pos: usize,
    buffer_size: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize) !Self {
        const buffer = try allocator.alloc(f32, buffer_size);
        @memset(buffer, 0);

        return .{
            .buffer = buffer,
            .buffer_pos = 0,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn push(self: *Self, block: []const f32) void {
        for (block) |s| {
            self.buffer[self.buffer_pos] = s;
            self.buffer_pos = (self.buffer_pos + 1) % self.buffer_size;
        }
    }

    pub fn correlate(self: *Self, target: []const f32) f32 {
        var correlation: f32 = 0;

        for (target, 0..) |t, i| {
            const idx = (self.buffer_pos + self.buffer_size - target.len + i) % self.buffer_size;
            correlation += t * self.buffer[idx];
        }

        return correlation;
    }
};
