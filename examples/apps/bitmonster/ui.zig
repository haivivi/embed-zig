//! BitMonster — UI Rendering (uses ui/ sub-modules)

const ui_state = @import("ui_state");
const Framebuffer = ui_state.Framebuffer;
pub const TtfFont = ui_state.TtfFont;

const state_mod = @import("state/state.zig");
const AppState = state_mod.AppState;

const icon_mod = @import("ui/icon.zig");
pub const Icon = icon_mod.Icon;
const grid = @import("ui/grid.zig");
const save_select_ui = @import("ui/save_select.zig");

pub const SCREEN_W: u16 = 320;
pub const SCREEN_H: u16 = 320;
pub const FB = Framebuffer(SCREEN_W, SCREEN_H, .rgb565);

// Resources (set by app.zig at init)
pub var font_20: ?*TtfFont = null;
pub var font_16: ?*TtfFont = null;
pub var map_icons: [9]?Icon = .{null} ** 9;
pub var back_icon: ?Icon = null;

const BLACK: u16 = 0x0000;
const WHITE: u16 = 0xFFFF;
const DARK_BG: u16 = 0x1082;
const ACCENT: u16 = 0xFD20;
const TEXT_DIM: u16 = 0x7BEF;

const place_colors = [9]u16{
    0x4208, // home
    0xFD20, // diner
    0x001F, // school
    0xF800, // clinic
    0x07E0, // pet
    0xFFE0, // gym
    0xF81F, // arcade
    0x07FF, // lucky
    0xBDF7, // shop
};

const place_names_en = [9][]const u8{
    "Home", "Diner", "School", "Clinic", "Pet", "Gym", "Arcade", "Lucky", "Shop",
};

const grid_config = grid.GridConfig{};

pub fn render(fb: *FB, state: *const AppState, prev: ?*const AppState) void {
    if (prev) |p| {
        if (p.page != state.page) {
            renderFull(fb, state);
            return;
        }
    } else {
        renderFull(fb, state);
        return;
    }

    const p = prev.?;
    switch (state.page) {
        .save_select => {
            if (state.selected_slot != p.selected_slot) renderSaveSelect(fb, state);
        },
        .main_map => {
            if (state.grid_cursor != p.grid_cursor) {
                renderGridCell(fb, p.grid_cursor, false);
                renderGridCell(fb, state.grid_cursor, true);
                renderBottomLabel(fb, state.grid_cursor);
            }
        },
        .new_game => {
            if (state.new_game_species != p.new_game_species) renderNewGame(fb, state);
        },
        .place => renderPlaceFull(fb, state),
        else => {},
    }
}

fn renderFull(fb: *FB, state: *const AppState) void {
    switch (state.page) {
        .save_select => renderSaveSelect(fb, state),
        .main_map => renderMainMap(fb, state),
        .new_game => renderNewGame(fb, state),
        .place => renderPlaceFull(fb, state),
        else => fb.fillRect(0, 0, SCREEN_W, SCREEN_H, BLACK),
    }
}

// ============================================================================
// Save Select
// ============================================================================

fn renderSaveSelect(fb: *FB, state: *const AppState) void {
    // Convert AppState saves to SlotViews
    var sv = save_select_ui.SaveSelectState{};
    sv.selected_slot = state.selected_slot;
    for (0..3) |i| {
        if (state.saves[i].active) {
            sv.slots[i] = .{
                .active = true,
                .pet = .{
                    .species = @enumFromInt(@intFromEnum(state.saves[i].pet.species)),
                    .health = state.saves[i].pet.health,
                    .spirit = state.saves[i].pet.spirit,
                },
            };
        }
    }
    save_select_ui.render(fb, &sv, save_select_ui.default_config);

    // Title text
    if (font_20) |f| {
        const title = "BitMonster";
        const tw = f.textWidth(title);
        fb.drawTextTtf((SCREEN_W -| tw) / 2, 24, title, f, ACCENT);
    }

    // Slot labels
    if (font_16) |f| {
        for (0..3) |i| {
            const rect = save_select_ui.slotRect(@intCast(i), save_select_ui.default_config);
            if (state.saves[i].active) {
                const name = state.saves[i].pet.getName();
                fb.drawTextTtf(rect.x + 70, rect.y + 38, name, f, TEXT_DIM);
            } else {
                fb.drawTextTtf(rect.x + 80, rect.y + 20, "New Game", f, TEXT_DIM);
            }
        }
    }
}

