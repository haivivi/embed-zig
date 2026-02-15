//! H106 Assets — loaded via board.fs (VFS)

const ui_state = @import("ui_state");
const Image = ui_state.Image;
const trait_fs = @import("trait").fs;

/// Parse an RGB565/RGBA5658 binary file into an Image descriptor.
/// Format: [0:2] width LE, [2:4] height LE, [4] bpp (2 or 3), [5:] pixels
pub fn loadRgb565(data: []const u8) Image {
    if (data.len < 5) return .{ .width = 0, .height = 0, .data = &.{}, .bytes_per_pixel = 2 };
    const w: u16 = @as(u16, data[0]) | (@as(u16, data[1]) << 8);
    const h: u16 = @as(u16, data[2]) | (@as(u16, data[3]) << 8);
    const bpp: u8 = data[4];
    return .{ .width = w, .height = h, .data = data[5..], .bytes_per_pixel = bpp };
}

/// Load an image from the VFS by path.
pub fn loadImageFromFs(fs: anytype, path: []const u8, buf: []u8) ?Image {
    var file = fs.open(path, .read) orelse return null;
    defer file.close();
    const data = file.readAll(buf);
    if (data.len < 5) return null;
    return loadRgb565(data);
}

// ============================================================================
// Asset paths
// ============================================================================

pub const PATH_FONT = "/fonts/NotoSansSC-Bold.ttf";
pub const PATH_BG = "/assets/bg.rgb565";
pub const PATH_ULTRAMAN = "/assets/ultraman.rgb565";

pub const PATH_MENU_ITEMS = [5][]const u8{
    "/assets/menu_item0.rgb565", "/assets/menu_item1.rgb565",
    "/assets/menu_item2.rgb565", "/assets/menu_item3.rgb565",
    "/assets/menu_item4.rgb565",
};

pub const PATH_BTN_LIST_ITEM = "/assets/btn_list_item.rgb565";

pub const PATH_GAME_ICONS = [4][]const u8{
    "/assets/icon_game_0.rgb565", "/assets/icon_game_1.rgb565",
    "/assets/icon_game_2.rgb565", "/assets/icon_game_3.rgb565",
};

pub const PATH_SETTING_ICONS = [9][]const u8{
    "/assets/listicon_0.rgb565", "/assets/listicon_1.rgb565",
    "/assets/listicon_2.rgb565", "/assets/listicon_3.rgb565",
    "/assets/listicon_4.rgb565", "/assets/listicon_5.rgb565",
    "/assets/listicon_6.rgb565", "/assets/listicon_7.rgb565",
    "/assets/listicon_8.rgb565",
};

// ============================================================================
// Labels (Chinese)
// ============================================================================

pub const MENU_LABELS = [5][]const u8{
    "\xe5\xa5\xa5\xe7\x89\xb9\xe9\x9b\x86\xe7\xbb\x93", // 奥特集结
    "\xe8\xb6\x85\xe8\x83\xbd\xe9\xa9\xaf\xe5\x8c\x96", // 超能驯化
    "\xe5\xae\x88\xe6\x8a\xa4\xe8\x81\x94\xe7\xbb\x9c", // 守护联络
    "\xe7\xa7\xaf\xe5\x88\x86",                         // 积分
    "\xe8\xae\xbe\xe7\xbd\xae",                         // 设置
};

pub const GAME_LABELS = [4][]const u8{
    "\xe7\x82\xbd\xe7\x84\xb0\xe8\xb7\x83\xe5\x8a\xa8", // 炽焰跃动
    "\xe6\xb7\xb1\xe6\xb8\x8a\xe5\xbe\x81\xe9\x80\x94", // 深渊征途
    "\xe8\xb6\x85\xe8\x83\xbd\xe5\x8f\x8d\xe5\x87\xbb", // 超能反击
    "\xe9\x87\x8f\xe5\xad\x90\xe6\x96\xb9\xe5\x9f\x9f", // 量子方域
};

pub const SETTING_LABELS = [9][]const u8{
    "\xe5\xb1\x8f\xe5\xb9\x95\xe4\xba\xae\xe5\xba\xa6", // 屏幕亮度
    "\xe6\x8c\x87\xe7\xa4\xba\xe7\x81\xaf\xe4\xba\xae\xe5\xba\xa6", // 指示灯亮度
    "\xe6\x8c\x89\xe9\x94\xae\xe6\x8f\x90\xe7\xa4\xba", // 按键提示
    "\xe9\x87\x8d\xe7\xbd\xae\xe8\xae\xbe\xe5\xa4\x87", // 重置设备
    "\xe8\xae\xbe\xe5\xa4\x87\xe4\xbf\xa1\xe6\x81\xaf", // 设备信息
    "\xe8\xae\xbe\xe5\xa4\x87\xe7\xbb\x91\xe5\xae\x9a", // 设备绑定
    "Sim\xe5\x8d\xa1\xe4\xbf\xa1\xe6\x81\xaf",         // Sim卡信息
    "\xe8\xae\xbe\xe5\xa4\x87\xe7\x89\x88\xe6\x9c\xac", // 设备版本
    "\xe7\xb3\xbb\xe7\xbb\x9f\xe8\xaf\xad\xe8\xa8\x80", // 系统语言
};
