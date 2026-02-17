//! UI Render Benchmark
//!
//! Measures performance of the framebuffer rendering pipeline:
//!   - Drawing primitives (fillRect, drawRect, fillRoundRect, blit, blitAlpha)
//!   - Dirty rect tracking efficiency (dirty pixels vs total pixels)
//!   - Full render pipeline (dispatch → reduce → render → flush)
//!   - Text rendering (bitmap + TTF)
//!
//! Run:
//!   bazel test //lib/pkg/ui/state:bench
//!
//! All timings use std.time.Timer for nanosecond precision.

const std = @import("std");
const ui = @import("ui_state.zig");
const Framebuffer = ui.Framebuffer;
const Rect = ui.Rect;
const DirtyTracker = ui.DirtyTracker;
const BitmapFont = ui.BitmapFont;
const Image = ui.Image;
const Store = ui.Store;

// ============================================================================
// Benchmark harness
// ============================================================================

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,

    fn avgNs(self: BenchResult) u64 {
        return if (self.iterations > 0) self.total_ns / self.iterations else 0;
    }

    fn opsPerSec(self: BenchResult) u64 {
        if (self.total_ns == 0) return 0;
        return self.iterations * std.time.ns_per_s / self.total_ns;
    }

    fn report(self: BenchResult) void {
        std.debug.print("  {s}: {d} iters, avg {d} ns, min {d} ns, max {d} ns, {d} ops/s\n", .{
            self.name,
            self.iterations,
            self.avgNs(),
            self.min_ns,
            self.max_ns,
            self.opsPerSec(),
        });
    }
};

