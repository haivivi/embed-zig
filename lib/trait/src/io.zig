//! IO Trait — Async I/O service contract
//!
//! Validates that a type provides platform-specific async I/O multiplexing
//! (kqueue on macOS/BSD, epoll on Linux, IOCP on Windows).
//!
//! This is a desktop/server-oriented trait. Embedded platforms typically
//! use different I/O models and would not implement this trait.
//!
//! ## Contract
//!
//! ```zig
//! const IOService = struct {
//!     pub const ReadyCallback = struct {
//!         ptr: ?*anyopaque,
//!         callback: *const fn (ptr: ?*anyopaque, fd: std.posix.fd_t) void,
//!     };
//!
//!     pub fn init(allocator: std.mem.Allocator) !IOService;
//!     pub fn deinit(self: *IOService) void;
//!     pub fn registerRead(self: *IOService, fd: fd_t, cb: ReadyCallback) void;
//!     pub fn registerWrite(self: *IOService, fd: fd_t, cb: ReadyCallback) void;
//!     pub fn unregister(self: *IOService, fd: fd_t) void;
//!     pub fn poll(self: *IOService, timeout_ms: i32) usize;
//!     pub fn wake(self: *IOService) void;
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! pub fn UDP(comptime Rt: type) type {
//!     comptime io.from(Rt.IO);  // validate IO service
//!     return struct {
//!         io: Rt.IO,
//!         // ...
//!     };
//! }
//! ```

const std = @import("std");

/// Validate that Impl is a valid IOService type
///
/// Required:
/// - `ReadyCallback` type with `ptr` and `callback` fields
/// - `init(Allocator) !Impl`
/// - `deinit(*Impl) void`
/// - `registerRead(*Impl, fd_t, ReadyCallback) void`
/// - `registerWrite(*Impl, fd_t, ReadyCallback) void`
/// - `unregister(*Impl, fd_t) void`
/// - `poll(*Impl, i32) usize`
/// - `wake(*Impl) void`
pub fn from(comptime Impl: type) void {
    comptime {
        // Must have ReadyCallback type
        if (!@hasDecl(Impl, "ReadyCallback")) @compileError("IOService missing ReadyCallback type");

        // Must have required methods
        if (!@hasDecl(Impl, "init")) @compileError("IOService missing init() function");
        if (!@hasDecl(Impl, "deinit")) @compileError("IOService missing deinit() function");
        if (!@hasDecl(Impl, "registerRead")) @compileError("IOService missing registerRead() function");
        if (!@hasDecl(Impl, "registerWrite")) @compileError("IOService missing registerWrite() function");
        if (!@hasDecl(Impl, "unregister")) @compileError("IOService missing unregister() function");
        if (!@hasDecl(Impl, "poll")) @compileError("IOService missing poll() function");
        if (!@hasDecl(Impl, "wake")) @compileError("IOService missing wake() function");

        const RC = Impl.ReadyCallback;
        if (@typeInfo(RC) != .@"struct") @compileError("ReadyCallback must be a struct");
        if (!@hasField(RC, "ptr") or !@hasField(RC, "callback")) {
            @compileError("ReadyCallback must contain ptr and callback fields");
        }

        const expected_ptr_t = ?*anyopaque;
        const expected_cb_t = *const fn (?*anyopaque, std.posix.fd_t) void;

        const rc_fields = @typeInfo(RC).@"struct".fields;
        var ptr_ok = false;
        var callback_ok = false;
        for (rc_fields) |f| {
            if (std.mem.eql(u8, f.name, "ptr")) {
                ptr_ok = (f.type == expected_ptr_t);
            } else if (std.mem.eql(u8, f.name, "callback")) {
                callback_ok = (f.type == expected_cb_t);
            }
        }
        if (!ptr_ok) @compileError("ReadyCallback.ptr must be ?*anyopaque");
        if (!callback_ok) @compileError("ReadyCallback.callback signature mismatch");

        const fd_t = std.posix.fd_t;
        _ = @as(*const fn (std.mem.Allocator) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl, fd_t, RC) void, &Impl.registerRead);
        _ = @as(*const fn (*Impl, fd_t, RC) void, &Impl.registerWrite);
        _ = @as(*const fn (*Impl, fd_t) void, &Impl.unregister);
        _ = @as(*const fn (*Impl, i32) usize, &Impl.poll);
        _ = @as(*const fn (*Impl) void, &Impl.wake);
    }
}
