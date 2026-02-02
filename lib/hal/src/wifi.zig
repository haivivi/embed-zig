//! WiFi HAL Component (Event-Driven)
//!
//! Provides a unified event-driven interface for WiFi STA and AP mode operations.
//! The driver runs in IRAM and communicates via events.
//!
//! NOTE: This module handles WiFi (802.11) layer events.
//! IP events (got_ip, lost_ip, dhcp) are handled by the Net HAL module.
//!
//! ## Spec Requirements
//!
//! A WiFi driver must implement:
//! ```zig
//! pub const wifi_spec = struct {
//!     pub const Driver = struct {
//!         // Required - STA mode connection
//!         pub fn connect(self: *Self, ssid: []const u8, password: []const u8) void;
//!         pub fn disconnect(self: *Self) void;
//!         pub fn isConnected(self: *const Self) bool;
//!         pub fn pollEvent(self: *Self) ?WifiEvent;
//!
//!         // Optional - Extended connection
//!         pub fn connectWithConfig(self: *Self, config: ConnectConfig) void;
//!         pub fn reconnect(self: *Self) void;
//!
//!         // Optional - Status queries
//!         pub fn getRssi(self: *const Self) ?i8;
//!         pub fn getMac(self: *const Self) ?Mac;
//!         pub fn getChannel(self: *const Self) ?u8;
//!         pub fn getSsid(self: *const Self) ?[]const u8;
//!         pub fn getBssid(self: *const Self) ?Mac;
//!         pub fn getPhyMode(self: *const Self) ?PhyMode;
//!
//!         // Optional - Scanning
//!         pub fn scanStart(self: *Self, config: ScanConfig) !void;
//!         pub fn scanGetResults(self: *Self) []const ApInfo;
//!
//!         // Optional - Power save
//!         pub fn setPowerSave(self: *Self, mode: PowerSaveMode) void;
//!         pub fn getPowerSave(self: *const Self) PowerSaveMode;
//!
//!         // Optional - Roaming (802.11k/v/r)
//!         pub fn setRoaming(self: *Self, config: RoamingConfig) void;
//!
//!         // Optional - RSSI threshold
//!         pub fn setRssiThreshold(self: *Self, rssi: i8) void;
//!
//!         // Optional - TX power
//!         pub fn setTxPower(self: *Self, power: i8) void;
//!         pub fn getTxPower(self: *const Self) ?i8;
//!
//!         // Optional - AP mode
//!         pub fn startAp(self: *Self, config: ApConfig) !void;
//!         pub fn stopAp(self: *Self) void;
//!         pub fn isApRunning(self: *const Self) bool;
//!         pub fn getStaList(self: *const Self) []const StaInfo;
//!         pub fn deauthSta(self: *Self, mac: Mac) void;
//!
//!         // Optional - Protocol/Bandwidth
//!         pub fn setProtocol(self: *Self, proto: Protocol) void;
//!         pub fn setBandwidth(self: *Self, bw: Bandwidth) void;
//!
//!         // Optional - Country code
//!         pub fn setCountryCode(self: *Self, code: [2]u8) void;
//!         pub fn getCountryCode(self: *const Self) [2]u8;
//!     };
//!     pub const meta = hal.Meta{ .id = "wifi.main" };
//! };
//! ```
//!
//! ## Example Usage (Event-Driven)
//!
//! ```zig
//! const Wifi = hal.Wifi(hw.wifi_spec);
//!
//! var wifi = Wifi.init(&driver);
//! wifi.connect("MySSID", "password");  // Non-blocking
//!
//! // In event loop:
//! while (board.nextEvent()) |event| {
//!     switch (event) {
//!         .wifi => |w| switch (w) {
//!             .connected => log.info("WiFi connected to AP"),
//!             .disconnected => |reason| log.warn("Disconnected: {}", .{reason}),
//!             .connection_failed => |reason| log.err("Connection failed: {}", .{reason}),
//!             .scan_done => |info| log.info("Scan found {} APs", .{info.count}),
//!             .rssi_low => |rssi| log.warn("Signal weak: {} dBm", .{rssi}),
//!             .ap_sta_connected => |sta| log.info("STA connected: {x}", .{sta.mac}),
//!             .ap_sta_disconnected => |sta| log.info("STA disconnected", .{}),
//!         },
//!         .net => |n| switch (n) {
//!             .dhcp_bound => |info| log.info("Got IP: {}.{}.{}.{}", .{info.ip[0], info.ip[1], info.ip[2], info.ip[3]}),
//!             .ip_lost => log.warn("Lost IP"),
//!             else => {},
//!         },
//!         else => {},
//!     }
//! }
//! ```

