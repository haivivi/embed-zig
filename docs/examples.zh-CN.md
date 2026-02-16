# 示例

中文 | [English](./examples.md)

## 编译和烧录

所有示例使用相同的模式：

```bash
# 编译
bazel build //examples/apps/<名称>:esp

# 烧录（指定串口）
bazel run //examples/apps/<名称>:flash --//bazel:port=/dev/ttyUSB0
```

## gpio_button

按钮输入控制 LED 开关。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/gpio_button:esp
  bazel run //examples/apps/gpio_button:flash --//bazel:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/gpio_button:esp --//bazel:board=korvo2_v3
  bazel run //examples/apps/gpio_button:flash --//bazel:port=/dev/ttyUSB1
  ```

## led_strip_flash

RGB LED 灯带闪烁。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/led_strip_flash:esp
  bazel run //examples/apps/led_strip_flash:flash --//bazel:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/led_strip_flash:esp --//bazel:board=korvo2_v3
  bazel run //examples/apps/led_strip_flash:flash --//bazel:port=/dev/ttyUSB1
  ```

## led_strip_anim

LED 动画效果。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/led_strip_anim:esp
  bazel run //examples/apps/led_strip_anim:flash --//bazel:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/led_strip_anim:esp --//bazel:board=korvo2_v3
  bazel run //examples/apps/led_strip_anim:flash --//bazel:port=/dev/ttyUSB1
  ```

## adc_button

ADC 按钮矩阵。

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/adc_button:esp --//bazel:board=korvo2_v3
  bazel run //examples/apps/adc_button:flash --//bazel:port=/dev/ttyUSB1
  ```

## timer_callback

硬件定时器回调。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/timer_callback:esp
  bazel run //examples/apps/timer_callback:flash --//bazel:port=/dev/ttyUSB0
  ```

## pwm_fade

LED 亮度渐变。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/pwm_fade:esp
  bazel run //examples/apps/pwm_fade:flash --//bazel:port=/dev/ttyUSB0
  ```

## temperature_sensor

内部温度传感器。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/temperature_sensor:esp
  bazel run //examples/apps/temperature_sensor:flash --//bazel:port=/dev/ttyUSB0
  ```

## nvs_storage

持久化键值存储。

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/nvs_storage:esp
  bazel run //examples/apps/nvs_storage:flash --//bazel:port=/dev/ttyUSB0
  ```

## speaker_test

ES8311 DAC 扬声器音频输出。播放 440Hz 正弦波测试音。

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/speaker_test:esp
  bazel run //examples/apps/speaker_test:flash --//bazel:port=/dev/cu.usbserial-120
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
      --//bazel:port=/dev/ttyUSB0 \
      --define WIFI_SSID=网络名 \
      --action_env=WIFI_PASSWORD
  ```

## E2E 测试和性能基准

功能测试和性能基准已迁移到 `e2e/` 目录。
CI 目标详见 `e2e/ci/BUILD.bazel`。

```bash
# 编译所有 ESP e2e 目标
bazel build //e2e/ci:build_all_e2e_esp --config=ci

# 运行本地测试（无需硬件）
bazel build //e2e/ci:test_all_std
```
