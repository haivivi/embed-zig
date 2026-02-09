//! CoreBluetooth Zig Binding
//!
//! Wraps the C API from cb_helper.h for Zig usage.
//! Provides both Peripheral (GATT Server) and Central (GATT Client) roles.

// ============================================================================
// Properties
// ============================================================================

pub const PROP_READ: u8 = 0x02;
pub const PROP_WRITE_NO_RSP: u8 = 0x04;
pub const PROP_WRITE: u8 = 0x08;
pub const PROP_NOTIFY: u8 = 0x10;
pub const PROP_INDICATE: u8 = 0x20;

// ============================================================================
// Callback Types
// ============================================================================

pub const ReadCallback = *const fn ([*c]const u8, [*c]const u8, [*c]u8, *u16, u16) callconv(.c) void;
pub const WriteCallback = *const fn ([*c]const u8, [*c]const u8, [*c]const u8, u16) callconv(.c) void;
pub const SubscribeCallback = *const fn ([*c]const u8, [*c]const u8, bool) callconv(.c) void;
pub const ConnectionCallback = *const fn (bool) callconv(.c) void;
pub const DeviceFoundCallback = *const fn ([*c]const u8, [*c]const u8, c_int) callconv(.c) void;
pub const NotificationCallback = *const fn ([*c]const u8, [*c]const u8, [*c]const u8, u16) callconv(.c) void;

// ============================================================================
// Extern C declarations
// ============================================================================

// Peripheral
extern fn cb_peripheral_set_read_callback(ReadCallback) void;
extern fn cb_peripheral_set_write_callback(WriteCallback) void;
extern fn cb_peripheral_set_subscribe_callback(SubscribeCallback) void;
extern fn cb_peripheral_set_connection_callback(ConnectionCallback) void;
extern fn cb_peripheral_init() c_int;
extern fn cb_peripheral_add_service([*c]const u8, [*c]const [*c]const u8, [*c]const u8, u16) c_int;
extern fn cb_peripheral_start_advertising([*c]const u8) c_int;
extern fn cb_peripheral_stop_advertising() void;
extern fn cb_peripheral_notify([*c]const u8, [*c]const u8, [*c]const u8, u16) c_int;
extern fn cb_peripheral_notify_blocking([*c]const u8, [*c]const u8, [*c]const u8, u16, u32) c_int;
extern fn cb_peripheral_deinit() void;

// Central
extern fn cb_central_set_device_found_callback(DeviceFoundCallback) void;
extern fn cb_central_set_notification_callback(NotificationCallback) void;
extern fn cb_central_set_connection_callback(ConnectionCallback) void;
extern fn cb_central_init() c_int;
extern fn cb_central_scan_start([*c]const u8) c_int;
extern fn cb_central_scan_stop() void;
extern fn cb_central_connect([*c]const u8) c_int;
extern fn cb_central_disconnect() void;
extern fn cb_central_rediscover() c_int;
extern fn cb_central_read([*c]const u8, [*c]const u8, [*c]u8, *u16, u16) c_int;
extern fn cb_central_write([*c]const u8, [*c]const u8, [*c]const u8, u16) c_int;
extern fn cb_central_write_no_response([*c]const u8, [*c]const u8, [*c]const u8, u16) c_int;
extern fn cb_central_subscribe([*c]const u8, [*c]const u8) c_int;
extern fn cb_central_unsubscribe([*c]const u8, [*c]const u8) c_int;
extern fn cb_central_deinit() void;

// Utility
extern fn cb_run_loop_once(u32) void;

// ============================================================================
// Zig-friendly API
// ============================================================================

pub const Error = error{
    NotReady,
    NotFound,
    Failed,
    QueueFull,
    Timeout,
    Disconnected,
};

