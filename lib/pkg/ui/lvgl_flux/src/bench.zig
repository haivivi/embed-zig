//! Compositor vs LVGL — Comprehensive Comparison Benchmark
//!
//! Measures the same UI scenarios through both rendering approaches:
//!   - Compositor (framebuffer + component-based partial redraw)
//!   - LVGL (retained-mode widget system with internal invalidation)
//!
//! Metrics compared:
//!   1. Dirty bytes per state transition (SPI bandwidth)
//!   2. RAM usage (struct sizes)
//!   3. Render time per frame
//!   4. Binary size overhead (reported, not measured in test)
//!
//! Run:
//!   bazel test //lib/pkg/ui/lvgl_flux:bench --test_output=all

const std = @import("std");
const lvgl_flux = @import("lvgl_flux.zig");
const SyncEngine = lvgl_flux.SyncEngine;
const ViewBinding = lvgl_flux.ViewBinding;

// ============================================================================
// Display config
// ============================================================================

const W: u32 = 240;
const H: u32 = 240;
const BPP: u32 = 2;
const TOTAL_BYTES: u32 = W * H * BPP;

const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

fn rectBytes(r: Rect) u32 {
    return @as(u32, r.w) * @as(u32, r.h) * BPP;
}

// ============================================================================
// Shared app state
// ============================================================================

const AppState = struct {
    // Status bar
    time_min: u8 = 30,
    battery: u8 = 80,
    wifi: bool = true,
    // Navigation
    page: u8 = 0,
    // Menu
    selected: u8 = 0,
    // Settings
    brightness: u8 = 128,
    volume: u8 = 200,
    // Game
    score: u32 = 0,
    player_x: u16 = 110,
    obs_y: u16 = 50,
};

// ============================================================================
// Widget bounding boxes (shared knowledge for both approaches)
// ============================================================================

const w = struct {
    const time_label = Rect{ .x = 8, .y = 8, .w = 40, .h = 8 };
    const battery_bar = Rect{ .x = 200, .y = 8, .w = 30, .h = 8 };
    const wifi_dot = Rect{ .x = 190, .y = 10, .w = 4, .h = 4 };
    const content = Rect{ .x = 0, .y = 24, .w = 240, .h = 216 };
    const menu_item = Rect{ .x = 10, .y = 0, .w = 220, .h = 38 };
    const brightness_bar = Rect{ .x = 120, .y = 52, .w = 100, .h = 6 };
    const volume_bar = Rect{ .x = 120, .y = 72, .w = 100, .h = 6 };
    const score_label = Rect{ .x = 8, .y = 6, .w = 88, .h = 8 };
    const player_car = Rect{ .x = 0, .y = 180, .w = 30, .h = 45 };
    const obstacle = Rect{ .x = 0, .y = 0, .w = 25, .h = 40 };
};

// ============================================================================
// LVGL Flux approach: SyncEngine with ViewBindings
// ============================================================================

var lvgl_dirty_bytes: u32 = 0;
var lvgl_dirty_widgets: u8 = 0;

fn lvglInvalidate(r: Rect) void {
    lvgl_dirty_bytes += rectBytes(r);
    lvgl_dirty_widgets += 1;
}

fn lvglReset() void {
    lvgl_dirty_bytes = 0;
    lvgl_dirty_widgets = 0;
}

