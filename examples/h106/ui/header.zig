//! Header — 54px top bar with time, signal, battery
//!
//! Layout: [HH:MM] [spacer] [signal] [battery%]

const c = @import("lvgl").c;
const theme = @import("../theme.zig");

pub fn create(parent: *c.lv_obj_t) ?*c.lv_obj_t {
    const bar = c.lv_obj_create(parent) orelse return null;
    c.lv_obj_set_size(bar, 240, 54);
    c.lv_obj_align(bar, c.LV_ALIGN_TOP_MID, 0, 0);
    theme.styleTransparent(bar);
    c.lv_obj_set_style_pad_left(bar, 16, 0);
    c.lv_obj_set_style_pad_right(bar, 16, 0);
    c.lv_obj_set_style_pad_top(bar, 16, 0);
    c.lv_obj_set_flex_flow(bar, c.LV_FLEX_FLOW_ROW);
    c.lv_obj_set_style_flex_main_place(bar, c.LV_FLEX_ALIGN_SPACE_BETWEEN, 0);
    c.lv_obj_set_style_flex_cross_place(bar, c.LV_FLEX_ALIGN_CENTER, 0);

    // Time (left)
    const time_lbl = c.lv_label_create(bar);
    c.lv_label_set_text(time_lbl, "12:00");
    theme.styleText(time_lbl, theme.getFont16());

    // Spacer
    const spacer = c.lv_obj_create(bar);
    c.lv_obj_set_flex_grow(spacer, 1);
    theme.styleTransparent(spacer);
    c.lv_obj_set_height(spacer, 1);

    // Signal + Battery (right)
    const right = c.lv_obj_create(bar) orelse return bar;
    theme.styleTransparent(right);
    c.lv_obj_set_size(right, c.LV_SIZE_CONTENT, c.LV_SIZE_CONTENT);
    c.lv_obj_set_flex_flow(right, c.LV_FLEX_FLOW_ROW);
    c.lv_obj_set_style_pad_column(right, 6, 0);

    const sig = c.lv_label_create(right);
    c.lv_label_set_text(sig, "\xEF\x80\x92"); // LV_SYMBOL_WIFI
    theme.styleText(sig, &c.lv_font_montserrat_14);

    const batt = c.lv_label_create(right);
    c.lv_label_set_text(batt, "\xEF\x89\x80"); // LV_SYMBOL_BATTERY_FULL
    theme.styleText(batt, &c.lv_font_montserrat_14);

    return bar;
}
