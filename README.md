# Espressif Zig Bootstrap

[中文文档](./README.zh-CN.md) | English

This project is based on `ziglang/zig-bootstrap`, replacing `llvm/llvm-project` with `espressif/llvm-project` to enable Xtensa support for ESP32 development.

## Key Improvements

1. **Version Control**: Uses `wget` to fetch source code, ensuring dependency versions are locked and reproducible
2. **Transparent Patches**: Uses `patch` files to modify code, making all changes explicit and reviewable

## Platform Support

Currently tested on **macOS** only. Linux builds should work in theory but haven't been tested yet.

## Quick Start

### Build the Compiler

```bash
CMAKE_BUILD_PARALLEL_LEVEL=16 ./bootstrap.sh espressif-0.15.x aarch64-macos-none baseline
```

**Available versions:**
- `espressif-0.14.x` - Zig 0.14.x with Xtensa support
- `espressif-0.15.x` - Zig 0.15.x with Xtensa support (recommended)

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
cd examples/led_strip_flash

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
    └── led_strip_flash/      # LED strip example with Zig
```

## What Gets Built

After running the bootstrap script, you'll have:

- A Zig compiler with Xtensa support at: `espressif-0.15.x/.out/zig-<target>-<mcpu>/bin/zig`
- LLVM with Espressif's Xtensa backend enabled
- All necessary libraries and tools for ESP32 development

## Environment Setup

To use the built compiler with ESP-IDF:

```bash
export ZIG_INSTALL=/path/to/espressif-zig-bootstrap/espressif-0.15.x/.out/zig-aarch64-macos-none-baseline/bin
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
