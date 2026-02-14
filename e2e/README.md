# Platform Conformance Tests (e2e)

Automated verification of trait and HAL interface implementations across platforms.

Unlike `examples/` (demo/教学), `e2e/` is strict functional verification — one test per interface, results are quantifiable.

## Structure

```
e2e/
├── trait/{interface}/       — one test per lib/trait/src/{interface}.zig
│   ├── app.zig              — cross-platform test logic (IDENTICAL for all platforms)
│   ├── platform.zig         — @import("board") module (IDENTICAL for all platforms)
│   ├── std/
│   │   ├── board.zig        — std board: provides log, time, runtime, etc.
│   │   └── BUILD.bazel      — zig_library("board") + zig_test("test")
│   └── esp/
│       ├── board.zig        — ESP board: wraps IDF implementations
│       └── BUILD.bazel      — zig_library("board") + esp_zig_app + esp_flash
│
├── hal/{interface}/         — one test per lib/hal/src/{interface}.zig
│   └── (same structure)
│
└── BUILD.bazel              — test_suite aggregation
```

### Key Design

Platform switching uses Zig's **module system**, not comptime-if:

- `platform.zig` does `@import("board")` — a module import, not a file import
- Each platform's `BUILD.bazel` provides `zig_library(module_name = "board")`
- The build system (Bazel deps) is the only thing that differs between platforms

This avoids Zig's `@import` resolution issue (dead comptime-if branches still resolve import paths).

### Output Format

Every test outputs standardized log markers for automated parsing:

```
[e2e] START: trait/time
[e2e] PASS: trait/time/sleepMs
[e2e] PASS: trait/time/monotonic — delta=12ms
[e2e] PASS: trait/time
```

On failure:

```
[e2e] FAIL: trait/time/monotonic — t1=100, t2=100
```

## Running Tests

```bash
# All std tests (CI — runs on every push)
bazel test //e2e/...

# Single test
bazel test //e2e/trait/time/std:test

# ESP build (manual — requires hardware)
bazel build //e2e/trait/time/esp:app
bazel run //e2e/trait/time/esp:flash
```

## Conformance Matrix

### Trait Tests

| Trait | std (macOS/Linux) | ESP32-S3 | Korvo2-v3 |
|-------|:-----------------:|:--------:|:---------:|
| time | PASS | - | - |
| log | PASS | - | - |
| sync (Mutex, Condition, Thread, Channel, WaitGroup) | PASS | - | - |
| socket | - | - | - |
| crypto | - | - | - |
| rng | - | - | - |
| spawner (standalone) | - | - | - |
| io (kqueue/epoll) | - | N/A | N/A |
| i2c | N/A | - | - |
| spi | N/A | - | - |
| codec | - | - | - |
| net | N/A | - | - |
| system | - | - | - |

### HAL Tests

| HAL | std (macOS/Linux) | ESP32-S3 | Korvo2-v3 |
|-----|:-----------------:|:--------:|:---------:|
| rtc | - | - | - |
| wifi | N/A | - | - |
| kvs | - | - | - |
| button | N/A | - | - |
| button_group | N/A | - | - |
| led | N/A | - | - |
| led_strip | N/A | - | - |
| mic | N/A | - | - |
| mono_speaker | N/A | - | - |
| temp_sensor | N/A | - | - |
| imu | N/A | - | - |
| motion | N/A | - | - |
| switch | N/A | - | - |
| ble | - | - | - |
| hci | N/A | - | - |
| net (events) | N/A | - | - |

### Legend

| Symbol | Meaning |
|--------|---------|
| PASS | Test exists and passes |
| FAIL | Test exists but fails |
| - | Test not yet implemented |
| N/A | Not applicable for this platform |

### Score

| Platform | Trait | HAL | Total |
|----------|:-----:|:---:|:-----:|
| std (macOS/Linux) | 3/13 | 0/16 | 3/29 |
| ESP32-S3 DevKit | 0/13 | 0/16 | 0/29 |
| Korvo2-v3 | 0/13 | 0/16 | 0/29 |

## Adding a New Test

1. Create directory: `e2e/trait/{name}/` or `e2e/hal/{name}/`

2. Write `app.zig` — cross-platform test logic:
   ```zig
   const platform = @import("platform.zig");
   const log = platform.log;

   fn runTests() !void {
       log.info("[e2e] START: trait/{name}", .{});
       // ... tests ...
       log.info("[e2e] PASS: trait/{name}", .{});
   }

   pub fn entry(_: anytype) void {
       runTests() catch |err| { log.err("[e2e] FATAL: {}", .{err}); };
   }

   test "e2e: trait/{name}" {
       try runTests();
   }
   ```

3. Write `platform.zig`:
   ```zig
   const board = @import("board");
   pub const log = board.log;
   // export whatever app.zig needs from board
   ```

4. Write `BUILD.bazel`:
   ```python
   filegroup(name = "app_srcs", srcs = ["app.zig", "platform.zig"])
   ```

5. Add `std/board.zig` + `std/BUILD.bazel`:
   ```python
   zig_library(name = "board", main = "board.zig", srcs = ["board.zig"],
               module_name = "board", deps = ["//lib/platform/std"])
   zig_test(name = "test", main = "//e2e/trait/{name}:app.zig",
            srcs = ["//e2e/trait/{name}:app_srcs"], deps = [":board"])
   ```

6. Add to `e2e/BUILD.bazel` test_suite.

7. Update this README matrix.

## Adding a New Platform

1. Create `{platform}/board.zig` in each existing test directory
2. Create `{platform}/BUILD.bazel` with `zig_library(module_name = "board")` + build target
3. For ESP: use `esp_zig_app` + `esp_flash`, add `tags = ["manual"]`
4. Update this README matrix with a new column
