# Development Guide

## 1. How-to Write

### Cross-Platform Lib

**Location**: `lib/{lib_name}/`

**Dependency Rules**:
- Can depend on `lib/trait`
- Can depend on `lib/hal`
- Can depend on other cross-platform libs in `lib/`
- **MUST NOT** depend on `lib/{platform}/` (e.g., `lib/esp/`, `lib/beken/`)
- **Avoid** `std` (freestanding environment)

**Example**: `lib/tls`, `lib/http`, `lib/dns` - they accept generic parameters like `Socket`, `Crypto`

```zig
// lib/tls/src/client.zig
pub fn Client(comptime Socket: type, comptime Crypto: type) type {
    // Socket and Crypto are validated via lib/trait
    return struct {
        // implementation using abstract interfaces
    };
}
```

---

### Platform

**Location**: `lib/{platform}/` + `bazel/{platform}/`

**Steps to introduce a new platform**:

1. **Implement native bindings** (as needed)
   - Location: `lib/{platform}/src/`
   - Wrap platform SDK APIs

2. **Implement trait interfaces** (as needed)
   - Provide implementations for `lib/trait` contracts
   - e.g., socket, rng, crypto

3. **Implement hal interfaces** (as needed)
   - Provide implementations for `lib/hal` contracts
   - e.g., wifi, gpio, adc, led_strip

4. **Provide Bazel rules**
   - Location: `bazel/{platform}/defs.bzl`
   - Build rules, flash rules, etc.

---

### Native Platform Bindings

**Principles**:
- **Preserve native API style** - keep function names and signatures close to official SDK (easier to reference docs)
- **Prefer c-translate** - use `@cImport` to translate C headers to Zig when possible
- **Use C Helper when necessary** - for constructs Zig cannot handle

