# GPIO 按键

[English](README.md)

GPIO 输入/输出示例，演示按键读取和 LED 控制。

## 功能

- 读取 Boot 按钮状态（GPIO0，低电平有效）
- 控制板载 RGB LED（GPIO48）
- 按键按下切换 LED 开/关
- 消抖处理

## 硬件

- ESP32-S3-DevKitC-1
- 板载 Boot 按钮（GPIO0）
- 板载 WS2812 RGB LED（GPIO48）

无需外部硬件！

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

## 使用方法

1. 烧录固件
2. 按下 Boot 按钮
3. LED 在开（白色）和关之间切换
4. 观察串口输出的按键计数
