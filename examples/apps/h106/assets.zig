//! H106 Assets — loaded via board.fs (VFS)
//!
//! Images are RGB565 binary files: u16 LE width + u16 LE height + pixels.
//! The actual storage backend depends on the platform:
//! - websim: @embedFile (EmbedFs)
//! - ESP32: SPIFFS partition

const ui_state = @import("ui_state");
const Image = ui_state.Image;
const trait_fs = @import("trait").fs;

/// Parse an RGB565 binary file into an Image descriptor.
/// Format: [0:2] width LE, [2:4] height LE, [4:] RGB565 pixels LE
pub fn loadRgb565(data: []const u8) Image {
    if (data.len < 4) return .{ .width = 0, .height = 0, .data = &.{}, .bytes_per_pixel = 2 };
    const w: u16 = @as(u16, data[0]) | (@as(u16, data[1]) << 8);
    const h: u16 = @as(u16, data[2]) | (@as(u16, data[3]) << 8);
    return .{
        .width = w,
        .height = h,
        .data = data[4..],
        .bytes_per_pixel = 2,
    };
}

/// Load an image from the VFS by path.
/// Reads the entire file into the provided buffer, then parses as RGB565.
pub fn loadImageFromFs(fs: anytype, path: []const u8, buf: []u8) ?Image {
    var file = fs.open(path, .read) orelse return null;
    defer file.close();
    const data = file.readAll(buf);
    if (data.len < 4) return null;
    return loadRgb565(data);
}

// Asset paths — same paths on all platforms
pub const PATH_BG = "/assets/bg.rgb565";
pub const PATH_ULTRAMAN = "/assets/ultraman.rgb565";
pub const PATH_MENU_ITEMS = [5][]const u8{
    "/assets/menu_item0.rgb565",
    "/assets/menu_item1.rgb565",
    "/assets/menu_item2.rgb565",
    "/assets/menu_item3.rgb565",
    "/assets/menu_item4.rgb565",
};

pub const PATH_FONT = "/fonts/NotoSansSC-Bold.ttf";

pub const MENU_LABELS = [5][]const u8{
    "Team",
    "Game",
    "Contact",
    "Points",
    "Settings",
};
