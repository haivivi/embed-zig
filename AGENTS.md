# Project Architecture

## Bazel 烧录与监控

**重要**: 必须使用 Bazel 指令进行烧录和串口监控，不要使用临时脚本。

### 烧录 (Flash)

```bash
# 烧录到指定端口
bazel run //examples/apps/{app_name}:flash --//bazel/esp:port=/dev/cu.usbmodem2101

# 例如烧录 async_test
bazel run //examples/apps/async_test:flash --//bazel/esp:port=/dev/cu.usbmodem2101
```

### 串口监控 (Monitor)

```bash
# 使用全局 monitor 规则
bazel run //bazel/esp:monitor --//bazel/esp:port=/dev/cu.usbmodem2101
```

### 端口类型

- **USB-JTAG** (内置): `/dev/cu.usbmodem*` - ESP32-S3 DevKit 等开发板
- **USB-UART** (外置): `/dev/cu.usbserial*` 或 `/dev/ttyUSB*` - CP2102/CH340 桥接器

### USB-JTAG 复位说明

USB-JTAG 端口的 DTR/RTS 是 CDC 虚拟信号，无法直接触发硬件复位。`esp_flash` 规则会自动使用 **watchdog reset** 方式：
- 烧录完成后重新连接到 bootloader
- 通过写 RTC 看门狗寄存器触发软件复位
- 设备会自动重启运行新固件

如果 watchdog reset 失败（设备卡死等情况），需要手动按 RST 或重新插拔 USB。

---

## 模块关系

```
┌─────────────────────────────────────────────────────────────┐
│ Application (examples/apps/*)                               │
│   使用 Board.crypto / Board.socket 等抽象                    │
├─────────────────────────────────────────────────────────────┤
│ lib/hal - Hardware Abstraction Layer                        │
│   Board(spec) 验证并组装 spec 中的组件                        │
│   导出: wifi, button, led_strip, rtc 等 HAL 组件             │
├─────────────────────────────────────────────────────────────┤
│ lib/trait - Interface Definitions                           │
│   定义底层接口契约: socket, rng, log, time, crypto           │
│   纯验证，不包含实现                                          │
├─────────────────────────────────────────────────────────────┤
│ lib/{platform}/impl - Platform Implementations              │
│   lib/esp/impl/crypto/suite.zig  (mbedTLS 实现)              │
│   lib/crypto/src/suite.zig       (纯 Zig 实现)               │
└─────────────────────────────────────────────────────────────┘
```

## 数据流示例

```zig
// 1. Platform impl 提供具体实现
// lib/esp/src/impl/crypto/suite.zig
pub const Suite = struct {
    pub const Sha256 = struct { ... };  // mbedTLS
    pub const Rng = struct { ... };     // ESP HW RNG
};

// 2. Board 文件导出实现
// examples/apps/xxx/boards/esp32s3_devkit.zig
pub const crypto = @import("esp").impl.crypto.Suite;

// 3. platform.zig 组装 spec
const spec = struct {
    pub const crypto = hw.crypto;
    pub const socket = hw.socket;
};
pub const Board = hal.Board(spec);

// 4. hal.Board 验证 spec
// lib/hal/src/board.zig
pub fn Board(comptime spec: type) type {
    comptime {
        if (@hasDecl(spec, "crypto")) {
            _ = trait.crypto.from(spec.crypto, .{ .rng = true, ... });
        }
    }
}

// 5. Application 使用
const Board = @import("platform.zig").Board;
const TlsClient = tls.Client(Board.socket, Board.crypto);
```

---

## Comptime 验证规范

### 核心原则: 签名验证 (REQUIRED)

禁止只用 `@hasDecl` - 必须验证完整函数签名:

```zig
// BAD - 只检查存在性
if (!@hasDecl(T, "send")) @compileError("missing send");

// GOOD - 验证签名，类型错误会编译失败
_ = @as(*const fn (*T, []const u8) Error!usize, &T.send);
```

### 子类型递归验证

嵌套类型用对应 `from()` 验证:

```zig
fn validateCrypto(comptime Impl: type) void {
    if (@hasDecl(Impl, "Rng")) {
        _ = rng.from(Impl.Rng);  // 递归验证
    }
}
```

### lib/trait 验证模式

验证类型本身，返回原类型:

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

### lib/hal 验证模式

验证 spec 结构 (含 Driver + meta)，返回 HAL wrapper:

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

## C 库集成 Pattern

Zig 的 `@cImport` 无法正确处理某些 C 结构：

- **Opaque structs** - 库隐藏了内部字段，Zig 无法访问
- **Bit-fields** - Zig 不支持 C bit-field 内存布局

### 解决方案：C Helper

创建 C helper 文件封装问题 API，暴露简单的 byte-array 接口给 Zig：

```
lib/{platform}/src/idf/{lib_name}/
├── xxx_helper.c   # C 实现，处理 opaque/bit-field
├── xxx_helper.h   # C 头文件，声明简单接口
└── xxx.zig        # Zig wrapper，@cImport helper.h
```

### 接口设计原则

1. **参数用 byte 数组** - 避免传递复杂结构体
2. **返回 int 错误码** - 0 成功，非 0 失败
3. **不暴露内部类型** - C helper 内部处理所有 mbedTLS/其他库类型

### 示例

参考 `lib/esp/src/idf/mbed_tls/` - mbedTLS X25519 封装：

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
