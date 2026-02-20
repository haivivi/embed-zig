//! Board Definition: Desktop (macOS/Linux) via PortAudio
//!
//! Provides mic and speaker drivers using PortAudio for the std platform.
//! Used by e2e tests and desktop demos — same app.zig runs on ESP and desktop.
//!
//! Usage:
//!   const board = @import("std_impl").boards.desktop;
//!   var mic_drv = try board.MicDriver.init(.{});
//!   var spk_drv = try board.SpeakerDriver.init(.{});

const pa = @import("portaudio");
const mic_impl = @import("../impl/mic.zig");
const speaker_impl = @import("../impl/speaker.zig");

pub const name = "desktop-portaudio";
pub const sample_rate: u32 = 16000;

pub const MicDriver = mic_impl.Driver;
pub const MicConfig = mic_impl.Config;
pub const SpeakerDriver = speaker_impl.Driver;
pub const SpeakerConfig = speaker_impl.Config;

pub fn initPortAudio() !void {
    try pa.init();
}

pub fn deinitPortAudio() void {
    pa.deinit();
}

pub fn deviceInfo() void {
    const std = @import("std");
    const in_dev = pa.defaultInputDevice();
    const out_dev = pa.defaultOutputDevice();
    if (pa.deviceInfo(in_dev)) |info| {
        std.debug.print("Input:  {s}\n", .{info.name});
    }
    if (pa.deviceInfo(out_dev)) |info| {
        std.debug.print("Output: {s}\n", .{info.name});
    }
}
