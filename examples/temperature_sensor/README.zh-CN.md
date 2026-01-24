# 内部温度传感器

[English](README.md)

内部温度传感器示例 - 读取芯片内置温度传感器。

## 功能

- 初始化内部温度传感器
- 周期性温度读取（每 2 秒）
- 跟踪最小/最大/平均统计
- 显示摄氏温度

## 硬件

- ESP32-S3-DevKitC-1

无需外部硬件！使用芯片内置温度传感器。

## 重要说明

⚠️ **这是芯片内部温度，不是环境温度！**

- 读数通常比环境温度高 10-20°C
- 芯片活动（WiFi、CPU 负载等）会使温度升高
- 适用于监控芯片热状态
- 不适合测量室温

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
I (xxx) temp_sensor: Temperature sensor initialized (range: -10 to 80°C)
I (xxx) temp_sensor: Note: This is chip internal temperature, not ambient!
I (xxx) temp_sensor: 
I (xxx) temp_sensor: Reading #1: 45.2°C (min: 45.2, max: 45.2, avg: 45.2)
I (xxx) temp_sensor: Reading #2: 45.8°C (min: 45.2, max: 45.8, avg: 45.5)
I (xxx) temp_sensor: Reading #3: 46.1°C (min: 45.2, max: 46.1, avg: 45.7)
...
```

## 使用场景

- 重负载操作时监控芯片温度
- 热节流决策
- 检测过热情况
- 电源管理优化
