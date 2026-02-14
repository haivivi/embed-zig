//! BK7258 Board — Opus codec test (no WiFi, no audio HW)

const bk = @import("bk");
const board = bk.boards.bk7258;

pub const log = board.log;
pub const time = struct {
    pub fn sleepMs(ms: u32) void { board.time.sleepMs(ms); }
    pub fn nowMs() u64 { return board.time.nowMs(); }
};

/// Use PSRAM allocator for opus encoder/decoder state
pub const heap = board.heap.psram;
