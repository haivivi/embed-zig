//! Virtual File System Interface
//!
//! Platform-independent file access modeled after Go's fs.FS interface.
//! Supports both small files (read into buffer) and large files (streaming).
//!
//! Platform implementations:
//! - websim: @embedFile-based (comptime file table)
//! - ESP32: SPIFFS, LittleFS, or raw partition
//! - std: host filesystem
//!
//! Usage:
//! ```zig
//! // Open and read a small file
//! var file = board.fs.open("/assets/icon.rgb565", .read) orelse return;
//! defer file.close();
//! const n = file.read(&buf);
//!
//! // Stream a large file
//! var fw = board.fs.open("/ota/firmware.bin", .write) orelse return;
//! defer fw.close();
//! _ = fw.write(data);
//! ```

/// File open mode
pub const OpenMode = enum {
    read,
    write,
    read_write,
};

/// Error type for file operations
pub const FsError = error{
    NotFound,
    PermissionDenied,
    IoError,
    NoSpace,
    InvalidPath,
};

/// File handle — returned by open(), used for read/write/close.
///
/// Supports two access modes:
/// - **Zero-copy** (mmap): `data` is non-null, points directly to backing store
///   (flash mmap, @embedFile). No RAM copy needed. Use this when available.
/// - **Streaming**: `data` is null, use read()/write() with caller buffer.
///   For network downloads, OTA, etc.
pub const File = struct {
    /// Zero-copy data pointer — non-null for mmap-capable backends
    /// (@embedFile, flash mmap). Points directly to backing store.
    /// When non-null, read()/readAll() are unnecessary — use this directly.
    data: ?[]const u8 = null,

    /// Opaque context pointer — points to backend-specific state.
    ctx: *anyopaque,

    /// Read up to buf.len bytes. Returns number of bytes read, 0 = EOF.
    readFn: ?*const fn (ctx: *anyopaque, buf: []u8) usize = null,

    /// Write data. Returns number of bytes written.
    writeFn: ?*const fn (ctx: *anyopaque, data: []const u8) usize = null,

    /// Close the file and release resources.
    closeFn: *const fn (ctx: *anyopaque) void,

    /// File size in bytes (known at open time, or 0 if unknown).
    size: u32,

    pub fn read(self: *File, buf: []u8) usize {
        const f = self.readFn orelse return 0;
        return f(self.ctx, buf);
    }

    pub fn write(self: *File, buf: []const u8) usize {
        const f = self.writeFn orelse return 0;
        return f(self.ctx, buf);
    }

    pub fn close(self: *File) void {
        self.closeFn(self.ctx);
    }

    /// Convenience: read entire file into buffer.
    /// Returns the portion of buf that was filled.
    pub fn readAll(self: *File, buf: []u8) []const u8 {
        var total: usize = 0;
        while (total < buf.len) {
            const n = self.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }
};

/// Compile-time validation that a type implements the FS interface.
///
/// Driver must provide:
///   pub fn open(self: *Driver, path: []const u8, mode: OpenMode) ?File
///
/// Example:
/// ```zig
/// const fs_spec = struct {
///     pub const Driver = EmbedFsDriver;
///     pub const meta = .{ .id = "fs.assets" };
/// };
/// const MyFs = fs.from(fs_spec);
/// ```
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify required method: open(self, path, mode) -> ?File
        _ = @as(*const fn (*BaseDriver, []const u8, OpenMode) ?File, &BaseDriver.open);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker = _FsMarker;
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn open(self: *Self, path: []const u8, mode: OpenMode) ?File {
            return self.driver.open(path, mode);
        }
    };
}

/// Check if a type is an Fs HAL component
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _FsMarker;
}

/// Private marker for type identification
const _FsMarker = struct {};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "Fs with mock driver" {
    const MockFsDriver = struct {
        const Self = @This();

        const mock_data = "hello world";

        const MockFileCtx = struct {
            data: []const u8,
            pos: usize,
        };

        var ctx_storage: MockFileCtx = .{ .data = mock_data, .pos = 0 };

        pub fn open(self: *Self, path: []const u8, mode: OpenMode) ?File {
            _ = self;
            _ = mode;
            if (std.mem.eql(u8, path, "/test.txt")) {
                ctx_storage = .{ .data = mock_data, .pos = 0 };
                return File{
                    .ctx = @ptrCast(&ctx_storage),
                    .readFn = &mockRead,
                    .closeFn = &mockClose,
                    .size = mock_data.len,
                };
            }
            return null;
        }

        fn mockRead(ctx: *anyopaque, buf: []u8) usize {
            const fctx: *MockFileCtx = @ptrCast(@alignCast(ctx));
            const remaining = fctx.data.len - fctx.pos;
            const to_read = @min(buf.len, remaining);
            if (to_read == 0) return 0;
            @memcpy(buf[0..to_read], fctx.data[fctx.pos..][0..to_read]);
            fctx.pos += to_read;
            return to_read;
        }

        fn mockClose(_: *anyopaque) void {}
    };

    const fs_spec = struct {
        pub const Driver = MockFsDriver;
        pub const meta = .{ .id = "fs.test" };
    };

    const TestFs = from(fs_spec);

    var driver = MockFsDriver{};
    var vfs = TestFs.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("fs.test", TestFs.meta.id);

    // Test open existing file
    var file = vfs.open("/test.txt", .read) orelse return error.TestUnexpectedResult;
    defer file.close();

    try std.testing.expectEqual(@as(u32, 11), file.size);

    // Test read
    var buf: [64]u8 = undefined;
    const data = file.readAll(&buf);
    try std.testing.expectEqualStrings("hello world", data);

    // Test open non-existent file
    const missing = vfs.open("/missing.txt", .read);
    try std.testing.expectEqual(@as(?File, null), missing);
}

test "Fs zero-copy (mmap) path" {
    const MmapDriver = struct {
        const Self = @This();
        const file_data = "mmap content here";
        var dummy: u8 = 0;

        pub fn open(_: *Self, path: []const u8, mode: OpenMode) ?File {
            _ = mode;
            if (std.mem.eql(u8, path, "/data.bin")) {
                return File{
                    .data = file_data, // zero-copy
                    .ctx = @ptrCast(&dummy),
                    .closeFn = &noopClose,
                    .size = file_data.len,
                };
            }
            return null;
        }

        fn noopClose(_: *anyopaque) void {}
    };

    const fs_spec = struct {
        pub const Driver = MmapDriver;
        pub const meta = .{ .id = "fs.mmap" };
    };

    var driver = MmapDriver{};
    var vfs = from(fs_spec).init(&driver);

    var file = vfs.open("/data.bin", .read) orelse return error.TestUnexpectedResult;
    defer file.close();

    // Zero-copy: data available directly, no read() needed
    try std.testing.expect(file.data != null);
    try std.testing.expectEqualStrings("mmap content here", file.data.?);
    try std.testing.expectEqual(@as(u32, 17), file.size);
}
