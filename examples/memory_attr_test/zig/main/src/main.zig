const std = @import("std");

const esp = @cImport({
    @cInclude("sdkconfig.h");
    @cInclude("esp_err.h");
    @cInclude("esp_log.h");
    @cInclude("esp_heap_caps.h");
    @cInclude("esp_attr.h");
});

const freertos = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
});

const TAG = "mem_attr_test";

// ESP32-S3 Memory Map Constants
// PSRAM is typically mapped at 0x3C000000 - 0x3DFFFFFF (external)
// IRAM is at 0x40370000 - 0x403DFFFF
// DRAM is at 0x3FC88000 - 0x3FCFFFFF
const PSRAM_START: usize = 0x3C000000;
const PSRAM_END: usize = 0x3E000000;
const IRAM_START: usize = 0x40370000;
const IRAM_END: usize = 0x403E0000;
const DRAM_START: usize = 0x3FC88000;
const DRAM_END: usize = 0x3FD00000;

// ============================================================================
// Test 1: PSRAM (External RAM) - Using linksection
// ============================================================================

/// Large array placed in PSRAM (.ext_ram.bss section)
/// In C: EXT_RAM_BSS_ATTR uint8_t psram_buffer[4096];
var psram_buffer: [4096]u8 linksection(".ext_ram.bss") = undefined;

/// Another PSRAM variable for testing
var psram_counter: u32 linksection(".ext_ram.bss") = 0;

// ============================================================================
// Test 2: DRAM (Internal RAM) - Using linksection
// ============================================================================

/// Variable placed in internal DRAM (.dram1 section)
/// In C: DRAM_ATTR uint32_t dram_variable = 0;
var dram_variable: u32 linksection(".dram1") = 0;

/// DMA-capable buffer in DRAM (must be word-aligned)
var dma_buffer: [256]u8 align(4) linksection(".dram1") = undefined;

// ============================================================================
// Test 3: IRAM (Internal RAM for code) - Using linksection
// ============================================================================

/// Function placed in IRAM - useful for ISR handlers
/// In C: void IRAM_ATTR fast_function(void) { ... }
fn iramFunction() linksection(".iram1") void {
    // Simple operation to test IRAM execution
    dram_variable +%= 1;
}

/// Another IRAM function that does some computation
fn iramCompute(a: u32, b: u32) linksection(".iram1") u32 {
    return a *% b +% dram_variable;
}

// ============================================================================
// Helper functions for address verification (using address ranges)
// ============================================================================

fn isInPsram(addr: usize) bool {
    return addr >= PSRAM_START and addr < PSRAM_END;
}

fn isInIram(addr: usize) bool {
    return addr >= IRAM_START and addr < IRAM_END;
}

fn isInDram(addr: usize) bool {
    return addr >= DRAM_START and addr < DRAM_END;
}

fn getMemoryRegionName(addr: usize) [*:0]const u8 {
    if (isInPsram(addr)) {
        return "PSRAM (External)";
    } else if (isInIram(addr)) {
        return "IRAM (Internal)";
    } else if (isInDram(addr)) {
        return "DRAM (Internal)";
    } else {
        return "Unknown/Other";
    }
}

// ============================================================================
// Logging helper
// ============================================================================

fn espLog(comptime format: []const u8, args: anytype) void {
    const esp_level = esp.ESP_LOG_INFO;
    const fmt = std.fmt.comptimePrint("I (%u): " ++ format ++ "\n", .{});
    const timestamp = esp.esp_log_timestamp();
    @call(.auto, esp.esp_log_write, .{ esp_level, TAG, fmt, timestamp } ++ args);
}

// ============================================================================
// Test functions
// ============================================================================

fn testPsramVariables() void {
    espLog("=== Testing PSRAM Variables ===", .{});

    // Test psram_buffer
    const buffer_addr = @intFromPtr(&psram_buffer);
    const buffer_region = getMemoryRegionName(buffer_addr);
    espLog("psram_buffer address: 0x%08X, region: %s", .{ buffer_addr, buffer_region });

    if (isInPsram(buffer_addr)) {
        espLog("  [PASS] psram_buffer is correctly in PSRAM", .{});
    } else {
        espLog("  [FAIL] psram_buffer is NOT in PSRAM!", .{});
    }

    // Test psram_counter
    const counter_addr = @intFromPtr(&psram_counter);
    const counter_region = getMemoryRegionName(counter_addr);
    espLog("psram_counter address: 0x%08X, region: %s", .{ counter_addr, counter_region });

    if (isInPsram(counter_addr)) {
        espLog("  [PASS] psram_counter is correctly in PSRAM", .{});
    } else {
        espLog("  [FAIL] psram_counter is NOT in PSRAM!", .{});
    }

    // Test read/write
    psram_counter = 12345;
    psram_buffer[0] = 0xAA;
    psram_buffer[4095] = 0x55;
    espLog("PSRAM read/write test: counter=%d, buf[0]=0x%02X, buf[4095]=0x%02X", .{
        psram_counter,
        psram_buffer[0],
        psram_buffer[4095],
    });
}

