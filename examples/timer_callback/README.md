# Timer Callback

[中文版](README.zh-CN.md)

Hardware timer (GPTimer) example with interrupt callback.

## Features

- Create hardware timer with 1MHz resolution (1us per tick)
- 1 second periodic alarm with auto-reload
- Timer ISR sets flag, main loop updates LED (ISR-safe pattern)
- Precise timing independent of FreeRTOS tick

## Hardware

- ESP32-S3-DevKitC-1
- Built-in WS2812 RGB LED on GPIO48

No external hardware required!

## How It Works

The GPTimer is configured to:
1. Run at 1MHz (1 microsecond per count)
2. Trigger alarm at 1,000,000 counts (1 second)
3. Auto-reload to 0 after alarm
4. Call ISR callback on each alarm

The LED toggles red on/off every second.

## Build

```bash
# Zig version
cd zig
idf.py set-target esp32s3
idf.py build flash monitor

# C version
cd c
idf.py set-target esp32s3
idf.py build flash monitor
```

## Expected Output

```
==========================================
Hardware Timer Example - Zig Version
==========================================
Timer started! LED toggles every 1 second
Timer resolution: 1MHz (1us per tick)
Timer tick #1, LED=ON
Timer tick #2, LED=OFF
Timer tick #3, LED=ON
...
```

## C vs Zig Comparison

### Binary Size

| Version | .bin Size | Diff |
|---------|-----------|------|
| **C** | 226,864 bytes (221.5 KB) | baseline |
| **Zig** | 236,464 bytes (230.9 KB) | **+4.2%** |

### Memory Usage (Static)

| Memory Region | C | Zig | Diff |
|---------------|---|-----|------|
| **Flash Code** | 105,892 bytes | 114,516 bytes | +8.1% |
| **DRAM** | 59,319 bytes | 59,247 bytes | **-0.1%** ✅ |
| **Flash Data** | 47,520 bytes | 48,572 bytes | +2.2% |

## ISR Best Practice

**Important**: LED strip operations (RMT driver) cannot run in ISR context. Both C and Zig versions use the pattern:
1. ISR only updates flags (`led_changed = true`)
2. Main loop checks flag and updates LED
