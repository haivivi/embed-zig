//! Motion Detection Test Application
//!
//! Demonstrates motion detection using QMI8658 6-axis IMU:
//! - Shake detection
//! - Tap detection (single and double)
//! - Tilt detection
//! - Flip detection (orientation change)
//!
//! Architecture (Event-Driven):
//! - hal.motion: Polls IMU and runs detection algorithms
//! - Motion events are delivered via board.nextEvent()
//!
//! This demonstrates the unified event architecture where all peripheral
//! events (buttons, motion, wifi, etc.) come through board's event queue.

const platform = @import("platform.zig");

const Board = platform.Board;
const log = Board.log;

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("Motion Detection Test (Event-Driven)", .{});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Board initialized with QMI8658 IMU", .{});
    log.info("Motion gyro support: {}", .{Board.Motion.has_gyroscope});
    log.info("", .{});
    log.info("Try these motions:", .{});
    log.info("  - SHAKE: Move the board quickly back and forth", .{});
    log.info("  - TAP: Give the board a quick tap", .{});
    log.info("  - TILT: Slowly tilt the board", .{});
    if (Board.Motion.has_gyroscope) {
        log.info("  - FLIP: Turn the board over", .{});
        log.info("  - FREEFALL: Drop the board (carefully!)", .{});
    }
    log.info("", .{});

    var event_count: u32 = 0;
    var shake_count: u32 = 0;
    var tap_count: u32 = 0;
    var tilt_count: u32 = 0;
    var flip_count: u32 = 0;
    var debug_counter: u32 = 0;

    while (Board.isRunning()) {
        // Poll motion sensor - events are pushed directly to board queue via callback
        // (in production, do this in a background task)
        board.motion.poll();

        // Debug: print raw IMU data every 50 iterations (~1 second)
        debug_counter += 1;
        if (debug_counter >= 50) {
            debug_counter = 0;
            if (board.motion_imu.readAccel()) |accel| {
                // Scale up for display (multiply by 1000 to see 3 decimal places)
                const ax: i32 = @intFromFloat(accel.x * 1000);
                const ay: i32 = @intFromFloat(accel.y * 1000);
                const az: i32 = @intFromFloat(accel.z * 1000);
                log.info("[DEBUG] accel: x={d} y={d} z={d} (milli-g)", .{ ax, ay, az });
            } else |_| {
                log.warn("[DEBUG] Failed to read accel", .{});
            }
        }

        // Process all events from the unified queue
        while (board.nextEvent()) |event| {
            switch (event) {
                .motion => |m| {
                    event_count += 1;
                    log.info("", .{});
                    log.info("[Motion Event #{} from {s}]", .{ event_count, m.source });

                    switch (m.action) {
                        .shake => |s| {
                            shake_count += 1;
                            log.info("  SHAKE detected!", .{});
                            const mag_int: u32 = @intFromFloat(s.magnitude * 100);
                            log.info("    Magnitude: {}.{}g", .{ mag_int / 100, mag_int % 100 });
                            log.info("    Duration: {}ms", .{s.duration_ms});
                            log.info("    Total shakes: {}", .{shake_count});
                        },
                        .tap => |t| {
                            tap_count += 1;
                            const tap_type = if (t.count == 2) "DOUBLE TAP" else "TAP";
                            log.info("  {s} detected!", .{tap_type});
                            log.info("    Axis: {s}", .{@tagName(t.axis)});
                            log.info("    Count: {}", .{t.count});
                            log.info("    Total taps: {}", .{tap_count});
                        },
                        .tilt => |t| {
                            tilt_count += 1;
                            log.info("  TILT detected!", .{});
                            const roll_int: i32 = @intFromFloat(t.roll * 10);
                            const pitch_int: i32 = @intFromFloat(t.pitch * 10);
                            log.info("    Roll: {}.{} degrees", .{ @divTrunc(roll_int, 10), @mod(@abs(roll_int), 10) });
                            log.info("    Pitch: {}.{} degrees", .{ @divTrunc(pitch_int, 10), @mod(@abs(pitch_int), 10) });
                            log.info("    Total tilts: {}", .{tilt_count});
                        },
                        .flip => |f| {
                            flip_count += 1;
                            log.info("  FLIP detected!", .{});
                            log.info("    From: {s}", .{@tagName(f.from)});
                            log.info("    To: {s}", .{@tagName(f.to)});
                            log.info("    Total flips: {}", .{flip_count});
                        },
                        .freefall => |f| {
                            log.info("  FREEFALL detected!", .{});
                            log.info("    Duration: {}ms", .{f.duration_ms});
                        },
                    }
                },
                .button => |btn| {
                    log.info("Button: {s} - {s}", .{ @tagName(btn.id), @tagName(btn.action) });
                },
                else => {},
            }
        }

        // Small delay to avoid busy-waiting
        Board.time.sleepMs(20);
    }

    log.info("", .{});
    log.info("==========================================", .{});
    log.info("Session Summary:", .{});
    log.info("  Total events: {}", .{event_count});
    log.info("  Shakes: {}", .{shake_count});
    log.info("  Taps: {}", .{tap_count});
    log.info("  Tilts: {}", .{tilt_count});
    log.info("  Flips: {}", .{flip_count});
    log.info("==========================================", .{});
}
