//! LVGL Flux Sync Engine — Bandwidth Efficiency Benchmark
//!
//! Measures the SyncEngine's ability to detect which state fields changed
//! and how that maps to LVGL widget invalidation (minimal dirty area).
//!
//! Complements lib/pkg/ui/state/src/bench.zig which measures the framebuffer
//! approach. Together they show the bandwidth difference between:
//!   - Framebuffer: redraw everything → DirtyTracker merges regions → large flush
//!   - LVGL Flux: diff state fields → invalidate only changed widgets → small flush
//!
//! Run:
//!   bazel test //lib/pkg/ui/lvgl_flux:bench --test_output=all

const std = @import("std");
const lvgl_flux = @import("lvgl_flux.zig");
const SyncEngine = lvgl_flux.SyncEngine;
const ViewBinding = lvgl_flux.ViewBinding;

// ============================================================================
// Display config (matches framebuffer bench)
// ============================================================================

const W: u32 = 240;
const H: u32 = 240;
const BPP: u32 = 2;
const TOTAL_BYTES: u32 = W * H * BPP;

// Widget bounding box areas (in bytes)
const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

fn rectBytes(r: Rect) u32 {
    return @as(u32, r.w) * @as(u32, r.h) * BPP;
}

// ============================================================================
// App state (realistic menu + game + settings UI)
// ============================================================================

const AppState = struct {
    // Status bar
    time_hour: u8 = 12,
    time_min: u8 = 30,
    battery: u8 = 80,
    wifi_on: bool = true,

    // Navigation
    page: enum(u8) { menu, settings, game } = .menu,

    // Menu page
    selected_item: u8 = 0,

    // Settings page
    brightness: u8 = 128,
    volume: u8 = 200,
    wifi_setting: bool = true,

    // Game page
    score: u32 = 0,
    player_x: u16 = 110,
    obstacle_y: [3]u16 = .{ 50, 100, 150 },
};

// ============================================================================
// Widget layout (known bounding boxes)
// ============================================================================

const widget = struct {
    const time_label = Rect{ .x = 8, .y = 8, .w = 40, .h = 8 };
    const battery_bar = Rect{ .x = 200, .y = 8, .w = 30, .h = 8 };
    const wifi_dot = Rect{ .x = 190, .y = 10, .w = 4, .h = 4 };
    const content_area = Rect{ .x = 0, .y = 24, .w = 240, .h = 216 };
    const menu_item_0 = Rect{ .x = 10, .y = 30, .w = 220, .h = 38 };
    const menu_item_1 = Rect{ .x = 10, .y = 72, .w = 220, .h = 38 };
    const menu_item_2 = Rect{ .x = 10, .y = 114, .w = 220, .h = 38 };
    const menu_item_3 = Rect{ .x = 10, .y = 156, .w = 220, .h = 38 };
    const menu_item_4 = Rect{ .x = 10, .y = 198, .w = 220, .h = 38 };
    const brightness_bar = Rect{ .x = 120, .y = 52, .w = 100, .h = 6 };
    const volume_bar = Rect{ .x = 120, .y = 72, .w = 100, .h = 6 };
    const wifi_toggle = Rect{ .x = 120, .y = 92, .w = 40, .h = 8 };
    const score_label = Rect{ .x = 8, .y = 6, .w = 88, .h = 8 };
    const player_car = Rect{ .x = 0, .y = 180, .w = 240, .h = 45 }; // full row (position varies)
    const obstacle_0 = Rect{ .x = 80, .y = 0, .w = 25, .h = 40 };
    const obstacle_1 = Rect{ .x = 140, .y = 0, .w = 25, .h = 40 };
    const obstacle_2 = Rect{ .x = 100, .y = 0, .w = 25, .h = 40 };
};

