//! H106 UI — 1:1 LVGL Layout Replica
//!
//! Page state machine with pixel-accurate layout matching LVGL version.
//! Assets loaded at runtime via VFS. Pure logic + rendering.

const state_lib = @import("ui_state");
const assets_mod = @import("assets.zig");
const tetris = @import("tetris.zig");
const racer = @import("racer.zig");

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;
pub const FB = state_lib.Framebuffer(SCREEN_W, SCREEN_H, .rgb565);
const Image = state_lib.Image;

// Colors (from theme.zig: globals_tiga.theme)
pub const BLACK: u16 = 0x0000;
pub const WHITE: u16 = 0xFFFF;
pub const GRAY: u16 = 0x4208;
pub const DIM_WHITE: u16 = 0x7BEF; // opa=125/255 white on black ≈ 0x7BEF

// ============================================================================
// Runtime Assets
// ============================================================================

var startup_player: ?state_lib.AnimPlayer = null;
var startup_frame_timer: u32 = 0;
var bg_img: ?Image = null;
var ultraman_img: ?Image = null;
var menu_imgs: [5]?Image = [_]?Image{null} ** 5;
var btn_list_img: ?Image = null;
var game_icons: [4]?Image = [_]?Image{null} ** 4;
var setting_icons: [9]?Image = [_]?Image{null} ** 9;
var font_24: ?state_lib.TtfFont = null;
var font_20: ?state_lib.TtfFont = null;
var font_16: ?state_lib.TtfFont = null;

/// Initialize startup animation from .anim file data (zero-copy)
pub fn initStartupAnim(anim_data: ?[]const u8) void {
    if (anim_data) |data| {
        startup_player = state_lib.AnimPlayer.init(data);
    }
}

pub fn initAssets(
    bg: Image, ultraman: ?Image, menus: [5]?Image,
    btn_list: ?Image, g_icons: [4]?Image, s_icons: [9]?Image,
    ttf_data: ?[]const u8,
) void {
    bg_img = bg;
    ultraman_img = ultraman;
    menu_imgs = menus;
    btn_list_img = btn_list;
    game_icons = g_icons;
    setting_icons = s_icons;
    if (ttf_data) |d| {
        font_24 = state_lib.TtfFont.init(d, 24.0);
        font_20 = state_lib.TtfFont.init(d, 20.0);
        font_16 = state_lib.TtfFont.init(d, 16.0);
    }
}

// ============================================================================
// State
// ============================================================================

pub const Page = enum { off, startup, desktop, menu, game_list, game_tetris, game_racer, settings, shutting_down };

pub const Transition = struct {
    from: Page, to: Page, start_tick: u32, duration: u32, direction: Dir,
    pub const Dir = enum { left, right };
};

pub const AppState = struct {
    page: Page = .startup,
    power_hold_ticks: u16 = 0, // power button hold counter
    shutdown_tick: u32 = 0, // tick when shutdown animation started
    transition: ?Transition = null,
    tick: u32 = 0,
    menu_index: u8 = 0,
    game_index: u8 = 0,
    settings_index: u8 = 0,
    settings_scroll: u16 = 0, // scroll offset for settings list
    tetris: tetris.GameState = .{},
    racer: racer.GameState = .{},
};

pub const AppEvent = union(enum) { tick, left, right, up, down, confirm, back, power_hold, power_release };
pub const Store = state_lib.Store(AppState, AppEvent);

// ============================================================================
// Reducer
// ============================================================================

const POWER_HOLD_THRESHOLD: u16 = 180; // ~3s at 60fps
const SHUTDOWN_DURATION: u32 = 36; // ~600ms at 60fps