const std = @import("std");


// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _WifiMarker = struct {};

/// Check if a type is a Wifi peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _WifiMarker;
}

// ============================================================================
// Types
// ============================================================================

/// IPv4 address as 4 bytes
pub const IpAddress = [4]u8;

/// MAC address as 6 bytes
pub const Mac = [6]u8;

/// WiFi connection state
pub const State = enum {
    disconnected,
    connecting,
    connected,
    failed,
    /// AP mode running
    ap_running,
};

/// WiFi event types (802.11 layer only)
/// NOTE: IP events (got_ip, lost_ip) are in Net HAL
pub const WifiEvent = union(enum) {
    // ========== STA Events ==========
    /// WiFi connected to AP (802.11 layer, before IP assignment)
    connected: void,
    /// WiFi disconnected from AP
    disconnected: DisconnectReason,
    /// Connection failed
    connection_failed: FailReason,
    /// Scan completed
    scan_done: ScanDoneInfo,
    /// RSSI dropped below threshold
    rssi_low: i8,

    // ========== AP Events ==========
    /// Station connected to our AP
    ap_sta_connected: StaInfo,
    /// Station disconnected from our AP
    ap_sta_disconnected: StaInfo,
};

/// Scan completion info
pub const ScanDoneInfo = struct {
    /// Number of APs found
    count: u16,
    /// Scan was successful
    success: bool,
};

/// Reason for disconnection
pub const DisconnectReason = enum {
    user_request,
    auth_failed,
    ap_not_found,
    connection_lost,
    unknown,
};

/// Reason for connection failure
pub const FailReason = enum {
    timeout,
    auth_failed,
    ap_not_found,
    dhcp_failed,
    unknown,
};

/// WiFi authentication mode
pub const AuthMode = enum {
    open,
    wep,
    wpa_psk,
    wpa2_psk,
    wpa_wpa2_psk,
    wpa3_psk,
    wpa2_wpa3_psk,
    wpa2_enterprise,
    wpa3_enterprise,
};

/// PHY mode (802.11 standard)
pub const PhyMode = enum {
    @"11b",
    @"11g",
    @"11n",
    @"11a",
    @"11ac",
    @"11ax",
};

/// WiFi connection configuration
pub const ConnectConfig = struct {
    ssid: []const u8,
    password: []const u8,
    /// Channel hint for faster connection (0 = auto)
    channel_hint: u8 = 0,
    /// Specific BSSID to connect to (null = any)
    bssid: ?Mac = null,
    /// Required authentication mode (null = auto)
    auth_mode: ?AuthMode = null,
    /// Connection timeout in milliseconds
    timeout_ms: u32 = 30_000,
};

/// WiFi status information
pub const Status = struct {
    state: State,
    ip: ?IpAddress,
    rssi: ?i8,
    ssid: ?[]const u8,
    bssid: ?Mac = null,
    channel: ?u8 = null,
    phy_mode: ?PhyMode = null,
};

// ============================================================================
// Scan Types
// ============================================================================

/// Scan type
pub const ScanType = enum {
    active,
    passive,
};

