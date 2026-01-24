//! ESP-IDF HTTP Client wrapper

const std = @import("std");

const heap = @import("heap.zig");
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("esp_http_client.h");
    @cInclude("esp_timer.h");
    @cInclude("esp_log.h");
});

pub const HttpError = error{
    InitFailed,
    RequestFailed,
    ConnectionFailed,
    Timeout,
    InvalidResponse,
};

/// Progress information passed to callback
pub const ProgressInfo = struct {
    bytes: usize,
    elapsed_ms: u32,
    speed_kbps: u32,
    iram_free: usize,
    psram_free: usize,
};

/// Progress callback type - set this to receive progress updates
pub const ProgressCallback = *const fn (ProgressInfo) void;

/// Global context for event handler (needed because user_data becomes invalid after init)
var g_total_bytes: usize = 0;
var g_last_print_bytes: usize = 0;
var g_start_time: i64 = 0;
var g_progress_callback: ?ProgressCallback = null;

/// Set progress callback (call before download)
pub fn setProgressCallback(callback: ?ProgressCallback) void {
    g_progress_callback = callback;
}

pub const HttpClient = struct {
    handle: c.esp_http_client_handle_t,

    pub const Config = struct {
        url: [:0]const u8,
        timeout_ms: u32 = 120000, // 2 minutes for large files
        buffer_size: usize = 16384, // 16KB buffer
    };

    pub fn init(config: Config) !HttpClient {
        // Use zeroes() like C's designated initializer - only set fields we need
        var http_config = std.mem.zeroes(c.esp_http_client_config_t);
        http_config.url = config.url.ptr;
        http_config.event_handler = eventHandler;
        http_config.buffer_size = @intCast(config.buffer_size);
        http_config.buffer_size_tx = 4096; // Match C version
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
            // Use u64 to avoid overflow: bytes * 1000 can overflow u32 when bytes > 4MB
            const bytes_u64: u64 = self.bytes;
            return @intCast((bytes_u64 * 1000) / 1024 / self.duration_ms);
        }
    };

    /// Download content using esp_http_client_perform (same as C version)
    pub fn download(self: *HttpClient) !DownloadResult {
        g_total_bytes = 0;
        g_last_print_bytes = 0;
        g_start_time = c.esp_timer_get_time();

        const start_time = g_start_time;
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

            // Report progress every 1MB
            if (g_total_bytes - g_last_print_bytes >= 1024 * 1024) {
                const now = c.esp_timer_get_time();
                const elapsed_us = now - g_start_time;
                const elapsed_ms: u32 = @intCast(@divTrunc(elapsed_us, 1000));
                // Use u64 to avoid overflow: bytes * 1000 can overflow u32 when bytes > 4MB
                const bytes_u64: u64 = g_total_bytes;
                const speed_kbps: u32 = if (elapsed_ms > 0)
                    @intCast((bytes_u64 * 1000) / 1024 / elapsed_ms)
                else
                    0;

                const info = ProgressInfo{
                    .bytes = g_total_bytes,
                    .elapsed_ms = elapsed_ms,
                    .speed_kbps = speed_kbps,
                    .iram_free = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL),
                    .psram_free = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM),
                };

                // Call user callback if set, otherwise default log
                if (g_progress_callback) |callback| {
                    callback(info);
                } else {
                    std.log.info("Progress: {} bytes ({} KB/s) | IRAM: {}, PSRAM: {} free", .{
                        info.bytes,
                        info.speed_kbps,
                        info.iram_free,
                        info.psram_free,
                    });
                }

                g_last_print_bytes = g_total_bytes;
            }
        }
        return 0;
    }
};

pub fn getTimeUs() i64 {
    return c.esp_timer_get_time();
}
