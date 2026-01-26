const std = @import("std");

const idf = @import("esp");
const sal = idf.sal;
const log = sal.log;

const c = @cImport({
    @cInclude("sdkconfig.h");
});

const BUILD_TAG = "wifi_dns_lookup_zig_v2";

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

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

fn dnsLookupTest() void {
    log.info("", .{});
    log.info("=== DNS Lookup Test ===", .{});

    const test_domains = [_][]const u8{
        "www.google.com",
        "www.baidu.com",
        "cloudflare.com",
        "github.com",
    };

    // Test with UDP - AliDNS
    log.info("--- UDP DNS (223.5.5.5 AliDNS) ---", .{});
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
            log.info("{s} => {s}", .{ domain, ip_str });
        } else |err| {
            log.err("{s} => failed: {}", .{ domain, err });
        }
    }

    // Test with TCP - AliDNS
    log.info("--- TCP DNS (223.5.5.5 AliDNS) ---", .{});
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
            log.info("{s} => {s}", .{ domain, ip_str });
        } else |err| {
            log.err("{s} => failed: {}", .{ domain, err });
        }
    }

    // Test with HTTPS - AliDNS DoH
    log.info("--- HTTPS DNS (223.5.5.5 AliDNS DoH) ---", .{});
    var doh_resolver = idf.DnsResolver{
        .protocol = .https,
        .doh_host = "223.5.5.5",
        .timeout_ms = 10000,
    };

    for (test_domains) |domain| {
        const result = doh_resolver.resolve(domain);
        var ip_buf2: [16]u8 = undefined;
        if (result) |ip| {
            const ip_str = idf.net.formatIpv4(ip, &ip_buf2);
            log.info("{s} => {s}", .{ domain, ip_str });
        } else |err| {
            log.err("{s} => failed: {}", .{ domain, err });
        }
    }

    // Test with backup AliDNS
    log.info("--- UDP DNS (223.6.6.6 AliDNS Backup) ---", .{});
    var ali_resolver = idf.DnsResolver{
        .server = .{ 223, 6, 6, 6 },
        .protocol = .udp,
    };

    const ali_result = ali_resolver.resolve("example.com");
    var ip_buf: [16]u8 = undefined;
    if (ali_result) |ip| {
        const ip_str = idf.net.formatIpv4(ip, &ip_buf);
        log.info("example.com => {s}", .{ip_str});
    } else |err| {
        log.err("example.com => failed: {}", .{err});
    }
}

export fn app_main() void {
    log.info("==========================================", .{});
    log.info("  WiFi DNS Lookup - Zig Version", .{});
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

    // Connect to WiFi (sentinel-terminated strings for C interop)
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
    const ip = wifi.getIpAddress();
    var ip_buf: [16]u8 = undefined;
    const ip_str = idf.net.formatIpv4(ip, &ip_buf);
    log.info("Connected! IP: {s}", .{ip_str});

    printMemoryStats();

    // Run DNS lookup tests
    dnsLookupTest();

    // Keep running
    log.info("", .{});
    log.info("=== Test Complete ===", .{});

    while (true) {
        sal.sleepMs(10000);
        log.info("Still running...", .{});
    }
}
