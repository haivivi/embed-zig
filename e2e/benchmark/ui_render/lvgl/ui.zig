//! LVGL-based UI renderer for benchmark
//!
//! Same UI as the Compositor version, built with LVGL widgets.
//! Uses the lvgl_flux SyncEngine to map state changes to widget updates.

const ui = @import("ui");
const lvgl_flux = @import("lvgl_flux");
const SyncEngine = lvgl_flux.SyncEngine;
const ViewBinding = lvgl_flux.ViewBinding;

const app = @import("state");
const State = app.State;

// ============================================================================
// Widget handles (created once at init, updated via sync)
// ============================================================================

pub const View = struct {
    // Status bar
    status_bar: ui.Obj = undefined,
    time_label: ui.Label = undefined,
    battery_bar: ui.Bar = undefined,
    wifi_icon: ui.Obj = undefined,

    // Menu page
    menu_panel: ui.Obj = undefined,
    menu_items: [5]ui.Obj = undefined,
    menu_labels: [5]ui.Label = undefined,

    // Settings page
    settings_panel: ui.Obj = undefined,
    brightness_label: ui.Label = undefined,
    brightness_bar: ui.Bar = undefined,
    volume_label: ui.Label = undefined,
    volume_bar: ui.Bar = undefined,

    // Game page
    game_panel: ui.Obj = undefined,
    hud_bar: ui.Obj = undefined,
    score_label: ui.Label = undefined,
    player: ui.Obj = undefined,
    obstacles: [3]ui.Obj = undefined,
    road: ui.Obj = undefined,

    pub fn init(screen: ui.Obj) View {
        var self: View = .{};

        // Status bar
        self.status_bar = ui.Obj.create(screen.raw()).?
            .size(240, 20).pos(0, 0).bgColor(0x202020);

        self.time_label = ui.Label.create(self.status_bar).?
            .text("12:30").setAlign(.left_mid, 8, 0).color(0xFFFFFF);

        self.wifi_icon = ui.Obj.create(self.status_bar).?
            .size(8, 8).setAlign(.right_mid, -44, 0).bgColor(0x00FF00);

        self.battery_bar = ui.Bar.create(self.status_bar).?
            .size(30, 8).setAlign(.right_mid, -8, 0)
            .range(0, 100).value(80);

        // Menu panel
        self.menu_panel = ui.Obj.create(screen.raw()).?
            .size(240, 216).pos(0, 24).bgColor(0x000000);

        for (0..5) |i| {
            const y: i32 = 6 + @as(i32, @intCast(i)) * 42;
            self.menu_items[i] = ui.Obj.create(self.menu_panel.raw()).?
                .size(220, 38).pos(10, y)
                .bgColor(if (i == 0) 0xF80000 else 0x181818);

            self.menu_labels[i] = ui.Label.create(self.menu_items[i].raw()).?
                .text("Menu Item").center().color(0xFFFFFF);
        }

        // Settings panel (hidden by default)
        self.settings_panel = ui.Obj.create(screen.raw()).?
            .size(240, 216).pos(0, 24).bgColor(0x000000).hide();

        _ = ui.Label.create(self.settings_panel.raw()).?
            .text("Settings").setAlign(.top_left, 10, 6).color(0xFFFFFF);

        self.brightness_label = ui.Label.create(self.settings_panel.raw()).?
            .text("Brightness").setAlign(.top_left, 10, 26).color(0xFFFFFF);
        self.brightness_bar = ui.Bar.create(self.settings_panel.raw()).?
            .size(100, 6).pos(120, 28).range(0, 255).value(128);

        self.volume_label = ui.Label.create(self.settings_panel.raw()).?
            .text("Volume").setAlign(.top_left, 10, 46).color(0xFFFFFF);
        self.volume_bar = ui.Bar.create(self.settings_panel.raw()).?
            .size(100, 6).pos(120, 48).range(0, 255).value(200);

        // Game panel (hidden by default)
        self.game_panel = ui.Obj.create(screen.raw()).?
            .size(240, 240).pos(0, 0).bgColor(0x000000).hide();

        self.hud_bar = ui.Obj.create(self.game_panel.raw()).?
            .size(240, 20).pos(0, 0).bgColor(0x202020);

        self.score_label = ui.Label.create(self.hud_bar.raw()).?
            .text("Score: 0").setAlign(.left_mid, 8, 0).color(0xFFFFFF);

        self.road = ui.Obj.create(self.game_panel.raw()).?
            .size(160, 160).pos(40, 20).bgColor(0x404040);

        self.player = ui.Obj.create(self.game_panel.raw()).?
            .size(30, 45).pos(110, 180).bgColor(0xF80000);

        for (0..3) |i| {
            const x: i32 = switch (i) { 0 => 60, 1 => 120, else => 90 };
            const y: i32 = @as(i32, @intCast([_]u16{ 50, 100, 150 }[i]));
            self.obstacles[i] = ui.Obj.create(self.game_panel.raw()).?
                .size(25, 35).pos(x, y).bgColor(0x00F800);
        }

        return self;
    }

    pub fn sync(self: *View, state: *const State, prev: *const State) void {
        // Page visibility
        if (state.page != prev.page) {
            self.menu_panel.setHidden(state.page != .menu);
            self.settings_panel.setHidden(state.page != .settings);
            self.game_panel.setHidden(state.page != .game);
            self.status_bar.setHidden(state.page == .game);
        }

        // Status bar
        if (state.time_hour != prev.time_hour or state.time_min != prev.time_min) {
            // In real code: format time string and set label
            self.time_label.text("12:31");
        }
        if (state.battery != prev.battery) {
            self.battery_bar.value(@intCast(state.battery));
        }
        if (state.wifi != prev.wifi) {
            self.wifi_icon.setHidden(!state.wifi);
        }

        // Menu selection
        if (state.page == .menu and state.selected != prev.selected) {
            self.menu_items[prev.selected].bgColor(0x181818);
            self.menu_items[state.selected].bgColor(0xF80000);
        }

        // Settings
        if (state.page == .settings) {
            if (state.brightness != prev.brightness) {
                self.brightness_bar.value(@intCast(state.brightness));
            }
            if (state.volume != prev.volume) {
                self.volume_bar.value(@intCast(state.volume));
            }
        }

        // Game
        if (state.page == .game) {
            if (state.score != prev.score) {
                self.score_label.text("Score: ...");
            }
            if (state.player_x != prev.player_x) {
                _ = self.player.pos(@intCast(state.player_x), 180);
            }
            for (0..3) |i| {
                if (state.obs_y[i] != prev.obs_y[i]) {
                    const x: i32 = switch (i) { 0 => 60, 1 => 120, else => 90 };
                    _ = self.obstacles[i].pos(x, @intCast(state.obs_y[i]));
                }
            }
        }
    }
};
