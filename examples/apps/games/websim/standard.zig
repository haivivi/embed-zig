//! WebSim Games Board wiring

const websim = @import("websim");
const hal = @import("hal");
const board = websim.boards.h106;

pub const name = "WebSim Games";
pub const ButtonId = board.ButtonId;
pub const adc_button_spec = board.adc_button_spec;
pub const led_spec = board.led_spec;
pub const log = board.log;
pub const time = board.time;
pub const isRunning = board.isRunning;

pub const power_button_spec = struct {
    pub const Driver = websim.PowerButtonDriver;
    pub const meta = .{ .id = "button.power" };
};

pub const rtc_spec = struct {
    pub const Driver = websim.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

// Fonts embedded from @fonts Bazel repo
pub const font_phosphor = @embedFile("../assets/Phosphor-Bold.ttf");
pub const font_text = @embedFile("../assets/PressStart2P.ttf");

pub const FsDriver = websim.EmbedFs(&.{
    .{ .path = "/fonts/Phosphor-Bold.ttf", .data = font_phosphor },
    .{ .path = "/fonts/PressStart2P.ttf", .data = font_text },
});

pub const fs_spec = struct {
    pub const Driver = FsDriver;
    pub const meta = .{ .id = "fs.assets" };
};
