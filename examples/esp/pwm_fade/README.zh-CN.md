# PWM 渐变（呼吸灯）

[English](README.md)

使用 LEDC PWM 硬件渐变功能实现呼吸灯效果。

## 功能

- 配置 LEDC 定时器和通道
- 硬件渐变实现平滑过渡
- 2 秒渐亮，2 秒渐灭
- 连续呼吸循环

## 硬件

- ESP32-S3-DevKitC-1
- **可选**：外接 LED（带电阻）到 GPIO2

注意：板载 WS2812 RGB LED 使用特定协议，不能用简单 PWM 控制。本示例在 GPIO2 输出 PWM。你可以：
1. 在 GPIO2 连接外部 LED
2. 用示波器观察 PWM 波形
3. 仅观察串口输出

## 配置

- PWM GPIO: 2
- 频率: 5000 Hz
- 分辨率: 13位（占空比范围 0-8191）
- 渐变时间: 每个方向 2000ms

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
I (xxx) pwm_fade: PWM output on GPIO2
I (xxx) pwm_fade: Frequency: 5000 Hz, Resolution: 13-bit
I (xxx) pwm_fade: LEDC initialized. Starting breathing effect...
I (xxx) pwm_fade: Cycle 1: Fading UP (0 -> 8191)
I (xxx) pwm_fade: Cycle 1: Fading DOWN (8191 -> 0)
I (xxx) pwm_fade: Cycle 2: Fading UP (0 -> 8191)
...
```
