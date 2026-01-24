# Internal Temperature Sensor

[中文版](README.zh-CN.md)

Internal temperature sensor example - reads the chip's built-in temperature sensor.

## Features

- Initialize internal temperature sensor
- Periodic temperature readings (every 2 seconds)
- Track min/max/average statistics
- Display temperature in Celsius

## Hardware

- ESP32-S3-DevKitC-1

No external hardware required! Uses the chip's built-in temperature sensor.

## Important Notes

⚠️ **This reads the chip's internal temperature, NOT ambient temperature!**

- The reading is typically 10-20°C higher than ambient
- Temperature increases with chip activity (WiFi, CPU load, etc.)
- Useful for monitoring chip thermal status
- Not suitable for room temperature measurement

## Build

```bash
# Zig version
cd zig
idf.py set-target esp32s3
idf.py build flash monitor

# C version
cd c
idf.py set-target esp32s3
idf.py build flash monitor
```

## Expected Output

```
I (xxx) temp_sensor: Temperature sensor initialized (range: -10 to 80°C)
I (xxx) temp_sensor: Note: This is chip internal temperature, not ambient!
I (xxx) temp_sensor: 
I (xxx) temp_sensor: Reading #1: 45.2°C (min: 45.2, max: 45.2, avg: 45.2)
I (xxx) temp_sensor: Reading #2: 45.8°C (min: 45.2, max: 45.8, avg: 45.5)
I (xxx) temp_sensor: Reading #3: 46.1°C (min: 45.2, max: 46.1, avg: 45.7)
...
```

## Use Cases

- Monitor chip temperature during heavy operations
- Thermal throttling decisions
- Detect overheating conditions
- Power management optimization

## C vs Zig Comparison

### Binary Size

| Version | .bin Size | Diff |
|---------|-----------|------|
| **C** | 202,128 bytes (197.4 KB) | baseline |
| **Zig** | 210,768 bytes (205.8 KB) | **+4.2%** |

### Memory Usage (Static)

| Memory Region | C | Zig | Diff |
|---------------|---|-----|------|
| **Flash Code** | 92,040 bytes | 99,708 bytes | +8.3% |
| **DRAM** | 53,175 bytes | 53,191 bytes | +0.03% |
| **Flash Data** | 42,752 bytes | 43,716 bytes | +2.3% |
