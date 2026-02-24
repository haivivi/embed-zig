//! Moving Average — 滑动平均
//! 用于平滑各种统计量

const std = @import("std");

pub fn MovingAverage(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        buffer_pos: usize,
        buffer_len: usize,
        sum: T,

        pub fn init(allocator: std.mem.Allocator, window_size: usize) !Self {
            const buffer = try allocator.alloc(T, window_size);
            @memset(buffer, 0);

            return .{
                .buffer = buffer,
                .buffer_pos = 0,
                .buffer_len = window_size,
                .sum = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn update(self: *Self, value: T) T {
            // 减去即将离开的值
            self.sum -= self.buffer[self.buffer_pos];
            // 添加新值
            self.sum += value;
            self.buffer[self.buffer_pos] = value;
            // 移动指针
            self.buffer_pos = (self.buffer_pos + 1) % self.buffer_len;

            return self.sum / @as(T, @intCast(self.buffer_len));
        }

        pub fn getAverage(self: *Self) T {
            return self.sum / @as(T, @intCast(self.buffer_len));
        }

        pub fn reset(self: *Self) void {
            @memset(self.buffer, 0);
            self.buffer_pos = 0;
            self.sum = 0;
        }
    };
}

/// f32 版本
pub const MovingAverageF32 = MovingAverage(f32);

/// i32 版本
pub const MovingAverageI32 = MovingAverage(i32);