fn menuItemRect(index: u8) Rect {
    return switch (index) {
        0 => widget.menu_item_0,
        1 => widget.menu_item_1,
        2 => widget.menu_item_2,
        3 => widget.menu_item_3,
        4 => widget.menu_item_4,
        else => widget.menu_item_0,
    };
}

// ============================================================================
// View bindings — each binding knows its widget's bounding box
// ============================================================================

// Track which widgets got invalidated per sync
var invalidated_bytes: u32 = 0;
var invalidated_widgets: u8 = 0;

fn invalidate(r: Rect) void {
    invalidated_bytes += rectBytes(r);
    invalidated_widgets += 1;
}

fn resetInvalidation() void {
    invalidated_bytes = 0;
    invalidated_widgets = 0;
}

const bindings = [_]ViewBinding(AppState){
    // Status: time
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.time_hour != p.time_hour or s.time_min != p.time_min) {
                invalidate(widget.time_label);
                return true;
            }
            return false;
        }
    }.f },
    // Status: battery
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.battery != p.battery) {
                invalidate(widget.battery_bar);
                return true;
            }
            return false;
        }
    }.f },
    // Status: wifi
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.wifi_on != p.wifi_on) {
                invalidate(widget.wifi_dot);
                return true;
            }
            return false;
        }
    }.f },
    // Page switch → invalidate entire content area
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page != p.page) {
                invalidate(widget.content_area);
                return true;
            }
            return false;
        }
    }.f },
    // Menu: selected item highlight
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == .menu and s.selected_item != p.selected_item) {
                invalidate(menuItemRect(p.selected_item)); // old
                invalidate(menuItemRect(s.selected_item)); // new
                return true;
            }
            return false;
        }
    }.f },
    // Settings: brightness
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == .settings and s.brightness != p.brightness) {
                invalidate(widget.brightness_bar);
                return true;
            }
            return false;
        }
    }.f },
    // Settings: volume
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == .settings and s.volume != p.volume) {
                invalidate(widget.volume_bar);
                return true;
            }
            return false;
        }
    }.f },
    // Settings: wifi toggle
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == .settings and s.wifi_setting != p.wifi_setting) {
                invalidate(widget.wifi_toggle);
                return true;
            }
            return false;
        }
    }.f },
    // Game: score
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == .game and s.score != p.score) {
                invalidate(widget.score_label);
                return true;
            }
            return false;
        }
    }.f },
    // Game: player position
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == .game and s.player_x != p.player_x) {
                invalidate(widget.player_car);
                return true;
            }
            return false;
        }
    }.f },
    // Game: obstacles
    .{ .sync_fn = struct {
        fn f(s: *const AppState, p: *const AppState) bool {
            if (s.page == .game and !std.mem.eql(u16, &s.obstacle_y, &p.obstacle_y)) {
                invalidate(widget.obstacle_0);
                invalidate(widget.obstacle_1);
                invalidate(widget.obstacle_2);
                return true;
            }
            return false;
        }
    }.f },
};

var engine = SyncEngine(AppState, &bindings).init();

// ============================================================================
// Measure helper
// ============================================================================

const SpiSpeed = struct { name: []const u8, mhz: u32 };
const spi_speeds = [_]SpiSpeed{
    .{ .name = "10MHz", .mhz = 10 },
    .{ .name = "20MHz", .mhz = 20 },
    .{ .name = "40MHz", .mhz = 40 },
    .{ .name = "80MHz", .mhz = 80 },
};

fn measureSync(name: []const u8, current: AppState, prev: AppState) void {
    resetInvalidation();
    engine.sync(&current, &prev);

    const bytes = invalidated_bytes;
    const widgets_count = invalidated_widgets;
    const pct = if (TOTAL_BYTES > 0) @as(u64, bytes) * 10000 / TOTAL_BYTES else 0;

    std.debug.print("  {s}:\n", .{name});
    std.debug.print("    dirty: {d} bytes ({d}.{d:0>2}% of screen), {d} widgets\n", .{
        bytes,
        pct / 100,
        pct % 100,
        widgets_count,
    });
    for (spi_speeds) |spd| {
        const bits: u64 = @as(u64, bytes) * 8;
        const time_us: u64 = if (spd.mhz > 0) bits / spd.mhz else 0;
        const max_fps: u64 = if (time_us > 0) 1_000_000 / time_us else 99999;
        std.debug.print("    @{s}: {d}us, max {d} fps\n", .{ spd.name, time_us, max_fps });
    }
}

