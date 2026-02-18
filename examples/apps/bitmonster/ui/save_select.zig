//! SaveSelect — save slot selection page renderer

pub const Species = enum(u8) { flame, tide, thorn, iron, muddy };

pub const PetView = struct {
    alive: bool = true,
    species: Species = .flame,
    health: u8 = 100,
    spirit: u8 = 100,
};

pub const SlotView = struct {
    active: bool = false,
    pet: PetView = .{},
};

pub const SaveSelectState = struct {
    selected_slot: u8 = 0,
    slots: [3]SlotView = [_]SlotView{.{}} ** 3,
};

pub const SaveSelectConfig = struct {
    screen_w: u16 = 320,
    slot_x: u16 = 30,
    slot_w: u16 = 260,
    slot_h: u16 = 60,
    slot_gap: u16 = 16,
    first_slot_y: u16 = 80,
    corner_radius: u8 = 10,
    bg_color: u16 = 0x1082,
    slot_color: u16 = 0x2945,
    sel_color: u16 = 0x4A69,
    accent_color: u16 = 0xFD20,
    border_width: u8 = 2,
};

pub const default_config = SaveSelectConfig{};

pub fn slotRect(index: u8, config: SaveSelectConfig) struct { x: u16, y: u16, w: u16, h: u16 } {
    return .{
        .x = config.slot_x,
        .y = config.first_slot_y + @as(u16, index) * (config.slot_h + config.slot_gap),
        .w = config.slot_w,
        .h = config.slot_h,
    };
}

pub fn speciesColor(species: Species) u16 {
    return switch (species) {
        .flame => 0xF800,
        .tide => 0x001F,
        .thorn => 0x07E0,
        .iron => 0xFFE0,
        .muddy => 0x8410,
    };
}

pub fn renderSlot(fb: anytype, index: u8, slot: *const SlotView, selected: bool, config: SaveSelectConfig) void {
    const rect = slotRect(index, config);
    const bg = if (selected) config.sel_color else config.slot_color;

    fb.fillRoundRect(rect.x, rect.y, rect.w, rect.h, config.corner_radius, bg);

    if (selected) {
        fb.drawRect(rect.x, rect.y, rect.w, rect.h, config.accent_color, config.border_width);
    }

    if (slot.active) {
        const color = speciesColor(slot.pet.species);
        fb.fillRoundRect(rect.x + 14, rect.y + 10, 40, 40, 8, color);

        // Health bar
        const bar_x = rect.x + 70;
        const bar_y = rect.y + 16;
        const bar_w: u16 = 120;
        const hw: u16 = @as(u16, slot.pet.health) * bar_w / 100;
        fb.fillRect(bar_x, bar_y, bar_w, 8, 0x2104);
        fb.fillRect(bar_x, bar_y, hw, 8, 0x07E0);

        // Spirit bar
        const sp_w: u16 = @as(u16, slot.pet.spirit) * bar_w / 100;
        fb.fillRect(bar_x, bar_y + 14, bar_w, 8, 0x2104);
        fb.fillRect(bar_x, bar_y + 14, sp_w, 8, 0x001F);
    }
}

pub fn render(fb: anytype, state: *const SaveSelectState, config: SaveSelectConfig) void {
    fb.fillRect(0, 0, config.screen_w, config.screen_w, config.bg_color);

    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        renderSlot(fb, i, &state.slots[i], i == state.selected_slot, config);
    }
}
