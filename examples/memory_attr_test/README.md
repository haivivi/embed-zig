# Memory Attribute Test

[中文版](README.zh-CN.md)

Compare memory attribute (IRAM/DRAM/PSRAM) usage between Zig and C on ESP32-S3.

## Features

- Test PSRAM variable placement (`.ext_ram.bss` section)
- Test DRAM variable placement (`.dram1` section)
- Test IRAM function placement (`.iram1` section)
- Verify memory address ranges
- Output heap memory statistics
- Compare Zig and C implementations

## Syntax Comparison

| Purpose | C Syntax | Zig Syntax |
|---------|----------|------------|
| PSRAM Variable | `EXT_RAM_BSS_ATTR uint8_t buf[4096];` | `var buf: [4096]u8 linksection(".ext_ram.bss") = undefined;` |
| DRAM Variable | `DRAM_ATTR uint32_t var = 0;` | `var var: u32 linksection(".dram1") = 0;` |
| DMA Buffer | `DMA_ATTR uint8_t buf[256];` | `var buf: [256]u8 align(4) linksection(".dram1") = undefined;` |
| IRAM Function | `void IRAM_ATTR func() { }` | `fn func() linksection(".iram1") void { }` |

## Build Comparison (ESP32-S3)

Test Environment: ESP-IDF v5.4, Zig 0.15.x (Espressif fork)

### Binary Size

| Version | Binary Size | Build Tag |
|---------|-------------|-----------|
| Zig | 216,384 bytes (211.3 KB) | `mem_attr_zig_v1` |
| C | 216,864 bytes (211.8 KB) | `mem_attr_c_v1` |
| **Diff** | **-480 bytes** | |

### Runtime Memory Usage (Heap)

| Memory Region | Metric | Zig | C | Diff |
|---------------|--------|-----|---|------|
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

> Note: Zig and C versions have identical runtime memory usage

## Runtime Logs

### Zig Version Output

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

### C Version Output

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

### Test Results

Both versions correctly place variables and functions in the specified memory regions:

| Memory Region | Address Range | Result |
|---------------|---------------|--------|
| PSRAM (.ext_ram.bss) | 0x3C030000+ | ✅ PASS |
| DRAM (.dram1) | 0x3FC94xxx | ✅ PASS |
| IRAM (.iram1) | 0x4037xxxx | ✅ PASS |

## Build

```bash
# Zig version
cd zig
idf.py set-target esp32s3
idf.py build

# C version
cd c
idf.py set-target esp32s3
idf.py build
```

## Flash & Monitor

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```
