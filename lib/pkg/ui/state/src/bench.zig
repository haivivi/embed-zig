//! UI Bandwidth Benchmark
//!
//! Measures the minimum SPI transfer bytes needed for each type of state
//! change. Lower dirty bytes = lower bandwidth = higher achievable frame rate.
//!
//! For a 240x240 RGB565 display:
//!   Full screen = 240 × 240 × 2 = 115,200 bytes
//!   SPI 40MHz = ~23ms per full frame → max 43 fps
//!   SPI 80MHz = ~11.5ms per full frame → max 86 fps
//!
//! If a state change only dirties 5% of the screen:
//!   5,760 bytes → ~1.15ms at 40MHz → 869 fps theoretical limit
//!
//! Run:
//!   bazel test //lib/pkg/ui/state:bench --test_output=all

const std = @import("std");
const ui = @import("ui_state.zig");
const Framebuffer = ui.Framebuffer;
const Rect = ui.Rect;
const DirtyTracker = ui.DirtyTracker;
const BitmapFont = ui.BitmapFont;
const Image = ui.Image;

// ============================================================================
// Display config
// ============================================================================

const W: u16 = 240;
const H: u16 = 240;
const BPP: u32 = 2; // RGB565
const TOTAL_BYTES: u32 = @as(u32, W) * H * BPP;
const TOTAL_PIXELS: u32 = @as(u32, W) * H;

const FB = Framebuffer(W, H, .rgb565);

// SPI clock speeds for bandwidth calculation
const spi_speeds = [_]struct { name: []const u8, mhz: u32 }{
    .{ .name = "10MHz", .mhz = 10 },
    .{ .name = "20MHz", .mhz = 20 },
    .{ .name = "40MHz", .mhz = 40 },
    .{ .name = "80MHz", .mhz = 80 },
};

// ============================================================================
// Bandwidth result
// ============================================================================

const BwResult = struct {
    name: []const u8,
    dirty_pixels: u32,
    dirty_bytes: u32,
    rect_count: u8,
    coverage_pct: u32, // 0-10000 (2 decimal places)

    fn fromFb(name: []const u8, f: *const FB) BwResult {
        const rects = f.getDirtyRects();
        var pixels: u32 = 0;
        for (rects) |r| {
            pixels += r.area();
        }
        pixels = @min(pixels, TOTAL_PIXELS);
        return .{
            .name = name,
            .dirty_pixels = pixels,
            .dirty_bytes = pixels * BPP,
            .rect_count = @intCast(rects.len),
            .coverage_pct = if (TOTAL_PIXELS > 0) pixels * 10000 / TOTAL_PIXELS else 0,
        };
    }

    fn report(self: BwResult) void {
        std.debug.print("  {s}:\n", .{self.name});
        std.debug.print("    dirty: {d} px, {d} bytes ({d}.{d:0>2}% of screen)\n", .{
            self.dirty_pixels,
            self.dirty_bytes,
            self.coverage_pct / 100,
            self.coverage_pct % 100,
        });
        std.debug.print("    rects: {d}\n", .{self.rect_count});
        // SPI transfer time at different speeds
        for (spi_speeds) |spd| {
            // SPI: 1 byte = 8 bits, time_us = bytes * 8 / (MHz)
            const bits: u64 = @as(u64, self.dirty_bytes) * 8;
            const time_us: u64 = bits / spd.mhz;
            const max_fps: u64 = if (time_us > 0) 1_000_000 / time_us else 99999;
            std.debug.print("    @{s}: {d}us transfer, max {d} fps\n", .{
                spd.name, time_us, max_fps,
            });
        }
    }
};

// ============================================================================
// Bitmap font for text rendering
// ============================================================================

const font_bitmap: [96 * 8]u8 = blk: {
    @setEvalBranchQuota(10000);
    var d: [96 * 8]u8 = undefined;
    for (0..96) |ch| {
        for (0..8) |row| {
            d[ch * 8 + row] = if (row % 2 == 0) 0xAA else 0x55;
        }
    }
    break :blk d;
};

fn fontLookup(cp: u21) ?u32 {
    if (cp >= 0x20 and cp <= 0x7F) return @as(u32, cp) - 0x20;
    return null;
}

