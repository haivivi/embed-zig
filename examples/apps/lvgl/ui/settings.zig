//! Settings List — 9-item vertical scrollable list

const c = @import("lvgl").c;
const ui = @import("ui");
const theme = @import("../theme.zig");
const assets = @import("../assets.zig");

pub var screen: ?ui.Obj = null;
var list_items: [9]?ui.Obj = .{null} ** 9;
pub var index: u8 = 0;

const labels_text = [_][*:0]const u8{
    "\xe5\xb1\x8f\xe5\xb9\x95\xe4\xba\xae\xe5\xba\xa6",
    "\xe6\x8c\x87\xe7\xa4\xba\xe7\x81\xaf\xe4\xba\xae\xe5\xba\xa6",
    "\xe6\x8c\x89\xe9\x94\xae\xe6\x8f\x90\xe7\xa4\xba",
    "\xe9\x87\x8d\xe7\xbd\xae\xe8\xae\xbe\xe5\xa4\x87",
    "\xe8\xae\xbe\xe5\xa4\x87\xe4\xbf\xa1\xe6\x81\xaf",
    "\xe8\xae\xbe\xe5\xa4\x87\xe7\xbb\x91\xe5\xae\x9a",
    "Sim\xe5\x8d\xa1\xe4\xbf\xa1\xe6\x81\xaf",
    "\xe8\xae\xbe\xe5\xa4\x87\xe7\x89\x88\xe6\x9c\xac",
    "\xe7\xb3\xbb\xe7\xbb\x9f\xe8\xaf\xad\xe8\xa8\x80",
};

pub fn create() void {
    screen = ui.Obj.createScreen();
    const scr = screen orelse return;
    _ = scr.bgColor(theme.black);

    if (assets.imgBg()) |src| _ = (ui.Image.create(scr) orelse return).src(src);

    const list = ui.Obj.create(scr.ptr) orelse return;
    _ = list.size(224, 240).setAlign(.center, 0, 0)
        .bgTransparent().flexFlow(.column).padRow(4).padTop(8).scrollbarOff();

    for (0..labels_text.len) |i| {
        const item = ui.Obj.create(list.ptr) orelse continue;
        _ = item.size(224, 55).radius(4).borderWidth(0).scrollbarOff()
            .flexFlow(.row).flexCross(.center)
            .padLeft(16).padColumn(16).padVer(8)
            .bgColor(theme.black);

        if (assets.settingIcon(i)) |src| {
            _ = (ui.Image.create(item) orelse continue).src(src);
        }
        _ = (ui.Label.create(item) orelse continue)
            .text(labels_text[i]).color(theme.white).font(theme.getFont20());

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
                item.scrollToView(true);
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
