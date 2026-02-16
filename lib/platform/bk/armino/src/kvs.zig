//! KVS bindings for BK7258 — wraps EasyFlash V4

pub const Error = error{ KvsError, NotFound };

extern fn bk_zig_kvs_get(key: [*]const u8, key_len: c_uint, value: [*]u8, value_len: c_uint) c_int;
extern fn bk_zig_kvs_set(key: [*]const u8, key_len: c_uint, value: [*]const u8, value_len: c_uint) c_int;
extern fn bk_zig_kvs_commit() c_int;

pub fn get(key: []const u8, buf: []u8) !usize {
    const ret = bk_zig_kvs_get(key.ptr, @intCast(key.len), buf.ptr, @intCast(buf.len));
    if (ret <= 0) return error.NotFound;
    return @intCast(ret);
}

pub fn set(key: []const u8, value: []const u8) !void {
    if (bk_zig_kvs_set(key.ptr, @intCast(key.len), value.ptr, @intCast(value.len)) != 0)
        return error.KvsError;
}

pub fn commit() !void {
    if (bk_zig_kvs_commit() != 0) return error.KvsError;
}
