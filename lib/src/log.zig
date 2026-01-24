//! ESP-IDF Logging with std.log integration

const std = @import("std");

const c = @cImport({
    @cInclude("esp_log.h");
});

// Log levels
pub const ESP_LOG_NONE = c.ESP_LOG_NONE;
pub const ESP_LOG_ERROR = c.ESP_LOG_ERROR;
pub const ESP_LOG_WARN = c.ESP_LOG_WARN;
pub const ESP_LOG_INFO = c.ESP_LOG_INFO;
pub const ESP_LOG_DEBUG = c.ESP_LOG_DEBUG;
pub const ESP_LOG_VERBOSE = c.ESP_LOG_VERBOSE;

// Functions
pub const esp_log_write = c.esp_log_write;
pub const esp_log_timestamp = c.esp_log_timestamp;

/// std.log adapter for ESP-IDF
/// Use: pub const std_options: std.Options = .{ .logFn = esp.log.stdLogFn };
pub fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const esp_level = switch (level) {
        .err => ESP_LOG_ERROR,
        .warn => ESP_LOG_WARN,
        .info => ESP_LOG_INFO,
        .debug => ESP_LOG_DEBUG,
    };

    const scope_prefix = if (scope != .default)
        "(" ++ @tagName(scope) ++ "): "
    else
        "";

    const tag: [*:0]const u8 = "zig";

    // Format into buffer then output
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, scope_prefix ++ format, args) catch return;

    if (msg.len < buf.len) {
        buf[msg.len] = 0;
    }

    esp_log_write(esp_level, tag, "%s\n", @as([*:0]const u8, @ptrCast(buf[0..].ptr)));
}
