//! H106 Embedded Assets
//!
//! All PNG images and TTF font embedded at compile time via @embedFile.
//! Uses a C helper (img_helper.h) to create lv_image_dsc_t since
//! lv_image_header_t has bit-fields that Zig can't translate.

const c = @import("lvgl").c;

// Extern C helper (compiled in third_party/lvgl as img_helper.c)
extern fn img_png_src(png_data: [*]const u8, png_size: u32) ?*const anyopaque;

// ============================================================================
// Embedded file data
// ============================================================================

pub const img_bg_data = @embedFile("assets/img_bg.png");
pub const img_ultraman_data = @embedFile("assets/img_ultraman.png");

pub const menu_icon_data = [_][]const u8{
    @embedFile("assets/img_menu_item0.png"),
    @embedFile("assets/img_menu_item1.png"),
    @embedFile("assets/img_menu_item2.png"),
    @embedFile("assets/img_menu_item3.png"),
    @embedFile("assets/img_menu_item4.png"),
};

pub const btn_list_item_data = @embedFile("assets/btn_list_item.png");

pub const setting_icon_data = [_][]const u8{
    @embedFile("assets/listicon_lcd_light.png"),
    @embedFile("assets/listicon_rgb_light.png"),
    @embedFile("assets/listicon_key_prompt.png"),
    @embedFile("assets/listicon_reset.png"),
    @embedFile("assets/listicon_device_info.png"),
    @embedFile("assets/listicon_bind.png"),
    @embedFile("assets/listicon_simcard.png"),
    @embedFile("assets/listicon_version.png"),
    @embedFile("assets/listicon_language.png"),
};

pub const game_icon_data = [_][]const u8{
    @embedFile("assets/icon_game_0.png"),
    @embedFile("assets/icon_game_1.png"),
    @embedFile("assets/icon_game_2.png"),
    @embedFile("assets/icon_game_3.png"),
};

pub const font_noto_sc = @embedFile("assets/NotoSansSC-Bold.ttf");

// ============================================================================
// Image source creation (via C helper, avoids bit-field issue)
// ============================================================================

/// Create an opaque image source from PNG data.
/// The returned pointer can be passed to lv_image_set_src().
pub fn pngSrc(data: []const u8) ?*const anyopaque {
    return img_png_src(data.ptr, @intCast(data.len));
}

// Pre-created sources (initialized on first call)
var _img_bg: ?*const anyopaque = null;
var _img_ultraman: ?*const anyopaque = null;
var _menu_icons: [5]?*const anyopaque = .{null} ** 5;
var _btn_list_item: ?*const anyopaque = null;
var _setting_icons: [9]?*const anyopaque = .{null} ** 9;
var _game_icons: [4]?*const anyopaque = .{null} ** 4;

pub fn imgBg() ?*const anyopaque {
    if (_img_bg == null) _img_bg = pngSrc(img_bg_data);
    return _img_bg;
}

pub fn imgUltraman() ?*const anyopaque {
    if (_img_ultraman == null) _img_ultraman = pngSrc(img_ultraman_data);
    return _img_ultraman;
}

pub fn menuIcon(i: usize) ?*const anyopaque {
    if (i >= 5) return null;
    if (_menu_icons[i] == null) _menu_icons[i] = pngSrc(menu_icon_data[i]);
    return _menu_icons[i];
}

pub fn btnListItem() ?*const anyopaque {
    if (_btn_list_item == null) _btn_list_item = pngSrc(btn_list_item_data);
    return _btn_list_item;
}

pub fn settingIcon(i: usize) ?*const anyopaque {
    if (i >= 9) return null;
    if (_setting_icons[i] == null) _setting_icons[i] = pngSrc(setting_icon_data[i]);
    return _setting_icons[i];
}

pub fn gameIcon(i: usize) ?*const anyopaque {
    if (i >= 4) return null;
    if (_game_icons[i] == null) _game_icons[i] = pngSrc(game_icon_data[i]);
    return _game_icons[i];
}
