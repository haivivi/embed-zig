//! H106 UI — Redux State Machine (pure functions, zero global mutable state)
//!
//! All mutable state lives in AppState. Reducer is the only state modifier.
//! Render is a pure function: f(state, resources) → pixels.
//! Resources (images, fonts, animation data) are immutable after init.

const state_lib = @import("ui_state");
const assets_mod = @import("assets.zig");
const tetris = @import("tetris.zig");
const racer = @import("racer.zig");

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;
pub const FB = state_lib.Framebuffer(SCREEN_W, SCREEN_H, .rgb565);
const Image = state_lib.Image;

pub const BLACK: u16 = 0x0000;
pub const WHITE: u16 = 0xFFFF;
pub const DIM_WHITE: u16 = 0x7BEF;

// ============================================================================
// Resources — immutable after init, passed explicitly to render
// ============================================================================

pub const Resources = struct {
    bg: ?Image = null,
    ultraman: ?Image = null,
    menu_icons: [5]?Image = [_]?Image{null} ** 5,
    btn_list: ?Image = null,
    game_icons: [4]?Image = [_]?Image{null} ** 4,
    setting_icons: [9]?Image = [_]?Image{null} ** 9,
    icon_haivivi: ?Image = null,
    intro_setting: ?Image = null,
    intro_list: ?Image = null,
    intro_device: ?Image = null,
    intro_arrow: ?Image = null,
    font_24: ?*state_lib.TtfFont = null,
    font_20: ?*state_lib.TtfFont = null,
    font_16: ?*state_lib.TtfFont = null,
    anim_player: ?*state_lib.AnimPlayer = null,
};

// ============================================================================
// State — ALL mutable state lives here
// ============================================================================

pub const Page = enum { off, startup, intro, desktop, menu, game_list, game_tetris, game_racer, settings, settings_lcd, settings_info, settings_reset, contact, points, shutting_down };

pub const Transition = struct {
    from: Page, to: Page, start_tick: u32, duration: u32, direction: Dir,
    pub const Dir = enum { left, right };
};

const POWER_HOLD_THRESHOLD: u16 = 180;
const SHUTDOWN_DURATION: u32 = 36;

pub const AppState = struct {
    page: Page = .startup,
    transition: ?Transition = null,
    tick: u32 = 0,
    menu_index: u8 = 0,
    game_index: u8 = 0,
    settings_index: u8 = 0,
    settings_scroll: u16 = 0,
    power_hold_ticks: u16 = 0,
    shutdown_tick: u32 = 0,

    // Animation
    anim_frame_index: u16 = 0,
    anim_frame_timer: u16 = 0,
    anim_done: bool = false,

    // Intro (first boot guide)
    intro_index: u8 = 0,
    is_first_boot: bool = true,

    // Settings sub-pages
    lcd_brightness: u8 = 55, // 10, 55, 85, 100

    // Contact
    device_bound: bool = false,

    // Points
    points_value: u32 = 0,

    // Sub-page states
    tetris: tetris.GameState = .{},
    racer: racer.GameState = .{},
};

pub const AppEvent = union(enum) { tick, left, right, up, down, confirm, back, power_hold, power_release };
pub const Store = state_lib.Store(AppState, AppEvent);

// ============================================================================
// Reducer — ONLY place that modifies state
// ============================================================================

