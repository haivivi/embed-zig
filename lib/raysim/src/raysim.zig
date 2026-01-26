//! raysim - Raylib-based Hardware Simulator
//!
//! A comptime-configured UI simulator for HAL hardware.
//! Uses .rgl layout files (rGuiLayout format) parsed at compile time.
//!
//! ## Usage
//!
//! ```zig
//! const layout = raysim.parseLayout(@embedFile("board.rgl"));
//!
//! var sim = raysim.Simulator(layout).init(.{
//!     .title = "My Board Simulator",
//! });
//! defer sim.deinit();
//!
//! while (sim.running()) {
//!     sim.update();
//!     // Read button state: sim.getButton("btn_boot")
//!     // Set LED color: sim.setLed("led_0", .{ .r = 255, .g = 0, .b = 0 })
//!     sim.draw();
//! }
//! ```

const std = @import("std");

pub const rgl = @import("rgl.zig");
pub const widgets = @import("widgets.zig");
pub const drivers = @import("drivers.zig");
pub const sim_state_mod = @import("sim_state.zig");

// Re-export common types
pub const Color = widgets.Color;
pub const Rectangle = widgets.Rectangle;
pub const Control = rgl.Control;
pub const ControlType = rgl.ControlType;
pub const Layout = rgl.Layout;

// Re-export driver types for app boards
pub const SimState = sim_state_mod.SimState;
pub const RtcDriver = drivers.RtcDriver;
pub const ButtonDriver = drivers.ButtonDriver;
pub const LedDriver = drivers.LedDriver;
pub const sal = drivers.sal;
pub const sim_state = &sim_state_mod.state;

// Note: HAL specs should be defined in each board's sim_raylib.zig
// using hal.Meta for type compatibility with HAL's spec verifier.

/// Parse RGL layout content at comptime
pub fn parseLayout(comptime content: []const u8) rgl.Layout(rgl.countControls(content)) {
    return comptime rgl.parse(content);
}

/// Simulator configuration
pub const Config = struct {
    title: [:0]const u8 = "raysim",
    width: i32 = 800,
    height: i32 = 600,
    fps: i32 = 60,
    background: Color = Color.init(40, 44, 52, 255),
};

