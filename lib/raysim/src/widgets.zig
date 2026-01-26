//! UI Widgets for raysim
//!
//! Drawing functions for various UI components.
//! Uses raygui for better text rendering with system fonts.

pub const rl = @import("raylib");
pub const rg = @import("raygui");

pub const Color = rl.Color;
pub const Rectangle = rl.Rectangle;

// ============================================================================
// Font Configuration
// ============================================================================

pub const FontSize = struct {
    pub const title: i32 = 20;
    pub const normal: i32 = 18;
    pub const small: i32 = 16;
    pub const log: i32 = 14;
};

var custom_font: ?rl.Font = null;

/// Initialize with system font (call after raylib window init)
pub fn initFont() void {
    // Try loading system fonts in order of preference
    const font_paths = [_][:0]const u8{
        // macOS system fonts
        "/System/Library/Fonts/PingFang.ttc", // 苹方 (中文友好)
        "/System/Library/Fonts/SFNS.ttf", // SF Pro
        "/Library/Fonts/Arial Unicode.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        // Linux
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        // Windows
        "C:/Windows/Fonts/msyh.ttc", // 微软雅黑
        "C:/Windows/Fonts/segoeui.ttf",
    };

    for (font_paths) |path| {
        const font = rl.loadFontEx(path, FontSize.normal, null) catch continue;
        if (font.texture.id != 0) {
            custom_font = font;
            rg.setFont(font);
            // Set default text size
            rg.setStyle(.default, .{ .default = .text_size }, FontSize.normal);
            return;
        }
    }
    // If no system font found, use default
}

/// Cleanup font resources
pub fn deinitFont() void {
    if (custom_font) |font| {
        rl.unloadFont(font);
        custom_font = null;
    }
}

// ============================================================================
// Theme Colors
// ============================================================================

pub const theme = struct {
    pub const background = Color.init(40, 44, 52, 255);
    pub const panel_bg = Color.init(30, 34, 42, 255);
    pub const panel_border = Color.init(80, 80, 80, 255);
    pub const text = Color.init(220, 220, 220, 255);
    pub const text_dim = Color.init(150, 150, 150, 255);
    pub const button_normal = Color.init(70, 70, 70, 255);
    pub const button_pressed = Color.init(100, 100, 100, 255);
    pub const slider_bg = Color.init(50, 50, 50, 255);
    pub const slider_fg = Color.init(100, 150, 200, 255);
    pub const led_off = Color.init(40, 40, 40, 255);
    pub const log_text = Color.init(150, 200, 150, 255);
};

// ============================================================================
// Drawing Functions
// ============================================================================

/// Draw a panel with title (using raygui GroupBox style)
pub fn drawPanel(x: i32, y: i32, w: i32, h: i32, title: []const u8) void {
    const rect = Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    
    if (title.len > 0) {
        var buf: [128]u8 = undefined;
        const text_z = toSlice(&buf, title);
        _ = rg.groupBox(rect, text_z);
    } else {
        _ = rg.panel(rect, null);
    }
}

/// Draw a button (using raygui)
pub fn drawButton(x: i32, y: i32, w: i32, h: i32, text: []const u8, pressed: bool) void {
    const rect = Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    
    var buf: [128]u8 = undefined;
    const text_z = toSlice(&buf, text);
    
    // Visual feedback for pressed state
    if (pressed) {
        rl.drawRectangle(x, y, w, h, theme.button_pressed);
        rl.drawRectangleLines(x, y, w, h, Color.white);
        _ = rg.label(rect, text_z);
    } else {
        _ = rg.button(rect, text_z);
    }
}

/// Draw a label (using raygui)
pub fn drawLabel(x: i32, y: i32, text: []const u8) void {
    const rect = Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = 300, // Wide enough for text
        .height = @floatFromInt(FontSize.normal + 4),
    };
    
    var buf: [256]u8 = undefined;
    const text_z = toSlice(&buf, text);
    _ = rg.label(rect, text_z);
}

