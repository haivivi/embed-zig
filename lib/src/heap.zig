//! ESP-IDF Heap memory functions

const c = @cImport({
    @cInclude("esp_heap_caps.h");
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
