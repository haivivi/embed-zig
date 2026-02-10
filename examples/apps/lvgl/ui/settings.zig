//! Settings List — 9-item vertical scrollable list
//!
//! Each item: 224x55, icon (32x32) + label text.
//! Focused item uses btn_list_item.png as background (purple gradient).
//! Matches setting_list.xml design.

const c = @import("lvgl").c;
const theme = @import("../theme.zig");
const assets = @import("../assets.zig");

pub var screen: ?*c.lv_obj_t = null;
var list_items: [9]?*c.lv_obj_t = .{null} ** 9;
pub var index: u8 = 0;

const labels_text = [_][*:0]const u8{
    "\xe5\xb1\x8f\xe5\xb9\x95\xe4\xba\xae\xe5\xba\xa6", // 屏幕亮度
    "\xe6\x8c\x87\xe7\xa4\xba\xe7\x81\xaf\xe4\xba\xae\xe5\xba\xa6", // 指示灯亮度
    "\xe6\x8c\x89\xe9\x94\xae\xe6\x8f\x90\xe7\xa4\xba", // 按键提示
    "\xe9\x87\x8d\xe7\xbd\xae\xe8\xae\xbe\xe5\xa4\x87", // 重置设备
    "\xe8\xae\xbe\xe5\xa4\x87\xe4\xbf\xa1\xe6\x81\xaf", // 设备信息
    "\xe8\xae\xbe\xe5\xa4\x87\xe7\xbb\x91\xe5\xae\x9a", // 设备绑定
    "Sim\xe5\x8d\xa1\xe4\xbf\xa1\xe6\x81\xaf",           // Sim卡信息
    "\xe8\xae\xbe\xe5\xa4\x87\xe7\x89\x88\xe6\x9c\xac", // 设备版本
    "\xe7\xb3\xbb\xe7\xbb\x9f\xe8\xaf\xad\xe8\xa8\x80", // 系统语言
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

    // Scrollable list container
    const list = c.lv_obj_create(scr) orelse return;
    c.lv_obj_set_size(list, 224, 240);
    c.lv_obj_align(list, c.LV_ALIGN_CENTER, 0, 0);
    theme.styleTransparent(list);
    c.lv_obj_set_flex_flow(list, c.LV_FLEX_FLOW_COLUMN);
    c.lv_obj_set_style_pad_row(list, 4, 0);
    c.lv_obj_set_style_pad_top(list, 8, 0);
    c.lv_obj_set_scrollbar_mode(list, c.LV_SCROLLBAR_MODE_OFF);

    // Create items
    for (0..labels_text.len) |i| {
        const item = c.lv_obj_create(list) orelse continue;
        c.lv_obj_set_size(item, 224, 55);
        c.lv_obj_set_style_radius(item, 4, 0);
        c.lv_obj_set_style_border_width(item, 0, 0);
        c.lv_obj_set_scrollbar_mode(item, c.LV_SCROLLBAR_MODE_OFF);
        c.lv_obj_set_flex_flow(item, c.LV_FLEX_FLOW_ROW);
        c.lv_obj_set_style_flex_cross_place(item, c.LV_FLEX_ALIGN_CENTER, 0);
        c.lv_obj_set_style_pad_left(item, 16, 0);
        c.lv_obj_set_style_pad_column(item, 16, 0);
        c.lv_obj_set_style_pad_ver(item, 8, 0);
        c.lv_obj_set_style_bg_color(item, c.lv_color_hex(theme.black), 0);

        // Icon
        if (assets.settingIcon(i)) |src| {
            const icon = c.lv_image_create(item);
            c.lv_image_set_src(icon, src);
        }

        // Label
        const lbl = c.lv_label_create(item);
        c.lv_label_set_text(lbl, labels_text[i]);
        theme.styleText(lbl, theme.getFont20());

        list_items[i] = item;
    }

    index = 0;
    updateFocus();
}

pub fn updateFocus() void {
    for (0..labels_text.len) |i| {
        if (list_items[i]) |item| {
            if (i == index) {
                // Focused: purple gradient (use bg image if available, else solid)
                c.lv_obj_set_style_bg_image_src(item, assets.btnListItem(), 0);
                c.lv_obj_set_style_bg_opa(item, 0, 0);
                // Scroll into view
                c.lv_obj_scroll_to_view(item, c.LV_ANIM_ON);
            } else {
                c.lv_obj_set_style_bg_image_src(item, @as(?*const anyopaque, null), 0);
                c.lv_obj_set_style_bg_opa(item, c.LV_OPA_COVER, 0);
            }
        }
    }
}

pub fn scrollUp() void {
    if (index > 0) {
        index -= 1;
        updateFocus();
    }
}

pub fn scrollDown() void {
    if (index < labels_text.len - 1) {
        index += 1;
        updateFocus();
    }
}

pub fn show() void {
    if (screen) |scr| c.lv_screen_load_anim(scr, c.LV_SCR_LOAD_ANIM_MOVE_LEFT, 200, 0, false);
}
