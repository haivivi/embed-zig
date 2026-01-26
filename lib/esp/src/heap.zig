//! ESP-IDF Heap memory functions and Allocators
//!
//! Provides std.mem.Allocator implementations for different memory types:
//! - psram: External PSRAM (large capacity, slightly slower)
//! - iram: Internal RAM (faster, limited capacity)
//! - dma: DMA-capable memory
//!
//! Usage:
//!   const heap = @import("esp").heap;
//!
//!   // Allocate from PSRAM
//!   const buf = try heap.psram.alloc(u8, 32768);
//!   defer heap.psram.free(buf);
//!
//!   // Use with sal.thread
//!   const result = try sal.thread.go(heap.psram, "task", fn, arg, .{});

const std = @import("std");

const c = @cImport({
    @cInclude("esp_heap_caps.h");
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
});

// Memory capability flags
pub const MALLOC_CAP_EXEC = c.MALLOC_CAP_EXEC;
pub const MALLOC_CAP_32BIT = c.MALLOC_CAP_32BIT;
pub const MALLOC_CAP_8BIT = c.MALLOC_CAP_8BIT;
pub const MALLOC_CAP_DMA = c.MALLOC_CAP_DMA;
pub const MALLOC_CAP_SPIRAM = c.MALLOC_CAP_SPIRAM;
pub const MALLOC_CAP_INTERNAL = c.MALLOC_CAP_INTERNAL;
pub const MALLOC_CAP_DEFAULT = c.MALLOC_CAP_DEFAULT;

// Functions
pub const heap_caps_get_free_size = c.heap_caps_get_free_size;
pub const heap_caps_get_total_size = c.heap_caps_get_total_size;
pub const heap_caps_get_minimum_free_size = c.heap_caps_get_minimum_free_size;
pub const heap_caps_get_largest_free_block = c.heap_caps_get_largest_free_block;
pub const heap_caps_malloc = c.heap_caps_malloc;
pub const heap_caps_free = c.heap_caps_free;
pub const heap_caps_realloc = c.heap_caps_realloc;

// ============================================================================
// std.mem.Allocator implementations
// ============================================================================

/// PSRAM Allocator - External SPIRAM (large capacity)
pub const psram = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &psram_vtable,
};

const psram_vtable = std.mem.Allocator.VTable{
    .alloc = psramAlloc,
    .resize = capsResize,
    .remap = noRemap,
    .free = capsFree,
};

fn psramAlloc(
    _: *anyopaque,
    len: usize,
    ptr_align: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    const caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    return capsAllocInner(len, ptr_align, caps);
}

/// IRAM Allocator - Internal RAM (fast, limited)
pub const iram = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &iram_vtable,
};

const iram_vtable = std.mem.Allocator.VTable{
    .alloc = iramAlloc,
    .resize = capsResize,
    .remap = noRemap,
    .free = capsFree,
};

fn iramAlloc(
    _: *anyopaque,
    len: usize,
    ptr_align: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    const caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
    return capsAllocInner(len, ptr_align, caps);
}

/// DMA Allocator - DMA-capable memory
pub const dma = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &dma_vtable,
};

const dma_vtable = std.mem.Allocator.VTable{
    .alloc = dmaAlloc,
    .resize = capsResize,
    .remap = noRemap,
    .free = capsFree,
};

fn dmaAlloc(
    _: *anyopaque,
    len: usize,
    ptr_align: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    const caps = MALLOC_CAP_DMA | MALLOC_CAP_8BIT;
    return capsAllocInner(len, ptr_align, caps);
}

/// Default Allocator - System default
pub const default = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &default_vtable,
};

const default_vtable = std.mem.Allocator.VTable{
    .alloc = defaultAlloc,
    .resize = capsResize,
    .remap = noRemap,
    .free = capsFree,
};

fn defaultAlloc(
    _: *anyopaque,
    len: usize,
    ptr_align: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    const caps = MALLOC_CAP_DEFAULT;
    return capsAllocInner(len, ptr_align, caps);
}

// Common implementation
fn capsAllocInner(len: usize, ptr_align: std.mem.Alignment, caps: u32) ?[*]u8 {
    // Use aligned alloc if alignment > 1
    const alignment = ptr_align.toByteUnits();
    if (alignment > 1) {
        return @ptrCast(c.heap_caps_aligned_alloc(alignment, len, caps));
    }
    return @ptrCast(c.heap_caps_malloc(len, caps));
}

fn capsResize(
    _: *anyopaque,
    buf: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) bool {
    // heap_caps doesn't support in-place resize
    // Return false to signal allocator should alloc+copy+free
    _ = buf;
    _ = new_len;
    return false;
}

fn noRemap(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
    _: usize,
) ?[*]u8 {
    // heap_caps doesn't support remap
    return null;
}

