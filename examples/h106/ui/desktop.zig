//! Desktop — Ultraman splash screen with starry background

const c = @import("lvgl").c;
const theme = @import("../theme.zig");
const header = @import("header.zig");
const assets = @import("../assets.zig");

pub var screen: ?*c.lv_obj_t = null;

pub fn create() void {
    screen = c.lv_obj_create(null);
    if (screen == null) return;
    const scr = screen.?;
    theme.styleScreen(scr);

    // Background image
    if (assets.imgBg()) |src| {
        const bg = c.lv_image_create(scr);
        c.lv_image_set_src(bg, src);
        c.lv_obj_align(bg, c.LV_ALIGN_CENTER, 0, 0);
    }

    // Ultraman character
    if (assets.imgUltraman()) |src| {
        const ultra = c.lv_image_create(scr);
        c.lv_image_set_src(ultra, src);
        c.lv_obj_align(ultra, c.LV_ALIGN_CENTER, 0, 0);
    }

    _ = header.create(scr);
}

pub fn show() void {
    if (screen) |scr| c.lv_screen_load(scr);
}
