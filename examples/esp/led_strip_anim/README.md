# LED Strip Animation Example

Demonstrates the LED Strip HAL abstraction with keyframe-based animations and easing support.

## Features

- Comptime-defined animations (breathing, flash, chase, rainbow)
- Runtime-created animations (volume indicator, pulse)
- Multiple easing curves (linear, ease-in, ease-out, cubic)
- Overlay support for temporary effects
- Independent brightness control

## Supported Boards

| Board | LED GPIO | LED Count | Config |
|-------|----------|-----------|--------|
| ESP32-S3-DevKitC | 48 | 1 | `idf.boards.esp32s3_devkit` |
| ESP32-S3-Korvo-2 V3 | 19 | 1 | `idf.boards.korvo2_v3` |

> Note: Both boards have only 1 LED. For multi-LED animations (chase, rainbow), 
> you need a board with LED strip (e.g., WS2812 strip).

To switch boards, edit `main/src/board.zig`:

```zig
const hw = idf.boards.esp32s3_devkit;  // or idf.boards.korvo2_v3
```

## Build & Flash

```bash
cd ~/esp/esp-adf && source ./export.sh
cd examples/esp/led_strip_anim/zig

# DevKit
idf.py build && idf.py -p /dev/cu.usbmodem1301 flash

# Korvo-2 V3
idf.py build && idf.py -p /dev/cu.usbserial-120 flash
```

## Memory Usage

### ESP32-S3 DevKitC (with 8MB PSRAM)

**Binary Size:** 239 KB (0x3a700 bytes), 77% flash free

| Stage | Internal RAM | PSRAM | DMA | Stack |
|-------|--------------|-------|-----|-------|
| Boot | 371KB/425KB (87%) | 8189KB/8192KB | 364KB/417KB | ~2592/8192 |
| After LED Init | 371KB/425KB | 8188KB/8192KB | 363KB/417KB | ~2720/8192 |
| After HAL Init | 371KB/425KB | 8188KB/8192KB | 363KB/417KB | ~2720/8192 |
| Running | 371KB/425KB | - | - | ~2720/8192 |

**Key Metrics:**
- Internal RAM: 87% free (371KB / 425KB)
- Stack usage: ~33% (2720 / 8192 bytes)
- Largest free block: 280KB
- HAL Controller overhead: ~128 bytes

### Notes

- Memory usage is very stable during runtime
- No memory leaks observed during animation cycling
- PSRAM available for large buffers if needed

## Easing Curves

| Easing | Description |
|--------|-------------|
| `none` | Instant switch (no transition) |
| `linear` | Linear interpolation |
| `ease_in` | Slow start (quadratic) |
| `ease_out` | Slow end (quadratic) |
| `ease_in_out` | Slow start and end (quadratic) |
| `cubic_in` | Slower start (cubic) |
| `cubic_out` | Slower end (cubic) |
| `cubic_in_out` | Slow start and end (cubic) |

## Demo Modes

The example cycles through these modes (5 seconds each):

1. **Breathing** - Red color with smooth fade in/out (ease_in_out)
2. **Flash** - White quick blink (no easing)
3. **Chase** - Green dot moving around
4. **Rainbow** - Rotating rainbow colors
5. **Volume** - Dynamic volume indicator (0-100%)
6. **Pulse** - 3x blue pulse
7. **Solid** - Static cyan color
