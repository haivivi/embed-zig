//! H106 UI — Page State Machine
//!
//! Multi-page UI with carousel menu, page transitions, and embedded games.
//!
//! Pages:
//!   Desktop → Menu (carousel, 5 items) → Game List → Tetris / Racer
//!                                       → Settings (placeholder)
//!
//! Navigation:
//!   Desktop: RIGHT → Menu
//!   Menu: LEFT/RIGHT scroll, OK → enter page, BACK → Desktop
//!   Game List: UP/DOWN scroll, OK → launch game, BACK → Menu
//!   Game: BACK → Game List
//!
//! Pure logic + rendering, no platform dependencies.

const state_lib = @import("ui_state");
const img_assets = @import("assets.zig");
const tetris = @import("tetris.zig");
const racer = @import("racer.zig");

// ============================================================================
// Constants
// ============================================================================

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;
pub const FB = state_lib.Framebuffer(SCREEN_W, SCREEN_H, .rgb565);

const MENU_COUNT: u8 = 5;
const MENU_ICON_SIZE: u16 = 160;
const MENU_ICON_Y: u16 = 20;
const DOT_Y: u16 = 220;
const DOT_SIZE: u16 = 8;
const DOT_ACTIVE_W: u16 = 18;
const DOT_GAP: u16 = 14;
const LABEL_Y: u16 = 195;

const GAME_COUNT: u8 = 2;

// Colors
pub const BLACK: u16 = 0x0000;
pub const WHITE: u16 = 0xFFFF;
pub const GRAY: u16 = 0x4208;
pub const DIM_WHITE: u16 = 0x7BEF;
pub const ACCENT: u16 = 0x07FF; // cyan
pub const SELECT_BG: u16 = 0x2965; // dark blue-ish

// ============================================================================
// State
// ============================================================================

pub const Page = enum {
    desktop,
    menu,
    game_list,
    game_tetris,
    game_racer,
    settings,
};

pub const Transition = struct {
    from: Page,
    to: Page,
    start_tick: u32,
    duration: u32,
    direction: Direction,

    pub const Direction = enum { left, right };
};

pub const AppState = struct {
    page: Page = .desktop,
    transition: ?Transition = null,
    tick: u32 = 0,

    // Menu
    menu_index: u8 = 0,

    // Game list
    game_index: u8 = 0,

    // Sub-page states
    tetris: tetris.GameState = .{},
    racer: racer.GameState = .{},
};

pub const AppEvent = union(enum) {
    tick,
    left,
    right,
    up,
    down,
    confirm,
    back,
};

pub const Store = state_lib.Store(AppState, AppEvent);

// ============================================================================
// Reducer
// ============================================================================

pub fn reduce(state: *AppState, event: AppEvent) void {
    state.tick += 1;

    // During transition, only tick advances
    if (state.transition) |t| {
        if (state.tick >= t.start_tick + t.duration) {
            state.page = t.to;
            state.transition = null;
        }
        // Forward ticks to active games during transitions
        if (event == .tick) {
            if (state.page == .game_tetris) tetris.reduce(&state.tetris, .tick);
            if (state.page == .game_racer) racer.reduce(&state.racer, .tick);
        }
        return;
    }

    switch (state.page) {
        .desktop => reduceDesktop(state, event),
        .menu => reduceMenu(state, event),
        .game_list => reduceGameList(state, event),
        .game_tetris => reduceTetris(state, event),
        .game_racer => reduceRacer(state, event),
        .settings => reduceSettings(state, event),
    }
}

fn reduceDesktop(state: *AppState, event: AppEvent) void {
    switch (event) {
        .right, .confirm => navigate(state, .menu, .left),
        else => {},
    }
}

