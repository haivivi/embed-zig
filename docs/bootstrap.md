# Getting Started

[中文](./bootstrap.zh-CN.md) | English

## TL;DR

```bash
# 1. Download Zig with Xtensa support
curl -LO https://github.com/haivivi/embed-zig/releases/download/zig-0.14.0-xtensa/zig-aarch64-macos-none-baseline.tar.xz
tar -xJf zig-aarch64-macos-none-baseline.tar.xz
export PATH=$PWD/zig-aarch64-macos-none-baseline:$PATH

# 2. Set up ESP-IDF
cd ~/esp/esp-idf && source export.sh

# 3. Build and flash an example
cd examples/esp/led_strip_flash/zig
idf.py build && idf.py flash monitor
```

That's it. Your LED should be blinking.

---

## Detailed Setup

### 1. Pre-built Zig Compiler

Standard Zig doesn't support Xtensa (ESP32's architecture). Download our pre-built version:

| Platform | Download |
|----------|----------|
| macOS ARM64 | `zig-aarch64-macos-none-baseline.tar.xz` |
| macOS x86_64 | `zig-x86_64-macos-none-baseline.tar.xz` |
| Linux x86_64 | `zig-x86_64-linux-gnu-baseline.tar.xz` |
| Linux ARM64 | `zig-aarch64-linux-gnu-baseline.tar.xz` |

[Download from GitHub Releases →](https://github.com/haivivi/embed-zig/releases)

```bash
# Verify Xtensa support
zig targets | grep xtensa
# Should show: xtensa-esp32, xtensa-esp32s2, xtensa-esp32s3
```

### 2. ESP-IDF Environment

embed-zig integrates with ESP-IDF. Install it first:

```bash
# Clone ESP-IDF (v5.x recommended)
mkdir -p ~/esp && cd ~/esp
git clone --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32s3

# Activate environment (required for each terminal session)
source ~/esp/esp-idf/export.sh
```

### 3. Clone This Repository

```bash
git clone https://github.com/haivivi/embed-zig.git
cd embed-zig
```

### 4. Build an Example

```bash
cd examples/esp/led_strip_flash/zig

# Set target chip
idf.py set-target esp32s3

# Build
idf.py build

# Flash and monitor
idf.py -p /dev/cu.usbmodem1301 flash monitor
# Press Ctrl+] to exit monitor
```

---

## Board Selection

Many examples support multiple boards. Use `-DZIG_BOARD` to select:

```bash
# ESP32-S3-DevKitC (default)
idf.py build

# ESP32-S3-Korvo-2 V3.1
idf.py -DZIG_BOARD=korvo2_v3 build
```

| Board | Parameter | Features |
|-------|-----------|----------|
| ESP32-S3-DevKitC | `esp32s3_devkit` | GPIO button, single LED |
| ESP32-S3-Korvo-2 | `korvo2_v3` | ADC buttons, RGB LED strip |

---

## Using as a Dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .hal = .{
        .url = "https://github.com/haivivi/embed-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",  // Run zig build to get the hash
    },
    .esp = .{
        .url = "https://github.com/haivivi/embed-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

In your `build.zig`:

```zig
const hal = b.dependency("hal", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hal", hal.module("hal"));
```

---

## Troubleshooting

### "xtensa-esp32s3-elf-gcc not found"

ESP-IDF environment not activated:
```bash
source ~/esp/esp-idf/export.sh
```

### "Stack overflow in main task"

Increase stack size in `sdkconfig.defaults`:
```
CONFIG_ESP_MAIN_TASK_STACK_SIZE=8192
```

Then rebuild:
```bash
rm sdkconfig && idf.py fullclean && idf.py build
```

### "sdkconfig.defaults changes not applied"

```bash
rm sdkconfig && idf.py fullclean && idf.py build
```

### Zig cache issues

```bash
rm -rf .zig-cache build
idf.py fullclean && idf.py build
```

---

## Why a Custom Zig Compiler?

Zig's official releases don't include Xtensa backend support. ESP32 (original), ESP32-S2, and ESP32-S3 use Xtensa cores.

We maintain a fork that:
1. Merges Espressif's LLVM Xtensa patches
2. Builds Zig against this patched LLVM
3. Provides pre-built binaries for common platforms

ESP32-C3/C6 use RISC-V and work with standard Zig. But for Xtensa chips, you need our build.

See [bootstrap/](https://github.com/haivivi/embed-zig/tree/main/bootstrap) for build scripts if you want to compile it yourself.
