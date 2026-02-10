//! H106 Theme — Colors, fonts, styles matching globals_tiga.theme

const c = @import("lvgl").c;
const ui = @import("ui");
const assets = @import("assets.zig");

// ============================================================================
// Colors (from globals_tiga.theme)
// ============================================================================

pub const white: u32 = 0xffffff;
pub const theme_color: u32 = 0x7565d6;
pub const ultraman_red: u32 = 0xe72d30;
pub const grey: u32 = 0xd9d9d9;
pub const dark_grey: u32 = 0x3a3a3a;
pub const medium_grey: u32 = 0x575757;
pub const black: u32 = 0x000000;

// ============================================================================
// Font
// ============================================================================

var font_24: ?*c.lv_font_t = null;
var font_20: ?*c.lv_font_t = null;
var font_16: ?*c.lv_font_t = null;

pub fn getFont24() *const c.lv_font_t {
    return font_24 orelse &c.lv_font_montserrat_20;
}

pub fn getFont20() *const c.lv_font_t {
    return font_20 orelse &c.lv_font_montserrat_16;
}

pub fn getFont16() *const c.lv_font_t {
    return font_16 orelse &c.lv_font_montserrat_14;
}

// ============================================================================
// Init
// ============================================================================

pub fn init() void {
    const data: *const anyopaque = @ptrCast(assets.font_noto_sc.ptr);
    const size: usize = assets.font_noto_sc.len;
    font_24 = c.lv_tiny_ttf_create_data(data, size, 24);
    font_20 = c.lv_tiny_ttf_create_data(data, size, 20);
    font_16 = c.lv_tiny_ttf_create_data(data, size, 16);
}
