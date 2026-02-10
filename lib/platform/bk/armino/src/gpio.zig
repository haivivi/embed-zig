//! BK7258 GPIO Binding

extern fn bk_zig_gpio_enable_output(id: u32) c_int;
extern fn bk_zig_gpio_enable_input(id: u32) c_int;
extern fn bk_zig_gpio_set_output(id: u32, high: c_int) void;
extern fn bk_zig_gpio_get_input(id: u32) c_int;
extern fn bk_zig_gpio_pull_up(id: u32) c_int;
extern fn bk_zig_gpio_pull_down(id: u32) c_int;
extern fn bk_zig_gpio_set_as_input_pullup(id: u32) c_int;
extern fn bk_zig_gpio_set_as_input_pulldown(id: u32) c_int;
extern fn bk_zig_gpio_set_as_output(id: u32) c_int;

pub fn enableOutput(id: u32) !void {
    if (bk_zig_gpio_enable_output(id) != 0) return error.GpioError;
}

pub fn enableInput(id: u32) !void {
    if (bk_zig_gpio_enable_input(id) != 0) return error.GpioError;
}

pub fn setOutput(id: u32, high: bool) void {
    bk_zig_gpio_set_output(id, if (high) 1 else 0);
}

pub fn getInput(id: u32) bool {
    return bk_zig_gpio_get_input(id) != 0;
}

pub fn pullUp(id: u32) !void {
    if (bk_zig_gpio_pull_up(id) != 0) return error.GpioError;
}

pub fn pullDown(id: u32) !void {
    if (bk_zig_gpio_pull_down(id) != 0) return error.GpioError;
}

/// Unmap GPIO from peripheral (QSPI etc.) and configure as input + pull-up
pub fn setAsInputPullup(id: u32) !void {
    if (bk_zig_gpio_set_as_input_pullup(id) != 0) return error.GpioError;
}

/// Unmap GPIO from peripheral and configure as input + pull-down
pub fn setAsInputPulldown(id: u32) !void {
    if (bk_zig_gpio_set_as_input_pulldown(id) != 0) return error.GpioError;
}

/// Unmap GPIO from peripheral and configure as output
pub fn setAsOutput(id: u32) !void {
    if (bk_zig_gpio_set_as_output(id) != 0) return error.GpioError;
}