pub const Peripheral = struct {
    pub fn setReadCallback(cb: ReadCallback) void {
        cb_peripheral_set_read_callback(cb);
    }
    pub fn setWriteCallback(cb: WriteCallback) void {
        cb_peripheral_set_write_callback(cb);
    }
    pub fn setSubscribeCallback(cb: SubscribeCallback) void {
        cb_peripheral_set_subscribe_callback(cb);
    }
    pub fn setConnectionCallback(cb: ConnectionCallback) void {
        cb_peripheral_set_connection_callback(cb);
    }

    pub fn init() Error!void {
        if (cb_peripheral_init() != 0) return error.NotReady;
    }

    pub fn addService(svc_uuid: [*c]const u8, chr_uuids: [*c]const [*c]const u8, chr_props: [*c]const u8, count: u16) Error!void {
        if (cb_peripheral_add_service(svc_uuid, chr_uuids, chr_props, count) != 0) return error.Failed;
    }

    pub fn startAdvertising(name: [*c]const u8) Error!void {
        if (cb_peripheral_start_advertising(name) != 0) return error.NotReady;
    }

    pub fn stopAdvertising() void {
        cb_peripheral_stop_advertising();
    }

    /// Send notification (non-blocking). Returns QueueFull if transmit queue is full.
    pub fn notify(svc_uuid: [*c]const u8, chr_uuid: [*c]const u8, data: []const u8) Error!void {
        const ret = cb_peripheral_notify(svc_uuid, chr_uuid, data.ptr, @intCast(data.len));
        switch (ret) {
            0 => {},
            -2 => return error.NotFound,
            -3 => return error.QueueFull,
            else => return error.Failed,
        }
    }

    /// Send notification with flow control (blocking).
    /// Waits for CoreBluetooth's transmit queue to have space via
    /// peripheralManagerIsReadyToUpdateSubscribers delegate.
    pub fn notifyBlocking(svc_uuid: [*c]const u8, chr_uuid: [*c]const u8, data: []const u8, timeout_ms: u32) Error!void {
        const ret = cb_peripheral_notify_blocking(svc_uuid, chr_uuid, data.ptr, @intCast(data.len), timeout_ms);
        switch (ret) {
            0 => {},
            -2 => return error.NotFound,
            -3 => return error.QueueFull,
            -4 => return error.Timeout,
            else => return error.Failed,
        }
    }

    pub fn deinit() void {
        cb_peripheral_deinit();
    }
};

pub const Central = struct {
    pub fn setDeviceFoundCallback(cb: DeviceFoundCallback) void {
        cb_central_set_device_found_callback(cb);
    }
    pub fn setNotificationCallback(cb: NotificationCallback) void {
        cb_central_set_notification_callback(cb);
    }
    pub fn setConnectionCallback(cb: ConnectionCallback) void {
        cb_central_set_connection_callback(cb);
    }

    pub fn init() Error!void {
        if (cb_central_init() != 0) return error.NotReady;
    }

    pub fn scanStart(service_uuid: ?[*c]const u8) Error!void {
        if (cb_central_scan_start(service_uuid orelse null) != 0) return error.NotReady;
    }

    pub fn scanStop() void {
        cb_central_scan_stop();
    }

    pub fn connect(peripheral_uuid: [*c]const u8) Error!void {
        const ret = cb_central_connect(peripheral_uuid);
        if (ret != 0) return error.Failed;
    }

    pub fn disconnect() void {
        cb_central_disconnect();
    }

    /// Force re-discovery of GATT services (clears CoreBluetooth cache).
    /// Disconnects and reconnects to the peripheral.
    pub fn rediscover() Error!void {
        if (cb_central_rediscover() != 0) return error.Failed;
    }

    pub fn read(svc_uuid: [*c]const u8, chr_uuid: [*c]const u8, buf: []u8) Error![]const u8 {
        var len: u16 = 0;
        const ret = cb_central_read(svc_uuid, chr_uuid, buf.ptr, &len, @intCast(buf.len));
        switch (ret) {
            0 => return buf[0..len],
            -2 => return error.NotFound,
            else => return error.Failed,
        }
    }

    pub fn write(svc_uuid: [*c]const u8, chr_uuid: [*c]const u8, data: []const u8) Error!void {
        const ret = cb_central_write(svc_uuid, chr_uuid, data.ptr, @intCast(data.len));
        switch (ret) {
            0 => {},
            -2 => return error.NotFound,
            else => return error.Failed,
        }
    }

    pub fn writeNoResponse(svc_uuid: [*c]const u8, chr_uuid: [*c]const u8, data: []const u8) Error!void {
        const ret = cb_central_write_no_response(svc_uuid, chr_uuid, data.ptr, @intCast(data.len));
        switch (ret) {
            0 => {},
            -2 => return error.NotFound,
            else => return error.Failed,
        }
    }

    pub fn subscribe(svc_uuid: [*c]const u8, chr_uuid: [*c]const u8) Error!void {
        if (cb_central_subscribe(svc_uuid, chr_uuid) != 0) return error.Failed;
    }

    pub fn unsubscribe(svc_uuid: [*c]const u8, chr_uuid: [*c]const u8) Error!void {
        if (cb_central_unsubscribe(svc_uuid, chr_uuid) != 0) return error.Failed;
    }

    pub fn deinit() void {
        cb_central_deinit();
    }
};

pub fn runLoopOnce(timeout_ms: u32) void {
    cb_run_loop_once(timeout_ms);
}
