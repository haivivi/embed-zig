//! Memory Attribute Test
//!
//! Tests PSRAM, IRAM, and DRAM memory placement using Zig's linksection.
//! Useful for verifying memory placement on different boards.

const std = @import("std");
const log = std.log.scoped(.app);

const BUILD_TAG = "mem_attr_v5";

// ESP32-S3 Memory Map Constants
const PSRAM_START: usize = 0x3C000000;
const PSRAM_END: usize = 0x3E000000;
const IRAM_START: usize = 0x40370000;
const IRAM_END: usize = 0x403E0000;
const DRAM_START: usize = 0x3FC88000;
const DRAM_END: usize = 0x3FD00000;

// ============================================================================
// Test 1: PSRAM (External RAM)
// ============================================================================

/// Large array placed in PSRAM (.ext_ram.bss section)
var psram_buffer: [4096]u8 linksection(".ext_ram.bss") = undefined;

/// Another PSRAM variable for testing
var psram_counter: u32 linksection(".ext_ram.bss") = 0;

// ============================================================================
// Test 2: DRAM (Internal RAM)
// ============================================================================

/// Variable placed in internal DRAM (.dram1 section)
var dram_variable: u32 linksection(".dram1") = 0;

/// DMA-capable buffer in DRAM (must be word-aligned)
var dma_buffer: [256]u8 align(4) linksection(".dram1") = undefined;

// ============================================================================
// Test 3: IRAM (Internal RAM for code)
// ============================================================================

/// Function placed in IRAM - useful for ISR handlers
fn iramFunction() linksection(".iram1") void {
    dram_variable +%= 1;
}

/// Another IRAM function that does some computation
fn iramCompute(a: u32, b: u32) linksection(".iram1") u32 {
    return a *% b +% dram_variable;
}

// ============================================================================
// Helpers
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

fn getRegion(addr: usize) []const u8 {
    if (isInPsram(addr)) return "PSRAM";
    if (isInIram(addr)) return "IRAM";
    if (isInDram(addr)) return "DRAM";
    return "???";
}

fn check(name: []const u8, addr: usize, expected: fn (usize) bool) void {
    const region = getRegion(addr);
    const pass = expected(addr);
    log.info("{s}: 0x{X:0>8} -> {s} [{s}]", .{
        name,
        addr,
        region,
        if (pass) "PASS" else "FAIL",
    });
}

// ============================================================================
// Tests
// ============================================================================

fn testPsram() void {
    log.info("=== PSRAM Test ===", .{});
    check("psram_buffer", @intFromPtr(&psram_buffer), isInPsram);
    check("psram_counter", @intFromPtr(&psram_counter), isInPsram);

    // R/W test
    psram_counter = 12345;
    psram_buffer[0] = 0xAA;
    psram_buffer[4095] = 0x55;
    log.info("R/W: counter={}, buf[0]=0x{X}, buf[4095]=0x{X}", .{
        psram_counter,
        psram_buffer[0],
        psram_buffer[4095],
    });
}

fn testDram() void {
    log.info("=== DRAM Test ===", .{});
    check("dram_variable", @intFromPtr(&dram_variable), isInDram);

    const dma_addr = @intFromPtr(&dma_buffer);
    const aligned = (dma_addr % 4) == 0;
    log.info("dma_buffer: 0x{X:0>8} -> {s} (aligned={}) [{s}]", .{
        dma_addr,
        getRegion(dma_addr),
        aligned,
        if (isInDram(dma_addr) and aligned) "PASS" else "FAIL",
    });
}

fn testIram() void {
    log.info("=== IRAM Test ===", .{});
    check("iramFunction", @intFromPtr(&iramFunction), isInIram);
    check("iramCompute", @intFromPtr(&iramCompute), isInIram);

    // Execution test
    dram_variable = 0;
    iramFunction();
    log.info("Exec: dram_variable = {}", .{dram_variable});

    const result = iramCompute(10, 20);
    log.info("Compute: iramCompute(10,20) = {} (expect 201)", .{result});
}

// ============================================================================
// Entry
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  Memory Attribute Test", .{});
    log.info("  Build: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    testPsram();
    testDram();
    testIram();

    log.info("==========================================", .{});
    log.info("All tests done!", .{});
}
