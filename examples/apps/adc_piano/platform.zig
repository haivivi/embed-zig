//! Platform Configuration — ADC Piano
//!
//! ESP: Korvo-2 V3 (ADC buttons + ES8311 speaker)
//! BK:  BK7258 (Matrix keys on GPIO 6/7/8 + onboard DAC speaker)

const hal = @import("hal");
const build_options = @import("build_options");

const BoardEnum = @TypeOf(build_options.board);

const hw = if (@hasField(BoardEnum, "bk7258") and build_options.board == .bk7258)
    @import("bk/bk7258.zig")
else switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
};

pub const Hardware = hw.Hardware;

/// 4 piano keys
pub const ButtonId = enum(u8) {
    do_ = 0,
    re = 1,
    mi = 2,
    fa = 3,

    pub fn name(self: @This()) []const u8 {
        return switch (self) {
            .do_ => "Do",
            .re => "Re",
            .mi => "Mi",
            .fa => "Fa",
        };
    }
};

const OuterButtonId = ButtonId;

/// Board spec — uses button_group for ESP (ADC), button_matrix for BK (GPIO matrix)
const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };
    pub const ButtonId = OuterButtonId;
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
    pub const speaker = hal.mono_speaker.from(hw.speaker_spec);
    pub const pa_switch = hal.switch_.from(hw.pa_switch_spec);

    // Button input: ADC group (ESP) or GPIO matrix (BK)
    pub const buttons = if (@hasDecl(hw, "button_group_spec"))
        hal.button_group.from(hw.button_group_spec, OuterButtonId)
    else if (@hasDecl(hw, "button_matrix_spec"))
        hal.button_matrix.from(hw.button_matrix_spec, OuterButtonId)
    else
        @compileError("no button spec found in hw");
};

pub const Board = hal.Board(spec);
