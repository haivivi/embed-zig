# Development Guide

## 1. How-to Write

### Cross-Platform Lib

**Location**: `lib/pkg/{lib_name}/`

**Dependency Rules**:
- Can depend on `lib/trait`
- Can depend on `lib/hal`
- Can depend on other cross-platform libs in `lib/pkg/`
- **MUST NOT** depend on `lib/platform/{platform}/` (e.g., `lib/platform/esp/`)
- **Avoid** `std` (freestanding environment)

**Example**: `lib/pkg/tls`, `lib/pkg/http`, `lib/pkg/dns` - they accept generic parameters like `Socket`, `Crypto`

```zig
// lib/pkg/tls/src/client.zig
pub fn Client(comptime Socket: type, comptime Crypto: type) type {
    // Socket and Crypto are validated via lib/trait
    return struct {
        // implementation using abstract interfaces
    };
}
```

---

### Platform

**Location**: `lib/platform/{platform}/` + `bazel/{platform}/`

**Steps to introduce a new platform**:

1. **Implement native bindings** (as needed)
   - Location: `lib/platform/{platform}/src/` or sub-package (e.g., `idf/`, `raylib/`)
   - Wrap platform SDK APIs

2. **Implement trait interfaces** (as needed)
   - Location: `lib/platform/{platform}/impl/` or `src/impl/`
   - Provide implementations for `lib/trait` contracts
   - e.g., socket, rng, crypto

3. **Implement hal interfaces** (as needed)
   - Provide implementations for `lib/hal` contracts
   - e.g., wifi, gpio, adc, led_strip

4. **Provide Bazel rules**
   - Location: `bazel/{platform}/defs.bzl`
   - Build rules, flash rules, etc.

**Current platforms**:
- `lib/platform/esp/` — ESP32 (idf/ for bindings, impl/ for trait/hal implementations)
- `lib/platform/std/` — Zig std library (src/impl/ for trait implementations)
- `lib/platform/raysim/` — Raylib simulator (src/raylib/ for bindings, src/impl/ for drivers)

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
lib/platform/{platform}/src/idf/{lib_name}/
├── xxx_helper.c   # C wrapper for problematic APIs
├── xxx_helper.h   # Simple byte-array interface
└── xxx.zig        # Zig binding via @cImport
```

**Interface design**:
- Use byte arrays for parameters (avoid complex structs)
- Return int error codes (0 = success)
- Don't expose internal types

**Example** (`lib/platform/esp/idf/src/mbed_tls/`):

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
- Can depend on cross-platform libs in `lib/pkg/`
- **MUST NOT** depend on `lib/platform/{platform}/`

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
| **Platform** | `lib/platform/{platform}/` | Generic driver implementations (core, most important) |
| **BSP** | `lib/platform/{platform}/src/boards/` | Pin configs + board-specific code (differences only) |
| **App Board** | `examples/apps/{app}/esp/{board}.zig` | Dependency injection (keep it simple) |

#### Layer 1: Platform (Core Implementations)

**Location**: `lib/platform/esp/idf/src/speaker.zig`

Encapsulate reusable driver logic:
- Combine low-level components (DAC + I2S)
- Handle data format conversion
- Provide unified interface

```zig
// lib/platform/esp/idf/src/speaker.zig
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

**Location**: `lib/platform/esp/src/boards/{board}.zig`

Only board-specific configurations:
- GPIO/I2C pin definitions
- Hardware parameters (addresses, clocks)
- Special initialization logic

```zig
// lib/platform/esp/src/boards/korvo2_v3.zig
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