fn reduceMenu(state: *AppState, event: AppEvent) void {
    switch (event) {
        .left => {
            if (state.menu_index > 0) {
                state.menu_index -= 1;
            } else {
                navigate(state, .desktop, .right);
            }
        },
        .right => {
            if (state.menu_index < MENU_COUNT - 1) {
                state.menu_index += 1;
            }
        },
        .confirm => {
            switch (state.menu_index) {
                1 => navigate(state, .game_list, .left), // Game
                4 => navigate(state, .settings, .left), // Settings
                else => {},
            }
        },
        .back => navigate(state, .desktop, .right),
        else => {},
    }
}

fn reduceGameList(state: *AppState, event: AppEvent) void {
    switch (event) {
        .up, .left => {
            if (state.game_index > 0) state.game_index -= 1;
        },
        .down, .right => {
            if (state.game_index < GAME_COUNT - 1) state.game_index += 1;
        },
        .confirm => {
            switch (state.game_index) {
                0 => {
                    state.tetris = .{};
                    navigate(state, .game_tetris, .left);
                },
                1 => {
                    state.racer = .{};
                    navigate(state, .game_racer, .left);
                },
                else => {},
            }
        },
        .back => navigate(state, .menu, .right),
        else => {},
    }
}

fn reduceTetris(state: *AppState, event: AppEvent) void {
    switch (event) {
        .back => navigate(state, .game_list, .right),
        .left => tetris.reduce(&state.tetris, .move_left),
        .right => tetris.reduce(&state.tetris, .move_right),
        .confirm => tetris.reduce(&state.tetris, .rotate),
        .up => tetris.reduce(&state.tetris, .hard_drop),
        .down => tetris.reduce(&state.tetris, .soft_drop),
        .tick => tetris.reduce(&state.tetris, .tick),
    }
}

fn reduceRacer(state: *AppState, event: AppEvent) void {
    switch (event) {
        .back => navigate(state, .game_list, .right),
        .left => racer.reduce(&state.racer, .move_left),
        .right => racer.reduce(&state.racer, .move_right),
        .tick => racer.reduce(&state.racer, .tick),
        else => {},
    }
}

fn reduceSettings(state: *AppState, event: AppEvent) void {
    switch (event) {
        .back => navigate(state, .menu, .right),
        else => {},
    }
}

fn navigate(state: *AppState, to: Page, direction: Transition.Direction) void {
    state.transition = .{
        .from = state.page,
        .to = to,
        .start_tick = state.tick,
        .duration = 10, // ~167ms at 60fps
        .direction = direction,
    };
}

// ============================================================================
// Render
// ============================================================================

pub fn render(fb: *FB, state: *const AppState) void {
    if (state.transition) |t| {
        renderTransition(fb, state, t);
    } else {
        renderPage(fb, state, state.page, 0);
    }
}

fn renderTransition(fb: *FB, state: *const AppState, t: Transition) void {
    const elapsed = state.tick -| t.start_tick;
    const progress_256 = @min(@as(u32, 256), elapsed * 256 / t.duration);
    const eased = easeOut(@intCast(progress_256));

    const offset: i16 = @intCast(@as(u32, SCREEN_W) * eased / 256);

    switch (t.direction) {
        .left => {
            // Old page slides left, new page enters from right
            renderPage(fb, state, t.from, -offset);
            renderPage(fb, state, t.to, @intCast(@as(i16, SCREEN_W) - offset));
        },
        .right => {
            // Old page slides right, new page enters from left
            renderPage(fb, state, t.from, offset);
            renderPage(fb, state, t.to, -(@as(i16, SCREEN_W) - offset));
        },
    }
}

fn renderPage(fb: *FB, state: *const AppState, page: Page, x_offset: i16) void {
    switch (page) {
        .desktop => renderDesktop(fb, x_offset),
        .menu => renderMenu(fb, state, x_offset),
        .game_list => renderGameList(fb, state, x_offset),
        .game_tetris => renderTetris(fb, state, x_offset),
        .game_racer => renderRacer(fb, state, x_offset),
        .settings => renderSettingsPage(fb, x_offset),
    }
}

