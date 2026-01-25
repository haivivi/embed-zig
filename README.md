# embed-zig

[中文文档](./README.zh-CN.md) | English

Zig libraries for embedded development, with ESP32 support via Espressif's LLVM fork.

📚 **[Documentation](https://haivivi.github.io/embed-zig/)**

## Features

- **ESP-IDF Bindings** - Idiomatic Zig wrappers for ESP-IDF APIs
- **System Abstraction Layer** - Cross-platform thread, sync, and time primitives
- **Pre-built Zig Compiler** - Zig with Xtensa support for ESP32

## Quick Start

### Using the Library

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .esp = .{
        .url = "https://github.com/haivivi/embed-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

Use in your code:

```zig
const esp = @import("esp");

pub fn main() !void {
    // GPIO
    try esp.gpio.configOutput(48);
    try esp.gpio.setLevel(48, 1);

    // WiFi
    var wifi = try esp.Wifi.init();
    try wifi.connect(.{ .ssid = "MyNetwork", .password = "secret" });

    // Timer
    var timer = try esp.Timer.init(.{ .callback = myCallback });
    try timer.start(1000000); // 1 second
}
```

## Pre-built Zig Compiler

Download Zig with Xtensa support from [GitHub Releases](https://github.com/haivivi/embed-zig/releases).

| Platform | Download |
|----------|----------|
| macOS ARM64 | `zig-aarch64-macos-none-baseline.tar.xz` |
| macOS x86_64 | `zig-x86_64-macos-none-baseline.tar.xz` |
| Linux x86_64 | `zig-x86_64-linux-gnu-baseline.tar.xz` |
| Linux ARM64 | `zig-aarch64-linux-gnu-baseline.tar.xz` |

```bash
# Download and extract (example for macOS ARM64)
curl -LO https://github.com/haivivi/embed-zig/releases/download/espressif-0.15.2/zig-aarch64-macos-none-baseline.tar.xz
tar -xJf zig-aarch64-macos-none-baseline.tar.xz

# Verify Xtensa support
./zig-aarch64-macos-none-baseline/zig targets | grep xtensa
```

## Library Modules

### ESP (`esp`)

ESP-IDF bindings:

| Module | Description |
|--------|-------------|
| `gpio` | Digital I/O control |
| `wifi` | WiFi station mode |
| `http` | HTTP client |
| `nvs` | Non-volatile storage |
| `timer` | Hardware timers |
| `led_strip` | Addressable LED control |
| `adc` | Analog-to-digital conversion |
| `ledc` | PWM generation |
| `sal` | System abstraction (FreeRTOS) |

### SAL (`sal`)

Cross-platform abstractions:

| Module | Description |
|--------|-------------|
| `thread` | Task/thread management |
| `sync` | Mutex, Semaphore, Event |
| `time` | Sleep and delay functions |

## Examples

See the [`examples/`](./examples/) directory:

| Example | Description |
|---------|-------------|
| `gpio_button` | Button input with interrupt |
| `led_strip_flash` | WS2812 LED strip control |
| `http_speed_test` | HTTP download speed test |
| `wifi_dns_lookup` | DNS resolution over WiFi |
| `timer_callback` | Hardware timer callbacks |
| `nvs_storage` | Non-volatile storage |
| `pwm_fade` | LED fade with PWM |
| `temperature_sensor` | Internal temp sensor |

### Running Examples

```bash
# 1. Set up ESP-IDF environment
cd ~/esp/esp-idf && source export.sh

# 2. Navigate to example
cd examples/esp/led_strip_flash/zig

# 3. Set target chip
idf.py set-target esp32s3

# 4. Build and flash
idf.py build
idf.py flash monitor
```

## Building the Compiler

To build Zig with Xtensa support from source:

```bash
cd bootstrap
./bootstrap.sh esp/0.15.2 <target> baseline
```

**Targets:**
- `aarch64-macos-none` - macOS ARM64
- `x86_64-macos-none` - macOS x86_64
- `x86_64-linux-gnu` - Linux x86_64
- `aarch64-linux-gnu` - Linux ARM64

## Project Structure

```
embed-zig/
├── lib/
│   ├── esp/              # ESP-IDF bindings
│   │   └── src/
│   │       ├── gpio.zig
│   │       ├── wifi/
│   │       ├── http.zig
│   │       └── ...
│   └── sal/              # System Abstraction Layer
│       └── src/
│           ├── thread.zig
│           ├── sync.zig
│           └── time.zig
├── examples/
│   └── esp/              # ESP32 examples
├── bootstrap/
│   └── esp/              # Compiler build scripts
│       ├── 0.14.0/
│       └── 0.15.2/
└── README.md
```

## License

This project includes patches and build scripts for:
- Zig Programming Language
- LLVM Project (Espressif fork)

Please refer to the respective upstream projects for their licenses.

## Acknowledgments

- [ziglang/zig-bootstrap](https://github.com/ziglang/zig-bootstrap)
- [espressif/llvm-project](https://github.com/espressif/llvm-project)
- [ESP-IDF](https://github.com/espressif/esp-idf)
- [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)
