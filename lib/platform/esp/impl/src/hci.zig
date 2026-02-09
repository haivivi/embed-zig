//! ESP HCI Transport Driver
//!
//! Implements the hal.hci transport trait using ESP-IDF VHCI interface.
//! This driver bridges the HAL's fd-like interface (read/write/poll) to
//! the ESP BLE controller's VHCI transport layer.
//!
//! ## Architecture
//!
//! ```
//! hal.hci.from(hci_spec)   — HAL wrapper (type validation)
//!   └── HciDriver          — this file (implements read/write/poll)
//!         └── idf.bt       — Zig VHCI binding
//!               └── bt_helper.c — C helper (ring buffer + callbacks)
//!                     └── esp_vhci_host_* — ESP-IDF VHCI API
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const impl = @import("impl");
//! const hal = @import("hal");
//!
//! const Hci = hal.hci.from(impl.hci.hci_spec);
//! var driver = try impl.hci.HciDriver.init();
//! var hci = Hci.init(&driver);
//!
//! // Write HCI Reset command
//! _ = try hci.write(&[_]u8{ 0x01, 0x03, 0x0C, 0x00 });
//!
//! // Poll + read response
//! const ready = hci.poll(.{ .readable = true }, 1000);
//! if (ready.readable) {
//!     var buf: [256]u8 = undefined;
//!     const n = try hci.read(&buf);
//!     // buf[0] == 0x04 (event indicator)
//! }
//! ```

const idf = @import("idf");
const hal = @import("hal");
const bt = idf.bt;

/// HCI poll flags (re-export from HAL for convenience)
const PollFlags = hal.hci.PollFlags;

/// HCI transport error set (must match hal.hci.Error)
const Error = hal.hci.Error;

/// ESP VHCI HCI Transport Driver
///
/// Stateless driver implementing the hal.hci trait.
/// All state is managed by the C helper's ring buffer.
pub const HciDriver = struct {
    const Self = @This();

    initialized: bool = false,

    /// Initialize the BLE controller and VHCI transport.
    ///
    /// This must be called before any read/write/poll operations.
    /// Runs on IRAM-safe stack internally (via C helper).
    pub fn init() !Self {
        bt.init() catch return error.HciError;
        return .{ .initialized = true };
    }

    /// Deinitialize the BLE controller.
    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            bt.deinit();
            self.initialized = false;
        }
    }

    /// Read an HCI packet from the controller.
    ///
    /// Returns the number of bytes read. The first byte is the HCI
    /// packet indicator (0x04=Event, 0x02=ACL Data).
    ///
    /// Returns `error.WouldBlock` if no data is available.
    /// Returns `error.HciError` on transport failure.
    pub fn read(self: *Self, buf: []u8) Error!usize {
        _ = self;
        const n = bt.recv(buf) catch return error.HciError;
        if (n == 0) return error.WouldBlock;
        return n;
    }

    /// Write an HCI packet to the controller.
    ///
    /// The first byte must be the HCI packet indicator:
    ///   0x01 = Command, 0x02 = ACL Data, 0x03 = SCO Data
    ///
    /// Returns `error.WouldBlock` if the controller is not ready.
    /// Returns `error.HciError` on transport failure.
    pub fn write(self: *Self, buf: []const u8) Error!usize {
        _ = self;
        return bt.send(buf) catch |err| switch (err) {
            error.NotReady => return error.WouldBlock,
            else => return error.HciError,
        };
    }

    /// Poll for transport readiness.
    ///
    /// Checks if the transport is readable and/or writable.
    /// For readable, uses the C helper's semaphore-based wait.
    /// For writable, checks the VHCI send-available flag.
    ///
    /// `timeout_ms`:
    /// -  0 — non-blocking
    /// - >0 — wait up to timeout_ms
    /// - -1 — wait indefinitely
    pub fn poll(self: *Self, flags: PollFlags, timeout_ms: i32) PollFlags {
        _ = self;
        var result = PollFlags{};

        if (flags.readable) {
            result.readable = bt.waitForData(timeout_ms);
        }

        if (flags.writable) {
            result.writable = bt.canSend();
        }

        return result;
    }
};

/// Pre-defined HCI spec for HAL integration.
///
/// Usage:
/// ```zig
/// const Hci = hal.hci.from(impl.hci.hci_spec);
/// ```
pub const hci_spec = struct {
    pub const Driver = HciDriver;
    pub const meta = .{ .id = "hci.esp_vhci" };
};
