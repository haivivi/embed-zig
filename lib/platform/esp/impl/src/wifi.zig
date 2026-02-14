//! WiFi Implementation for ESP32
//!
//! Provides HAL-compatible WiFi drivers for STA and AP modes.
//! Uses idf/event, idf/net, and idf/wifi for low-level operations.
//!
//! ## Architecture
//!
//! ```
//! impl/wifi (this file)
//!   ├── StaDriver - STA mode (connect to AP)
//!   └── ApDriver  - AP mode (create hotspot)
//!         │
//!         ▼
//! idf/wifi - Low-level WiFi hardware control
//!         │
//!         ▼
//! idf/net  - Network interface (netif) management
//!         │
//!         ▼
//! idf/event - Event loop foundation
//! ```
//!
//! ## Usage (STA mode)
//!
//! ```zig
//! const wifi_spec = impl.wifi.sta_spec;
//! const Board = hal.board.from(.{ .wifi = wifi_spec, ... });
//!
//! var board: Board = undefined;
//! try board.init();
//! board.wifi.connect("SSID", "password");
//! ```

const std = @import("std");
const idf = @import("idf");
const hal = @import("hal");
const waitgroup = @import("waitgroup");

const log = std.log.scoped(.wifi_impl);
const heap = idf.heap;
const EspRt = idf.runtime;

/// WaitGroup type used for running tasks on IRAM stack.
/// Uses heap.iram allocator for GoContext allocation.
const WG = waitgroup.WaitGroup(EspRt);

// ============================================================================
// Common Types
// ============================================================================

/// WiFi event types - same as hal.wifi.WifiEvent for compatibility
pub const WifiEvent = hal.wifi.WifiEvent;

/// WiFi error type
pub const Error = error{
    InitFailed,
    AlreadyInitialized,
    NotInitialized,
    ConfigFailed,
    ConnectFailed,
    Timeout,
};

// ============================================================================
// Internal: IRAM Task Contexts
// ============================================================================

/// Context for WiFi STA initialization task
const StaInitCtx = struct {
    result: c_int = 0,
};

/// STA init task - runs on IRAM stack to avoid XIP PSRAM conflict
fn staInitTask(ctx: *StaInitCtx) void {

    // 1. Initialize event loop
    idf.event.init() catch {
        ctx.result = -1;
        return;
    };

    // 2. Initialize netif subsystem
    idf.net.netif.init() catch {
        ctx.result = -2;
        return;
    };

    // 3. Create WiFi STA netif
    idf.net.netif.createWifiSta() catch {
        ctx.result = -3;
        return;
    };

    // 4. Initialize WiFi driver
    idf.wifi.init() catch {
        ctx.result = -4;
        return;
    };

    // 5. Set STA mode
    idf.wifi.setMode(.sta) catch {
        ctx.result = -5;
        return;
    };

    ctx.result = 0;
}

/// Context for WiFi connect task
const StaConnectCtx = struct {
    ssid: [33:0]u8 = std.mem.zeroes([33:0]u8),
    password: [65:0]u8 = std.mem.zeroes([65:0]u8),
    timeout_ms: u32 = 30000,
    result: c_int = 0,
};

/// STA connect task - runs on IRAM stack
fn staConnectTask(ctx: *StaConnectCtx) void {

    const ssid_len = std.mem.indexOfScalar(u8, &ctx.ssid, 0) orelse ctx.ssid.len;
    const pass_len = std.mem.indexOfScalar(u8, &ctx.password, 0) orelse ctx.password.len;

    // Configure STA
    idf.wifi.setStaConfig(
        ctx.ssid[0..ssid_len :0],
        ctx.password[0..pass_len :0],
    ) catch {
        ctx.result = -1;
        return;
    };

    // Connect (blocking)
    idf.wifi.connect(.{
        .timeout_ms = ctx.timeout_ms,
        .max_retry = 5,
    }) catch |err| {
        ctx.result = switch (err) {
            error.Timeout => -2,
            else => -3,
        };
        return;
    };

    ctx.result = 0;
}

// ============================================================================
// STA Driver
// ============================================================================

