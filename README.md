# Espressif Zig Bootstrap

[中文文档](./README.zh-CN.md) | English

This project is based on `ziglang/zig-bootstrap`, replacing `llvm/llvm-project` with `espressif/llvm-project` to enable Xtensa support for ESP32 development.

## Pre-built Downloads

You can download pre-built Zig compilers with Xtensa support from [GitHub Releases](https://github.com/haivivi/zig-bootstrap/releases).

| Platform | Download |
|----------|----------|
| macOS ARM64 | `zig-aarch64-macos-none-baseline.tar.xz` |
| macOS x86_64 | `zig-x86_64-macos-none-baseline.tar.xz` |
| Linux x86_64 | `zig-x86_64-linux-gnu-baseline.tar.xz` |
| Linux ARM64 | `zig-aarch64-linux-gnu-baseline.tar.xz` |

```bash
# Download and extract (example for macOS ARM64)
curl -LO https://github.com/haivivi/zig-bootstrap/releases/download/espressif-0.15.2/zig-aarch64-macos-none-baseline.tar.xz
tar -xJf zig-aarch64-macos-none-baseline.tar.xz

# Verify Xtensa support
./zig-aarch64-macos-none-baseline/zig targets | grep xtensa
```

## Key Improvements

1. **Version Control**: Uses `wget` to fetch source code, ensuring dependency versions are locked and reproducible
2. **Transparent Patches**: Uses `patch` files to modify code, making all changes explicit and reviewable
3. **Cross-compilation**: Supports building Linux binaries from macOS

## Platform Support

| Host Platform | Status |
|---------------|--------|
| macOS ARM64 | ✅ Tested |
| macOS x86_64 | ✅ Tested |
| Linux x86_64 | ✅ Supported (cross-compiled from macOS) |
| Linux ARM64 | ✅ Supported (cross-compiled from macOS) |

## Quick Start

### Build the Compiler

```bash
./bootstrap.sh espressif-0.15.x <target> baseline
```

**Available targets:**
- `aarch64-macos-none` - macOS ARM64
- `x86_64-macos-none` - macOS x86_64
- `x86_64-linux-gnu` - Linux x86_64
- `aarch64-linux-gnu` - Linux ARM64

**Available versions:**
- `espressif-0.14.x` - Zig 0.14.x with Xtensa support
- `espressif-0.15.x` - Zig 0.15.x with Xtensa support (recommended)

The script automatically detects CPU cores and uses up to 8 cores for parallel compilation.

### Run Examples

To build and run the examples (e.g., `led_strip_flash`):

```bash
# 1. Navigate to ESP-IDF installation
pushd PATH_TO_IDF

# 2. Set up ESP-IDF environment
. export.sh

# 3. Return to project directory
popd

# 4. Navigate to example directory
cd examples/led_strip_flash/zig

# 5. Set target chip
idf.py set-target esp32s3

# 6. (Optional) Configure project
idf.py menuconfig

# 7. Build and flash
idf.py build
idf.py flash monitor
```

## Project Structure

```
espressif-zig-bootstrap/
├── bootstrap.sh              # Bootstrap script
├── espressif-0.14.x/         # Zig 0.14.x support
│   ├── espressif.patch       # Patches for Xtensa support
│   ├── llvm-project          # URL to Espressif LLVM
│   └── zig-bootstrap         # URL to Zig bootstrap
├── espressif-0.15.x/         # Zig 0.15.x support (recommended)
│   ├── espressif.patch       # Patches for Xtensa support
│   ├── llvm-project          # URL to Espressif LLVM
│   └── zig-bootstrap         # URL to Zig bootstrap
└── examples/
    ├── led_strip_flash/      # LED strip example
    ├── gpio_button/          # GPIO button example
    ├── http_speed_test/      # HTTP speed test
    ├── memory_attr_test/     # Memory attribute test
    ├── wifi_dns_lookup/      # WiFi DNS lookup
    └── ...                   # More examples
```

## What Gets Built

After running the bootstrap script, you'll have:

- A Zig compiler with Xtensa support at: `espressif-0.15.x/.out/zig-<target>-baseline/zig`
- LLVM 20.1.1 with Espressif's Xtensa backend enabled
- Support for ESP32, ESP32-S2, ESP32-S3 targets

## Environment Setup

The examples use automatic Zig installation detection. If you need to manually specify the path:

```bash
export ZIG_INSTALL=/path/to/espressif-zig-bootstrap/espressif-0.15.x/.out/zig-aarch64-macos-none-baseline
```

## License

This project includes patches and build scripts for:
- Zig Programming Language
- LLVM Project (Espressif fork)
- Zig Bootstrap

Please refer to the respective upstream projects for their licenses.

## Acknowledgments

- [ziglang/zig-bootstrap](https://github.com/ziglang/zig-bootstrap)
- [espressif/llvm-project](https://github.com/espressif/llvm-project)
- [ESP-IDF](https://github.com/espressif/esp-idf)
- [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)
- [gpanders/esp32-zig-starter](https://github.com/gpanders/esp32-zig-starter)
- [kassane/zig-esp-idf-sample](https://github.com/kassane/zig-esp-idf-sample)
