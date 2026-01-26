# WiFi DNS Lookup

[中文版](./README.zh-CN.md)

WiFi connection and DNS lookup example demonstrating custom DNS resolver with multiple protocols support.

## Features

- WiFi STA mode connection
- Custom DNS resolver (pure Zig implementation)
- **UDP DNS** - Fast, standard DNS queries
- **TCP DNS** - For large responses or firewalled networks
- **HTTPS DNS (DoH)** - DNS over HTTPS with TLS certificate verification
- Interface binding support (for multi-NIC scenarios like PPP + WLAN)
- Configurable DNS server (AliDNS, Google, Cloudflare, etc.)

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
Internal DRAM: Total=387815 Free=327895 Used=59920
External PSRAM: Total=8388608 Free=8386148 Used=2460

Initializing WiFi...
Connecting to SSID: HAIVIVI-MFG
Connected! IP: 192.168.4.7

=== DNS Lookup Test ===
--- UDP DNS (223.5.5.5 AliDNS) ---
www.google.com => 199.59.148.20
www.baidu.com => 110.242.70.57
cloudflare.com => 104.16.133.229
github.com => 20.205.243.166

--- TCP DNS (223.5.5.5 AliDNS) ---
www.google.com => 199.59.148.20
www.baidu.com => 110.242.69.21
cloudflare.com => 104.16.133.229
github.com => 20.205.243.166

--- HTTPS DNS (223.5.5.5 AliDNS DoH) ---
I (6562) esp-x509-crt-bundle: Certificate validated
www.google.com => 199.59.148.20
I (9932) esp-x509-crt-bundle: Certificate validated
www.baidu.com => 110.242.69.21
I (12082) esp-x509-crt-bundle: Certificate validated
cloudflare.com => 104.16.132.229
I (13782) esp-x509-crt-bundle: Certificate validated
github.com => 20.205.243.166

--- UDP DNS (223.6.6.6 AliDNS Backup) ---
example.com => 104.18.26.120

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

// DNS lookup with UDP (fastest)
var udp_resolver = idf.DnsResolver{
    .server = .{ 223, 5, 5, 5 },  // AliDNS
    .protocol = .udp,
    .timeout_ms = 5000,
};
const ip = try udp_resolver.resolve("example.com");

// DNS lookup with TCP
var tcp_resolver = idf.DnsResolver{
    .server = .{ 223, 5, 5, 5 },  // AliDNS
    .protocol = .tcp,
};
const ip2 = try tcp_resolver.resolve("example.com");

// DNS over HTTPS (DoH) - encrypted and secure
var doh_resolver = idf.DnsResolver{
    .protocol = .https,
    .doh_host = "223.5.5.5",  // AliDNS DoH
    .timeout_ms = 10000,
};
const ip3 = try doh_resolver.resolve("example.com");
```

## Binary Size & Memory

### Binary Size

| Version | .bin Size | Notes |
|---------|-----------|-------|
| **Zig (with DoH)** | 901,296 bytes (880 KB) | Includes CA certificate bundle for HTTPS |
| **Zig (UDP/TCP only)** | 828,544 bytes (809 KB) | Without CA bundle |

### Memory Usage (Runtime)

| Memory Type | Before WiFi | After WiFi | Notes |
|-------------|-------------|------------|-------|
| **Internal DRAM** | 327,895 free | 276,951 free | ~51 KB used by WiFi |
| **External PSRAM** | 8,386,148 free | 8,386,020 free | Minimal PSRAM usage |

> Note: This is a Zig-only example showcasing pure Zig DNS implementation with SAL socket abstraction.

## Architecture Notes

### DNS Resolution Stack

```
┌─────────────────────────────────────────┐
│           Application Code              │
│    (main.zig - DnsResolver API)         │
├─────────────────────────────────────────┤
│         lib/esp/src/net/dns.zig         │
│    (ESP DNS wrapper with DoH support)   │
├─────────────────────────────────────────┤
│      lib/dns/src/dns.zig (UDP/TCP)      │    lib/esp/src/http.zig (DoH)
│    (Cross-platform DNS protocol)        │    (esp_http_client wrapper)
├─────────────────────────────────────────┤
│       lib/esp/src/sal/socket.zig        │
│      (SAL Socket - LWIP sockets)        │
├─────────────────────────────────────────┤
│            ESP-IDF / LWIP               │
└─────────────────────────────────────────┘
```

### Protocol Implementation

- **UDP/TCP DNS**: Pure Zig implementation using `lib/dns` with SAL socket abstraction
- **HTTPS DNS (DoH)**: Uses `esp_http_client` with ESP-IDF CA certificate bundle
- **WiFi**: Uses C helper functions due to complex bit-fields in WiFi config structures

### sdkconfig Requirements for DoH

```
CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y
CONFIG_MBEDTLS_CERTIFICATE_BUNDLE_DEFAULT_FULL=y
```
