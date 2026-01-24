# GPIO Button

[中文版](README.zh-CN.md)

GPIO input/output example demonstrating button reading and LED control.

## Features

- Read Boot button state (GPIO0, active low)
- Control onboard RGB LED (GPIO48)
- Button press toggles LED on/off
- Debounce handling

## Hardware

- ESP32-S3-DevKitC-1
- Built-in Boot button on GPIO0
- Built-in WS2812 RGB LED on GPIO48

No external hardware required!

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

## Usage

1. Flash the firmware
2. Press the Boot button
3. LED toggles between ON (white) and OFF
4. Watch serial output for press count

## C vs Zig Comparison

### Binary Size

| Version | .bin Size | Diff |
|---------|-----------|------|
| **C** | 225,504 bytes (220.2 KB) | baseline |
| **Zig** | 233,600 bytes (228.1 KB) | **+3.5%** |

### Memory Usage (Static)

| Memory Region | C | Zig | Diff |
|---------------|---|-----|------|
| **Flash Code** | 105,464 bytes | 112,452 bytes | +6.6% |
| **DRAM** | 59,027 bytes | 59,019 bytes | **-0.01%** ✅ |
| **Flash Data** | 46,856 bytes | 47,972 bytes | +2.4% |

### Expected Output

```
==========================================
GPIO Button Example - Zig Version
==========================================
Press Boot button to toggle LED
GPIO initialized. Button=GPIO0, LED=GPIO48
Button pressed! Count=1, LED=ON
Button pressed! Count=2, LED=OFF
Button pressed! Count=3, LED=ON
...
```
