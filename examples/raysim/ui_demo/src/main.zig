//! raysim Demo
//!
//! Demonstrates all raysim components:
//! - 8 LED Strip with rainbow animation
//! - Buttons (Boot, Reset)
//! - ADC Slider
//! - PWM Progress Bar
//! - Brightness Control
//! - Log Panel

const std = @import("std");
const raysim = @import("raysim");

// Parse layout at comptime
const layout = raysim.parseLayout(@embedFile("board_demo.rgl"));

// Create simulator type
const Sim = raysim.Simulator(layout);

pub fn main() !void {
    var sim = Sim.init(.{
        .title = "raysim Demo - HAL Hardware Simulator",
        .width = 700,
        .height = 500,
        .fps = 60,
    });
    defer sim.deinit();

    sim.log("raysim Demo Started", .{});
    sim.log("Press BOOT or RESET buttons", .{});
    sim.log("Adjust sliders to control LEDs", .{});

    var frame: u64 = 0;
    var led_state = false;
    var rainbow_offset: u8 = 0;

    while (sim.running()) {
        sim.update();
        frame += 1;

        // Handle Boot button
        if (sim.getButton("btn_boot")) {
            if (!led_state) {
                led_state = true;
                sim.log("Boot button pressed - LED ON", .{});
                sim.setLed("led_status", raysim.Color.init(0, 255, 0, 255));
            }
        } else {
            if (led_state) {
                led_state = false;
                sim.log("Boot button released - LED OFF", .{});
                sim.setLed("led_status", raysim.Color.black);
            }
        }

        // Handle Reset button
        if (sim.getButton("btn_reset")) {
            rainbow_offset = 0;
            sim.log("Reset pressed - Animation reset", .{});
        }

        // Get slider values
        const adc_value = sim.getSlider("slider_adc");
        const brightness = sim.getSlider("slider_brightness");

        // Update PWM display based on ADC
        sim.setSlider("progress_pwm", adc_value);

        // Rainbow LED strip animation
        if (frame % 3 == 0) {
            rainbow_offset +%= 8;
        }

        // Set LED strip colors with brightness
        for (0..8) |i| {
            const hue: u8 = @truncate(rainbow_offset +% @as(u8, @intCast(i * 32)));
            var color = hsvToRgb(hue, 255, 255);
            
            // Apply brightness
            color.r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * brightness);
            color.g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * brightness);
            color.b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * brightness);
            
            sim.setLedPixel("led_strip", i, color);
        }

        // Log ADC changes periodically
        if (frame % 60 == 0 and adc_value > 0.01) {
            const adc_int: u32 = @intFromFloat(adc_value * 1023);
            sim.log("ADC: {d} ({d}%)", .{ adc_int, @as(u32, @intFromFloat(adc_value * 100)) });
        }

        sim.draw();
    }
}

/// HSV to RGB conversion
fn hsvToRgb(h: u8, s: u8, v: u8) raysim.Color {
    if (s == 0) {
        return raysim.Color.init(v, v, v, 255);
    }

    const region = h / 43;
    const remainder = (h - (region * 43)) * 6;

    const p: u8 = @intCast((@as(u16, v) * (255 - s)) >> 8);
    const q: u8 = @intCast((@as(u16, v) * (255 - ((@as(u16, s) * remainder) >> 8))) >> 8);
    const t: u8 = @intCast((@as(u16, v) * (255 - ((@as(u16, s) * (255 - remainder)) >> 8))) >> 8);

    return switch (region) {
        0 => raysim.Color.init(v, t, p, 255),
        1 => raysim.Color.init(q, v, p, 255),
        2 => raysim.Color.init(p, v, t, 255),
        3 => raysim.Color.init(p, q, v, 255),
        4 => raysim.Color.init(t, p, v, 255),
        else => raysim.Color.init(v, p, q, 255),
    };
}
