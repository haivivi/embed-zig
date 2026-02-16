//! BK7258 HCI Transport Driver
//!
//! Implements hal.hci transport trait using Armino BLE controller.
//! Same interface as ESP's VHCI-based HCI driver.
//!
//! Architecture:
//! ```
//! hal.hci.from(hci_spec)   — HAL wrapper
//!   └── HciDriver          — this file (read/write/poll)
//!         └── armino.ble   — Zig BLE binding
//!               └── bk_zig_ble_helper.c — C helper (ring buffer + IPC)
//!                     └── bk_ble_hci_* — Armino BLE HCI API
//! ```

const armino = @import("../../armino/src/armino.zig");
const hal = @import("hal");

const PollFlags = hal.hci.PollFlags;
const Error = hal.hci.Error;

/// BK7258 HCI Transport Driver
pub const HciDriver = struct {
    const Self = @This();

    initialized: bool = false,

    pub fn init() !Self {
        armino.ble.init() catch return error.HciError;
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            armino.ble.deinit();
            self.initialized = false;
        }
    }

    /// Read HCI packet. buf[0] = indicator (0x04=Event, 0x02=ACL).
    pub fn read(self: *Self, buf: []u8) Error!usize {
        _ = self;
        const n = armino.ble.recv(buf) catch return error.HciError;
        if (n == 0) return error.WouldBlock;
        return n;
    }

    /// Write HCI packet. buf[0] = indicator (0x01=Cmd, 0x02=ACL).
    pub fn write(self: *Self, buf: []const u8) Error!usize {
        _ = self;
        return armino.ble.send(buf) catch |err| switch (err) {
            error.NotReady => return error.WouldBlock,
            else => return error.HciError,
        };
    }

    /// Poll for readable/writable.
    pub fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags {
        _ = self;
        var result = PollFlags{};

        if (flags.readable) {
            result.readable = armino.ble.waitForData(timeout_ms);
        }

        if (flags.writable) {
            result.writable = armino.ble.canSend();
        }

        return result;
    }
};

/// Pre-defined HCI spec for HAL integration.
pub const hci_spec = struct {
    pub const Driver = HciDriver;
    pub const meta = .{ .id = "hci.bk_ble" };
};
