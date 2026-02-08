//! Bluetooth Low Energy Protocol Stack
//!
//! Pure Zig BLE stack implementing Host Controller Interface (HCI),
//! L2CAP, ATT/GATT, GAP, and SMP layers.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────────┐
//! │  GATT Server / Client (handler pattern)     │
//! ├─────────────────────────────────────────────┤
//! │  ATT    │  GAP     │  SMP (future)          │
//! ├─────────┴──────────┴────────────────────────┤
//! │  Host coordinator (loops, queues, dispatch)  │
//! ├──────────────────────────────────────────────┤
//! │  L2CAP (fragmentation, channel mux)          │
//! ├──────────────────────────────────────────────┤
//! │  HCI codec (command/event/ACL encode/decode) │
//! └──────────────────────────────────────────────┘
//!        ↕ raw bytes via hal.hci trait
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const bluetooth = @import("bluetooth");
//!
//! // HCI packet codec
//! const cmd = bluetooth.hci.commands.reset();
//! const evt = bluetooth.hci.events.decode(buf);
//!
//! // L2CAP fragmentation
//! var iter = bluetooth.l2cap.fragment(sdu, cid, handle, mtu);
//! while (iter.next()) |frag| { ... }
//!
//! // Full host (future)
//! var host = bluetooth.Host(Rt).init(&hci_driver);
//! try host.start();
//! ```

// ============================================================================
// HCI Layer — packet encode/decode
// ============================================================================

/// HCI command encoding, event decoding, ACL data format
pub const hci = @import("host/hci/hci.zig");

// ============================================================================
// L2CAP Layer — fragmentation/reassembly + channel mux
// ============================================================================

/// L2CAP fragmentation, reassembly, and signaling
pub const l2cap = @import("host/l2cap/l2cap.zig");

// ============================================================================
// ATT Layer — Attribute Protocol
// ============================================================================

/// ATT PDU codec + attribute database
pub const att = @import("host/att/att.zig");

// ============================================================================
// GAP Layer — Generic Access Profile (future)
// ============================================================================

// pub const gap = @import("host/gap/gap.zig");

// ============================================================================
// GATT Server (future)
// ============================================================================

// pub const gatt_server = @import("gatt_server.zig");

// ============================================================================
// Host Coordinator (future)
// ============================================================================

// pub const Host = @import("host/host.zig").Host;

// ============================================================================
// Tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