pub fn reduce(state: *AppState, event: AppEvent) void {
    state.tick += 1;

    // Power hold tracking (works on any page except off)
    if (state.page != .off and state.page != .shutting_down and state.page != .startup) {
        switch (event) {
            .power_hold => {
                state.power_hold_ticks += 1;
                if (state.power_hold_ticks >= POWER_HOLD_THRESHOLD) {
                    state.page = .shutting_down;
                    state.shutdown_tick = state.tick;
                    state.power_hold_ticks = 0;
                }
                return;
            },
            .power_release => { state.power_hold_ticks = 0; return; },
            else => {},
        }
    }

    // Off state: long press to boot
    if (state.page == .off) {
        switch (event) {
            .power_hold => {
                state.power_hold_ticks += 1;
                if (state.power_hold_ticks >= POWER_HOLD_THRESHOLD) {
                    state.page = .startup;
                    state.power_hold_ticks = 0;
                    if (startup_player) |*p| p.reset();
                    startup_frame_timer = 0;
                }
            },
            .power_release => state.power_hold_ticks = 0,
            else => {},
        }
        return;
    }

    // Shutdown animation
    if (state.page == .shutting_down) {
        if (state.tick >= state.shutdown_tick + SHUTDOWN_DURATION) {
            state.page = .off;
        }
        return;
    }

    if (state.transition) |t| {
        if (state.tick >= t.start_tick + t.duration) { state.page = t.to; state.transition = null; }
        if (event == .tick) {
            if (state.page == .game_tetris) tetris.reduce(&state.tetris, .tick);
            if (state.page == .game_racer) racer.reduce(&state.racer, .tick);
        }
        return;
    }
    switch (state.page) {
        .startup => switch (event) {
            .tick => {
                if (startup_player != null and startup_player.?.isDone()) {
                    state.page = .desktop;
                }
            },
            .confirm, .back => state.page = .desktop,
            else => {},
        },
        .desktop => switch (event) { .right, .confirm => nav(state, .menu, .left), else => {} },
        .menu => switch (event) {
            .left => if (state.menu_index > 0) { state.menu_index -= 1; } else nav(state, .desktop, .right),
            .right => if (state.menu_index < 4) { state.menu_index += 1; },
            .confirm => switch (state.menu_index) {
                1 => nav(state, .game_list, .left), 4 => nav(state, .settings, .left), else => {}
            },
            .back => nav(state, .desktop, .right), else => {},
        },
        .game_list => switch (event) {
            .up, .left => if (state.game_index > 0) { state.game_index -= 1; },
            .down, .right => if (state.game_index < 3) { state.game_index += 1; },
            .confirm => switch (state.game_index) {
                0 => { state.tetris = .{}; nav(state, .game_tetris, .left); },
                1 => { state.racer = .{}; nav(state, .game_racer, .left); },
                else => {},
            },
            .back => nav(state, .menu, .right), else => {},
        },
        .settings => switch (event) {
            .up, .left => if (state.settings_index > 0) { state.settings_index -= 1; updateSettingsScroll(state); },
            .down, .right => if (state.settings_index < 8) { state.settings_index += 1; updateSettingsScroll(state); },
            .back => nav(state, .menu, .right), else => {},
        },
        .game_tetris => switch (event) {
            .back => nav(state, .game_list, .right),
            .left => tetris.reduce(&state.tetris, .move_left),
            .right => tetris.reduce(&state.tetris, .move_right),
            .confirm => tetris.reduce(&state.tetris, .rotate),
            .up => tetris.reduce(&state.tetris, .hard_drop),
            .down => tetris.reduce(&state.tetris, .soft_drop),
            .tick => tetris.reduce(&state.tetris, .tick),
            .power_hold, .power_release => {},
        },
        .game_racer => switch (event) {
            .back => nav(state, .game_list, .right),
            .left => racer.reduce(&state.racer, .move_left),
            .right => racer.reduce(&state.racer, .move_right),
            .tick => racer.reduce(&state.racer, .tick),
            else => {},
        },
        .off, .shutting_down => {}, // handled above (early return)
    }
}

fn nav(state: *AppState, to: Page, dir: Transition.Dir) void {
    state.transition = .{ .from = state.page, .to = to, .start_tick = state.tick, .duration = 12, .direction = dir };
}

fn updateSettingsScroll(state: *AppState) void {
    // Each item 55+4=59px. Visible ~4 items. Scroll to keep selected visible.
    const item_h: u16 = 59;
    const visible_h: u16 = SCREEN_H - 8; // padTop=8
    const selected_top = @as(u16, state.settings_index) * item_h;
    const selected_bottom = selected_top + 55;
    if (selected_bottom > state.settings_scroll + visible_h) {
        state.settings_scroll = selected_bottom - visible_h;
    }
    if (selected_top < state.settings_scroll) {
        state.settings_scroll = selected_top;
    }
}

