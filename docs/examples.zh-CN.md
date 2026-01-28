# 示例

中文 | [English](./examples.md)

所有示例位于 `examples/`。每个示例演示特定的 HAL 组件或 ESP-IDF 功能。

## 快速索引

| 示例 | 说明 | HAL 组件 | 板子 |
|------|------|----------|:----:|
| [gpio_button](#gpio_button) | 按钮输入控制 LED | Button, LedStrip | ①②③ |
| [led_strip_flash](#led_strip_flash) | RGB LED 闪烁 | LedStrip | ①②③ |
| [led_strip_anim](#led_strip_anim) | LED 动画效果 | LedStrip | ①②③ |
| [adc_button](#adc_button) | ADC 按钮矩阵 | ButtonGroup | ② |
| [timer_callback](#timer_callback) | 硬件定时器回调 | LedStrip + idf.timer | ① |
| [pwm_fade](#pwm_fade) | LED 亮度渐变 | Led (PWM) | ① |
| [temperature_sensor](#temperature_sensor) | 内部温度传感器 | TempSensor | ①② |
| [nvs_storage](#nvs_storage) | 持久化键值存储 | Kvs | ①② |
| [wifi_dns_lookup](#wifi_dns_lookup) | WiFi + DNS 解析 | (直接 idf) | ①② |
| [http_speed_test](#http_speed_test) | HTTP 下载测速 | (直接 idf) | ①② |
| [https_speed_test](#https_speed_test) | HTTPS 下载测速 | (直接 idf) | ①② |
| [memory_attr_test](#memory_attr_test) | PSRAM/IRAM 测试 | (直接 idf) | ①② |

> ① ESP32-S3-DevKit　② Korvo-2 V3.1　③ Raylib 模拟器

---

## 运行示例

### ESP32（硬件）- Bazel

```bash
# 编译
bazel build //examples/esp/<示例名>/zig:app

# 烧录（自动检测串口）
bazel run //examples/esp/<示例名>/zig:flash

# 监控
bazel run //examples/esp/<示例名>/zig:monitor
```

**选项：**

```bash
# 指定板子（默认: esp32s3_devkit）
bazel build //target:app --//bazel/esp:board=korvo2_v3

# 指定芯片（默认: esp32s3）
bazel build //target:app --//bazel/esp:chip=esp32c3

# 指定串口
bazel run //target:flash --//bazel/esp:port=/dev/ttyUSB0
```

### ESP32（硬件）- idf.py

```bash
cd examples/esp/<示例名>/zig
idf.py set-target esp32s3
idf.py -DZIG_BOARD=<板子> build
idf.py -p <端口> flash monitor
```

### 桌面模拟（Raylib）

```bash
cd examples/raysim/<示例名>
zig build run
```

无需硬件。GUI 窗口模拟按钮和 LED。

---

## HAL 示例

### gpio_button

按下按钮切换 LED。演示事件驱动架构。

**ESP32：**
```bash
bazel build //examples/esp/gpio_button/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/gpio_button/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/gpio_button/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**模拟器：**
```bash
cd examples/raysim/gpio_button && zig build run
```

**演示内容：**
- `hal.Button` 带消抖
- `hal.LedStrip` 控制
- `Board.poll()` + `Board.nextEvent()` 模式

### led_strip_flash

简单的 RGB LED 1Hz 闪烁。

**ESP32：**
```bash
bazel build //examples/esp/led_strip_flash/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/led_strip_flash/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/led_strip_flash/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**模拟器：**
```bash
cd examples/raysim/led_strip_flash && zig build run
```

**演示内容：**
- `hal.LedStrip` 基本用法
- 颜色操作

### led_strip_anim

RGB LED 彩虹和呼吸动画。

**ESP32：**
```bash
bazel build //examples/esp/led_strip_anim/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/led_strip_anim/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/led_strip_anim/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**模拟器：**
```bash
cd examples/raysim/led_strip_anim && zig build run
```

**演示内容：**
- 动画状态机
- HSV 色彩空间
- 帧时序控制

### adc_button

单个 ADC 引脚连接多个按钮（分压器）。

**ESP32（仅 Korvo-2）：**
```bash
bazel build //examples/esp/adc_button/zig:app --//bazel/esp:board=korvo2_v3 --//bazel/esp:chip=esp32s3
bazel run //examples/esp/adc_button/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/adc_button/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**演示内容：**
- `hal.ButtonGroup` ADC 按钮
- 电压阈值配置
- Korvo-2 板子支持

**注意：** 只能在有 ADC 按钮矩阵的板子上运行（Korvo-2）。

### timer_callback

硬件定时器触发 LED 切换。

**ESP32：**
```bash
bazel build //examples/esp/timer_callback/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/timer_callback/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/timer_callback/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**演示内容：**
- `idf.timer` 集成
- 回调函数注册
- HAL + 直接 IDF 混合使用

### pwm_fade

用 PWM 控制 LED 亮度渐变。

**ESP32：**
```bash
bazel build //examples/esp/pwm_fade/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/pwm_fade/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/pwm_fade/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**演示内容：**
- `hal.Led` PWM 控制
- 硬件渐变支持
- 亮度控制 (0-65535)

**注意：** 使用 DevKit 的 GPIO48 LED。

### temperature_sensor

读取内部温度传感器。

**ESP32：**
```bash
bazel build //examples/esp/temperature_sensor/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/temperature_sensor/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/temperature_sensor/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**演示内容：**
- `hal.TempSensor` 用法
- 周期性传感器读取
- 摄氏度温度值

### nvs_storage

持久化存储，带启动计数器。

**ESP32：**
```bash
bazel build //examples/esp/nvs_storage/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/nvs_storage/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/nvs_storage/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**演示内容：**
- `hal.Kvs` NVS 访问
- 读写 u32 值
- 数据跨重启保持

---

## ESP 特定示例

这些示例直接使用 ESP-IDF，不经过 HAL 抽象。

### wifi_dns_lookup

连接 WiFi 并解析 DNS。

**ESP32：**
```bash
bazel build //examples/esp/wifi_dns_lookup/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/wifi_dns_lookup/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/wifi_dns_lookup/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**配置：** 在 `sdkconfig.defaults` 中设置 WiFi SSID/密码：
```
CONFIG_WIFI_SSID="你的网络"
CONFIG_WIFI_PASSWORD="你的密码"
```

### http_speed_test

HTTP 下载速度测量。需要先启动测试服务器。

**启动测试服务器：**
```bash
bazel run //examples/esp/http_speed_test/server:run
```

**ESP32（Zig）：**
```bash
cd examples/esp/http_speed_test/zig
idf.py set-target esp32s3
idf.py menuconfig  # 设置 TEST_SERVER_IP
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

**ESP32（C）：**
```bash
cd examples/esp/http_speed_test/c
idf.py set-target esp32s3
idf.py menuconfig  # 设置 TEST_SERVER_IP
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

**演示内容：**
- HTTP 客户端用法
- 下载速度计算
- 网络性能测试

### https_speed_test

HTTPS 下载速度测量，使用自签名证书。需要先启动测试服务器。

**启动 HTTPS 测试服务器：**
```bash
bazel run //examples/esp/https_speed_test/server:run
```

**ESP32（Zig）：**
```bash
cd examples/esp/https_speed_test/zig
idf.py set-target esp32s3
idf.py menuconfig  # 设置 TEST_SERVER_IP
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

**ESP32（C）：**
```bash
cd examples/esp/https_speed_test/c
idf.py set-target esp32s3
idf.py menuconfig  # 设置 TEST_SERVER_IP
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

**演示内容：**
- HTTPS 客户端用法
- 自签名证书验证
- TLS 连接性能测试

### memory_attr_test

测试 PSRAM 和 IRAM 内存分配。

**ESP32：**
```bash
bazel build //examples/esp/memory_attr_test/zig:app --//bazel/esp:board=esp32s3_devkit --//bazel/esp:chip=esp32s3
bazel run //examples/esp/memory_attr_test/zig:flash --//bazel/esp:port=/dev/ttyUSB0
bazel run //examples/esp/memory_attr_test/zig:monitor --//bazel/esp:port=/dev/ttyUSB0
```

**演示内容：**
- `linksection` 内存定位
- PSRAM 分配
- IRAM 用于性能关键代码

---

## 项目结构

```
examples/
├── apps/<名称>/              # 平台无关的应用逻辑
│   ├── app.zig               # 主应用
│   ├── platform.zig          # HAL spec + Board 类型
│   └── boards/               # 板子特定驱动
│       ├── esp32s3_devkit.zig
│       ├── korvo2_v3.zig
│       └── sim_raylib.zig    # 桌面模拟
├── esp/<名称>/zig/           # ESP32 入口点
│   └── main/
│       ├── src/main.zig
│       ├── build.zig
│       └── CMakeLists.txt
└── raysim/<名称>/            # 桌面模拟入口点
    ├── src/main.zig
    └── build.zig
```

这种分离让同一个 `app.zig` 可以跑在 ESP32 硬件或 Raylib GUI 桌面模拟上。
