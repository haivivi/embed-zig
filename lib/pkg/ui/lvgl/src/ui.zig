//! UI Framework — Zig-native LVGL wrapper
//!
//! Provides type-safe, chainable API for embedded UI development.
//!
//! ## Usage
//!
//! ```zig
//! const ui = @import("ui");
//!
//! // Create objects with chaining
//! const bar = ui.Obj.create(parent).?
//!     .size(240, 54)
//!     .align(.top_mid, 0, 0)
//!     .bgTransparent()
//!     .flexFlow(.row)
//!     .flexMain(.space_between);
//!
//! const lbl = ui.Label.create(bar).?
//!     .text("Hello")
//!     .color(0xffffff)
//!     .font(&lv_font_montserrat_20);
//!
//! const img = ui.Image.create(bar).?
//!     .src(my_png_data)
//!     .align(.center, 0, 0);
//!
//! // Screens
//! const scr = ui.Obj.createScreen().?
//!     .bgColor(0x000000);
//! scr.load(); // or scr.loadAnim(.move_left, 200);
//! ```

const lvgl = @import("lvgl");
const c = lvgl.c;
const display_pkg = @import("display");

// Core types
pub const Obj = @import("obj.zig");
pub const color = @import("color.zig");
pub const font = @import("font.zig");
pub const anim = @import("anim.zig");
pub const event = @import("event.zig");

// Widgets
pub const Label = @import("label.zig");
pub const Image = @import("image.zig");
pub const Button = @import("button.zig");
pub const Bar = @import("bar.zig");
pub const Slider = @import("slider.zig");
pub const Canvas = @import("canvas.zig");
pub const Arc = @import("arc.zig");
pub const Checkbox = @import("checkbox.zig");
pub const Dropdown = @import("dropdown.zig");
pub const Led = @import("led.zig");
pub const Line = @import("line.zig");
pub const Roller = @import("roller.zig");
pub const Switch = @import("switch_.zig");
pub const Textarea = @import("textarea.zig");
pub const Table = @import("table.zig");

// Test utilities
pub const MemDisplay = display_pkg.MemDisplay;

// Re-export common enums
pub const Align = Obj.Align;
pub const FlexFlow = Obj.FlexFlow;
pub const FlexAlign = Obj.FlexAlign;
pub const ScreenAnim = Obj.ScreenAnim;
pub const Color = color.Color;
pub const Font = font.Font;

// Re-export display types for convenience
pub const RenderMode = display_pkg.RenderMode;
pub const Area = display_pkg.Area;
pub const ColorFormat = display_pkg.ColorFormat;

// ============================================================================
// Display Context
// ============================================================================

pub fn Context(comptime DisplayDriver: type) type {
    return struct {
        const Self = @This();

        display: *DisplayDriver,
        lv_display: *c.lv_display_t,

        pub fn screen(self: *const Self) Obj {
            _ = self;
            return Obj{ .ptr = c.lv_screen_active().? };
        }

        pub fn tick(_: *Self, ms: u32) void {
            c.lv_tick_inc(ms);
        }

        pub fn handler(_: *Self) u32 {
            return c.lv_timer_handler();
        }

        pub fn deinit(self: *Self) void {
            c.lv_deinit();
            self.* = undefined;
        }
    };
}

