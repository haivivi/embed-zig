//! RTC Implementation for ESP32
//!
//! Implements hal.rtc Driver interfaces.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const rtc_reader_spec = struct {
//!       pub const Driver = impl.RtcReaderDriver;
//!       pub const meta = .{ .id = "rtc.reader" };
//!   };
//!   const RtcReader = hal.rtc.reader.from(rtc_reader_spec);

const idf = @import("idf");

/// RTC Reader Driver using esp_timer for uptime
pub const RtcReaderDriver = struct {
    const Self = @This();

    /// Wall clock epoch offset (set via NTP or other source)
    epoch_offset: ?i64 = null,

    pub fn init() Self {
        return .{};
    }

    /// Get monotonic uptime in milliseconds (required by hal.rtc.reader)
    pub fn uptime(self: *Self) u64 {
        _ = self;
        return idf.time.nowMs();
    }

    /// Get wall clock time in epoch milliseconds (required by hal.rtc.reader)
    /// Returns null if time not synchronized
    pub fn nowMs(self: *Self) ?i64 {
        if (self.epoch_offset) |offset| {
            return @as(i64, @intCast(idf.time.nowMs())) + offset;
        }
        return null;
    }

    /// Sync wall clock with epoch time
    pub fn sync(self: *Self, epoch_ms: i64) void {
        const now_ms: i64 = @intCast(idf.time.nowMs());
        self.epoch_offset = epoch_ms - now_ms;
    }
};

/// RTC Writer Driver
pub const RtcWriterDriver = struct {
    const Self = @This();

    reader: *RtcReaderDriver,

    pub fn init(reader: *RtcReaderDriver) Self {
        return .{ .reader = reader };
    }

    /// Set wall clock time (required by hal.rtc.writer)
    pub fn setNowMs(self: *Self, epoch_ms: i64) !void {
        self.reader.sync(epoch_ms);
    }
};