fn bench(name: []const u8, comptime warmup: u32, comptime iters: u32, comptime func: fn () void) BenchResult {
    // Warmup
    for (0..warmup) |_| func();

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iters) |_| {
        const start = std.time.nanoTimestamp();
        func();
        const end = std.time.nanoTimestamp();
        const elapsed: u64 = @intCast(end - start);
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return .{
        .name = name,
        .iterations = iters,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

// ============================================================================
// Benchmark framebuffer types
// ============================================================================

// Small screen (typical watch/IoT)
const SmallFB = Framebuffer(240, 240, .rgb565);
// Medium screen (typical phone-like)
const MedFB = Framebuffer(320, 320, .rgb565);

// Shared mutable state for benchmarks (avoid stack allocation issues)
var small_fb: SmallFB = SmallFB.init(0);
var med_fb: MedFB = MedFB.init(0);

// ============================================================================
// 1. Drawing Primitive Benchmarks
// ============================================================================

fn benchFillRectSmall() void {
    small_fb.clearDirty();
    small_fb.fillRect(10, 10, 100, 100, 0xF800);
}

fn benchFillRectFullScreen() void {
    small_fb.clearDirty();
    small_fb.fillRect(0, 0, 240, 240, 0x07E0);
}

fn benchFillRectManySmall() void {
    small_fb.clearDirty();
    var i: u16 = 0;
    while (i < 16) : (i += 1) {
        small_fb.fillRect(i * 15, i * 15, 10, 10, 0x001F);
    }
}

fn benchDrawRect() void {
    small_fb.clearDirty();
    small_fb.drawRect(20, 20, 200, 200, 0xFFFF, 2);
}

fn benchFillRoundRect() void {
    small_fb.clearDirty();
    small_fb.fillRoundRect(30, 30, 180, 60, 10, 0xF800);
}

fn benchFillRoundRectLargeRadius() void {
    small_fb.clearDirty();
    small_fb.fillRoundRect(20, 20, 200, 200, 30, 0x07E0);
}

fn benchClear() void {
    small_fb.clear(0x0000);
}

fn benchSetPixelGrid() void {
    small_fb.clearDirty();
    var y: u16 = 0;
    while (y < 240) : (y += 4) {
        var x: u16 = 0;
        while (x < 240) : (x += 4) {
            small_fb.setPixel(x, y, 0xFFFF);
        }
    }
}

// ============================================================================
// 2. Blit Benchmarks
// ============================================================================

// 32x32 test image data (RGB565)
var img_data_32: [32 * 32 * 2]u8 = blk: {
    @setEvalBranchQuota(10000);
    var d: [32 * 32 * 2]u8 = undefined;
    for (0..32 * 32) |i| {
        const x = i % 32;
        const y = i / 32;
        const color: u16 = if ((x + y) % 2 == 0) 0xF800 else 0x07E0;
        d[i * 2] = @truncate(color);
        d[i * 2 + 1] = @truncate(color >> 8);
    }
    break :blk d;
};

const test_img_32 = Image{
    .data = &img_data_32,
    .width = 32,
    .height = 32,
    .bytes_per_pixel = 2,
};

fn benchBlit32x32() void {
    small_fb.clearDirty();
    small_fb.blit(50, 50, test_img_32);
}

fn benchBlitMultiple() void {
    small_fb.clearDirty();
    var i: u16 = 0;
    while (i < 8) : (i += 1) {
        small_fb.blit(i * 28, i * 28, test_img_32);
    }
}

fn benchBlitTransparent() void {
    small_fb.clearDirty();
    small_fb.blitTransparent(50, 50, test_img_32, 0xF800);
}

// 32x32 RGBA5658 image (3 bytes per pixel)
var img_data_alpha: [32 * 32 * 3]u8 = blk: {
    @setEvalBranchQuota(10000);
    var d: [32 * 32 * 3]u8 = undefined;
    for (0..32 * 32) |i| {
        const x = i % 32;
        const y = i / 32;
        const color: u16 = 0xF800;
        d[i * 3] = @truncate(color);
        d[i * 3 + 1] = @truncate(color >> 8);
        d[i * 3 + 2] = @truncate((x * 8) ^ (y * 8));
    }
    break :blk d;
};

const test_img_alpha = Image{
    .data = &img_data_alpha,
    .width = 32,
    .height = 32,
    .bytes_per_pixel = 3,
};

fn benchBlitAlpha() void {
    small_fb.clearDirty();
    small_fb.blit(50, 50, test_img_alpha);
}

// ============================================================================
// 3. Text Rendering Benchmarks
// ============================================================================

// Minimal ASCII bitmap font for benchmarking (8x8 monospace)
const bench_font_bitmap: [96 * 8]u8 = blk: {
    @setEvalBranchQuota(10000);
    var d: [96 * 8]u8 = undefined;
    for (0..96) |ch| {
        for (0..8) |row| {
            d[ch * 8 + row] = if (row % 2 == 0) 0xAA else 0x55;
        }
    }
    break :blk d;
};

fn benchFontLookup(cp: u21) ?u32 {
    if (cp >= 0x20 and cp <= 0x7F) return @as(u32, cp) - 0x20;
    return null;
}

const bench_font = BitmapFont{
    .glyph_w = 8,
    .glyph_h = 8,
    .data = &bench_font_bitmap,
    .lookup = benchFontLookup,
};

fn benchDrawTextShort() void {
    small_fb.clearDirty();
    small_fb.drawText(10, 10, "Hello", &bench_font, 0xFFFF);
}

fn benchDrawTextLong() void {
    small_fb.clearDirty();
    small_fb.drawText(10, 10, "The quick brown fox jumps", &bench_font, 0xFFFF);
}

fn benchDrawTextMultiLine() void {
    small_fb.clearDirty();
    var y: u16 = 0;
    while (y < 240) : (y += 10) {
        small_fb.drawText(0, y, "ABCDEFGHIJKLMNOP", &bench_font, 0xFFFF);
    }
}

// ============================================================================
// 4. Dirty Rect Tracking Benchmarks
// ============================================================================

fn benchDirtyMarkScattered() void {
    var dt = DirtyTracker(16).init();
    // 16 non-overlapping rects → fill tracker
    var i: u16 = 0;
    while (i < 16) : (i += 1) {
        dt.mark(.{ .x = i * 15, .y = 0, .w = 10, .h = 10 });
    }
}

fn benchDirtyMarkOverlapping() void {
    var dt = DirtyTracker(16).init();
    // Overlapping rects → should merge
    var i: u16 = 0;
    while (i < 100) : (i += 1) {
        dt.mark(.{ .x = i * 2, .y = i * 2, .w = 20, .h = 20 });
    }
}

fn benchDirtyMarkAndCollapse() void {
    var dt = DirtyTracker(4).init();
    // Force repeated collapse (tracker size = 4)
    var i: u16 = 0;
    while (i < 50) : (i += 1) {
        dt.mark(.{ .x = i * 4, .y = i * 4, .w = 5, .h = 5 });
    }
}

// ============================================================================
// 5. Full Render Pipeline Benchmarks
// ============================================================================

// Simulates a typical menu UI render
fn benchRenderMenuScene() void {
    small_fb.clearDirty();
    // Background
    small_fb.fillRect(0, 0, 240, 240, 0x0000);
    // Status bar
    small_fb.fillRect(0, 0, 240, 24, 0x2104);
    small_fb.drawText(10, 4, "12:30", &bench_font, 0xFFFF);
    // Menu items (5 rows)
    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        const y = 30 + i * 42;
        small_fb.fillRoundRect(10, y, 220, 38, 8, 0x18E3);
        small_fb.drawText(20, y + 12, "Menu Item", &bench_font, 0xFFFF);
    }
    // Footer
    small_fb.fillRect(0, 220, 240, 20, 0x2104);
}

// Simulates a game render (lots of small objects)
fn benchRenderGameScene() void {
    small_fb.clearDirty();
    // Background fill
    small_fb.fillRect(0, 0, 240, 240, 0x0000);
    // Road (center stripe)
    small_fb.fillRect(80, 0, 80, 240, 0x4208);
    // Road markings
    var y: u16 = 0;
    while (y < 240) : (y += 20) {
        small_fb.fillRect(118, y, 4, 10, 0xFFFF);
    }
    // Player car
    small_fb.fillRoundRect(100, 180, 40, 50, 5, 0xF800);
    // Obstacles (8 cars)
    var i: u16 = 0;
    while (i < 8) : (i += 1) {
        small_fb.fillRoundRect(85 + (i % 3) * 30, i * 28, 25, 35, 4, 0x07E0);
    }
}

// Simulates partial update (only one menu item changes)
fn benchRenderPartialUpdate() void {
    small_fb.clearDirty();
    // Only update one menu item's highlight
    small_fb.fillRoundRect(10, 72, 220, 38, 8, 0xF800);
    small_fb.drawText(20, 84, "Selected", &bench_font, 0xFFFF);
}

// ============================================================================
// 6. Flush (getRegion) Benchmarks
// ============================================================================

var flush_out: [240 * 240]u16 = undefined;

fn benchGetRegionSmall() void {
    _ = small_fb.getRegion(.{ .x = 10, .y = 10, .w = 100, .h = 100 }, &flush_out);
}

fn benchGetRegionFullScreen() void {
    _ = small_fb.getRegion(.{ .x = 0, .y = 0, .w = 240, .h = 240 }, &flush_out);
}

fn benchGetRegionPartial() void {
    // Simulate flushing only dirty rects after partial update
    small_fb.clearDirty();
    small_fb.fillRoundRect(10, 72, 220, 38, 8, 0xF800);
    const rects = small_fb.getDirtyRects();
    for (rects) |r| {
        _ = small_fb.getRegion(r, &flush_out);
    }
}

// ============================================================================
// 7. Dirty Tracking Efficiency Analysis
// ============================================================================

const DirtyStats = struct {
    scenario: []const u8,
    total_pixels: u32,
    dirty_pixels: u32,
    rect_count: u8,
    coverage_pct: u32,

    fn report(self: DirtyStats) void {
        std.debug.print("  {s}: {d} dirty / {d} total = {d}%, rects={d}\n", .{
            self.scenario,
            self.dirty_pixels,
            self.total_pixels,
            self.coverage_pct,
            self.rect_count,
        });
    }
};

fn analyzeDirtyEfficiency(comptime W: u16, comptime H: u16, scenario: []const u8, rects: []const Rect) DirtyStats {
    const total: u32 = @as(u32, W) * @as(u32, H);
    var dirty: u32 = 0;
    for (rects) |r| {
        dirty += r.area();
    }
    // Cap at total (overlapping rects can exceed)
    dirty = @min(dirty, total);
    const pct: u32 = if (total > 0) dirty * 100 / total else 0;

    return .{
        .scenario = scenario,
        .total_pixels = total,
        .dirty_pixels = dirty,
        .rect_count = @intCast(rects.len),
        .coverage_pct = pct,
    };
}

// ============================================================================
// 8. Store dispatch benchmark
// ============================================================================

const Page = enum { home, menu, game, settings };

const BenchState = struct {
    page: Page = .home,
    selected: u8 = 0,
    score: u32 = 0,
    frame_count: u32 = 0,
};

const BenchEvent = union(enum) {
    navigate: Page,
    select_up,
    select_down,
    score_add: u32,
    tick,
};

fn benchReducer(state: *BenchState, event: BenchEvent) void {
    switch (event) {
        .navigate => |page| state.page = page,
        .select_up => {
            if (state.selected > 0) state.selected -= 1;
        },
        .select_down => {
            if (state.selected < 10) state.selected += 1;
        },
        .score_add => |n| state.score += n,
        .tick => state.frame_count += 1,
    }
}

fn benchStoreDispatch() void {
    var store = Store(BenchState, BenchEvent).init(.{}, benchReducer);
    // Simulate 100 events
    for (0..100) |i| {
        if (i % 5 == 0) {
            store.dispatch(.{ .navigate = .menu });
        } else if (i % 3 == 0) {
            store.dispatch(.select_down);
        } else {
            store.dispatch(.tick);
        }
    }
    store.commitFrame();
}

fn benchStoreDispatchBatch() void {
    var store = Store(BenchState, BenchEvent).init(.{}, benchReducer);
    const events = [_]BenchEvent{
        .tick, .tick, .tick, .select_down, .select_down,
        .{ .score_add = 100 }, .tick, .tick, .tick, .tick,
    };
    for (0..10) |_| {
        store.dispatchBatch(&events);
    }
    store.commitFrame();
}

// ============================================================================
// Test entrypoints
// ============================================================================

test "bench: drawing primitives" {
    std.debug.print("\n=== Drawing Primitives (240x240 RGB565) ===\n", .{});
    bench("fillRect 100x100", 10, 1000, benchFillRectSmall).report();
    bench("fillRect fullscreen", 10, 1000, benchFillRectFullScreen).report();
    bench("fillRect 16x small", 10, 1000, benchFillRectManySmall).report();
    bench("drawRect 200x200", 10, 1000, benchDrawRect).report();
    bench("fillRoundRect 180x60 r10", 10, 1000, benchFillRoundRect).report();
    bench("fillRoundRect 200x200 r30", 10, 1000, benchFillRoundRectLargeRadius).report();
    bench("clear", 10, 1000, benchClear).report();
    bench("setPixel 60x60 grid", 10, 1000, benchSetPixelGrid).report();
}

test "bench: blit operations" {
    std.debug.print("\n=== Blit Operations (32x32 images) ===\n", .{});
    bench("blit 32x32 RGB565", 10, 1000, benchBlit32x32).report();
    bench("blit 8x 32x32", 10, 1000, benchBlitMultiple).report();
    bench("blitTransparent 32x32", 10, 1000, benchBlitTransparent).report();
    bench("blitAlpha 32x32 RGBA5658", 10, 1000, benchBlitAlpha).report();
}

test "bench: text rendering" {
    std.debug.print("\n=== Text Rendering (bitmap font) ===\n", .{});
    bench("drawText 5 chars", 10, 1000, benchDrawTextShort).report();
    bench("drawText 25 chars", 10, 1000, benchDrawTextLong).report();
    bench("drawText 24 lines fill", 10, 500, benchDrawTextMultiLine).report();
}

test "bench: dirty rect tracking" {
    std.debug.print("\n=== Dirty Rect Tracking ===\n", .{});
    bench("mark 16 scattered", 100, 10000, benchDirtyMarkScattered).report();
    bench("mark 100 overlapping", 100, 10000, benchDirtyMarkOverlapping).report();
    bench("mark 50 with collapse", 100, 10000, benchDirtyMarkAndCollapse).report();
}

test "bench: full render pipeline" {
    std.debug.print("\n=== Full Render Pipeline (240x240 RGB565) ===\n", .{});
    bench("menu scene", 5, 500, benchRenderMenuScene).report();
    bench("game scene", 5, 500, benchRenderGameScene).report();
    bench("partial update", 10, 1000, benchRenderPartialUpdate).report();
}

test "bench: flush (getRegion)" {
    std.debug.print("\n=== Flush / getRegion ===\n", .{});
    bench("getRegion 100x100", 10, 1000, benchGetRegionSmall).report();
    bench("getRegion fullscreen", 10, 1000, benchGetRegionFullScreen).report();
    bench("getRegion partial dirty", 10, 1000, benchGetRegionPartial).report();
}

test "bench: store dispatch" {
    std.debug.print("\n=== Store Dispatch ===\n", .{});
    bench("100 dispatches", 10, 1000, benchStoreDispatch).report();
    bench("10x batch of 10", 10, 1000, benchStoreDispatchBatch).report();
}

test "bench: dirty tracking efficiency analysis" {
    std.debug.print("\n=== Dirty Tracking Efficiency ===\n", .{});

    // Scenario 1: Full screen clear
    {
        small_fb.clearDirty();
        small_fb.clear(0x0000);
        analyzeDirtyEfficiency(240, 240, "full clear", small_fb.getDirtyRects()).report();
    }

    // Scenario 2: Menu scene (mixed rects)
    {
        benchRenderMenuScene();
        analyzeDirtyEfficiency(240, 240, "menu scene", small_fb.getDirtyRects()).report();
    }

    // Scenario 3: Partial update (one item)
    {
        // First render full menu
        benchRenderMenuScene();
        small_fb.clearDirty();
        // Then update only one item
        small_fb.fillRoundRect(10, 72, 220, 38, 8, 0xF800);
        small_fb.drawText(20, 84, "Selected", &bench_font, 0xFFFF);
        analyzeDirtyEfficiency(240, 240, "partial (1 item)", small_fb.getDirtyRects()).report();
    }

    // Scenario 4: Game scene (scattered small objects)
    {
        benchRenderGameScene();
        analyzeDirtyEfficiency(240, 240, "game scene", small_fb.getDirtyRects()).report();
    }

    // Scenario 5: Single pixel change
    {
        small_fb.clearDirty();
        small_fb.setPixel(120, 120, 0xFFFF);
        analyzeDirtyEfficiency(240, 240, "single pixel", small_fb.getDirtyRects()).report();
    }

    // Scenario 6: Two corners (worst case for dirty tracking)
    {
        small_fb.clearDirty();
        small_fb.fillRect(0, 0, 20, 20, 0xF800);
        small_fb.fillRect(220, 220, 20, 20, 0x07E0);
        analyzeDirtyEfficiency(240, 240, "two corners", small_fb.getDirtyRects()).report();
    }
}

// ============================================================================
// 9. Medium screen (320x320) comparison
// ============================================================================

fn benchFillRectMed() void {
    med_fb.clearDirty();
    med_fb.fillRect(10, 10, 100, 100, 0xF800);
}

fn benchFillRectFullMed() void {
    med_fb.clearDirty();
    med_fb.fillRect(0, 0, 320, 320, 0x07E0);
}

fn benchClearMed() void {
    med_fb.clear(0x0000);
}

test "bench: 320x320 comparison" {
    std.debug.print("\n=== 320x320 vs 240x240 Comparison ===\n", .{});
    bench("240: fillRect 100x100", 10, 1000, benchFillRectSmall).report();
    bench("320: fillRect 100x100", 10, 1000, benchFillRectMed).report();
    bench("240: fillRect full", 10, 1000, benchFillRectFullScreen).report();
    bench("320: fillRect full", 10, 1000, benchFillRectFullMed).report();
    bench("240: clear", 10, 1000, benchClear).report();
    bench("320: clear", 10, 1000, benchClearMed).report();
}
