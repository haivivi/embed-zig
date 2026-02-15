//! ESP board for e2e trait/kvs
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);
pub const Nvs = struct {
    pub const NvsError = idf.nvs.NvsError;

    inner: idf.Nvs,

    pub fn flashInit() NvsError!void {
        return idf.nvs.init();
    }

    pub fn open(namespace: [:0]const u8) NvsError!Nvs {
        const inner = try idf.Nvs.open(namespace);
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Nvs) void {
        self.inner.close();
    }

    pub fn setU32(self: *Nvs, key: [:0]const u8, value: u32) NvsError!void {
        return self.inner.setU32(key, value);
    }

    pub fn getU32(self: *Nvs, key: [:0]const u8) NvsError!u32 {
        return self.inner.getU32(key);
    }

    pub fn commit(self: *Nvs) NvsError!void {
        return self.inner.commit();
    }
};
