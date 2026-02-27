//! PortAudio Speaker Driver — hal.mono_speaker.Driver implementation for std platform
//!
//! Wraps PortAudio OutputStream to satisfy the hal.mono_speaker Driver contract.
//! Provides blocking write() that sends PCM to the system default output device.

const pa = @import("portaudio");

pub const Config = struct {
    sample_rate: u32 = 16000,
    frames_per_buffer: u32 = 160,
};

pub const Driver = struct {
    stream: pa.OutputStream(i16),
    started: bool,

    pub fn init(config: Config) !Driver {
        var stream = try pa.OutputStream(i16).open(.{
            .sample_rate = @floatFromInt(config.sample_rate),
            .channels = 1,
            .frames_per_buffer = config.frames_per_buffer,
        });
        try stream.start();
        return .{ .stream = stream, .started = true };
    }

    pub fn deinit(self: *Driver) void {
        if (self.started) {
            self.stream.stop() catch {};
            self.started = false;
        }
        self.stream.close();
    }

    pub fn write(self: *Driver, buffer: []const i16) !usize {
        try self.stream.write(buffer);
        return buffer.len;
    }

    pub fn setVolume(_: *Driver, _: u8) !void {
        // PortAudio doesn't support per-stream volume; system mixer handles it
    }

    pub fn start(self: *Driver) !void {
        if (!self.started) {
            try self.stream.start();
            self.started = true;
        }
    }

    pub fn stop(self: *Driver) !void {
        if (self.started) {
            try self.stream.stop();
            self.started = false;
        }
    }
};
