//! Crypto wrapper — Zig + C mixed compilation.
//! Depends on math_utils (which depends on base) to test deep transitive deps.
//! Uses C function xor_bytes() via @cImport to test C source compilation.

const math_utils = @import("math_utils");
const c = @cImport(@cInclude("xor.h"));

/// XOR a slice with a key, clamping key values to [0, 255].
pub fn xor_with_key(data: []u8, key: []const u8) void {
    if (key.len == 0) return;

    // Use C implementation for the XOR
    // Build a repeated key buffer
    var key_buf: [256]u8 = undefined;
    for (0..@min(data.len, 256)) |i| {
        const k = key[i % key.len];
        // Use math_utils.clamp (which uses base internally) to validate key byte
        key_buf[i] = @intCast(math_utils.clamp(@as(i32, k), 0, 255));
    }

    c.xor_bytes(data.ptr, &key_buf, @min(data.len, 256));
}

/// Simple checksum using base arithmetic through math_utils.
pub fn checksum(data: []const u8) i32 {
    var sum: i32 = 0;
    for (data) |byte| {
        sum = @import("base").add(sum, @as(i32, byte));
    }
    return sum;
}

test "xor_with_key roundtrip" {
    const std = @import("std");
    var data = [_]u8{ 0x48, 0x65, 0x6C, 0x6C, 0x6F }; // "Hello"
    const original = data;
    const key = [_]u8{ 0xAA, 0xBB };

    // Encrypt
    xor_with_key(&data, &key);
    // Should be different from original
    try std.testing.expect(!std.mem.eql(u8, &data, &original));

    // Decrypt (XOR again with same key)
    xor_with_key(&data, &key);
    // Should match original
    try std.testing.expectEqualSlices(u8, &original, &data);
}

test "checksum uses transitive base.add" {
    const std = @import("std");
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(i32, 15), checksum(&data));
}

test "math_utils.clamp accessible through dep chain" {
    const std = @import("std");
    // Verify we can call math_utils (transitive dep)
    try std.testing.expectEqual(@as(i32, 100), math_utils.clamp(200, 0, 100));
}