// ============================================================================
// Render
// ============================================================================

pub fn render(fb: *FB, state: *const AppState) void {
    if (state.transition) |t| {
        const elapsed = state.tick -| t.start_tick;
        const p = @min(@as(u32, 256), elapsed * 256 / t.duration);
        const e = easeOut(@intCast(p));
        const off: i16 = @intCast(@as(u32, SCREEN_W) * e / 256);
        switch (t.direction) {
            .left => { renderPage(fb, state, t.from, -off); renderPage(fb, state, t.to, @intCast(@as(i16, SCREEN_W) - off)); },
            .right => { renderPage(fb, state, t.from, off); renderPage(fb, state, t.to, -(@as(i16, SCREEN_W) - off)); },
        }
    } else renderPage(fb, state, state.page, 0);
}

fn renderPage(fb: *FB, state: *const AppState, page: Page, xo: i16) void {
    switch (page) {
        .off => fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK),
        .startup => renderStartup(fb),
        .shutting_down => renderShutdown(fb, state),
        .desktop => renderDesktop(fb, xo),
        .menu => renderMenu(fb, state, xo),
        .game_list => renderGameList(fb, state, xo),
        .settings => renderSettings(fb, state, xo),
        .game_tetris => if (xo == 0) { const e = tetris.GameState{}; tetris.render(fb, &state.tetris, &e); } else fillOff(fb, xo, BLACK),
        .game_racer => if (xo == 0) { const e = racer.GameState{}; racer.render(fb, &state.racer, &e); } else fillOff(fb, xo, BLACK),
    }
}

fn renderStartup(fb: *FB) void {
    if (startup_player) |*player| {
        // Advance frame based on frame timer
        // We advance one animation frame per (60/fps) ticks
        const ticks_per_frame = @max(1, 60 / @as(u32, @max(1, player.header.fps)));
        startup_frame_timer += 1;
        if (startup_frame_timer >= ticks_per_frame) {
            startup_frame_timer = 0;
            if (player.nextFrame()) |frame| {
                state_lib.blitAnimFrame(SCREEN_W, SCREEN_H, .rgb565, fb, frame, player.header.scale);
            }
        }
    } else {
        // No animation — show black
        fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);
    }
}

fn renderShutdown(fb: *FB, state: *const AppState) void {
    // Shutdown animation: white rectangle shrinks to center, fades out
    // Timeline (matching LVGL power_anim.c):
    //   0-370ms: height 240→0 (ease-in)    = 0-22 ticks
    //   260-520ms: opacity 255→0 (ease-out) = 16-31 ticks
    //   370-600ms: width 240→0 (ease-out)   = 22-36 ticks
    fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);

    const elapsed = state.tick -| state.shutdown_tick;
    const total: u32 = SHUTDOWN_DURATION;

    // Phase 1: height shrinks (first 60%)
    const h_progress = @min(@as(u32, 256), elapsed * 256 * 100 / (total * 62));
    const h_ease = easeIn(@intCast(@min(h_progress, 256)));
    const rect_h: u16 = @intCast(@as(u32, SCREEN_H) * (256 - h_ease) / 256);

    // Phase 2: width shrinks (last 40%)
    var rect_w: u16 = SCREEN_W;
    if (elapsed > total * 62 / 100) {
        const w_elapsed = elapsed - total * 62 / 100;
        const w_progress = @min(@as(u32, 256), w_elapsed * 256 * 100 / (total * 38));
        const w_ease = easeOut(@intCast(@min(w_progress, 256)));
        rect_w = @intCast(@as(u32, SCREEN_W) * (256 - w_ease) / 256);
    }

    // Phase 3: opacity fades (middle 43%)
    var alpha: u8 = 255;
    if (elapsed > total * 43 / 100) {
        const a_elapsed = elapsed - total * 43 / 100;
        const a_progress = @min(@as(u32, 256), a_elapsed * 256 * 100 / (total * 43));
        const a_ease = easeOut(@intCast(@min(a_progress, 256)));
        alpha = @intCast(255 - (255 * a_ease / 256));
    }

    if (rect_w > 0 and rect_h > 0 and alpha > 0) {
        const rx = (SCREEN_W - rect_w) / 2;
        const ry = (SCREEN_H - rect_h) / 2;
        // Blend white rectangle
        if (alpha >= 250) {
            fb.fillRect(rx, ry, rect_w, rect_h, WHITE);
        } else {
            // Alpha blend white on black = just scale white
            const gray565: u16 = @as(u16, @as(u5, @intCast(@as(u32, alpha) * 31 / 255)));
            const green: u16 = @as(u16, @as(u6, @intCast(@as(u32, alpha) * 63 / 255)));
            const color: u16 = (gray565 << 11) | (green << 5) | gray565;
            fb.fillRect(rx, ry, rect_w, rect_h, color);
        }
    }
}

