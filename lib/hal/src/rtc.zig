//! HAL RTC (Real-Time Clock) Components
//!
//! Provides time-related abstractions:
//! - RtcReader: Read uptime and wall-clock time
//! - RtcWriter: Set wall-clock time
//!
//! ## Usage
//!
//! ```zig
//! // board.zig
//! pub const spec = struct {
//!     pub const rtc_reader = hal.RtcReader(hw.rtc_reader_spec);
//!     pub const rtc_writer = hal.RtcWriter(hw.rtc_writer_spec);
//! };
//!
//! // main.zig
//! const uptime = board.rtc_reader.uptime();  // always available
//! if (board.rtc_reader.now()) |time| {
//!     std.log.info("Time: {}", .{time.format()});
//! }
//! try board.rtc_writer.set(ntp_epoch);
//! ```

const std = @import("std");
const spec_mod = @import("spec.zig");

// ============================================================================
// Timestamp Type
// ============================================================================

/// Unix timestamp with formatting utilities
pub const Timestamp = struct {
    /// Unix epoch seconds
    epoch_secs: i64,

    /// Create from epoch seconds
    pub fn fromEpoch(epoch: i64) Timestamp {
        return .{ .epoch_secs = epoch };
    }

    /// Get current epoch seconds
    pub fn toEpoch(self: Timestamp) i64 {
        return self.epoch_secs;
    }

    /// Convert to datetime components
    pub fn toDatetime(self: Timestamp) Datetime {
        return Datetime.fromEpoch(self.epoch_secs);
    }

    /// Format as ISO 8601 string: "2026-01-26T12:34:56Z"
    pub fn format(self: Timestamp, buf: []u8) []const u8 {
        const dt = self.toDatetime();
        return dt.format(buf);
    }
};

/// Datetime components
pub const Datetime = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23
    minute: u8, // 0-59
    second: u8, // 0-59

    /// Convert from Unix epoch seconds
    pub fn fromEpoch(epoch: i64) Datetime {
        // Days since 1970-01-01
        var days = @divFloor(epoch, 86400);
        var secs = @mod(epoch, 86400);
        if (secs < 0) {
            secs += 86400;
            days -= 1;
        }

        const hour: u8 = @intCast(@divFloor(secs, 3600));
        secs = @mod(secs, 3600);
        const minute: u8 = @intCast(@divFloor(secs, 60));
        const second: u8 = @intCast(@mod(secs, 60));

        // Calculate year, month, day
        var year: i32 = 1970;
        while (true) {
            const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
            if (days < days_in_year) break;
            days -= days_in_year;
            year += 1;
        }

        const leap = isLeapYear(year);
        const month_days = if (leap) leap_month_days else normal_month_days;

        var month: u8 = 1;
        while (month <= 12) : (month += 1) {
            if (days < month_days[month - 1]) break;
            days -= month_days[month - 1];
        }

        return .{
            .year = @intCast(year),
            .month = month,
            .day = @intCast(days + 1),
            .hour = hour,
            .minute = minute,
            .second = second,
        };
    }

    /// Convert to Unix epoch seconds
    pub fn toEpoch(self: Datetime) i64 {
        var days: i64 = 0;

        // Years since 1970
        var y: i32 = 1970;
        while (y < self.year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }

        // Months
        const leap = isLeapYear(@intCast(self.year));
        const month_days = if (leap) leap_month_days else normal_month_days;
        var m: u8 = 1;
        while (m < self.month) : (m += 1) {
            days += month_days[m - 1];
        }

        // Days
        days += self.day - 1;

        // Convert to seconds
        return days * 86400 + @as(i64, self.hour) * 3600 + @as(i64, self.minute) * 60 + self.second;
    }

    /// Format as ISO 8601 string: "2026-01-26T12:34:56Z"
    pub fn format(self: Datetime, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
        }) catch "????-??-??T??:??:??Z";
    }

    fn isLeapYear(year: i32) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }

    const normal_month_days = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap_month_days = [12]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
};

// ============================================================================
// RtcReader - Read time
// ============================================================================

/// HAL marker for RtcReader type detection
const _RtcReaderMarker = struct {};

/// Check if a type is an RtcReader HAL component
pub fn isRtcReaderType(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _RtcReaderMarker;
}

