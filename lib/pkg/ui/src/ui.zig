//! UI Framework — Zig-friendly LVGL wrapper
//!
//! Bridges LVGL C core with embed-zig's HAL display trait.
//! Provides type-safe, Zig-idiomatic API for embedded UI development.
//!
//! ## Architecture
//!
//! ```
//! ┌──────────────────────────────────────────┐
//! │ Application                              │
//! │   const label = ui.Label.create(screen)  │
//! │   label.setText("Hello!")                 │
//! ├──────────────────────────────────────────┤
//! │ lib/pkg/ui  (this module)                │
//! │   - Display adapter (HAL → LVGL flush)   │
//! │   - Widget wrappers (Label, Button, ...)  │
//! │   - Tick/timer management                │
//! ├──────────────────────────────────────────┤
//! │ third_party/lvgl  (C core, zig-cc)       │
//! ├──────────────────────────────────────────┤
//! │ hal.display  (platform driver)           │
//! └──────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const ui = @import("ui");
//!
//! // Initialize with a HAL display driver
//! var ctx = try ui.init(display_driver, .{});
//! defer ctx.deinit();
//!
//! // Create widgets on the active screen
//! const label = ui.Label.create(ctx.screen());
//! label.setText("Hello LVGL!");
//! label.center();
//!
//! // Main loop
//! while (running) {
//!     ctx.tick(5);
//!     ctx.handler();
//!     sleep(5);
//! }
//! ```

const lvgl = @import("lvgl");
const c = lvgl.c;
const hal = @import("hal");

// Re-export sub-modules
pub const Label = @import("label.zig");
pub const Obj = @import("obj.zig");

// ============================================================================
// UI Context
// ============================================================================

/// Options for UI initialization
pub const InitOptions = struct {
    /// Draw buffer size in lines (partial rendering).
    /// Smaller = less RAM, larger = faster rendering.
    /// Default: 10 lines.
    buf_lines: u16 = 10,
};

/// UI Context — manages LVGL lifecycle and display binding.
///
/// Created by `init()`, must be cleaned up with `deinit()`.
/// Only one context should be active at a time (LVGL is single-instance).
pub fn Context(comptime DisplayDriver: type) type {
    return struct {
        const Self = @This();

        display: *DisplayDriver,
        lv_display: *c.lv_display_t,
        buf1: []u8,

        /// Get the active screen object
        pub fn screen(self: *const Self) Obj {
            _ = self;
            return Obj.wrap(c.lv_screen_active());
        }

        /// Report elapsed time to LVGL's tick counter.
        /// Call this periodically with the actual elapsed ms.
        pub fn tick(_: *Self, ms: u32) void {
            c.lv_tick_inc(ms);
        }

        /// Run LVGL's timer handler. Processes redraws and animations.
        /// Returns ms until next call is needed (can be used for sleep).
        pub fn handler(_: *Self) u32 {
            return c.lv_timer_handler();
        }

        /// Deinitialize LVGL and free resources.
        pub fn deinit(self: *Self) void {
            c.lv_deinit();
            // buf1 is stack-allocated or statically allocated, no free needed
            self.* = undefined;
        }
    };
}

/// LVGL flush callback — bridges LVGL rendering to HAL display driver.
///
/// This is called by LVGL when a display region has been rendered and
/// needs to be sent to the physical display. We convert the LVGL types
/// to HAL types and call the driver's flush method.
fn flushCb(
    lv_disp: ?*c.lv_display_t,
    lv_area: ?*const c.lv_area_t,
    px_map: ?*u8,
) callconv(.C) void {
    if (lv_area == null or px_map == null or lv_disp == null) return;

    const area = lv_area.?;
    const hal_area = hal.DisplayArea{
        .x1 = @intCast(area.x1),
        .y1 = @intCast(area.y1),
        .x2 = @intCast(area.x2),
        .y2 = @intCast(area.y2),
    };

    // Retrieve the HAL display driver pointer from LVGL's user_data
    const driver_ptr: ?*anyopaque = c.lv_display_get_user_data(lv_disp.?);
    if (driver_ptr) |ptr| {
        // We store a FlushFn pointer in user_data
        const flush_fn: *const FlushFn = @ptrCast(@alignCast(ptr));
        flush_fn.*(hal_area, px_map.?);
    }

    c.lv_display_flush_ready(lv_disp.?);
}

/// Type-erased flush function pointer
const FlushFn = fn (hal.DisplayArea, [*]const u8) void;

/// Initialize LVGL and bind it to a HAL display driver.
///
/// `driver` must be a pointer to a HAL display driver type created by
/// `hal.display.from(spec)`. The driver's lifetime must exceed the
/// UI context's lifetime.
///
/// Returns a Context that manages the LVGL lifecycle.
pub fn init(comptime HalDisplay: type, display: *HalDisplay, opts: InitOptions) !Context(HalDisplay) {
    // Initialize LVGL core
    c.lv_init();

    // Create LVGL display
    const lv_disp = c.lv_display_create(
        @intCast(HalDisplay.width),
        @intCast(HalDisplay.height),
    ) orelse return error.DisplayCreateFailed;

    // Calculate buffer size
    const buf_lines = opts.buf_lines;
    const line_bytes = @as(u32, HalDisplay.width) * @as(u32, HalDisplay.bpp);
    const buf_size = line_bytes * @as(u32, buf_lines);

    // Use a static buffer for the draw buffer (LVGL requires it to persist)
    const S = struct {
        var draw_buf: [320 * 240 * 2]u8 = undefined; // max 320x240 RGB565
    };

    // Validate buffer fits
    if (buf_size > S.draw_buf.len) return error.BufferTooSmall;

    // Set draw buffers (single buffer, partial rendering mode)
    c.lv_display_set_buffers(
        lv_disp,
        &S.draw_buf,
        null,
        buf_size,
        c.LV_DISPLAY_RENDER_MODE_PARTIAL,
    );

    // Store a pointer to a static flush wrapper that captures the display driver
    const Adapter = struct {
        var hal_display: *HalDisplay = undefined;

        fn flush(area: hal.DisplayArea, color_data: [*]const u8) void {
            hal_display.flush(area, color_data);
        }

        const flush_fn: FlushFn = flush;
    };
    Adapter.hal_display = display;

    c.lv_display_set_user_data(lv_disp, @constCast(@ptrCast(&Adapter.flush_fn)));
    c.lv_display_set_flush_cb(lv_disp, flushCb);

    return .{
        .display = display,
        .lv_display = lv_disp,
        .buf1 = S.draw_buf[0..buf_size],
    };
}

// ============================================================================
// Tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = Label;
    _ = Obj;
}
