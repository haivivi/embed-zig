//! BK Module
//!
//! Provides access to Armino SDK bindings and trait/hal implementations.
//!
//! ## Package Structure
//!
//! ```
//! lib/platform/bk/
//! ├── bk.zig       (this file — entry)
//! ├── armino/      Low-level Armino SDK bindings
//! ├── impl/        trait + hal implementations
//! └── src/boards/  Board definitions
//! ```

/// Low-level Armino SDK bindings (C helper wrappers)
pub const armino = @import("armino/src/armino.zig");

/// trait + hal implementations
pub const impl = @import("impl/src/impl.zig");

/// Board hardware definitions
pub const boards = struct {
    pub const bk7258 = @import("src/boards/bk7258.zig");
};