**When C Helper is needed**:
- Opaque structs (library hides internal fields)
- Bit-fields (Zig doesn't support C bit-field layout)
- Complex macros

**File structure**:
```
lib/{platform}/src/idf/{lib_name}/
├── xxx_helper.c   # C wrapper for problematic APIs
├── xxx_helper.h   # Simple byte-array interface
└── xxx.zig        # Zig binding via @cImport
```

**Interface design**:
- Use byte arrays for parameters (avoid complex structs)
- Return int error codes (0 = success)
- Don't expose internal types

**Example** (`lib/esp/src/idf/mbed_tls/`):

```c
// x25519_helper.h
int mbed_x25519_scalarmult(const uint8_t sk[32], const uint8_t pk[32], uint8_t out[32]);
```

```zig
// x25519.zig
const c = @cImport(@cInclude("x25519_helper.h"));

pub fn scalarmult(sk: [32]u8, pk: [32]u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (c.mbed_x25519_scalarmult(&sk, &pk, &out) != 0)
        return error.CryptoError;
    return out;
}
```

---

### App

#### Platform-Free Code

**Location**: `examples/apps/{app}/app.zig`, `platform.zig`

**Dependency Rules**:
- Can depend on `lib/trait`
- Can depend on `lib/hal`
- Can depend on cross-platform libs in `lib/`
- **MUST NOT** depend on `lib/{platform}/`

```zig
// platform.zig - abstracts board selection
const build_options = @import("build_options");
const hal = @import("hal");

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
};

pub const Board = hal.Board(.{
    .wifi = hw.wifi,
    .button = hw.button,
    // ...
});
```

#### Board Definition

**Location**: `examples/apps/{app}/esp/{board}.zig`

**Purpose**: Assemble trait and hal implementations from platform lib for the app

```zig
// esp/korvo2_v3.zig
const esp = @import("esp");

pub const wifi = esp.wifi.Driver;
pub const button = esp.adc.Button(.{
    .unit = .adc1,
    .channel = .channel3,
    .thresholds = &.{ 500, 1500, 2500 },
});
```

---

### Driver

**Goal**: Keep board definitions simple. Reusable drivers belong in the platform layer.

#### Three-Layer Architecture

| Layer | Location | Responsibility |
|-------|----------|----------------|
| **Platform** | `lib/{platform}/` | Generic driver implementations (core, most important) |
| **BSP** | `lib/{platform}/src/boards/` | Pin configs + board-specific code (differences only) |
| **App Board** | `examples/apps/{app}/esp/{board}.zig` | Dependency injection (keep it simple) |

#### Layer 1: Platform (Core Implementations)

**Location**: `lib/esp/idf/src/speaker.zig`

Encapsulate reusable driver logic:
- Combine low-level components (DAC + I2S)
- Handle data format conversion
- Provide unified interface

```zig
// lib/esp/idf/src/speaker.zig
pub fn Speaker(comptime Dac: type) type {
    return struct {
        dac: *Dac,
        i2s: *I2s,
        pub fn write(self: *Self, buffer: []const i16) !usize { ... }
        pub fn setVolume(self: *Self, volume: u8) !void { ... }
    };
}
```

#### Layer 2: BSP (Board-Specific)

**Location**: `lib/esp/src/boards/{board}.zig`

Only board-specific configurations:
- GPIO/I2C pin definitions
- Hardware parameters (addresses, clocks)
- Special initialization logic

```zig
// lib/esp/src/boards/korvo2_v3.zig
pub const i2c_config = .{ .sda = 17, .scl = 18 };
pub const speaker_config = .{ .dac_addr = 0x18, .pa_gpio = 12 };
```

#### Layer 3: App Board (Dependency Injection)

**Location**: `examples/apps/{app}/esp/{board}.zig`

Import and assemble only, no logic implementation:

```zig
// examples/apps/speaker_test/esp/korvo2_v3.zig
const board = esp.boards.korvo2_v3;
pub const SpeakerDriver = board.SpeakerDriver;  // Reuse directly
pub const speaker_spec = board.speaker_spec;
```

#### Anti-pattern

**Don't** duplicate driver implementation in app board files:

```zig
// BAD: Reimplementing driver in app layer
pub const SpeakerDriver = struct {
    pub fn write(...) { /* duplicated logic */ }
};
```

**Do** reuse existing platform layer implementations.

---

## 2. How-to Recipes

### Build & Flash

#### How to Build

```bash
# Build with defaults (first board, first data variant)
bazel build //examples/apps/{app}/esp:app

# Build with specific board and data
bazel build //examples/apps/{app}/esp:app \
  --//bazel:board=esp32s3_devkit \
  --//bazel:data=zero
```

#### How to Flash

```bash
bazel run //examples/apps/{app}/esp:flash \
  --//bazel:port=/dev/cu.usbmodem2101
```

#### How to Monitor

```bash
bazel run //bazel/esp:monitor --//bazel:port=/dev/cu.usbmodem2101
```

**Port types**:
- USB-JTAG (built-in): `/dev/cu.usbmodem*` - ESP32-S3 DevKit
- USB-UART (external): `/dev/cu.usbserial*` - CP2102/CH340

---

### Configuration

#### How to Select Board

First board in `boards` list is default:

```python
# esp/BUILD.bazel
esp_zig_app(
    boards = ["korvo2_v3", "esp32s3_devkit"],  # korvo2_v3 is default
)
```

Override: `--//bazel:board=esp32s3_devkit`

#### How to Select Data Variant

First option in `data_select` is default:

```python
# BUILD.bazel
load("//bazel:data.bzl", "data_select")

data_select(
    name = "data_files",
    options = {
        "tiga": glob(["data/tiga/**"]),  # default
        "zero": glob(["data/zero/**"]),
    },
)
```

Override: `--//bazel:data=zero`

#### How to Configure WiFi (env)

Compile-time environment variables (baked into firmware):

```python
# esp/BUILD.bazel
load("//bazel:env.bzl", "make_env_file")

make_env_file(
    name = "env",
    defines = ["WIFI_SSID", "WIFI_PASSWORD"],
    defaults = {
        "WIFI_SSID": "MyWiFi",
        "WIFI_PASSWORD": "12345678",
    },
)
```

Override: `--define WIFI_SSID=OtherWiFi`

#### How to Add NVS Data

Runtime storage (can update without reflashing app):

```python
# esp/BUILD.bazel
load("//bazel/esp/partition:nvs.bzl", "esp_nvs_string", "esp_nvs_u8", "esp_nvs_image")

esp_nvs_string(name = "nvs_sn", namespace = "device", key = "sn")
esp_nvs_u8(name = "nvs_hw_ver", namespace = "device", key = "hw_ver")

esp_nvs_image(
    name = "nvs_data",
    entries = [":nvs_sn", ":nvs_hw_ver"],
    partition_size = "24K",
)
```

Override: `--define nvs_sn=H106-000001`

#### How to Add Data Files (SPIFFS)

```python
# esp/BUILD.bazel
load("//bazel/esp/partition:spiffs.bzl", "esp_spiffs_image")

esp_spiffs_image(
    name = "storage_data",
    srcs = ["//examples/apps/{app}:data_files"],
    partition_size = "1M",
    strip_prefix = "examples/apps/{app}/data",
)
```

#### How to Define Partition Table

```python
# esp/BUILD.bazel
load("//bazel/esp/partition:entry.bzl", "esp_partition_entry")
load("//bazel/esp/partition:table.bzl", "esp_partition_table")

esp_partition_entry(name = "part_nvs", partition_name = "nvs", type = "data", subtype = "nvs", partition_size = "24K")
esp_partition_entry(name = "part_factory", partition_name = "factory", type = "app", subtype = "factory", partition_size = "4M")
esp_partition_entry(name = "part_storage", partition_name = "storage", type = "data", subtype = "spiffs", partition_size = "1M")

esp_partition_table(
    name = "partitions",
    entries = [":part_nvs", ":part_factory", ":part_storage"],
    flash_size = "8M",
)
```

---

### Development

#### How to Add a New Board

1. Create board file: `examples/apps/{app}/esp/{board}.zig`
2. Define hardware configuration (GPIO, ADC, etc.)
3. Add to `boards` list in `esp/BUILD.bazel`
4. Add to `BoardType` enum in `esp/build.zig`
5. Add switch case in `platform.zig`

#### How to Add a New App

1. Create directory: `examples/apps/{app}/`
2. Create `app.zig` (application logic)
3. Create `platform.zig` (board abstraction)
4. Create `BUILD.bazel` (app_srcs, data_select)
5. Create `esp/` subdirectory with:
   - `BUILD.bazel` (sdkconfig, app, flash rules)
   - `build.zig`, `build.zig.zon`
   - `{board}.zig` files

Reference: `examples/apps/adc_button/` for complete example.
