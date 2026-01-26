# Examples

[中文](./examples.zh-CN.md) | English

All examples live in `examples/`. Each demonstrates specific HAL components or ESP-IDF features.

## Quick Reference

| Example | Description | HAL Components | Boards |
|---------|-------------|----------------|:------:|
| [gpio_button](#gpio_button) | Button input with LED toggle | Button, LedStrip | ①②③ |
| [led_strip_flash](#led_strip_flash) | RGB LED strip blinking | LedStrip | ①②③ |
| [led_strip_anim](#led_strip_anim) | LED animation effects | LedStrip | ①②③ |
| [adc_button](#adc_button) | ADC-based button matrix | ButtonGroup | ② |
| [timer_callback](#timer_callback) | Hardware timer callbacks | LedStrip + idf.timer | ① |
| [pwm_fade](#pwm_fade) | LED brightness fading | Led (PWM) | ① |
| [temperature_sensor](#temperature_sensor) | Internal temp sensor | TempSensor | ①② |
| [nvs_storage](#nvs_storage) | Persistent key-value storage | Kvs | ①② |
| [wifi_dns_lookup](#wifi_dns_lookup) | WiFi + DNS resolution | (direct idf) | ①② |
| [http_speed_test](#http_speed_test) | HTTP download benchmark | (direct idf) | ①② |
| [memory_attr_test](#memory_attr_test) | PSRAM/IRAM placement | (direct idf) | ①② |

> ① ESP32-S3-DevKit　② Korvo-2 V3.1　③ Raylib Simulator

---

## Running Examples

### ESP32 (Hardware)

```bash
cd examples/esp/<example>/zig
idf.py set-target esp32s3
idf.py build
idf.py -p <PORT> flash monitor
```

**Board Selection:**

```bash
# DevKit (default)
idf.py build

# Korvo-2
idf.py -DZIG_BOARD=korvo2_v3 build
```

**Common Ports:**

| Board | Port (macOS) |
|-------|--------------|
| ESP32-S3-DevKit | `/dev/cu.usbmodem1301` |
| Korvo-2 V3.1 | `/dev/cu.usbserial-120` |

### Desktop Simulation (Raylib)

```bash
cd examples/raysim/<example>
zig build run
```

No hardware needed. GUI window simulates buttons and LEDs.

---

## HAL Examples

### gpio_button

Button press toggles LED. Demonstrates event-driven architecture.

**ESP32:**
```bash
cd examples/esp/gpio_button/zig
idf.py -DZIG_BOARD=esp32s3_devkit build
idf.py -p /dev/cu.usbmodem1301 flash monitor
```

**Simulation:**
```bash
cd examples/raysim/gpio_button
zig build run
```

**What it shows:**
- `hal.Button` with debounce
- `hal.LedStrip` control
- `Board.poll()` + `Board.nextEvent()` pattern

### led_strip_flash

Simple RGB LED blinking at 1Hz.

**ESP32:**
```bash
cd examples/esp/led_strip_flash/zig
idf.py build && idf.py flash monitor
```

**Simulation:**
```bash
cd examples/raysim/led_strip_flash
zig build run
```

**What it shows:**
- `hal.LedStrip` basic usage
- Color manipulation

### led_strip_anim

Rainbow and breathing animations on RGB LED strip.

**ESP32:**
```bash
cd examples/esp/led_strip_anim/zig
idf.py build && idf.py flash monitor
```

**Simulation:**
```bash
cd examples/raysim/led_strip_anim
zig build run
```

**What it shows:**
- Animation state machines
- HSV color space
- Frame timing

### adc_button

Multiple buttons through single ADC pin (voltage divider).

```bash
cd examples/esp/adc_button/zig
idf.py -DZIG_BOARD=korvo2_v3 build
idf.py -p /dev/cu.usbserial-120 flash monitor
```

**What it shows:**
- `hal.ButtonGroup` for ADC buttons
- Voltage threshold configuration
- Korvo-2 board support

**Note:** Only works on boards with ADC button matrix (Korvo-2).

### timer_callback

Hardware timer triggers LED toggle.

```bash
cd examples/esp/timer_callback/zig
idf.py build && idf.py flash monitor
```

**What it shows:**
- `idf.timer` integration
- Callback function registration
- HAL + direct IDF mixing

### pwm_fade

LED brightness fading using PWM.

```bash
cd examples/esp/pwm_fade/zig
idf.py build && idf.py flash monitor
```

**What it shows:**
- `hal.Led` with PWM
- Hardware fade support
- Brightness control (0-65535)

**Note:** Uses GPIO48 LED on DevKit.

### temperature_sensor

Read internal temperature sensor.

```bash
cd examples/esp/temperature_sensor/zig
idf.py build && idf.py flash monitor
```

**What it shows:**
- `hal.TempSensor` usage
- Periodic sensor reading
- Temperature in Celsius

### nvs_storage

Persistent storage with boot counter.

```bash
cd examples/esp/nvs_storage/zig
idf.py build && idf.py flash monitor
```

**What it shows:**
- `hal.Kvs` for NVS access
- Read/write u32 values
- Data persists across reboots

---

## ESP-specific Examples

These examples use ESP-IDF directly without HAL abstraction.

### wifi_dns_lookup

Connect to WiFi and resolve DNS.

```bash
cd examples/esp/wifi_dns_lookup/zig
# Edit sdkconfig.defaults with your WiFi credentials
idf.py build && idf.py flash monitor
```

**Configuration:** Set WiFi SSID/password in `sdkconfig.defaults`:
```
CONFIG_WIFI_SSID="YourNetwork"
CONFIG_WIFI_PASSWORD="YourPassword"
```

### http_speed_test

HTTP download speed measurement.

```bash
cd examples/esp/http_speed_test/zig
# Edit sdkconfig.defaults with your WiFi credentials
idf.py build && idf.py flash monitor
```

**What it shows:**
- HTTP client usage
- Download speed calculation
- Network performance testing

### memory_attr_test

Test PSRAM and IRAM memory placement.

```bash
cd examples/esp/memory_attr_test/zig
idf.py build && idf.py flash monitor
```

**What it shows:**
- `linksection` for memory placement
- PSRAM allocation
- IRAM for performance-critical code

---

## Project Structure

```
examples/
├── apps/<name>/              # Platform-independent app logic
│   ├── app.zig               # Main application
│   ├── platform.zig          # HAL spec + Board type
│   └── boards/               # Board-specific drivers
│       ├── esp32s3_devkit.zig
│       ├── korvo2_v3.zig
│       └── sim_raylib.zig    # Desktop simulation
├── esp/<name>/zig/           # ESP32 entry point
│   └── main/
│       ├── src/main.zig
│       ├── build.zig
│       └── CMakeLists.txt
└── raysim/<name>/            # Desktop simulation entry point
    ├── src/main.zig
    └── build.zig
```

This separation allows the same `app.zig` to run on ESP32 hardware or desktop simulation with Raylib GUI.
