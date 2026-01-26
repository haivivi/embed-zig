# Architecture

[中文](./design.zh-CN.md) | English

embed-zig is built on three layers of abstraction. Each layer is independent and optional.

```
┌─────────────────────────────────────────────────────────────┐
│                       Application                            │
│                    Your code lives here                      │
├─────────────────────────────────────────────────────────────┤
│                      HAL (lib/hal)                           │
│          Board-agnostic hardware abstraction                 │
├─────────────────────────────────────────────────────────────┤
│                      SAL (lib/sal)                           │
│           Cross-platform system primitives                   │
├─────────────────────────────┬───────────────────────────────┤
│       ESP (lib/esp)         │      Raysim (lib/raysim)      │
│    ESP-IDF bindings         │    Desktop simulation         │
├─────────────────────────────┼───────────────────────────────┤
│         ESP-IDF             │          Raylib               │
│     FreeRTOS + drivers      │        GUI + Input            │
└─────────────────────────────┴───────────────────────────────┘
```

---

## SAL: System Abstraction Layer

**Location:** `lib/sal/`

SAL provides cross-platform primitives that work identically whether you're on FreeRTOS, a desktop OS, or bare metal.

### Modules

| Module | Purpose |
|--------|---------|
| `thread` | Task creation and management |
| `sync` | Mutex, Semaphore, Event |
| `time` | Sleep, delays, timestamps |
| `queue` | Thread-safe message queues |
| `log` | Structured logging |

### Usage

```zig
const sal = @import("sal");

// Sleep
sal.time.sleepMs(100);

// Mutex
var mutex = sal.sync.Mutex.init();
mutex.lock();
defer mutex.unlock();

// Logging
sal.log.info("Temperature: {d}°C", .{temp});
```

### Implementations

SAL is an interface. The actual implementation comes from the platform:

| Platform | Implementation | Location |
|----------|----------------|----------|
| ESP32 | FreeRTOS wrappers | `lib/esp/src/sal/` |
| Desktop | std.Thread wrappers | `lib/std/src/sal/` |

Your code imports `sal`, and the build system links the correct backend.

---

## HAL: Hardware Abstraction Layer

**Location:** `lib/hal/`

HAL provides board-agnostic peripheral abstractions. The same code works across different hardware.

### Core Concepts

#### 1. Driver

A driver implements hardware operations for a specific peripheral:

```zig
pub const LedDriver = struct {
    strip: *led_strip.LedStrip,

    pub fn init() !LedDriver {
        const strip = try led_strip.init(.{ .gpio = 48, .max_leds = 1 });
        return .{ .strip = strip };
    }

    pub fn deinit(self: *LedDriver) void {
        self.strip.deinit();
    }

    pub fn setColor(self: *LedDriver, r: u8, g: u8, b: u8) void {
        self.strip.setPixel(0, r, g, b);
        self.strip.refresh();
    }
};
```

#### 2. Spec

A spec connects a driver to the HAL system:

```zig
pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = hal.Meta{ .id = "led" };
};
```

#### 3. Board

Board is a comptime-generic that combines multiple specs:

```zig
const spec = struct {
    pub const rtc = hal.RtcReader(hw.rtc_spec);
    pub const button = hal.Button(hw.button_spec);
    pub const led = hal.LedStrip(hw.led_spec);
};

pub const Board = hal.Board(spec);
```

### Available Peripherals

| Peripheral | Description | Required Driver Methods |
|------------|-------------|------------------------|
| `RtcReader` | Uptime/timestamp (required) | `init`, `deinit`, `uptime` |
| `Button` | GPIO button with debounce | `init`, `deinit`, `read` |
| `ButtonGroup` | ADC button matrix | `init`, `deinit`, `read` |
| `LedStrip` | RGB LED strip | `init`, `deinit`, `setColor` |
| `Led` | Single LED with PWM | `init`, `deinit`, `setBrightness` |
| `TempSensor` | Temperature sensor | `init`, `deinit`, `readCelsius` |
| `Kvs` | Key-value storage | `init`, `deinit`, `get*`, `set*` |

### Event System

Board aggregates events from all peripherals:

```zig
var board = try Board.init();
defer board.deinit();

while (true) {
    board.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| handleButton(btn),
            .button_group => |grp| handleButtonGroup(grp),
            // ...
        }
    }
    sal.time.sleepMs(10);
}
```

