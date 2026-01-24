# NVS Storage Example

Non-Volatile Storage (NVS) example demonstrating persistent key-value storage in flash memory.

## Features

- **Boot Counter**: Integer that increments on each device reboot
- **Device Name**: String stored and retrieved from NVS
- **Blob Data**: Binary data storage and retrieval
- **Persistence**: Data survives power cycles and reboots

## Building and Running

```bash
cd examples/nvs_storage/zig
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

## Example Output

```
==========================================
NVS Storage Example - Zig Version
==========================================
NVS initialized

=== Boot Counter ===
Boot count: 3

=== Device Name ===
Device name: ESP32-Zig-Device

=== Blob Data ===
Blob data (6 bytes): deadbeefcafe
NVS committed to flash

=== Summary ===
Boot count: 3 (will increment on next boot)
Device name: ESP32-Zig-Device
Blob stored: 6 bytes

Reboot the device to see boot_count increment!
```

## NVS API Usage

```zig
const idf = @import("esp");

// Initialize NVS
try idf.nvs.init();

// Open a namespace
var nvs = try idf.Nvs.open("storage");
defer nvs.close();

// Integer operations
try nvs.setU32("counter", 42);
const value = try nvs.getU32("counter");

// String operations
try nvs.setString("name", "ESP32-Device");
var buf: [64]u8 = undefined;
const name = try nvs.getString("name", &buf);

// Blob (binary) operations
const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
try nvs.setBlob("blob", &data);
var blob_buf: [16]u8 = undefined;
const blob = try nvs.getBlob("blob", &blob_buf);

// Commit changes to flash
try nvs.commit();

// Error handling
const result = nvs.getU32("missing_key") catch |err| {
    if (err == idf.nvs.NvsError.NotFound) {
        // Key doesn't exist
    }
};
```

## Supported Types

| Type | Set | Get |
|------|-----|-----|
| i8, u8 | `setI8`, `setU8` | `getI8`, `getU8` |
| i16, u16 | `setI16`, `setU16` | `getI16`, `getU16` |
| i32, u32 | `setI32`, `setU32` | `getI32`, `getU32` |
| i64, u64 | `setI64`, `setU64` | `getI64`, `getU64` |
| String | `setString` | `getString`, `getStringLen` |
| Blob | `setBlob` | `getBlob`, `getBlobLen` |

## C vs Zig Comparison

### Binary Size

| Version | .bin Size | Diff |
|---------|-----------|------|
| **C** | 228,048 bytes (222.7 KB) | baseline |
| **Zig** | 230,512 bytes (225.1 KB) | +1.1% |

### Memory Usage (Static)

| Memory Region | C | Zig | Diff |
|---------------|---|-----|------|
| **IRAM** | 16,383 bytes | 16,383 bytes | 0% |
| **DRAM** | 55,023 bytes | 55,023 bytes | **0%** ✅ |
| **Flash Code** | 116,556 bytes | 118,264 bytes | +1.5% |

### Code Lines

| Version | Lines | Notes |
|---------|-------|-------|
| **C** | ~120 | Manual error handling, verbose |
| **Zig** | ~100 | Cleaner with `try`/`catch`, defer |

### Data Compatibility

✅ NVS data written by Zig can be read by C and vice versa. The storage format is identical.

## Hardware

- ESP32-S3-DevKitC-1 with PSRAM
