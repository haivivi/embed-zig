# Project Architecture

## Bazel Flash and Monitor

**Important**: Always use Bazel commands for flashing and serial monitoring. Do not use ad-hoc scripts.

### Flash

```bash
# Flash to specified port
bazel run //examples/apps/{app_name}:flash --//bazel/esp:port=/dev/cu.usbmodem2101

# Example: flash async_test
bazel run //examples/apps/async_test:flash --//bazel/esp:port=/dev/cu.usbmodem2101
```

### Serial Monitor

```bash
# Use the global monitor rule
bazel run //bazel/esp:monitor --//bazel/esp:port=/dev/cu.usbmodem2101
```

### Port Types

- **USB-JTAG** (built-in): `/dev/cu.usbmodem*` - ESP32-S3 DevKit and similar boards
- **USB-UART** (external): `/dev/cu.usbserial*` or `/dev/ttyUSB*` - CP2102/CH340 bridges

### USB-JTAG Reset Notes

USB-JTAG port DTR/RTS are virtual CDC signals and cannot directly trigger hardware reset. The `esp_flash` rule automatically uses **watchdog reset**:
- Reconnects to bootloader after flashing
- Triggers software reset by writing to RTC watchdog register
- Device automatically restarts with new firmware

If watchdog reset fails (device stuck, etc.), manually press RST or re-plug USB.

---

## Module Relationships

```
┌─────────────────────────────────────────────────────────────┐
│ Application (examples/apps/*)                               │
│   Uses Board.crypto / Board.socket abstractions             │
├─────────────────────────────────────────────────────────────┤
│ lib/hal - Hardware Abstraction Layer                        │
│   Board(spec) validates and assembles components from spec  │
│   Exports: wifi, button, led_strip, rtc and other HAL       │
├─────────────────────────────────────────────────────────────┤
│ lib/trait - Interface Definitions                           │
│   Defines low-level interface contracts: socket, rng, etc.  │
│   Pure validation, no implementation                        │
├─────────────────────────────────────────────────────────────┤
│ lib/{platform}/impl - Platform Implementations              │
│   lib/esp/impl/crypto/suite.zig  (mbedTLS implementation)   │
│   lib/crypto/src/suite.zig       (pure Zig implementation)  │
└─────────────────────────────────────────────────────────────┘
```

## Data Flow Example

```zig
// 1. Platform impl provides concrete implementation
// lib/esp/src/impl/crypto/suite.zig
pub const Suite = struct {
    pub const Sha256 = struct { ... };  // mbedTLS
    pub const Rng = struct { ... };     // ESP HW RNG
};

// 2. Board file exports implementation
// examples/apps/xxx/boards/esp32s3_devkit.zig
pub const crypto = @import("esp").impl.crypto.Suite;

// 3. platform.zig assembles spec
const spec = struct {
    pub const crypto = hw.crypto;
    pub const socket = hw.socket;
};
pub const Board = hal.Board(spec);

// 4. hal.Board validates spec
// lib/hal/src/board.zig
pub fn Board(comptime spec: type) type {
    comptime {
        if (@hasDecl(spec, "crypto")) {
            _ = trait.crypto.from(spec.crypto, .{ .rng = true, ... });
        }
    }
}

// 5. Application uses
const Board = @import("platform.zig").Board;
const TlsClient = tls.Client(Board.socket, Board.crypto);
```

---

## Comptime Validation Guidelines

### Core Principle: Signature Validation (REQUIRED)

Do not use `@hasDecl` alone - must validate full function signature:

```zig
// BAD - only checks existence
if (!@hasDecl(T, "send")) @compileError("missing send");

// GOOD - validates signature, type errors cause compile failure
_ = @as(*const fn (*T, []const u8) Error!usize, &T.send);
```

### Recursive Subtype Validation

Nested types use corresponding `from()` for validation:

```zig
fn validateCrypto(comptime Impl: type) void {
    if (@hasDecl(Impl, "Rng")) {
        _ = rng.from(Impl.Rng);  // recursive validation
    }
}
```

### lib/trait Validation Pattern

Validates the type itself, returns original type:

```zig
// lib/trait/src/socket.zig
pub fn from(comptime Impl: type) type {
    comptime {
        const T = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };
        _ = @as(*const fn () Error!T, &T.tcp);
        _ = @as(*const fn (*T, []const u8) Error!usize, &T.send);
        _ = @as(*const fn (*T, []u8) Error!usize, &T.recv);
    }
    return Impl;
}
```

### lib/hal Validation Pattern

Validates spec structure (Driver + meta), returns HAL wrapper:

