# 快速开始

中文 | [English](./bootstrap.md)

## TL;DR

```bash
# 1. 下载支持 Xtensa 的 Zig
curl -LO https://github.com/haivivi/embed-zig/releases/download/zig-0.14.0-xtensa/zig-aarch64-macos-none-baseline.tar.xz
tar -xJf zig-aarch64-macos-none-baseline.tar.xz
export PATH=$PWD/zig-aarch64-macos-none-baseline:$PATH

# 2. 设置 ESP-IDF
cd ~/esp/esp-idf && source export.sh

# 3. 编译烧录示例
cd examples/esp/led_strip_flash/zig
idf.py build && idf.py flash monitor
```

完成。你的 LED 应该在闪烁了。

---

## 详细设置

### 1. 预编译 Zig 编译器

标准 Zig 不支持 Xtensa（ESP32 的架构）。下载我们的预编译版本：

| 平台 | 下载 |
|------|------|
| macOS ARM64 | `zig-aarch64-macos-none-baseline.tar.xz` |
| macOS x86_64 | `zig-x86_64-macos-none-baseline.tar.xz` |
| Linux x86_64 | `zig-x86_64-linux-gnu-baseline.tar.xz` |
| Linux ARM64 | `zig-aarch64-linux-gnu-baseline.tar.xz` |

[从 GitHub Releases 下载 →](https://github.com/haivivi/embed-zig/releases)

```bash
# 验证 Xtensa 支持
zig targets | grep xtensa
# 应该显示: xtensa-esp32, xtensa-esp32s2, xtensa-esp32s3
```

### 2. ESP-IDF 环境

embed-zig 与 ESP-IDF 集成。先安装它：

```bash
# 克隆 ESP-IDF (推荐 v5.x)
mkdir -p ~/esp && cd ~/esp
git clone --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32s3

# 激活环境（每个终端会话都需要）
source ~/esp/esp-idf/export.sh
```

### 3. 克隆本仓库

```bash
git clone https://github.com/haivivi/embed-zig.git
cd embed-zig
```

### 4. 编译示例

```bash
cd examples/esp/led_strip_flash/zig

# 设置目标芯片
idf.py set-target esp32s3

# 编译
idf.py build

# 烧录并监控
idf.py -p /dev/cu.usbmodem1301 flash monitor
# 按 Ctrl+] 退出监控
```

---

## 板子选择

很多示例支持多种板子。用 `-DZIG_BOARD` 选择：

```bash
# ESP32-S3-DevKitC (默认)
idf.py build

# ESP32-S3-Korvo-2 V3.1
idf.py -DZIG_BOARD=korvo2_v3 build
```

| 板子 | 参数 | 特性 |
|------|------|------|
| ESP32-S3-DevKitC | `esp32s3_devkit` | GPIO 按钮，单色 LED |
| ESP32-S3-Korvo-2 | `korvo2_v3` | ADC 按钮，RGB LED 灯带 |

---

## 作为依赖使用

添加到你的 `build.zig.zon`：

```zig
.dependencies = .{
    .hal = .{
        .url = "https://github.com/haivivi/embed-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",  // 运行 zig build 获取 hash
    },
    .esp = .{
        .url = "https://github.com/haivivi/embed-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

在你的 `build.zig` 中：

```zig
const hal = b.dependency("hal", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hal", hal.module("hal"));
```

---

## 常见问题

### "xtensa-esp32s3-elf-gcc not found"

ESP-IDF 环境未激活：
```bash
source ~/esp/esp-idf/export.sh
```

### "Stack overflow in main task"

在 `sdkconfig.defaults` 中增加栈大小：
```
CONFIG_ESP_MAIN_TASK_STACK_SIZE=8192
```

然后重新编译：
```bash
rm sdkconfig && idf.py fullclean && idf.py build
```

### "sdkconfig.defaults 修改不生效"

```bash
rm sdkconfig && idf.py fullclean && idf.py build
```

### Zig 缓存问题

```bash
rm -rf .zig-cache build
idf.py fullclean && idf.py build
```

---

## 为什么需要定制 Zig 编译器？

Zig 官方版本不包含 Xtensa 后端支持。ESP32（原版）、ESP32-S2 和 ESP32-S3 使用 Xtensa 内核。

我们维护一个分支：
1. 合并 Espressif 的 LLVM Xtensa 补丁
2. 基于打过补丁的 LLVM 编译 Zig
3. 为常见平台提供预编译二进制

ESP32-C3/C6 使用 RISC-V，可以用标准 Zig。但对于 Xtensa 芯片，你需要我们的构建版本。

如果你想自己编译，参见 [bootstrap/](https://github.com/haivivi/embed-zig/tree/main/bootstrap)。
