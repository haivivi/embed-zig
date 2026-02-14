//! WebSim Speaker Simulation Driver
//!
//! Writes PCM audio samples to SharedState ring buffer.
//! JS reads the buffer via WASM exports and plays through Web Audio API.
//!
//! Data flow:
//!   Zig app → speaker.write(buffer) → SharedState.audio_out_buf
//!     → JS reads via getAudioOutPtr/getAudioOutWrite/setAudioOutRead
//!       → AudioContext + ScriptProcessorNode → speaker output
//!
//! Non-blocking: write() copies as many samples as fit in the ring buffer
//! and returns the count. In the frame-based WASM model, the app should
//! write small chunks each step (e.g., 10ms = 160 samples @ 16kHz).

const state_mod = @import("state.zig");
const shared = &state_mod.state;

/// Simulated mono speaker driver for WebSim.
///
/// Satisfies hal.mono_speaker Driver required interface:
/// - write(buffer: []const i16) !usize
/// Plus optional: setVolume, setMute
pub const SpeakerDriver = struct {
    const Self = @This();

    volume: u8 = 200,
    muted: bool = false,

    pub fn init() !Self {
        shared.addLog("WebSim: Speaker ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    // ================================================================
    // Required: write
    // ================================================================

    /// Write audio samples to the output ring buffer (non-blocking).
    /// Returns the number of samples actually written.
    /// If the ring buffer is full, returns less than buffer.len.
    pub fn write(self: *Self, buffer: []const i16) !usize {
        if (self.muted) {
            // Accept but discard samples when muted
            return buffer.len;
        }
        return @as(usize, shared.audioOutWrite(buffer));
    }

    // ================================================================
    // Optional: setVolume / setMute
    // ================================================================

    pub fn setVolume(self: *Self, volume: u8) !void {
        self.volume = volume;
    }

    pub fn setMute(self: *Self, mute: bool) !void {
        self.muted = mute;
    }
};