/// WiFi Station Driver - connects to existing WiFi networks
/// Implements hal.wifi.Driver interface
pub const StaDriver = struct {
    const Self = @This();

    initialized: bool = false,
    connected: bool = false,
    ip_address: [4]u8 = .{ 0, 0, 0, 0 },

    /// Initialize STA mode
    /// Initializes: event loop -> netif -> wifi driver -> STA mode
    pub fn init() !Self {
        // Run initialization on IRAM stack (PHY calibration accesses Flash)
        var wg = WG.init();
        defer wg.deinit();

        var ctx = StaInitCtx{};
        wg.go(staInitTask, .{&ctx}) catch {
            return error.InitFailed;
        };
        wg.wait();

        if (ctx.result != 0) {
            log.err("STA init failed at step {d}", .{-ctx.result});
            return error.InitFailed;
        }

        log.info("STA driver initialized", .{});
        return .{ .initialized = true };
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        if (self.connected) {
            idf.wifi.disconnect();
        }
        idf.wifi.deinit();
        self.initialized = false;
        self.connected = false;
    }

    /// Connect to WiFi network (required by hal.wifi)
    /// Note: HAL expects void return, errors are logged internally
    pub fn connect(self: *Self, ssid: []const u8, password: []const u8) void {
        if (!self.initialized) {
            log.err("STA not initialized", .{});
            return;
        }

        // Run connection on IRAM stack
        var wg = WG.init();
        defer wg.deinit();

        var ctx = StaConnectCtx{
            .timeout_ms = 30000,
        };

        const ssid_len = @min(ssid.len, 32);
        const pass_len = @min(password.len, 64);
        @memcpy(ctx.ssid[0..ssid_len], ssid[0..ssid_len]);
        @memcpy(ctx.password[0..pass_len], password[0..pass_len]);

        wg.go(staConnectTask, .{&ctx}) catch {
            log.err("Failed to spawn connect task", .{});
            return;
        };
        wg.wait();

        if (ctx.result == 0) {
            self.connected = true;
            self.ip_address = idf.wifi.getStaIp();
            log.info("WiFi connected, IP: {}.{}.{}.{}", .{
                self.ip_address[0],
                self.ip_address[1],
                self.ip_address[2],
                self.ip_address[3],
            });
        } else if (ctx.result == -2) {
            log.err("WiFi connect timeout", .{});
            self.connected = false;
        } else {
            log.err("WiFi connect failed: {d}", .{ctx.result});
            self.connected = false;
        }
    }

    /// Disconnect from WiFi (required by hal.wifi)
    pub fn disconnect(self: *Self) void {
        idf.wifi.disconnect();
        self.connected = false;
        self.ip_address = .{ 0, 0, 0, 0 };
    }

    /// Check if connected (required by hal.wifi)
    pub fn isConnected(self: *const Self) bool {
        return self.connected;
    }

    /// Get IP address (optional for hal.wifi)
    pub fn getIpAddress(self: *const Self) ?[4]u8 {
        if (self.connected) {
            return self.ip_address;
        }
        return null;
    }

    /// Get RSSI (optional for hal.wifi)
    pub fn getRssi(self: *const Self) ?i8 {
        _ = self;
        const rssi = idf.wifi.getRssi();
        return if (rssi != 0) rssi else null;
    }

    /// Poll for events (required by hal.wifi)
    pub fn pollEvent(_: *Self) ?WifiEvent {
        // Events are handled via net HAL (dhcp_bound, etc.)
        return null;
    }
};

// ============================================================================
// AP Driver
// ============================================================================

/// Context for WiFi AP initialization task
const ApInitCtx = struct {
    result: c_int = 0,
};

/// AP init task - runs on IRAM stack
fn apInitTask(ctx: *ApInitCtx) void {

    // 1. Initialize event loop
    idf.event.init() catch {
        ctx.result = -1;
        return;
    };

    // 2. Initialize netif subsystem
    idf.net.netif.init() catch {
        ctx.result = -2;
        return;
    };

    // 3. Create WiFi AP netif
    idf.net.netif.createWifiAp() catch {
        ctx.result = -3;
        return;
    };

    // 4. Initialize WiFi driver
    idf.wifi.init() catch {
        ctx.result = -4;
        return;
    };

    // 5. Set AP mode
    idf.wifi.setMode(.ap) catch {
        ctx.result = -5;
        return;
    };

    ctx.result = 0;
}

