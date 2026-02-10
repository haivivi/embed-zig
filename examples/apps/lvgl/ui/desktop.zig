//! Desktop — Ultraman splash screen with starry background

const ui = @import("ui");
const theme = @import("../theme.zig");
const header = @import("header.zig");
const assets = @import("../assets.zig");

pub var screen: ?ui.Obj = null;

pub fn create() void {
    screen = ui.Obj.createScreen();
    const scr = screen orelse return;
    _ = scr.bgColor(theme.black);

    if (assets.imgBg()) |src| {
        _ = (ui.Image.create(scr) orelse return).src(src).center();
    }
    if (assets.imgUltraman()) |src| {
        _ = (ui.Image.create(scr) orelse return).src(src).center();
    }
    _ = header.create(scr);
}

pub fn show() void {
    if (screen) |scr| scr.load();
}