/// Scan configuration
pub const ScanConfig = struct {
    /// Specific SSID to scan for (null = all)
    ssid: ?[]const u8 = null,
    /// Specific BSSID to scan for (null = all)
    bssid: ?Mac = null,
    /// Specific channel to scan (0 = all)
    channel: u8 = 0,
    /// Show hidden SSIDs
    show_hidden: bool = false,
    /// Scan type
    scan_type: ScanType = .active,
};

/// Information about a scanned AP
pub const ApInfo = struct {
    /// SSID (may be empty for hidden networks)
    ssid: [32]u8,
    /// Length of valid SSID bytes
    ssid_len: u8,
    /// BSSID (MAC address of AP)
    bssid: Mac,
    /// Primary channel
    channel: u8,
    /// Signal strength in dBm
    rssi: i8,
    /// Authentication mode
    auth_mode: AuthMode,

    /// Get SSID as slice
    pub fn getSsid(self: *const ApInfo) []const u8 {
        return self.ssid[0..self.ssid_len];
    }
};

// ============================================================================
// Power Save Types
// ============================================================================

/// Power save mode
pub const PowerSaveMode = enum {
    /// No power save, maximum throughput
    none,
    /// Minimum power save, wake at every DTIM beacon
    min_modem,
    /// Maximum power save, wake at listen interval
    max_modem,
};

// ============================================================================
// Roaming Types (802.11k/v/r)
// ============================================================================

/// Roaming configuration
pub const RoamingConfig = struct {
    /// Enable 802.11k Radio Resource Management
    rm_enabled: bool = false,
    /// Enable 802.11v BSS Transition Management
    btm_enabled: bool = false,
    /// Enable 802.11r Fast BSS Transition
    ft_enabled: bool = false,
    /// Enable Multi-Band Operation
    mbo_enabled: bool = false,
};

// ============================================================================
// AP Mode Types
// ============================================================================

/// AP configuration
pub const ApConfig = struct {
    /// SSID of the AP
    ssid: []const u8,
    /// Password (empty for open network)
    password: []const u8,
    /// Channel (1-14 for 2.4GHz)
    channel: u8 = 1,
    /// Authentication mode
    auth_mode: AuthMode = .wpa2_psk,
    /// Maximum number of connected stations
    max_connections: u8 = 4,
    /// Hide SSID in beacon
    hidden: bool = false,
    /// Beacon interval in TUs (1 TU = 1024 us)
    beacon_interval: u16 = 100,
};

/// Information about a connected station
pub const StaInfo = struct {
    /// MAC address of the station
    mac: Mac,
    /// Signal strength in dBm
    rssi: i8,
    /// Association ID
    aid: u16,
};

// ============================================================================
// Protocol/Bandwidth Types
// ============================================================================

/// WiFi protocol bitmap
pub const Protocol = packed struct {
    /// 802.11b (1-11 Mbps)
    b: bool = true,
    /// 802.11g (6-54 Mbps)
    g: bool = true,
    /// 802.11n (HT, up to 150 Mbps)
    n: bool = true,
    /// Long Range mode (ESP proprietary)
    lr: bool = false,
    /// Padding
    _padding: u4 = 0,
};

/// Channel bandwidth
pub const Bandwidth = enum {
    /// 20 MHz bandwidth
    bw_20,
    /// 40 MHz bandwidth (requires 11n)
    bw_40,
};

// ============================================================================
// WiFi HAL Component
// ============================================================================

