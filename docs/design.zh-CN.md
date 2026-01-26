# 架构设计

中文 | [English](./design.md)

embed-zig 建立在三层抽象之上。每层都是独立且可选的。

```
┌─────────────────────────────────────────────────────────────┐
│                        应用层                                │
│                     你的代码在这里                           │
├─────────────────────────────────────────────────────────────┤
│                      HAL (lib/hal)                           │
│                   板子无关的硬件抽象                         │
├─────────────────────────────────────────────────────────────┤
│                      SAL (lib/sal)                           │
│                    跨平台系统原语                            │
├─────────────────────────────┬───────────────────────────────┤
│       ESP (lib/esp)         │     Raysim (lib/raysim)       │
│     ESP-IDF 绑定            │        桌面模拟               │
├─────────────────────────────┼───────────────────────────────┤
│         ESP-IDF             │          Raylib               │
│     FreeRTOS + 驱动         │        GUI + 输入             │
└─────────────────────────────┴───────────────────────────────┘
```

---

## SAL: 系统抽象层

**位置：** `lib/sal/`

SAL 提供跨平台原语，在 FreeRTOS、桌面操作系统或裸机上行为完全一致。

### 模块

| 模块 | 用途 |
|------|------|
| `thread` | 任务创建和管理 |
| `sync` | Mutex、Semaphore、Event |
| `time` | 睡眠、延时、时间戳 |
| `queue` | 线程安全消息队列 |
| `log` | 结构化日志 |

### 使用方法

```zig
const sal = @import("sal");

// 睡眠
sal.time.sleepMs(100);

// 互斥锁
var mutex = sal.sync.Mutex.init();
mutex.lock();
defer mutex.unlock();

// 日志
sal.log.info("温度: {d}°C", .{temp});
```

### 实现

SAL 是一个接口。实际实现来自平台：

| 平台 | 实现 | 位置 |
|------|------|------|
| ESP32 | FreeRTOS 封装 | `lib/esp/src/sal/` |
| 桌面 | std.Thread 封装 | `lib/std/src/sal/` |

你的代码导入 `sal`，构建系统链接正确的后端。

---

## HAL: 硬件抽象层

**位置：** `lib/hal/`

HAL 提供板子无关的外设抽象。同样的代码在不同硬件上运行。

### 核心概念

#### 1. Driver（驱动）

驱动实现特定外设的硬件操作：

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

#### 2. Spec（规格）

Spec 把驱动连接到 HAL 系统：

```zig
pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = hal.Meta{ .id = "led" };
};
```

#### 3. Board（板子）

Board 是编译期泛型，组合多个 spec：

```zig
const spec = struct {
    pub const rtc = hal.RtcReader(hw.rtc_spec);
    pub const button = hal.Button(hw.button_spec);
    pub const led = hal.LedStrip(hw.led_spec);
};

pub const Board = hal.Board(spec);
```

### 可用外设

| 外设 | 说明 | 必需的驱动方法 |
|------|------|---------------|
| `RtcReader` | 运行时间/时间戳（必需） | `init`, `deinit`, `uptime` |
| `Button` | GPIO 按钮带消抖 | `init`, `deinit`, `read` |
| `ButtonGroup` | ADC 按钮矩阵 | `init`, `deinit`, `read` |
| `LedStrip` | RGB LED 灯带 | `init`, `deinit`, `setColor` |
| `Led` | 单 LED 带 PWM | `init`, `deinit`, `setBrightness` |
| `TempSensor` | 温度传感器 | `init`, `deinit`, `readCelsius` |
| `Kvs` | 键值存储 | `init`, `deinit`, `get*`, `set*` |

### 事件系统

Board 聚合所有外设的事件：

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

## ESP: ESP-IDF 绑定

**位置：** `lib/esp/`

ESP-IDF C API 的地道 Zig 封装。

### 模块

