//! GPIO Button Simulator
//!
//! Runs the gpio_button app with a raylib UI.

const std = @import("std");
const raysim = @import("raysim");
const app = @import("app");

// Access shared sim state from raysim
const sim_state = raysim.sim_state;

// Parse layout at comptime
const layout = raysim.parseLayout(@embedFile("gpio_button.rgl"));

// Track last synced log count
var last_log_count: usize = 0;

// Track last button state for edge detection logging
var last_ui_pressed: bool = false;

// Track LED state for debug logging
var last_led_on: bool = false;

pub fn main() void {
    // Initialize debug log
    raysim.sim_state_mod.initDebugLog();
    defer raysim.sim_state_mod.deinitDebugLog();

    // Initialize simulator
    var sim = raysim.Simulator(layout).init(.{
        .title = "GPIO Button - HAL Simulator",
        .width = 400,
        .height = 500,
    });
    defer sim.deinit();

    // Start app in background thread
    const app_thread = std.Thread.spawn(.{}, runApp, .{}) catch {
        sim.log("Failed to start app thread", .{});
        return;
    };

    // Main UI loop
    while (sim.running()) {
        // Update button state from UI (mouse click or space key)
        const pressed = sim.getButton("btn_boot") or
            raysim.widgets.rl.isKeyDown(.space);
        
        // Debug: log UI state changes
        if (pressed != last_ui_pressed) {
            raysim.sim_state_mod.debugLog("[UI] Button state: {} -> {}\n", .{ last_ui_pressed, pressed });
            last_ui_pressed = pressed;
        }
        
        sim_state.setButtonPressed(pressed);

        sim.update();

        // Sync LED state from app (first LED in strip)
        const color = sim_state.led_colors[0];
        const ui_color = raysim.Color.init(color.r, color.g, color.b, 255);
        
        // Debug: track LED color sync
        const is_on = (color.r > 0 or color.g > 0 or color.b > 0);
        if (is_on != last_led_on) {
            raysim.sim_state_mod.debugLog("[UI-LED] sim_state color: rgb({},{},{}) -> UI: {s}\n", .{ 
                color.r, color.g, color.b, 
                if (is_on) "ON" else "OFF" 
            });
            last_led_on = is_on;
        }
        
        sim.setLed("led_main", ui_color);

        // Sync logs from app
        syncLogs(&sim);

        sim.draw();
    }

    // Signal app thread to stop and wait for it
    sim_state.stop();
    app_thread.join();
}

fn runApp() void {
    app.run();
}

fn syncLogs(sim: anytype) void {
    const count = sim_state.log_count;
    
    // Sync new logs
    while (last_log_count < count) : (last_log_count += 1) {
        if (sim_state.getLogLine(last_log_count)) |log_line| {
            sim.log("{s}", .{log_line});
        }
    }
}