const font8x8 = BitmapFont{
    .glyph_w = 8,
    .glyph_h = 8,
    .data = &font_bitmap,
    .lookup = fontLookup,
};

// ============================================================================
// Colors (typical H106-style theme)
// ============================================================================

const BLACK: u16 = 0x0000;
const WHITE: u16 = 0xFFFF;
const DARK_GRAY: u16 = 0x2104;
const MID_GRAY: u16 = 0x4208;
const ACCENT: u16 = 0xF800; // red
const MENU_BG: u16 = 0x18E3;
const GREEN: u16 = 0x07E0;

// ============================================================================
// Scene renderers
//
// Each renders a complete frame. To measure a state transition:
//   1. Render old state
//   2. clearDirty()
//   3. Render new state
//   4. Measure dirty bytes
// ============================================================================

/// Status bar: time + battery + wifi icons
fn renderStatusBar(f: *FB, hour: u8, min: u8, battery: u8, wifi: bool) void {
    f.fillRect(0, 0, W, 24, DARK_GRAY);
    var time_buf: [8]u8 = undefined;
    const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ hour, min }) catch "??:??";
    f.drawText(8, 8, time_str, &font8x8, WHITE);
    const bat_w: u16 = @as(u16, battery) * 30 / 100;
    f.fillRect(W - 40, 8, 30, 8, MID_GRAY);
    f.fillRect(W - 40, 8, bat_w, 8, if (battery > 20) GREEN else ACCENT);
    if (wifi) f.fillRect(W - 50, 10, 4, 4, GREEN);
}

/// Menu page with N items, one selected
fn renderMenuPage(f: *FB, selected: u8, item_count: u8) void {
    f.fillRect(0, 24, W, H - 24, BLACK);
    var i: u8 = 0;
    while (i < item_count) : (i += 1) {
        const y: u16 = 30 + @as(u16, i) * 42;
        const bg = if (i == selected) ACCENT else MENU_BG;
        f.fillRoundRect(10, y, 220, 38, 8, bg);
        var label_buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Item {d}", .{i}) catch "Item ?";
        f.drawText(20, y + 14, label, &font8x8, WHITE);
    }
}

/// Game HUD: score display at top
fn renderGameHud(f: *FB, score: u32) void {
    f.fillRect(0, 0, W, 20, DARK_GRAY);
    var score_buf: [16]u8 = undefined;
    const score_str = std.fmt.bufPrint(&score_buf, "Score: {d}", .{score}) catch "Score: ?";
    f.drawText(8, 6, score_str, &font8x8, WHITE);
}

/// Game field: player position + obstacles
fn renderGameField(f: *FB, player_x: u16, obstacles: []const [2]u16) void {
    f.fillRect(0, 20, W, H - 20, BLACK);
    f.fillRect(40, 20, 160, H - 20, MID_GRAY);
    f.fillRoundRect(player_x, 180, 30, 45, 5, ACCENT);
    for (obstacles) |obs| {
        f.fillRoundRect(obs[0], obs[1], 25, 35, 4, GREEN);
    }
}

/// Settings page: list of toggles/values
fn renderSettings(f: *FB, brightness: u8, volume: u8, wifi_on: bool) void {
    f.fillRect(0, 24, W, H - 24, BLACK);
    f.drawText(10, 30, "Settings", &font8x8, WHITE);
    f.drawText(10, 50, "Brightness", &font8x8, WHITE);
    f.fillRect(120, 52, 100, 6, MID_GRAY);
    f.fillRect(120, 52, @as(u16, brightness) * 100 / 255, 6, GREEN);
    f.drawText(10, 70, "Volume", &font8x8, WHITE);
    f.fillRect(120, 72, 100, 6, MID_GRAY);
    f.fillRect(120, 72, @as(u16, volume) * 100 / 255, 6, GREEN);
    f.drawText(10, 90, "WiFi", &font8x8, WHITE);
    f.fillRect(120, 92, 40, 8, if (wifi_on) GREEN else MID_GRAY);
}

// ============================================================================
// State transition measurements
// ============================================================================

var fb: FB = FB.init(BLACK);

