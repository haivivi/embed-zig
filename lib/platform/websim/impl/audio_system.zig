//! WebSim AudioSystem — unified mic + speaker with simulated AEC.
//!
//! Provides the same interface as the ESP AudioSystem (ES7210 + ES8311 + AEC),
//! but uses SharedState ring buffers for audio I/O.
//!
//! AEC is handled on the browser side via WebRTC's echoCancellation constraint
//! in getUserMedia(). The Zig side just reads/writes ring buffers.

const state_mod = @import("state.zig");
const shared = &state_mod.state;

pub const AudioSystem = struct {
    const Self = @This();

    volume: u8 = 100,

    /// Initialize the audio system.
    /// On ESP this sets up I2S + codec via I2C. On WebSim it's a no-op
    /// (JS handles Web Audio setup on first user interaction).
    pub fn init(_: anytype) !Self {
        shared.addLog("WebSim: AudioSystem initialized (AEC via WebRTC)");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Read AEC-processed microphone samples.
    /// Returns the number of samples actually read.
    pub fn readMic(_: *Self, buffer: []i16) !usize {
        return @as(usize, shared.audioInRead(buffer));
    }

    /// Write samples to the speaker.
    /// Returns the number of samples actually written.
    pub fn writeSpeaker(self: *Self, samples: []const i16) !usize {
        // Fast path: no volume scaling needed
        if (self.volume == 255) {
            return @as(usize, shared.audioOutWrite(samples));
        }

        // Apply volume scaling in chunks (512-sample stack buffer)
        const vol: i32 = @as(i32, self.volume);
        var scaled: [512]i16 = undefined;
        var total_written: usize = 0;
        var offset: usize = 0;

        while (offset < samples.len) {
            const chunk_len = @min(samples.len - offset, scaled.len);
            for (0..chunk_len) |i| {
                const s: i32 = @divTrunc(@as(i32, samples[offset + i]) * vol, 255);
                scaled[i] = @intCast(@max(-32768, @min(32767, s)));
            }
            total_written += @as(usize, shared.audioOutWrite(scaled[0..chunk_len]));
            offset += chunk_len;
        }
        return total_written;
    }

    /// Set speaker volume (0-255).
    pub fn setVolume(self: *Self, vol: u32) void {
        self.volume = @intCast(@min(vol, 255));
    }

    /// Get current volume.
    pub fn getVolume(self: *Self) u8 {
        return self.volume;
    }
};

/// Simulated PA (Power Amplifier) switch.
/// On ESP this controls a GPIO pin. On WebSim it just sets a flag
/// (JS could use this to mute/unmute audio output).
pub const PaSwitchDriver = struct {
    const Self = @This();

    enabled: bool = false,

    pub fn init(_: anytype) !Self {
        shared.addLog("WebSim: PA switch initialized");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn on(self: *Self) !void {
        self.enabled = true;
        shared.addLog("WebSim: PA switch ON");
    }

    pub fn off(self: *Self) !void {
        self.enabled = false;
        shared.addLog("WebSim: PA switch OFF");
    }

    pub fn isOn(self: *Self) bool {
        return self.enabled;
    }
};
