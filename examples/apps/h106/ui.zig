//! H106 UI — Page State Machine
//!
//! Multi-page UI with carousel menu, page transitions, and embedded games.
//! Assets are loaded at runtime via VFS — this module receives them via initAssets().
//!
//! Pure logic + rendering, no platform dependencies.

const state_lib = @import("ui_state");
const tetris = @import("tetris.zig");
const racer = @import("racer.zig");

// ============================================================================
// Constants
// ============================================================================

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;
pub const FB = state_lib.Framebuffer(SCREEN_W, SCREEN_H, .rgb565);
const Image = state_lib.Image;

const MENU_COUNT: u8 = 5;
const MENU_ICON_SIZE: u16 = 160;
const MENU_ICON_X: u16 = (SCREEN_W - MENU_ICON_SIZE) / 2;
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
pub const ACCENT: u16 = 0x07FF;
pub const SELECT_BG: u16 = 0x2965;

const MENU_LABELS = [5][]const u8{ "Team", "Game", "Contact", "Points", "Settings" };

// ============================================================================
// Runtime Assets (loaded via VFS in app.zig)
// ============================================================================

var bg_image: ?Image = null;
var ultraman_image: ?Image = null;
var menu_images: [5]?Image = [_]?Image{null} ** 5;

/// Called by app.zig after loading assets from VFS.
pub fn initAssets(
    bg: Image,
    ultraman: ?Image,
    menus: [5]?Image,
) void {
    bg_image = bg;
    ultraman_image = ultraman;
    menu_images = menus;
}

// ============================================================================
// State
// ============================================================================

pub const Page = enum { desktop, menu, game_list, game_tetris, game_racer, settings };

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
    menu_index: u8 = 0,
    game_index: u8 = 0,
    tetris: tetris.GameState = .{},
    racer: racer.GameState = .{},
};

pub const AppEvent = union(enum) { tick, left, right, up, down, confirm, back };

pub const Store = state_lib.Store(AppState, AppEvent);

// ============================================================================
// Reducer
// ============================================================================

pub fn reduce(state: *AppState, event: AppEvent) void {
    state.tick += 1;

    if (state.transition) |t| {
        if (state.tick >= t.start_tick + t.duration) {
            state.page = t.to;
            state.transition = null;
        }
        if (event == .tick) {
            if (state.page == .game_tetris) tetris.reduce(&state.tetris, .tick);
            if (state.page == .game_racer) racer.reduce(&state.racer, .tick);
        }
        return;
    }

    switch (state.page) {
        .desktop => switch (event) {
            .right, .confirm => navigate(state, .menu, .left),
            else => {},
        },
        .menu => switch (event) {
            .left => if (state.menu_index > 0) { state.menu_index -= 1; } else navigate(state, .desktop, .right),
            .right => if (state.menu_index < MENU_COUNT - 1) { state.menu_index += 1; },
            .confirm => switch (state.menu_index) {
                1 => navigate(state, .game_list, .left),
                4 => navigate(state, .settings, .left),
                else => {},
            },
            .back => navigate(state, .desktop, .right),
            else => {},
        },
        .game_list => switch (event) {
            .up, .left => if (state.game_index > 0) { state.game_index -= 1; },
            .down, .right => if (state.game_index < GAME_COUNT - 1) { state.game_index += 1; },
            .confirm => switch (state.game_index) {
                0 => { state.tetris = .{}; navigate(state, .game_tetris, .left); },
                1 => { state.racer = .{}; navigate(state, .game_racer, .left); },
                else => {},
            },
            .back => navigate(state, .menu, .right),
            else => {},
        },
        .game_tetris => switch (event) {
            .back => navigate(state, .game_list, .right),
            .left => tetris.reduce(&state.tetris, .move_left),
            .right => tetris.reduce(&state.tetris, .move_right),
            .confirm => tetris.reduce(&state.tetris, .rotate),
            .up => tetris.reduce(&state.tetris, .hard_drop),
            .down => tetris.reduce(&state.tetris, .soft_drop),
            .tick => tetris.reduce(&state.tetris, .tick),
        },
        .game_racer => switch (event) {
            .back => navigate(state, .game_list, .right),
            .left => racer.reduce(&state.racer, .move_left),
            .right => racer.reduce(&state.racer, .move_right),
            .tick => racer.reduce(&state.racer, .tick),
            else => {},
        },
        .settings => switch (event) {
            .back => navigate(state, .menu, .right),
            else => {},
        },
    }
}