pub fn reduce(state: *AppState, event: AppEvent) void {
    state.tick += 1;

    // Power hold (any page except off/shutting_down/startup)
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

    // Off: long press to boot
    if (state.page == .off) {
        switch (event) {
            .power_hold => {
                state.power_hold_ticks += 1;
                if (state.power_hold_ticks >= POWER_HOLD_THRESHOLD) {
                    state.page = .startup;
                    state.power_hold_ticks = 0;
                    state.anim_frame_index = 0;
                    state.anim_frame_timer = 0;
                    state.anim_done = false;
                }
            },
            .power_release => state.power_hold_ticks = 0,
            else => {},
        }
        return;
    }

    // Shutdown animation
    if (state.page == .shutting_down) {
        if (state.tick >= state.shutdown_tick + SHUTDOWN_DURATION) state.page = .off;
        return;
    }

    // Transition
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
                if (!state.anim_done) {
                    state.anim_frame_timer += 1;
                    if (state.anim_frame_timer >= 2) {
                        state.anim_frame_timer = 0;
                        state.anim_frame_index += 1;
                    }
                }
                if (state.anim_done) {
                    if (state.is_first_boot) { state.page = .intro; state.intro_index = 0; }
                    else state.page = .desktop;
                }
            },
            .confirm, .back => {
                state.anim_done = true;
                if (state.is_first_boot) { state.page = .intro; state.intro_index = 0; }
                else state.page = .desktop;
            },
            else => {},
        },
        .intro => switch (event) {
            .right => if (state.intro_index < 2) { state.intro_index += 1; },
            .left => if (state.intro_index > 0) { state.intro_index -= 1; },
            .confirm => {
                if (state.intro_index == 2) {
                    state.is_first_boot = false;
                    nav(state, .desktop, .left);
                } else {
                    state.intro_index += 1;
                }
            },
            .back => {
                state.is_first_boot = false;
                nav(state, .desktop, .left);
            },
            else => {},
        },
        .desktop => switch (event) { .right, .confirm => nav(state, .menu, .left), else => {} },
        .menu => switch (event) {
            .left => if (state.menu_index > 0) { state.menu_index -= 1; } else nav(state, .desktop, .right),
            .right => if (state.menu_index < 4) { state.menu_index += 1; },
            .confirm => switch (state.menu_index) {
                0 => {}, // Team — TODO
                1 => nav(state, .game_list, .left),
                2 => nav(state, .contact, .left),
                3 => nav(state, .points, .left),
                4 => nav(state, .settings, .left),
                else => {},
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
            .up, .left => if (state.settings_index > 0) { state.settings_index -= 1; updateScroll(state); },
            .down, .right => if (state.settings_index < 8) { state.settings_index += 1; updateScroll(state); },
            .confirm => switch (state.settings_index) {
                0 => nav(state, .settings_lcd, .left),   // 屏幕亮度
                3 => nav(state, .settings_reset, .left),  // 重置设备
                4 => nav(state, .settings_info, .left),   // 设备信息
                else => {},
            },
            .back => nav(state, .menu, .right), else => {},
        },
        .settings_lcd => switch (event) {
            .left, .down => {
                state.lcd_brightness = switch (state.lcd_brightness) {
                    100 => 85, 85 => 55, else => 10,
                };
            },
            .right, .up => {
                state.lcd_brightness = switch (state.lcd_brightness) {
                    10 => 55, 55 => 85, else => 100,
                };
            },
            .back => nav(state, .settings, .right), else => {},
        },
        .settings_info => switch (event) { .back => nav(state, .settings, .right), else => {} },
        .settings_reset => switch (event) {
            .confirm => {
                // Reset device — go back to startup
                state.is_first_boot = true;
                state.page = .startup;
                state.anim_frame_index = 0;
                state.anim_frame_timer = 0;
                state.anim_done = false;
            },
            .back => nav(state, .settings, .right), else => {},
        },
        .contact => switch (event) { .back => nav(state, .menu, .right), else => {} },
        .points => switch (event) { .back => nav(state, .menu, .right), else => {} },
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
        .off, .shutting_down => {},
    }
}

fn nav(state: *AppState, to: Page, dir: Transition.Dir) void {
    state.transition = .{ .from = state.page, .to = to, .start_tick = state.tick, .duration = 12, .direction = dir };
}

fn updateScroll(state: *AppState) void {
    const item_h: u16 = 59;
    const visible_h: u16 = SCREEN_H - 54;
    const top = @as(u16, state.settings_index) * item_h;
    const bottom = top + 55;
    if (bottom > state.settings_scroll + visible_h) state.settings_scroll = bottom - visible_h;
    if (top < state.settings_scroll) state.settings_scroll = top;
}

// ============================================================================
// Render — PURE FUNCTION of (state, resources) → pixels
// No side effects. No global mutable state. No mutation of anything.
// ============================================================================