/// WiFi Access Point Driver - creates a WiFi hotspot
pub const ApDriver = struct {
    const Self = @This();

    initialized: bool = false,
    started: bool = false,
    ssid: [33]u8 = std.mem.zeroes([33]u8),
    ssid_len: u8 = 0,

    /// Initialize AP mode
    pub fn init() !Self {
        var wg = WG.init();
        defer wg.deinit();

        var ctx = ApInitCtx{};
        wg.go(apInitTask, .{&ctx}) catch {
            return error.InitFailed;
        };
        wg.wait();

        if (ctx.result != 0) {
            log.err("AP init failed at step {d}", .{-ctx.result});
            return error.InitFailed;
        }

        log.info("AP driver initialized", .{});
        return .{ .initialized = true };
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        if (self.started) {
            idf.wifi.stop();
        }
        idf.wifi.deinit();
        self.initialized = false;
        self.started = false;
    }

    /// AP configuration
    pub const Config = struct {
        ssid: []const u8,
        password: []const u8 = "",
        channel: u8 = 1,
        max_connections: u8 = 4,
    };

    /// Start AP with given configuration
    pub fn start(self: *Self, config: Config) !void {
        if (!self.initialized) {
            return error.NotInitialized;
        }

        // Store SSID
        const ssid_len = @min(config.ssid.len, 32);
        @memcpy(self.ssid[0..ssid_len], config.ssid[0..ssid_len]);
        self.ssid_len = @intCast(ssid_len);

        // Convert to sentinel-terminated
        var ssid_buf: [33:0]u8 = std.mem.zeroes([33:0]u8);
        var pass_buf: [65:0]u8 = std.mem.zeroes([65:0]u8);

        @memcpy(ssid_buf[0..ssid_len], config.ssid[0..ssid_len]);
        const pass_len = @min(config.password.len, 64);
        @memcpy(pass_buf[0..pass_len], config.password[0..pass_len]);

        // Configure AP
        try idf.wifi.setApConfig(.{
            .ssid = ssid_buf[0..ssid_len :0],
            .password = pass_buf[0..pass_len :0],
            .channel = config.channel,
            .max_connections = config.max_connections,
        });

        // Start WiFi
        try idf.wifi.start();

        self.started = true;
        log.info("AP started: {s}", .{config.ssid});
    }

    /// Stop AP
    pub fn stop(self: *Self) void {
        if (self.started) {
            idf.wifi.stop();
            self.started = false;
            log.info("AP stopped", .{});
        }
    }

    /// Check if AP is running
    pub fn isStarted(self: *const Self) bool {
        return self.started;
    }

    /// Get SSID
    pub fn getSsid(self: *const Self) []const u8 {
        return self.ssid[0..self.ssid_len];
    }

    /// Get number of connected stations
    pub fn getStationCount(self: *const Self) usize {
        _ = self;
        return idf.wifi.getApStationCount();
    }

    /// Get connected station info
    pub fn getStations(self: *const Self, buffer: []idf.wifi.StationInfo) []idf.wifi.StationInfo {
        _ = self;
        return idf.wifi.getApStations(buffer);
    }

    /// Poll for events (required by hal.wifi for AP mode)
    pub fn pollEvent(_: *Self) ?WifiEvent {
        // AP events (sta_connected, sta_disconnected) could be implemented here
        return null;
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

/// Pre-defined WiFi STA spec for HAL board integration
pub const sta_spec = struct {
    pub const Driver = StaDriver;
    pub const meta = .{ .id = "wifi.sta" };
};

/// Pre-defined WiFi AP spec for HAL board integration
pub const ap_spec = struct {
    pub const Driver = ApDriver;
    pub const meta = .{ .id = "wifi.ap" };
};

// Legacy alias for backward compatibility
pub const wifi_spec = sta_spec;
pub const WifiDriver = StaDriver;
