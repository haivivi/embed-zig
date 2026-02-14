//! WebSim WASM entry point for aec_test
//!
//! AEC loopback: mic -> gain -> speaker via SharedState ring buffers.

const std = @import("std");
const websim = @import("websim");
const platform = @import("platform.zig");

const Board = platform.Board;
const log = platform.log;

const BUFFER_SIZE: usize = 256;
const MIC_GAIN: i32 = 16;

var board: Board = undefined;
var initialized: bool = false;

pub fn init() void {
    log.info("==========================================", .{});
    log.info("AEC (Echo Cancellation) Test - WebSim", .{});
    log.info("Board:       {s}", .{platform.Hardware.name});
    log.info("Sample Rate: {}Hz", .{platform.Hardware.sample_rate});
    log.info("Mic Gain:    {}x", .{MIC_GAIN});
    log.info("==========================================", .{});

    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };

    board.pa_switch.on() catch |err| {
        log.err("Failed to enable PA: {}", .{err});
        return;
    };

    board.audio.setVolume(150);
    initialized = true;
    log.info("Ready! Enable mic in browser to start.", .{});
}

pub fn step() void {
    if (!initialized) return;

    var input_buffer: [BUFFER_SIZE]i16 = undefined;
    var output_buffer: [BUFFER_SIZE]i16 = undefined;

    const samples_read = board.audio.readMic(&input_buffer) catch return;
    if (samples_read == 0) return;

    for (0..samples_read) |i| {
        const amplified: i32 = @as(i32, input_buffer[i]) * MIC_GAIN;
        output_buffer[i] = @intCast(std.math.clamp(amplified, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    _ = board.audio.writeSpeaker(output_buffer[0..samples_read]) catch return;
}

// Board config JSON for dynamic UI rendering in JS
pub const board_config_json = websim.boards.korvo2_v3.board_config_json;

comptime {
    websim.wasm.exportAll(@This());
}