pub fn render(fb: *FB, state: *const AppState, res: *const Resources) void {
    if (state.transition) |t| {
        const elapsed = state.tick -| t.start_tick;
        const p = @min(@as(u32, 256), elapsed * 256 / t.duration);
        const e = easeOut(@intCast(p));
        const off: i16 = @intCast(@as(u32, SCREEN_W) * e / 256);
        switch (t.direction) {
            .left => { renderPage(fb, state, res, t.from, -off); renderPage(fb, state, res, t.to, @intCast(@as(i16, SCREEN_W) - off)); },
            .right => { renderPage(fb, state, res, t.from, off); renderPage(fb, state, res, t.to, -(@as(i16, SCREEN_W) - off)); },
        }
    } else renderPage(fb, state, res, state.page, 0);
}

fn renderPage(fb: *FB, state: *const AppState, res: *const Resources, page: Page, xo: i16) void {
    switch (page) {
        .off => fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK),
        .startup => renderStartup(fb, state, res),
        .shutting_down => renderShutdown(fb, state),
        .intro => renderIntro(fb, state, res, xo),
        .desktop => renderDesktop(fb, res, xo),
        .menu => renderMenu(fb, state, res, xo),
        .game_list => renderGameList(fb, state, res, xo),
        .settings => renderSettings(fb, state, res, xo),
        .settings_lcd => renderSettingsLcd(fb, state, res, xo),
        .settings_info => renderSettingsInfo(fb, res, xo),
        .settings_reset => renderSettingsReset(fb, res, xo),
        .contact => renderContact(fb, state, res, xo),
        .points => renderPoints(fb, state, res, xo),
        .game_tetris => if (xo == 0) { const e = tetris.GameState{}; tetris.render(fb, &state.tetris, &e); } else fillOff(fb, xo, BLACK),
        .game_racer => if (xo == 0) { const e = racer.GameState{}; racer.render(fb, &state.racer, &e); } else fillOff(fb, xo, BLACK),
    }
}

fn renderStartup(fb: *FB, state: *const AppState, res: *const Resources) void {
    // Pure: reads state.anim_frame_index, does NOT modify anything
    if (res.anim_player) |player| {
        // Seek to the frame indicated by state
        var p = player.*;
        p.reset();
        var last_frame: ?state_lib.AnimFrame = null;
        var i: u16 = 0;
        while (i <= state.anim_frame_index and !p.isDone()) : (i += 1) {
            if (p.nextFrame()) |frame| {
                last_frame = frame;
                // Blit each frame as we go (accumulates on framebuffer)
                state_lib.blitAnimFrame(SCREEN_W, SCREEN_H, .rgb565, fb, frame, p.header.scale);
            }
        }
    } else {
        fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);
    }
}

fn renderShutdown(fb: *FB, state: *const AppState) void {
    fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);
    const elapsed = state.tick -| state.shutdown_tick;
    const total: u32 = SHUTDOWN_DURATION;
    const h_progress = @min(@as(u32, 256), elapsed * 256 * 100 / (total * 62));
    const h_ease = easeIn(@intCast(@min(h_progress, 256)));
    const rect_h: u16 = @intCast(@as(u32, SCREEN_H) * (256 - h_ease) / 256);
    var rect_w: u16 = SCREEN_W;
    if (elapsed > total * 62 / 100) {
        const w_elapsed = elapsed - total * 62 / 100;
        const w_progress = @min(@as(u32, 256), w_elapsed * 256 * 100 / (total * 38));
        const w_ease = easeOut(@intCast(@min(w_progress, 256)));
        rect_w = @intCast(@as(u32, SCREEN_W) * (256 - w_ease) / 256);
    }
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
        if (alpha >= 250) {
            fb.fillRect(rx, ry, rect_w, rect_h, WHITE);
        } else {
            const g565: u16 = @as(u16, @as(u5, @intCast(@as(u32, alpha) * 31 / 255)));
            const green: u16 = @as(u16, @as(u6, @intCast(@as(u32, alpha) * 63 / 255)));
            fb.fillRect(rx, ry, rect_w, rect_h, (g565 << 11) | (green << 5) | g565);
        }
    }
}

fn renderDesktop(fb: *FB, res: *const Resources, xo: i16) void {
    if (xo == 0) {
        if (res.bg) |img| fb.blit(0, 0, img);
        if (res.ultraman) |img| fb.blit(0, 0, img);
        renderHeader(fb, res);
    } else blitBgOff(fb, res, xo);
}