| 模块 | ESP-IDF 组件 |
|------|-------------|
| `gpio` | `driver/gpio.h` |
| `adc` | `esp_adc/adc_oneshot.h` |
| `ledc` | `driver/ledc.h` |
| `led_strip` | `led_strip` |
| `nvs` | `nvs_flash` |
| `wifi` | `esp_wifi` |
| `http` | `esp_http_client` |
| `timer` | `esp_timer` |

### 直接使用

```zig
const idf = @import("esp").idf;

// GPIO
try idf.gpio.configOutput(48);
try idf.gpio.setLevel(48, 1);

// ADC
var adc = try idf.adc.init(.{ .unit = .unit1, .channel = .channel0 });
const value = try adc.read();

// 定时器
var timer = try idf.timer.init(.{
    .callback = myCallback,
    .name = "my_timer",
});
try timer.start(1_000_000); // 1 秒
```

### 何时直接用 ESP

用 HAL：
- 可能跑在其他地方的应用逻辑
- 标准外设（按钮、LED、传感器）
- 多板子支持

直接用 ESP：
- WiFi、蓝牙、HTTP（还没有 HAL 抽象）
- 性能关键代码
- ESP 特有功能（PSRAM、ULP 等）

---

## 多板子支持

### 编译期选择

板子在编译期通过构建选项选择：

```zig
// 在你的 board.zig 中
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
    .korvo2_v3 => @import("boards/korvo2_v3.zig"),
};
```

### 板级支持包 (BSP)

每个板子提供硬件特定的驱动：

```
boards/
├── esp32s3_devkit.zig    # DevKit BSP
│   ├── LedDriver         # GPIO48 单色 LED
│   ├── ButtonDriver      # GPIO0 启动按钮
│   └── RtcDriver         # idf.nowMs()
└── korvo2_v3.zig         # Korvo-2 BSP
    ├── LedDriver         # WS2812 RGB 灯带
    ├── ButtonDriver      # ADC 按钮矩阵
    └── RtcDriver         # idf.nowMs()
```

### 添加新板子

1. 创建 `boards/my_board.zig`
2. 实现必需的驱动
3. 在 `build.zig` 的 `BoardType` 枚举中添加
4. 更新 platform.zig 的 switch 语句

---

## Pure Zig 理念

### 最小化 C

C 互操作对于 ESP-IDF 是必需的，但我们把它限制在边缘：

```
┌──────────────────────────────────────┐
│           你的应用                    │  ← 纯 Zig
├──────────────────────────────────────┤
│              HAL                     │  ← 纯 Zig
├──────────────────────────────────────┤
│              SAL                     │  ← 纯 Zig（接口）
├──────────────────────────────────────┤
│          ESP 绑定                    │  ← Zig + @cImport
├──────────────────────────────────────┤
│           ESP-IDF                    │  ← C
└──────────────────────────────────────┘
```

### 编译期泛型

通过编译期多态实现零成本抽象：

```zig
// 这会为每个板子生成特化代码
// 没有虚表，没有运行时分发
pub fn Board(comptime spec: type) type {
    return struct {
        rtc: spec.rtc,
        button: if (@hasDecl(spec, "button")) spec.button else void,
        led: if (@hasDecl(spec, "led")) spec.led else void,
        // ...
    };
}
```

### 无隐藏分配

所有内存分配都是显式的。没有全局分配器。驱动管理自己的资源。

---

## 桌面模拟

同样的 HAL 代码可以在桌面上用模拟后端运行。

```
┌─────────────────────┐     ┌─────────────────────┐
│        应用         │     │        应用         │
├─────────────────────┤     ├─────────────────────┤
│        HAL          │     │        HAL          │
├─────────────────────┤     ├─────────────────────┤
│  ESP SAL (RTOS)     │     │  Std SAL (Thread)   │
├─────────────────────┤     ├─────────────────────┤
│      ESP-IDF        │     │   Raylib (GUI)      │
└─────────────────────┘     └─────────────────────┘
      ESP32                       桌面
```

这使得：
- 不烧录就能快速迭代 UI
- 在 CI 上单元测试
- 无硬件开发

参见 `examples/raysim/` 的模拟示例。
