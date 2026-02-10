//! Font — Zig-native font helpers
//!
//! ```zig
//! const f14 = ui.font.montserrat(14);  // built-in
//! const cn = ui.font.fromTTF(data, 24); // TTF from memory
//! ```

const c = @import("lvgl").c;

pub const Font = c.lv_font_t;

/// Get a built-in Montserrat font by size.
/// Available sizes: 8,10,12,14,16,18,20,22,...,48
/// Falls back to 14 if the requested size is not enabled.
pub fn montserrat(comptime size: u8) *const Font {
    return switch (size) {
        14 => &c.lv_font_montserrat_14,
        16 => &c.lv_font_montserrat_16,
        20 => &c.lv_font_montserrat_20,
        else => &c.lv_font_montserrat_14,
    };
}

/// Default font (Montserrat 14)
pub const default = &c.lv_font_montserrat_14;

/// Create a font from TTF data in memory.
/// Returns null if tiny_ttf is not available or allocation fails.
pub fn fromTTF(data: []const u8, size: i32) ?*Font {
    return c.lv_tiny_ttf_create_data(@ptrCast(data.ptr), data.len, size);
}

/// Destroy a TTF font created with fromTTF.
pub fn destroyTTF(f: *Font) void {
    c.lv_tiny_ttf_destroy(f);
}
