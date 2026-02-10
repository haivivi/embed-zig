//! Heap allocator for BK7258 — PSRAM and SRAM
//!
//! Provides std.mem.Allocator compatible allocators backed by Armino's
//! psram_malloc/os_malloc.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

extern fn bk_zig_psram_malloc(size: c_uint) ?[*]u8;
extern fn bk_zig_sram_malloc(size: c_uint) ?[*]u8;
extern fn bk_zig_free(ptr: ?*anyopaque) void;

/// PSRAM allocator (8MB external RAM, for large buffers like TLS)
pub const psram = Allocator{
    .ptr = undefined,
    .vtable = &psram_vtable,
};

const psram_vtable = Allocator.VTable{
    .alloc = psramAlloc,
    .resize = noResize,
    .remap = noRemap,
    .free = heapFree,
};

/// SRAM allocator (internal 640KB, for small/fast allocations)
pub const sram = Allocator{
    .ptr = undefined,
    .vtable = &sram_vtable,
};

const sram_vtable = Allocator.VTable{
    .alloc = sramAlloc,
    .resize = noResize,
    .remap = noRemap,
    .free = heapFree,
};

fn psramAlloc(_: *anyopaque, len: usize, _: mem.Alignment, _: usize) ?[*]u8 {
    return bk_zig_psram_malloc(@intCast(len));
}

fn sramAlloc(_: *anyopaque, len: usize, _: mem.Alignment, _: usize) ?[*]u8 {
    return bk_zig_sram_malloc(@intCast(len));
}

fn noResize(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn noRemap(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn heapFree(_: *anyopaque, buf: []u8, _: mem.Alignment, _: usize) void {
    bk_zig_free(@ptrCast(buf.ptr));
}
