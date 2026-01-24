//! ESP-IDF HTTP Client wrapper

const std = @import("std");
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("esp_http_client.h");
    @cInclude("esp_timer.h");
});

pub const HttpError = error{
    InitFailed,
    RequestFailed,
    ConnectionFailed,
    Timeout,
    InvalidResponse,
};

/// Global context for event handler (needed because user_data becomes invalid after init)
var g_total_bytes: usize = 0;

pub const HttpClient = struct {
    handle: c.esp_http_client_handle_t,

    pub const Config = struct {
        url: [:0]const u8,
        timeout_ms: u32 = 30000,
        buffer_size: usize = 4096,
    };

    pub fn init(config: Config) !HttpClient {
        // Use zeroes() like C's designated initializer - only set fields we need
        var http_config = std.mem.zeroes(c.esp_http_client_config_t);
        http_config.url = config.url.ptr;
        http_config.event_handler = eventHandler;
        http_config.buffer_size = @intCast(config.buffer_size);
        http_config.buffer_size_tx = 1024;
        http_config.timeout_ms = @intCast(config.timeout_ms);

        const handle = c.esp_http_client_init(&http_config);
        if (handle == null) {
            return HttpError.InitFailed;
        }

        return HttpClient{
            .handle = handle,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        if (self.handle != null) {
            _ = c.esp_http_client_cleanup(self.handle);
            self.handle = null;
        }
    }

    pub const DownloadResult = struct {
        bytes: usize,
        duration_ms: u32,
        status_code: i32,
        content_length: i64,

        /// Calculate speed in KB/s (integer only, avoids 128-bit ops)
        pub fn speedKBps(self: DownloadResult) u32 {
            if (self.duration_ms == 0) return 0;
            return @intCast((self.bytes * 1000) / 1024 / self.duration_ms);
        }
    };

    /// Download content using esp_http_client_perform (same as C version)
    pub fn download(self: *HttpClient) !DownloadResult {
        g_total_bytes = 0;

        const start_time = c.esp_timer_get_time();
        const err = c.esp_http_client_perform(self.handle);
        const end_time = c.esp_timer_get_time();

        if (err != sys.ESP_OK) {
            return HttpError.RequestFailed;
        }

        const duration_us = end_time - start_time;
        const duration_ms: u32 = @intCast(@divTrunc(duration_us, 1000));

        return DownloadResult{
            .bytes = g_total_bytes,
            .duration_ms = duration_ms,
            .status_code = c.esp_http_client_get_status_code(self.handle),
            .content_length = c.esp_http_client_get_content_length(self.handle),
        };
    }

    fn eventHandler(evt: [*c]c.esp_http_client_event_t) callconv(.c) c_int {
        if (evt == null) return 0;
        if (evt.*.event_id == c.HTTP_EVENT_ON_DATA) {
            g_total_bytes += @intCast(evt.*.data_len);
        }
        return 0;
    }
};

pub fn getTimeUs() i64 {
    return c.esp_timer_get_time();
}