/// WiFi HAL wrapper
/// Wraps a platform-specific WiFi driver and provides unified event-driven interface
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        // ================================================================
        // Required method signature verification
        // ================================================================
        _ = @as(*const fn (*BaseDriver, []const u8, []const u8) void, &BaseDriver.connect);
        _ = @as(*const fn (*BaseDriver) void, &BaseDriver.disconnect);
        _ = @as(*const fn (*const BaseDriver) bool, &BaseDriver.isConnected);
        if (!@hasDecl(BaseDriver, "pollEvent")) {
            @compileError("Driver must have pollEvent method");
        }

        // ================================================================
        // Optional method signature verification
        // ================================================================

        // Extended connection - signature checked by usage in wrapper methods
        // connectWithConfig: takes a ConnectConfig-compatible struct
        // reconnect: *BaseDriver -> void
        if (@hasDecl(BaseDriver, "reconnect")) {
            _ = @as(*const fn (*BaseDriver) void, &BaseDriver.reconnect);
        }

        // Status queries - signature verified through usage due to platform-specific types
        // getRssi, getMac, getChannel, getBssid, getPhyMode
        if (@hasDecl(BaseDriver, "getRssi")) {
            _ = @as(*const fn (*const BaseDriver) ?i8, &BaseDriver.getRssi);
        }
        if (@hasDecl(BaseDriver, "getChannel")) {
            _ = @as(*const fn (*const BaseDriver) ?u8, &BaseDriver.getChannel);
        }

        // RSSI threshold
        if (@hasDecl(BaseDriver, "setRssiThreshold")) {
            _ = @as(*const fn (*BaseDriver, i8) void, &BaseDriver.setRssiThreshold);
        }

        // TX power
        if (@hasDecl(BaseDriver, "setTxPower")) {
            _ = @as(*const fn (*BaseDriver, i8) void, &BaseDriver.setTxPower);
        }
        if (@hasDecl(BaseDriver, "getTxPower")) {
            _ = @as(*const fn (*const BaseDriver) ?i8, &BaseDriver.getTxPower);
        }

        // AP mode - startAp and getStaList have platform-specific types
        if (@hasDecl(BaseDriver, "stopAp")) {
            _ = @as(*const fn (*BaseDriver) void, &BaseDriver.stopAp);
        }
        if (@hasDecl(BaseDriver, "isApRunning")) {
            _ = @as(*const fn (*const BaseDriver) bool, &BaseDriver.isApRunning);
        }

        // Country code
        if (@hasDecl(BaseDriver, "setCountryCode")) {
            _ = @as(*const fn (*BaseDriver, [2]u8) void, &BaseDriver.setCountryCode);
        }
        if (@hasDecl(BaseDriver, "getCountryCode")) {
            _ = @as(*const fn (*const BaseDriver) [2]u8, &BaseDriver.getCountryCode);
        }
        // Note: Methods with platform-specific types are validated through usage:
        // connectWithConfig, scanStart, scanGetResults, setPowerSave, getPowerSave,
        // setRoaming, startAp, getStaList, deauthSta, setProtocol, setBandwidth,
        // getMac, getBssid, getPhyMode

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _WifiMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver
        driver: *Driver,

        /// Current state (tracked by HAL, updated from events)
        state: State = .disconnected,

        /// Current SSID (if connecting/connected)
        current_ssid: ?[]const u8 = null,

        // ================================================================
        // Initialization
        // ================================================================

        /// Initialize WiFi wrapper with driver
        pub fn init(driver: *Driver) Self {
            return .{
                .driver = driver,
            };
        }

        // ================================================================
        // Connection Operations (Non-blocking)
        // ================================================================

        /// Request WiFi connection (non-blocking)
        /// Connection result will be delivered via events
        pub fn connect(self: *Self, ssid: []const u8, password: []const u8) void {
            self.state = .connecting;
            self.current_ssid = ssid;
            self.driver.connect(ssid, password);
        }

        /// Request WiFi connection with full configuration (non-blocking)
        pub fn connectWithConfig(self: *Self, config: ConnectConfig) void {
            self.state = .connecting;
            self.current_ssid = config.ssid;
            if (@hasDecl(Driver, "connectWithConfig")) {
                self.driver.connectWithConfig(.{
                    .ssid = config.ssid,
                    .password = config.password,
                    .channel_hint = config.channel_hint,
                    .bssid = config.bssid,
                    .auth_mode = if (config.auth_mode) |m| @enumFromInt(@intFromEnum(m)) else null,
                    .timeout_ms = config.timeout_ms,
                });
            } else {
                self.driver.connect(config.ssid, config.password);
            }
        }

        /// Request disconnection from current network
        pub fn disconnect(self: *Self) void {
            self.driver.disconnect();
        }

        /// Request reconnection (uses previously configured credentials)
        pub fn reconnect(self: *Self) void {
            if (@hasDecl(Driver, "reconnect")) {
                self.state = .connecting;
                self.driver.reconnect();
            }
        }

        // ================================================================
        // Event Polling
        // ================================================================

        /// Poll for WiFi events (called by board.poll())
        /// Returns the next pending event, or null if none
        pub fn pollEvent(self: *Self) ?WifiEvent {
            const driver_event = self.driver.pollEvent() orelse return null;

            // Convert driver event to HAL event type
            const event: WifiEvent = switch (driver_event) {
                .connected => .{ .connected = {} },
                .disconnected => |r| .{ .disconnected = @enumFromInt(@intFromEnum(r)) },
                .connection_failed => |r| .{ .connection_failed = @enumFromInt(@intFromEnum(r)) },
                .scan_done => |info| .{ .scan_done = .{ .count = info.count, .success = info.success } },
                .rssi_low => |rssi| .{ .rssi_low = rssi },
                .ap_sta_connected => |sta| .{ .ap_sta_connected = .{ .mac = sta.mac, .rssi = sta.rssi, .aid = sta.aid } },
                .ap_sta_disconnected => |sta| .{ .ap_sta_disconnected = .{ .mac = sta.mac, .rssi = sta.rssi, .aid = sta.aid } },
            };

            // Update internal state based on event
            switch (event) {
                .connected => self.state = .connected,
                .disconnected => self.state = .disconnected,
                .connection_failed => self.state = .failed,
                .scan_done => {},
                .rssi_low => {},
                .ap_sta_connected => {},
                .ap_sta_disconnected => {},
            }

            return event;
        }

        // ================================================================
        // Status Queries
        // ================================================================

        /// Check if connected (802.11 layer)
        pub fn isConnected(self: *const Self) bool {
            return self.driver.isConnected();
        }

        /// Get current signal strength in dBm (if supported)
        pub fn getRssi(self: *const Self) ?i8 {
            if (@hasDecl(Driver, "getRssi")) {
                return self.driver.getRssi();
            }
            return null;
        }

        /// Get MAC address (if supported)
        pub fn getMac(self: *const Self) ?Mac {
            if (@hasDecl(Driver, "getMac")) {
                return self.driver.getMac();
            }
            return null;
        }

        /// Get current channel (if supported)
        pub fn getChannel(self: *const Self) ?u8 {
            if (@hasDecl(Driver, "getChannel")) {
                return self.driver.getChannel();
            }
            return null;
        }

        /// Get connected SSID (if supported)
        pub fn getSsid(self: *const Self) ?[]const u8 {
            if (@hasDecl(Driver, "getSsid")) {
                return self.driver.getSsid();
            }
            return self.current_ssid;
        }

        /// Get connected BSSID (if supported)
        pub fn getBssid(self: *const Self) ?Mac {
            if (@hasDecl(Driver, "getBssid")) {
                return self.driver.getBssid();
            }
            return null;
        }

        /// Get negotiated PHY mode (if supported)
        pub fn getPhyMode(self: *const Self) ?PhyMode {
            if (@hasDecl(Driver, "getPhyMode")) {
                return self.driver.getPhyMode();
            }
            return null;
        }

        /// Get current state
        pub fn getState(self: *const Self) State {
            return self.state;
        }

        /// Get full status information
        pub fn getStatus(self: *const Self) Status {
            return .{
                .state = self.state,
                .ip = null, // Use Net HAL for IP
                .rssi = self.getRssi(),
                .ssid = self.getSsid(),
                .bssid = self.getBssid(),
                .channel = self.getChannel(),
                .phy_mode = self.getPhyMode(),
            };
        }

        // ================================================================
        // Scanning
        // ================================================================

        /// Start WiFi scan (non-blocking)
        /// Results delivered via scan_done event, then call scanGetResults()
        pub fn scanStart(self: *Self, config: ScanConfig) !void {
            if (@hasDecl(Driver, "scanStart")) {
                // Convert scan_type to passive flag
                const passive = (config.scan_type == .passive);
                return self.driver.scanStart(.{
                    .ssid = config.ssid,
                    .bssid = config.bssid,
                    .channel = config.channel,
                    .show_hidden = config.show_hidden,
                    .passive = passive,
                });
            }
            return error.NotSupported;
        }

        /// Get scan results (call after scan_done event)
        /// Note: Returns driver's ApInfo slice directly (structurally compatible with HAL ApInfo)
        pub fn scanGetResults(self: *Self) []const ApInfo {
            if (@hasDecl(Driver, "scanGetResults")) {
                // Driver returns its own ApInfo type which is structurally identical
                // Use @ptrCast to reinterpret the slice as HAL's ApInfo slice
                const driver_results = self.driver.scanGetResults();
                return @ptrCast(driver_results);
            }
            return &[_]ApInfo{};
        }

        // ================================================================
        // Power Save
        // ================================================================

        /// Set power save mode
        pub fn setPowerSave(self: *Self, mode: PowerSaveMode) void {
            if (@hasDecl(Driver, "setPowerSave")) {
                self.driver.setPowerSave(mode);
            }
        }

        /// Get current power save mode
        pub fn getPowerSave(self: *const Self) PowerSaveMode {
            if (@hasDecl(Driver, "getPowerSave")) {
                return self.driver.getPowerSave();
            }
            return .none;
        }

        // ================================================================
        // Roaming (802.11k/v/r)
        // ================================================================

        /// Configure roaming behavior
        pub fn setRoaming(self: *Self, config: RoamingConfig) void {
            if (@hasDecl(Driver, "setRoaming")) {
                self.driver.setRoaming(.{
                    .rm_enabled = config.rm_enabled,
                    .btm_enabled = config.btm_enabled,
                    .ft_enabled = config.ft_enabled,
                    .mbo_enabled = config.mbo_enabled,
                });
            }
        }

        // ================================================================
        // RSSI Threshold
        // ================================================================

        /// Set RSSI threshold for rssi_low event
        pub fn setRssiThreshold(self: *Self, rssi: i8) void {
            if (@hasDecl(Driver, "setRssiThreshold")) {
                self.driver.setRssiThreshold(rssi);
            }
        }

        // ================================================================
        // TX Power
        // ================================================================

        /// Set maximum TX power (in 0.25 dBm units)
        pub fn setTxPower(self: *Self, power: i8) void {
            if (@hasDecl(Driver, "setTxPower")) {
                self.driver.setTxPower(power);
            }
        }

        /// Get maximum TX power (in 0.25 dBm units)
        pub fn getTxPower(self: *const Self) ?i8 {
            if (@hasDecl(Driver, "getTxPower")) {
                return self.driver.getTxPower();
            }
            return null;
        }

        // ================================================================
        // AP Mode
        // ================================================================

        /// Start WiFi AP
        pub fn startAp(self: *Self, config: ApConfig) !void {
            if (@hasDecl(Driver, "startAp")) {
                try self.driver.startAp(.{
                    .ssid = config.ssid,
                    .password = config.password,
                    .channel = config.channel,
                    .auth_mode = @enumFromInt(@intFromEnum(config.auth_mode)),
                    .max_connections = config.max_connections,
                    .hidden = config.hidden,
                    .beacon_interval = config.beacon_interval,
                });
                self.state = .ap_running;
                return;
            }
            return error.NotSupported;
        }

        /// Stop WiFi AP
        pub fn stopAp(self: *Self) void {
            if (@hasDecl(Driver, "stopAp")) {
                self.driver.stopAp();
                self.state = .disconnected;
            }
        }

        /// Check if AP is running
        pub fn isApRunning(self: *const Self) bool {
            if (@hasDecl(Driver, "isApRunning")) {
                return self.driver.isApRunning();
            }
            return false;
        }

        /// Get list of connected stations
        /// Note: Returns driver's StaInfo slice directly (structurally compatible with HAL StaInfo)
        pub fn getStaList(self: *const Self) []const StaInfo {
            if (@hasDecl(Driver, "getStaList")) {
                // Driver returns its own StaInfo type which is structurally identical
                // Use @ptrCast to reinterpret the slice as HAL's StaInfo slice
                const driver_results = self.driver.getStaList();
                return @ptrCast(driver_results);
            }
            return &[_]StaInfo{};
        }

        /// Deauthenticate a station
        pub fn deauthSta(self: *Self, mac: Mac) void {
            if (@hasDecl(Driver, "deauthSta")) {
                self.driver.deauthSta(mac);
            }
        }

        // ================================================================
        // Protocol/Bandwidth
        // ================================================================

        /// Set WiFi protocol
        pub fn setProtocol(self: *Self, proto: Protocol) void {
            if (@hasDecl(Driver, "setProtocol")) {
                self.driver.setProtocol(proto);
            }
        }

        /// Set channel bandwidth
        pub fn setBandwidth(self: *Self, bw: Bandwidth) void {
            if (@hasDecl(Driver, "setBandwidth")) {
                self.driver.setBandwidth(bw);
            }
        }

        // ================================================================
        // Country Code
        // ================================================================

        /// Set country code (e.g. "US", "CN")
        pub fn setCountryCode(self: *Self, code: [2]u8) void {
            if (@hasDecl(Driver, "setCountryCode")) {
                self.driver.setCountryCode(code);
            }
        }

        /// Get country code
        pub fn getCountryCode(self: *const Self) [2]u8 {
            if (@hasDecl(Driver, "getCountryCode")) {
                return self.driver.getCountryCode();
            }
            return "01".*; // World safe mode
        }

        // ================================================================
        // Utility Methods
        // ================================================================

        /// Get signal quality as percentage (0-100)
        /// Based on RSSI: -50dBm = 100%, -100dBm = 0%
        pub fn getSignalQuality(self: *const Self) ?u8 {
            const rssi = self.getRssi() orelse return null;

            if (rssi >= -50) return 100;
            if (rssi <= -100) return 0;

            // Linear interpolation: -50 to -100 -> 100 to 0
            const quality: i16 = @as(i16, rssi) + 100;
            return @intCast(@as(u16, @intCast(quality)) * 2);
        }

        /// Format IP address as string (for logging)
        pub fn formatIp(ip: IpAddress) [15]u8 {
            var buf: [15]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] }) catch {
                return "0.0.0.0        ".*;
            };
            return buf;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

