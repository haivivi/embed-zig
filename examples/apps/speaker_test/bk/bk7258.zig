//! BK7258 Board Configuration for Speaker Test
//!
//! Uses onboard DAC via Armino audio pipeline (not I2S + external DAC).
//! No external PA switch — the onboard DAC handles everything.

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

pub const Hardware = struct {
    pub const name = board.name;
    pub const sample_rate: u32 = board.audio.sample_rate;
    pub const pa_enable_gpio: u8 = 0; // No external PA
};

const rtc_spec = struct {
    pub const Driver = board.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

const speaker_spec = struct {
    pub const Driver = board.SpeakerDriver;
    pub const meta = .{ .id = "speaker.onboard" };
    pub const config = hal.MonoSpeakerConfig{ .sample_rate = Hardware.sample_rate };
};

const pa_switch_spec = struct {
    pub const Driver = board.PaSwitchDriver;
    pub const meta = .{ .id = "switch.pa" };
};

pub const spec = struct {
    pub const meta = .{ .id = Hardware.name };
    pub const rtc = hal.rtc.reader.from(rtc_spec);
    pub const log = board.log;
    pub const time = board.time;
    pub const speaker = hal.mono_speaker.from(speaker_spec);
    pub const pa_switch = hal.switch_.from(pa_switch_spec);
};
