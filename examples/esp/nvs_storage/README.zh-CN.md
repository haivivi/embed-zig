# NVS 存储示例

NVS（非易失性存储）示例，演示在 Flash 中进行持久化键值存储。

## 功能

- **启动计数器**：每次设备重启时递增的整数
- **设备名称**：从 NVS 存储和读取的字符串
- **Blob 数据**：二进制数据的存储和读取
- **持久化**：数据在断电和重启后仍然保留

## 编译和运行

```bash
cd examples/nvs_storage/zig
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

## 示例输出

```
==========================================
NVS Storage Example - Zig Version
==========================================
NVS initialized

=== Boot Counter ===
Boot count: 3

=== Device Name ===
Device name: ESP32-Zig-Device

=== Blob Data ===
Blob data (6 bytes): deadbeefcafe
NVS committed to flash

=== Summary ===
Boot count: 3 (will increment on next boot)
Device name: ESP32-Zig-Device
Blob stored: 6 bytes

Reboot the device to see boot_count increment!
```

## NVS API 使用

```zig
const idf = @import("esp");

// 初始化 NVS
try idf.nvs.init();

// 打开命名空间
var nvs = try idf.Nvs.open("storage");
defer nvs.close();

// 整数操作
try nvs.setU32("counter", 42);
const value = try nvs.getU32("counter");

// 字符串操作
try nvs.setString("name", "ESP32-Device");
var buf: [64]u8 = undefined;
const name = try nvs.getString("name", &buf);

// Blob（二进制）操作
const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
try nvs.setBlob("blob", &data);
var blob_buf: [16]u8 = undefined;
const blob = try nvs.getBlob("blob", &blob_buf);

// 提交更改到 Flash
try nvs.commit();

// 错误处理
const result = nvs.getU32("missing_key") catch |err| {
    if (err == idf.nvs.NvsError.NotFound) {
        // 键不存在
    }
};
```

## 支持的类型

| 类型 | 写入 | 读取 |
|------|-----|-----|
| i8, u8 | `setI8`, `setU8` | `getI8`, `getU8` |
| i16, u16 | `setI16`, `setU16` | `getI16`, `getU16` |
| i32, u32 | `setI32`, `setU32` | `getI32`, `getU32` |
| i64, u64 | `setI64`, `setU64` | `getI64`, `getU64` |
| 字符串 | `setString` | `getString`, `getStringLen` |
| Blob | `setBlob` | `getBlob`, `getBlobLen` |

## C 与 Zig 对比

### 二进制大小

| 版本 | .bin 大小 | 差异 |
|------|-----------|------|
| **C** | 228,048 字节（222.7 KB） | 基准 |
| **Zig** | 230,512 字节（225.1 KB） | +1.1% |

### 内存占用（静态）

| 内存区域 | C | Zig | 差异 |
|----------|---|-----|------|
| **IRAM** | 16,383 字节 | 16,383 字节 | 0% |
| **DRAM** | 55,023 字节 | 55,023 字节 | **0%** ✅ |
| **Flash Code** | 116,556 字节 | 118,264 字节 | +1.5% |

### 代码行数

| 版本 | 行数 | 说明 |
|------|------|------|
| **C** | ~120 | 手动错误处理，较冗长 |
| **Zig** | ~100 | 使用 `try`/`catch` 和 `defer` 更简洁 |

### 数据兼容性

✅ Zig 写入的 NVS 数据可以被 C 读取，反之亦然。存储格式完全相同。

## 硬件

- ESP32-S3-DevKitC-1 带 PSRAM