fn capsFree(
    _: *anyopaque,
    buf: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {
    c.heap_caps_free(buf.ptr);
}

/// Get memory stats for a capability
pub const MemStats = struct {
    total: usize,
    free: usize,
    used: usize,
    min_free: usize,
    largest_block: usize,
};

pub fn getMemStats(caps: u32) MemStats {
    const total = heap_caps_get_total_size(caps);
    const free = heap_caps_get_free_size(caps);
    return .{
        .total = total,
        .free = free,
        .used = total - free,
        .min_free = heap_caps_get_minimum_free_size(caps),
        .largest_block = heap_caps_get_largest_free_block(caps),
    };
}

/// Get internal DRAM stats
pub fn getInternalStats() MemStats {
    return getMemStats(MALLOC_CAP_INTERNAL);
}

/// Get external PSRAM stats (returns zeros if not available)
pub fn getPsramStats() MemStats {
    return getMemStats(MALLOC_CAP_SPIRAM);
}

/// Get DMA-capable memory stats
pub fn getDmaStats() MemStats {
    return getMemStats(MALLOC_CAP_DMA);
}

/// Get default heap stats
pub fn getDefaultStats() MemStats {
    return getMemStats(MALLOC_CAP_DEFAULT);
}

// ============================================================================
// Stack Stats
// ============================================================================

pub const StackStats = struct {
    total: usize, // Total stack size
    high_water: usize, // Minimum free ever (high water mark)
    used: usize, // Current estimated usage = total - high_water
    free_now: usize, // Current free (same as high_water for safety)
};

/// Get current task's stack statistics
pub fn getCurrentTaskStackStats() StackStats {
    const handle = c.xTaskGetCurrentTaskHandle();
    const high_water = c.uxTaskGetStackHighWaterMark(handle);

    // Note: FreeRTOS doesn't provide a direct way to get total stack size
    // for current task. We use CONFIG_ESP_MAIN_TASK_STACK_SIZE as estimate
    // for main task, or a default of 4096.
    const total: usize = 8192; // CONFIG_ESP_MAIN_TASK_STACK_SIZE default

    return .{
        .total = total,
        .high_water = high_water,
        .used = total -| high_water,
        .free_now = high_water,
    };
}

/// Get stack stats for a specific task handle
pub fn getTaskStackStats(handle: ?*anyopaque, total_size: usize) StackStats {
    const high_water = c.uxTaskGetStackHighWaterMark(handle);
    return .{
        .total = total_size,
        .high_water = high_water,
        .used = total_size -| high_water,
        .free_now = high_water,
    };
}

// ============================================================================
// System Memory Report
// ============================================================================

pub const SystemMemoryReport = struct {
    internal: MemStats,
    psram: MemStats,
    dma: MemStats,
    stack: StackStats,

    /// Format as string for logging (returns static buffer)
    pub fn format(self: SystemMemoryReport, buf: []u8) []const u8 {
        const len = std.fmt.bufPrint(buf,
            \\Internal: {d}KB free / {d}KB total (min: {d}KB, largest: {d}KB)
            \\PSRAM:    {d}KB free / {d}KB total
            \\DMA:      {d}KB free / {d}KB total
            \\Stack:    ~{d} bytes used / {d} bytes (high water: {d})
        , .{
            self.internal.free / 1024,
            self.internal.total / 1024,
            self.internal.min_free / 1024,
            self.internal.largest_block / 1024,
            self.psram.free / 1024,
            self.psram.total / 1024,
            self.dma.free / 1024,
            self.dma.total / 1024,
            self.stack.used,
            self.stack.total,
            self.stack.high_water,
        }) catch return "Format error";
        return buf[0..len];
    }
};

/// Get comprehensive system memory report
pub fn getSystemReport() SystemMemoryReport {
    return .{
        .internal = getInternalStats(),
        .psram = getPsramStats(),
        .dma = getDmaStats(),
        .stack = getCurrentTaskStackStats(),
    };
}

/// Print memory report to log
pub fn printReport() void {
    const report = getSystemReport();
    const log = @import("std").log;
    log.info("=== Memory Report ===", .{});
    log.info("Internal: {d}KB free / {d}KB ({d}KB min, {d}KB block)", .{
        report.internal.free / 1024,
        report.internal.total / 1024,
        report.internal.min_free / 1024,
        report.internal.largest_block / 1024,
    });
    if (report.psram.total > 0) {
        log.info("PSRAM:    {d}KB free / {d}KB", .{
            report.psram.free / 1024,
            report.psram.total / 1024,
        });
    }
    log.info("Stack:    ~{d} used / {d} (high water: {d})", .{
        report.stack.used,
        report.stack.total,
        report.stack.high_water,
    });
}
