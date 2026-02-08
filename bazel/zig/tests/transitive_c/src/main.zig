//! Transitive C test binary — exercises the bug where zig_binary depending on
//! a zig_package with @cImport fails because cache_merge doesn't copy h/ and o/.
//!
//! crypto_wrapper uses @cImport("xor.h") internally. When this binary depends
//! on crypto_wrapper, the merged cache must include h/ (cImport manifest) and
//! o/ (C object files), otherwise zig will try to re-invoke clang and fail
//! because the -I paths are not available at the binary level.

const std = @import("std");
const crypto = @import("crypto_wrapper");

pub fn main() void {
    // Exercise crypto_wrapper.xor_with_key which internally calls C xor_bytes()
    var data = [_]u8{ 0x48, 0x65, 0x6C, 0x6C, 0x6F }; // "Hello"
    const key = [_]u8{ 0xAA, 0xBB };

    crypto.xor_with_key(&data, &key);
    std.debug.print("xor result: {x}\n", .{data});

    // Also exercise the transitive pure-Zig path (crypto_wrapper → math_utils → base)
    const sum = crypto.checksum(&data);
    std.debug.print("checksum: {d}\n", .{sum});
}
