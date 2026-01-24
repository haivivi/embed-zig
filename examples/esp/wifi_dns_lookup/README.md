# WiFi DNS Lookup

[中文版](./README.zh-CN.md)

WiFi connection and DNS lookup example demonstrating custom DNS resolver with interface binding support.

## Features

- WiFi STA mode connection
- Custom DNS resolver (pure Zig implementation)
- UDP and TCP DNS protocols
- Interface binding support (for multi-NIC scenarios like PPP + WLAN)
- Configurable DNS server

## Hardware Requirements

- ESP32-S3 with PSRAM (tested on ESP32-S3-DevKitC-1)
- WiFi network access

## Configuration

Before building, configure WiFi credentials:

```bash
idf.py menuconfig
# Navigate to: WiFi DNS Lookup Configuration
# Set:
#   - WiFi SSID
#   - WiFi Password
```

## Build & Flash

```bash
cd zig

# Set target (first time)
idf.py set-target esp32s3

# Build
idf.py build

# Flash and monitor
idf.py -p /dev/cu.usbmodem* flash monitor
```

## Expected Output

```
==========================================
  WiFi DNS Lookup - Zig Version
  Build Tag: wifi_dns_lookup_zig_v1
==========================================
=== Heap Memory Statistics ===
Internal DRAM: Total=... Free=... Used=...

Initializing WiFi...
Connecting to SSID: MyNetwork
Connected! IP: 192.168.1.100

=== DNS Lookup Test ===
--- UDP DNS (8.8.8.8) ---
www.google.com => 142.250.xxx.xxx
www.baidu.com => 110.242.xxx.xxx
cloudflare.com => 104.16.xxx.xxx
github.com => 140.82.xxx.xxx

--- TCP DNS (8.8.8.8) ---
www.google.com => 142.250.xxx.xxx
...

--- UDP DNS (1.1.1.1 Cloudflare) ---
example.com => 93.184.xxx.xxx

=== Test Complete ===
```

## API Usage

```zig
const idf = @import("esp");

// Initialize and connect WiFi
var wifi = try idf.Wifi.init();
try wifi.connect(.{
    .ssid = "MyNetwork",
    .password = "password",
    .timeout_ms = 30000,
});

// DNS lookup with UDP
var resolver = idf.DnsResolver{
    .server = .{ 8, 8, 8, 8 },  // Google DNS
    .protocol = .udp,
    .timeout_ms = 5000,
};
const ip = try resolver.resolve("example.com");

// DNS lookup with TCP
var tcp_resolver = idf.DnsResolver{
    .server = .{ 1, 1, 1, 1 },  // Cloudflare DNS
    .protocol = .tcp,
};
const ip2 = try tcp_resolver.resolve("example.com");

// DNS with interface binding (for PPP scenarios)
var ppp_resolver = idf.DnsResolver{
    .server = .{ 10, 0, 0, 1 },  // PPP gateway DNS
    .interface = "ppp0",         // Bind to PPP interface
};
const ip3 = try ppp_resolver.resolve("example.com");
```

## Binary Size & Memory

### Binary Size

| Version | .bin Size |
|---------|-----------|
| **Zig** | 766,032 bytes (748 KB) |

### Memory Usage (Static)

| Memory Region | Zig |
|---------------|-----|
| **IRAM** | 16,383 bytes |
| **DRAM** | 106,231 bytes |
| **Flash Code** | 553,150 bytes |

> Note: No C version for comparison - this example is Zig-only to showcase pure Zig DNS implementation.

## Architecture Notes

Due to ESP-IDF's WiFi configuration structures containing complex bit-fields and unions that `@cImport` cannot translate, WiFi initialization uses C helper functions:

- `esp/src/wifi.zig` - Zig interface
- `main/src/main.c` - C helper implementation

DNS resolver is pure Zig implementation using lwIP sockets.
