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
    font_24: ?*state_lib.TtfFont = null,
    font_20: ?*state_lib.TtfFont = null,
    font_16: ?*state_lib.TtfFont = null,
    anim_player: ?*state_lib.AnimPlayer = null,
};

// ============================================================================
// State — ALL mutable state lives here
// ============================================================================

pub const Page = enum { off, startup, desktop, menu, game_list, game_tetris, game_racer, settings, shutting_down };

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

    // Animation state — reducer controls frame advancement
    anim_frame_index: u16 = 0,
    anim_frame_timer: u16 = 0, // sub-frame counter for fps matching
    anim_done: bool = false,

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
                // Advance animation frame in reducer (not in render!)
                if (!state.anim_done) {
                    state.anim_frame_timer += 1;
                    // 30fps anim in 60fps loop → advance every 2 ticks
                    if (state.anim_frame_timer >= 2) {
                        state.anim_frame_timer = 0;
                        state.anim_frame_index += 1;
                    }
                }
                // anim_done is set by render when player reports done
                if (state.anim_done) state.page = .desktop;
            },
            .confirm, .back => { state.page = .desktop; state.anim_done = true; },
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
            .up, .left => if (state.settings_index > 0) { state.settings_index -= 1; updateScroll(state); },
            .down, .right => if (state.settings_index < 8) { state.settings_index += 1; updateScroll(state); },
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
        .desktop => renderDesktop(fb, res, xo),
        .menu => renderMenu(fb, state, res, xo),
        .game_list => renderGameList(fb, state, res, xo),
        .settings => renderSettings(fb, state, res, xo),
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