```zig
// lib/hal/src/wifi.zig
pub fn from(comptime spec: type) type {
    comptime {
        const Driver = spec.Driver;
        _ = @as(*const fn (*Driver, []const u8, []const u8) void, &Driver.connect);
        _ = @as(*const fn (*const Driver) bool, &Driver.isConnected);
        _ = @as([]const u8, spec.meta.id);
    }
    return struct {
        driver: *spec.Driver,
        pub fn connect(self: *@This(), ssid: []const u8, pwd: []const u8) void {
            self.driver.connect(ssid, pwd);
        }
    };
}
```

---

## C Library Integration Pattern

Zig's `@cImport` cannot properly handle certain C constructs:

- **Opaque structs** - library hides internal fields, Zig cannot access
- **Bit-fields** - Zig does not support C bit-field memory layout

### Solution: C Helper

Create C helper files to wrap problematic APIs, exposing simple byte-array interfaces to Zig:

```
lib/{platform}/src/idf/{lib_name}/
├── xxx_helper.c   # C implementation, handles opaque/bit-field
├── xxx_helper.h   # C header, declares simple interface
└── xxx.zig        # Zig wrapper, @cImport helper.h
```

### Interface Design Principles

1. **Use byte arrays for parameters** - avoid passing complex structs
2. **Return int error codes** - 0 for success, non-zero for failure
3. **Don't expose internal types** - C helper handles all mbedTLS/library types internally

### Example

See `lib/esp/src/idf/mbed_tls/` - mbedTLS X25519 wrapper:

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

## NFC / FM175XX Driver

### Status: In Progress (Pending Hardware Test)

FM175XX NFC reader driver migrated from C to Zig. Core functionality complete, awaiting hardware testing.

### Architecture

```
┌─────────────────────────────────────────────┐
│ Application                                 │
│   nfc.poll() -> CardInfo                    │
├─────────────────────────────────────────────┤
│ lib/nfc/drivers/fm175xx                     │
│   Fm175xx(Transport, Time)                  │
│   - driver.zig (core, FIFO, RF, transceive) │
│   - type_a.zig (ISO14443A, NTAG)            │
│   - type_b.zig (ISO14443B)                  │
│   - regs.zig   (register definitions)       │
├─────────────────────────────────────────────┤
│ lib/nfc (common NFC definitions)            │
│   - card.zig     (TypeACard, TypeBCard)     │
│   - protocol.zig (ISO14443 constants)       │
│   - ndef.zig     (NDEF parsing/encoding)    │
├─────────────────────────────────────────────┤
│ lib/hal (adapters)                          │
│   - I2cDevice(I2c) -> addr_io               │
│   - SpiDevice(Spi, Gpio) -> addr_io         │
├─────────────────────────────────────────────┤
│ lib/trait/addr_io                           │
│   Unified register R/W interface            │
│   - readByte(reg) / writeByte(reg, val)     │
│   - read(reg, buf) / write(reg, data)       │
└─────────────────────────────────────────────┘
```

### Usage Example

```zig
const hal = @import("hal");
const fm175xx = @import("fm175xx");

// I2C mode
const I2cDev = hal.I2cDevice(hw.I2c);
var transport = I2cDev.init(&i2c_bus, 0x28);
var nfc = fm175xx.Fm175xx(@TypeOf(&transport), Time).init(&transport);

try nfc.softReset();
try nfc.setRf(.both);

if (try nfc.poll()) |card| {
    switch (card) {
        .type_a => |a| {
            // ISO14443A card detected
            const uid = a.getUid();
        },
        .type_b => |b| {
            // ISO14443B card detected
        },
    }
}
```

### Files

| Path | Description |
|------|-------------|
| `lib/trait/src/addr_io.zig` | Unified I2C/SPI register interface trait |
| `lib/hal/src/i2c_device.zig` | I2C bus + device addr -> addr_io adapter |
| `lib/hal/src/spi_device.zig` | SPI bus + CS GPIO -> addr_io adapter |
| `lib/nfc/src/` | Common NFC definitions (card, protocol, ndef) |
| `lib/nfc/drivers/fm175xx/src/` | FM175XX driver implementation |
| `lib/nfc/drivers/fm175xx/docs/` | FM175XX register reference documentation |

### Next Steps

1. **Hardware Testing** - Test with actual FM175XX module (I2C or SPI)
2. **Mifare Classic** - Add authentication and sector read/write
3. **Example App** - Create `examples/apps/nfc_reader/` demo
4. **NDEF Write** - Implement writing NDEF records to tags
