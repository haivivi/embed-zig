//! BK board for e2e trait/kvs — wraps EasyFlash KVS as NVS-compatible interface
const bk = @import("bk");
const KvsInner = bk.impl.kvs.KvsDriver;

pub const log = bk.impl.log.scoped("e2e");

pub const Nvs = struct {
    pub const NvsError = error{ KvsError, ReadFailed, WriteFailed, NotFound };

    inner: KvsInner,

    pub fn flashInit() NvsError!void {
        // BK EasyFlash auto-initializes at boot — no-op
    }

    pub fn open(_: [:0]const u8) NvsError!Nvs {
        // BK EasyFlash is global, no namespace
        const inner = KvsInner.init() catch return error.KvsError;
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Nvs) void {
        self.inner.deinit();
    }

    pub fn setU32(self: *Nvs, key: [:0]const u8, value: u32) NvsError!void {
        self.inner.setU32(key, value) catch return error.WriteFailed;
    }

    pub fn getU32(self: *Nvs, key: [:0]const u8) NvsError!u32 {
        return self.inner.getU32(key) catch return error.NotFound;
    }

    pub fn commit(self: *Nvs) NvsError!void {
        self.inner.commit() catch return error.WriteFailed;
    }
};
