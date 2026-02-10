//! Menu Carousel — 5-item horizontal scroll with PNG icons

const c = @import("lvgl").c;
const ui = @import("ui");
const theme = @import("../theme.zig");
const header = @import("header.zig");
const assets = @import("../assets.zig");

pub var screen: ?ui.Obj = null;
var carousel: ?ui.Obj = null;
var items: [5]?ui.Obj = .{null} ** 5;
var labels: [5]?ui.Label = .{null} ** 5;
var dots: [5]?ui.Obj = .{null} ** 5;
pub var index: u8 = 0;

const menu_titles = [_][*:0]const u8{
    "\xe5\xa5\xa5\xe7\x89\xb9\xe9\x9b\x86\xe7\xbb\x93", // 奥特集结
    "\xe8\xb6\x85\xe8\x83\xbd\xe9\xa9\xaf\xe5\x8c\x96", // 超能驯化
    "\xe5\xae\x88\xe6\x8a\xa4\xe8\x81\x94\xe7\xbb\x9c", // 守护联络
    "\xe7\xa7\xaf\xe5\x88\x86",                           // 积分
    "\xe8\xae\xbe\xe7\xbd\xae",                           // 设置
};

pub fn create() void {
    screen = ui.Obj.createScreen();
    const scr = screen orelse return;
    _ = scr.bgColor(theme.black);

    if (assets.imgBg()) |src| _ = (ui.Image.create(scr) orelse return).src(src);

    // Carousel container
    if (ui.Obj.create(scr.ptr)) |car| {
        _ = car.size(240, 200).setAlign(.top_mid, 0, 10)
            .bgTransparent().flexFlow(.row).padColumn(0)
            .scrollSnapX().scrollbarOff();
        carousel = car;

        for (0..5) |i| {
            if (ui.Obj.create(car.ptr)) |item| {
                _ = item.size(240, 200).bgTransparent();
                if (assets.menuIcon(i)) |src| {
                    if (ui.Image.create(item)) |img| {
                        _ = img.setAlign(.center, 0, -10);
                        _ = img.src(src);
                    }
                }
                items[i] = item;
            }
        }
    }

    // Title labels
    for (0..5) |i| {
        if (ui.Label.create(scr)) |lbl| {
            var l = lbl.text(menu_titles[i]).color(theme.white).font(theme.getFont24());
            _ = l.setAlign(.bottom_mid, 0, -35);
            if (i != 0) _ = l.hide();
            labels[i] = l;
        }
    }

    // Dot indicators
    if (ui.Obj.create(scr.ptr)) |row| {
        _ = row.size(240, 16).setAlign(.bottom_mid, 0, -8)
            .bgTransparent().flexFlow(.row)
            .flexMain(.center).flexCross(.center).padColumn(10);

        for (0..5) |i| {
            if (ui.Obj.create(row.ptr)) |dot| {
                _ = dot.scrollbarOff().borderWidth(0).bgColor(theme.white);
                if (i == 0) {
                    _ = dot.size(24, 12).radius(6).bgOpa(255);
                } else {
                    _ = dot.size(12, 12).radius(6).bgOpa(125);
                }
                dots[i] = dot;
            }
        }
    }

    _ = header.create(scr);
    index = 0;
}

pub fn scrollTo(new_index: u8) void {
    if (new_index >= 5) return;
    const old = index;
    index = new_index;

    if (labels[old]) |l| _ = l.hide();
    if (labels[index]) |l| _ = l.show();

    for (0..5) |i| {
        if (dots[i]) |dot| {
            if (i == index) {
                _ = dot.size(24, 12).bgOpa(255);
            } else {
                _ = dot.size(12, 12).bgOpa(125);
            }
        }
    }

    if (carousel != null and items[index] != null) {
        items[index].?.scrollToView(true);
    }
}

pub fn show() void {
    if (screen) |scr| scr.load();
}

pub fn showAnim(from_left: bool) void {
    if (screen) |scr| {
        scr.loadAnim(if (from_left) .move_right else .move_left, 200);
    }
}