/// Mock WiFi event for testing
const MockWifiEvent = union(enum) {
    connected: void,
    disconnected: DisconnectReason,
    connection_failed: FailReason,
    scan_done: ScanDoneInfo,
    rssi_low: i8,
    ap_sta_connected: StaInfo,
    ap_sta_disconnected: StaInfo,
};

test "Wifi event-driven operations" {
    const MockDriver = struct {
        const Self = @This();

        connected: bool = false,
        pending_event: ?MockWifiEvent = null,

        pub fn connect(self: *Self, ssid: []const u8, password: []const u8) void {
            _ = ssid;
            _ = password;
            self.connected = true;
            self.pending_event = .{ .connected = {} };
        }

        pub fn disconnect(self: *Self) void {
            self.connected = false;
        }

        pub fn isConnected(self: *const Self) bool {
            return self.connected;
        }

        pub fn pollEvent(self: *Self) ?MockWifiEvent {
            const event = self.pending_event;
            self.pending_event = null;
            return event;
        }

        pub fn getRssi(_: *const Self) ?i8 {
            return -60;
        }
    };

    const mock_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "wifi.test" };
    };

    const TestWifi = from(mock_spec);

    var driver = MockDriver{};
    var wifi = TestWifi.init(&driver);

    // Initially disconnected
    try std.testing.expect(!wifi.isConnected());
    try std.testing.expectEqual(State.disconnected, wifi.getState());

    // Request connection (non-blocking)
    wifi.connect("TestSSID", "password");
    try std.testing.expectEqual(State.connecting, wifi.getState());

    // Poll for event - should get connected event
    const event = wifi.pollEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(WifiEvent{ .connected = {} }, event.?);

    // State should be updated
    try std.testing.expectEqual(State.connected, wifi.getState());
    try std.testing.expect(wifi.isConnected());

    // No more events
    try std.testing.expect(wifi.pollEvent() == null);

    // Disconnect
    wifi.disconnect();
    try std.testing.expect(!wifi.isConnected());
}

