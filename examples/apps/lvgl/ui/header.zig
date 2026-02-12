//! Header — 54px top bar with time, signal, battery

const c = @import("lvgl").c;
const ui = @import("ui");
const theme = @import("../theme.zig");

pub fn create(parent: ui.Obj) ?ui.Obj {
    const bar = ui.Obj.create(parent.ptr) orelse return null;
    _ = bar.size(240, 54)
        .setAlign(.top_mid, 0, 0)
        .bgTransparent()
        .padLeft(16).padRight(16).padTop(16)
        .flexFlow(.row)
        .flexMain(.space_between)
        .flexCross(.center);

    // Time (left)
    if (ui.Label.create(bar)) |time_lbl| {
        _ = time_lbl.text("12:00").color(theme.white).font(theme.getFont16());
    }

    // Spacer
    if (ui.Obj.create(bar.ptr)) |spacer| {
        _ = spacer.flexGrow(1).bgTransparent().height(1);
    }

    // Signal + Battery (right)
    if (ui.Obj.create(bar.ptr)) |right| {
        _ = right.bgTransparent()
            .size(c.LV_SIZE_CONTENT, c.LV_SIZE_CONTENT)
            .flexFlow(.row).padColumn(6);

        if (ui.Label.create(right)) |sig| {
            _ = sig.text("\xEF\x80\x92") // WIFI symbol
                .color(theme.white).font(&c.lv_font_montserrat_14);
        }
        if (ui.Label.create(right)) |batt| {
            _ = batt.text("\xEF\x89\x80") // BATTERY symbol
                .color(theme.white).font(&c.lv_font_montserrat_14);
        }
    }

    return bar;
}
