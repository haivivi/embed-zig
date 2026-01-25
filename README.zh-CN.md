# embed-zig

中文文档 | [English](./README.md)

用于嵌入式开发的 Zig 库，通过 Espressif 的 LLVM 分支支持 ESP32。

📚 **[在线文档](https://haivivi.github.io/embed-zig/)**

## 特性

- **ESP-IDF 绑定** - ESP-IDF API 的惯用 Zig 封装
- **系统抽象层** - 跨平台的线程、同步和时间原语
- **预编译 Zig 编译器** - 支持 Xtensa 架构的 Zig

## 快速开始

### 使用库

添加到你的 `build.zig.zon`：

```zig
.dependencies = .{
    .esp = .{
        .url = "https://github.com/haivivi/embed-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

在代码中使用：

```zig
const esp = @import("esp");

pub fn main() !void {
    // GPIO
    try esp.gpio.configOutput(48);
    try esp.gpio.setLevel(48, 1);

    // WiFi
    var wifi = try esp.Wifi.init();
    try wifi.connect(.{ .ssid = "MyNetwork", .password = "secret" });

    // Timer
    var timer = try esp.Timer.init(.{ .callback = myCallback });
    try timer.start(1000000); // 1 秒
}
```

## 预编译 Zig 编译器

从 [GitHub Releases](https://github.com/haivivi/embed-zig/releases) 下载支持 Xtensa 的 Zig。

| 平台 | 下载文件 |
|------|----------|
| macOS ARM64 | `zig-aarch64-macos-none-baseline.tar.xz` |
| macOS x86_64 | `zig-x86_64-macos-none-baseline.tar.xz` |
| Linux x86_64 | `zig-x86_64-linux-gnu-baseline.tar.xz` |
| Linux ARM64 | `zig-aarch64-linux-gnu-baseline.tar.xz` |

```bash
# 下载并解压（以 macOS ARM64 为例）
curl -LO https://github.com/haivivi/embed-zig/releases/download/espressif-0.15.2/zig-aarch64-macos-none-baseline.tar.xz
tar -xJf zig-aarch64-macos-none-baseline.tar.xz

# 验证 Xtensa 支持
./zig-aarch64-macos-none-baseline/zig targets | grep xtensa
```

## 库模块

### ESP (`esp`)

ESP-IDF 绑定：

| 模块 | 描述 |
|------|------|
| `gpio` | 数字 I/O 控制 |
| `wifi` | WiFi 站点模式 |
| `http` | HTTP 客户端 |
| `nvs` | 非易失性存储 |
| `timer` | 硬件定时器 |
| `led_strip` | 可寻址 LED 控制 |
| `adc` | 模数转换 |
| `ledc` | PWM 生成 |
| `sal` | 系统抽象层（FreeRTOS） |

### SAL (`sal`)

跨平台抽象：

| 模块 | 描述 |
|------|------|
| `thread` | 任务/线程管理 |
| `sync` | 互斥锁、信号量、事件 |
| `time` | 休眠和延时函数 |

## 示例

查看 [`examples/`](./examples/) 目录：

| 示例 | 描述 |
|------|------|
| `gpio_button` | 带中断的按钮输入 |
| `led_strip_flash` | WS2812 LED 灯带控制 |
| `http_speed_test` | HTTP 下载速度测试 |
| `wifi_dns_lookup` | WiFi DNS 解析 |
| `timer_callback` | 硬件定时器回调 |
| `nvs_storage` | 非易失性存储 |
| `pwm_fade` | PWM LED 渐变 |
| `temperature_sensor` | 内部温度传感器 |

### 运行示例

```bash
# 1. 设置 ESP-IDF 环境
cd ~/esp/esp-idf && source export.sh

# 2. 进入示例目录
cd examples/esp/led_strip_flash/zig

# 3. 设置目标芯片
idf.py set-target esp32s3

# 4. 构建和烧录
idf.py build
idf.py flash monitor
```

## 构建编译器

从源码构建支持 Xtensa 的 Zig：

```bash
cd bootstrap
./bootstrap.sh esp/0.15.2 <target> baseline
```

**目标平台：**
- `aarch64-macos-none` - macOS ARM64
- `x86_64-macos-none` - macOS x86_64
- `x86_64-linux-gnu` - Linux x86_64
- `aarch64-linux-gnu` - Linux ARM64

## 项目结构

```
embed-zig/
├── lib/
│   ├── esp/              # ESP-IDF 绑定
│   │   └── src/
│   │       ├── gpio.zig
│   │       ├── wifi/
│   │       ├── http.zig
│   │       └── ...
│   └── sal/              # 系统抽象层
│       └── src/
│           ├── thread.zig
│           ├── sync.zig
│           └── time.zig
├── examples/
│   └── esp/              # ESP32 示例
├── bootstrap/
│   └── esp/              # 编译器构建脚本
│       ├── 0.14.0/
│       └── 0.15.2/
└── README.md
```

## 许可证

本项目包含以下项目的补丁和构建脚本：
- Zig 编程语言
- LLVM 项目（Espressif 分支）

请参考各上游项目的许可证。

## 致谢

- [ziglang/zig-bootstrap](https://github.com/ziglang/zig-bootstrap)
- [espressif/llvm-project](https://github.com/espressif/llvm-project)
- [ESP-IDF](https://github.com/espressif/esp-idf)
- [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)
