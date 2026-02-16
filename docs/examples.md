# Examples

[中文](./examples.zh-CN.md) | English

## Build & Flash

All examples follow the same pattern:

```bash
# Build
bazel build //examples/apps/<name>:esp

# Flash (specify port)
bazel run //examples/apps/<name>:flash --//bazel:port=/dev/ttyUSB0
```

## gpio_button

Button input with LED toggle.

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

RGB LED strip blinking.

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

LED animation effects.

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

ADC-based button matrix.

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/adc_button:esp --//bazel:board=korvo2_v3
  bazel run //examples/apps/adc_button:flash --//bazel:port=/dev/ttyUSB1
  ```

## timer_callback

Hardware timer callbacks.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/timer_callback:esp
  bazel run //examples/apps/timer_callback:flash --//bazel:port=/dev/ttyUSB0
  ```

## pwm_fade

LED brightness fading.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/pwm_fade:esp
  bazel run //examples/apps/pwm_fade:flash --//bazel:port=/dev/ttyUSB0
  ```

## temperature_sensor

Internal temperature sensor.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/temperature_sensor:esp
  bazel run //examples/apps/temperature_sensor:flash --//bazel:port=/dev/ttyUSB0
  ```

## nvs_storage

Persistent key-value storage.

- **Zig / ESP32-S3-DevKit**
  ```bash
  bazel build //examples/apps/nvs_storage:esp
  bazel run //examples/apps/nvs_storage:flash --//bazel:port=/dev/ttyUSB0
  ```

## speaker_test

Speaker audio output with ES8311 DAC. Plays a 440Hz sine wave tone.

- **Zig / Korvo-2 V3**
  ```bash
  bazel build //examples/apps/speaker_test:esp
  bazel run //examples/apps/speaker_test:flash --//bazel:port=/dev/cu.usbserial-120
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
      --//bazel:port=/dev/ttyUSB0 \
      --define WIFI_SSID=MyNetwork \
      --action_env=WIFI_PASSWORD
  ```

## E2E Tests & Benchmarks

Functional tests and benchmarks have been moved to the `e2e/` directory.
See `e2e/ci/BUILD.bazel` for CI targets.

```bash
# Build all ESP e2e targets
bazel build //e2e/ci:build_all_e2e_esp --config=ci

# Run native tests (no hardware needed)
bazel build //e2e/ci:test_all_std
```
