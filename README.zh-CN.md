# Espressif Zig Bootstrap

中文文档 | [English](./README.md)

本项目基于 `ziglang/zig-bootstrap`，使用 `espressif/llvm-project` 替换 `llvm/llvm-project`，以支持 ESP32 的 Xtensa 架构开发。

## 主要改进

1. **版本控制**：使用 `wget` 拉取源代码，确保依赖版本锁定且可重现
2. **透明补丁**：使用 `patch` 文件修改代码，使所有改动明确且可审查

## 平台支持

目前仅在 **macOS** 上测试过。理论上 Linux 可以构建，但尚未测试。

## 快速开始

### 构建编译器

```bash
CMAKE_BUILD_PARALLEL_LEVEL=16 ./bootstrap.sh espressif-0.15.x aarch64-macos-none baseline
```

**可用版本：**
- `espressif-0.14.x` - 支持 Xtensa 的 Zig 0.14.x
- `espressif-0.15.x` - 支持 Xtensa 的 Zig 0.15.x（推荐）

### 运行示例

要构建和运行示例（例如 `led_strip_flash`）：

```bash
# 1. 进入 ESP-IDF 安装目录
pushd PATH_TO_IDF

# 2. 设置 ESP-IDF 环境
. export.sh

# 3. 返回项目目录
popd

# 4. 进入示例目录
cd examples/led_strip_flash

# 5. 设置目标芯片
idf.py set-target esp32s3

# 6. （可选）配置项目
idf.py menuconfig

# 7. 构建和烧录
idf.py build
idf.py flash monitor
```

## 项目结构

```
espressif-zig-bootstrap/
├── bootstrap.sh              # 引导脚本
├── espressif-0.14.x/         # Zig 0.14.x 支持
│   ├── espressif.patch       # Xtensa 支持补丁
│   ├── llvm-project          # Espressif LLVM 的 URL
│   └── zig-bootstrap         # Zig bootstrap 的 URL
├── espressif-0.15.x/         # Zig 0.15.x 支持（推荐）
│   ├── espressif.patch       # Xtensa 支持补丁
│   ├── llvm-project          # Espressif LLVM 的 URL
│   └── zig-bootstrap         # Zig bootstrap 的 URL
└── examples/
    └── led_strip_flash/      # Zig 编写的 LED 灯带示例
```

## 构建产物

运行引导脚本后，您将得到：

- 支持 Xtensa 的 Zig 编译器，位于：`espressif-0.15.x/.out/zig-<target>-<mcpu>/bin/zig`
- 启用了 Espressif Xtensa 后端的 LLVM
- ESP32 开发所需的所有库和工具

## 环境设置

要在 ESP-IDF 中使用构建的编译器：

```bash
export ZIG_INSTALL=/path/to/espressif-zig-bootstrap/espressif-0.15.x/.out/zig-aarch64-macos-none-baseline/bin
```

## 许可证

本项目包含以下项目的补丁和构建脚本：
- Zig 编程语言
- LLVM 项目（Espressif 分支）
- Zig Bootstrap

请参考各上游项目的许可证。

## 致谢

- [ziglang/zig-bootstrap](https://github.com/ziglang/zig-bootstrap)
- [espressif/llvm-project](https://github.com/espressif/llvm-project)
- [ESP-IDF](https://github.com/espressif/esp-idf)
- [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)
- [gpanders/esp32-zig-starter](https://github.com/gpanders/esp32-zig-starter)
- [kassane/zig-esp-idf-sample](https://github.com/kassane/zig-esp-idf-sample)