/// Measure dirty bytes for a state transition.
/// Renders old scene, clears dirty, renders new scene, returns BwResult.
fn measure(
    name: []const u8,
    comptime renderOld: fn (*FB) void,
    comptime renderNew: fn (*FB) void,
) BwResult {
    renderOld(&fb);
    fb.clearDirty();
    renderNew(&fb);
    return BwResult.fromFb(name, &fb);
}

// --- Menu transitions ---

fn menuSelected0(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderMenuPage(f, 0, 5);
}
fn menuSelected1(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderMenuPage(f, 1, 5);
}
fn menuSelected2(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderMenuPage(f, 2, 5);
}

// --- Time update ---

fn statusTime1230(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderMenuPage(f, 0, 5);
}
fn statusTime1231(f: *FB) void {
    renderStatusBar(f, 12, 31, 80, true);
    renderMenuPage(f, 0, 5);
}

// --- Battery change ---

fn battery80(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderMenuPage(f, 0, 5);
}
fn battery75(f: *FB) void {
    renderStatusBar(f, 12, 30, 75, true);
    renderMenuPage(f, 0, 5);
}

// --- WiFi toggle ---

fn wifiOn(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderMenuPage(f, 0, 5);
}
fn wifiOff(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, false);
    renderMenuPage(f, 0, 5);
}

// --- Page switch: menu → settings ---

fn pageMenu(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderMenuPage(f, 0, 5);
}
fn pageSettings(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderSettings(f, 128, 200, true);
}

// --- Settings brightness change ---

fn settingsBright128(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderSettings(f, 128, 200, true);
}
fn settingsBright180(f: *FB) void {
    renderStatusBar(f, 12, 30, 80, true);
    renderSettings(f, 180, 200, true);
}

// --- Game: score change only ---

fn gameScore100(f: *FB) void {
    renderGameHud(f, 100);
    const obs = [_][2]u16{ .{ 80, 50 }, .{ 140, 100 }, .{ 100, 150 } };
    renderGameField(f, 110, &obs);
}
fn gameScore101(f: *FB) void {
    renderGameHud(f, 101);
    const obs = [_][2]u16{ .{ 80, 50 }, .{ 140, 100 }, .{ 100, 150 } };
    renderGameField(f, 110, &obs);
}

// --- Game: player moves ---

fn gamePlayerLeft(f: *FB) void {
    renderGameHud(f, 100);
    const obs = [_][2]u16{ .{ 80, 50 }, .{ 140, 100 }, .{ 100, 150 } };
    renderGameField(f, 110, &obs);
}
fn gamePlayerRight(f: *FB) void {
    renderGameHud(f, 100);
    const obs = [_][2]u16{ .{ 80, 50 }, .{ 140, 100 }, .{ 100, 150 } };
    renderGameField(f, 140, &obs);
}

// --- Game: obstacles scroll (every frame) ---

fn gameFrame0(f: *FB) void {
    renderGameHud(f, 100);
    const obs = [_][2]u16{ .{ 80, 50 }, .{ 140, 100 }, .{ 100, 150 } };
    renderGameField(f, 110, &obs);
}
fn gameFrame1(f: *FB) void {
    renderGameHud(f, 100);
    const obs = [_][2]u16{ .{ 80, 55 }, .{ 140, 105 }, .{ 100, 155 } };
    renderGameField(f, 110, &obs);
}

// --- Full screen clear ---

fn screenBlack(f: *FB) void {
    f.clear(BLACK);
}
fn screenWhite(f: *FB) void {
    f.clear(WHITE);
}

// ============================================================================
// Theoretical minimum (widget-level invalidation, like LVGL)
// ============================================================================