/// Ease-in quadratic: t^2
fn easeIn(t: u16) u16 {
    const tv: u32 = t;
    return @intCast(tv * tv / 256);
}

fn renderDesktop(fb: *FB, xo: i16) void {
    if (xo == 0) {
        // bg → ultraman → header (layered)
        if (bg_img) |img| fb.blit(0, 0, img);
        if (ultraman_img) |img| fb.blit(0, 0, img);
        renderHeader(fb);
    } else blitBgOff(fb, xo);
}

fn renderMenu(fb: *FB, state: *const AppState, xo: i16) void {
    blitBgOff(fb, xo);
    if (xo != 0) return;

    // Menu icon: centered in 240x200 container at y=10, icon center y_off=-10
    // → icon at x=(240-160)/2=40, y=10+(200-160)/2-10=20
    if (menu_imgs[state.menu_index]) |img| fb.blit(40, 20, img);

    // Title label: align=bottom_mid, y=-35 → y=240-35-24=181 (approx with font height)
    if (font_24) |*f| {
        const label = assets_mod.MENU_LABELS[state.menu_index];
        const tw = f.textWidth(label);
        fb.drawTextTtf((SCREEN_W -| tw) / 2, 181, label, f, WHITE);
    }

    // Dot indicators: 240x16 row at y=240-8-16=216, padColumn=10
    // Active: 24x12 radius=6, opa=255. Inactive: 12x12 radius=6, opa=125
    const dot_row_y: u16 = 216;
    // Total width: calculate based on current selection
    var total_w: u16 = 0;
    for (0..5) |i| { total_w += if (i == state.menu_index) @as(u16, 24) else @as(u16, 12); }
    total_w += 4 * 10; // 4 gaps of padColumn=10
    var dx: u16 = (SCREEN_W - total_w) / 2;
    for (0..5) |i| {
        const active = (i == state.menu_index);
        const w: u16 = if (active) 24 else 12;
        const h: u16 = 12;
        const color: u16 = if (active) WHITE else DIM_WHITE;
        fb.fillRoundRect(dx, dot_row_y + 2, w, h, 6, color);
        dx += w + 10;
    }

    renderHeader(fb);
}

fn renderGameList(fb: *FB, state: *const AppState, xo: i16) void {
    blitBgOff(fb, xo);
    if (xo != 0) return;

    // List: 224x240, center, padRow=4, padTop=20, flexMain=center
    // 4 items × (55+4) = 236px. Center vertically: top ≈ 20
    const list_x: u16 = (SCREEN_W - 224) / 2; // = 8
    const list_top: u16 = 20;

    for (0..4) |i| {
        const y = list_top + @as(u16, @intCast(i)) * 59;
        const selected = (i == state.game_index);

        if (selected) {
            // Selected: btn_list_item.png background (224x56)
            if (btn_list_img) |img| fb.blit(list_x, y, img);
        } else {
            // Unselected: black bg with radius=4
            fb.fillRoundRect(list_x, y, 224, 55, 4, BLACK);
        }

        // Icon (32x32): padLeft=16, vertically centered in 55px item
        const icon_x = list_x + 16;
        const icon_y = y + (55 - 32) / 2;
        if (game_icons[i]) |icon| fb.blit(icon_x, icon_y, icon);

        // Label: padColumn=12 from icon, font_24
        if (font_24) |*f| {
            const label_x = icon_x + 32 + 12;
            fb.drawTextTtf(label_x, y + 14, assets_mod.GAME_LABELS[i], f, WHITE);
        }
    }
}

