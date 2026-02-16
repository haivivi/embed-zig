//! BK7258 BLE HCI Transport Binding
//!
//! Raw HCI read/write/poll via Armino BLE controller + IPC.

extern fn bk_zig_ble_init() c_int;
extern fn bk_zig_ble_deinit() void;
extern fn bk_zig_ble_send_cmd(buf: [*]const u8, len: c_uint) c_int;
extern fn bk_zig_ble_send_acl(buf: [*]const u8, len: c_uint) c_int;
extern fn bk_zig_ble_recv(buf: [*]u8, max_len: c_uint) c_uint;
extern fn bk_zig_ble_wait_for_data(timeout_ms: c_int) c_int;
extern fn bk_zig_ble_can_send() c_int;

pub const Error = error{ BleError, NotReady };

pub fn init() Error!void {
    if (bk_zig_ble_init() != 0) return error.BleError;
}

pub fn deinit() void {
    bk_zig_ble_deinit();
}

/// Send HCI packet to controller.
/// buf[0] = indicator: 0x01=Command, 0x02=ACL
/// Returns bytes sent (= buf.len) or error.
pub fn send(buf: []const u8) Error!usize {
    if (buf.len == 0) return 0;
    const indicator = buf[0];
    const payload = buf[1..];

    const ret = switch (indicator) {
        0x01 => bk_zig_ble_send_cmd(payload.ptr, @intCast(payload.len)),
        0x02 => bk_zig_ble_send_acl(payload.ptr, @intCast(payload.len)),
        else => return error.BleError,
    };
    if (ret != 0) return error.BleError;
    return buf.len;
}

/// Receive HCI packet from controller.
/// Returns bytes read. buf[0] = indicator (0x04=Event, 0x02=ACL).
/// Returns 0 if no data.
pub fn recv(buf: []u8) Error!usize {
    const n = bk_zig_ble_recv(buf.ptr, @intCast(buf.len));
    return @intCast(n);
}

/// Wait for data with timeout.
pub fn waitForData(timeout_ms: i32) bool {
    return bk_zig_ble_wait_for_data(timeout_ms) != 0;
}

/// Check if controller can accept data.
pub fn canSend() bool {
    return bk_zig_ble_can_send() != 0;
}