fn renderDesktop(fb: *FB, x_off: i16) void {
    if (x_off == 0) {
        // Full screen — blit ultraman image directly
        fb.blit(0, 0, img_assets.ultraman);
    } else {
        // During transition: fill with bg first, then overlay
        blitWithOffset(fb, x_off, 0, img_assets.bg);
    }
}

fn renderMenu(fb: *FB, state: *const AppState, x_off: i16) void {
    // Background
    blitWithOffset(fb, x_off, 0, img_assets.bg);

    // Current menu item icon (centered)
    const icon = img_assets.menu_items[state.menu_index];
    const icon_x: i16 = @as(i16, (SCREEN_W - MENU_ICON_SIZE) / 2) + x_off;
    blitAt(fb, icon_x, MENU_ICON_Y, icon);

    // Dot indicators
    const total_w = (@as(u16, MENU_COUNT) - 1) * DOT_GAP + DOT_ACTIVE_W;
    var dot_x: i16 = @as(i16, (SCREEN_W - total_w) / 2) + x_off;
    for (0..MENU_COUNT) |i| {
        const is_active = (i == state.menu_index);
        const w: u16 = if (is_active) DOT_ACTIVE_W else DOT_SIZE;
        const h: u16 = DOT_SIZE;
        const color: u16 = if (is_active) WHITE else DIM_WHITE;
        const rx: u16 = if (dot_x < 0) 0 else @intCast(@min(@as(i16, SCREEN_W), dot_x));
        if (dot_x >= 0 and dot_x < SCREEN_W) {
            fb.fillRect(rx, DOT_Y, w, h, color);
        }
        dot_x += @as(i16, @intCast(if (is_active) DOT_ACTIVE_W + DOT_GAP - DOT_SIZE else DOT_GAP));
    }

    // Menu label
    const label = img_assets.MENU_LABELS[state.menu_index];
    const label_x: i16 = @as(i16, (SCREEN_W / 2) -| @as(u16, @intCast(label.len * 6 / 2))) + x_off;
    if (label_x >= 0 and label_x < SCREEN_W) {
        drawTextSimple(fb, @intCast(label_x), LABEL_Y, label, WHITE);
    }
}

fn renderGameList(fb: *FB, state: *const AppState, x_off: i16) void {
    // Background
    blitWithOffset(fb, x_off, 0, img_assets.bg);

    const game_names = [_][]const u8{ "Tetris", "Racer" };
    const item_h: u16 = 40;
    const list_y: u16 = 60;

    for (0..GAME_COUNT) |i| {
        const y: u16 = list_y + @as(u16, @intCast(i)) * (item_h + 8);
        const is_selected = (i == state.game_index);
        const bg_color: u16 = if (is_selected) SELECT_BG else BLACK;
        const txt_color: u16 = if (is_selected) ACCENT else GRAY;

        const rx: i16 = 20 + x_off;
        if (rx >= 0 and rx < SCREEN_W) {
            const rxu: u16 = @intCast(rx);
            fb.fillRect(rxu, y, 200, item_h, bg_color);
            if (is_selected) {
                fb.drawRect(rxu, y, 200, item_h, ACCENT, 1);
            }
            drawTextSimple(fb, rxu + 16, y + 14, game_names[i], txt_color);
        }
    }

    // Title
    const title_x: i16 = 70 + x_off;
    if (title_x >= 0 and title_x < SCREEN_W) {
        drawTextSimple(fb, @intCast(title_x), 20, "Games", WHITE);
    }
}

fn renderTetris(fb: *FB, state: *const AppState, x_off: i16) void {
    if (x_off == 0) {
        // Full render
        const empty_state = tetris.GameState{};
        tetris.render(fb, &state.tetris, &empty_state);
    } else {
        // During transition, just show black
        fillWithOffset(fb, x_off, BLACK);
    }
}