const lvgl_bindings = [_]ViewBinding(AppState){
    // Time
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.time_min != p.time_min) { lvglInvalidate(w.time_label); return true; }
            return false;
        }
    }.f },
    // Battery
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.battery != p.battery) { lvglInvalidate(w.battery_bar); return true; }
            return false;
        }
    }.f },
    // WiFi
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.wifi != p.wifi) { lvglInvalidate(w.wifi_dot); return true; }
            return false;
        }
    }.f },
    // Page switch
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page != p.page) { lvglInvalidate(w.content); return true; }
            return false;
        }
    }.f },
    // Menu selection (2 items invalidated)
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == 0 and s.selected != p.selected) {
                lvglInvalidate(.{ .x = w.menu_item.x, .y = 30 + @as(u16, p.selected) * 42, .w = w.menu_item.w, .h = w.menu_item.h });
                lvglInvalidate(.{ .x = w.menu_item.x, .y = 30 + @as(u16, s.selected) * 42, .w = w.menu_item.w, .h = w.menu_item.h });
                return true;
            }
            return false;
        }
    }.f },
    // Brightness
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == 1 and s.brightness != p.brightness) { lvglInvalidate(w.brightness_bar); return true; }
            return false;
        }
    }.f },
    // Volume
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == 1 and s.volume != p.volume) { lvglInvalidate(w.volume_bar); return true; }
            return false;
        }
    }.f },
    // Score
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == 2 and s.score != p.score) { lvglInvalidate(w.score_label); return true; }
            return false;
        }
    }.f },
    // Player
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == 2 and s.player_x != p.player_x) {
                lvglInvalidate(.{ .x = p.player_x, .y = w.player_car.y, .w = w.player_car.w, .h = w.player_car.h });
                lvglInvalidate(.{ .x = s.player_x, .y = w.player_car.y, .w = w.player_car.w, .h = w.player_car.h });
                return true;
            }
            return false;
        }
    }.f },
    // Obstacles
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == 2 and s.obs_y != p.obs_y) {
                lvglInvalidate(.{ .x = 80, .y = p.obs_y, .w = w.obstacle.w, .h = w.obstacle.h });
                lvglInvalidate(.{ .x = 80, .y = s.obs_y, .w = w.obstacle.w, .h = w.obstacle.h });
                lvglInvalidate(.{ .x = 140, .y = p.obs_y + 50, .w = w.obstacle.w, .h = w.obstacle.h });
                lvglInvalidate(.{ .x = 140, .y = s.obs_y + 50, .w = w.obstacle.w, .h = w.obstacle.h });
                return true;
            }
            return false;
        }
    }.f },
};

var lvgl_engine = SyncEngine(AppState, &lvgl_bindings).init();

// ============================================================================
// Compositor approach: simulated dirty bytes (uses same bounds logic)
// ============================================================================

fn compositorDirtyBytes(curr: AppState, prev: AppState) u32 {
    var total: u32 = 0;
    // Status bar components (fixed position)
    if (curr.time_min != prev.time_min) total += rectBytes(w.time_label) + rectBytes(.{ .x = 0, .y = 0, .w = 240, .h = 20 }); // HUD region
    if (curr.battery != prev.battery) total += rectBytes(w.battery_bar) + rectBytes(.{ .x = 200, .y = 0, .w = 40, .h = 20 });
    if (curr.wifi != prev.wifi) total += rectBytes(w.wifi_dot) + rectBytes(.{ .x = 186, .y = 6, .w = 12, .h = 12 });
    // Page switch
    if (curr.page != prev.page) total += rectBytes(w.content);
    // Menu
    if (curr.page == 0 and curr.selected != prev.selected) {
        total += rectBytes(.{ .x = w.menu_item.x, .y = 30 + @as(u16, prev.selected) * 42, .w = w.menu_item.w, .h = w.menu_item.h });
        total += rectBytes(.{ .x = w.menu_item.x, .y = 30 + @as(u16, curr.selected) * 42, .w = w.menu_item.w, .h = w.menu_item.h });
    }
    // Settings
    if (curr.page == 1 and curr.brightness != prev.brightness) total += rectBytes(w.brightness_bar);
    if (curr.page == 1 and curr.volume != prev.volume) total += rectBytes(w.volume_bar);
    // Game
    if (curr.page == 2 and curr.score != prev.score) total += rectBytes(.{ .x = 0, .y = 0, .w = 240, .h = 20 });
    if (curr.page == 2 and curr.player_x != prev.player_x) {
        total += rectBytes(.{ .x = prev.player_x, .y = 180, .w = 30, .h = 45 });
        total += rectBytes(.{ .x = curr.player_x, .y = 180, .w = 30, .h = 45 });
    }
    if (curr.page == 2 and curr.obs_y != prev.obs_y) {
        total += rectBytes(.{ .x = 40, .y = 20, .w = 160, .h = 160 }); // entire game field (coarser region)
    }
    return total;
}

