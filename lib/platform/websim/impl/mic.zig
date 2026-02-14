//! WebSim Microphone Simulation Driver
//!
//! Reads PCM audio samples from SharedState ring buffer.
//! JS captures audio via getUserMedia + AudioWorklet and writes
//! samples to the buffer via WASM exports.
//!
//! Data flow:
//!   Browser mic → getUserMedia → AudioWorklet/ScriptProcessor
//!     → JS writes via setAudioInSample/advanceAudioInWrite
//!       → SharedState.audio_in_buf
//!         → Zig app ← mic.read(buffer)
//!
//! Non-blocking: read() returns whatever samples are available
//! in the ring buffer (may be 0 if JS hasn't captured yet).

const state_mod = @import("state.zig");
const shared = &state_mod.state;

/// Simulated microphone driver for WebSim.
///
/// Satisfies hal.mic Driver required interface:
/// - read(buffer: []i16) !usize
/// Plus optional: setGain, start, stop
pub const MicDriver = struct {
    const Self = @This();

    recording: bool = true,
    gain_db: i8 = 24,

    pub fn init() !Self {
        shared.addLog("WebSim: Microphone ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    // ================================================================
    // Required: read
    // ================================================================

    /// Read audio samples from the input ring buffer (non-blocking).
    /// Returns the number of samples actually read.
    /// Returns 0 if no samples are available from JS audio capture.
    pub fn read(self: *Self, buffer: []i16) !usize {
        if (!self.recording) return 0;
        return @as(usize, shared.audioInRead(buffer));
    }

    // ================================================================
    // Optional: setGain / start / stop
    // ================================================================

    pub fn setGain(self: *Self, gain_db: i8) !void {
        self.gain_db = gain_db;
    }

    pub fn start(self: *Self) !void {
        self.recording = true;
        shared.addLog("WebSim: Mic recording started");
    }

    pub fn stop(self: *Self) !void {
        self.recording = false;
        shared.addLog("WebSim: Mic recording stopped");
    }
};