fn renderSettings(fb: *FB, state: *const AppState, xo: i16) void {
    blitBgOff(fb, xo);
    if (xo != 0) return;

    // List: 224x240, center, padRow=4, padTop=8
    const list_x: u16 = (SCREEN_W - 224) / 2;
    const base_y: i32 = 8 - @as(i32, state.settings_scroll);

    for (0..9) |i| {
        const iy: i32 = base_y + @as(i32, @intCast(i)) * 59;
        if (iy + 55 < 0 or iy >= SCREEN_H) continue; // off screen
        const y: u16 = if (iy < 0) 0 else @intCast(iy);
        const selected = (i == state.settings_index);

        if (selected) {
            if (btn_list_img) |img| fb.blit(list_x, y, img);
        } else {
            fb.fillRoundRect(list_x, y, 224, 55, 4, BLACK);
        }

        // Icon: padLeft=16, padColumn=16
        const icon_x = list_x + 16;
        const icon_y = y + (55 - 32) / 2;
        if (setting_icons[i]) |icon| fb.blit(icon_x, icon_y, icon);

        // Label: font_20
        if (font_20) |*f| {
            const label_x = icon_x + 32 + 16;
            fb.drawTextTtf(label_x, y + 16, assets_mod.SETTING_LABELS[i], f, WHITE);
        }
    }
}

fn renderHeader(fb: *FB) void {
    // 240x54, padLeft=16, padRight=16, padTop=16, flex row space-between
    // Time left, WiFi+Battery right
    if (font_16) |*f| {
        fb.drawTextTtf(16, 16, "12:00", f, WHITE);
        // WiFi + battery symbols (simple rectangles as placeholders)
        // Real version uses FontAwesome glyphs — we draw simple icons
        drawWifiIcon(fb, 200, 18);
        drawBatteryIcon(fb, 218, 18);
    }
}

fn drawWifiIcon(fb: *FB, x: u16, y: u16) void {
    // Simple WiFi arc approximation
    fb.fillRect(x + 4, y + 8, 3, 3, WHITE); // dot
    fb.hline(x + 2, y + 5, 7, WHITE); // arc 1
    fb.hline(x, y + 2, 11, WHITE); // arc 2
}

fn drawBatteryIcon(fb: *FB, x: u16, y: u16) void {
    fb.drawRect(x, y + 2, 14, 8, WHITE, 1);
    fb.fillRect(x + 14, y + 4, 2, 4, WHITE); // terminal
    fb.fillRect(x + 2, y + 4, 8, 4, WHITE); // charge level
}

// ============================================================================
// Helpers
// ============================================================================

fn easeOut(t: u16) u16 {
    const inv: u32 = 256 - t;
    return @intCast(256 - (inv * inv / 256));
}

fn blitBgOff(fb: *FB, xo: i16) void {
    if (bg_img) |img| {
        if (xo == 0) { fb.blit(0, 0, img); }
        else if (xo > 0 and xo < SCREEN_W) {
            fb.fillRect(0, 0, @intCast(xo), SCREEN_H, BLACK);
            fb.blit(@intCast(xo), 0, img);
        } else if (xo < 0 and xo > -@as(i16, SCREEN_W)) {
            fb.blit(0, 0, img);
            const gx: u16 = @intCast(@as(i16, SCREEN_W) + xo);
            fb.fillRect(gx, 0, @intCast(-xo), SCREEN_H, BLACK);
        }
    } else fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);
}

fn fillOff(fb: *FB, xo: i16, color: u16) void {
    if (xo >= 0 and xo < SCREEN_W) fb.fillRect(@intCast(xo), 0, SCREEN_W -| @as(u16, @intCast(xo)), SCREEN_H, color)
    else if (xo < 0 and xo > -@as(i16, SCREEN_W)) fb.fillRect(0, 0, @intCast(@as(i16, SCREEN_W) + xo), SCREEN_H, color);
}

// Simple 5x7 text fallback (kept for non-TTF testing)
pub fn drawTextSimple(fb: *FB, x: u16, y: u16, text: []const u8, color: u16) void {
    _ = fb; _ = x; _ = y; _ = text; _ = color;
}
