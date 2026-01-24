# LED Strip Flash

[English](README.md)

ESP32-S3 LED 灯带闪烁示例，对比 Zig 与 C 实现。

## 功能

- 控制 WS2812/SK6812 RGB LED 灯带
- 使用 ESP-IDF RMT 驱动
- 周期性闪烁效果
- 输出堆内存统计信息

## 目录结构

```
led_strip_flash/
├── zig/           # Zig 实现
│   ├── main/
│   │   ├── build.zig
│   │   └── src/main.zig
│   └── CMakeLists.txt
├── c/             # C 实现
│   └── main/
│       └── main.c
└── README.md
```

## 编译对比 (ESP32-S3)

测试环境：
- ESP-IDF v5.4.0
- Zig 0.15.x (Espressif fork)
- Target: esp32s3
- 编译优化: Size (`CONFIG_COMPILER_OPTIMIZATION_SIZE=y`)
- PSRAM: 已启用 (8MB Octal)

### 二进制大小

| 版本 | .bin 大小 | 差异 |
|------|-----------|------|
| **C** | 223,088 bytes (217.9 KB) | 基准 |
| **Zig** | 230,768 bytes (225.4 KB) | **+3.4%** |

### 内存占用（静态）

| 内存区域 | C | Zig | 差异 |
|----------|---|-----|------|
| **IRAM** | 16,383 bytes | 16,383 bytes | 0% |
| **DRAM** | 59,027 bytes | 59,019 bytes | -0.01% |
| **Flash Code** | 103,324 bytes | 110,948 bytes | +7.4% |

> 注：DRAM 使用量几乎相同。Flash Code 增加（~7.6KB）是由于 Zig 的 `std.fmt` 整数格式化代码（`std.log` 使用）。

## 运行日志

### Zig 版本输出

```
I (347):   LED Strip Flash - Zig Version
I (347):   Build Tag: led_strip_zig_v1
I (357): === Heap Memory Statistics ===
I (367): Internal DRAM:
I (377): External PSRAM: not available
I (377): Toggling the LED OFF!
I (1377): Toggling the LED ON!
I (2377): Toggling the LED OFF!
I (3377): Toggling the LED ON!
```

### C 版本输出

```
I (274) led_strip:   LED Strip Flash - C Version
I (284) led_strip:   Build Tag: led_strip_c_v1
I (294) led_strip: === Heap Memory Statistics ===
I (294) led_strip: Internal DRAM:
I (314) led_strip: External PSRAM: not available
I (324) led_strip: DMA capable free: 383788 bytes
I (324) led_strip: Toggling the LED OFF!
I (1324) led_strip: Toggling the LED ON!
I (2324) led_strip: Toggling the LED OFF!
I (3324) led_strip: Toggling the LED ON!
```

## 关键发现

`std.log` 导致的 **~3.4%** 二进制大小增加来自：
1. `std.fmt` 整数格式化代码（~7.6KB）
2. Zig 的 comptime 格式字符串验证

**重要提示**：之前 14.1% 的增加是由于 sdkconfig 配置错误（使用了 `CONFIG_COMPILER_OPTIMIZATION_DEBUG=y` 而不是 `CONFIG_COMPILER_OPTIMIZATION_SIZE=y`）。

## 构建

```bash
# Zig 版本
cd zig
idf.py set-target esp32s3
idf.py build

# C 版本
cd c
idf.py set-target esp32s3
idf.py build
```

## 烧录

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```

## 配置

通过 `idf.py menuconfig` 配置:
- `BLINK_GPIO`: LED 数据引脚 (默认: 48)
- `BLINK_PERIOD`: 闪烁周期 (默认: 1000ms)
