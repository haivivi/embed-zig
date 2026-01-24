# LED Strip Flash

[中文版](README.zh-CN.md)

ESP32-S3 LED strip blinking example, comparing Zig and C implementations.

## Features

- Control WS2812/SK6812 RGB LED strip
- Use ESP-IDF RMT driver
- Periodic blinking effect
- Output heap memory statistics

## Directory Structure

```
led_strip_flash/
├── zig/           # Zig implementation
│   ├── main/
│   │   ├── build.zig
│   │   └── src/main.zig
│   └── CMakeLists.txt
├── c/             # C implementation
│   └── main/
│       └── main.c
└── README.md
```

## Build Comparison (ESP32-S3)

Test Environment:
- ESP-IDF v5.4.0
- Zig 0.15.x (Espressif fork)
- Target: esp32s3
- Optimization: ReleaseSafe (Zig), Debug (C)

### Binary Size

| Version | .bin Size | Build Tag | Diff |
|---------|-----------|-----------|------|
| Zig | 225,808 bytes (220.5 KB) | `led_strip_zig_v3` | +11,040 bytes (+5.1%) |
| C | 214,768 bytes (209.7 KB) | `led_strip_c_v1` | baseline |

### Runtime Memory Usage (Heap)

| Memory Region | Zig | C |
|---------------|-----|---|
| **Internal DRAM Total** | 408,544 bytes | 408,536 bytes |
| **Free** | 391,300 bytes | 391,292 bytes |
| **Used** | 17,244 bytes | 17,244 bytes |

> ✅ Zig with `std.log` only adds ~11KB (+5%) to binary size. Runtime memory is identical to C!

## Runtime Logs

### Zig Version Output

```
I (347):   LED Strip Flash - Zig Version
I (347):   Build Tag: led_strip_zig_v1
I (357): === Heap Memory Statistics ===
I (367): Internal DRAM:
I (377): External PSRAM: not available
I (377): Toggling the LED OFF!
I (1377): Toggling the LED ON!
I (2377): Toggling the LED OFF!
I (3377): Toggling the LED ON!
```

### C Version Output

```
I (274) led_strip:   LED Strip Flash - C Version
I (284) led_strip:   Build Tag: led_strip_c_v1
I (294) led_strip: === Heap Memory Statistics ===
I (294) led_strip: Internal DRAM:
I (314) led_strip: External PSRAM: not available
I (324) led_strip: DMA capable free: 383788 bytes
I (324) led_strip: Toggling the LED OFF!
I (1324) led_strip: Toggling the LED ON!
I (2324) led_strip: Toggling the LED OFF!
I (3324) led_strip: Toggling the LED ON!
```

> Note: PSRAM is not enabled, memory statistics only show internal DRAM.

## Key Finding

The ~430KB bloat was **NOT** caused by `std.log`, but by incorrect CMakeLists.txt configuration:

```cmake
# ❌ These lines force-link entire WiFi stack (~430KB)!
"-Wl,-u,esp_netif_init"
"-Wl,-u,esp_wifi_init"
```

After removing unnecessary linker symbols, `std.log` only adds ~11KB (+5%).

## Build

```bash
# Zig version
cd zig
idf.py set-target esp32s3
idf.py build

# C version
cd c
idf.py set-target esp32s3
idf.py build
```

## Flash

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```

## Configuration

Configure via `idf.py menuconfig`:
- `BLINK_GPIO`: LED data pin (default: 48)
- `BLINK_PERIOD`: Blink period (default: 1000ms)
