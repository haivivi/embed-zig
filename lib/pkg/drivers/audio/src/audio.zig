//! Audio codec drivers.

pub const es7210 = @import("es7210.zig");
pub const es8311 = @import("es8311.zig");

test {
    _ = es7210;
    _ = es8311;
}
