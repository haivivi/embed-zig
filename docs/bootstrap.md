# Getting Started

[中文](./bootstrap.zh-CN.md) | English

## Prerequisites

### 1. Install Bazel

```bash
# macOS
brew install bazel

# Linux (Ubuntu/Debian)
sudo apt install apt-transport-https curl gnupg
curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > bazel.gpg
sudo mv bazel.gpg /etc/apt/trusted.gpg.d/
echo "deb [arch=amd64] https://storage.googleapis.com/bazel-apt stable jdk1.8" | sudo tee /etc/apt/sources.list.d/bazel.list
sudo apt update && sudo apt install bazel
```

### 2. Install ESP-IDF

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
git clone https://github.com/haivivi/zig-bootstrap.git
cd zig-bootstrap
```

---

## Quick Start

```bash
# Activate ESP-IDF
source ~/esp/esp-idf/export.sh

# Build an example
bazel build //examples/apps/led_strip_flash:esp

# Flash to device
bazel run //examples/apps/led_strip_flash:flash --//bazel/esp:port=/dev/ttyUSB0
```

That's it. Your LED should be blinking.

---

## Build Commands

### Build

```bash
bazel build //examples/apps/<name>:esp
```

### Flash

```bash
bazel run //examples/apps/<name>:flash --//bazel/esp:port=/dev/ttyUSB0
```

### Board Selection

```bash
# ESP32-S3-DevKitC (default)
bazel build //examples/apps/gpio_button:esp

# ESP32-S3-Korvo-2 V3
bazel build //examples/apps/gpio_button:esp --//bazel/esp:board=korvo2_v3
```

| Board | Parameter | Features |
|-------|-----------|----------|
| ESP32-S3-DevKitC | `esp32s3_devkit` | GPIO button, single LED |
| ESP32-S3-Korvo-2 | `korvo2_v3` | ADC buttons, RGB LED strip, mic |

### Environment Variables (WiFi examples)

```bash
# Pass WiFi credentials
WIFI_PASSWORD=secret bazel build //examples/apps/wifi_dns_lookup:esp \
    --define WIFI_SSID=MyNetwork \
    --action_env=WIFI_PASSWORD
```

---

## Troubleshooting

### "xtensa-esp32s3-elf-gcc not found"

ESP-IDF environment not activated:
```bash
source ~/esp/esp-idf/export.sh
```

### Bazel cache issues

```bash
bazel clean --expunge
```

### Build errors after pulling updates

```bash
bazel clean
bazel build //examples/apps/<name>:esp
```

---

## Why Bazel?

- **Hermetic builds**: Zig toolchain is downloaded automatically
- **Caching**: Only recompile what changed
- **Cross-platform**: Same commands work on macOS and Linux
- **Reproducible**: Same source = same binary

The Zig compiler with Xtensa support is fetched automatically by Bazel - no manual download needed.

---

## Alternative: Direct idf.py

If you prefer using ESP-IDF directly:

```bash
cd examples/esp/led_strip_flash/zig
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

Note: This requires manually downloading the Xtensa Zig compiler.