fn testDramVariables() void {
    espLog("=== Testing DRAM Variables ===", .{});

    // Test dram_variable
    const dram_addr = @intFromPtr(&dram_variable);
    const dram_region = getMemoryRegionName(dram_addr);
    espLog("dram_variable address: 0x%08X, region: %s", .{ dram_addr, dram_region });

    if (isInDram(dram_addr)) {
        espLog("  [PASS] dram_variable is correctly in DRAM", .{});
    } else {
        espLog("  [FAIL] dram_variable is NOT in DRAM!", .{});
    }

    // Test dma_buffer
    const dma_addr = @intFromPtr(&dma_buffer);
    const dma_region = getMemoryRegionName(dma_addr);
    espLog("dma_buffer address: 0x%08X, region: %s", .{ dma_addr, dma_region });

    const is_aligned = (dma_addr % 4) == 0;
    espLog("  dma_buffer alignment: %s (required: 4-byte)", .{
        @as([*:0]const u8, if (is_aligned) "OK" else "FAIL"),
    });

    if (isInDram(dma_addr) and is_aligned) {
        espLog("  [PASS] dma_buffer is correctly in DRAM and aligned", .{});
    } else {
        espLog("  [FAIL] dma_buffer check failed!", .{});
    }
}

fn testIramFunctions() void {
    espLog("=== Testing IRAM Functions ===", .{});

    // Test iramFunction location
    const func_addr = @intFromPtr(&iramFunction);
    const func_region = getMemoryRegionName(func_addr);
    espLog("iramFunction address: 0x%08X, region: %s", .{ func_addr, func_region });

    if (isInIram(func_addr)) {
        espLog("  [PASS] iramFunction is correctly in IRAM", .{});
    } else {
        espLog("  [FAIL] iramFunction is NOT in IRAM!", .{});
    }

    // Test iramCompute location
    const compute_addr = @intFromPtr(&iramCompute);
    const compute_region = getMemoryRegionName(compute_addr);
    espLog("iramCompute address: 0x%08X, region: %s", .{ compute_addr, compute_region });

    if (isInIram(compute_addr)) {
        espLog("  [PASS] iramCompute is correctly in IRAM", .{});
    } else {
        espLog("  [FAIL] iramCompute is NOT in IRAM!", .{});
    }

    // Test execution
    dram_variable = 0;
    iramFunction();
    espLog("IRAM function test: dram_variable after call = %d", .{dram_variable});

    const result = iramCompute(10, 20);
    espLog("IRAM compute test: iramCompute(10, 20) = %d (expected: 201)", .{result});
}

fn printMemoryStats() void {
    espLog("=== Heap Memory Statistics ===", .{});

    // Internal DRAM
    const dram_free = esp.heap_caps_get_free_size(esp.MALLOC_CAP_INTERNAL);
    const dram_total = esp.heap_caps_get_total_size(esp.MALLOC_CAP_INTERNAL);
    const dram_min_free = esp.heap_caps_get_minimum_free_size(esp.MALLOC_CAP_INTERNAL);
    const dram_largest = esp.heap_caps_get_largest_free_block(esp.MALLOC_CAP_INTERNAL);

    espLog("Internal DRAM:", .{});
    espLog("  Total: %6d bytes", .{dram_total});
    espLog("  Free:  %6d bytes", .{dram_free});
    espLog("  Used:  %6d bytes", .{dram_total - dram_free});
    espLog("  Min free ever: %d bytes", .{dram_min_free});
    espLog("  Largest block: %d bytes", .{dram_largest});

    // External PSRAM
    const psram_free = esp.heap_caps_get_free_size(esp.MALLOC_CAP_SPIRAM);
    const psram_total = esp.heap_caps_get_total_size(esp.MALLOC_CAP_SPIRAM);
    const psram_min_free = esp.heap_caps_get_minimum_free_size(esp.MALLOC_CAP_SPIRAM);
    const psram_largest = esp.heap_caps_get_largest_free_block(esp.MALLOC_CAP_SPIRAM);

    espLog("External PSRAM:", .{});
    espLog("  Total: %6d bytes", .{psram_total});
    espLog("  Free:  %6d bytes", .{psram_free});
    espLog("  Used:  %6d bytes", .{psram_total - psram_free});
    espLog("  Min free ever: %d bytes", .{psram_min_free});
    espLog("  Largest block: %d bytes", .{psram_largest});

    // DMA capable memory
    const dma_free = esp.heap_caps_get_free_size(esp.MALLOC_CAP_DMA);
    espLog("DMA capable free: %d bytes", .{dma_free});
}

// ============================================================================
// Main entry point
// ============================================================================

const BUILD_TAG = "mem_attr_zig_v1";

export fn app_main() void {
    espLog("==========================================", .{});
    espLog("  Memory Attribute Test - Zig Version", .{});
    espLog("  Build Tag: %s", .{@as([*:0]const u8, BUILD_TAG)});
    espLog("==========================================", .{});

    printMemoryStats();

    testPsramVariables();
    testDramVariables();
    testIramFunctions();

    espLog("=====================================", .{});
    espLog("All tests completed!", .{});

    // Keep running
    while (true) {
        freertos.vTaskDelay(1000 / freertos.portTICK_PERIOD_MS);
    }
}
