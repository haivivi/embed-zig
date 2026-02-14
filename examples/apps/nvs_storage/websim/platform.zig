//! Board Configuration for WebSim nvs_storage
//!
//! Uses esp32_devkit board for base hardware (rtc, log, time).
//! Assembles kvs_spec here — KVS is partition-dependent, not board hardware.

const hal = @import("hal");
const websim = @import("websim");
const board = websim.boards.esp32_devkit;

const kvs_spec = struct {
    pub const Driver = websim.KvsDriver;
    pub const meta = .{ .id = "kvs.sim" };
};

const spec = struct {
    pub const meta = .{ .id = "WebSim ESP32 DevKit" };

    pub const rtc = hal.rtc.reader.from(board.rtc_spec);
    pub const log = board.log;
    pub const time = board.time;

    pub const kvs = hal.kvs.from(kvs_spec);
};

pub const Board = hal.Board(spec);