fn navigate(state: *AppState, to: Page, direction: Transition.Direction) void {
    state.transition = .{
        .from = state.page,
        .to = to,
        .start_tick = state.tick,
        .duration = 10,
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
    const progress = @min(@as(u32, 256), elapsed * 256 / t.duration);
    const eased = easeOut(@intCast(progress));
    const offset: i16 = @intCast(@as(u32, SCREEN_W) * eased / 256);

    switch (t.direction) {
        .left => {
            renderPage(fb, state, t.from, -offset);
            renderPage(fb, state, t.to, @intCast(@as(i16, SCREEN_W) - offset));
        },
        .right => {
            renderPage(fb, state, t.from, offset);
            renderPage(fb, state, t.to, -(@as(i16, SCREEN_W) - offset));
        },
    }
}

fn renderPage(fb: *FB, state: *const AppState, page: Page, x_off: i16) void {
    switch (page) {
        .desktop => renderDesktop(fb, x_off),
        .menu => renderMenu(fb, state, x_off),
        .game_list => renderGameList(fb, state, x_off),
        .game_tetris => renderTetris(fb, state, x_off),
        .game_racer => renderRacer(fb, state, x_off),
        .settings => renderSettings(fb, x_off),
    }
}

fn renderDesktop(fb: *FB, x_off: i16) void {
    if (x_off == 0) {
        if (ultraman_image) |img| fb.blit(0, 0, img)
        else if (bg_image) |img| fb.blit(0, 0, img)
        else fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);
    } else {
        blitBg(fb, x_off);
    }
}

fn renderMenu(fb: *FB, state: *const AppState, x_off: i16) void {
    blitBg(fb, x_off);

    // Menu icon
    if (menu_images[state.menu_index]) |img| {
        const ix: i16 = @as(i16, MENU_ICON_X) + x_off;
        if (ix > -@as(i16, MENU_ICON_SIZE) and ix < SCREEN_W) {
            const ux: u16 = if (ix < 0) 0 else @intCast(ix);
            fb.blit(ux, MENU_ICON_Y, img);
        }
    }

    // Dot indicators
    if (x_off == 0) {
        const total_w = (@as(u16, MENU_COUNT) - 1) * DOT_GAP + DOT_ACTIVE_W;
        var dx: u16 = (SCREEN_W - total_w) / 2;
        for (0..MENU_COUNT) |i| {
            const active = (i == state.menu_index);
            const w: u16 = if (active) DOT_ACTIVE_W else DOT_SIZE;
            const color: u16 = if (active) WHITE else DIM_WHITE;
            fb.fillRect(dx, DOT_Y, w, DOT_SIZE, color);
            dx += if (active) DOT_ACTIVE_W + DOT_GAP - DOT_SIZE else DOT_GAP;
        }

        // Label
        const label = MENU_LABELS[state.menu_index];
        const lx = (SCREEN_W / 2) -| @as(u16, @intCast(label.len * 6 / 2));
        drawTextSimple(fb, lx, LABEL_Y, label, WHITE);
    }
}

fn renderGameList(fb: *FB, state: *const AppState, x_off: i16) void {
    blitBg(fb, x_off);
    if (x_off != 0) return;

    drawTextSimple(fb, 90, 20, "Games", WHITE);

    const names = [_][]const u8{ "Tetris", "Racer" };
    for (0..GAME_COUNT) |i| {
        const y: u16 = 60 + @as(u16, @intCast(i)) * 48;
        const sel = (i == state.game_index);
        fb.fillRect(20, y, 200, 40, if (sel) SELECT_BG else BLACK);
        if (sel) fb.drawRect(20, y, 200, 40, ACCENT, 1);
        drawTextSimple(fb, 36, y + 14, names[i], if (sel) ACCENT else GRAY);
    }
}

fn renderTetris(fb: *FB, state: *const AppState, x_off: i16) void {
    if (x_off == 0) {
        const empty = tetris.GameState{};
        tetris.render(fb, &state.tetris, &empty);
    } else fillOffset(fb, x_off, BLACK);
}

fn renderRacer(fb: *FB, state: *const AppState, x_off: i16) void {
    if (x_off == 0) {
        const empty = racer.GameState{};
        racer.render(fb, &state.racer, &empty);
    } else fillOffset(fb, x_off, BLACK);
}

