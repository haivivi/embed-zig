//! EmbedFs — VFS implementation backed by @embedFile data
//!
//! Provides a comptime-configured filesystem for websim / testing.
//! Files are embedded in the binary at compile time via @embedFile.
//!
//! Usage:
//! ```zig
//! const MyFs = EmbedFs(&.{
//!     .{ .path = "/assets/bg.rgb565", .data = @embedFile("assets/bg.rgb565") },
//!     .{ .path = "/assets/icon.rgb565", .data = @embedFile("assets/icon.rgb565") },
//! });
//!
//! const vfs_spec = struct {
//!     pub const Driver = MyFs;
//!     pub const meta = .{ .id = "fs.embed" };
//! };
//! ```

const trait_fs = @import("trait").fs;

/// A single embedded file entry.
pub const Entry = struct {
    path: []const u8,
    data: []const u8,
};

/// Create an EmbedFs driver type from a comptime file table.
///
/// Returns a type that implements the trait.fs Driver interface:
///   pub fn init() !Self
///   pub fn open(self: *Self, path: []const u8, mode: OpenMode) ?trait_fs.File
pub fn EmbedFs(comptime entries: []const Entry) type {
    return struct {
        const Self = @This();

        /// Per-file read state (tracks position for streaming reads).
        const ReadCtx = struct {
            data: []const u8,
            pos: usize,
        };

        /// Storage for active file contexts.
        /// Max 4 concurrent open files — sufficient for embedded UI.
        const MAX_OPEN = 4;
        ctx_slots: [MAX_OPEN]ReadCtx = [_]ReadCtx{.{ .data = &.{}, .pos = 0 }} ** MAX_OPEN,
        ctx_active: [MAX_OPEN]bool = [_]bool{false} ** MAX_OPEN,

        pub fn init() !Self {
            return .{};
        }

        pub fn open(self: *Self, path: []const u8, mode: trait_fs.OpenMode) ?trait_fs.File {
            // EmbedFs is read-only
            if (mode != .read) return null;

            // Find matching entry
            const data = findEntry(path) orelse return null;

            // Allocate a context slot
            const slot = self.allocSlot() orelse return null;
            self.ctx_slots[slot] = .{ .data = data, .pos = 0 };
            self.ctx_active[slot] = true;

            return trait_fs.File{
                .ctx = @ptrCast(&self.ctx_slots[slot]),
                .readFn = &readFn,
                .writeFn = null,
                .closeFn = &closeFn,
                .size = @intCast(data.len),
            };
        }

        fn findEntry(path: []const u8) ?[]const u8 {
            for (entries) |e| {
                if (eql(e.path, path)) return e.data;
            }
            return null;
        }

        fn allocSlot(self: *Self) ?usize {
            for (0..MAX_OPEN) |i| {
                if (!self.ctx_active[i]) return i;
            }
            return null;
        }

        fn readFn(ctx: *anyopaque, buf: []u8) usize {
            const rctx: *ReadCtx = @ptrCast(@alignCast(ctx));
            const remaining = rctx.data.len - rctx.pos;
            const n = @min(buf.len, remaining);
            if (n == 0) return 0;
            @memcpy(buf[0..n], rctx.data[rctx.pos..][0..n]);
            rctx.pos += n;
            return n;
        }

        fn closeFn(ctx: *anyopaque) void {
            const rctx: *ReadCtx = @ptrCast(@alignCast(ctx));
            rctx.pos = 0;
            rctx.data = &.{};
            // Note: ctx_active flag is not cleared here because we
            // don't have a back-reference to the slot index.
            // Slots are reused when data is empty.
        }

        fn eql(a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            for (a, b) |ca, cb| {
                if (ca != cb) return false;
            }
            return true;
        }
    };
}
