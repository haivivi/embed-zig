# 快速开始

中文 | [English](./bootstrap.md)

## 前置要求

### 1. 安装 Bazel

```bash
# macOS
brew install bazel

# Linux (Ubuntu/Debian)
sudo apt install apt-transport-https curl gnupg
curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > bazel.gpg
sudo mv bazel.gpg /etc/apt/trusted.gpg.d/
echo "deb [arch=amd64] https://storage.googleapis.com/bazel-apt stable jdk1.8" | sudo tee /etc/apt/sources.list.d/bazel.list
sudo apt update && sudo apt install bazel
```

### 2. 安装 ESP-IDF

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
git clone https://github.com/haivivi/zig-bootstrap.git
cd zig-bootstrap
```

---

## 快速上手

```bash
# 激活 ESP-IDF
source ~/esp/esp-idf/export.sh

# 编译示例
bazel build //examples/apps/led_strip_flash:esp

# 烧录到设备
bazel run //examples/apps/led_strip_flash:flash --//bazel:port=/dev/ttyUSB0
```

完成。你的 LED 应该在闪烁了。

---

## 编译命令

### 编译

```bash
bazel build //examples/apps/<名称>:esp
```

### 烧录

```bash
bazel run //examples/apps/<名称>:flash --//bazel:port=/dev/ttyUSB0
```

### 板子选择

```bash
# ESP32-S3-DevKitC (默认)
bazel build //examples/apps/gpio_button:esp

# ESP32-S3-Korvo-2 V3
bazel build //examples/apps/gpio_button:esp --//bazel:board=korvo2_v3
```

| 板子 | 参数 | 特性 |
|------|------|------|
| ESP32-S3-DevKitC | `esp32s3_devkit` | GPIO 按钮，单色 LED |
| ESP32-S3-Korvo-2 | `korvo2_v3` | ADC 按钮，RGB LED 灯带，麦克风 |

### 环境变量（WiFi 示例）

```bash
# 传递 WiFi 凭证
WIFI_PASSWORD=密码 bazel build //examples/apps/wifi_dns_lookup:esp \
    --define WIFI_SSID=网络名 \
    --action_env=WIFI_PASSWORD
```

---

## 常见问题

### "xtensa-esp32s3-elf-gcc not found"

ESP-IDF 环境未激活：
```bash
source ~/esp/esp-idf/export.sh
```

### Bazel 缓存问题

```bash
bazel clean --expunge
```

### 拉取更新后编译错误

```bash
bazel clean
bazel build //examples/apps/<名称>:esp
```

---

## 为什么用 Bazel？

- **封闭式构建**：Zig 工具链自动下载
- **缓存**：只重新编译改动的部分
- **跨平台**：macOS 和 Linux 使用相同命令
- **可复现**：相同源码 = 相同二进制

支持 Xtensa 的 Zig 编译器由 Bazel 自动获取，无需手动下载。

---

## 备选：直接使用 idf.py

如果你更习惯直接用 ESP-IDF：

```bash
cd examples/esp/led_strip_flash/zig
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

注意：这需要手动下载支持 Xtensa 的 Zig 编译器。
