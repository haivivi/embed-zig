//! PortAudio Microphone Driver — hal.mic.Driver implementation for std platform
//!
//! Wraps PortAudio InputStream to satisfy the hal.mic Driver contract.
//! Provides blocking read() that captures PCM from the system default input device.

const pa = @import("portaudio");

pub const Config = struct {
    sample_rate: u32 = 16000,
    frames_per_buffer: u32 = 160,
};

pub const Driver = struct {
    stream: pa.InputStream(i16),
    started: bool,

    pub fn init(config: Config) !Driver {
        var stream = try pa.InputStream(i16).open(.{
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

    pub fn read(self: *Driver, buffer: []i16) !usize {
        try self.stream.read(buffer);
        return buffer.len;
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
