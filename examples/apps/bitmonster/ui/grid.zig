//! Grid — 3x3 icon grid component
//!
//! Renders a 3x3 grid of cells with optional icons and selection highlight.
//! Used for main map and sub-menus.

const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;

pub const GridConfig = struct {
    screen_w: u16 = 320,
    screen_h: u16 = 320,
    margin: u16 = 14,
    cell_size: u16 = 90,
    gap: u16 = 8,
    label_h: u16 = 32,
    corner_radius: u8 = 12,
    bg_color: u16 = 0x2945,
    sel_color: u16 = 0x4A69,
    accent_color: u16 = 0xFD20,
    border_width: u8 = 2,
};

pub const default_config = GridConfig{};

pub fn cellPos(index: u8, config: GridConfig) struct { x: u16, y: u16 } {
    const col = index % 3;
    const row = index / 3;
    return .{
        .x = config.margin + @as(u16, col) * (config.cell_size + config.gap),
        .y = config.margin + @as(u16, row) * (config.cell_size + config.gap),
    };
}

pub fn cellRect(index: u8, config: GridConfig) struct { x: u16, y: u16, w: u16, h: u16 } {
    const pos = cellPos(index, config);
    return .{ .x = pos.x, .y = pos.y, .w = config.cell_size, .h = config.cell_size };
}

pub fn labelRect(config: GridConfig) struct { x: u16, y: u16, w: u16, h: u16 } {
    return .{
        .x = 0,
        .y = config.screen_h - config.label_h,
        .w = config.screen_w,
        .h = config.label_h,
    };
}

pub fn iconOffset(index: u8, icon_w: u8, icon_h: u8, config: GridConfig) struct { x: u16, y: u16 } {
    const pos = cellPos(index, config);
    return .{
        .x = pos.x + (config.cell_size - @as(u16, icon_w)) / 2,
        .y = pos.y + (config.cell_size - @as(u16, icon_h)) / 2 - 2,
    };
}

pub fn renderCell(fb: anytype, index: u8, selected: bool, icon: ?Icon, icon_color: u16, config: GridConfig) void {
    const pos = cellPos(index, config);
    const bg = if (selected) config.sel_color else config.bg_color;

    fb.fillRoundRect(pos.x, pos.y, config.cell_size, config.cell_size, config.corner_radius, bg);

    if (icon) |ic| {
        const ipos = iconOffset(index, ic.width, ic.height, config);
        ic.draw(fb, ipos.x, ipos.y, icon_color);
    }

    if (selected) {
        fb.drawRect(pos.x, pos.y, config.cell_size, config.cell_size, config.accent_color, config.border_width);
    }
}

pub fn renderGrid(fb: anytype, cursor: u8, icons: [9]?Icon, colors: [9]u16, config: GridConfig) void {
    var i: u8 = 0;
    while (i < 9) : (i += 1) {
        renderCell(fb, i, i == cursor, icons[i], colors[i], config);
    }
}
