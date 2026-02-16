//! BK7258 — BLE E2E Test

const bk = @import("bk");
const board = bk.boards.bk7258;
const armino = bk.armino;
const impl = bk.impl;

pub const Runtime = armino.runtime;
pub const HciDriver = impl.HciDriver;
pub const heap = board.heap.psram;
pub const log = board.log;
pub const board_name_str = "BK7258";

pub const time = struct {
    pub fn sleepMs(ms: u32) void { board.time.sleepMs(ms); }
    pub fn nowMs() u64 { return board.time.nowMs(); }
};

pub fn isRunning() bool {
    return board.isRunning();
}
