# Memory Attribute Test

[English](README.md)

测试 Zig 与 C 在 ESP32-S3 上的内存属性（IRAM/DRAM/PSRAM）使用对比。

## 功能

- 测试 PSRAM 变量放置 (`.ext_ram.bss` section)
- 测试 DRAM 变量放置 (`.dram1` section)
- 测试 IRAM 函数放置 (`.iram1` section)
- 验证内存地址范围
- 输出堆内存统计信息
- 对比 Zig 与 C 的实现方式

## 语法对比

| 用途 | C 语法 | Zig 语法 |
|------|--------|----------|
| PSRAM 变量 | `EXT_RAM_BSS_ATTR uint8_t buf[4096];` | `var buf: [4096]u8 linksection(".ext_ram.bss") = undefined;` |
| DRAM 变量 | `DRAM_ATTR uint32_t var = 0;` | `var var: u32 linksection(".dram1") = 0;` |
| DMA 缓冲 | `DMA_ATTR uint8_t buf[256];` | `var buf: [256]u8 align(4) linksection(".dram1") = undefined;` |
| IRAM 函数 | `void IRAM_ATTR func() { }` | `fn func() linksection(".iram1") void { }` |

## 编译对比 (ESP32-S3)

测试环境：ESP-IDF v5.4, Zig 0.15.x (Espressif fork)

### Binary Size

| 版本 | Binary 大小 | Build Tag |
|------|-------------|-----------|
| Zig  | 216,384 bytes (211.3 KB) | `mem_attr_zig_v1` |
| C    | 216,864 bytes (211.8 KB) | `mem_attr_c_v1` |
| **Diff** | **-480 bytes** | |

### 运行时内存占用 (Heap)

| 内存区域 | 指标 | Zig | C | 差异 |
|----------|------|-----|---|------|
| **Internal DRAM** | Total | 436,919 | 436,919 | 0 |
| | Free | 386,247 | 386,247 | 0 |
| | Used | 50,672 | 50,672 | 0 |
| | Min free ever | 386,247 | 386,247 | 0 |
| | Largest block | 286,720 | 286,720 | 0 |
| **External PSRAM** | Total | 8,384,508 | 8,384,508 | 0 |
| | Free | 8,382,048 | 8,382,048 | 0 |
| | Used | 2,460 | 2,460 | 0 |
| | Min free ever | 8,382,048 | 8,382,048 | 0 |
| | Largest block | 8,257,536 | 8,257,536 | 0 |
| **DMA capable** | Free | 378,743 | 378,743 | 0 |

> 注：Zig 与 C 版本运行时内存占用完全相同

## 运行日志

### Zig 版本输出

```
I (1073):   Memory Attribute Test - Zig Version
I (1073):   Build Tag: mem_attr_zig_v1
I (1083): === Heap Memory Statistics ===
I (1093): Internal DRAM:
I (1103): External PSRAM:
I (1123): DMA capable free: 378743 bytes
I (1133): === Testing PSRAM Variables ===
I (1133): psram_buffer address: 0x3C030000, region: PSRAM (External)
I (1133):   [PASS] psram_buffer is correctly in PSRAM
I (1143): psram_counter address: 0x3C031000, region: PSRAM (External)
I (1153):   [PASS] psram_counter is correctly in PSRAM
I (1153): PSRAM read/write test: counter=12345, buf[0]=0xAA, buf[4095]=0x55
I (1163): === Testing DRAM Variables ===
I (1163): dram_variable address: 0x3FC943FC, region: DRAM (Internal)
I (1173):   [PASS] dram_variable is correctly in DRAM
I (1173): dma_buffer address: 0x3FC94400, region: DRAM (Internal)
I (1183):   [PASS] dma_buffer is correctly in DRAM and aligned
I (1193): === Testing IRAM Functions ===
I (1203):   [PASS] iramFunction is correctly in IRAM
I (1213):   [PASS] iramCompute is correctly in IRAM
I (1233): All tests completed!
```

### C 版本输出

```
I (1071) mem_attr_test:   Memory Attribute Test - C Version
I (1081) mem_attr_test:   Build Tag: mem_attr_c_v1
I (1091) mem_attr_test: === Heap Memory Statistics ===
I (1091) mem_attr_test: Internal DRAM:
I (1121) mem_attr_test: External PSRAM:
I (1141) mem_attr_test: DMA capable free: 378743 bytes
I (1151) mem_attr_test: === Testing PSRAM Variables ===
I (1151) mem_attr_test: psram_buffer address: 0x3C030004, region: PSRAM (External)
I (1161) mem_attr_test:   ✓ psram_buffer is correctly in PSRAM
I (1161) mem_attr_test: psram_counter address: 0x3C030000, region: PSRAM (External)
I (1171) mem_attr_test:   ✓ psram_counter is correctly in PSRAM
I (1181) mem_attr_test: PSRAM read/write test: counter=12345, buf[0]=0xAA, buf[4095]=0x55
I (1191) mem_attr_test: === Testing DRAM Variables ===
I (1191) mem_attr_test: dram_variable address: 0x3FC94368, region: DRAM (Internal)
I (1201) mem_attr_test:   ✓ dram_variable is correctly in DRAM
I (1201) mem_attr_test: dma_buffer address: 0x3FC94268, region: DRAM (Internal)
I (1221) mem_attr_test:   ✓ dma_buffer is correctly in DRAM and aligned
I (1221) mem_attr_test: === Testing IRAM Functions ===
I (1241) mem_attr_test:   ✓ iram_function is correctly in IRAM
I (1251) mem_attr_test:   ✓ iram_compute is correctly in IRAM
I (1271) mem_attr_test: All tests completed!
```

### 测试结果

两个版本都正确地将变量和函数放置到了指定的内存区域：

| 内存区域 | 地址范围 | 验证 |
|----------|----------|------|
| PSRAM (.ext_ram.bss) | 0x3C030000+ | ✅ PASS |
| DRAM (.dram1) | 0x3FC94xxx | ✅ PASS |
| IRAM (.iram1) | 0x4037xxxx | ✅ PASS |

## 构建

```bash
# Zig 版本
cd zig
idf.py set-target esp32s3
idf.py build

# C 版本
cd c
idf.py set-target esp32s3
idf.py build
```

## 烧录测试

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```
