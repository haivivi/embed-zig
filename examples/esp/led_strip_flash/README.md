# LED Strip Flash

[中文版](README.zh-CN.md)

ESP32-S3 LED strip blinking example using HAL v5 architecture.

## Features

- **HAL v5 Architecture** - Board-agnostic application code
- **Multi-board Support** - ESP32-S3-DevKit and Korvo-2 V3
- Control WS2812/SK6812 RGB LED strip
- Use ESP-IDF RMT driver
- Periodic blinking effect

## Architecture

```
examples/
├── apps/led_strip_flash/     # Platform-independent code
│   ├── app.zig               # Main application logic
│   ├── platform.zig          # HAL spec and board selection
│   └── boards/
│       ├── esp32s3_devkit.zig  # DevKit BSP
│       └── korvo2_v3.zig       # Korvo-2 BSP
└── esp/led_strip_flash/
    └── zig/main/
        ├── src/main.zig      # Minimal ESP entry point
        └── build.zig         # Build with -Dboard option
```

## Key Code

**app.zig** (Platform-independent):
```zig
const hal = @import("hal");
const platform = @import("platform.zig");
const Board = platform.Board;
const sal = platform.sal;

pub fn run() void {
    var board = Board.init() catch return;
    defer board.deinit();

    while (true) {
        board.rgb_leds.setColor(hal.Color.white);
        board.rgb_leds.refresh();
        sal.sleepMs(1000);

        board.rgb_leds.clear();
        board.rgb_leds.refresh();
        sal.sleepMs(1000);
    }
}
```

**main.zig** (ESP entry point):
```zig
const app = @import("app");

export fn app_main() void {
    app.run();
}
```

## Build

```bash
# Setup ESP-IDF
cd ~/esp/esp-idf && source export.sh

# Build for default board (ESP32-S3-DevKit)
cd examples/esp/led_strip_flash/zig
idf.py set-target esp32s3
idf.py build

# Build for Korvo-2 V3
idf.py build -- -DZIG_BOARD=korvo2_v3
```

## Flash

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```

## Supported Boards

| Board | LED Type | GPIO | LED Count |
|-------|----------|------|-----------|
| ESP32-S3-DevKit | WS2812 | 48 | 1 |
| Korvo-2 V3 | WS2812 | 45 | 12 |

## Configuration

Configure via `idf.py menuconfig`:
- `BLINK_GPIO`: LED data pin (default: 48)
- `BLINK_PERIOD`: Blink period (default: 1000ms)