fn renderMenu(fb: *FB, state: *const AppState, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    if (res.menu_icons[state.menu_index]) |img| fb.blit(40, 20, img);
    if (res.font_24) |f| {
        const label = assets_mod.MENU_LABELS[state.menu_index];
        const tw = f.textWidth(label);
        fb.drawTextTtf((SCREEN_W -| tw) / 2, 181, label, f, WHITE);
    }
    // Dots
    var total_w: u16 = 0;
    for (0..5) |i| { total_w += if (i == state.menu_index) @as(u16, 24) else @as(u16, 12); }
    total_w += 4 * 10;
    var dx: u16 = (SCREEN_W - total_w) / 2;
    for (0..5) |i| {
        const active = (i == state.menu_index);
        const w: u16 = if (active) 24 else 12;
        fb.fillRoundRect(dx, 218, w, 12, 6, if (active) WHITE else DIM_WHITE);
        dx += w + 10;
    }
    renderHeader(fb, res);
}

fn renderGameList(fb: *FB, state: *const AppState, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    renderHeader(fb, res);
    const lx: u16 = 8;
    for (0..4) |i| {
        const y: u16 = 50 + @as(u16, @intCast(i)) * 59;
        if (i == state.game_index) {
            if (res.btn_list) |img| fb.blit(lx, y, img);
        } else fb.fillRoundRect(lx, y, 224, 55, 4, BLACK);
        if (res.game_icons[i]) |icon| fb.blit(lx + 16, y + 11, icon);
        if (res.font_24) |f| fb.drawTextTtf(lx + 64, y + 14, assets_mod.GAME_LABELS[i], f, WHITE);
    }
}

fn renderSettings(fb: *FB, state: *const AppState, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    renderHeader(fb, res);
    const lx: u16 = 8;
    const base_y: i32 = 54 - @as(i32, state.settings_scroll);
    for (0..9) |i| {
        const iy: i32 = base_y + @as(i32, @intCast(i)) * 59;
        if (iy + 55 < 0 or iy >= SCREEN_H) continue;
        const y: u16 = if (iy < 0) 0 else @intCast(iy);
        if (i == state.settings_index) {
            if (res.btn_list) |img| fb.blit(lx, y, img);
        } else fb.fillRoundRect(lx, y, 224, 55, 4, BLACK);
        if (res.setting_icons[i]) |icon| fb.blit(lx + 16, y + 11, icon);
        if (res.font_20) |f| fb.drawTextTtf(lx + 64, y + 16, assets_mod.SETTING_LABELS[i], f, WHITE);
    }
}

fn renderHeader(fb: *FB, res: *const Resources) void {
    if (res.font_16) |f| {
        fb.drawTextTtf(16, 16, "12:00", f, WHITE);
        drawWifiIcon(fb, 200, 18);
        drawBatteryIcon(fb, 218, 18);
    }
}

fn drawWifiIcon(fb: *FB, x: u16, y: u16) void {
    fb.fillRect(x + 4, y + 8, 3, 3, WHITE);
    fb.hline(x + 2, y + 5, 7, WHITE);
    fb.hline(x, y + 2, 11, WHITE);
}

fn drawBatteryIcon(fb: *FB, x: u16, y: u16) void {
    fb.drawRect(x, y + 2, 14, 8, WHITE, 1);
    fb.fillRect(x + 14, y + 4, 2, 4, WHITE);
    fb.fillRect(x + 2, y + 4, 8, 4, WHITE);
}