// ============================================================================
// Tests — each measures one type of state transition
// ============================================================================

test "bandwidth: menu select next item" {
    std.debug.print("\n=== LVGL Flux: Menu select 0 → 1 ===\n", .{});
    var s = AppState{};
    const prev = s;
    s.selected_item = 1;
    measureSync("select next", s, prev);
}

test "bandwidth: menu select skip" {
    std.debug.print("\n=== LVGL Flux: Menu select 0 → 2 ===\n", .{});
    var s = AppState{};
    const prev = s;
    s.selected_item = 2;
    measureSync("select skip", s, prev);
}

test "bandwidth: time update" {
    std.debug.print("\n=== LVGL Flux: Time 12:30 → 12:31 ===\n", .{});
    var s = AppState{};
    const prev = s;
    s.time_min = 31;
    measureSync("time update", s, prev);
}

test "bandwidth: battery update" {
    std.debug.print("\n=== LVGL Flux: Battery 80% → 75% ===\n", .{});
    var s = AppState{};
    const prev = s;
    s.battery = 75;
    measureSync("battery update", s, prev);
}

test "bandwidth: wifi toggle" {
    std.debug.print("\n=== LVGL Flux: WiFi on → off ===\n", .{});
    var s = AppState{};
    const prev = s;
    s.wifi_on = false;
    measureSync("wifi toggle", s, prev);
}

test "bandwidth: page switch menu → settings" {
    std.debug.print("\n=== LVGL Flux: Page menu → settings ===\n", .{});
    var s = AppState{};
    const prev = s;
    s.page = .settings;
    measureSync("page switch", s, prev);
}

test "bandwidth: settings brightness change" {
    std.debug.print("\n=== LVGL Flux: Brightness 128 → 180 ===\n", .{});
    var s = AppState{ .page = .settings };
    const prev = s;
    s.brightness = 180;
    measureSync("brightness", s, prev);
}

test "bandwidth: game score increment" {
    std.debug.print("\n=== LVGL Flux: Score 100 → 101 ===\n", .{});
    var s = AppState{ .page = .game, .score = 100 };
    const prev = s;
    s.score = 101;
    measureSync("score update", s, prev);
}

test "bandwidth: game player move" {
    std.debug.print("\n=== LVGL Flux: Player move 110 → 140 ===\n", .{});
    var s = AppState{ .page = .game, .player_x = 110 };
    const prev = s;
    s.player_x = 140;
    measureSync("player move", s, prev);
}

test "bandwidth: game obstacle scroll" {
    std.debug.print("\n=== LVGL Flux: Obstacles scroll 5px ===\n", .{});
    var s = AppState{ .page = .game, .obstacle_y = .{ 50, 100, 150 } };
    const prev = s;
    s.obstacle_y = .{ 55, 105, 155 };
    measureSync("obstacle scroll", s, prev);
}

test "bandwidth: no change (idle)" {
    std.debug.print("\n=== LVGL Flux: No change (idle frame) ===\n", .{});
    const s = AppState{};
    measureSync("idle", s, s);
}

test "bandwidth: multiple changes at once" {
    std.debug.print("\n=== LVGL Flux: Multiple changes (time + battery + wifi) ===\n", .{});
    var s = AppState{};
    const prev = s;
    s.time_min = 31;
    s.battery = 75;
    s.wifi_on = false;
    measureSync("multi-change", s, prev);
}
