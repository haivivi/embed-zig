//! BK7258 AudioSystem — Speaker + Mic + AEC
//!
//! Combines direct DAC FIFO speaker, direct ADC FIFO mic, and Armino's
//! standalone AEC library. No pipeline, no extra tasks.
//!
//! Interface matches ESP's AudioSystem: readMic() / writeSpeaker() / setVolume()
//!
//! Usage:
//!   var audio = try AudioSystem.init();
//!   defer audio.deinit();
//!
//!   // Write audio to speaker (also saves as AEC reference)
//!   _ = try audio.writeSpeaker(&playback_buffer);
//!
//!   // Read echo-cancelled audio from microphone
//!   const n = try audio.readMic(&mic_buffer);

const armino = @import("../../armino/src/armino.zig");

pub const AudioSystem = struct {
    const Self = @This();

    speaker: armino.speaker.Speaker = .{},
    mic: armino.mic.Mic = .{},
    aec: armino.aec.Aec = undefined,
    initialized: bool = false,

    // Reference ring buffer: stores recent speaker output for AEC
    ref_ring: [1280]i16 = .{0} ** 1280, // ~80ms at 16kHz or ~160ms at 8kHz
    ref_write_pos: u32 = 0,
    ref_read_pos: u32 = 0,

    pub fn init() !Self {
        return initWithRate(8000);
    }

    pub fn initWithRate(sample_rate: u32) !Self {
        var self = Self{};

        const board = @import("../../src/boards/bk7258.zig");
        const gain = board.audio.dig_gain;
        const mic_gain = board.audio.mic_gain;

        // Init speaker (DAC)
        self.speaker = armino.speaker.Speaker.init(
            sample_rate, 1, 16, gain,
        ) catch return error.SpeakerInitFailed;

        // Init mic (ADC)
        self.mic = armino.mic.Mic.init(
            sample_rate, 1, mic_gain,
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
    /// Returns number of samples written.
    pub fn writeSpeaker(self: *Self, buffer: []const i16) !usize {
        if (!self.initialized) return error.NotInitialized;

        // Write to DAC
        const written = try self.speaker.write(buffer);

        // Save to reference ring buffer for AEC
        for (buffer[0..written]) |sample| {
            self.ref_ring[self.ref_write_pos % self.ref_ring.len] = sample;
            self.ref_write_pos +%= 1;
        }

        return written;
    }

    /// Read echo-cancelled audio from microphone.
    /// Returns number of samples read.
    pub fn readMic(self: *Self, buffer: []i16) !usize {
        if (!self.initialized) return error.NotInitialized;

        const frame_size = self.aec.getFrameSamples();
        const to_read = @min(buffer.len, frame_size);

        // Read raw mic data
        var mic_raw: [320]i16 = undefined;
        const mic_read = try self.mic.read(mic_raw[0..to_read]);
        if (mic_read == 0) return 0;

        // Get reference data from ring buffer
        var ref_data: [320]i16 = undefined;
        for (0..mic_read) |i| {
            ref_data[i] = self.ref_ring[self.ref_read_pos % self.ref_ring.len];
            self.ref_read_pos +%= 1;
        }

        // Run AEC: ref + mic → cleaned output
        self.aec.process(
            ref_data[0..mic_read],
            mic_raw[0..mic_read],
            buffer[0..mic_read],
        );

        return mic_read;
    }

    /// Get optimal frame size for readMic calls
    pub fn getFrameSize(self: *const Self) usize {
        return self.aec.getFrameSamples();
    }

    /// Set speaker volume. BK range: 0x00-0x3F.
    pub fn setVolume(_: *Self, volume: u8) void {
        armino.speaker.setVolume(volume);
    }
};