/// RTC Reader HAL component
///
/// Provides:
/// - uptime(): Monotonic time since boot (always available)
/// - now(): Wall-clock time as Timestamp (may be null if not synced)
/// - read(): Raw epoch seconds (may be null)
pub fn RtcReader(comptime spec: type) type {
    // Verify spec at compile time
    spec_mod.verifyRtcReaderSpec(spec);

    const Driver = spec.Driver;

    return struct {
        const Self = @This();

        /// HAL type marker (private, for Board detection)
        pub const _hal_marker = _RtcReaderMarker;

        /// Driver type (for Board auto-init)
        pub const DriverType = Driver;

        /// Component metadata
        pub const meta = spec.meta;

        // Internal state
        driver: *Driver,

        /// Initialize with driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        /// Get monotonic uptime in milliseconds (always available)
        pub fn uptime(self: *Self) u64 {
            return self.driver.uptime();
        }

        /// Get current wall-clock time as Timestamp
        /// Returns null if time is not synchronized
        pub fn now(self: *Self) ?Timestamp {
            if (self.driver.read()) |epoch| {
                return Timestamp.fromEpoch(epoch);
            }
            return null;
        }

        /// Get raw epoch seconds
        /// Returns null if time is not synchronized
        pub fn read(self: *Self) ?i64 {
            return self.driver.read();
        }

        /// Check if wall-clock time is available
        pub fn isSynced(self: *Self) bool {
            return self.driver.read() != null;
        }
    };
}

// ============================================================================
// RtcWriter - Write time
// ============================================================================

/// HAL marker for RtcWriter type detection
const _RtcWriterMarker = struct {};

/// Check if a type is an RtcWriter HAL component
pub fn isRtcWriterType(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _RtcWriterMarker;
}

/// RTC Writer HAL component
///
/// Provides:
/// - set(epoch): Set wall-clock time from epoch seconds
/// - setDatetime(dt): Set wall-clock time from Datetime
pub fn RtcWriter(comptime spec: type) type {
    // Verify spec at compile time
    spec_mod.verifyRtcWriterSpec(spec);

    const Driver = spec.Driver;

    return struct {
        const Self = @This();

        /// HAL type marker (private, for Board detection)
        pub const _hal_marker = _RtcWriterMarker;

        /// Driver type (for Board auto-init)
        pub const DriverType = Driver;

        /// Component metadata
        pub const meta = spec.meta;

        // Internal state
        driver: *Driver,

        /// Initialize with driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        /// Set time from Unix epoch seconds
        pub fn set(self: *Self, epoch_secs: i64) !void {
            try self.driver.write(epoch_secs);
        }

        /// Set time from Timestamp
        pub fn setTimestamp(self: *Self, ts: Timestamp) !void {
            try self.driver.write(ts.epoch_secs);
        }

        /// Set time from Datetime
        pub fn setDatetime(self: *Self, dt: Datetime) !void {
            try self.driver.write(dt.toEpoch());
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Timestamp and Datetime conversion" {
    // 2026-01-26 11:34:56 UTC
    const epoch: i64 = 1769427296;
    const ts = Timestamp.fromEpoch(epoch);
    const dt = ts.toDatetime();

    try std.testing.expectEqual(@as(u16, 2026), dt.year);
    try std.testing.expectEqual(@as(u8, 1), dt.month);
    try std.testing.expectEqual(@as(u8, 26), dt.day);
    try std.testing.expectEqual(@as(u8, 11), dt.hour);
    try std.testing.expectEqual(@as(u8, 34), dt.minute);
    try std.testing.expectEqual(@as(u8, 56), dt.second);

    // Round-trip
    try std.testing.expectEqual(epoch, dt.toEpoch());
}

test "Datetime format" {
    const dt = Datetime{
        .year = 2026,
        .month = 1,
        .day = 26,
        .hour = 12,
        .minute = 34,
        .second = 56,
    };

    var buf: [32]u8 = undefined;
    const formatted = dt.format(&buf);
    try std.testing.expectEqualStrings("2026-01-26T12:34:56Z", formatted);
}

test "RtcReader basic usage" {
    const MockDriver = struct {
        boot_time: u64 = 12345,
        epoch: ?i64 = 1769427296,

        pub fn uptime(self: *@This()) u64 {
            return self.boot_time;
        }

        pub fn read(self: *@This()) ?i64 {
            return self.epoch;
        }
    };

    const TestSpec = struct {
        pub const Driver = MockDriver;
        pub const meta = spec_mod.Meta{ .id = "rtc.test" };
    };

    const Reader = RtcReader(TestSpec);
    var driver = MockDriver{};
    var reader = Reader.init(&driver);

    try std.testing.expectEqual(@as(u64, 12345), reader.uptime());
    try std.testing.expect(reader.isSynced());

    if (reader.now()) |ts| {
        const dt = ts.toDatetime();
        try std.testing.expectEqual(@as(u16, 2026), dt.year);
    } else {
        return error.ExpectedTime;
    }
}

test "RtcWriter basic usage" {
    const MockDriver = struct {
        stored: ?i64 = null,

        pub fn write(self: *@This(), epoch_secs: i64) !void {
            self.stored = epoch_secs;
        }
    };

    const TestSpec = struct {
        pub const Driver = MockDriver;
        pub const meta = spec_mod.Meta{ .id = "rtc.test" };
    };

    const Writer = RtcWriter(TestSpec);
    var driver = MockDriver{};
    var writer = Writer.init(&driver);

    try writer.set(1769427296);
    try std.testing.expectEqual(@as(?i64, 1769427296), driver.stored);
}
