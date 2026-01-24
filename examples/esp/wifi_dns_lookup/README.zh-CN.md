# WiFi DNS 查询

[English](./README.md)

WiFi 连接和 DNS 查询示例，演示自定义 DNS 解析器，支持接口绑定。

## 功能特性

- WiFi STA 模式连接
- 自定义 DNS 解析器（纯 Zig 实现）
- 支持 UDP 和 TCP DNS 协议
- 接口绑定支持（适用于多网卡场景，如 PPP + WLAN）
- 可配置 DNS 服务器

## 硬件要求

- 带 PSRAM 的 ESP32-S3（在 ESP32-S3-DevKitC-1 上测试）
- WiFi 网络接入

## 配置

构建前，配置 WiFi 凭据：

```bash
idf.py menuconfig
# 导航到: WiFi DNS Lookup Configuration
# 设置:
#   - WiFi SSID
#   - WiFi Password
```

## 构建和烧录

```bash
cd zig

# 设置目标芯片（首次）
idf.py set-target esp32s3

# 构建
idf.py build

# 烧录并监控
idf.py -p /dev/cu.usbmodem* flash monitor
```

## 预期输出

```
==========================================
  WiFi DNS Lookup - Zig Version
  Build Tag: wifi_dns_lookup_zig_v1
==========================================
=== Heap Memory Statistics ===
Internal DRAM: Total=... Free=... Used=...

Initializing WiFi...
Connecting to SSID: MyNetwork
Connected! IP: 192.168.1.100

=== DNS Lookup Test ===
--- UDP DNS (8.8.8.8) ---
www.google.com => 142.250.xxx.xxx
www.baidu.com => 110.242.xxx.xxx
cloudflare.com => 104.16.xxx.xxx
github.com => 140.82.xxx.xxx

--- TCP DNS (8.8.8.8) ---
www.google.com => 142.250.xxx.xxx
...

--- UDP DNS (1.1.1.1 Cloudflare) ---
example.com => 93.184.xxx.xxx

=== Test Complete ===
```

## API 使用

```zig
const idf = @import("esp");

// 初始化并连接 WiFi
var wifi = try idf.Wifi.init();
try wifi.connect(.{
    .ssid = "MyNetwork",
    .password = "password",
    .timeout_ms = 30000,
});

// UDP DNS 查询
var resolver = idf.DnsResolver{
    .server = .{ 8, 8, 8, 8 },  // Google DNS
    .protocol = .udp,
    .timeout_ms = 5000,
};
const ip = try resolver.resolve("example.com");

// TCP DNS 查询
var tcp_resolver = idf.DnsResolver{
    .server = .{ 1, 1, 1, 1 },  // Cloudflare DNS
    .protocol = .tcp,
};
const ip2 = try tcp_resolver.resolve("example.com");

// 带接口绑定的 DNS（适用于 PPP 场景）
var ppp_resolver = idf.DnsResolver{
    .server = .{ 10, 0, 0, 1 },  // PPP 网关 DNS
    .interface = "ppp0",         // 绑定到 PPP 接口
};
const ip3 = try ppp_resolver.resolve("example.com");
```

## 二进制大小与内存

### 二进制大小

| 版本 | .bin 大小 |
|------|-----------|
| **Zig** | 766,032 字节 (748 KB) |

### 内存占用（静态）

| 内存区域 | Zig |
|----------|-----|
| **IRAM** | 16,383 字节 |
| **DRAM** | 106,231 字节 |
| **Flash Code** | 553,150 字节 |

> 注：本示例仅有 Zig 版本，用于展示纯 Zig DNS 实现。

## 架构说明

由于 ESP-IDF 的 WiFi 配置结构体包含复杂的位域和联合体，`@cImport` 无法正确翻译，因此 WiFi 初始化使用 C 辅助函数：

- `esp/src/wifi.zig` - Zig 接口层
- `main/src/main.c` - C 辅助函数实现

DNS 解析器是纯 Zig 实现，使用 lwIP socket。
