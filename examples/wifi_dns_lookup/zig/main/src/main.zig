const std = @import("std");
const idf = @import("idf");

const c = @cImport({
    @cInclude("sdkconfig.h");
});

const BUILD_TAG = "wifi_dns_lookup_zig_v1";

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

fn dnsLookupTest() void {
    std.log.info("", .{});
    std.log.info("=== DNS Lookup Test ===", .{});

    const test_domains = [_][]const u8{
        "www.google.com",
        "www.baidu.com",
        "cloudflare.com",
        "github.com",
    };

    // Test with UDP - AliDNS
    std.log.info("--- UDP DNS (223.5.5.5 AliDNS) ---", .{});
    var udp_resolver = idf.DnsResolver{
        .server = .{ 223, 5, 5, 5 },
        .protocol = .udp,
        .timeout_ms = 5000,
    };

    for (test_domains) |domain| {
        const result = udp_resolver.resolve(domain);
        var ip_buf: [16]u8 = undefined;
        if (result) |ip| {
            const ip_str = idf.net.formatIpv4(ip, &ip_buf);
            std.log.info("{s} => {s}", .{ domain, ip_str });
        } else |err| {
            std.log.err("{s} => failed: {}", .{ domain, err });
        }
    }

    // Test with TCP - AliDNS
    std.log.info("--- TCP DNS (223.5.5.5 AliDNS) ---", .{});
    var tcp_resolver = idf.DnsResolver{
        .server = .{ 223, 5, 5, 5 },
        .protocol = .tcp,
        .timeout_ms = 5000,
    };

    for (test_domains) |domain| {
        const result = tcp_resolver.resolve(domain);
        var ip_buf: [16]u8 = undefined;
        if (result) |ip| {
            const ip_str = idf.net.formatIpv4(ip, &ip_buf);
            std.log.info("{s} => {s}", .{ domain, ip_str });
        } else |err| {
            std.log.err("{s} => failed: {}", .{ domain, err });
        }
    }

    // Test with backup AliDNS
    std.log.info("--- UDP DNS (223.6.6.6 AliDNS Backup) ---", .{});
    var ali_resolver = idf.DnsResolver{
        .server = .{ 223, 6, 6, 6 },
        .protocol = .udp,
    };

    const ali_result = ali_resolver.resolve("example.com");
    var ip_buf: [16]u8 = undefined;
    if (ali_result) |ip| {
        const ip_str = idf.net.formatIpv4(ip, &ip_buf);
        std.log.info("example.com => {s}", .{ip_str});
    } else |err| {
        std.log.err("example.com => failed: {}", .{err});
    }
}

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("  WiFi DNS Lookup - Zig Version", .{});
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
    const ssid = c.CONFIG_WIFI_SSID;
    const password = c.CONFIG_WIFI_PASSWORD;

    std.log.info("Connecting to SSID: {s}", .{ssid});

    wifi.connect(.{
        .ssid = std.mem.sliceTo(ssid, 0),
        .password = std.mem.sliceTo(password, 0),
        .timeout_ms = 30000,
    }) catch |err| {
        std.log.err("WiFi connect failed: {}", .{err});
        return;
    };

    // Print IP address
    const ip = wifi.getIpAddress();
    var ip_buf: [16]u8 = undefined;
    const ip_str = idf.net.formatIpv4(ip, &ip_buf);
    std.log.info("Connected! IP: {s}", .{ip_str});

    printMemoryStats();

    // Run DNS lookup tests
    dnsLookupTest();

    // Keep running
    std.log.info("", .{});
    std.log.info("=== Test Complete ===", .{});

    while (true) {
        idf.delayMs(10000);
        std.log.info("Still running...", .{});
    }
}
