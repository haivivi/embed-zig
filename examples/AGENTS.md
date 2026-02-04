# Example App Structure

This document describes:

1. **Directory structure for examples** - All apps in `examples/apps/` should follow this layout
2. **App and platform organization** - How to structure platform-free code and platform-specific implementations
3. **Multi-variant data organization** - How to manage different data sets

**Use cases**:
- One product, multiple boards -> use `boards` list + `--//bazel:board`
- One product, multiple SKUs -> use `data_select` + `--//bazel:data`

---

## Directory Layout

```
examples/apps/{app_name}/
├── BUILD.bazel          # Shared app sources + data_select
├── app.zig              # Application logic
├── platform.zig         # Platform abstraction (imports board via build_options)
│
├── data/                # Shared assets (platform-independent), with variants
│   ├── tiga/            # First variant = default (e.g., H106 product)
│   │   ├── *.wav        # Audio files
│   │   ├── *.mp3
│   │   ├── *.ttf        # Fonts
│   │   ├── *.png        # Images
│   │   └── ...
│   └── zero/            # Another variant
│       └── ...
│
├── esp/                 # ESP32 platform
│   ├── BUILD.bazel      # ESP-specific Bazel rules
│   ├── build.zig        # Zig build script
│   ├── build.zig.zon    # Zig package dependencies
│   └── {board}.zig      # Board hardware config (e.g., esp32s3_devkit.zig, korvo2_v3.zig)
│
├── beken/               # Beken platform (BK72xx)
│   ├── BUILD.bazel
│   ├── build.zig
│   ├── build.zig.zon
│   └── {board}.zig      # e.g., bk7256.zig
│
└── simulator/           # Desktop simulator (for development/testing)
    ├── BUILD.bazel
    ├── build.zig
    └── build.zig.zon
```

## File Descriptions

### Root Level (Platform-Independent)

- **app.zig** - Main application code, uses `platform.zig` abstractions
- **platform.zig** - Platform abstraction layer, imports board hardware via `build_options.board`
- **BUILD.bazel** - Exports `app_srcs` filegroup and `data_select` for platform builds
- **data/** - Shared assets with variant support (audio, fonts, images, configs, etc.)

### Platform Directory (`esp/`, `beken/`, `simulator/`)

Each platform has its own subdirectory with platform-specific build configuration:

- **BUILD.bazel** - Platform-specific Bazel rules
- **build.zig** - Defines `BoardType` enum and build options (first board = default)
- **build.zig.zon** - Zig package dependencies (e.g., `esp`, `hal` or `beken`, `hal`)
- **{board}.zig** - Board hardware configuration (GPIO pins, ADC channels, peripherals, etc.)

### ESP Platform Rules (`esp/BUILD.bazel`)

- `esp_sdkconfig` - SDK configuration (CPU freq, flash, PSRAM, WiFi, etc.)
- `esp_app` - App runtime config (stack size, memory placement)
- `make_env_file` - Compile-time environment variables
- `esp_nvs_*` - NVS entries (string, u8, bool, etc.)
- `esp_nvs_image` - Generate NVS binary from entries
- `esp_spiffs_image` / `esp_littlefs_image` - Filesystem images
- `esp_partition_table` - Partition layout
- `esp_zig_app` - Application build
- `esp_flash` - Flash target

## Configuration Types

### Compile-time Environment (env)

Baked into firmware. Change requires reflashing app.

```python
make_env_file(
    name = "env",
    defines = ["WIFI_SSID", "WIFI_PASSWORD"],
    defaults = {"WIFI_SSID": "MyWiFi", "WIFI_PASSWORD": "12345678"},
)
```

Override: `--define WIFI_SSID=OtherWiFi`

### Runtime Storage (NVS)

Separate partition. Can update without reflashing app.

```python
esp_nvs_string(name = "nvs_sn", namespace = "device", key = "sn")
esp_nvs_u8(name = "nvs_hw_ver", namespace = "device", key = "hw_ver")
```

Override: `--define nvs_sn=H106-000001`

### Data Files (Filesystem)

Static assets packaged into SPIFFS or LittleFS image. Located at app root `data/` with variant subdirectories.

Supported file types: audio (wav, mp3), fonts (ttf, otf), images (png, jpg, bmp), text, JSON, binary, etc.

**App BUILD.bazel** - Define data variants (first = default):
```python
load("//bazel:data.bzl", "data_select")

data_select(
    name = "data_files",
    options = {
        "tiga": glob(["data/tiga/**"]),  # default (first)
        "zero": glob(["data/zero/**"]),
    },
)
```

**Platform BUILD.bazel** - Reference data:
```python
esp_spiffs_image(
    name = "storage_data",
    srcs = ["//examples/apps/{app_name}:data_files"],
    partition_size = "1M",
    strip_prefix = "examples/apps/{app_name}/data",  # auto-strips variant subdir
)
```

Select variant: `--//bazel:data=tiga`

## Partition Table Example

```python
esp_partition_entry(name = "part_nvs", partition_name = "nvs", type = "data", subtype = "nvs", partition_size = "24K", data = [":nvs_data"])
esp_partition_entry(name = "part_phy", partition_name = "phy_init", type = "data", subtype = "phy", partition_size = "4K")
esp_partition_entry(name = "part_factory", partition_name = "factory", type = "app", subtype = "factory", partition_size = "4M")
esp_partition_entry(name = "part_storage", partition_name = "storage", type = "data", subtype = "spiffs", partition_size = "1M", data = [":storage_data"])

esp_partition_table(
    name = "partitions",
    entries = [":part_nvs", ":part_phy", ":part_factory", ":part_storage"],
    flash_size = "8M",
)
```

## Build & Flash

```bash
# Build (uses first data variant as default)
bazel build //examples/apps/{app_name}/esp:app

# Build with specific data variant
bazel build //examples/apps/{app_name}/esp:app --//bazel:data=zero

# Flash with defaults
bazel run //examples/apps/{app_name}/esp:flash \
  --//bazel:port=/dev/cu.usbmodem2101

# Flash with all overrides
bazel run //examples/apps/{app_name}/esp:flash \
  --//bazel:port=/dev/cu.usbmodem2101 \
  --//bazel:data=zero \
  --define WIFI_SSID=MyWiFi \
  --define nvs_sn=H106-000001

# Monitor serial output
bazel run //bazel/esp:monitor --//bazel:port=/dev/cu.usbmodem2101
```

## Reference Example

See `examples/apps/adc_button/` for a complete implementation.
