//! WebSim BLE Simulation Driver
//!
//! Simulates BLE Host GAP/GATT-level behavior:
//!   start() → idle
//!   startAdvertising() → advertising (after 100ms)
//!   JS triggers "connect" → connected event
//!   JS triggers "disconnect" → disconnected event
//!
//! JS controls BLE state via SharedState:
//!   - ble_sim_connect: set true to simulate peer connection
//!   - ble_sim_disconnect: set true to simulate peer disconnection
//!
//! The driver uses HAL's BLE types directly since hal.ble.from()
//! passes poll() results through without conversion.

const hal_ble = @import("hal").ble;
const state_mod = @import("state.zig");
const shared = &state_mod.state;

// Re-export HAL types (driver must return these exact types)
pub const BleEvent = hal_ble.BleEvent;
pub const State = hal_ble.State;
pub const AdvConfig = hal_ble.AdvConfig;
pub const ConnectionInfo = hal_ble.ConnectionInfo;
pub const DisconnectionInfo = hal_ble.DisconnectionInfo;

/// Advertising start delay (milliseconds)
const ADV_START_DELAY_MS: u64 = 100;

/// Simulated BLE Host driver for WebSim.
///
/// Satisfies hal.ble Driver required interface:
/// - start / stop
/// - startAdvertising / stopAdvertising
/// - poll
/// - getState
/// Plus optional: disconnect, notify, indicate, getConnHandle
pub const BleDriver = struct {
    const Self = @This();

    state: State = .uninitialized,
    conn_handle: ?u16 = null,

    /// Pending event (single slot)
    pending_event: ?BleEvent = null,

    /// Timestamp when startAdvertising was called
    adv_start_ms: u64 = 0,
    /// Whether we're waiting for adv start delay
    adv_pending: bool = false,

    pub fn init() !Self {
        shared.addLog("WebSim: BLE driver ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    // ================================================================
    // Required: start / stop
    // ================================================================

    pub fn start(self: *Self) !void {
        self.state = .idle;
        shared.ble_state = @intFromEnum(State.idle);
        shared.addLog("WebSim: BLE started");
    }

    pub fn stop(self: *Self) void {
        self.state = .uninitialized;
        self.conn_handle = null;
        shared.ble_state = @intFromEnum(State.uninitialized);
        shared.ble_connected = false;
    }

    // ================================================================
    // Required: startAdvertising / stopAdvertising
    // ================================================================

    pub fn startAdvertising(self: *Self, _: AdvConfig) !void {
        self.adv_pending = true;
        self.adv_start_ms = shared.time_ms;
        shared.addLog("WebSim: BLE advertising starting...");
    }

    pub fn stopAdvertising(self: *Self) !void {
        self.adv_pending = false;
        if (self.state == .advertising) {
            self.state = .idle;
            shared.ble_state = @intFromEnum(State.idle);
            self.pending_event = BleEvent{ .advertising_stopped = {} };
            shared.addLog("WebSim: BLE advertising stopped");
        }
    }

    // ================================================================
    // Required: poll
    // ================================================================

    pub fn poll(self: *Self, _: i32) ?BleEvent {
        // Return pending event
        if (self.pending_event) |event| {
            self.pending_event = null;
            return event;
        }

        // Advertising start delay
        if (self.adv_pending) {
            const elapsed = shared.time_ms -| self.adv_start_ms;
            if (elapsed >= ADV_START_DELAY_MS) {
                self.adv_pending = false;
                self.state = .advertising;
                shared.ble_state = @intFromEnum(State.advertising);
                shared.addLog("WebSim: BLE advertising");
                return BleEvent{ .advertising_started = {} };
            }
        }

        // JS-triggered connect
        if (shared.ble_sim_connect) {
            shared.ble_sim_connect = false;
            self.state = .connected;
            self.conn_handle = 0x0040; // Simulated handle
            shared.ble_state = @intFromEnum(State.connected);
            shared.ble_connected = true;
            shared.addLog("WebSim: BLE peer connected");
            return BleEvent{ .connected = ConnectionInfo{
                .conn_handle = 0x0040,
                .peer_addr = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
                .peer_addr_type = 0,
                .role = .peripheral,
                .conn_interval = 24, // 30ms
                .conn_latency = 0,
                .supervision_timeout = 400, // 4s
            } };
        }

        // JS-triggered disconnect
        if (shared.ble_sim_disconnect) {
            shared.ble_sim_disconnect = false;
            if (self.state == .connected) {
                const handle = self.conn_handle orelse 0;
                self.state = .idle;
                self.conn_handle = null;
                shared.ble_state = @intFromEnum(State.idle);
                shared.ble_connected = false;
                shared.addLog("WebSim: BLE peer disconnected");
                return BleEvent{ .disconnected = DisconnectionInfo{
                    .conn_handle = handle,
                    .reason = 0x13, // Remote User Terminated Connection
                } };
            }
        }

        return null;
    }

    // ================================================================
    // Required: getState
    // ================================================================

    pub fn getState(self: *const Self) State {
        return self.state;
    }

    // ================================================================
    // Optional: disconnect / notify / indicate / getConnHandle
    // ================================================================

    pub fn disconnect(self: *Self, _: u16, _: u8) !void {
        if (self.state == .connected) {
            const handle = self.conn_handle orelse 0;
            self.state = .idle;
            self.conn_handle = null;
            shared.ble_state = @intFromEnum(State.idle);
            shared.ble_connected = false;
            self.pending_event = BleEvent{ .disconnected = DisconnectionInfo{
                .conn_handle = handle,
                .reason = 0x16, // Local Host Terminated Connection
            } };
        }
    }

    pub fn notify(_: *Self, _: u16, _: u16, _: []const u8) void {
        // In simulation: no-op (data would go to virtual peer)
    }

    pub fn indicate(_: *Self, _: u16, _: u16, _: []const u8) void {
        // In simulation: no-op
    }

    pub fn getConnHandle(self: *const Self) ?u16 {
        return self.conn_handle;
    }
};
