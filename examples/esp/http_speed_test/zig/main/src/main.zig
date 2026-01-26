//! HTTP Speed Test - Zig Version (esp_http_client)
//!
//! Tests HTTP download speed using esp_http_client
//! Runs on PSRAM task stack via SAL

const std = @import("std");

const idf = @import("esp");
const log = idf.sal.log;

const c = @cImport({
    @cInclude("sdkconfig.h");
});

const BUILD_TAG = "https_speed_zig_esp_v2";

// HTTPS test URL - Tsinghua Mirror Python 3.12 (27MB)
const HTTPS_TEST_URL = "https://mirrors.tuna.tsinghua.edu.cn/python/3.12.0/Python-3.12.0.tgz";

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

/// Progress callback with WiFi RSSI
fn progressCallback(info: idf.http.ProgressInfo) void {
    // Get WiFi RSSI via idf.wifi module
    const rssi = idf.wifi.getRssi();
    log.info("Progress: {} bytes ({} KB/s) | RSSI: {} | IRAM: {}, PSRAM: {} free", .{
        info.bytes,
        info.speed_kbps,
        rssi,
        info.iram_free,
        info.psram_free,
    });
}

fn printMemoryStats() void {
    log.info("=== Heap Memory Statistics ===", .{});

    const internal = idf.heap.getInternalStats();
    log.info("Internal DRAM: Total={} Free={} Used={}", .{
        internal.total,
        internal.free,
        internal.used,
    });

    const psram = idf.heap.getPsramStats();
    if (psram.total > 0) {
        log.info("External PSRAM: Total={} Free={} Used={}", .{
            psram.total,
            psram.free,
            psram.used,
        });
    }
}

fn runSpeedTest(url: [:0]const u8, test_name: []const u8) void {
    log.info("--- {s} ---", .{test_name});
    log.info("URL: {s}", .{url});

    // Set progress callback with WiFi RSSI
    idf.http.setProgressCallback(progressCallback);

    var client = idf.HttpClient.init(.{
        .url = url,
        .timeout_ms = 120000, // 2 minutes for large HTTPS downloads
        .buffer_size = 16384,
        .is_https = true, // Enable HTTPS with CA bundle
    }) catch {
        log.err("Failed to init HTTP client", .{});
        return;
    };
    defer client.deinit();

    // Record memory AFTER init (same as C version)
    const mem_before = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    const result = client.download() catch {
        log.err("HTTP request failed", .{});
        return;
    };

    // Record memory after download
    const mem_after = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    log.info("Status: {}, Content-Length: {}", .{ result.status_code, result.content_length });
    log.info("Downloaded: {} bytes in {} ms", .{ result.bytes, result.duration_ms });
    log.info("Speed: {} KB/s", .{result.speedKBps()});

    const mem_used = if (mem_before > mem_after) mem_before - mem_after else 0;
    log.info("Memory used during download: {} bytes", .{mem_used});
}

fn runHttpsSpeedTest() void {
    log.info("", .{});
    log.info("=== HTTPS Speed Test (Zig esp_http_client) ===", .{});
    log.info("Note: Using ESP-IDF CA certificate bundle", .{});

    // Test HTTPS download - Tsinghua Mirror Python 3.12 (27MB)
    runSpeedTest(HTTPS_TEST_URL, "HTTPS Download 27MB (Tsinghua Mirror)");

    log.info("", .{});
    log.info("=== HTTPS Speed Test Complete ===", .{});
    printMemoryStats();
}

export fn app_main() void {
    log.info("==========================================", .{});
    log.info("  HTTP Speed Test - Zig esp_http_client", .{});
    log.info("  Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    printMemoryStats();

    // Initialize WiFi
    log.info("", .{});
    log.info("Initializing WiFi...", .{});

    var wifi = idf.Wifi.init() catch |err| {
        log.err("WiFi init failed: {}", .{err});
        return;
    };

    // Connect to WiFi (use sentinel-terminated strings for C interop)
    const ssid: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_SSID));
    const password: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_PASSWORD));

    log.info("Connecting to SSID: {s}", .{ssid});

    wifi.connect(.{
        .ssid = ssid,
        .password = password,
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("WiFi connect failed: {}", .{err});
        return;
    };

    // Print IP address
    const ip_bytes = wifi.getIpAddress();
    log.info("Connected! IP: {}.{}.{}.{}", .{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] });

    printMemoryStats();

    // Run HTTPS speed test
    runHttpsSpeedTest();

    // Keep running
    while (true) {
        idf.sal.sleepMs(10000);
        log.info("Still running...", .{});
    }
}
