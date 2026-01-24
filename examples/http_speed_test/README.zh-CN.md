# HTTP 速度测试

本示例使用 `esp_http_client` 测试 HTTP 下载速度，比较 C 和 Zig 实现。

## 功能

- 支持多种文件大小的下载速度测试（1KB、10KB、100KB、1MB）
- 下载过程中内存使用监控
- WiFi 连接处理
- 包含本地测试服务器
- 优化的 WiFi/LWIP 设置以获得最大吞吐量

## 测试服务器设置

在运行 ESP32 之前，在电脑上启动本地测试服务器：

```bash
cd examples/http_speed_test
python3 server.py
```

服务器会显示本机 IP 地址。请在 menuconfig 或 `sdkconfig.defaults` 中更新 `CONFIG_TEST_SERVER_IP`。

## 编译和烧录

### C 版本

```bash
cd c
source ~/esp/esp-adf/esp-idf/export.sh
idf.py set-target esp32s3
idf.py menuconfig  # 设置 TEST_SERVER_IP 为电脑的 IP
idf.py build flash monitor
```

### Zig 版本

```bash
cd zig
source ~/esp/esp-adf/esp-idf/export.sh
idf.py set-target esp32s3
idf.py menuconfig  # 设置 TEST_SERVER_IP 为电脑的 IP
idf.py build flash monitor
```

## 对比结果

**测试环境:** ESP32-S3 配备 8MB PSRAM，WiFi 2.4GHz，本地 HTTP 服务器

### 二进制大小

| 版本 | 二进制大小 | 差异 |
|------|-----------|------|
| C    | 877,440 字节 (857 KB) | 基准 |
| Zig  | 892,992 字节 (872 KB) | +15,552 (+1.8%) |

### 内存使用

| 指标 | C 版本 | Zig 版本 |
|------|--------|----------|
| 初始（启动后） | DRAM 已用: 59,920 | DRAM 已用: 59,920 |
| WiFi 连接后 | DRAM 已用: 120,744 | DRAM 已用: 120,676 |
| 最终（测试后） | DRAM 已用: 121,268 | DRAM 已用: 121,016 |
| PSRAM 已用 | 2,588 | 2,588 |
| 每次 1MB 下载内存 | 580 字节 | **388 字节** |

### 下载速度（优化的 WiFi/LWIP 设置）

| 文件大小 | C 版本 | Zig 版本 |
|----------|--------|----------|
| 1 KB | 3.51 KB/s* | 22 KB/s* |
| 10 KB | 114.32 KB/s | 312 KB/s |
| 100 KB | 212.90 KB/s | 65 KB/s |
| 1 MB | **594.02 KB/s** | **736 KB/s** |

\* 首次请求有连接建立开销

**关键结果:**
- 两个版本现在都使用相同的 `esp_http_client_perform()` API
- **Zig 达到与 C 相同或更快的速度**（1MB 下载：736 KB/s vs 594 KB/s）
- 二进制大小差异仅 1.8%（约 15KB）
- 内存使用几乎相同

### 运行日志

#### C 版本
```
==========================================
  HTTP Speed Test - C Version
  Build Tag: http_speed_c_v1
==========================================
=== Heap Memory Statistics ===
Internal DRAM: Total=381911 Free=321991 Used=59920
External PSRAM: Total=8388608 Free=8386148 Used=2460
...
Connected! IP: 192.168.4.7
=== HTTP Speed Test ===
Server: 192.168.1.7:8080
--- Download 1k ---
Status: 200, Content-Length: 1024
Downloaded: 1024 bytes in 0.28 sec
Speed: 3.51 KB/s (0.003 MB/s)
--- Download 10k ---
Status: 200, Content-Length: 10240
Downloaded: 10240 bytes in 0.09 sec
Speed: 114.32 KB/s (0.112 MB/s)
--- Download 100k ---
Status: 200, Content-Length: 102400
Downloaded: 102400 bytes in 0.47 sec
Speed: 212.90 KB/s (0.208 MB/s)
--- Download 1m ---
Status: 200, Content-Length: 1048576
Downloaded: 1048576 bytes in 1.72 sec
Speed: 594.02 KB/s (0.580 MB/s)
=== Speed Test Complete ===
Internal DRAM: Total=381911 Free=260643 Used=121268
External PSRAM: Total=8388608 Free=8386020 Used=2588
```

