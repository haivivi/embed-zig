//! Compositor-based UI renderer for benchmark
//!
//! Same UI as the LVGL version, built with Framebuffer + Compositor.

const ui_state = @import("ui_state");
const Framebuffer = ui_state.Framebuffer;
const Compositor = ui_state.Compositor;
const Rect = ui_state.Rect;
const BitmapFont = ui_state.BitmapFont;

const app = @import("../state.zig");
const State = app.State;

pub const FB = Framebuffer(app.SCREEN_W, app.SCREEN_H, .rgb565);

const BLACK: u16 = 0x0000;
const WHITE: u16 = 0xFFFF;
const DARK_GRAY: u16 = 0x2104;
const MID_GRAY: u16 = 0x4208;
const RED: u16 = 0xF800;
const GREEN: u16 = 0x07E0;
const BLUE: u16 = 0x001F;
const MENU_BG: u16 = 0x18E3;

// ============================================================================
// Components
// ============================================================================

pub const StatusTime = struct {
    const bg: u16 = DARK_GRAY;
    pub fn bounds(_: *const State) Rect {
        return .{ .x = 0, .y = 0, .w = 80, .h = 20 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        return s.time_hour != p.time_hour or s.time_min != p.time_min;
    }
    pub fn draw(fb: *FB, _: *const State) void {
        fb.fillRect(0, 0, 80, 20, DARK_GRAY);
        fb.fillRect(8, 6, 48, 8, WHITE);
    }
};

pub const StatusBattery = struct {
    const bg: u16 = DARK_GRAY;
    pub fn bounds(_: *const State) Rect {
        return .{ .x = 200, .y = 0, .w = 40, .h = 20 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        return s.battery != p.battery;
    }
    pub fn draw(fb: *FB, s: *const State) void {
        fb.fillRect(200, 0, 40, 20, DARK_GRAY);
        fb.fillRect(206, 6, 30, 8, MID_GRAY);
        const w: u16 = @as(u16, s.battery) * 30 / 100;
        fb.fillRect(206, 6, w, 8, if (s.battery > 20) GREEN else RED);
    }
};

pub const StatusWifi = struct {
    const bg: u16 = DARK_GRAY;
    pub fn bounds(_: *const State) Rect {
        return .{ .x = 184, .y = 6, .w = 12, .h = 12 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        return s.wifi != p.wifi;
    }
    pub fn draw(fb: *FB, s: *const State) void {
        fb.fillRect(184, 6, 12, 12, DARK_GRAY);
        if (s.wifi) fb.fillRect(188, 8, 4, 4, GREEN);
    }
};

pub const MenuContent = struct {
    const bg: u16 = BLACK;
    pub fn bounds(s: *const State) Rect {
        _ = s;
        return .{ .x = 0, .y = 24, .w = 240, .h = 216 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        return s.page != p.page or (s.page == .menu and s.selected != p.selected);
    }
    pub fn draw(fb: *FB, s: *const State) void {
        if (s.page != .menu) return;
        fb.fillRect(0, 24, 240, 216, BLACK);
        var i: u8 = 0;
        while (i < 5) : (i += 1) {
            const y: u16 = 30 + @as(u16, i) * 42;
            const color = if (i == s.selected) RED else MENU_BG;
            fb.fillRoundRect(10, y, 220, 38, 8, color);
            fb.fillRect(20, y + 14, 60, 8, WHITE);
        }
    }
};

pub const SettingsContent = struct {
    const bg: u16 = BLACK;
    pub fn bounds(_: *const State) Rect {
        return .{ .x = 0, .y = 24, .w = 240, .h = 216 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        return s.page != p.page or
            (s.page == .settings and (s.brightness != p.brightness or s.volume != p.volume));
    }
    pub fn draw(fb: *FB, s: *const State) void {
        if (s.page != .settings) return;
        fb.fillRect(0, 24, 240, 216, BLACK);
        fb.fillRect(10, 30, 80, 8, WHITE); // "Settings" label
        // Brightness bar
        fb.fillRect(10, 50, 80, 8, WHITE); // label
        fb.fillRect(120, 52, 100, 6, MID_GRAY);
        fb.fillRect(120, 52, @as(u16, s.brightness) * 100 / 255, 6, GREEN);
        // Volume bar
        fb.fillRect(10, 70, 60, 8, WHITE); // label
        fb.fillRect(120, 72, 100, 6, MID_GRAY);
        fb.fillRect(120, 72, @as(u16, s.volume) * 100 / 255, 6, BLUE);
    }
};

pub const GameHud = struct {
    const bg: u16 = DARK_GRAY;
    pub fn bounds(_: *const State) Rect {
        return .{ .x = 0, .y = 0, .w = 240, .h = 20 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        return s.page != p.page or (s.page == .game and s.score != p.score);
    }
    pub fn draw(fb: *FB, s: *const State) void {
        if (s.page != .game) return;
        fb.fillRect(0, 0, 240, 20, DARK_GRAY);
        fb.fillRect(8, 4, 60, 12, WHITE);
    }
};

pub const GamePlayer = struct {
    const bg: u16 = MID_GRAY;
    pub fn bounds(s: *const State) Rect {
        return .{ .x = s.player_x, .y = 180, .w = 30, .h = 45 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        if (s.page != .game) return false;
        return s.player_x != p.player_x or !eqlU16x3(s.obs_y, p.obs_y);
    }
    pub fn draw(fb: *FB, s: *const State) void {
        if (s.page != .game) return;
        fb.fillRoundRect(s.player_x, 180, 30, 45, 5, RED);
    }
};

pub const GameObstacles = struct {
    const bg: u16 = BLACK;
    pub fn bounds(_: *const State) Rect {
        return .{ .x = 40, .y = 20, .w = 160, .h = 220 };
    }
    pub fn changed(s: *const State, p: *const State) bool {
        return s.page == .game and !eqlU16x3(s.obs_y, p.obs_y);
    }
    pub fn draw(fb: *FB, s: *const State) void {
        if (s.page != .game) return;
        fb.fillRect(40, 20, 160, 220, MID_GRAY); // road (below HUD)
        for (s.obs_y, 0..) |y, i| {
            if (y + 35 <= 20) continue;
            const x: u16 = switch (i) { 0 => 60, 1 => 120, else => 90 };
            const oy: u16 = @max(y, 20);
            const oh: u16 = if (y < 20) 35 - (20 - y) else 35;
            fb.fillRoundRect(x, oy, 25, oh, 4, GREEN);
        }
    }
};

fn eqlU16x3(a: [3]u16, b: [3]u16) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

// Menu page compositor
pub const MenuScene = Compositor(FB, State, .{ StatusTime, StatusBattery, StatusWifi, MenuContent });

// Settings page compositor
pub const SettingsScene = Compositor(FB, State, .{ StatusTime, StatusBattery, StatusWifi, SettingsContent });

// Game page compositor (no status bar — HUD instead)
pub const GameScene = Compositor(FB, State, .{ GameObstacles, GamePlayer, GameHud });

// ============================================================================
// Public render — dispatches to page-specific compositor
// ============================================================================

pub fn render(fb: *FB, state: *const State, prev: *const State) u8 {
    const first_frame = state.page != prev.page;
    if (first_frame) fb.clear(0x0000);
    return switch (state.page) {
        .menu => MenuScene.render(fb, state, prev, first_frame),
        .settings => SettingsScene.render(fb, state, prev, first_frame),
        .game => GameScene.render(fb, state, prev, first_frame),
    };
}
