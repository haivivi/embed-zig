//! WebSim WiFi Simulation Driver
//!
//! Simulates WiFi STA connection with timed state transitions:
//!   connect() → 500ms delay → connected event
//!
//! JS can control WiFi state via SharedState:
//!   - wifi_force_disconnect: set true to simulate AP loss
//!   - wifi_rssi: set signal strength for simulation
//!
//! The driver uses SharedState.time_ms for timing (set by JS each frame).

const state_mod = @import("state.zig");
const shared = &state_mod.state;

/// WiFi MAC address type
pub const Mac = [6]u8;

/// Simulated connection delay in milliseconds
const CONNECT_DELAY_MS: u64 = 500;

/// Disconnect reason (must match HAL wifi.DisconnectReason enum order)
pub const DisconnectReason = enum {
    user_request,
    auth_failed,
    ap_not_found,
    connection_lost,
    unknown,
};

/// Connection failure reason (must match HAL wifi.FailReason enum order)
pub const FailReason = enum {
    timeout,
    auth_failed,
    ap_not_found,
    dhcp_failed,
    unknown,
};

/// Scan done info (structurally compatible with HAL)
pub const ScanDoneInfo = struct {
    count: u16,
    success: bool,
};

/// Station info (structurally compatible with HAL)
pub const StaInfo = struct {
    mac: Mac,
    rssi: i8,
    aid: u16,
};

/// WiFi event (driver's own type, converted by HAL wrapper)
pub const WifiEvent = union(enum) {
    connected: void,
    disconnected: DisconnectReason,
    connection_failed: FailReason,
    scan_done: ScanDoneInfo,
    rssi_low: i8,
    ap_sta_connected: StaInfo,
    ap_sta_disconnected: StaInfo,
};

/// Internal state machine
const State = enum {
    disconnected,
    connecting,
    connected,
};

/// Simulated WiFi STA driver for WebSim.
///
/// Satisfies hal.wifi Driver required interface:
/// - connect / disconnect / isConnected / pollEvent
/// Plus optional: getRssi, getMac, getChannel, getSsid, reconnect
pub const WifiDriver = struct {
    const Self = @This();

    state: State = .disconnected,

    /// SSID of the network being connected to
    ssid_buf: [32]u8 = undefined,
    ssid_len: u8 = 0,

    /// Timestamp when connect() was called (for simulated delay)
    connect_start_ms: u64 = 0,

    /// Pending event queue (single slot — one event per poll cycle)
    pending_event: ?WifiEvent = null,

    /// Simulated MAC address
    mac: Mac = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01 },

    pub fn init() !Self {
        shared.addLog("WebSim: WiFi driver ready");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    // ================================================================
    // Required: connect / disconnect / isConnected / pollEvent
    // ================================================================

    pub fn connect(self: *Self, ssid: []const u8, password: []const u8) void {
        _ = password;

        // Store SSID
        const len: u8 = @intCast(@min(ssid.len, 32));
        @memcpy(self.ssid_buf[0..len], ssid[0..len]);
        self.ssid_len = len;

        // Update shared state for JS display
        @memcpy(shared.wifi_ssid[0..len], ssid[0..len]);
        shared.wifi_ssid_len = len;

        // Start connection timer
        self.state = .connecting;
        self.connect_start_ms = shared.time_ms;

        shared.addLog("WebSim: WiFi connecting...");
    }

    pub fn disconnect(self: *Self) void {
        if (self.state == .connected) {
            self.pending_event = .{ .disconnected = .user_request };
        }
        self.state = .disconnected;
        shared.wifi_connected = false;
        shared.addLog("WebSim: WiFi disconnected");
    }

    pub fn isConnected(self: *const Self) bool {
        return self.state == .connected;
    }

    pub fn pollEvent(self: *Self) ?WifiEvent {
        // Return pending event if any
        if (self.pending_event) |event| {
            self.pending_event = null;
            return event;
        }

        // Check for JS-triggered force disconnect
        if (shared.wifi_force_disconnect) {
            shared.wifi_force_disconnect = false;
            if (self.state == .connected) {
                self.state = .disconnected;
                shared.wifi_connected = false;
                shared.addLog("WebSim: WiFi connection lost (simulated)");
                return WifiEvent{ .disconnected = .connection_lost };
            }
        }

        // State machine: connecting → connected after delay
        if (self.state == .connecting) {
            const elapsed = shared.time_ms -| self.connect_start_ms;
            if (elapsed >= CONNECT_DELAY_MS) {
                self.state = .connected;
                shared.wifi_connected = true;
                shared.addLog("WebSim: WiFi connected");
                return WifiEvent{ .connected = {} };
            }
        }

        return null;
    }

    // ================================================================
    // Optional: status queries
    // ================================================================

    pub fn getRssi(_: *const Self) ?i8 {
        return shared.wifi_rssi;
    }

    pub fn getMac(self: *const Self) ?Mac {
        return self.mac;
    }

    pub fn getChannel(_: *const Self) ?u8 {
        return 6; // Simulated channel
    }

    pub fn getSsid(self: *const Self) ?[]const u8 {
        if (self.ssid_len == 0) return null;
        return self.ssid_buf[0..self.ssid_len];
    }

    // ================================================================
    // Optional: reconnect
    // ================================================================

    pub fn reconnect(self: *Self) void {
        if (self.ssid_len > 0) {
            self.state = .connecting;
            self.connect_start_ms = shared.time_ms;
            shared.addLog("WebSim: WiFi reconnecting...");
        }
    }
};
