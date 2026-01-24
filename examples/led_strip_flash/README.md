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
- Optimization: Size (`CONFIG_COMPILER_OPTIMIZATION_SIZE=y`)
- PSRAM: Enabled (8MB Octal)

### Binary Size

| Version | .bin Size | Diff |
|---------|-----------|------|
| **C** | 223,088 bytes (217.9 KB) | baseline |
| **Zig** | 230,768 bytes (225.4 KB) | **+3.4%** |

### Memory Usage (Static)

| Memory Region | C | Zig | Diff |
|---------------|---|-----|------|
| **IRAM** | 16,383 bytes | 16,383 bytes | 0% |
| **DRAM** | 59,027 bytes | 59,019 bytes | -0.01% |
| **Flash Code** | 103,324 bytes | 110,948 bytes | +7.4% |

> Note: DRAM usage is nearly identical. The Flash Code increase (~7.6KB) is due to Zig's `std.fmt` integer formatting code used by `std.log`.

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

## Key Finding

The **~3.4%** binary size overhead from `std.log` comes from:
1. `std.fmt` integer formatting code (~7.6KB)
2. Zig's comptime format string validation

**Important**: Previous 14.1% overhead was due to incorrect sdkconfig (using `CONFIG_COMPILER_OPTIMIZATION_DEBUG=y` instead of `CONFIG_COMPILER_OPTIMIZATION_SIZE=y`).

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
