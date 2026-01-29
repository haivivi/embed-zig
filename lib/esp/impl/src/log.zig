//! Log Implementation for ESP32
//!
//! Implements trait.log using ESP-IDF esp_log.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const trait = @import("trait");
//!   const Log = trait.log.from(impl.Log);

const std = @import("std");

const c = @cImport({
    @cInclude("esp_log.h");
});

/// Log implementation that satisfies trait.log interface
/// Uses ESP-IDF esp_log for output
pub const Log = struct {
    const tag: [*:0]const u8 = "app";

    pub fn info(comptime fmt: []const u8, args: anytype) void {
        logImpl(c.ESP_LOG_INFO, fmt, args);
    }

    pub fn err(comptime fmt: []const u8, args: anytype) void {
        logImpl(c.ESP_LOG_ERROR, fmt, args);
    }

    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        logImpl(c.ESP_LOG_WARN, fmt, args);
    }

    pub fn debug(comptime fmt: []const u8, args: anytype) void {
        logImpl(c.ESP_LOG_DEBUG, fmt, args);
    }

    fn logImpl(level: c_int, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        if (msg.len < buf.len) {
            buf[msg.len] = 0;
        }

        c.esp_log_write(level, tag, "%s\n", @as([*:0]const u8, @ptrCast(buf[0..].ptr)));
    }
};

/// Scoped logger - creates a log with custom tag
pub fn scoped(comptime scope: []const u8) type {
    return struct {
        const tag: [*:0]const u8 = scope ++ "\x00";

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            logImpl(c.ESP_LOG_INFO, fmt, args);
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            logImpl(c.ESP_LOG_ERROR, fmt, args);
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            logImpl(c.ESP_LOG_WARN, fmt, args);
        }

        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            logImpl(c.ESP_LOG_DEBUG, fmt, args);
        }

        fn logImpl(level: c_int, comptime fmt: []const u8, args: anytype) void {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

            if (msg.len < buf.len) {
                buf[msg.len] = 0;
            }

            c.esp_log_write(level, tag, "%s\n", @as([*:0]const u8, @ptrCast(buf[0..].ptr)));
        }
    };
}

/// std.log adapter for ESP-IDF
/// Use in main.zig:
///   pub const std_options: std.Options = .{ .logFn = impl.log.stdLogFn };
pub fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const esp_level: c_int = switch (level) {
        .err => c.ESP_LOG_ERROR,
        .warn => c.ESP_LOG_WARN,
        .info => c.ESP_LOG_INFO,
        .debug => c.ESP_LOG_DEBUG,
    };

    const scope_prefix = if (scope != .default)
        "(" ++ @tagName(scope) ++ "): "
    else
        "";

    const tag: [*:0]const u8 = "zig";

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, scope_prefix ++ format, args) catch return;

    if (msg.len < buf.len) {
        buf[msg.len] = 0;
    }

    c.esp_log_write(esp_level, tag, "%s\n", @as([*:0]const u8, @ptrCast(buf[0..].ptr)));
}
