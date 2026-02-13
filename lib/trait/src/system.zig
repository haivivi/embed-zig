//! System Trait — System information query contract
//!
//! Provides access to CPU, memory, and other system-level information.
//!
//! ## Contract
//!
//! ```zig
//! const Runtime = struct {
//!     pub fn getCpuCount() !usize;
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("std_impl").runtime;
//! const num_cores = try Rt.getCpuCount();
//! ```

const std = @import("std");

/// Validate that Impl provides system information queries
///
/// Required:
/// - `getCpuCount() !usize`
pub fn from(comptime Impl: type) void {
    comptime {
        // Validate getCpuCount
        if (!@hasDecl(Impl, "getCpuCount")) @compileError("System trait missing getCpuCount() function");
        
        // Validate return type (allow any error set)
        const getCpuCountFn = @typeInfo(@TypeOf(Impl.getCpuCount));
        if (getCpuCountFn != .@"fn") @compileError("getCpuCount must be a function");
        
        const return_type = @typeInfo(getCpuCountFn.@"fn".return_type.?);
        if (return_type != .error_union) @compileError("getCpuCount() must return error union");
        if (return_type.error_union.payload != usize) {
            @compileError("getCpuCount() must return !usize");
        }
    }
}
