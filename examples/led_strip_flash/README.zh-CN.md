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
- 编译优化: ReleaseSafe (Zig), Debug (C)

### Binary Size

| 版本 | .bin 大小 | Build Tag | 差异 |
|------|-----------|-----------|------|
| Zig | 225,808 bytes (220.5 KB) | `led_strip_zig_v3` | +11,040 bytes (+5.1%) |
| C | 214,768 bytes (209.7 KB) | `led_strip_c_v1` | baseline |

### 运行时内存占用 (Heap)

| 内存区域 | Zig | C |
|----------|-----|---|
| **Internal DRAM Total** | 408,544 bytes | 408,536 bytes |
| **Free** | 391,300 bytes | 391,292 bytes |
| **Used** | 17,244 bytes | 17,244 bytes |

> ✅ 使用 `std.log` 的 Zig 只增加 ~11KB (+5%) 二进制大小。运行时内存与 C 版本相同！

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

> 注：此示例未启用 PSRAM，内存统计仅显示内部 DRAM。

## 关键发现

~430KB 的体积膨胀**不是**由 `std.log` 引起的，而是 CMakeLists.txt 配置错误：

```cmake
# ❌ 这两行强制链接了整个 WiFi 协议栈 (~430KB)！
"-Wl,-u,esp_netif_init"
"-Wl,-u,esp_wifi_init"
```

移除不需要的链接符号后，`std.log` 只增加 ~11KB (+5%)。

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