const IdealResult = struct {
    name: []const u8,
    widgets: []const Rect, // exact widget bounding boxes that changed

    fn dirtyPixels(self: IdealResult) u32 {
        var total: u32 = 0;
        for (self.widgets) |r| total += r.area();
        return total;
    }

    fn dirtyBytes(self: IdealResult) u32 {
        return self.dirtyPixels() * BPP;
    }

    fn report(self: IdealResult) void {
        const pixels = self.dirtyPixels();
        const bytes = self.dirtyBytes();
        const pct = if (TOTAL_PIXELS > 0) pixels * 10000 / TOTAL_PIXELS else 0;
        std.debug.print("  {s} (ideal):\n", .{self.name});
        std.debug.print("    dirty: {d} px, {d} bytes ({d}.{d:0>2}%)\n", .{
            pixels, bytes, pct / 100, pct % 100,
        });
        std.debug.print("    widgets: {d}\n", .{self.widgets.len});
        for (spi_speeds) |spd| {
            const bits: u64 = @as(u64, bytes) * 8;
            const time_us: u64 = if (spd.mhz > 0) bits / spd.mhz else 0;
            const max_fps: u64 = if (time_us > 0) 1_000_000 / time_us else 99999;
            std.debug.print("    @{s}: {d}us, max {d} fps\n", .{ spd.name, time_us, max_fps });
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "bandwidth: menu navigation (select next item)" {
    std.debug.print("\n=== Menu Navigation: select item 0 → 1 ===\n", .{});

    // Framebuffer approach
    const fb_result = measure("framebuffer", menuSelected0, menuSelected1);
    fb_result.report();

    // Ideal (LVGL-like): only old highlight + new highlight changed
    const ideal = IdealResult{
        .name = "select next",
        .widgets = &.{
            .{ .x = 10, .y = 30, .w = 220, .h = 38 }, // old item unhighlight
            .{ .x = 10, .y = 72, .w = 220, .h = 38 }, // new item highlight
        },
    };
    ideal.report();

    std.debug.print("    savings: {d}% fewer bytes with widget-level tracking\n", .{
        if (fb_result.dirty_bytes > 0)
            (fb_result.dirty_bytes - ideal.dirtyBytes()) * 100 / fb_result.dirty_bytes
        else
            @as(u32, 0),
    });
}

test "bandwidth: menu select skip (item 0 → 2)" {
    std.debug.print("\n=== Menu Navigation: select item 0 → 2 ===\n", .{});

    const fb_result = measure("framebuffer", menuSelected0, menuSelected2);
    fb_result.report();

    const ideal = IdealResult{
        .name = "select skip",
        .widgets = &.{
            .{ .x = 10, .y = 30, .w = 220, .h = 38 },
            .{ .x = 10, .y = 114, .w = 220, .h = 38 },
        },
    };
    ideal.report();
}

test "bandwidth: time update (12:30 → 12:31)" {
    std.debug.print("\n=== Status Bar: time update ===\n", .{});

    const fb_result = measure("framebuffer", statusTime1230, statusTime1231);
    fb_result.report();

    // Ideal: only the time label region
    const ideal = IdealResult{
        .name = "time update",
        .widgets = &.{
            .{ .x = 8, .y = 8, .w = 40, .h = 8 }, // "12:31" text area
        },
    };
    ideal.report();
}

test "bandwidth: battery change (80% → 75%)" {
    std.debug.print("\n=== Status Bar: battery update ===\n", .{});

    const fb_result = measure("framebuffer", battery80, battery75);
    fb_result.report();

    // Ideal: only battery bar
    const ideal = IdealResult{
        .name = "battery update",
        .widgets = &.{
            .{ .x = W - 40, .y = 8, .w = 30, .h = 8 },
        },
    };
    ideal.report();
}

test "bandwidth: wifi toggle" {
    std.debug.print("\n=== Status Bar: wifi toggle ===\n", .{});

    const fb_result = measure("framebuffer", wifiOn, wifiOff);
    fb_result.report();

    // Ideal: only wifi indicator dot
    const ideal = IdealResult{
        .name = "wifi toggle",
        .widgets = &.{
            .{ .x = W - 50, .y = 10, .w = 4, .h = 4 },
        },
    };
    ideal.report();
}

test "bandwidth: page switch (menu → settings)" {
    std.debug.print("\n=== Page Switch: menu → settings ===\n", .{});

    const fb_result = measure("framebuffer", pageMenu, pageSettings);
    fb_result.report();

    // Ideal: entire content area changes (status bar stays)
    const ideal = IdealResult{
        .name = "page switch",
        .widgets = &.{
            .{ .x = 0, .y = 24, .w = W, .h = H - 24 },
        },
    };
    ideal.report();
}

test "bandwidth: settings brightness change" {
    std.debug.print("\n=== Settings: brightness slider ===\n", .{});

    const fb_result = measure("framebuffer", settingsBright128, settingsBright180);
    fb_result.report();

    // Ideal: only the brightness bar
    const ideal = IdealResult{
        .name = "brightness",
        .widgets = &.{
            .{ .x = 120, .y = 52, .w = 100, .h = 6 },
        },
    };
    ideal.report();
}

test "bandwidth: game score increment" {
    std.debug.print("\n=== Game: score 100 → 101 ===\n", .{});

    const fb_result = measure("framebuffer", gameScore100, gameScore101);
    fb_result.report();

    // Ideal: only HUD score label
    const ideal = IdealResult{
        .name = "score update",
        .widgets = &.{
            .{ .x = 8, .y = 6, .w = 88, .h = 8 }, // "Score: 101"
        },
    };
    ideal.report();
}

test "bandwidth: game player move" {
    std.debug.print("\n=== Game: player move left → right ===\n", .{});

    const fb_result = measure("framebuffer", gamePlayerLeft, gamePlayerRight);
    fb_result.report();

    // Ideal: old player rect + new player rect
    const ideal = IdealResult{
        .name = "player move",
        .widgets = &.{
            .{ .x = 110, .y = 180, .w = 30, .h = 45 }, // old position
            .{ .x = 140, .y = 180, .w = 30, .h = 45 }, // new position
        },
    };
    ideal.report();
}

test "bandwidth: game frame scroll (obstacles move)" {
    std.debug.print("\n=== Game: obstacle scroll (per frame) ===\n", .{});

    const fb_result = measure("framebuffer", gameFrame0, gameFrame1);
    fb_result.report();

    // Ideal: each obstacle old+new position (3 obstacles × 2)
    const ideal = IdealResult{
        .name = "obstacle scroll",
        .widgets = &.{
            .{ .x = 80, .y = 50, .w = 25, .h = 40 }, // obs0 old+new merged
            .{ .x = 140, .y = 100, .w = 25, .h = 40 }, // obs1
            .{ .x = 100, .y = 150, .w = 25, .h = 40 }, // obs2
        },
    };
    ideal.report();
}

test "bandwidth: full screen transition (black → white)" {
    std.debug.print("\n=== Full Screen: black → white ===\n", .{});

    const fb_result = measure("framebuffer", screenBlack, screenWhite);
    fb_result.report();

    // No savings possible — entire screen changed
    const ideal = IdealResult{
        .name = "full screen",
        .widgets = &.{
            .{ .x = 0, .y = 0, .w = W, .h = H },
        },
    };
    ideal.report();
}

test "bandwidth: summary table" {
    std.debug.print(
        \\
        \\=== Bandwidth Summary (240x240 RGB565, full screen = 115,200 bytes) ===
        \\
        \\  State Change          | FB Approach        | LVGL Ideal         | Savings
        \\  ----------------------|--------------------|--------------------|--------
        \\  Menu: select next     | 2 items redrawn    | 2 widget rects     | ~50%+
        \\  Status: time update   | status bar redrawn | 1 label rect       | ~90%+
        \\  Status: battery       | status bar redrawn | 1 bar rect         | ~95%+
        \\  Status: wifi toggle   | status bar redrawn | 1 dot (4x4 px)     | ~99%+
        \\  Page switch           | full content area  | full content area  | ~0%
        \\  Settings: slider      | full content area  | 1 bar rect         | ~95%+
        \\  Game: score update    | full HUD redrawn   | 1 label rect       | ~90%+
        \\  Game: player move     | game field redrawn | 2 car rects        | ~90%+
        \\  Game: obstacle scroll | game field redrawn | 3 obs rects        | ~80%+
        \\  Full screen clear     | 115,200 bytes      | 115,200 bytes      | 0%
        \\
        \\  Key takeaway:
        \\    Framebuffer immediate-mode redraws entire scene → DirtyTracker
        \\    marks large merged regions → high transfer bytes.
        \\
        \\    LVGL retained-mode only invalidates changed widgets → minimal
        \\    transfer bytes for sparse UI updates (status bar, sliders, labels).
        \\
        \\    For games (frequent full-area changes), both approaches transfer
        \\    similar amounts. For system UI (rare sparse changes), LVGL can
        \\    reduce SPI bandwidth by 80-99%.
        \\
    , .{});
}
