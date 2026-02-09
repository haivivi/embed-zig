//! Hardware Definition & Drivers: BK7258

const armino = @import("../../armino/src/armino.zig");
const impl = @import("../../impl/src/impl.zig");

pub const name = "BK7258";
pub const serial_port = "/dev/cu.usbserial-130";

pub const log = impl.log.scoped("app");

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        impl.Time.sleepMs(ms);
    }
    pub fn getTimeMs() u64 {
        return impl.Time.getTimeMs();
    }
};

pub fn isRunning() bool {
    return true;
}

// ============================================================================
// Socket (LWIP — same as ESP)
// ============================================================================

pub const socket = impl.Socket;

// ============================================================================
// WiFi
// ============================================================================

pub const wifi = armino.wifi;

// ============================================================================
// Audio Configuration (BK7258 Onboard DAC)
// ============================================================================

pub const audio = struct {
    pub const sample_rate: u32 = 8000;
    pub const channels: u8 = 1;
    pub const bits: u8 = 16;
    pub const dig_gain: u8 = 0x2d;
    pub const ana_gain: u8 = 0x0A;
};
