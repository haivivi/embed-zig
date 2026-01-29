//! Microphone Implementation for ESP32
//!
//! Implements hal.mic Driver interface using idf.mic.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const mic_spec = struct {
//!       pub const Driver = impl.MicDriver;
//!       pub const meta = .{ .id = "mic.main" };
//!       pub const config = hal.MicConfig{ .sample_rate = 16000 };
//!   };
//!   const Mic = hal.mic.from(mic_spec);

const idf = @import("idf");

/// Microphone Driver that implements hal.mic.Driver interface
pub const MicDriver = struct {
    const Self = @This();

    mic: idf.Mic,

    /// Initialize microphone driver
    pub fn init(config: idf.MicConfig) !Self {
        const mic = try idf.Mic.init(config);
        return .{ .mic = mic };
    }

    /// Deinitialize microphone driver
    pub fn deinit(self: *Self) void {
        self.mic.deinit();
    }

    /// Read audio samples (required by hal.mic)
    /// Blocking read, returns number of samples read
    pub fn read(self: *Self, buffer: []i16) !usize {
        return self.mic.read(buffer);
    }

    /// Set microphone gain (optional for hal.mic)
    pub fn setGain(self: *Self, gain_db: i8) !void {
        return self.mic.setGain(gain_db);
    }

    /// Start recording (optional for hal.mic)
    pub fn start(self: *Self) !void {
        return self.mic.start();
    }

    /// Stop recording (optional for hal.mic)
    pub fn stop(self: *Self) !void {
        return self.mic.stop();
    }
};

// Re-export config types
pub const Config = idf.MicConfig;
pub const ChannelRole = idf.ChannelRole;
