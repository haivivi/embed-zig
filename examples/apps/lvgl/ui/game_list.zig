//! Game List — 4-game vertical list

const c = @import("lvgl").c;
const theme = @import("../theme.zig");
const assets = @import("../assets.zig");

pub var screen: ?*c.lv_obj_t = null;
var list_items: [4]?*c.lv_obj_t = .{null} ** 4;
pub var index: u8 = 0;

const labels_text = [_][*:0]const u8{
    "\xe7\x82\xbd\xe7\x84\xb0\xe8\xb7\x83\xe5\x8a\xa8", // 炽焰跃动
    "\xe6\xb7\xb1\xe6\xb8\x8a\xe5\xbe\x81\xe9\x80\x94", // 深渊征途
    "\xe8\xb6\x85\xe8\x83\xbd\xe5\x8f\x8d\xe5\x87\xbb", // 超能反击
    "\xe9\x87\x8f\xe5\xad\x90\xe6\x96\xb9\xe5\x9f\x9f", // 量子方域
};

pub fn create() void {
    screen = c.lv_obj_create(null);
    if (screen == null) return;
    const scr = screen.?;
    theme.styleScreen(scr);

    if (assets.imgBg()) |src| {
        const bg = c.lv_image_create(scr);
        c.lv_image_set_src(bg, src);
    }

    const list = c.lv_obj_create(scr) orelse return;
    c.lv_obj_set_size(list, 224, 240);
    c.lv_obj_align(list, c.LV_ALIGN_CENTER, 0, 0);
    theme.styleTransparent(list);
    c.lv_obj_set_flex_flow(list, c.LV_FLEX_FLOW_COLUMN);
    c.lv_obj_set_style_pad_row(list, 4, 0);
    c.lv_obj_set_style_pad_top(list, 20, 0);
    c.lv_obj_set_style_flex_main_place(list, c.LV_FLEX_ALIGN_CENTER, 0);

    for (0..labels_text.len) |i| {
        const item = c.lv_obj_create(list) orelse continue;
        c.lv_obj_set_size(item, 224, 55);
        c.lv_obj_set_style_radius(item, 4, 0);
        c.lv_obj_set_style_border_width(item, 0, 0);
        c.lv_obj_set_scrollbar_mode(item, c.LV_SCROLLBAR_MODE_OFF);
        c.lv_obj_set_flex_flow(item, c.LV_FLEX_FLOW_ROW);
        c.lv_obj_set_style_flex_cross_place(item, c.LV_FLEX_ALIGN_CENTER, 0);
        c.lv_obj_set_style_pad_left(item, 16, 0);
        c.lv_obj_set_style_pad_column(item, 12, 0);
        c.lv_obj_set_style_pad_ver(item, 8, 0);
        c.lv_obj_set_style_bg_color(item, c.lv_color_hex(theme.black), 0);

        if (assets.gameIcon(i)) |src| {
            const icon = c.lv_image_create(item);
            c.lv_image_set_src(icon, src);
        }

        const lbl = c.lv_label_create(item);
        c.lv_label_set_text(lbl, labels_text[i]);
        theme.styleText(lbl, theme.getFont24());

        list_items[i] = item;
    }

    index = 0;
    updateFocus();
}

pub fn updateFocus() void {
    for (0..labels_text.len) |i| {
        if (list_items[i]) |item| {
            if (i == index) {
                c.lv_obj_set_style_bg_image_src(item, assets.btnListItem(), 0);
                c.lv_obj_set_style_bg_opa(item, 0, 0);
            } else {
                c.lv_obj_set_style_bg_image_src(item, @as(?*const anyopaque, null), 0);
                c.lv_obj_set_style_bg_opa(item, c.LV_OPA_COVER, 0);
            }
        }
    }
}

pub fn scrollUp() void {
    if (index > 0) { index -= 1; updateFocus(); }
}

pub fn scrollDown() void {
    if (index < labels_text.len - 1) { index += 1; updateFocus(); }
}

pub fn show() void {
    if (screen) |scr| c.lv_screen_load_anim(scr, c.LV_SCR_LOAD_ANIM_MOVE_LEFT, 200, 0, false);
}
