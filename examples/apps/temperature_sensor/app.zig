//! Temperature Sensor Application - Platform Independent
//!
//! Demonstrates internal temperature sensor:
//! - Initialize temperature sensor
//! - Read chip temperature periodically
//! - Display temperature statistics

const hal = @import("hal");

const platform = @import("platform.zig");

const Board = platform.Board;
const log = Board.log;

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("Temperature Sensor Example", .{});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Board initialized", .{});
    log.info("Note: This is chip internal temperature, not ambient!", .{});
    log.info("", .{});

    var reading_count: u32 = 0;
    var min_temp: i32 = 100;
    var max_temp: i32 = -100;

    while (true) {
        reading_count += 1;

        // Read temperature
        const temp = board.temp.readCelsius() catch |err| {
            log.err("Failed to read temperature: {}", .{err});
            Board.time.sleepMs(1000);
            continue;
        };

        // Convert to integer for simpler display
        const temp_int: i32 = @intFromFloat(temp);

        // Update statistics
        if (temp_int < min_temp) min_temp = temp_int;
        if (temp_int > max_temp) max_temp = temp_int;

        // Display reading
        log.info("Reading #{}: {}C (min: {}, max: {})", .{
            reading_count,
            temp_int,
            min_temp,
            max_temp,
        });

        Board.time.sleepMs(2000);
    }
}
