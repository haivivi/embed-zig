# Development Guide

## 1. How-to Write

### Cross-Platform Lib

**Location**: `lib/{lib_name}/`

**Dependency Rules**:
- Can depend on `lib/trait`
- Can depend on `lib/hal`
- Can depend on other cross-platform libs in `lib/`
- **MUST NOT** depend on `lib/platform/{platform}/` (e.g., `lib/platform/esp/`)
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
- Can depend on cross-platform libs in `lib/`
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

---

### BLE Stack

#### Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  App Code                                               │
│    gatt_server.handle(svc, char, handler_fn)            │
├─────────────────────────────────────────────────────────┤
│  gatt_server / gatt_client          (lib/bluetooth/)    │
│    Cross-platform, handler pattern like Go http.Server  │
│    Each handler runs in a coroutine                     │
├─────────────────────────────────────────────────────────┤
│  Host trait                          (lib/hal/ble.zig)  │
│    GAP/GATT-level abstraction boundary                  │
├────────────────────┬────────────────────────────────────┤
│  Pure Zig Host     │  CoreBluetooth wrapper             │
│  (lib/bluetooth/)  │  (future platform impl)            │
│  HCI → L2CAP → ATT│                                    │
├────────────────────┤  (no HCI needed)                   │
│  HCI trait         │                                    │
│  (lib/hal/hci.zig) │                                    │
├────────────────────┤                                    │
│  ESP VHCI impl     │  Apple hardware                    │
│  (platform/esp/)    │                                    │
└────────────────────┴────────────────────────────────────┘
```

**Analogy with Go:**
- `Host trait` = `net.Conn` (transport abstraction)
- `gatt_server` = `http.Server` (handler pattern, cross-platform)
- `gatt_client` = `http.Client` (cross-platform)

#### Two-Level Traits

| Trait | Location | Purpose | Implemented by |
|-------|----------|---------|----------------|
| HCI transport | `lib/hal/src/hci.zig` | Raw HCI read/write/poll | ESP VHCI, Linux raw HCI |
| BLE Host | `lib/hal/src/ble.zig` | GAP/GATT-level API | Pure Zig stack, CoreBluetooth |

#### HCI Transport Interface

Three non-blocking methods:

```zig
// lib/hal/src/hci.zig - Driver must implement:
fn read(self: *Self, buf: []u8) error{WouldBlock, HciError}!usize
fn write(self: *Self, buf: []const u8) error{WouldBlock, HciError}!usize
fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags
```

- `read()` - Non-blocking, returns HCI packet or `WouldBlock`
- `write()` - Non-blocking, sends HCI packet or `WouldBlock`
- `poll()` - POSIX-style poll, waits for read/write readiness with timeout

#### Concurrency Model

**Two dedicated loops** (each runs in its own task/coroutine):
- **Read loop**: HCI read → demux → L2CAP → ATT → dispatch to handlers
- **Write loop**: drain write queue → HCI write (queue protected by mutex)

**Handler pattern** (like Go `http.HandleFunc`):

```zig
// App code
const server = gatt_server.Server(Host, Executor);

server.handle(heart_rate_svc, bpm_char, struct {
    fn handler(req: *Request, resp: *Response) void {
        // Runs in its own coroutine
        // Can "block" (actually coroutine yield)
        const data = sensor.read();
        resp.setValue(data);
    }
}.handler);

server.run();  // Starts read loop + write loop
```

#### Executor Trait

Defined in `lib/trait`, provides coroutine primitives via comptime generic:

```zig
// lib/trait/src/executor.zig - Platform must implement:
fn spawn(func, ctx) void      // Create a coroutine/task
fn Mutex                       // Mutual exclusion
fn Channel(T)                  // Inter-coroutine communication
```

Platform mapping:
- ESP: FreeRTOS tasks + semaphores + queues
- macOS: GCD / pthreads
- Linux: pthreads

#### ESP HCI Implementation

Uses ESP-IDF VHCI API with FreeRTOS Event Groups:

```
ESP VHCI callbacks:
  host_recv_pkt    → enqueue to rx buffer → set READABLE event bit
  host_send_available → set WRITABLE event bit

