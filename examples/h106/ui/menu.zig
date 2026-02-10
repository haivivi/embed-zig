//! Menu Carousel — 5-item horizontal scroll with PNG icons
//!
//! Items: Team(0), AwakenX(1), Contact(2), Points(3), Settings(4)

const c = @import("lvgl").c;
const theme = @import("../theme.zig");
const header = @import("header.zig");
const assets = @import("../assets.zig");

pub var screen: ?*c.lv_obj_t = null;
var carousel: ?*c.lv_obj_t = null;
var items: [5]?*c.lv_obj_t = .{null} ** 5;
var labels: [5]?*c.lv_obj_t = .{null} ** 5;
var dots: [5]?*c.lv_obj_t = .{null} ** 5;
pub var index: u8 = 0;

const menu_titles = [_][*:0]const u8{
    "\xe5\xa5\xa5\xe7\x89\xb9\xe9\x9b\x86\xe7\xbb\x93", // 奥特集结
    "\xe8\xb6\x85\xe8\x83\xbd\xe9\xa9\xaf\xe5\x8c\x96", // 超能驯化
    "\xe5\xae\x88\xe6\x8a\xa4\xe8\x81\x94\xe7\xbb\x9c", // 守护联络
    "\xe7\xa7\xaf\xe5\x88\x86",                           // 积分
    "\xe8\xae\xbe\xe7\xbd\xae",                           // 设置
};

pub fn create() void {
    screen = c.lv_obj_create(null);
    if (screen == null) return;
    const scr = screen.?;
    theme.styleScreen(scr);

    // Background
    if (assets.imgBg()) |src| {
        const bg = c.lv_image_create(scr);
        c.lv_image_set_src(bg, src);
    }

    // Carousel container
    carousel = c.lv_obj_create(scr);
    if (carousel) |car| {
        c.lv_obj_set_size(car, 240, 200);
        c.lv_obj_align(car, c.LV_ALIGN_TOP_MID, 0, 10);
        theme.styleTransparent(car);
        c.lv_obj_set_flex_flow(car, c.LV_FLEX_FLOW_ROW);
        c.lv_obj_set_style_pad_column(car, 0, 0);
        c.lv_obj_set_scroll_snap_x(car, c.LV_SCROLL_SNAP_CENTER);
        c.lv_obj_set_scrollbar_mode(car, c.LV_SCROLLBAR_MODE_OFF);

        for (0..5) |i| {
            const item = c.lv_obj_create(car) orelse continue;
            c.lv_obj_set_size(item, 240, 200);
            theme.styleTransparent(item);

            // Icon image
            if (assets.menuIcon(i)) |src| {
                const icon = c.lv_image_create(item);
                c.lv_image_set_src(icon, src);
                c.lv_obj_align(icon, c.LV_ALIGN_CENTER, 0, -10);
            }

            items[i] = item;
        }
    }

    // Title labels
    for (0..5) |i| {
        const lbl = c.lv_label_create(scr) orelse continue;
        c.lv_label_set_text(lbl, menu_titles[i]);
        theme.styleText(lbl, theme.getFont24());
        c.lv_obj_align(lbl, c.LV_ALIGN_BOTTOM_MID, 0, -35);
        if (i != 0) c.lv_obj_add_flag(lbl, c.LV_OBJ_FLAG_HIDDEN);
        labels[i] = lbl;
    }

    // Dot indicators
    const dot_row = c.lv_obj_create(scr) orelse return;
    c.lv_obj_set_size(dot_row, 240, 16);
    c.lv_obj_align(dot_row, c.LV_ALIGN_BOTTOM_MID, 0, -8);
    theme.styleTransparent(dot_row);
    c.lv_obj_set_flex_flow(dot_row, c.LV_FLEX_FLOW_ROW);
    c.lv_obj_set_style_flex_main_place(dot_row, c.LV_FLEX_ALIGN_CENTER, 0);
    c.lv_obj_set_style_flex_cross_place(dot_row, c.LV_FLEX_ALIGN_CENTER, 0);
    c.lv_obj_set_style_pad_column(dot_row, 10, 0);

    for (0..5) |i| {
        const dot = c.lv_obj_create(dot_row) orelse continue;
        c.lv_obj_set_scrollbar_mode(dot, c.LV_SCROLLBAR_MODE_OFF);
        c.lv_obj_set_style_border_width(dot, 0, 0);
        c.lv_obj_set_style_bg_color(dot, c.lv_color_hex(theme.white), 0);
        if (i == 0) {
            c.lv_obj_set_size(dot, 24, 12);
            c.lv_obj_set_style_radius(dot, 6, 0);
            c.lv_obj_set_style_bg_opa(dot, 255, 0);
        } else {
            c.lv_obj_set_size(dot, 12, 12);
            c.lv_obj_set_style_radius(dot, 6, 0);
            c.lv_obj_set_style_bg_opa(dot, 125, 0);
        }
        dots[i] = dot;
    }

    _ = header.create(scr);
    index = 0;
}

pub fn scrollTo(new_index: u8) void {
    if (new_index >= 5) return;
    const old = index;
    index = new_index;

    if (labels[old]) |l| c.lv_obj_add_flag(l, c.LV_OBJ_FLAG_HIDDEN);
    if (labels[index]) |l| c.lv_obj_clear_flag(l, c.LV_OBJ_FLAG_HIDDEN);

    for (0..5) |i| {
        if (dots[i]) |dot| {
            if (i == index) {
                c.lv_obj_set_size(dot, 24, 12);
                c.lv_obj_set_style_bg_opa(dot, 255, 0);
            } else {
                c.lv_obj_set_size(dot, 12, 12);
                c.lv_obj_set_style_bg_opa(dot, 125, 0);
            }
        }
    }

    if (carousel != null and items[index] != null) {
        c.lv_obj_scroll_to_view(items[index].?, c.LV_ANIM_ON);
    }
}

pub fn show() void {
    if (screen) |scr| c.lv_screen_load(scr);
}

pub fn showAnim(from_left: bool) void {
    if (screen) |scr| {
        const anim: c.lv_screen_load_anim_t = if (from_left) c.LV_SCR_LOAD_ANIM_MOVE_RIGHT else c.LV_SCR_LOAD_ANIM_MOVE_LEFT;
        c.lv_screen_load_anim(scr, anim, 200, 0, false);
    }
}