/// Initialize LVGL with a display driver.
///
/// `Driver` is any type that provides:
/// - `width: u16`, `height: u16` — resolution (comptime)
/// - `color_format: ColorFormat` — pixel format (comptime)
/// - `render_mode: RenderMode` — buffer strategy (comptime)
/// - `buf_lines: u16` — draw buffer height for partial mode (comptime)
/// - `fn flush(self: *Driver, area: Area, color_data: [*]const u8) void`
///
/// For `.direct` mode, Driver must also have:
/// - `fn getFramebuffer(self: *Driver) [*]u8`
///
/// Examples: `display.SpiLcd(Spi, DcPin, config)`, `display.MemDisplay(w, h, fmt)`
pub fn init(comptime Driver: type, driver: *Driver) !Context(Driver) {
    // Comptime validation
    comptime {
        _ = @as(u16, Driver.width);
        _ = @as(u16, Driver.height);
        _ = @as(display_pkg.ColorFormat, Driver.color_format);
        _ = @as(display_pkg.RenderMode, Driver.render_mode);
        _ = @as(u16, Driver.buf_lines);
        _ = @as(*const fn (*Driver, display_pkg.Area, [*]const u8) void, &Driver.flush);
    }

    const render_mode = Driver.render_mode;

    const Adapter = struct {
        const bpp: u32 = display_pkg.bytesPerPixel(Driver.color_format);

        var lcd: *Driver = undefined;

        fn flushCb(
            lv_disp: ?*c.lv_display_t,
            lv_area: ?*const c.lv_area_t,
            px_map: ?*u8,
        ) callconv(.c) void {
            // LVGL requires lv_display_flush_ready() on EVERY callback invocation.
            // Missing it causes LVGL to stall in "flushing" state permanently.
            defer if (lv_disp) |d| c.lv_display_flush_ready(d);

            if (lv_area == null or px_map == null) return;
            const area = lv_area.?;
            lcd.flush(.{
                .x1 = @intCast(area.x1),
                .y1 = @intCast(area.y1),
                .x2 = @intCast(area.x2),
                .y2 = @intCast(area.y2),
            }, @ptrCast(px_map.?));
        }

        // Static draw buffer — sized by render_mode + buf_lines (comptime).
        // For .direct mode this is unused; the driver provides the buffer.
        const draw_buf_size = if (render_mode == .direct)
            0
        else
            @as(u32, Driver.width) * bpp * @as(u32, Driver.buf_lines);

        var draw_buf: [draw_buf_size]u8 = undefined;
    };
    Adapter.lcd = driver;

    c.lv_init();

    const lv_disp = c.lv_display_create(
        @intCast(Driver.width),
        @intCast(Driver.height),
    ) orelse return error.DisplayCreateFailed;

    // Configure LVGL display buffers based on render mode
    const lv_render_mode: c_uint = switch (render_mode) {
        .partial => c.LV_DISPLAY_RENDER_MODE_PARTIAL,
        .direct => c.LV_DISPLAY_RENDER_MODE_DIRECT,
        .full => c.LV_DISPLAY_RENDER_MODE_FULL,
    };

    if (render_mode == .direct) {
        // Direct mode: LVGL writes into driver's framebuffer
        const fb = driver.getFramebuffer();
        const fb_size = @as(u32, Driver.width) * @as(u32, Driver.height) * Adapter.bpp;
        c.lv_display_set_buffers(lv_disp, fb, null, fb_size, lv_render_mode);
    } else {
        // Partial/Full mode: use the static draw buffer
        c.lv_display_set_buffers(
            lv_disp,
            &Adapter.draw_buf,
            null,
            Adapter.draw_buf_size,
            lv_render_mode,
        );
    }

    c.lv_display_set_flush_cb(lv_disp, Adapter.flushCb);

    return .{
        .display = driver,
        .lv_display = lv_disp,
    };
}


// ============================================================================
// Tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}

test "LVGL init and deinit" {
    const Display = MemDisplay(320, 240, .rgb565);

    var display = Display.create();

    var ctx = try init(Display, &display);
    defer ctx.deinit();

    const scr = ctx.screen();
    _ = scr.raw();
}

test "LVGL create label with chaining" {
    const Display = MemDisplay(320, 240, .rgb565);

    var display = Display.create();

    var ctx = try init(Display, &display);
    defer ctx.deinit();

    const lbl = Label.create(ctx.screen()).?
        .text("Hello")
        .color(0xffffff)
        .center();

    _ = lbl.raw();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        ctx.tick(5);
        _ = ctx.handler();
    }

    try @import("std").testing.expect(display.flush_count > 0);
}
