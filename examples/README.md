# Examples

ESP-IDF examples written in Zig with C comparison versions.

## Development Board

All examples are developed and tested on:

| Item | Value |
|------|-------|
| **Board** | ESP32-S3-DevKitC-1 (or compatible) |
| **Chip** | ESP32-S3 |
| **Flash** | 16MB |
| **PSRAM** | 8MB (Octal SPI) |
| **ESP-IDF** | v5.4.0 |
| **Zig** | 0.15.x (Espressif fork) |

## Examples List

| Example | Description | Status |
|---------|-------------|--------|
| [led_strip_flash](./led_strip_flash/) | WS2812 LED strip control | ✅ Working |
| [memory_attr_test](./memory_attr_test/) | IRAM/DRAM/PSRAM memory placement | ✅ Working |
| [wifi_dns_lookup](./wifi_dns_lookup/) | WiFi connection + DNS lookup (UDP/TCP) | ✅ Working |
| [http_speed_test](./http_speed_test/) | HTTP download speed test (C vs Zig) | 🚧 New |

## Project Structure

Each example follows this structure:

```
example_name/
├── README.md           # English documentation
├── README.zh-CN.md     # Chinese documentation
├── zig/                # Zig implementation
│   ├── CMakeLists.txt
│   ├── sdkconfig.defaults
│   └── main/
│       ├── CMakeLists.txt
│       ├── build.zig
│       ├── build.zig.zon
│       └── src/
│           ├── main.zig
│           └── main.c   # C helpers (if needed)
└── c/                  # C implementation (for comparison)
    ├── CMakeLists.txt
    ├── sdkconfig.defaults
    └── main/
        └── main.c
```

## Build & Flash

```bash
# Navigate to example
cd examples/led_strip_flash/zig

# Set target (first time only)
idf.py set-target esp32s3

# Configure (if needed)
idf.py menuconfig

# Build
idf.py build

# Flash and monitor
idf.py -p /dev/cu.usbmodem* flash monitor
```

## WiFi Configuration

For WiFi examples, configure SSID and password:

```bash
idf.py menuconfig
# Navigate to: WiFi DNS Lookup Configuration
# Set WIFI_SSID and WIFI_PASSWORD
```

Or edit `sdkconfig.defaults`:

```
CONFIG_WIFI_SSID="your_ssid"
CONFIG_WIFI_PASSWORD="your_password"
```
