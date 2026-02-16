//! Platform Configuration - Speaker Test
//!
//! ESP: Korvo-2 V3, LiChuang (ES8311 mono DAC + shared I2C/I2S + PA)
//! BK:  BK7258 (onboard DAC, no external buses)

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
    .lichuang_szp => @import("esp/lichuang_szp.zig"),
    .lichuang_gocool => @import("esp/lichuang_gocool.zig"),
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for speaker_test"),
};

pub const Hardware = hw.Hardware;

/// Board type — uses hal.Board pattern.
/// ESP boards that need shared I2C/I2S handle that inside their driver init().
pub const Board = hal.Board(hw.spec);