// ============================================================================
// New Game (species selection)
// ============================================================================

fn renderNewGame(fb: *FB, state: *const AppState) void {
    fb.fillRect(0, 0, SCREEN_W, SCREEN_H, DARK_BG);

    if (font_20) |f| {
        const title = "Choose Your Pet";
        const tw = f.textWidth(title);
        fb.drawTextTtf((SCREEN_W -| tw) / 2, 20, title, f, WHITE);
    }

    const species_colors = [5]u16{ 0xF800, 0x001F, 0x07E0, 0xFFE0, 0x8410 };
    const species_names = [5][]const u8{ "Flame", "Tide", "Thorn", "Iron", "Muddy" };

    for (0..5) |i| {
        const x: u16 = 20 + @as(u16, @intCast(i)) * 58;
        const selected = (i == state.new_game_species);
        const bg: u16 = if (selected) 0x4A69 else 0x2945;
        fb.fillRoundRect(x, 80, 52, 52, 10, bg);
        fb.fillRoundRect(x + 10, 90, 32, 32, 6, species_colors[i]);
        if (selected) fb.drawRect(x, 80, 52, 52, ACCENT, 2);

        if (font_16) |f| {
            const name = species_names[i];
            const tw = f.textWidth(name);
            fb.drawTextTtf(x + (52 -| tw) / 2, 140, name, f, if (selected) WHITE else TEXT_DIM);
        }
    }
}

// ============================================================================
// Main Map
// ============================================================================

fn renderMainMap(fb: *FB, state: *const AppState) void {
    fb.fillRect(0, 0, SCREEN_W, SCREEN_H, DARK_BG);

    var i: u8 = 0;
    while (i < 9) : (i += 1) {
        renderGridCell(fb, i, i == state.grid_cursor);
    }
    renderBottomLabel(fb, state.grid_cursor);
}

fn renderGridCell(fb: *FB, index: u8, selected: bool) void {
    grid.renderCell(fb, index, selected, map_icons[index], place_colors[index], grid_config);
}

fn renderBottomLabel(fb: *FB, cursor: u8) void {
    const lr = grid.labelRect(grid_config);
    fb.fillRect(lr.x, lr.y, lr.w, lr.h, DARK_BG);

    if (font_20) |f| {
        const name = place_names_en[cursor];
        const tw = f.textWidth(name);
        fb.drawTextTtf((SCREEN_W -| tw) / 2, lr.y + 4, name, f, WHITE);
    } else {
        fb.fillRoundRect(120, lr.y + 8, 80, 16, 4, place_colors[cursor]);
    }
}

// ============================================================================
// Place (stub)
// ============================================================================

fn renderPlaceFull(fb: *FB, state: *const AppState) void {
    fb.fillRect(0, 0, SCREEN_W, SCREEN_H, DARK_BG);

    const idx = @intFromEnum(state.current_place);
    fb.fillRoundRect(20, 8, 32, 32, 6, place_colors[idx]);

    if (font_20) |f| {
        fb.drawTextTtf(60, 12, place_names_en[idx], f, WHITE);
    }

    // Back hint
    if (font_16) |f| {
        fb.drawTextTtf(SCREEN_W - 60, 14, "Back", f, TEXT_DIM);
    }

    // Placeholder content
    fb.fillRoundRect(20, 60, SCREEN_W - 40, 200, 10, 0x2945);
}