fn renderIntro(fb: *FB, state: *const AppState, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;

    switch (state.intro_index) {
        0 => {
            // Page 1: haivivi logo + text
            if (res.icon_haivivi) |img| fb.blit((SCREEN_W - 64) / 2, 60, img);
            if (res.font_16) |f| {
                const txt = "\xe5\xbc\x80\xe5\xa7\x8b\xe9\x85\x8d\xe5\xaf\xb9\xe4\xbd\xa0\xe7\x9a\x84\xe8\xae\xbe\xe5\xa4\x87"; // 开始配对你的设备
                const tw = f.textWidth(txt);
                fb.drawTextTtf((SCREEN_W -| tw) / 2, 140, txt, f, WHITE);
            }
            if (res.font_24) |f| fb.drawTextTtf(60, 190, assets_mod.INTRO_LABELS[0], f, WHITE);
        },
        1 => {
            // Page 2: settings icon + arrow + list demo
            if (res.intro_setting) |img| fb.blit(0, 40, img);
            if (res.intro_arrow) |img| fb.blit(86, 26, img);
            if (res.intro_list) |img| fb.blit(116, 67, img);
            if (res.font_24) |f| fb.drawTextTtf(50, 190, assets_mod.INTRO_LABELS[1], f, WHITE);
        },
        2 => {
            // Page 3: device image
            if (res.intro_device) |img| fb.blit((SCREEN_W - 185) / 2, 50, img);
            if (res.font_24) |f| fb.drawTextTtf(50, 190, assets_mod.INTRO_LABELS[2], f, WHITE);
        },
        else => {},
    }

    // Dot indicators (same style as menu)
    var total_w: u16 = 0;
    for (0..3) |i| { total_w += if (i == state.intro_index) @as(u16, 24) else @as(u16, 12); }
    total_w += 2 * 10;
    var dx: u16 = (SCREEN_W - total_w) / 2;
    for (0..3) |i| {
        const active = (i == state.intro_index);
        const w: u16 = if (active) 24 else 12;
        fb.fillRoundRect(dx, 220, w, 12, 6, if (active) WHITE else DIM_WHITE);
        dx += w + 10;
    }
}

fn renderSettingsLcd(fb: *FB, state: *const AppState, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    renderHeader(fb, res);

    // Three-stage brightness indicator
    if (res.font_24) |f| {
        fb.drawTextTtf(50, 70, "\xe5\xb1\x8f\xe5\xb9\x95\xe4\xba\xae\xe5\xba\xa6", f, WHITE); // 屏幕亮度
    }

    const stages = [_]u8{ 10, 55, 85, 100 };
    const bar_y: u16 = 130;
    const bar_w: u16 = 180;
    const bar_h: u16 = 12;
    const bar_x: u16 = (SCREEN_W - bar_w) / 2;

    // Background bar
    fb.fillRoundRect(bar_x, bar_y, bar_w, bar_h, 6, 0x2104);

    // Fill based on brightness
    const fill_w: u16 = @intCast(@as(u32, bar_w) * state.lcd_brightness / 100);
    if (fill_w > 0) fb.fillRoundRect(bar_x, bar_y, fill_w, bar_h, 6, 0x6C8C); // theme_color

    // Stage dots
    for (stages, 0..) |val, i| {
        const dot_x = bar_x + @as(u16, @intCast(@as(u32, bar_w) * val / 100)) -| 4;
        const color: u16 = if (state.lcd_brightness >= val) WHITE else 0x4208;
        fb.fillRoundRect(dot_x, bar_y - 2, 8, bar_h + 4, 4, color);
        // Label
        if (res.font_16) |f| {
            var buf: [4]u8 = undefined;
            const len = fmtU8(val, &buf);
            fb.drawTextTtf(dot_x -| 4, bar_y + 20, buf[0..len], f, WHITE);
        }
        _ = i;
    }
}

fn renderSettingsInfo(fb: *FB, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    renderHeader(fb, res);
    if (res.font_20) |f| {
        fb.drawTextTtf(30, 60, "\xe8\xae\xbe\xe5\xa4\x87\xe4\xbf\xa1\xe6\x81\xaf", f, WHITE); // 设备信息
        fb.drawTextTtf(30, 100, "H106", f, 0x7BEF);
        fb.drawTextTtf(30, 130, "FW: 1.0.0", f, 0x7BEF);
        fb.drawTextTtf(30, 160, "BLE: OK", f, 0x7BEF);
    }
}

fn renderSettingsReset(fb: *FB, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    // Confirmation dialog
    fb.fillRoundRect(30, 60, 180, 120, 8, 0x1084);
    fb.drawRect(30, 60, 180, 120, WHITE, 1);
    if (res.font_24) |f| {
        fb.drawTextTtf(50, 90, "\xe9\x87\x8d\xe7\xbd\xae\xe8\xae\xbe\xe5\xa4\x87?", f, WHITE); // 重置设备?
    }
    if (res.font_16) |f| {
        fb.drawTextTtf(45, 130, "OK \xe7\xa1\xae\xe8\xae\xa4  BACK \xe5\x8f\x96\xe6\xb6\x88", f, 0x7BEF); // OK 确认  BACK 取消
    }
}

