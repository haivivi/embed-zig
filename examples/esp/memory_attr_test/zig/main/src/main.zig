//! Memory Attribute Test - Demonstrates linksection placement in Zig
//!
//! Tests PSRAM, IRAM, and DRAM memory placement using Zig's linksection.

const std = @import("std");
const idf = @import("esp");

// sdkconfig only
const c = @cImport({
    @cInclude("sdkconfig.h");
});

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

const BUILD_TAG = "mem_attr_zig_v2";

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

fn getMemoryRegionName(addr: usize) []const u8 {
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
// Test functions
// ============================================================================

fn testPsramVariables() void {
    std.log.info("=== Testing PSRAM Variables ===", .{});

    // Test psram_buffer
    const buffer_addr = @intFromPtr(&psram_buffer);
    const buffer_region = getMemoryRegionName(buffer_addr);
    std.log.info("psram_buffer address: 0x{X:0>8}, region: {s}", .{ buffer_addr, buffer_region });

    if (isInPsram(buffer_addr)) {
        std.log.info("  [PASS] psram_buffer is correctly in PSRAM", .{});
    } else {
        std.log.err("  [FAIL] psram_buffer is NOT in PSRAM!", .{});
    }

    // Test psram_counter
    const counter_addr = @intFromPtr(&psram_counter);
    const counter_region = getMemoryRegionName(counter_addr);
    std.log.info("psram_counter address: 0x{X:0>8}, region: {s}", .{ counter_addr, counter_region });

    if (isInPsram(counter_addr)) {
        std.log.info("  [PASS] psram_counter is correctly in PSRAM", .{});
    } else {
        std.log.err("  [FAIL] psram_counter is NOT in PSRAM!", .{});
    }

    // Test read/write
    psram_counter = 12345;
    psram_buffer[0] = 0xAA;
    psram_buffer[4095] = 0x55;
    std.log.info("PSRAM read/write test: counter={}, buf[0]=0x{X:0>2}, buf[4095]=0x{X:0>2}", .{
        psram_counter,
        psram_buffer[0],
        psram_buffer[4095],
    });
}

fn testDramVariables() void {
    std.log.info("=== Testing DRAM Variables ===", .{});

    // Test dram_variable
    const dram_addr = @intFromPtr(&dram_variable);
    const dram_region = getMemoryRegionName(dram_addr);
    std.log.info("dram_variable address: 0x{X:0>8}, region: {s}", .{ dram_addr, dram_region });

    if (isInDram(dram_addr)) {
        std.log.info("  [PASS] dram_variable is correctly in DRAM", .{});
    } else {
        std.log.err("  [FAIL] dram_variable is NOT in DRAM!", .{});
    }

    // Test dma_buffer
    const dma_addr = @intFromPtr(&dma_buffer);
    const dma_region = getMemoryRegionName(dma_addr);
    std.log.info("dma_buffer address: 0x{X:0>8}, region: {s}", .{ dma_addr, dma_region });

    const is_aligned = (dma_addr % 4) == 0;
    std.log.info("  dma_buffer alignment: {s} (required: 4-byte)", .{
        if (is_aligned) "OK" else "FAIL",
    });

    if (isInDram(dma_addr) and is_aligned) {
        std.log.info("  [PASS] dma_buffer is correctly in DRAM and aligned", .{});
    } else {
        std.log.err("  [FAIL] dma_buffer check failed!", .{});
    }
}

fn testIramFunctions() void {
    std.log.info("=== Testing IRAM Functions ===", .{});

    // Test iramFunction location
    const func_addr = @intFromPtr(&iramFunction);
    const func_region = getMemoryRegionName(func_addr);
    std.log.info("iramFunction address: 0x{X:0>8}, region: {s}", .{ func_addr, func_region });

    if (isInIram(func_addr)) {
        std.log.info("  [PASS] iramFunction is correctly in IRAM", .{});
    } else {
        std.log.err("  [FAIL] iramFunction is NOT in IRAM!", .{});
    }

    // Test iramCompute location
    const compute_addr = @intFromPtr(&iramCompute);
    const compute_region = getMemoryRegionName(compute_addr);
    std.log.info("iramCompute address: 0x{X:0>8}, region: {s}", .{ compute_addr, compute_region });

    if (isInIram(compute_addr)) {
        std.log.info("  [PASS] iramCompute is correctly in IRAM", .{});
    } else {
        std.log.err("  [FAIL] iramCompute is NOT in IRAM!", .{});
    }

    // Test execution
    dram_variable = 0;
    iramFunction();
    std.log.info("IRAM function test: dram_variable after call = {}", .{dram_variable});

    const result = iramCompute(10, 20);
    std.log.info("IRAM compute test: iramCompute(10, 20) = {} (expected: 201)", .{result});
}

fn printMemoryStats() void {
    std.log.info("=== Heap Memory Statistics ===", .{});

    // Internal DRAM
    const internal = idf.heap.getInternalStats();
    std.log.info("Internal DRAM:", .{});
    std.log.info("  Total: {} bytes", .{internal.total});
    std.log.info("  Free:  {} bytes", .{internal.free});
    std.log.info("  Used:  {} bytes", .{internal.used});

    // External PSRAM
    const psram = idf.heap.getPsramStats();
    std.log.info("External PSRAM:", .{});
    std.log.info("  Total: {} bytes", .{psram.total});
    std.log.info("  Free:  {} bytes", .{psram.free});
    std.log.info("  Used:  {} bytes", .{psram.used});

    // DMA capable memory
    const dma_free = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_DMA);
    std.log.info("DMA capable free: {} bytes", .{dma_free});
}

// ============================================================================
// Main entry point
// ============================================================================

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("  Memory Attribute Test - Zig Version", .{});
    std.log.info("  Build Tag: {s}", .{BUILD_TAG});
    std.log.info("==========================================", .{});

    printMemoryStats();

    testPsramVariables();
    testDramVariables();
    testIramFunctions();

    std.log.info("=====================================", .{});
    std.log.info("All tests completed!", .{});

    // Keep running
    while (true) {
        idf.delayMs(1000);
    }
}
