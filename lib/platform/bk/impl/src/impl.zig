//! BK7258 Implementations of trait and hal interfaces

// ============================================================================
// trait implementations
// ============================================================================

pub const socket = @import("socket.zig");
pub const Socket = socket.Socket;

pub const log = @import("log.zig");
pub const Log = log.Log;
pub const stdLogFn = log.stdLogFn;

pub const time = @import("time.zig");
pub const Time = time.Time;

pub const crypto = @import("crypto/suite.zig");

// ============================================================================
// hal implementations (Drivers)
// ============================================================================

pub const wifi = @import("wifi.zig");
pub const WifiDriver = wifi.WifiDriver;

pub const net = @import("net.zig");
pub const NetDriver = net.NetDriver;

pub const kvs = @import("kvs.zig");
pub const KvsDriver = kvs.KvsDriver;

pub const audio_system = @import("audio_system.zig");

pub const button = @import("button.zig");
pub const ButtonDriver = button.ButtonDriver;

pub const button_group = @import("button_group.zig");
pub const ButtonGroupDriver = button_group.ButtonGroupDriver;

pub const led = @import("led.zig");
pub const PwmLedDriver = led.PwmLedDriver;

pub const rtc = @import("rtc.zig");
pub const RtcReaderDriver = rtc.RtcReaderDriver;
pub const RtcWriterDriver = rtc.RtcWriterDriver;

pub const mic = @import("mic.zig");
pub const MicDriver = mic.MicDriver;

pub const timer = @import("timer.zig");
pub const Timer = timer.Timer;

pub const hci = @import("hci.zig");
pub const HciDriver = hci.HciDriver;

pub const codec = struct {
    pub const opus = @import("codec/opus.zig");
    pub const OpusEncoder = opus.OpusEncoder;
    pub const OpusDecoder = opus.OpusDecoder;
};
