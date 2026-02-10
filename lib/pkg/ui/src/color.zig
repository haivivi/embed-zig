//! Color — Zig-native color helpers
//!
//! ```zig
//! const red = ui.color.hex(0xff0000);
//! const blue = ui.color.rgb(0, 0, 255);
//! const white = ui.color.white;
//! const black = ui.color.black;
//! ```

const c = @import("lvgl").c;

pub const Color = c.lv_color_t;

pub fn hex(v: u32) Color {
    return c.lv_color_hex(v);
}

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return c.lv_color_make(r, g, b);
}

pub const white = c.lv_color_hex(0xffffff);
pub const black = c.lv_color_hex(0x000000);
