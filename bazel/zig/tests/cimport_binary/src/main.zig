//! Regression test for multi-module @cImport ordering bug.
//!
//! This binary depends on TWO modules:
//!   1. crypto_wrapper — has @cImport("xor.h") with -I include paths
//!   2. config — a plain Zig module with NO @cImport
//!
//! The Zig compiler has a bug where -I flags for a module are not passed
//! to clang during @cImport if another -M definition follows on the CLI:
//!
//!   -Mcrypto_wrapper=... -I src -Mconfig=...   # FAILS: -I lost
//!   -Mconfig=... -Mcrypto_wrapper=... -I src    # OK: -I at end
//!
//! The fix in _build_module_args ensures modules with c_include_dirs are
//! emitted last, so no subsequent -M can interfere with their -I flags.
//!
//! This test exercises the bug by deeply using crypto_wrapper (forcing
//! @cImport evaluation) alongside config.

const std = @import("std");
const crypto = @import("crypto_wrapper");
const config = @import("config");

pub fn main() void {
    // Exercise crypto_wrapper.xor_with_key which internally calls C xor_bytes()
    // This forces @cImport evaluation in the crypto_wrapper module
    var data = [_]u8{ 0x48, 0x65, 0x6C, 0x6C, 0x6F }; // "Hello"
    const key = [_]u8{ 0xAA, 0xBB };

    crypto.xor_with_key(&data, &key);
    std.debug.print("xor result: {x}\n", .{data});

    // Also use config to ensure both modules are fully resolved
    const cfg = config.getDefault();
    std.debug.print("config: v{d}, retries={d}\n", .{ cfg.version, cfg.retries });

    // Transitive pure-Zig path (crypto_wrapper → math_utils → base)
    const sum = crypto.checksum(&data);
    std.debug.print("checksum: {d}\n", .{sum});
}
