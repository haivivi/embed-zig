//! RTC Implementation for BK7258
//!
//! Implements hal.rtc Driver interfaces using AON RTC for uptime.

const armino = @import("../../armino/src/armino.zig");

/// RTC Reader — uptime from AON RTC, wall clock via sync
pub const RtcReaderDriver = struct {
    const Self = @This();

    epoch_offset: ?i64 = null,

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return armino.time.nowMs();
    }

    pub fn nowMs(self: *Self) ?i64 {
        if (self.epoch_offset) |offset| {
            return @as(i64, @intCast(armino.time.nowMs())) + offset;
        }
        return null;
    }

    pub fn sync(self: *Self, epoch_ms: i64) void {
        const now_ms: i64 = @intCast(armino.time.nowMs());
        self.epoch_offset = epoch_ms - now_ms;
    }
};

/// RTC Writer — sets wall clock via reader sync
pub const RtcWriterDriver = struct {
    const Self = @This();
    reader: *RtcReaderDriver,

    pub fn init(reader: *RtcReaderDriver) Self {
        return .{ .reader = reader };
    }

    pub fn setNowMs(self: *Self, epoch_ms: i64) !void {
        self.reader.sync(epoch_ms);
    }
};
