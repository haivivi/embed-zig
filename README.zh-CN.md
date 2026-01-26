# embed-zig

中文 | [English](./README.md)

 

**用于嵌入式开发的 Zig 库。**

*从裸机到应用层，从 ESP32 到桌面模拟，*
*一种语言，一套抽象，到处运行。*

 

[文档](https://haivivi.github.io/embed-zig/) · [API 参考](https://haivivi.github.io/embed-zig/api/) · [示例](./examples/)

---

## 概述

embed-zig 为嵌入式系统提供统一的开发体验。应用逻辑只写一次——今天跑在 ESP32 硬件上，明天在桌面模拟器里运行。

### 核心特性

- **HAL** — 板子无关的硬件抽象（按钮、LED、传感器）
- **SAL** — 跨平台系统原语（线程、同步、时间）
- **ESP** — ESP-IDF 的地道 Zig 绑定
- **Raysim** — 基于 Raylib 的桌面模拟
- **预编译 Zig** — 支持 ESP32 Xtensa 架构的编译器

---

## 快速开始

```bash
# 下载支持 Xtensa 的 Zig
curl -LO https://github.com/haivivi/embed-zig/releases/download/zig-0.14.0-xtensa/zig-aarch64-macos-none-baseline.tar.xz
tar -xJf zig-aarch64-macos-none-baseline.tar.xz && export PATH=$PWD/zig-aarch64-macos-none-baseline:$PATH

# 设置 ESP-IDF 并编译示例
cd ~/esp/esp-idf && source export.sh
cd examples/esp/led_strip_flash/zig && idf.py build && idf.py flash monitor
```

或者在模拟器中运行（无需硬件）：

```bash
cd examples/raysim/gpio_button && zig build run
```

---

## 文档

| 文档 | 说明 |
|------|------|
| [简介](./docs/intro.zh-CN.md) | 项目愿景、理念、设计目标 |
| [快速开始](./docs/bootstrap.zh-CN.md) | 环境设置、编译、常见问题 |
| [示例](./docs/examples.zh-CN.md) | 示例清单与运行命令 |
| [架构](./docs/design.zh-CN.md) | SAL / HAL / ESP / Raysim 设计 |

---

## 支持的平台

| 平台 | 状态 | 说明 |
|------|:----:|------|
| ESP32-S3-DevKit | ✅ | GPIO 按钮，单色 LED |
| ESP32-S3-Korvo-2 | ✅ | ADC 按钮，RGB 灯带 |
| Raylib 模拟器 | ✅ | 桌面 GUI 模拟 |
| ESP32-C3/C6 (RISC-V) | 🚧 | 标准 Zig 可用 |

---

## 项目结构

```
embed-zig/
├── lib/
│   ├── hal/          # 硬件抽象层
│   ├── sal/          # 系统抽象层（接口）
│   ├── esp/          # ESP-IDF 绑定 + SAL 实现
│   └── raysim/       # Raylib 模拟 + SAL 实现
├── examples/
│   ├── apps/         # 平台无关的应用逻辑
│   ├── esp/          # ESP32 入口点
│   └── raysim/       # 桌面模拟入口点
└── bootstrap/        # Zig 编译器构建脚本
```

---

## 许可证

Apache License 2.0。见 [LICENSE](./LICENSE)。

本项目包含 Zig 和 LLVM（Espressif 分支）的补丁。相关许可证请参考上游项目。

---

## 致谢

- [ziglang/zig-bootstrap](https://github.com/ziglang/zig-bootstrap)
- [espressif/llvm-project](https://github.com/espressif/llvm-project)
- [ESP-IDF](https://github.com/espressif/esp-idf)
- [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)

---

 

*"宇宙建立在层层抽象之上。好的软件也是。"*

 
