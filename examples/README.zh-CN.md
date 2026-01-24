# 示例项目

使用 Zig 编写的 ESP-IDF 示例，附带 C 语言对照版本。

## 开发板

所有示例基于以下开发板进行开发和测试：

| 项目 | 值 |
|------|-------|
| **开发板** | ESP32-S3-DevKitC-1（或兼容板） |
| **芯片** | ESP32-S3 |
| **Flash** | 16MB |
| **PSRAM** | 8MB（Octal SPI） |
| **ESP-IDF** | v5.4.0 |
| **Zig** | 0.15.x（Espressif 分支） |

## 示例列表

| 示例 | 描述 | 状态 |
|---------|-------------|--------|
| [led_strip_flash](./led_strip_flash/) | WS2812 LED 灯带控制 | ✅ 可用 |
| [memory_attr_test](./memory_attr_test/) | IRAM/DRAM/PSRAM 内存位置测试 | ✅ 可用 |
| [wifi_dns_lookup](./wifi_dns_lookup/) | WiFi 连接 + DNS 查询（UDP/TCP） | ✅ 可用 |
| [http_speed_test](./http_speed_test/) | HTTP 下载测速（C 与 Zig 对比） | 🚧 新增 |

## 项目结构

每个示例遵循以下结构：

```
example_name/
├── README.md           # 英文文档
├── README.zh-CN.md     # 中文文档
├── zig/                # Zig 实现
│   ├── CMakeLists.txt
│   ├── sdkconfig.defaults
│   └── main/
│       ├── CMakeLists.txt
│       ├── build.zig
│       ├── build.zig.zon
│       └── src/
│           ├── main.zig
│           └── main.c   # C 辅助函数（如需要）
└── c/                  # C 实现（用于对比）
    ├── CMakeLists.txt
    ├── sdkconfig.defaults
    └── main/
        └── main.c
```

## 构建和烧录

```bash
# 进入示例目录
cd examples/led_strip_flash/zig

# 设置目标芯片（首次）
idf.py set-target esp32s3

# 配置（如需要）
idf.py menuconfig

# 构建
idf.py build

# 烧录并监控
idf.py -p /dev/cu.usbmodem* flash monitor
```

## WiFi 配置

对于 WiFi 示例，需要配置 SSID 和密码：

```bash
idf.py menuconfig
# 导航到: WiFi DNS Lookup Configuration
# 设置 WIFI_SSID 和 WIFI_PASSWORD
```

或编辑 `sdkconfig.defaults`：

```
CONFIG_WIFI_SSID="你的SSID"
CONFIG_WIFI_PASSWORD="你的密码"
```
