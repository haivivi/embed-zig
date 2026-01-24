# 定时器回调

[English](README.md)

硬件定时器（GPTimer）中断回调示例。

## 功能

- 创建 1MHz 分辨率（每 tick 1us）的硬件定时器
- 1 秒周期闹钟，自动重载
- 定时器回调在 ISR 中切换 LED
- 精确计时，独立于 FreeRTOS tick

## 硬件

- ESP32-S3-DevKitC-1
- 板载 WS2812 RGB LED（GPIO48）

无需外部硬件！

## 工作原理

GPTimer 配置为：
1. 以 1MHz 运行（每计数 1 微秒）
2. 在 1,000,000 计数时触发闹钟（1 秒）
3. 闹钟后自动重载为 0
4. 每次闹钟调用 ISR 回调

LED 每秒切换红色开/关。

## 编译

```bash
# Zig 版本
cd zig
idf.py set-target esp32s3
idf.py build flash monitor

# C 版本
cd c
idf.py set-target esp32s3
idf.py build flash monitor
```

## 预期输出

```
I (xxx) timer_callback: Timer started! LED toggles every 1 second
I (xxx) timer_callback: Timer resolution: 1MHz (1us per tick)
I (xxx) timer_callback: Timer tick #1, LED=ON
I (xxx) timer_callback: Timer tick #2, LED=OFF
I (xxx) timer_callback: Timer tick #3, LED=ON
...
```
