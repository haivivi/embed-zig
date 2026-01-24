//! GPIO (General Purpose Input/Output) driver
//!
//! Example:
//! ```zig
//! const gpio = idf.gpio;
//!
//! // Configure as output
//! try gpio.setDirection(48, .output);
//! try gpio.setLevel(48, 1);
//!
//! // Configure as input with pull-up
//! try gpio.setDirection(0, .input);
//! try gpio.setPullMode(0, .up);
//! const level = gpio.getLevel(0);
//! ```

const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("driver/gpio.h");
});

/// GPIO direction
pub const Direction = enum(c_uint) {
    disable = 0,
    input = 1,
    output = 2,
    output_od = 3, // Open-drain output
    input_output = 4,
    input_output_od = 5,
};

/// GPIO pull mode
pub const PullMode = enum(c_uint) {
    disable = 0,
    up = 1,
    down = 2,
    up_down = 3,
};

/// GPIO interrupt type
pub const IntrType = enum(c_uint) {
    disable = 0,
    rising_edge = 1,
    falling_edge = 2,
    any_edge = 3,
    low_level = 4,
    high_level = 5,
};

/// GPIO pin number type
pub const Pin = u8;

/// Reset GPIO to default state
pub fn reset(pin: Pin) !void {
    const err = c.gpio_reset_pin(@intCast(pin));
    try sys.espErrToZig(err);
}

/// Set GPIO direction
pub fn setDirection(pin: Pin, direction: Direction) !void {
    const err = c.gpio_set_direction(@intCast(pin), @intFromEnum(direction));
    try sys.espErrToZig(err);
}

/// Set GPIO output level (0 or 1)
pub fn setLevel(pin: Pin, level: u1) !void {
    const err = c.gpio_set_level(@intCast(pin), level);
    try sys.espErrToZig(err);
}

/// Get GPIO input level
pub fn getLevel(pin: Pin) u1 {
    return @intCast(c.gpio_get_level(@intCast(pin)));
}

/// Set GPIO pull mode
pub fn setPullMode(pin: Pin, mode: PullMode) !void {
    const err = c.gpio_set_pull_mode(@intCast(pin), @intFromEnum(mode));
    try sys.espErrToZig(err);
}

/// Enable internal pull-up
pub fn pullUpEnable(pin: Pin) !void {
    const err = c.gpio_pullup_en(@intCast(pin));
    try sys.espErrToZig(err);
}

/// Disable internal pull-up
pub fn pullUpDisable(pin: Pin) !void {
    const err = c.gpio_pullup_dis(@intCast(pin));
    try sys.espErrToZig(err);
}

/// Enable internal pull-down
pub fn pullDownEnable(pin: Pin) !void {
    const err = c.gpio_pulldown_en(@intCast(pin));
    try sys.espErrToZig(err);
}

/// Disable internal pull-down
pub fn pullDownDisable(pin: Pin) !void {
    const err = c.gpio_pulldown_dis(@intCast(pin));
    try sys.espErrToZig(err);
}

/// Set GPIO interrupt type
pub fn setIntrType(pin: Pin, intr_type: IntrType) !void {
    const err = c.gpio_set_intr_type(@intCast(pin), @intFromEnum(intr_type));
    try sys.espErrToZig(err);
}

/// Enable GPIO interrupt
pub fn intrEnable(pin: Pin) !void {
    const err = c.gpio_intr_enable(@intCast(pin));
    try sys.espErrToZig(err);
}

/// Disable GPIO interrupt
pub fn intrDisable(pin: Pin) !void {
    const err = c.gpio_intr_disable(@intCast(pin));
    try sys.espErrToZig(err);
}

/// Install GPIO ISR service
pub fn installIsrService(flags: c_int) !void {
    const err = c.gpio_install_isr_service(flags);
    try sys.espErrToZig(err);
}

/// ISR handler function type
pub const IsrHandler = *const fn (?*anyopaque) callconv(.c) void;

/// Add ISR handler for a GPIO pin
pub fn isrHandlerAdd(pin: Pin, handler: IsrHandler, arg: ?*anyopaque) !void {
    const err = c.gpio_isr_handler_add(@intCast(pin), handler, arg);
    try sys.espErrToZig(err);
}

/// Remove ISR handler for a GPIO pin
pub fn isrHandlerRemove(pin: Pin) !void {
    const err = c.gpio_isr_handler_remove(@intCast(pin));
    try sys.espErrToZig(err);
}

/// High-level GPIO configuration helper
pub const GpioConfig = struct {
    pin: Pin,
    direction: Direction = .input,
    pull_mode: PullMode = .disable,
    intr_type: IntrType = .disable,

    pub fn apply(self: GpioConfig) !void {
        try reset(self.pin);
        try setDirection(self.pin, self.direction);
        try setPullMode(self.pin, self.pull_mode);
        if (self.intr_type != .disable) {
            try setIntrType(self.pin, self.intr_type);
        }
    }
};

/// Configure GPIO as simple output
pub fn configOutput(pin: Pin) !void {
    try reset(pin);
    try setDirection(pin, .output);
}

/// Configure GPIO as simple input with optional pull-up
pub fn configInput(pin: Pin, pull_up: bool) !void {
    try reset(pin);
    try setDirection(pin, .input);
    if (pull_up) {
        try setPullMode(pin, .up);
    }
}