test "Signal quality calculation" {
    const MockDriver = struct {
        const Self = @This();
        rssi: i8 = -75,

        pub fn connect(_: *Self, _: []const u8, _: []const u8) void {}
        pub fn disconnect(_: *Self) void {}
        pub fn isConnected(_: *const Self) bool {
            return true;
        }
        pub fn pollEvent(_: *Self) ?MockWifiEvent {
            return null;
        }
        pub fn getRssi(self: *const Self) ?i8 {
            return self.rssi;
        }
    };

    const mock_spec2 = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "wifi.test2" };
    };

    const TestWifi = from(mock_spec2);

    var driver = MockDriver{};
    var wifi = TestWifi.init(&driver);

    // -75 dBm should be 50%
    driver.rssi = -75;
    try std.testing.expectEqual(@as(?u8, 50), wifi.getSignalQuality());

    // -50 dBm should be 100%
    driver.rssi = -50;
    try std.testing.expectEqual(@as(?u8, 100), wifi.getSignalQuality());

    // -100 dBm should be 0%
    driver.rssi = -100;
    try std.testing.expectEqual(@as(?u8, 0), wifi.getSignalQuality());

    // Better than -50 should be capped at 100%
    driver.rssi = -30;
    try std.testing.expectEqual(@as(?u8, 100), wifi.getSignalQuality());
}

test "Scan and AP mode types" {
    // Test ScanConfig defaults
    const scan_cfg = ScanConfig{};
    try std.testing.expectEqual(@as(?[]const u8, null), scan_cfg.ssid);
    try std.testing.expectEqual(@as(u8, 0), scan_cfg.channel);
    try std.testing.expectEqual(ScanType.active, scan_cfg.scan_type);

    // Test ApConfig defaults
    const ap_cfg = ApConfig{ .ssid = "TestAP", .password = "password" };
    try std.testing.expectEqual(@as(u8, 1), ap_cfg.channel);
    try std.testing.expectEqual(AuthMode.wpa2_psk, ap_cfg.auth_mode);
    try std.testing.expectEqual(@as(u8, 4), ap_cfg.max_connections);

    // Test ApInfo.getSsid()
    var ap_info = ApInfo{
        .ssid = undefined,
        .ssid_len = 4,
        .bssid = .{ 0, 0, 0, 0, 0, 0 },
        .channel = 6,
        .rssi = -50,
        .auth_mode = .wpa2_psk,
    };
    @memcpy(ap_info.ssid[0..4], "Test");
    try std.testing.expectEqualStrings("Test", ap_info.getSsid());
}
