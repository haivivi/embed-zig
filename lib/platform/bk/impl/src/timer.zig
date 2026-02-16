//! Timer Implementation for BK7258
//!
//! Wraps RTOS software timer for hal.timer interface.

const armino = @import("../../armino/src/armino.zig");

pub const Timer = armino.timer.Timer;
pub const TimerCallback = armino.timer.TimerCallback;
