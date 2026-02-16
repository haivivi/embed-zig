//! Platform Configuration — Mic Auto Test

const hal = @import("hal");
const build_options = @import("build_options");

const BoardEnum = @TypeOf(build_options.board);

const hw = if (@hasField(BoardEnum, "bk7258") and build_options.board == .bk7258)
    @import("bk/bk7258.zig")
else
    @compileError("aec_test only supports bk7258");

pub const Hardware = hw.Hardware;

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
};

pub const Board = hal.Board(spec);
