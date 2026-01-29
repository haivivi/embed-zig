# 示例

中文 | [English](./examples.md)

## 编译和烧录

所有示例使用相同的模式：

```bash
# 编译
bazel build //examples/apps/<名称>:esp

# 烧录（指定串口）
bazel run //examples/apps/<名称>:flash --//bazel/esp:port=/dev/ttyUSB0
```

## gpio_button

按钮输入控制 LED 开关。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/gpio_button:esp
  bazel run //examples/apps/gpio_button:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/gpio_button:esp --//bazel/esp:board=korvo2_v3
  bazel run //examples/apps/gpio_button:flash --//bazel/esp:port=/dev/ttyUSB1
  ```

- **Zig / 桌面模拟器 (Raylib)**
  ```bash
  bazel run //examples/raysim/gpio_button:run
  ```

## led_strip_flash

RGB LED 灯带闪烁。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/led_strip_flash:esp
  bazel run //examples/apps/led_strip_flash:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/led_strip_flash:esp --//bazel/esp:board=korvo2_v3
  bazel run //examples/apps/led_strip_flash:flash --//bazel/esp:port=/dev/ttyUSB1
  ```

## led_strip_anim

LED 动画效果。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/led_strip_anim:esp
  bazel run //examples/apps/led_strip_anim:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/led_strip_anim:esp --//bazel/esp:board=korvo2_v3
  bazel run //examples/apps/led_strip_anim:flash --//bazel/esp:port=/dev/ttyUSB1
  ```

## adc_button

ADC 按钮矩阵。

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/adc_button:esp --//bazel/esp:board=korvo2_v3
  bazel run //examples/apps/adc_button:flash --//bazel/esp:port=/dev/ttyUSB1
  ```

## timer_callback

硬件定时器回调。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/timer_callback:esp
  bazel run //examples/apps/timer_callback:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## pwm_fade

LED 亮度渐变。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/pwm_fade:esp
  bazel run //examples/apps/pwm_fade:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## temperature_sensor

内部温度传感器。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/temperature_sensor:esp
  bazel run //examples/apps/temperature_sensor:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## nvs_storage

持久化键值存储。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/nvs_storage:esp
  bazel run //examples/apps/nvs_storage:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## mic_test

ES7210 编解码器麦克风录音。

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/mic_test:esp --//bazel/esp:board=korvo2_v3
  bazel run //examples/apps/mic_test:flash --//bazel/esp:port=/dev/ttyUSB1
  ```

## wifi_dns_lookup

WiFi 连接 + DNS 解析。

**环境变量：**
- `WIFI_SSID` - WiFi 网络名（通过 `--define` 传递）
- `WIFI_PASSWORD` - WiFi 密码（通过 `--action_env` 传递，更安全）

- **Zig / ESP32-S3-DevKit**
  ```bash
  # 编译（传入 WiFi 凭证）
  WIFI_PASSWORD=密码 bazel build //examples/apps/wifi_dns_lookup:esp \
      --define WIFI_SSID=网络名 \
      --action_env=WIFI_PASSWORD

  # 烧录
  WIFI_PASSWORD=密码 bazel run //examples/apps/wifi_dns_lookup:flash \
      --//bazel/esp:port=/dev/ttyUSB0 \
      --define WIFI_SSID=网络名 \
      --action_env=WIFI_PASSWORD
  ```

## http_speed_test

HTTP 下载测速。

**首先，在电脑上启动测试服务器：**
```bash
cd examples/apps/http_speed_test/server && python3 server.py
# 或者: bazel run //examples/apps/http_speed_test/server:run
```

- **Zig / ESP32-S3-DevKit**
  ```bash
  WIFI_PASSWORD=密码 bazel build //examples/apps/http_speed_test:esp \
      --define WIFI_SSID=网络名 \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD

  WIFI_PASSWORD=密码 bazel run //examples/apps/http_speed_test:flash \
      --//bazel/esp:port=/dev/ttyUSB0 \
      --define WIFI_SSID=网络名 \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD
  ```

## https_speed_test

HTTPS 下载测速（带 TLS）。

**首先，启动 HTTPS 测试服务器：**
```bash
cd examples/apps/https_speed_test/server && python3 server.py
# 或者: bazel run //examples/apps/https_speed_test/server:run
```

- **Zig / ESP32-S3-DevKit**
  ```bash
  WIFI_PASSWORD=密码 bazel build //examples/apps/https_speed_test:esp \
      --define WIFI_SSID=网络名 \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD

  WIFI_PASSWORD=密码 bazel run //examples/apps/https_speed_test:flash \
      --//bazel/esp:port=/dev/ttyUSB0 \
      --define WIFI_SSID=网络名 \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD
  ```

## memory_attr_test

PSRAM/IRAM 内存分配测试。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/memory_attr_test:esp
  bazel run //examples/apps/memory_attr_test:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## ui_demo

UI 组件演示（仅桌面模拟器）。

- **Zig / 桌面模拟器 (Raylib)**
  ```bash
  bazel run //examples/raysim/ui_demo:run
  ```