fn renderRacer(fb: *FB, state: *const AppState, x_off: i16) void {
    if (x_off == 0) {
        const empty_state = racer.GameState{};
        racer.render(fb, &state.racer, &empty_state);
    } else {
        fillWithOffset(fb, x_off, BLACK);
    }
}

fn renderSettingsPage(fb: *FB, x_off: i16) void {
    blitWithOffset(fb, x_off, 0, img_assets.bg);
    const tx: i16 = 60 + x_off;
    if (tx >= 0 and tx < SCREEN_W) {
        drawTextSimple(fb, @intCast(tx), 100, "Settings", WHITE);
        drawTextSimple(fb, @intCast(tx), 130, "(Coming Soon)", GRAY);
    }
}

// ============================================================================
// Helpers
// ============================================================================

/// Ease-out quadratic: 1 - (1-t)^2, integer version (0-256 range)
fn easeOut(t: u16) u16 {
    const inv: u32 = 256 - t;
    return @intCast(256 - (inv * inv / 256));
}

/// Blit image at an i16 offset (for page transitions)
fn blitAt(fb: *FB, x: i16, y: u16, img: @import("ui_state").Image) void {
    if (x >= SCREEN_W or x + @as(i16, @intCast(img.width)) <= 0) return;
    const ux: u16 = if (x < 0) 0 else @intCast(x);
    fb.blit(ux, y, img);
}

/// Blit background with horizontal offset
fn blitWithOffset(fb: *FB, x_off: i16, y: u16, img: @import("ui_state").Image) void {
    if (x_off == 0) {
        fb.blit(0, y, img);
    } else if (x_off > 0 and x_off < SCREEN_W) {
        // Partial: fill left gap with black, blit shifted
        fb.fillRect(0, y, @intCast(x_off), SCREEN_H, BLACK);
        fb.blit(@intCast(x_off), y, img);
    } else if (x_off < 0 and x_off > -@as(i16, SCREEN_W)) {
        fb.blit(0, y, img);
        const gap_x: u16 = @intCast(@as(i16, SCREEN_W) + x_off);
        fb.fillRect(gap_x, y, @intCast(-x_off), SCREEN_H, BLACK);
    }
}

fn fillWithOffset(fb: *FB, x_off: i16, color: u16) void {
    if (x_off >= 0 and x_off < SCREEN_W) {
        fb.fillRect(@intCast(x_off), 0, SCREEN_W -| @as(u16, @intCast(x_off)), SCREEN_H, color);
    } else if (x_off < 0 and x_off > -@as(i16, SCREEN_W)) {
        fb.fillRect(0, 0, @intCast(@as(i16, SCREEN_W) + x_off), SCREEN_H, color);
    }
}

// Simple text using 5x7 digit bitmaps (ASCII printable subset)
const DIGIT_BITMAPS = [10][7]u8{
    .{ 0x70, 0x88, 0x98, 0xA8, 0xC8, 0x88, 0x70 },
    .{ 0x20, 0x60, 0x20, 0x20, 0x20, 0x20, 0x70 },
    .{ 0x70, 0x88, 0x08, 0x10, 0x20, 0x40, 0xF8 },
    .{ 0x70, 0x88, 0x08, 0x30, 0x08, 0x88, 0x70 },
    .{ 0x10, 0x30, 0x50, 0x90, 0xF8, 0x10, 0x10 },
    .{ 0xF8, 0x80, 0xF0, 0x08, 0x08, 0x88, 0x70 },
    .{ 0x30, 0x40, 0x80, 0xF0, 0x88, 0x88, 0x70 },
    .{ 0xF8, 0x08, 0x10, 0x20, 0x40, 0x40, 0x40 },
    .{ 0x70, 0x88, 0x88, 0x70, 0x88, 0x88, 0x70 },
    .{ 0x70, 0x88, 0x88, 0x78, 0x08, 0x10, 0x60 },
};

