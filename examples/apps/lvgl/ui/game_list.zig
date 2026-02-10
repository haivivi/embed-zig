//! Game List — 4-game vertical list

const c = @import("lvgl").c;
const ui = @import("ui");
const theme = @import("../theme.zig");
const assets = @import("../assets.zig");

pub var screen: ?ui.Obj = null;
var list_items: [4]?ui.Obj = .{null} ** 4;
pub var index: u8 = 0;

const labels_text = [_][*:0]const u8{
    "炽焰跃动",
    "深渊征途",
    "超能反击",
    "量子方域",
};

pub fn create() void {
    screen = ui.Obj.createScreen();
    const scr = screen orelse return;
    _ = scr.bgColor(theme.black);

    if (assets.imgBg()) |src| _ = (ui.Image.create(scr) orelse return).src(src);

    const list = ui.Obj.create(scr.ptr) orelse return;
    _ = list.size(224, 240).setAlign(.center, 0, 0)
        .bgTransparent().flexFlow(.column).padRow(4).padTop(20)
        .flexMain(.center);

    for (0..labels_text.len) |i| {
        const item = ui.Obj.create(list.ptr) orelse continue;
        _ = item.size(224, 55).radius(4).borderWidth(0).scrollbarOff()
            .flexFlow(.row).flexCross(.center)
            .padLeft(16).padColumn(12).padVer(8)
            .bgColor(theme.black);

        if (assets.gameIcon(i)) |src| {
            _ = (ui.Image.create(item) orelse continue).src(src);
        }
        _ = (ui.Label.create(item) orelse continue)
            .text(labels_text[i]).color(theme.white).font(theme.getFont24());

        list_items[i] = item;
    }

    index = 0;
    updateFocus();
}

pub fn updateFocus() void {
    for (0..labels_text.len) |i| {
        if (list_items[i]) |item| {
            if (i == index) {
                _ = item.bgImage(assets.btnListItem()).bgOpa(0);
            } else {
                _ = item.bgImage(null).bgOpa(c.LV_OPA_COVER);
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
    if (screen) |scr| scr.loadAnim(.move_left, 200);
}
