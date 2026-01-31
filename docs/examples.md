# Examples

[中文](./examples.zh-CN.md) | English

## Build & Flash

All examples follow the same pattern:

```bash
# Build
bazel build //examples/apps/<name>:esp

# Flash (specify port)
bazel run //examples/apps/<name>:flash --//bazel/esp:port=/dev/ttyUSB0
```

## gpio_button

Button input with LED toggle.

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

- **Zig / Desktop Simulator (Raylib)**
  ```bash
  bazel run //examples/raysim/gpio_button:run
  ```

## led_strip_flash

RGB LED strip blinking.

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

LED animation effects.

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

ADC-based button matrix.

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/adc_button:esp --//bazel/esp:board=korvo2_v3
  bazel run //examples/apps/adc_button:flash --//bazel/esp:port=/dev/ttyUSB1
  ```

## timer_callback

Hardware timer callbacks.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/timer_callback:esp
  bazel run //examples/apps/timer_callback:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## pwm_fade

LED brightness fading.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/pwm_fade:esp
  bazel run //examples/apps/pwm_fade:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## temperature_sensor

Internal temperature sensor.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/temperature_sensor:esp
  bazel run //examples/apps/temperature_sensor:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## nvs_storage

Persistent key-value storage.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/nvs_storage:esp
  bazel run //examples/apps/nvs_storage:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## speaker_test

Speaker audio output with ES8311 DAC. Plays a 440Hz sine wave tone.

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/speaker_test:esp
  bazel run //examples/apps/speaker_test:flash --//bazel/esp:port=/dev/cu.usbserial-120
  ```

## wifi_dns_lookup

WiFi connection + DNS resolution.

**Environment variables:**
- `WIFI_SSID` - WiFi network name (via `--define`)
- `WIFI_PASSWORD` - WiFi password (via `--action_env` for security)

- **Zig / ESP32-S3-DevKit**
  ```bash
  # Build with WiFi credentials
  WIFI_PASSWORD=secret bazel build //examples/apps/wifi_dns_lookup:esp \
      --define WIFI_SSID=MyNetwork \
      --action_env=WIFI_PASSWORD

  # Flash
  WIFI_PASSWORD=secret bazel run //examples/apps/wifi_dns_lookup:flash \
      --//bazel/esp:port=/dev/ttyUSB0 \
      --define WIFI_SSID=MyNetwork \
      --action_env=WIFI_PASSWORD
  ```

## http_speed_test

HTTP download benchmark.

**First, start the test server on your computer:**
```bash
cd examples/apps/http_speed_test/server && python3 server.py
# Or: bazel run //examples/apps/http_speed_test/server:run
```

- **Zig / ESP32-S3-DevKit**
  ```bash
  WIFI_PASSWORD=secret bazel build //examples/apps/http_speed_test:esp \
      --define WIFI_SSID=MyNetwork \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD

  WIFI_PASSWORD=secret bazel run //examples/apps/http_speed_test:flash \
      --//bazel/esp:port=/dev/ttyUSB0 \
      --define WIFI_SSID=MyNetwork \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD
  ```

## https_speed_test

HTTPS download benchmark with TLS.

**First, start the HTTPS test server:**
```bash
cd examples/apps/https_speed_test/server && python3 server.py
# Or: bazel run //examples/apps/https_speed_test/server:run
```

- **Zig / ESP32-S3-DevKit**
  ```bash
  WIFI_PASSWORD=secret bazel build //examples/apps/https_speed_test:esp \
      --define WIFI_SSID=MyNetwork \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD

  WIFI_PASSWORD=secret bazel run //examples/apps/https_speed_test:flash \
      --//bazel/esp:port=/dev/ttyUSB0 \
      --define WIFI_SSID=MyNetwork \
      --define TEST_SERVER_IP=192.168.1.100 \
      --action_env=WIFI_PASSWORD
  ```

## memory_attr_test

PSRAM/IRAM memory placement test.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/memory_attr_test:esp
  bazel run //examples/apps/memory_attr_test:flash --//bazel/esp:port=/dev/ttyUSB0
  ```

## ui_demo

UI components demo (desktop simulator only).

- **Zig / Desktop Simulator (Raylib)**
  ```bash
  bazel run //examples/raysim/ui_demo:run
  ```