---

## ESP: ESP-IDF Bindings

**Location:** `lib/esp/`

Idiomatic Zig wrappers around ESP-IDF C APIs.

### Modules

| Module | ESP-IDF Component |
|--------|-------------------|
| `gpio` | `driver/gpio.h` |
| `adc` | `esp_adc/adc_oneshot.h` |
| `ledc` | `driver/ledc.h` |
| `led_strip` | `led_strip` |
| `nvs` | `nvs_flash` |
| `wifi` | `esp_wifi` |
| `http` | `esp_http_client` |
| `timer` | `esp_timer` |

### Direct Usage

```zig
const idf = @import("esp").idf;

// GPIO
try idf.gpio.configOutput(48);
try idf.gpio.setLevel(48, 1);

// ADC
var adc = try idf.adc.init(.{ .unit = .unit1, .channel = .channel0 });
const value = try adc.read();

// Timer
var timer = try idf.timer.init(.{
    .callback = myCallback,
    .name = "my_timer",
});
try timer.start(1_000_000); // 1 second
```

### When to Use ESP Directly

Use HAL for:
- Application logic that might run elsewhere
- Standard peripherals (buttons, LEDs, sensors)
- Multi-board support

Use ESP directly for:
- WiFi, Bluetooth, HTTP (no HAL abstraction yet)
- Performance-critical code
- ESP-specific features (PSRAM, ULP, etc.)

---

## Multi-Board Support

### Compile-Time Selection

Boards are selected at compile time via build options:

```zig
// In your board.zig
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
    .korvo2_v3 => @import("boards/korvo2_v3.zig"),
};
```

### Board Support Package (BSP)

Each board provides hardware-specific drivers:

```
boards/
├── esp32s3_devkit.zig    # DevKit BSP
│   ├── LedDriver         # GPIO48 single LED
│   ├── ButtonDriver      # GPIO0 boot button
│   └── RtcDriver         # idf.nowMs()
└── korvo2_v3.zig         # Korvo-2 BSP
    ├── LedDriver         # WS2812 RGB strip
    ├── ButtonDriver      # ADC button matrix
    └── RtcDriver         # idf.nowMs()
```

### Adding a New Board

1. Create `boards/my_board.zig`
2. Implement required drivers
3. Add to `BoardType` enum in `build.zig`
4. Update platform.zig switch statement

---

## Pure Zig Philosophy

### Minimize C

C interop is necessary for ESP-IDF, but we keep it at the edges:

```
┌──────────────────────────────────────┐
│         Your Application             │  ← Pure Zig
├──────────────────────────────────────┤
│              HAL                     │  ← Pure Zig
├──────────────────────────────────────┤
│              SAL                     │  ← Pure Zig (interface)
├──────────────────────────────────────┤
│         ESP Bindings                 │  ← Zig with @cImport
├──────────────────────────────────────┤
│           ESP-IDF                    │  ← C
└──────────────────────────────────────┘
```

### Comptime Generics

Zero-cost abstraction through compile-time polymorphism:

```zig
// This generates specialized code for each board
// No vtables, no runtime dispatch
pub fn Board(comptime spec: type) type {
    return struct {
        rtc: spec.rtc,
        button: if (@hasDecl(spec, "button")) spec.button else void,
        led: if (@hasDecl(spec, "led")) spec.led else void,
        // ...
    };
}
```

### No Hidden Allocations

All memory allocation is explicit. No global allocator. Drivers manage their own resources.

---

## Desktop Simulation

The same HAL code can run on desktop with a simulated backend.

```
┌─────────────────────┐     ┌─────────────────────┐
│    Application      │     │    Application      │
├─────────────────────┤     ├─────────────────────┤
│        HAL          │     │        HAL          │
├─────────────────────┤     ├─────────────────────┤
│   ESP SAL (RTOS)    │     │   Std SAL (Thread)  │
├─────────────────────┤     ├─────────────────────┤
│      ESP-IDF        │     │   Raylib (GUI)      │
└─────────────────────┘     └─────────────────────┘
      ESP32                      Desktop
```

This enables:
- Rapid UI iteration without flashing
- Unit testing on CI
- Development without hardware

See `examples/raysim/` for simulation examples.