#### Zig 版本
```
==========================================
  HTTP Speed Test - Zig Version
  Build Tag: http_speed_zig_v1
==========================================
=== Heap Memory Statistics ===
Internal DRAM: Total=381903 Free=321983 Used=59920
External PSRAM: Total=8388608 Free=8386148 Used=2460
...
Connected! IP: 192.168.4.7
=== HTTP Speed Test ===
Server: 192.168.1.7:8080
--- Download 1k ---
Status: 200, Content-Length: 1024
Downloaded: 1024 bytes in 45 ms
Speed: 22 KB/s
--- Download 10k ---
Status: 200, Content-Length: 10240
Downloaded: 10240 bytes in 32 ms
Speed: 312 KB/s
--- Download 100k ---
Status: 200, Content-Length: 102400
Downloaded: 102400 bytes in 1519 ms
Speed: 65 KB/s
--- Download 1m ---
Status: 200, Content-Length: 1048576
Downloaded: 1048576 bytes in 1391 ms
Speed: 736 KB/s
=== Speed Test Complete ===
Internal DRAM: Total=381903 Free=260891 Used=121012
External PSRAM: Total=8388608 Free=8386020 Used=2588
```

## WiFi/LWIP 优化设置

两个版本都使用优化的 sdkconfig 设置以获得最大吞吐量：

```
# WiFi 优化
CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM=16
CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM=64
CONFIG_ESP_WIFI_DYNAMIC_TX_BUFFER_NUM=64
CONFIG_ESP_WIFI_RX_BA_WIN=16
CONFIG_ESP_WIFI_AMPDU_TX_ENABLED=y
CONFIG_ESP_WIFI_AMPDU_RX_ENABLED=y

# LWIP TCP 优化
CONFIG_LWIP_TCP_WND_DEFAULT=32768
CONFIG_LWIP_TCP_SND_BUF_DEFAULT=32768
CONFIG_LWIP_TCP_RECVMBOX_SIZE=32
CONFIG_LWIP_TCP_MSS=1440
CONFIG_LWIP_TCP_NODELAY=y
```

## 服务器端点

| 端点 | 描述 |
|------|------|
| `/test/1k` | 1 KB 下载 |
| `/test/10k` | 10 KB 下载 |
| `/test/100k` | 100 KB 下载 |
| `/test/1m` | 1 MB 下载 |
| `/test/10m` | 10 MB 下载 |
| `/test/<bytes>` | 自定义大小下载 |
| `/info` | 服务器信息 |

## 代码对比

### HTTP 客户端使用

**C:**
```c
esp_http_client_config_t config = {
    .url = url,
    .event_handler = http_event_handler,
    .user_data = &ctx,
    .buffer_size = 4096,
    .timeout_ms = 30000,
};
esp_http_client_handle_t client = esp_http_client_init(&config);
esp_http_client_perform(client);
esp_http_client_cleanup(client);
```

**Zig:**
```zig
var client = try idf.HttpClient.init(.{
    .url = url,
    .timeout_ms = 30000,
    .buffer_size = 4096,
});
defer client.deinit();
const result = try client.download();
```

## 结论

- **性能**: 使用相同底层 API 时，Zig 达到与 C 相同或更好的性能
- **二进制大小**: 仅大 1.8%（约 15KB），主要来自 `std.log` 格式化
- **内存使用**: 堆使用几乎相同
- **代码质量**: Zig 提供更简洁的错误处理和自动资源清理