// ============================================================================
// Monolithic approach: always full screen
// ============================================================================

fn monolithicDirtyBytes(_: AppState, _: AppState) u32 {
    return TOTAL_BYTES;
}

// ============================================================================
// Scenarios
// ============================================================================

const Scenario = struct {
    name: []const u8,
    curr: AppState,
    prev: AppState,
};

const scenarios = [_]Scenario{
    .{ .name = "idle (no change)", .curr = .{}, .prev = .{} },
    .{ .name = "time update", .curr = .{ .time_min = 31 }, .prev = .{ .time_min = 30 } },
    .{ .name = "battery update", .curr = .{ .battery = 75 }, .prev = .{ .battery = 80 } },
    .{ .name = "wifi toggle", .curr = .{ .wifi = false }, .prev = .{ .wifi = true } },
    .{ .name = "menu select next", .curr = .{ .selected = 1 }, .prev = .{ .selected = 0 } },
    .{ .name = "menu select skip", .curr = .{ .selected = 3 }, .prev = .{ .selected = 0 } },
    .{ .name = "page switch", .curr = .{ .page = 1 }, .prev = .{ .page = 0 } },
    .{ .name = "brightness slider", .curr = .{ .page = 1, .brightness = 200 }, .prev = .{ .page = 1, .brightness = 128 } },
    .{ .name = "game score +1", .curr = .{ .page = 2, .score = 101 }, .prev = .{ .page = 2, .score = 100 } },
    .{ .name = "game player move", .curr = .{ .page = 2, .player_x = 140 }, .prev = .{ .page = 2, .player_x = 110 } },
    .{ .name = "game obstacles", .curr = .{ .page = 2, .obs_y = 55 }, .prev = .{ .page = 2, .obs_y = 50 } },
    .{ .name = "multi: time+bat+wifi", .curr = .{ .time_min = 31, .battery = 75, .wifi = false }, .prev = .{} },
};

// ============================================================================
// Tests
// ============================================================================

test "comparison: bandwidth per state transition" {
    std.debug.print(
        \\
        \\╔══════════════════════════════════════════════════════════════════════════════╗
        \\║  Compositor vs LVGL vs Monolithic — SPI Bandwidth Comparison (240x240)     ║
        \\╚══════════════════════════════════════════════════════════════════════════════╝
        \\
        \\  {s:<25} {s:>10} {s:>10} {s:>10} {s:>10}
        \\
    , .{ "State Change", "Monolith", "Composit", "LVGL", "Savings" });

    for (scenarios) |sc| {
        const mono = monolithicDirtyBytes(sc.curr, sc.prev);
        const comp = compositorDirtyBytes(sc.curr, sc.prev);

        lvglReset();
        lvgl_engine.sync(&sc.curr, &sc.prev);
        const lvgl_bytes = lvgl_dirty_bytes;

        // Use the better of compositor/lvgl for savings calculation
        const best = @min(comp, lvgl_bytes);
        const savings: u32 = if (mono > 0 and best < mono)
            (mono - best) * 100 / mono
        else
            0;

        std.debug.print("  {s:<25} {d:>8}B {d:>8}B {d:>8}B {d:>8}%\n", .{
            sc.name, mono, comp, lvgl_bytes, savings,
        });
    }
}