HciDriver.poll():
  xEventGroupWaitBits(READABLE | WRITABLE, timeout)
```

Files:
- `lib/platform/esp/idf/src/bt/bt_helper.c` - BT controller init + VHCI callbacks
- `lib/platform/esp/idf/src/bt/bt.zig` - Zig binding
- `lib/platform/esp/impl/src/hci.zig` - HCI driver (event group based)

#### BLE Protocol Layers

```
Controller (Link Layer + PHY)  — ESP32 hardware
         │
        HCI                    — transport (read/write/poll)
         │
       L2CAP                   — multiplexing, fragmentation
         │
    ┌────┴────┬───────┐
    │         │       │
   ATT       SMP   Signaling   — fixed L2CAP channels
 (CID 4)  (CID 6)  (CID 5)
    │         │
  GATT     Security
    │
   GAP                         — advertising, scanning, connections
```

#### Directory Structure

```
lib/hal/src/
  hci.zig                   -- HCI transport trait (read/write/poll)
  ble.zig                   -- BLE Host trait (GAP/GATT level)

lib/bluetooth/
  src/
    bluetooth.zig            -- root module
    gatt_server.zig          -- GATT server (handler pattern, cross-platform)
    gatt_client.zig          -- GATT client (cross-platform)
    host/                    -- Pure Zig Host implementation
      host.zig               -- central coordinator, read/write loops
      hci/                   -- HCI packet encode/decode
        commands.zig
        events.zig
        acl.zig
      l2cap/                 -- L2CAP channel manager
        l2cap.zig
        signal.zig
      att/                   -- Attribute Protocol
        att.zig
        server.zig
        client.zig
      smp/                   -- Security Manager
        smp.zig
      gap/                   -- GAP state machine
        gap.zig
        advertiser.zig
        scanner.zig

lib/platform/esp/idf/src/bt/          -- ESP VHCI bindings
lib/platform/esp/impl/src/hci.zig     -- ESP HCI driver implementation
```

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

---

## 3. BLE Stack Implementation Plan

### Overview

构建纯 Zig BLE 协议栈。分为三大阶段：async 原语、HCI 传输、BLE 协议栈。每完成一步就提交。

### TODO List

#### Phase 0: Async 原语 (from zgrnet)

从 [zgrnet/zgrnet](https://github.com/zgrnet/zgrnet) 的 `zig/src/async/` 复制并改造到 `lib/async/`。

- [ ] **0.1** 创建 `lib/async/` 模块骨架（BUILD.bazel, build.zig, build.zig.zon, src/async.zig）
- [ ] **0.2** 复制 `task.zig` — 类型擦除的可调用单元，零平台依赖，直接搬
- [ ] **0.3** 复制 `executor.zig` — Executor vtable + InlineExecutor，零平台依赖，直接搬
- [ ] **0.4** 复制 `concepts.zig` — comptime 接口校验，零平台依赖，直接搬
- [ ] **0.5** 改造 `channel.zig` — 原版硬编码 `std.Thread.Mutex/Condition`，改成 `Channel(T, Sync)` 接受 comptime Sync 参数
- [ ] **0.6** 改造 `mpsc.zig` — 同上，`MpscQueue(T, Mutex)` 和 `BoundedMpscQueue(T, N, Sync)` 泛化
- [ ] **0.7** 改造 `actor.zig` — 依赖 MpscQueue + Executor，跟着泛化
- [ ] **0.8** 复制 `thread/` 后端 — ThreadExecutor + EventLoop，保持用 `std.Thread`（桌面平台用）
- [ ] **0.9** 预留 `minicoro/` 目录 — stackful coroutine 后端（后续裸机平台用）

**Sync trait 说明：** 平台提供一个 Sync 类型，包含 Mutex 和 Condition：

```zig
// 平台注入的 Sync 类型示例
const Sync = struct {
    pub const Mutex = struct {
        pub fn init() @This() { ... }
        pub fn deinit(self: *@This()) void { ... }
        pub fn lock(self: *@This()) void { ... }
        pub fn unlock(self: *@This()) void { ... }
    };
    pub const Condition = struct {
        pub fn init() @This() { ... }
        pub fn wait(self: *@This(), mutex: *Mutex) void { ... }
        pub fn timedWait(self: *@This(), mutex: *Mutex, timeout_ns: u64) error{Timeout}!void { ... }
        pub fn signal(self: *@This()) void { ... }
        pub fn broadcast(self: *@This()) void { ... }
    };
};
```

ESP 映射：Mutex = FreeRTOS Mutex (`lib/platform/esp/idf/src/sync.zig`)，Condition = Event Group
std 映射：Mutex = `std.Thread.Mutex`，Condition = `std.Thread.Condition`

#### Phase 1: HCI 传输层

- [ ] **1.1** 定义 HCI transport trait `lib/hal/src/hci.zig` — read/write/poll 三个方法
- [ ] **1.2** 注册到 `lib/hal/src/hal.zig` — `pub const hci = @import("hci.zig")`
- [ ] **1.3** ESP VHCI C helper — `lib/platform/esp/idf/src/bt/bt_helper.c/.h`（BT controller init + VHCI 回调）
- [ ] **1.4** ESP VHCI Zig binding — `lib/platform/esp/idf/src/bt/bt.zig`
- [ ] **1.5** ESP HCI driver — `lib/platform/esp/impl/src/hci.zig`（Event Group: READABLE/WRITABLE bits）

**HCI trait 接口：**

```zig
// lib/hal/src/hci.zig — Driver 必须实现：
fn read(self: *Self, buf: []u8) error{WouldBlock, HciError}!usize
fn write(self: *Self, buf: []const u8) error{WouldBlock, HciError}!usize
fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags

