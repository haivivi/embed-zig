//! Internal Temperature Sensor Example - Zig Version
//!
//! Demonstrates the internal temperature sensor:
//! - Initialize temperature sensor with default range
//! - Read chip temperature periodically
//! - Display temperature in Celsius
//!
//! Note: This reads the chip's internal temperature, not ambient temperature.
//! The reading is affected by chip operation and may be 10-20°C higher than ambient.

const std = @import("std");
const idf = @import("esp");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("Temperature Sensor Example - Zig Version", .{});
    std.log.info("==========================================", .{});

    // Initialize temperature sensor
    var temp_sensor = idf.adc.TempSensor.init(.{
        .range = .{ .min = -10, .max = 80 },
    }) catch |err| {
        std.log.err("Failed to initialize temperature sensor: {}", .{err});
        return;
    };
    defer temp_sensor.deinit();

    // Enable sensor
    temp_sensor.enable() catch |err| {
        std.log.err("Failed to enable temperature sensor: {}", .{err});
        return;
    };

    std.log.info("Temperature sensor initialized (range: -10 to 80°C)", .{});
    std.log.info("Note: This is chip internal temperature, not ambient!", .{});
    std.log.info("", .{});

    var reading_count: u32 = 0;
    var min_temp: i32 = 100;
    var max_temp: i32 = -100;

    while (true) {
        reading_count += 1;

        // Read temperature
        const temp = temp_sensor.readCelsius() catch |err| {
            std.log.err("Failed to read temperature: {}", .{err});
            idf.delayMs(1000);
            continue;
        };

        // Convert to integer for simpler display
        const temp_int: i32 = @intFromFloat(temp);

        // Update statistics
        if (temp_int < min_temp) min_temp = temp_int;
        if (temp_int > max_temp) max_temp = temp_int;

        // Display reading (using integer to avoid 128-bit division issues)
        std.log.info("Reading #{}: {}C (min: {}, max: {})", .{
            reading_count,
            temp_int,
            min_temp,
            max_temp,
        });

        idf.delayMs(2000);
    }
}
