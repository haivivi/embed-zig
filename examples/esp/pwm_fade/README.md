# PWM Fade (Breathing LED)

[中文版](README.zh-CN.md)

LEDC PWM example with hardware fade function for breathing LED effect.

## Features

- Configure LEDC timer and channel
- Hardware fade for smooth transitions
- 2 second fade up, 2 second fade down
- Continuous breathing cycle

## Hardware

- ESP32-S3-DevKitC-1
- **Optional**: External LED with resistor on GPIO2

Note: The onboard WS2812 RGB LED uses a specific protocol and cannot be controlled with simple PWM. This example outputs PWM on GPIO2. You can:
1. Connect an external LED to GPIO2
2. Use an oscilloscope to observe the PWM waveform
3. Just observe the serial output

## Configuration

- PWM GPIO: 2
- Frequency: 5000 Hz
- Resolution: 13-bit (0-8191 duty range)
- Fade time: 2000ms per direction

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
PWM Fade Example - Zig Version
==========================================
LEDC initialized. Starting breathing effect...
Cycle 1: Fading up...
Cycle 1: Fading down...
Cycle 2: Fading up...
Cycle 2: Fading down...
...
```

## C vs Zig Comparison

### Binary Size

| Version | .bin Size | Diff |
|---------|-----------|------|
| **C** | 206,208 bytes (201.4 KB) | baseline |
| **Zig** | 215,440 bytes (210.4 KB) | **+4.4%** |

### Memory Usage (Static)

| Memory Region | C | Zig | Diff |
|---------------|---|-----|------|
| **Flash Code** | 94,556 bytes | 103,112 bytes | +9.1% |
| **DRAM** | 54,315 bytes | 54,307 bytes | **-0.01%** ✅ |
| **Flash Data** | 43,216 bytes | 43,900 bytes | +1.6% |