fn renderContact(fb: *FB, state: *const AppState, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    renderHeader(fb, res);

    if (!state.device_bound) {
        // Empty state
        if (res.font_24) |f| fb.drawTextTtf(50, 80, "\xe5\xae\x88\xe6\x8a\xa4\xe8\x81\x94\xe7\xbb\x9c", f, WHITE); // 守护联络
        if (res.font_16) |f| fb.drawTextTtf(30, 130, "\xe8\xaf\xb7\xe5\x85\x88\xe7\xbb\x91\xe5\xae\x9a\xe8\xae\xbe\xe5\xa4\x87", f, 0x7BEF); // 请先绑定设备
    } else {
        if (res.font_24) |f| fb.drawTextTtf(50, 60, "\xe5\xae\x88\xe6\x8a\xa4\xe8\x81\x94\xe7\xbb\x9c", f, WHITE);
        // Contact list would go here
    }
}

fn renderPoints(fb: *FB, state: *const AppState, res: *const Resources, xo: i16) void {
    blitBgOff(fb, res, xo);
    if (xo != 0) return;
    renderHeader(fb, res);

    if (res.font_20) |f| {
        fb.drawTextTtf(20, 60, "\xe7\xa7\xaf\xe5\x88\x86", f, WHITE); // 积分
        // Points value
        var buf: [10]u8 = undefined;
        const len = fmtU32(state.points_value, &buf);
        fb.drawTextTtf(140, 60, buf[0..len], f, WHITE);
    }

    if (state.points_value == 0 and !state.device_bound) {
        if (res.font_16) |f| fb.drawTextTtf(20, 120, "\xe8\xaf\xb7\xe5\x85\x88\xe7\xbb\x91\xe5\xae\x9a\xe8\xae\xbe\xe5\xa4\x87", f, 0x7BEF); // 请先绑定设备
    }
}

fn fmtU8(val: u8, buf: *[4]u8) usize {
    var v: u8 = val;
    var i: usize = 4;
    if (v == 0) { buf[3] = '0'; return 1; }
    while (v > 0) : (v /= 10) { i -= 1; buf[i] = '0' + @as(u8, @intCast(v % 10)); }
    const len = 4 - i;
    if (i > 0) { for (0..len) |j| buf[j] = buf[i + j]; }
    return len;
}

fn fmtU32(val: u32, buf: *[10]u8) usize {
    var v: u32 = val;
    var i: usize = 10;
    if (v == 0) { buf[9] = '0'; return 1; }
    while (v > 0) : (v /= 10) { i -= 1; buf[i] = @intCast('0' + v % 10); }
    const len = 10 - i;
    if (i > 0) { for (0..len) |j| buf[j] = buf[i + j]; }
    return len;
}

// ============================================================================
// Helpers (pure, no state)
// ============================================================================

fn easeOut(t: u16) u16 { const inv: u32 = 256 - t; return @intCast(256 - (inv * inv / 256)); }
fn easeIn(t: u16) u16 { const tv: u32 = t; return @intCast(tv * tv / 256); }

fn blitBgOff(fb: *FB, res: *const Resources, xo: i16) void {
    if (res.bg) |img| {
        if (xo == 0) fb.blit(0, 0, img)
        else if (xo > 0 and xo < SCREEN_W) { fb.fillRect(0, 0, @intCast(xo), SCREEN_H, BLACK); fb.blit(@intCast(xo), 0, img); }
        else if (xo < 0 and xo > -@as(i16, SCREEN_W)) { fb.blit(0, 0, img); fb.fillRect(@intCast(@as(i16, SCREEN_W) + xo), 0, @intCast(-xo), SCREEN_H, BLACK); }
    } else fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);
}

fn fillOff(fb: *FB, xo: i16, color: u16) void {
    if (xo >= 0 and xo < SCREEN_W) fb.fillRect(@intCast(xo), 0, SCREEN_W -| @as(u16, @intCast(xo)), SCREEN_H, color)
    else if (xo < 0 and xo > -@as(i16, SCREEN_W)) fb.fillRect(0, 0, @intCast(@as(i16, SCREEN_W) + xo), SCREEN_H, color);
}
