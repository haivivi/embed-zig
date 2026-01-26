# ESP32 Examples

ESP-IDF examples written in Zig using HAL v5 architecture.

## Supported Boards

| Board | Chip | PSRAM | Notes |
|-------|------|-------|-------|
| **ESP32-S3-DevKitC-1** | ESP32-S3 | 8MB Octal | Default board |
| **ESP32-S3-Korvo-2 V3** | ESP32-S3 | 8MB | Audio dev board |

## Architecture

Examples use HAL v5 architecture for board-agnostic code:

```
examples/
├── apps/                     # Platform-independent app code
│   └── <example>/
│       ├── app.zig           # Main logic (no esp imports)
│       ├── platform.zig      # HAL spec + board selection
│       └── boards/           # BSP implementations
│           ├── esp32s3_devkit.zig
│           └── korvo2_v3.zig
└── esp/                      # ESP entry points
    └── <example>/
        └── zig/main/
            ├── src/main.zig  # Minimal entry point
            └── build.zig     # Build with -Dboard option
```

## Examples

### HAL Examples (Multi-board)

| Example | Description | HAL Peripherals |
|---------|-------------|-----------------|
| [gpio_button](./gpio_button/) | Button input with debounce | Button |
| [led_strip_flash](./led_strip_flash/) | WS2812 LED strip control | RgbLedStrip |
| [led_strip_anim](./led_strip_anim/) | LED animation effects | RgbLedStrip |
| [adc_button](./adc_button/) | ADC button matrix | ButtonGroup |
| [timer_callback](./timer_callback/) | Hardware timer callbacks | RtcReader |
| [pwm_fade](./pwm_fade/) | LED fade with PWM | Led |
| [temperature_sensor](./temperature_sensor/) | Internal temp sensor | TempSensor |
| [nvs_storage](./nvs_storage/) | Key-value storage | Kvs |

### ESP-specific Examples

| Example | Description |
|---------|-------------|
| [http_speed_test](./http_speed_test/) | HTTP download speed test |
| [wifi_dns_lookup](./wifi_dns_lookup/) | DNS resolution over WiFi |
| [memory_attr_test](./memory_attr_test/) | PSRAM/IRAM placement test |

## Build & Flash

```bash
# Setup ESP-IDF environment
cd ~/esp/esp-idf && source export.sh

# Navigate to example
cd examples/esp/led_strip_flash/zig

# Set target (first time only)
idf.py set-target esp32s3

# Build (default board)
idf.py build

# Build for specific board
idf.py build -- -DZIG_BOARD=korvo2_v3

# Flash and monitor
idf.py -p /dev/cu.usbmodem* flash monitor
```

## WiFi Configuration

For WiFi examples, configure SSID and password:

```bash
idf.py menuconfig
# Navigate to: WiFi Configuration
# Set WIFI_SSID and WIFI_PASSWORD
```

Or edit `sdkconfig.defaults`:

```
CONFIG_WIFI_SSID="your_ssid"
CONFIG_WIFI_PASSWORD="your_password"
```

## Adding New Boards

1. Create BSP file in `examples/apps/<example>/boards/<board>.zig`
2. Implement drivers for all HAL peripherals used by the example
3. Add board to `BoardType` enum in `build.zig`
4. Add board case in `platform.zig`
