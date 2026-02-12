//! H106 Theme — Colors, fonts, styles matching globals_tiga.theme

const ui = @import("ui");
const assets = @import("assets.zig");

// ============================================================================
// Colors (from globals_tiga.theme)
// ============================================================================

pub const white: u32 = 0xffffff;
pub const theme_color: u32 = 0x7565d6;
pub const ultraman_red: u32 = 0xe72d30;
pub const grey: u32 = 0xd9d9d9;
pub const dark_grey: u32 = 0x3a3a3a;
pub const medium_grey: u32 = 0x575757;
pub const black: u32 = 0x000000;

// ============================================================================
// Font
// ============================================================================

var font_24: ?*ui.Font = null;
var font_20: ?*ui.Font = null;
var font_16: ?*ui.Font = null;

pub fn getFont24() *const ui.Font {
    return font_24 orelse ui.font.montserrat(20);
}

pub fn getFont20() *const ui.Font {
    return font_20 orelse ui.font.montserrat(20);
}

pub fn getFont16() *const ui.Font {
    return font_16 orelse ui.font.montserrat(16);
}

// ============================================================================
// Init
// ============================================================================

pub fn init() void {
    font_24 = ui.font.fromTTF(assets.font_noto_sc, 24);
    font_20 = ui.font.fromTTF(assets.font_noto_sc, 20);
    font_16 = ui.font.fromTTF(assets.font_noto_sc, 16);
}
