//! Config module — a plain Zig module with no @cImport.
//! Used to test the multi-module ordering bug: when this module is defined
//! after a module with @cImport on the zig CLI, the @cImport's -I flags
//! are lost due to a Zig compiler bug.

pub const version: u32 = 1;
pub const max_retries: u32 = 3;

pub fn getDefault() struct { version: u32, retries: u32 } {
    return .{ .version = version, .retries = max_retries };
}