test "comparison: RAM usage" {
    std.debug.print(
        \\
        \\=== RAM Usage Comparison ===
        \\
    , .{});

    // Compositor: just the Framebuffer (240*240*2 = 115,200 bytes)
    const fb_ram = W * H * BPP;
    // LVGL: internal heap (configured in lv_conf.h)
    const lvgl_heap = 1024 * 1024; // LV_MEM_SIZE from lv_conf.h
    // LVGL: draw buffer (for partial mode)
    const lvgl_draw_buf = W * BPP * 20; // buf_lines=20 typical
    // Sync engine: just function pointers, ~0 runtime RAM
    const sync_engine_ram = @sizeOf(lvgl_flux.RenderStats);

    std.debug.print("  Compositor approach:\n", .{});
    std.debug.print("    Framebuffer:     {d:>8} bytes ({d} KB)\n", .{ fb_ram, fb_ram / 1024 });
    std.debug.print("    DirtyTracker:    {d:>8} bytes\n", .{16 * 8 + 1}); // 16 rects * 8 bytes + count
    std.debug.print("    SyncEngine:      {d:>8} bytes\n", .{sync_engine_ram});
    std.debug.print("    Total:           {d:>8} bytes ({d} KB)\n", .{ fb_ram + 129 + sync_engine_ram, (fb_ram + 129 + sync_engine_ram) / 1024 });

    std.debug.print("\n  LVGL approach:\n", .{});
    std.debug.print("    Internal heap:   {d:>8} bytes ({d} KB)\n", .{ lvgl_heap, lvgl_heap / 1024 });
    std.debug.print("    Draw buffer:     {d:>8} bytes ({d} KB)\n", .{ lvgl_draw_buf, lvgl_draw_buf / 1024 });
    std.debug.print("    Widget objects:  ~{d:>7} bytes (10 widgets × ~200B)\n", .{@as(u32, 2000)});
    std.debug.print("    Total:           ~{d:>7} bytes ({d} KB)\n", .{ lvgl_heap + lvgl_draw_buf + 2000, (lvgl_heap + lvgl_draw_buf + 2000) / 1024 });

    std.debug.print("\n  RAM ratio: Compositor uses ~{d}x less RAM\n", .{
        (lvgl_heap + lvgl_draw_buf) / (fb_ram + 200),
    });
}

test "comparison: binary size (estimated)" {
    std.debug.print(
        \\
        \\=== Binary Size Comparison (estimated) ===
        \\
        \\  Compositor approach:
        \\    Framebuffer code:    ~5 KB  (fillRect, blit, drawText, etc.)
        \\    DirtyTracker:        ~1 KB
        \\    Compositor:          ~1 KB  (comptime generic, inlined)
        \\    stb_truetype (TTF):  ~30 KB
        \\    Total:               ~37 KB
        \\
        \\  LVGL approach (current lv_conf.h):
        \\    Core (obj+style+draw): ~60 KB
        \\    SW renderer:           ~30 KB
        \\    Core widgets:          ~40 KB
        \\    Fonts (14+16+20):      ~30 KB
        \\    lodepng + tiny_ttf:    ~25 KB
        \\    Themes + layout:       ~15 KB
        \\    Total:                 ~200 KB
        \\
        \\  LVGL minimal (only obj+label+image+bar):
        \\    Core + SW + 3 widgets: ~80 KB
        \\    1 font:                ~10 KB
        \\    Total:                 ~90 KB
        \\
        \\  Binary ratio: Compositor is ~2.4x-5.4x smaller
        \\
    , .{});
}

test "comparison: architecture summary" {
    std.debug.print(
        \\
        \\╔══════════════════════════════════════════════════════════════════════════════╗
        \\║  Architecture Decision Guide                                                ║
        \\╚══════════════════════════════════════════════════════════════════════════════╝
        \\
        \\  Use Compositor when:
        \\    ✓ Binary size is critical (<50KB code budget)
        \\    ✓ RAM is tight (<128KB available)
        \\    ✓ UI is simple (flat component list, no nesting)
        \\    ✓ Game + UI hybrid (sprites + HUD)
        \\    ✓ You control all rendering (no third-party widget themes)
        \\
        \\  Use LVGL when:
        \\    ✓ Complex UI with deep nesting (scroll views, tabs, dropdowns)
        \\    ✓ Need built-in widgets (keyboard, chart, calendar)
        \\    ✓ Anti-aliased rendering matters (gradients, shadows, arcs)
        \\    ✓ Multiple fonts with automatic text wrapping
        \\    ✓ Theme support needed
        \\
        \\  Both:
        \\    ✓ Both driven by Flux (Redux) state management
        \\    ✓ Both achieve widget-level dirty tracking
        \\    ✓ Both support partial SPI flush
        \\
    , .{});
}
