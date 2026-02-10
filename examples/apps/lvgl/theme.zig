//! H106 Theme — Colors, fonts, styles matching globals_tiga.theme

const c = @import("lvgl").c;
const assets = @import("assets.zig");

// ============================================================================
// Colors (from globals_tiga.theme)
// ============================================================================

pub const white = 0xffffff;
pub const theme_color = 0x7565d6;
pub const ultraman_red = 0xe72d30;
pub const grey = 0xd9d9d9;
pub const dark_grey = 0x3a3a3a;
pub const medium_grey = 0x575757;
pub const disable = 0x8d8d8d;
pub const black = 0x000000;

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
    // Load TTF fonts from embedded data (NotoSansSC-Bold for Chinese)
    const data: *const anyopaque = @ptrCast(assets.font_noto_sc.ptr);
    const size: usize = assets.font_noto_sc.len;
    font_24 = c.lv_tiny_ttf_create_data(data, size, 24);
    font_20 = c.lv_tiny_ttf_create_data(data, size, 20);
    font_16 = c.lv_tiny_ttf_create_data(data, size, 16);
}

// ============================================================================
// Style Helpers
// ============================================================================

/// Style a screen as full-screen with no padding/border
pub fn styleScreen(opt: ?*c.lv_obj_t) void {
    const obj = opt orelse return;
    c.lv_obj_set_style_bg_opa(obj, c.LV_OPA_COVER, 0);
    c.lv_obj_set_style_bg_color(obj, c.lv_color_hex(black), 0);
    c.lv_obj_set_style_border_width(obj, 0, 0);
    c.lv_obj_set_style_pad_all(obj, 0, 0);
    c.lv_obj_set_style_radius(obj, 0, 0);
    c.lv_obj_set_scrollbar_mode(obj, c.LV_SCROLLBAR_MODE_OFF);
}

/// Style an object as transparent container
pub fn styleTransparent(opt: ?*c.lv_obj_t) void {
    const obj = opt orelse return;
    c.lv_obj_set_style_bg_opa(obj, 0, 0);
    c.lv_obj_set_style_border_width(obj, 0, 0);
    c.lv_obj_set_style_radius(obj, 0, 0);
    c.lv_obj_set_style_pad_all(obj, 0, 0);
    c.lv_obj_set_scrollbar_mode(obj, c.LV_SCROLLBAR_MODE_OFF);
}

/// Set white text with the given font
pub fn styleText(opt: ?*c.lv_obj_t, font: *const c.lv_font_t) void {
    const obj = opt orelse return;
    c.lv_obj_set_style_text_color(obj, c.lv_color_hex(white), 0);
    c.lv_obj_set_style_text_font(obj, font, 0);
}
