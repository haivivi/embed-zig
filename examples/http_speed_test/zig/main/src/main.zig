//! HTTP Speed Test - Zig Version
//!
//! Tests HTTP download speed using esp_http_client

const std = @import("std");
const idf = @import("idf");

const c = @cImport({
    @cInclude("sdkconfig.h");
});

const BUILD_TAG = "http_speed_zig_v1";

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

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

fn httpSpeedTestTask() void {
    const server_ip = c.CONFIG_TEST_SERVER_IP;
    const server_port = c.CONFIG_TEST_SERVER_PORT;

    std.log.info("", .{});
    std.log.info("=== HTTP Speed Test ===", .{});
    std.log.info("Server: {s}:{}", .{ server_ip, server_port });

    // Test different sizes
    const sizes = [_][]const u8{ "1k", "10k", "100k", "1m" };
    const test_names = [_][]const u8{ "Download 1k", "Download 10k", "Download 100k", "Download 1m" };

    inline for (sizes, test_names) |size, name| {
        const url = std.fmt.comptimePrint("http://{s}:{d}/test/{s}", .{ server_ip, server_port, size });
        runSpeedTest(url, name);
        idf.delayMs(1000);
    }

    std.log.info("", .{});
    std.log.info("=== Speed Test Complete ===", .{});
    printMemoryStats();
}

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("  HTTP Speed Test - Zig Version", .{});
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

    // Connect to WiFi
    const ssid: []const u8 = std.mem.sliceTo(c.CONFIG_WIFI_SSID, 0);
    const password: []const u8 = std.mem.sliceTo(c.CONFIG_WIFI_PASSWORD, 0);

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

    // Run speed test
    httpSpeedTestTask();

    // Keep running
    while (true) {
        idf.delayMs(10000);
        std.log.info("Still running...", .{});
    }
}