// Simple 5x7 uppercase letter bitmaps
const LETTER_BITMAPS = [26][7]u8{
    .{ 0x70, 0x88, 0x88, 0xF8, 0x88, 0x88, 0x88 }, // A
    .{ 0xF0, 0x88, 0x88, 0xF0, 0x88, 0x88, 0xF0 }, // B
    .{ 0x70, 0x88, 0x80, 0x80, 0x80, 0x88, 0x70 }, // C
    .{ 0xF0, 0x88, 0x88, 0x88, 0x88, 0x88, 0xF0 }, // D
    .{ 0xF8, 0x80, 0x80, 0xF0, 0x80, 0x80, 0xF8 }, // E
    .{ 0xF8, 0x80, 0x80, 0xF0, 0x80, 0x80, 0x80 }, // F
    .{ 0x70, 0x88, 0x80, 0xB8, 0x88, 0x88, 0x70 }, // G
    .{ 0x88, 0x88, 0x88, 0xF8, 0x88, 0x88, 0x88 }, // H
    .{ 0x70, 0x20, 0x20, 0x20, 0x20, 0x20, 0x70 }, // I
    .{ 0x38, 0x10, 0x10, 0x10, 0x10, 0x90, 0x60 }, // J
    .{ 0x88, 0x90, 0xA0, 0xC0, 0xA0, 0x90, 0x88 }, // K
    .{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0xF8 }, // L
    .{ 0x88, 0xD8, 0xA8, 0x88, 0x88, 0x88, 0x88 }, // M
    .{ 0x88, 0xC8, 0xA8, 0x98, 0x88, 0x88, 0x88 }, // N
    .{ 0x70, 0x88, 0x88, 0x88, 0x88, 0x88, 0x70 }, // O
    .{ 0xF0, 0x88, 0x88, 0xF0, 0x80, 0x80, 0x80 }, // P
    .{ 0x70, 0x88, 0x88, 0x88, 0xA8, 0x90, 0x68 }, // Q
    .{ 0xF0, 0x88, 0x88, 0xF0, 0xA0, 0x90, 0x88 }, // R
    .{ 0x70, 0x88, 0x80, 0x70, 0x08, 0x88, 0x70 }, // S
    .{ 0xF8, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20 }, // T
    .{ 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x70 }, // U
    .{ 0x88, 0x88, 0x88, 0x88, 0x50, 0x50, 0x20 }, // V
    .{ 0x88, 0x88, 0x88, 0x88, 0xA8, 0xD8, 0x88 }, // W
    .{ 0x88, 0x88, 0x50, 0x20, 0x50, 0x88, 0x88 }, // X
    .{ 0x88, 0x88, 0x50, 0x20, 0x20, 0x20, 0x20 }, // Y
    .{ 0xF8, 0x08, 0x10, 0x20, 0x40, 0x80, 0xF8 }, // Z
};

pub fn drawTextSimple(fb: *FB, x: u16, y: u16, text: []const u8, color: u16) void {
    var cx = x;
    for (text) |ch| {
        const bitmap: ?*const [7]u8 = if (ch >= '0' and ch <= '9')
            &DIGIT_BITMAPS[ch - '0']
        else if (ch >= 'A' and ch <= 'Z')
            &LETTER_BITMAPS[ch - 'A']
        else if (ch >= 'a' and ch <= 'z')
            &LETTER_BITMAPS[ch - 'a']
        else if (ch == '(' or ch == ')' or ch == ' ')
            null
        else
            null;

        if (bitmap) |bmp| {
            for (0..7) |row| {
                for (0..5) |col| {
                    const bit = @as(u8, 0x80) >> @intCast(col);
                    if (bmp[row] & bit != 0) {
                        fb.setPixel(cx + @as(u16, @intCast(col)), y + @as(u16, @intCast(row)), color);
                    }
                }
            }
        }
        cx += 6;
    }
}
