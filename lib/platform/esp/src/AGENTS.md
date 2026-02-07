# ESP Library Architecture

This document defines the structure and conventions for the `lib/esp/src/` directory.

## Directory Structure

```
lib/esp/src/
├── idf/           # ESP-IDF/ADF framework C API wrappers -> Zig packages
├── impl/          # Implementations of lib/trait and lib/hal interfaces
└── AGENTS.md      # This file
```

**IMPORTANT**: Only `idf/` and `impl/` directories should exist directly under `src/`.
All other code must be organized within these two directories.

## Directory Responsibilities

### `idf/` - ESP-IDF Framework Wrappers

Purpose: Wrap ESP-IDF/ESP-ADF C APIs into clean Zig packages.

Conventions:
- Each subdirectory represents a self-contained Zig package
- Can include C helper files (`*_helper.c`, `*_helper.h`) for:
  - Handling opaque C structures
  - Working with C bit-fields
  - Wrapping complex C macros
  - Bridging callback mechanisms
- Include CMake files (`*.cmake`) for build system integration
- Zig files provide the public API that `impl/` layer uses

Example structure:
```
idf/
├── mbed_tls/
│   ├── mbed_tls.cmake      # CMake build configuration
│   ├── x25519_helper.c     # C helper for opaque structures
│   ├── x25519_helper.h
│   └── x25519.zig          # Zig bindings
├── wifi/
│   ├── wifi.cmake
│   ├── wifi_helper.c
│   ├── wifi_helper.h
│   └── wifi.zig
└── net/
    ├── net.cmake
    ├── netif_helper.c
    ├── netif_helper.h
    └── netif.zig
```

### `impl/` - Trait and HAL Implementations

Purpose: Implement interfaces defined in `lib/trait` and `lib/hal`.

Conventions:
- Import from `idf/` layer for ESP-IDF functionality
- Must satisfy trait/HAL compile-time validation
- Should NOT contain C helper files (those belong in `idf/`)
- Focus on business logic and interface adaptation

Example structure:
```
impl/
├── crypto/
│   ├── suite.zig    # Implements crypto trait using idf/mbed_tls
│   └── cert.zig     # Certificate verification
├── wifi.zig         # Implements WiFi HAL using idf/wifi
└── net.zig          # Implements Net HAL using idf/net
```

## C Helper Pattern

When ESP-IDF C APIs cannot be directly called from Zig due to:
- Opaque structures (`esp_netif_t*`, etc.)
- Bit-fields in structs
- Complex macros
- Callback registration with void* context

Create C helper files in the appropriate `idf/` subdirectory:

```c
// idf/xxx/xxx_helper.h
#pragma once
int xxx_helper_do_something(void* handle, int param);

// idf/xxx/xxx_helper.c
#include "xxx_helper.h"
#include <esp_xxx.h>

int xxx_helper_do_something(void* handle, int param) {
    return esp_xxx_do_something((esp_xxx_t*)handle, param);
}
```

```zig
// idf/xxx/xxx.zig
extern fn xxx_helper_do_something(handle: ?*anyopaque, param: c_int) c_int;

pub fn doSomething(handle: Handle, param: i32) !void {
    const ret = xxx_helper_do_something(handle.ptr, @intCast(param));
    if (ret != 0) return error.Failed;
}
```

## Layer Dependency

```
┌─────────────────────────────────────┐
│           Application               │
├─────────────────────────────────────┤
│    lib/hal (Board, WiFi, etc.)      │
├─────────────────────────────────────┤
│         lib/trait (interfaces)      │
├─────────────────────────────────────┤
│     lib/esp/src/impl/ (ESP impl)    │
├─────────────────────────────────────┤
│     lib/esp/src/idf/ (C wrappers)   │
├─────────────────────────────────────┤
│         ESP-IDF / ESP-ADF           │
└─────────────────────────────────────┘
```

- `impl/` imports from `idf/` (same package)
- `impl/` implements interfaces from `lib/trait` and `lib/hal`
- `idf/` only depends on ESP-IDF C APIs
- Applications use `lib/hal` which internally uses `impl/`