/// Create a Simulator type for a given layout
pub fn Simulator(comptime layout: anytype) type {
    const control_count = layout.count;

    return struct {
        const Self = @This();

        config: Config,
        
        // Widget states
        button_states: [control_count]bool = [_]bool{false} ** control_count,
        slider_values: [control_count]f32 = [_]f32{0.5} ** control_count,
        toggle_states: [control_count]bool = [_]bool{false} ** control_count,
        led_colors: [control_count]Color = [_]Color{Color.black} ** control_count,
        
        // Log buffer
        log_lines: [32][256]u8 = undefined,
        log_lens: [32]usize = [_]usize{0} ** 32,
        log_count: usize = 0,
        log_next: usize = 0,

        pub fn init(config: Config) Self {
            widgets.rl.initWindow(config.width, config.height, config.title);
            widgets.rl.setTargetFPS(config.fps);
            widgets.initFont(); // Load system font for better text
            return .{ .config = config };
        }

        pub fn deinit(_: *Self) void {
            widgets.deinitFont();
            widgets.rl.closeWindow();
        }

        pub fn running(_: *Self) bool {
            return !widgets.rl.windowShouldClose();
        }

        pub fn update(self: *Self) void {
            // Update button states from controls
            inline for (0..control_count) |i| {
                const ctrl = layout.controls[i];
                switch (ctrl.type) {
                    .button => {
                        const rect = widgets.Rectangle{
                            .x = @floatFromInt(ctrl.x),
                            .y = @floatFromInt(ctrl.y),
                            .width = @floatFromInt(ctrl.width),
                            .height = @floatFromInt(ctrl.height),
                        };
                        const mouse = widgets.rl.getMousePosition();
                        const in_rect = widgets.rl.checkCollisionPointRec(mouse, rect);
                        self.button_states[i] = in_rect and widgets.rl.isMouseButtonDown(.left);
                    },
                    else => {},
                }
            }
        }

        pub fn draw(self: *Self) void {
            widgets.rl.beginDrawing();
            defer widgets.rl.endDrawing();

            widgets.rl.clearBackground(self.config.background);

            // Draw all controls
            inline for (0..control_count) |i| {
                const ctrl = layout.controls[i];
                self.drawControl(ctrl, i);
            }
        }

        fn drawControl(self: *Self, ctrl: Control, idx: usize) void {
            switch (ctrl.type) {
                .button => widgets.drawButton(
                    ctrl.x, ctrl.y, ctrl.width, ctrl.height,
                    ctrl.text, self.button_states[idx],
                ),
                .label => widgets.drawLabel(
                    ctrl.x, ctrl.y, ctrl.text,
                ),
                .toggle, .checkbox => widgets.drawToggle(
                    ctrl.x, ctrl.y, ctrl.width, ctrl.height,
                    ctrl.text, self.toggle_states[idx],
                ),
                .slider, .slider_bar => widgets.drawSlider(
                    ctrl.x, ctrl.y, ctrl.width, ctrl.height,
                    self.slider_values[idx],
                ),
                .progress_bar => widgets.drawProgressBar(
                    ctrl.x, ctrl.y, ctrl.width, ctrl.height,
                    self.slider_values[idx],
                ),
                .led => widgets.drawLed(
                    ctrl.x, ctrl.y, ctrl.width,
                    self.led_colors[idx],
                ),
                .led_strip => widgets.drawLedStrip(
                    ctrl.x, ctrl.y, ctrl.width, ctrl.height,
                    self.led_colors[idx..],
                ),
                .panel => widgets.drawPanel(
                    ctrl.x, ctrl.y, ctrl.width, ctrl.height,
                    ctrl.text,
                ),
                .log_panel => self.drawLogPanel(ctrl),
                else => {},
            }
        }

        fn drawLogPanel(self: *Self, ctrl: Control) void {
            widgets.drawPanel(ctrl.x, ctrl.y, ctrl.width, ctrl.height, "Log");
            
            const line_height: i32 = widgets.FontSize.log + 4;
            var y: i32 = ctrl.y + 30;
            const max_lines: usize = @intCast(@divTrunc(ctrl.height - 35, line_height));
            const start = if (self.log_count > max_lines) self.log_count - max_lines else 0;
            
            for (start..self.log_count) |i| {
                const actual_idx = if (self.log_count < 32) i else (self.log_next + i) % 32;
                const line = self.log_lines[actual_idx][0..self.log_lens[actual_idx]];
                widgets.drawText(line, ctrl.x + 10, y, widgets.FontSize.log, Color.init(150, 200, 150, 255));
                y += line_height;
            }
        }

        // ============================================================
        // Public API for controlling widgets
        // ============================================================

        /// Get button pressed state by name
        pub fn getButton(self: *const Self, comptime name: []const u8) bool {
            const idx = comptime layout.findControl(name) orelse @compileError("Control not found: " ++ name);
            return self.button_states[idx];
        }

        /// Get slider value by name (0.0 - 1.0)
        pub fn getSlider(self: *const Self, comptime name: []const u8) f32 {
            const idx = comptime layout.findControl(name) orelse @compileError("Control not found: " ++ name);
            return self.slider_values[idx];
        }

        /// Set slider value by name
        pub fn setSlider(self: *Self, comptime name: []const u8, value: f32) void {
            const idx = comptime layout.findControl(name) orelse @compileError("Control not found: " ++ name);
            self.slider_values[idx] = std.math.clamp(value, 0.0, 1.0);
        }

        /// Get toggle state by name
        pub fn getToggle(self: *const Self, comptime name: []const u8) bool {
            const idx = comptime layout.findControl(name) orelse @compileError("Control not found: " ++ name);
            return self.toggle_states[idx];
        }

        /// Set toggle state by name
        pub fn setToggle(self: *Self, comptime name: []const u8, state: bool) void {
            const idx = comptime layout.findControl(name) orelse @compileError("Control not found: " ++ name);
            self.toggle_states[idx] = state;
        }

        /// Set LED color by name
        pub fn setLed(self: *Self, comptime name: []const u8, color: Color) void {
            const idx = comptime layout.findControl(name) orelse @compileError("Control not found: " ++ name);
            self.led_colors[idx] = color;
        }

        /// Set LED strip pixel by name and index
        pub fn setLedPixel(self: *Self, comptime name: []const u8, pixel_idx: usize, color: Color) void {
            const idx = comptime layout.findControl(name) orelse @compileError("Control not found: " ++ name);
            if (idx + pixel_idx < control_count) {
                self.led_colors[idx + pixel_idx] = color;
            }
        }

        /// Add log message
        pub fn log(self: *Self, comptime fmt: []const u8, args: anytype) void {
            const msg = std.fmt.bufPrint(&self.log_lines[self.log_next], fmt, args) catch return;
            self.log_lens[self.log_next] = msg.len;
            self.log_next = (self.log_next + 1) % 32;
            if (self.log_count < 32) self.log_count += 1;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseLayout basic" {
    const content =
        \\# Test layout
        \\c 000 5 btn_test 10 20 100 30 0 Test
    ;
    const layout = comptime parseLayout(content);
    try std.testing.expectEqual(@as(usize, 1), layout.count);
    try std.testing.expectEqualStrings("btn_test", layout.controls[0].name);
}
