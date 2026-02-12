//! BK7258 AudioSystem — Speaker + Mic + AEC
//!
//! Combines direct DAC FIFO speaker, direct ADC FIFO mic, and Armino's
//! standalone AEC library (via C helper). No pipeline, no extra tasks.
//!
//! Interface matches ESP's AudioSystem: readMic() / writeSpeaker() / setVolume()

const armino = @import("../../armino/src/armino.zig");

pub const AudioSystem = struct {
    const Self = @This();

    speaker: armino.speaker.Speaker = .{},
    mic: armino.mic.Mic = .{},
    aec: armino.aec.Aec = undefined,
    initialized: bool = false,

    // Reference buffer: stores last speaker output frame for AEC
    last_ref: [320]i16 = .{0} ** 320,

    pub fn init() !Self {
        return initWithRate(8000);
    }

    pub fn initWithRate(sample_rate: u32) !Self {
        var self = Self{};

        const board = @import("../../src/boards/bk7258.zig");

        // Init speaker first
        self.speaker = armino.speaker.Speaker.init(
            sample_rate, 1, 16, board.audio.dig_gain,
        ) catch return error.SpeakerInitFailed;

        // Init mic
        self.mic = armino.mic.Mic.init(
            sample_rate, 1, board.audio.mic_dig_gain, board.audio.mic_ana_gain,
        ) catch {
            self.speaker.deinit();
            return error.MicInitFailed;
        };

        // Init AEC
        self.aec = armino.aec.Aec.init(1000, @intCast(sample_rate)) catch {
            self.mic.deinit();
            self.speaker.deinit();
            return error.AecInitFailed;
        };

        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (!self.initialized) return;
        self.aec.deinit();
        self.mic.deinit();
        self.speaker.deinit();
        self.initialized = false;
    }

    /// Write audio to speaker and save as AEC reference.
    pub fn writeSpeaker(self: *Self, buffer: []const i16) !usize {
        if (!self.initialized) return error.NotInitialized;
        const written = try self.speaker.write(buffer);
        // Save as reference for next AEC frame
        const n = @min(written, self.last_ref.len);
        @memcpy(self.last_ref[0..n], buffer[0..n]);
        return written;
    }

    /// Read echo-cancelled audio from microphone.
    pub fn readMic(self: *Self, buffer: []i16) !usize {
        if (!self.initialized) return error.NotInitialized;

        const frame_size = self.aec.getFrameSamples();
        const to_read = @min(buffer.len, frame_size);

        var mic_raw: [320]i16 = undefined;
        const mic_read = try self.mic.read(mic_raw[0..to_read]);
        if (mic_read == 0) return 0;

        // AEC: ref + mic → cleaned output
        self.aec.process(
            self.last_ref[0..mic_read],
            mic_raw[0..mic_read],
            buffer[0..mic_read],
        );

        return mic_read;
    }

    pub fn getFrameSize(self: *const Self) usize {
        return self.aec.getFrameSamples();
    }

    pub fn setVolume(_: *Self, volume: u8) void {
        armino.speaker.setVolume(volume);
    }
};
