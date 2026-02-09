//! Board Configuration - Net Event Test
//!
//! Tests WiFi and Net HAL event systems through board.nextEvent().

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for net_event_test"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
    pub const isRunning = hw.isRunning;

    // WiFi HAL - provides 802.11 layer events (connected, disconnected, connection_failed)
    pub const wifi = hal.wifi.from(hw.wifi_spec);

    // Net HAL - provides IP layer events (dhcp_bound, ip_lost, etc.)
    pub const net = hal.net.from(hw.net_spec);
};

pub const Board = hal.Board(spec);

/// Net query functions (optional, platform-specific)
/// ESP provides list/get/getDns; BK does not yet.
pub const has_net_query = @hasDecl(hw, "net_query");
pub const net_query = if (has_net_query) hw.net_query else void;
