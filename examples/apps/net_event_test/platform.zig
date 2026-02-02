//! Board Configuration - Net Event Test
//!
//! This app tests the Net HAL event system through board.poll() and board.nextEvent().
//!
//! Test targets:
//! - lib/esp/src/idf/net/netif_helper.c (IP_EVENT handling, event queue)
//! - lib/esp/src/idf/net/netif.zig (pollEvent, eventInit)
//! - lib/esp/src/impl/net.zig (NetDriver implementation)
//! - lib/hal/src/net.zig (HAL wrapper)
//! - lib/hal/src/board.zig (event integration)

const hal = @import("hal");
const build_options = @import("build_options");
const idf = @import("esp");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
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
    // THIS IS THE PRIMARY TARGET OF THIS TEST
    pub const net = hal.net.from(hw.net_spec);
};

pub const Board = hal.Board(spec);

/// Static net functions for querying network interfaces
/// These are convenience functions that don't require an instance
pub const net_impl = idf.impl.net;