/// Draw a toggle/checkbox (using raygui)
pub fn drawToggle(x: i32, y: i32, w: i32, h: i32, text: []const u8, active: bool) void {
    const rect = Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    
    var buf: [128]u8 = undefined;
    const text_z = toSlice(&buf, text);
    
    var state = active;
    _ = rg.checkBox(rect, text_z, &state);
}

/// Draw a slider (using raygui)
pub fn drawSlider(x: i32, y: i32, w: i32, h: i32, value: f32) void {
    const rect = Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    
    var val = value;
    _ = rg.sliderBar(rect, "", "", &val, 0.0, 1.0);
}

/// Draw a progress bar (using raygui)
pub fn drawProgressBar(x: i32, y: i32, w: i32, h: i32, value: f32) void {
    const rect = Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    
    var val = value;
    _ = rg.progressBar(rect, "", "", &val, 0.0, 1.0);
}

/// Draw a single LED
pub fn drawLed(x: i32, y: i32, size: i32, color: Color) void {
    const radius: f32 = @floatFromInt(@divTrunc(size, 2));
    const cx: i32 = x + @divTrunc(size, 2);
    const cy: i32 = y + @divTrunc(size, 2);
    
    // Glow effect if lit
    if (color.r > 0 or color.g > 0 or color.b > 0) {
        const glow = Color.init(color.r, color.g, color.b, 60);
        rl.drawCircle(cx, cy, radius + 5, glow);
    }
    
    // LED body
    const display_color = if (color.r == 0 and color.g == 0 and color.b == 0)
        theme.led_off
    else
        color;
    
    rl.drawCircle(cx, cy, radius, display_color);
    rl.drawCircleLines(cx, cy, radius, Color.white);
}

/// Draw LED strip (horizontal array of LEDs)
pub fn drawLedStrip(x: i32, y: i32, w: i32, h: i32, colors: []const Color) void {
    const count = colors.len;
    if (count == 0) return;
    
    const led_size: i32 = @min(h - 4, @divTrunc(w - 4, @as(i32, @intCast(count))));
    const spacing: i32 = if (count > 1)
        @divTrunc(w - led_size, @as(i32, @intCast(count - 1)))
    else
        0;
    
    // Background
    rl.drawRectangle(x, y, w, h, theme.panel_bg);
    rl.drawRectangleLines(x, y, w, h, theme.panel_border);
    
    // Draw each LED
    for (0..count) |i| {
        const led_x = x + 2 + @as(i32, @intCast(i)) * spacing;
        const led_y = y + @divTrunc(h - led_size, 2);
        drawLed(led_x, led_y, led_size, colors[i]);
    }
}

/// Convert slice to null-terminated slice (for raygui)
fn toSlice(buf: []u8, text: []const u8) [:0]const u8 {
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}

/// Draw text (helper for Zig slices, using raygui style)
pub fn drawText(text: []const u8, x: i32, y: i32, size: i32, color: Color) void {
    var buf: [256]u8 = undefined;
    const text_z = toSlice(&buf, text);
    // Use raygui's font for consistent rendering
    const rect = Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = 500,
        .height = @floatFromInt(size + 4),
    };
    // Set text color temporarily
    const prev_color = rg.getStyle(.label, .{ .control = .text_color_normal });
    rg.setStyle(.label, .{ .control = .text_color_normal }, @bitCast(rl.colorToInt(color)));
    _ = rg.label(rect, text_z);
    rg.setStyle(.label, .{ .control = .text_color_normal }, prev_color);
}

/// Format integer to buffer
fn formatInt(buf: []u8, value: u32) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    
    var v = value;
    var len: usize = 0;
    while (v > 0 and len < buf.len) {
        buf[len] = @intCast('0' + (v % 10));
        v /= 10;
        len += 1;
    }
    
    // Reverse
    var i: usize = 0;
    var j: usize = len - 1;
    while (i < j) {
        const tmp = buf[i];
        buf[i] = buf[j];
        buf[j] = tmp;
        i += 1;
        j -= 1;
    }
    
    return len;
}
