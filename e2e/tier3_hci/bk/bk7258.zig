//! BK7258 Board — HCI Test

const bk = @import("bk");
const board = bk.boards.bk7258;
const armino = bk.armino;

pub const log = board.log;

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        board.time.sleepMs(ms);
    }
};

pub fn isRunning() bool {
    return board.isRunning();
}

/// BLE HCI transport — wraps armino.ble
pub const ble = struct {
    pub fn init() !void {
        armino.ble.init() catch return error.BleError;
    }

    pub fn send(data: []const u8) !usize {
        return armino.ble.send(data) catch return error.BleError;
    }

    pub fn recv(buf: []u8) !usize {
        return armino.ble.recv(buf) catch return error.BleError;
    }

    pub fn waitForData(timeout_ms: i32) bool {
        return armino.ble.waitForData(timeout_ms);
    }
};
