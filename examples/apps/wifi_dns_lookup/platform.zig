//! Board Configuration - WiFi DNS Lookup (Event-Driven)

const hal = @import("hal");
const dns = @import("dns");
const build_options = @import("build_options");

/// Hardware implementation (exported for access to crypto types like CaStore)
pub const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
    pub const isRunning = hw.isRunning;

    // WiFi HAL peripheral (802.11 layer events)
    pub const wifi = hal.wifi.from(hw.wifi_spec);

    // Net HAL peripheral (IP events, DNS)
    pub const net = hal.net.from(hw.net_spec);

    // Socket trait (for DNS resolver)
    pub const socket = hw.socket;

    // Crypto suite (mbedTLS-based, for TLS)
    pub const crypto = hw.crypto;
};

pub const Board = hal.Board(spec);

// ============================================================================
// DNS Resolver with TLS (for DoH)
// ============================================================================

/// DNS Resolver using mbedTLS crypto suite for DoH
/// Uses ESP hardware RNG via Crypto.Rng
pub const DnsResolver = dns.ResolverWithTls(hw.socket, hw.crypto, hw.Rt);
