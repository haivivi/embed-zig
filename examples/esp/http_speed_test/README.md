# HTTP Speed Test

This example tests HTTP download speeds, comparing three implementations:
- **C** with `esp_http_client`
- **Zig** with `esp_http_client` wrapper
- **Zig Std** with pure Zig LWIP sockets (no TLS/embedTLS)

All versions run HTTP tests on **PSRAM stack tasks** (64KB) for fair comparison.

## Features

- Download speed testing with configurable sizes (1KB, 100KB, 1MB, 10MB, 50MB)
- Memory usage monitoring during downloads
- WiFi connection handling
- Local test server included
- Optimized WiFi/LWIP settings for maximum throughput
- **SAL (System Abstraction Layer)** for PSRAM task stack allocation

## Test Server Setup

Before running the ESP32, start the local test server on your computer:

```bash
cd examples/http_speed_test
python3 server.py
```

The server will display your local IP address. Update the `CONFIG_TEST_SERVER_IP` in menuconfig or `sdkconfig.defaults`.

## Build & Flash

### C Version

```bash
cd c
source ~/esp/esp-adf/esp-idf/export.sh
idf.py set-target esp32s3
idf.py menuconfig  # Set TEST_SERVER_IP to your computer's IP
idf.py build flash monitor
```

### Zig esp_http_client Version

```bash
cd zig
source ~/esp/esp-adf/esp-idf/export.sh
idf.py set-target esp32s3
idf.py menuconfig  # Set TEST_SERVER_IP to your computer's IP
idf.py build flash monitor
```

### Zig Std Version (Pure Zig HTTP)

```bash
cd zig_std
source ~/esp/esp-adf/esp-idf/export.sh
idf.py set-target esp32s3
idf.py menuconfig  # Set TEST_SERVER_IP to your computer's IP
idf.py build flash monitor
```

## Comparison Results

**Test Environment:** ESP32-S3-DevKitC-1 with 8MB PSRAM @ 80MHz, WiFi 2.4GHz (RSSI: -45 to -60 dBm), Go HTTP Server, CPU @ 240MHz

### Binary Size

| Version | .bin Size | Diff |
|---------|-----------|------|
| **C** | 802 KB | baseline |
| **Zig esp_http** | 897 KB | +11.8% |
| **Zig std** | 726 KB | **-9.5%** |

> **Zig std has the smallest binary** because it doesn't include `esp_http_client` and `esp-tls` libraries.

### Download Speed (KB/s)

| File Size | C | Zig esp_http | Zig std | Winner |
|-----------|---|--------------|---------|--------|
| **10 MB** | 871 | 790 | **1,058** | Zig std (+21%) |
| **50 MB** | 626 | 818 | **941** | Zig std (+50%) |

> **Zig std achieves ~1 MB/s** for 10MB downloads, **21% faster** than C version.
> For sustained 50MB transfers, Zig std is **50% faster** than C (941 vs 626 KB/s).

### Runtime Memory Usage

| Metric | C | Zig esp_http | Zig std | Winner |
|--------|---|--------------|---------|--------|
| **Internal DRAM Used** | 139,684 | 139,560 | **139,468** | Zig std |
| **External PSRAM Used** | 133,896 | 133,896 | **133,440** | Zig std |
| **Task Stack Used** | **2,960** | 4,096 | 36,640 | C |

> All versions use identical PSRAM for task stack allocation (64KB each).
> Zig std uses more stack due to 32KB receive buffer allocated on stack.

### Key Results

1. **Binary Size**: Zig std is **9.5% smaller** than C (no TLS overhead)
2. **Speed**: Zig std achieves **21-50% faster** downloads than C
3. **Memory (Heap)**: Zig std uses **slightly less** IRAM and PSRAM
4. **Memory (Stack)**: C uses least stack; Zig std uses most (32KB buffer on stack)

## Architecture

All three versions now use the SAL (System Abstraction Layer) for PSRAM task creation:

**C Version:**
```c
// Create PSRAM task with custom stack
StackType_t *stack = heap_caps_malloc(65536, MALLOC_CAP_SPIRAM);
xTaskCreateRestrictedPinnedToCore(&task_params, &handle, 1);
```

**Zig Versions (using SAL async):**
```zig
var wg = idf.sal.async_.WaitGroup.init(idf.heap.psram);
defer wg.deinit();
try wg.go(idf.heap.psram, "http_test", httpTestFn, null, .{
    .stack_size = 65536,  // 64KB stack on PSRAM
});
wg.wait();
```

## Server Endpoints

| Endpoint | Description |
|----------|-------------|
| `/test/1k` | 1 KB download |
| `/test/10k` | 10 KB download |
| `/test/100k` | 100 KB download |
| `/test/1m` | 1 MB download |
| `/test/10m` | 10 MB download |
| `/test/<bytes>` | Custom size download |
| `/info` | Server info |

## WiFi/LWIP Optimization Settings

All versions use optimized sdkconfig settings for maximum throughput:

```
# WiFi Optimizations
CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM=16
CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM=64
CONFIG_ESP_WIFI_DYNAMIC_TX_BUFFER_NUM=64
CONFIG_ESP_WIFI_RX_BA_WIN=16
CONFIG_ESP_WIFI_AMPDU_TX_ENABLED=y
CONFIG_ESP_WIFI_AMPDU_RX_ENABLED=y

# LWIP TCP Optimizations
CONFIG_LWIP_TCP_WND_DEFAULT=32768
CONFIG_LWIP_TCP_SND_BUF_DEFAULT=32768
CONFIG_LWIP_TCP_RECVMBOX_SIZE=32
CONFIG_LWIP_TCP_MSS=1440
CONFIG_LWIP_TCP_NODELAY=y

# PSRAM
CONFIG_SPIRAM=y
CONFIG_SPIRAM_MODE_OCT=y
CONFIG_SPIRAM_SPEED_80M=y
```

## Conclusion

| Criteria | Winner | Notes |
|----------|--------|-------|
| **Binary Size** | **Zig std** | 9.5% smaller, no TLS overhead |
| **Download Speed** | **Zig std** | 21-50% faster than C |
| **Heap Memory** | **Zig std** | Slightly less IRAM/PSRAM |
| **Stack Usage** | **C** | 2,960 bytes vs Zig std's 36,640 bytes |
| **Code Complexity** | **Zig** | Cleaner error handling, automatic cleanup |
| **TLS Support** | **C/Zig esp_http** | Zig std doesn't include TLS |

**Recommendation:**
- Use **Zig std** for HTTP-only applications (smaller, faster, less heap)
- Use **Zig esp_http** when HTTPS is required
- Consider stack size when using Zig std (needs ~40KB for 32KB buffer)

**Note:** Test results may vary based on WiFi signal strength (tested at RSSI -45 to -60 dBm).
