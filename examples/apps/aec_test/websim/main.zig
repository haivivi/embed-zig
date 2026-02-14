//! Native WebSim entry point for aec_test
//!
//! AEC loopback: mic -> gain -> speaker.
//! Mic uses WebRTC echoCancellation in the browser.

const std = @import("std");
const websim = @import("websim");
const platform = @import("platform.zig");

const Board = platform.Board;
const log = platform.log;

const SAMPLE_RATE: u32 = platform.Hardware.sample_rate;
const BUFFER_SIZE: usize = 256;
const MIC_GAIN: i32 = 16;

const html = @embedFile("native_shell.html");

var board: Board = undefined;
var initialized: bool = false;

pub fn init() void {
    log.info("==========================================", .{});
    log.info("AEC (Echo Cancellation) Test - WebSim", .{});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{platform.Hardware.name});
    log.info("Sample Rate: {}Hz", .{SAMPLE_RATE});
    log.info("Buffer Size: {} samples", .{BUFFER_SIZE});
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

    log.info("Board initialized. Click MIC button to start.", .{});
    log.info("Speak into mic - AEC cancels speaker feedback.", .{});
}

pub fn step() void {
    if (!initialized) return;

    var input_buffer: [BUFFER_SIZE]i16 = undefined;
    var output_buffer: [BUFFER_SIZE]i16 = undefined;

    // Read from microphone (AEC-processed via WebRTC)
    const samples_read = board.audio.readMic(&input_buffer) catch {
        return;
    };

    if (samples_read == 0) return;

    // Apply gain
    for (0..samples_read) |i| {
        const amplified: i32 = @as(i32, input_buffer[i]) * MIC_GAIN;
        output_buffer[i] = @intCast(std.math.clamp(amplified, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    // Play through speaker
    _ = board.audio.writeSpeaker(output_buffer[0..samples_read]) catch {
        return;
    };
}

pub fn main() !void {
    websim.native.run(@This(), html);
}
