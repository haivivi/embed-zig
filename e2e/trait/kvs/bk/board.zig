//! BK board for e2e trait/kvs
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");

/// KVS wrapper matching ESP NVS interface for e2e tests
pub const Nvs = struct {
    const KvsInner = bk.impl.KvsDriver;
    inner: KvsInner,

    pub const NvsError = error{ KvsError, ReadFailed, WriteFailed };

    pub fn flashInit() NvsError!void {
        // BK EasyFlash auto-initializes — no-op
    }

    pub fn open(namespace: [:0]const u8) NvsError!Nvs {
        const inner = try KvsInner.open(namespace);
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Nvs) void {
        self.inner.deinit();
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
