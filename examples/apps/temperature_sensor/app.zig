//! Temperature Sensor Application - Platform Independent
//!
//! Demonstrates internal temperature sensor:
//! - Initialize temperature sensor
//! - Read chip temperature periodically
//! - Display temperature statistics

const platform = @import("platform");
const hal = @import("hal");
const sal = platform.sal;

const Board = hal.Board(platform.spec);

pub fn run() void {
    sal.log.info("==========================================", .{});
    sal.log.info("Temperature Sensor Example", .{});
    sal.log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        sal.log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    sal.log.info("Board initialized", .{});
    sal.log.info("Note: This is chip internal temperature, not ambient!", .{});
    sal.log.info("", .{});

    var reading_count: u32 = 0;
    var min_temp: i32 = 100;
    var max_temp: i32 = -100;

    while (true) {
        reading_count += 1;

        // Read temperature
        const temp = board.temp.readCelsius() catch |err| {
            sal.log.err("Failed to read temperature: {}", .{err});
            sal.sleepMs(1000);
            continue;
        };

        // Convert to integer for simpler display
        const temp_int: i32 = @intFromFloat(temp);

        // Update statistics
        if (temp_int < min_temp) min_temp = temp_int;
        if (temp_int > max_temp) max_temp = temp_int;

        // Display reading
        sal.log.info("Reading #{}: {}C (min: {}, max: {})", .{
            reading_count,
            temp_int,
            min_temp,
            max_temp,
        });

        sal.sleepMs(2000);
    }
}
