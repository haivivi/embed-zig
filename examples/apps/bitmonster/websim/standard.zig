//! WebSim BitMonster Board wiring

const websim = @import("websim");
const board = websim.boards.bitmonster;

pub const ButtonId = board.ButtonId;
pub const adc_button_spec = board.adc_button_spec;
pub const power_button_spec = board.power_button_spec;
pub const rtc_spec = board.rtc_spec;

pub const FsDriver = websim.EmbedFs(&.{
    // No assets yet — will add pixel art later
});

pub const fs_spec = struct {
    pub const Driver = FsDriver;
    pub const meta = .{ .id = "fs.assets" };
};
