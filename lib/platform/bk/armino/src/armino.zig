//! Armino SDK Low-level Bindings
//!
//! Provides idiomatic Zig wrappers for Armino C APIs.
//! Since Armino headers use variadic macros (BK_LOGI etc.) and GNU extensions
//! that Zig's @cImport can't handle, we use explicit C helper functions
//! defined in bk_zig_helper.c.
//!
//! This is the low-level layer - for trait/hal implementations, use lib/bk/impl.
//!
//! ## Modules
//!
//! | Category | Module | Description |
//! |----------|--------|-------------|
//! | Core | log | BK_LOGI/BK_LOGW/BK_LOGE via C helper |
//! | Core | time | rtos_delay, aon_rtc timestamps |
//! | Core | rtos | FreeRTOS task/thread management |

pub const log = @import("log.zig");
pub const time = @import("time.zig");
pub const rtos = @import("rtos.zig");
pub const socket = @import("socket.zig");
pub const wifi = @import("wifi.zig");
pub const speaker = @import("speaker.zig");
