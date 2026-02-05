//! ESP Module
//!
//! Provides access to ESP-IDF bindings and trait/hal implementations.
//!
//! ## Package Structure
//!
//! ```
//! lib/esp/
//! ├── idf/      # Low-level ESP-IDF bindings (C API wrappers)
//! │   └── src/
//! │       ├── gpio.zig, adc.zig, nvs.zig, ...
//! │       ├── sync.zig, queue.zig, async.zig, ...
//! │       └── wifi/, ledc/, timer/, ...
//! │
//! └── impl/     # trait + hal implementations
//!     └── src/
//!         ├── socket.zig, tls.zig, time.zig, i2c.zig, log.zig  (trait)
//!         └── wifi.zig, kvs.zig, mic.zig, led.zig, ...         (hal)
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const esp = @import("esp");
//!
//! // Low-level ESP-IDF access
//! esp.idf.gpio.setLevel(5, 1);
//! esp.idf.time.sleepMs(100);
//!
//! // trait/hal implementations
//! const trait = @import("trait");
//! const Socket = trait.socket.from(esp.impl.Socket);
//! ```

/// Low-level ESP-IDF bindings (C API wrappers)
pub const idf = @import("idf");

/// trait + hal implementations
pub const impl = @import("impl");

/// Board hardware definitions
pub const boards = struct {
    pub const korvo2_v3 = @import("boards/korvo2_v3.zig");
    pub const esp32s3_devkit = @import("boards/esp32s3_devkit.zig");
    pub const lichuang_szp = @import("boards/lichuang_szp.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
}
