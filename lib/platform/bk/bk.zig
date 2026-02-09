//! BK Module — Entry point for BK7258 platform
//!
//! Single flat module using relative @import paths.
//! All armino/impl/boards files are part of this module tree.

/// Low-level Armino SDK bindings
pub const armino = @import("armino/src/armino.zig");

/// trait + hal implementations
pub const impl = @import("impl/src/impl.zig");

/// Board hardware definitions
pub const boards = struct {
    pub const bk7258 = @import("src/boards/bk7258.zig");
};
