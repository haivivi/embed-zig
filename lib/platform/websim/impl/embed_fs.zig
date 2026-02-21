//! EmbedFs — Zero-copy VFS backed by @embedFile
//!
//! Files are embedded in the binary at compile time. open() returns
//! a File with `data` pointing directly to the embedded bytes.
//! No RAM copy, no read buffers, no slots.

const trait_fs = @import("hal").trait.fs;

pub const Entry = struct {
    path: []const u8,
    data: []const u8,
};

/// Create a zero-copy EmbedFs driver from a comptime file table.
pub fn EmbedFs(comptime entries: []const Entry) type {
    return struct {
        const Self = @This();

        // Dummy close context (no resources to release)
        var dummy: u8 = 0;

        pub fn init() !Self {
            return .{};
        }

        pub fn open(_: *Self, path: []const u8, mode: trait_fs.OpenMode) ?trait_fs.File {
            if (mode != .read) return null;

            const file_data = findEntry(path) orelse return null;

            return trait_fs.File{
                .data = file_data, // zero-copy: points directly to @embedFile data
                .ctx = @ptrCast(&dummy),
                .readFn = null, // not needed — use .data directly
                .writeFn = null,
                .closeFn = &noopClose,
                .size = @intCast(file_data.len),
            };
        }

        fn findEntry(path: []const u8) ?[]const u8 {
            for (entries) |e| {
                if (eql(e.path, path)) return e.data;
            }
            return null;
        }

        fn noopClose(_: *anyopaque) void {}

        fn eql(a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            for (a, b) |ca, cb| {
                if (ca != cb) return false;
            }
            return true;
        }
    };
}
