# Examples

[中文](./examples.zh-CN.md) | English

## gpio_button

Button input with LED toggle.

- **Zig / ESP32-S3-DevKit** (bin: 252KB, RAM: 390KB)
  ```bash
  bazel build //examples/esp/gpio_button/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/gpio_button/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/gpio_button/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3** (bin: 253KB, RAM: 390KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/gpio_button/zig:app --//bazel/esp:board=korvo2_v3
  bazel run //examples/esp/gpio_button/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB1
  bazel run //examples/esp/gpio_button/zig:monitor --//bazel/esp:port=/dev/ttyUSB1
  ```

- **Zig / Desktop Simulator (Raylib)**
  ```bash
  bazel run //examples/raysim/gpio_button:run
  ```

- **C / ESP32-S3** (bin: 220KB, RAM: 392KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/gpio_button/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## led_strip_flash

RGB LED strip blinking.

- **Zig / ESP32-S3-DevKit** (bin: 249KB, RAM: 391KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/led_strip_flash/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/led_strip_flash/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/led_strip_flash/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3** (bin: 244KB, RAM: 391KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/led_strip_flash/zig:app --//bazel/esp:board=korvo2_v3
  bazel run //examples/esp/led_strip_flash/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB1
  bazel run //examples/esp/led_strip_flash/zig:monitor --//bazel/esp:port=/dev/ttyUSB1
  ```

- **C / ESP32-S3** (bin: 218KB, RAM: 392KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/led_strip_flash/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## led_strip_anim

LED animation effects.

- **Zig / ESP32-S3-DevKit** (bin: 243KB, RAM: 391KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/led_strip_anim/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/led_strip_anim/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/led_strip_anim/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **Zig / Korvo-2 V3** (bin: 243KB, RAM: 391KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/led_strip_anim/zig:app --//bazel/esp:board=korvo2_v3
  bazel run //examples/esp/led_strip_anim/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB1
  bazel run //examples/esp/led_strip_anim/zig:monitor --//bazel/esp:port=/dev/ttyUSB1
  ```

## adc_button

ADC-based button matrix.

- **Zig / Korvo-2 V3** (bin: 219KB, RAM: 397KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/adc_button/zig:app --//bazel/esp:board=korvo2_v3
  bazel run //examples/esp/adc_button/zig:flash --//bazel/esp:board=korvo2_v3 --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB1
  bazel run //examples/esp/adc_button/zig:monitor --//bazel/esp:port=/dev/ttyUSB1
  ```

## timer_callback

Hardware timer callbacks.

- **Zig / ESP32-S3-DevKit** (bin: 235KB, RAM: 391KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/timer_callback/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/timer_callback/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/timer_callback/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **C / ESP32-S3** (bin: 222KB, RAM: 391KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/timer_callback/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## pwm_fade

LED brightness fading.

- **Zig / ESP32-S3-DevKit** (bin: 210KB, RAM: 396KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/pwm_fade/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/pwm_fade/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/pwm_fade/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **C / ESP32-S3** (bin: 201KB, RAM: 396KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/pwm_fade/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## temperature_sensor

Internal temperature sensor.

- **Zig / ESP32-S3-DevKit** (bin: 206KB, RAM: 397KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/temperature_sensor/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/temperature_sensor/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/temperature_sensor/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **C / ESP32-S3** (bin: 197KB, RAM: 397KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/temperature_sensor/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## nvs_storage

Persistent key-value storage.

- **Zig / ESP32-S3-DevKit** (bin: 223KB, RAM: 396KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/nvs_storage/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/nvs_storage/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/nvs_storage/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **C / ESP32-S3** (bin: 223KB, RAM: 396KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/nvs_storage/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## wifi_dns_lookup

WiFi + DNS resolution.

- **Zig / ESP32-S3-DevKit** (bin: 869KB, RAM: 345KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/wifi_dns_lookup/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/wifi_dns_lookup/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/wifi_dns_lookup/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **C / ESP32-S3** (bin: 854KB, RAM: 344KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/wifi_dns_lookup/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## http_speed_test

HTTP download benchmark. Requires running the test server on your computer.

**First, start the test server:**
```bash
bazel run //examples/esp/http_speed_test/server:run
```

- **Zig / ESP32-S3-DevKit** (bin: 758KB)
  ```bash
  cd examples/esp/http_speed_test/zig
  idf.py set-target esp32s3
  idf.py menuconfig  # Set TEST_SERVER_IP
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

- **C / ESP32-S3** (bin: 861KB)
  ```bash
  cd examples/esp/http_speed_test/c
  idf.py set-target esp32s3
  idf.py menuconfig  # Set TEST_SERVER_IP
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## https_speed_test

HTTPS download benchmark with self-signed certificates. Requires running the test server.

**First, start the HTTPS test server:**
```bash
bazel run //examples/esp/https_speed_test/server:run
```

- **Zig / ESP32-S3-DevKit** (bin: 813KB)
  ```bash
  cd examples/esp/https_speed_test/zig
  idf.py set-target esp32s3
  idf.py menuconfig  # Set TEST_SERVER_IP
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

- **C / ESP32-S3** (bin: 862KB)
  ```bash
  cd examples/esp/https_speed_test/c
  idf.py set-target esp32s3
  idf.py menuconfig  # Set TEST_SERVER_IP
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## memory_attr_test

PSRAM/IRAM placement.

- **Zig / ESP32-S3-DevKit** (bin: 212KB, RAM: 397KB, PSRAM: 8MB)
  ```bash
  bazel build //examples/esp/memory_attr_test/zig:app --//bazel/esp:board=esp32s3_devkit
  bazel run //examples/esp/memory_attr_test/zig:flash --//bazel/esp:chip=esp32s3 --//bazel/esp:port=/dev/ttyUSB0
  bazel run //examples/esp/memory_attr_test/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
  ```

- **C / ESP32-S3** (bin: 195KB, RAM: 397KB, PSRAM: 8MB)
  ```bash
  cd examples/esp/memory_attr_test/c
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/ttyUSB0 flash monitor
  ```

## ui_demo

UI components demo (desktop only).

- **Zig / Desktop Simulator (Raylib)**
  ```bash
  bazel run //examples/raysim/ui_demo:run
  ```