fn renderSettings(fb: *FB, x_off: i16) void {
    blitBg(fb, x_off);
    if (x_off == 0) {
        drawTextSimple(fb, 60, 100, "Settings", WHITE);
        drawTextSimple(fb, 50, 130, "Coming Soon", GRAY);
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn easeOut(t: u16) u16 {
    const inv: u32 = 256 - t;
    return @intCast(256 - (inv * inv / 256));
}

fn blitBg(fb: *FB, x_off: i16) void {
    if (bg_image) |img| {
        if (x_off == 0) {
            fb.blit(0, 0, img);
        } else if (x_off > 0 and x_off < SCREEN_W) {
            fb.fillRect(0, 0, @intCast(x_off), SCREEN_H, BLACK);
            fb.blit(@intCast(x_off), 0, img);
        } else if (x_off < 0 and x_off > -@as(i16, SCREEN_W)) {
            fb.blit(0, 0, img);
            const gx: u16 = @intCast(@as(i16, SCREEN_W) + x_off);
            fb.fillRect(gx, 0, @intCast(-x_off), SCREEN_H, BLACK);
        }
    } else {
        fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK);
    }
}

fn fillOffset(fb: *FB, x_off: i16, color: u16) void {
    if (x_off >= 0 and x_off < SCREEN_W)
        fb.fillRect(@intCast(x_off), 0, SCREEN_W -| @as(u16, @intCast(x_off)), SCREEN_H, color)
    else if (x_off < 0 and x_off > -@as(i16, SCREEN_W))
        fb.fillRect(0, 0, @intCast(@as(i16, SCREEN_W) + x_off), SCREEN_H, color);
}

// Simple 5x7 text (A-Z, a-z, 0-9)
const DIGIT_BMP = [10][7]u8{
    .{0x70,0x88,0x98,0xA8,0xC8,0x88,0x70},.{0x20,0x60,0x20,0x20,0x20,0x20,0x70},
    .{0x70,0x88,0x08,0x10,0x20,0x40,0xF8},.{0x70,0x88,0x08,0x30,0x08,0x88,0x70},
    .{0x10,0x30,0x50,0x90,0xF8,0x10,0x10},.{0xF8,0x80,0xF0,0x08,0x08,0x88,0x70},
    .{0x30,0x40,0x80,0xF0,0x88,0x88,0x70},.{0xF8,0x08,0x10,0x20,0x40,0x40,0x40},
    .{0x70,0x88,0x88,0x70,0x88,0x88,0x70},.{0x70,0x88,0x88,0x78,0x08,0x10,0x60},
};
const LETTER_BMP = [26][7]u8{
    .{0x70,0x88,0x88,0xF8,0x88,0x88,0x88},.{0xF0,0x88,0x88,0xF0,0x88,0x88,0xF0},
    .{0x70,0x88,0x80,0x80,0x80,0x88,0x70},.{0xF0,0x88,0x88,0x88,0x88,0x88,0xF0},
    .{0xF8,0x80,0x80,0xF0,0x80,0x80,0xF8},.{0xF8,0x80,0x80,0xF0,0x80,0x80,0x80},
    .{0x70,0x88,0x80,0xB8,0x88,0x88,0x70},.{0x88,0x88,0x88,0xF8,0x88,0x88,0x88},
    .{0x70,0x20,0x20,0x20,0x20,0x20,0x70},.{0x38,0x10,0x10,0x10,0x10,0x90,0x60},
    .{0x88,0x90,0xA0,0xC0,0xA0,0x90,0x88},.{0x80,0x80,0x80,0x80,0x80,0x80,0xF8},
    .{0x88,0xD8,0xA8,0x88,0x88,0x88,0x88},.{0x88,0xC8,0xA8,0x98,0x88,0x88,0x88},
    .{0x70,0x88,0x88,0x88,0x88,0x88,0x70},.{0xF0,0x88,0x88,0xF0,0x80,0x80,0x80},
    .{0x70,0x88,0x88,0x88,0xA8,0x90,0x68},.{0xF0,0x88,0x88,0xF0,0xA0,0x90,0x88},
    .{0x70,0x88,0x80,0x70,0x08,0x88,0x70},.{0xF8,0x20,0x20,0x20,0x20,0x20,0x20},
    .{0x88,0x88,0x88,0x88,0x88,0x88,0x70},.{0x88,0x88,0x88,0x88,0x50,0x50,0x20},
    .{0x88,0x88,0x88,0x88,0xA8,0xD8,0x88},.{0x88,0x88,0x50,0x20,0x50,0x88,0x88},
    .{0x88,0x88,0x50,0x20,0x20,0x20,0x20},.{0xF8,0x08,0x10,0x20,0x40,0x80,0xF8},
};

pub fn drawTextSimple(fb: *FB, x: u16, y: u16, text: []const u8, color: u16) void {
    var cx = x;
    for (text) |ch| {
        const bmp: ?*const [7]u8 = if (ch >= '0' and ch <= '9') &DIGIT_BMP[ch - '0']
            else if (ch >= 'A' and ch <= 'Z') &LETTER_BMP[ch - 'A']
            else if (ch >= 'a' and ch <= 'z') &LETTER_BMP[ch - 'a']
            else null;
        if (bmp) |b| {
            for (0..7) |r| for (0..5) |c| {
                if (b[r] & (@as(u8, 0x80) >> @intCast(c)) != 0)
                    fb.setPixel(cx + @as(u16, @intCast(c)), y + @as(u16, @intCast(r)), color);
            };
        }
        cx += 6;
    }
}