const PollFlags = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};
```

#### Phase 2: BLE 协议栈 (`lib/bluetooth/`)

- [ ] **2.1** 创建 `lib/bluetooth/` 模块骨架
- [ ] **2.2** HCI 包层 — `host/hci/commands.zig` + `events.zig` + `acl.zig`（编码/解码 HCI 包）
- [ ] **2.3** L2CAP 层 — `host/l2cap/l2cap.zig`（固定信道 CID 4/5/6，分片/重组）
- [ ] **2.4** ATT 协议 — `host/att/att.zig`（PDU 编码/解码）
- [ ] **2.5** GATT server — `gatt_server.zig`（handler 模式，Go http.Server 风格）
- [ ] **2.6** GAP — `host/gap/gap.zig`（广播、扫描、连接管理）
- [ ] **2.7** Host 组装 — `host/host.zig`（read loop + write loop + 状态机协调器）
- [ ] **2.8** BLE Host trait — `lib/hal/src/ble.zig`（GAP/GATT 级别抽象边界）

**Host 并发模型：**

```
Executor.spawn(readLoop):
  loop:
    hci.poll(.readable, -1)       // 阻塞等可读
    pkt = hci.read()              // 非阻塞读
    l2cap.handlePacket(pkt)       // 解包分发
    → att → gatt_server.dispatch  // 找到 handler
    → Executor.spawn(handler)     // handler 跑在新 coroutine

Executor.spawn(writeLoop):
  loop:
    cmd = write_channel.recv()    // 阻塞等队列
    hci.poll(.writable, -1)       // 等可写
    hci.write(cmd)                // 非阻塞写
```

#### Phase 3: 扩展 (后续)

- [ ] **3.1** SMP — 配对、绑定
- [ ] **3.2** GATT client — 服务发现、读写 characteristic
- [ ] **3.3** BLE 5.4 扩展 — PAwR、加密广播
- [ ] **3.4** macOS CoreBluetooth 后端 — `lib/platform/macos/impl/src/ble.zig` (future)
