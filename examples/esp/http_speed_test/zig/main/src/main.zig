//! HTTP Speed Test - Zig Version (esp_http_client)
//!
//! Tests HTTP download speed using esp_http_client
//! Runs on PSRAM task stack via SAL

const std = @import("std");

const idf = @import("esp");

const c = @cImport({
    @cInclude("sdkconfig.h");
});

const BUILD_TAG = "http_speed_zig_esp_v2";

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

/// Progress callback with WiFi RSSI
fn progressCallback(info: idf.http.ProgressInfo) void {
    // Get WiFi RSSI via idf.wifi module
    const rssi = idf.wifi.getRssi();
    std.log.info("Progress: {} bytes ({} KB/s) | RSSI: {} | IRAM: {}, PSRAM: {} free", .{
        info.bytes,
        info.speed_kbps,
        rssi,
        info.iram_free,
        info.psram_free,
    });
}

fn printMemoryStats() void {
    std.log.info("=== Heap Memory Statistics ===", .{});

    const internal = idf.heap.getInternalStats();
    std.log.info("Internal DRAM: Total={} Free={} Used={}", .{
        internal.total,
        internal.free,
        internal.used,
    });

    const psram = idf.heap.getPsramStats();
    if (psram.total > 0) {
        std.log.info("External PSRAM: Total={} Free={} Used={}", .{
            psram.total,
            psram.free,
            psram.used,
        });
    }
}

fn runSpeedTest(url: [:0]const u8, test_name: []const u8) void {
    std.log.info("--- {s} ---", .{test_name});
    std.log.info("URL: {s}", .{url});

    // Set progress callback with WiFi RSSI
    idf.http.setProgressCallback(progressCallback);

    var client = idf.HttpClient.init(.{
        .url = url,
        .timeout_ms = 30000,
        .buffer_size = 4096,
    }) catch {
        std.log.err("Failed to init HTTP client", .{});
        return;
    };
    defer client.deinit();

    // Record memory AFTER init (same as C version)
    const mem_before = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    const result = client.download() catch {
        std.log.err("HTTP request failed", .{});
        return;
    };

    // Record memory after download
    const mem_after = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    std.log.info("Status: {}, Content-Length: {}", .{ result.status_code, result.content_length });
    std.log.info("Downloaded: {} bytes in {} ms", .{ result.bytes, result.duration_ms });
    std.log.info("Speed: {} KB/s", .{result.speedKBps()});

    const mem_used = if (mem_before > mem_after) mem_before - mem_after else 0;
    std.log.info("Memory used during download: {} bytes", .{mem_used});
}

/// HTTP speed test task function (runs on PSRAM stack)
fn httpSpeedTestTaskFn(_: ?*anyopaque) callconv(.c) i32 {
    const server_ip: []const u8 = std.mem.sliceTo(c.CONFIG_TEST_SERVER_IP, 0);
    const server_port: u16 = c.CONFIG_TEST_SERVER_PORT;

    std.log.info("", .{});
    std.log.info("=== HTTP Speed Test (Zig esp_http_client) ===", .{});
    std.log.info("Server: {s}:{}", .{ server_ip, server_port });
    std.log.info("Note: Running on PSRAM stack task (64KB)", .{});

    // Test 10MB and 50MB for stable speed measurement
    const tests = [_]struct { path: []const u8, name: []const u8 }{
        .{ .path = "/test/10m", .name = "Download 10MB" },
        .{ .path = "/test/52428800", .name = "Download 50MB" },
    };

    for (tests) |t| {
        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrintZ(&url_buf, "http://{s}:{d}{s}", .{ server_ip, server_port, t.path }) catch {
            std.log.err("URL too long", .{});
            continue;
        };
        runSpeedTest(url, t.name);
        idf.delayMs(1000);
    }

    std.log.info("", .{});
    std.log.info("=== Speed Test Complete ===", .{});
    printMemoryStats();

    return 0;
}

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("  HTTP Speed Test - Zig esp_http_client", .{});
    std.log.info("  Build Tag: {s}", .{BUILD_TAG});
    std.log.info("==========================================", .{});

    printMemoryStats();

    // Initialize WiFi
    std.log.info("", .{});
    std.log.info("Initializing WiFi...", .{});

    var wifi = idf.Wifi.init() catch |err| {
        std.log.err("WiFi init failed: {}", .{err});
        return;
    };

    // Connect to WiFi (use sentinel-terminated strings for C interop)
    const ssid: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_SSID));
    const password: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_PASSWORD));

    std.log.info("Connecting to SSID: {s}", .{ssid});

    wifi.connect(.{
        .ssid = ssid,
        .password = password,
        .timeout_ms = 30000,
    }) catch |err| {
        std.log.err("WiFi connect failed: {}", .{err});
        return;
    };

    // Print IP address
    const ip_bytes = wifi.getIpAddress();
    std.log.info("Connected! IP: {}.{}.{}.{}", .{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] });

    printMemoryStats();

    // Run speed test on PSRAM stack task using SAL
    std.log.info("Starting HTTP test on PSRAM stack task (64KB stack)...", .{});
    const result = idf.sal.thread.go(idf.heap.psram, "http_test", httpSpeedTestTaskFn, null, .{
        .stack_size = 65536, // 64KB
    }) catch |err| {
        std.log.err("Failed to run HTTP test task: {}", .{err});
        return;
    };
    std.log.info("HTTP test task completed with result: {}", .{result});

    // Keep running
    while (true) {
        idf.delayMs(10000);
        std.log.info("Still running...", .{});
    }
}
