//! Platform Configuration - AEC Test (WebSim Native)
//!
//! Uses WebSim's AudioSystem (ring buffers + WebRTC AEC in browser)
//! instead of ESP's I2S + ES7210/ES8311 codecs.

const websim = @import("websim");
const board = websim.boards.korvo2_v3;

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = "websim";
    pub const sample_rate = board.sample_rate;
    pub const pa_enable_gpio = 0;
};

pub const log = board.log;
pub const time = board.time;
pub fn isRunning() bool {
    return board.isRunning();
}

pub const AudioSystem = board.AudioSystem;
pub const PaSwitchDriver = board.PaSwitchDriver;

/// Board struct for AEC test — matches ESP version's interface
pub const Board = struct {
    const Self = @This();

    pub const log = board.log;
    pub const time = board.time;

    audio: AudioSystem,
    pa_switch: PaSwitchDriver,

    pub fn init(self: *Self) !void {
        // WebSim AudioSystem doesn't need I2C — just initialize directly
        self.audio = try AudioSystem.init(.{});
        self.pa_switch = try PaSwitchDriver.init(.{});
    }

    pub fn deinit(self: *Self) void {
        self.pa_switch.deinit();
        self.audio.deinit();
    }
};
