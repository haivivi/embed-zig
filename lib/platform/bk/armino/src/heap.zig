//! BK7258 Heap memory functions and Allocators
//!
//! Provides std.mem.Allocator implementations for different memory types:
//! - psram: External PSRAM (8/16MB, large capacity, slightly slower)
//! - sram: Internal SRAM (~640KB, fast, limited capacity)
//! - default: Same as sram (system default)
//!
//! Usage:
//!   const heap = @import("bk").armino.heap;
//!
//!   // Allocate from PSRAM (large buffers, TLS, BLE state)
//!   const buf = try heap.psram.alloc(u8, 32768);
//!   defer heap.psram.free(buf);
//!
//!   // Allocate from SRAM (fast, small/critical allocations)
//!   const small = try heap.sram.alloc(u8, 256);
//!   defer heap.sram.free(small);

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// C helper externs
extern fn bk_zig_psram_malloc(size: c_uint) ?[*]u8;
extern fn bk_zig_sram_malloc(size: c_uint) ?[*]u8;
extern fn bk_zig_free(ptr: ?*anyopaque) void;
extern fn bk_zig_psram_aligned_alloc(alignment: c_uint, size: c_uint) ?[*]u8;
extern fn bk_zig_sram_aligned_alloc(alignment: c_uint, size: c_uint) ?[*]u8;
extern fn bk_zig_aligned_free(ptr: ?*anyopaque) void;

// Stats externs
extern fn bk_zig_sram_get_total() c_uint;
extern fn bk_zig_sram_get_free() c_uint;
extern fn bk_zig_sram_get_min_free() c_uint;
extern fn bk_zig_psram_get_total() c_uint;
extern fn bk_zig_psram_get_free() c_uint;
extern fn bk_zig_psram_get_min_free() c_uint;

// ============================================================================
// std.mem.Allocator implementations
// ============================================================================

/// PSRAM Allocator — External RAM (8/16MB, for large buffers)
pub const psram = Allocator{
    .ptr = undefined,
    .vtable = &psram_vtable,
};

const psram_vtable = Allocator.VTable{
    .alloc = psramAlloc,
    .resize = noResize,
    .remap = noRemap,
    .free = psramFree,
};

fn psramAlloc(_: *anyopaque, len: usize, ptr_align: mem.Alignment, _: usize) ?[*]u8 {
    const alignment = ptr_align.toByteUnits();
    if (alignment > 4) {
        return bk_zig_psram_aligned_alloc(@intCast(alignment), @intCast(len));
    }
    return bk_zig_psram_malloc(@intCast(len));
}

fn psramFree(_: *anyopaque, buf: []u8, ptr_align: mem.Alignment, _: usize) void {
    const alignment = ptr_align.toByteUnits();
    if (alignment > 4) {
        bk_zig_aligned_free(@ptrCast(buf.ptr));
    } else {
        bk_zig_free(@ptrCast(buf.ptr));
    }
}

/// SRAM Allocator — Internal RAM (~640KB, fast)
pub const sram = Allocator{
    .ptr = undefined,
    .vtable = &sram_vtable,
};

const sram_vtable = Allocator.VTable{
    .alloc = sramAlloc,
    .resize = noResize,
    .remap = noRemap,
    .free = sramFree,
};

fn sramAlloc(_: *anyopaque, len: usize, ptr_align: mem.Alignment, _: usize) ?[*]u8 {
    const alignment = ptr_align.toByteUnits();
    if (alignment > 4) {
        return bk_zig_sram_aligned_alloc(@intCast(alignment), @intCast(len));
    }
    return bk_zig_sram_malloc(@intCast(len));
}

fn sramFree(_: *anyopaque, buf: []u8, ptr_align: mem.Alignment, _: usize) void {
    const alignment = ptr_align.toByteUnits();
    if (alignment > 4) {
        bk_zig_aligned_free(@ptrCast(buf.ptr));
    } else {
        bk_zig_free(@ptrCast(buf.ptr));
    }
}

/// Default Allocator — Same as SRAM (system default)
pub const default = sram;

// Common helpers
fn noResize(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn noRemap(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

// ============================================================================
// Memory Statistics
// ============================================================================

pub const MemStats = struct {
    total: usize,
    free: usize,
    used: usize,
    min_free: usize,
};

/// Get internal SRAM heap stats
pub fn getSramStats() MemStats {
    const total = bk_zig_sram_get_total();
    const free = bk_zig_sram_get_free();
    return .{
        .total = total,
        .free = free,
        .used = total -| free,
        .min_free = bk_zig_sram_get_min_free(),
    };
}

/// Get external PSRAM heap stats
pub fn getPsramStats() MemStats {
    const total = bk_zig_psram_get_total();
    const free = bk_zig_psram_get_free();
    return .{
        .total = total,
        .free = free,
        .used = total -| free,
        .min_free = bk_zig_psram_get_min_free(),
    };
}

/// Aliases matching ESP naming convention
pub const getInternalStats = getSramStats;
pub const getDefaultStats = getSramStats;
