//! ADC (SARADC) bindings for BK7258

pub const Error = error{AdcError};

extern fn bk_zig_adc_read(channel: c_uint, value_out: *u16) c_int;

/// Read a single ADC sample from the given channel.
pub fn read(channel: u32) !u16 {
    var value: u16 = 0;
    if (bk_zig_adc_read(@intCast(channel), &value) != 0) return error.AdcError;
    return value;
}
