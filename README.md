# embed-zig

[中文](./README.zh-CN.md) | English

 

**Zig libraries for embedded development.**

*From bare metal to application layer, from ESP32 to desktop simulation,*
*one language, one abstraction, everywhere.*

 

🌐 **https://embed.giztoy.com**

[Documentation](https://embed.giztoy.com/docs/) · [API Reference](https://embed.giztoy.com/api/) · [Examples](./examples/)

---

## Overview

embed-zig provides a unified development experience for embedded systems. Write your application logic once — run it on ESP32 hardware today, simulate it on your desktop tomorrow.

### Key Features

- **HAL** — Board-agnostic hardware abstraction (buttons, LEDs, sensors)
- **Trait** — Interface contracts for cross-platform abstractions
- **ESP** — Idiomatic Zig bindings for ESP-IDF
- **Raysim** — Desktop simulation with Raylib GUI
- **Pre-built Zig** — Compiler with Xtensa support for ESP32

---

## Quick Start

```bash
# Download Zig with Xtensa support
curl -LO https://github.com/haivivi/embed-zig/releases/download/zig-0.14.0-xtensa/zig-aarch64-macos-none-baseline.tar.xz
tar -xJf zig-aarch64-macos-none-baseline.tar.xz && export PATH=$PWD/zig-aarch64-macos-none-baseline:$PATH

# Set up ESP-IDF and build an example
cd ~/esp/esp-idf && source export.sh
cd examples/esp/led_strip_flash/zig && idf.py build && idf.py flash monitor
```

Or run in simulation (no hardware needed):

```bash
cd examples/raysim/gpio_button && zig build run
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [Introduction](./docs/intro.md) | Project vision, philosophy, and design goals |
| [Getting Started](./docs/bootstrap.md) | Setup guide, compilation, troubleshooting |
| [Examples](./docs/examples.md) | Example catalog with run commands |
| [Architecture](./docs/design.md) | SAL / HAL / ESP / Raysim design |

---

## Supported Platforms

| Platform | Status | Notes |
|----------|:------:|-------|
| ESP32-S3-DevKit | ✅ | GPIO button, single LED |
| ESP32-S3-Korvo-2 | ✅ | ADC buttons, RGB LED strip |
| Raylib Simulator | ✅ | Desktop GUI simulation |
| ESP32-C3/C6 (RISC-V) | 🚧 | Standard Zig works |

---

## Project Structure

```
embed-zig/
├── lib/
│   ├── hal/          # Hardware Abstraction Layer
│   ├── trait/        # Interface contracts (log, time, socket, tls, i2c)
│   ├── esp/          # ESP-IDF bindings + trait impl
│   └── raysim/       # Raylib simulation + trait impl
├── examples/
│   ├── apps/         # Platform-independent app logic
│   ├── esp/          # ESP32 entry points
│   └── raysim/       # Desktop simulation entry points
└── bootstrap/        # Zig compiler build scripts
```

---

## License

Apache License 2.0. See [LICENSE](./LICENSE).

This project includes patches for Zig and LLVM (Espressif fork). Please refer to the respective upstream projects for their licenses.

---

## Acknowledgments

- [ziglang/zig-bootstrap](https://github.com/ziglang/zig-bootstrap)
- [espressif/llvm-project](https://github.com/espressif/llvm-project)
- [ESP-IDF](https://github.com/espressif/esp-idf)
- [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)

---

 

*"The universe is built on layers of abstraction. So is good software."*

 
