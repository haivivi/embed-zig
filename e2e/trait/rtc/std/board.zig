const std = @import("std");
const std_impl = @import("std_impl");

pub const log = struct {
    pub fn info(comptime fmt: []const u8, args: anytype) void { std.debug.print("[INFO] " ++ fmt ++ "\n", args); }
    pub fn err(comptime fmt: []const u8, args: anytype) void { std.debug.print("[ERR]  " ++ fmt ++ "\n", args); }
    pub fn warn(comptime fmt: []const u8, args: anytype) void { std.debug.print("[WARN] " ++ fmt ++ "\n", args); }
    pub fn debug(comptime fmt: []const u8, args: anytype) void { std.debug.print("[DBG]  " ++ fmt ++ "\n", args); }
};

pub const time = struct {
    pub fn sleepMs(ms: u32) void { std_impl.time.sleepMs(ms); }
    pub fn nowMs() u64 { return std_impl.time.nowMs(); }
};

/// Std RTC driver — uses milliTimestamp for uptime
pub const StdRtcDriver = struct {
    pub fn init() !StdRtcDriver { return .{}; }
    pub fn deinit(_: *StdRtcDriver) void {}
    pub fn uptime(_: *StdRtcDriver) u64 {
        return @intCast(std.time.milliTimestamp());
    }
    pub fn nowMs(_: *StdRtcDriver) ?i64 { return null; }
};

pub const rtc_spec = struct {
    pub const Driver = StdRtcDriver;
    pub const meta = .{ .id = "std_rtc" };
};
