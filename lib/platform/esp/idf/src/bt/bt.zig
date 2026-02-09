//! BLE Controller + VHCI Transport Binding
//!
//! Zig wrapper for ESP-IDF BLE controller VHCI interface.
//! Uses C helper to work around complex macros and callback structs.
//!
//! The C helper functions are declared as extern and linked at build time.
//! See: lib/platform/esp/idf/src/bt/bt_helper.c

const std = @import("std");

// ============================================================================
// Extern declarations for C helper functions
// ============================================================================

extern fn bt_helper_init() c_int;
extern fn bt_helper_deinit() void;
extern fn bt_helper_can_send() bool;
extern fn bt_helper_send(data: [*]const u8, len: u16) c_int;
extern fn bt_helper_recv(buf: [*]u8, buf_len: u16) c_int;
extern fn bt_helper_has_data() bool;
extern fn bt_helper_wait_for_data(timeout_ms: u32) bool;

// ============================================================================
// Types
// ============================================================================

pub const Error = error{
    /// BT memory release failed
    MemReleaseFailed,
    /// Controller init failed
    InitFailed,
    /// Controller enable failed
    EnableFailed,
    /// VHCI callback registration failed
    CallbackFailed,
    /// Semaphore creation failed
    SemaphoreFailed,
    /// Controller not ready to accept packet
    NotReady,
    /// Receive buffer too small for packet
    BufferTooSmall,
    /// Transport-level error
    TransportError,
};

// ============================================================================
// Public API
// ============================================================================

/// Initialize the BLE controller in VHCI mode.
///
/// Performs the full init sequence:
/// 1. Release classic BT memory (BLE-only)
/// 2. Init controller with default config
/// 3. Enable controller in BLE mode
/// 4. Register VHCI callbacks (internal ring buffer)
pub fn init() Error!void {
    const ret = bt_helper_init();
    switch (ret) {
        0 => {},
        -1 => return error.MemReleaseFailed,
        -2 => return error.InitFailed,
        -3 => return error.EnableFailed,
        -4 => return error.CallbackFailed,
        -5 => return error.SemaphoreFailed,
        else => return error.TransportError,
    }
}

/// Deinitialize the BLE controller.
pub fn deinit() void {
    bt_helper_deinit();
}

/// Check if the controller is ready to accept a packet.
pub fn canSend() bool {
    return bt_helper_can_send();
}

/// Send an HCI packet to the controller via VHCI.
///
/// The packet must include the HCI packet indicator byte:
///   0x01 = Command, 0x02 = ACL Data, 0x03 = SCO Data
///
/// Returns the number of bytes sent (always == data.len on success).
pub fn send(data: []const u8) Error!usize {
    if (data.len == 0) return 0;
    if (data.len > std.math.maxInt(u16)) return error.TransportError;

    const ret = bt_helper_send(data.ptr, @intCast(data.len));
    if (ret != 0) return error.NotReady;
    return data.len;
}

/// Read the next HCI packet from the receive ring buffer.
///
/// Returns the number of bytes read, or 0 if no packet is available.
/// The packet includes the HCI indicator byte (0x04=Event, 0x02=ACL).
pub fn recv(buf: []u8) Error!usize {
    if (buf.len == 0) return 0;

    const buf_len: u16 = if (buf.len > std.math.maxInt(u16))
        std.math.maxInt(u16)
    else
        @intCast(buf.len);

    const ret = bt_helper_recv(buf.ptr, buf_len);
    if (ret < 0) return error.BufferTooSmall;
    return @intCast(ret);
}

/// Check if there are packets available to read.
pub fn hasData() bool {
    return bt_helper_has_data();
}

/// Wait until data is available or timeout expires.
///
/// Blocks on internal semaphore signaled by VHCI RX callback.
///
/// `timeout_ms`:
/// -  0 — non-blocking, return immediately
/// - >0 — wait up to timeout_ms milliseconds
/// - -1 — wait indefinitely (maps to UINT32_MAX)
///
/// Returns true if data became available, false on timeout.
pub fn waitForData(timeout_ms: i32) bool {
    const ms: u32 = if (timeout_ms < 0)
        std.math.maxInt(u32) // portMAX_DELAY
    else
        @intCast(timeout_ms);
    return bt_helper_wait_for_data(ms);
}
