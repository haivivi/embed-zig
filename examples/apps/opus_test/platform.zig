//! Platform Configuration — Opus Encode/Decode Test
//! Pure codec test, no WiFi/audio hardware needed.

const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for opus_test"),
};

pub const log = hw.log;
pub const time = hw.time;
pub const heap = hw.heap;
