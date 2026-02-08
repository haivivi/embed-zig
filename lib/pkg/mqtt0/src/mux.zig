//! ServeMux — Topic-based message router
//!
//! Routes incoming MQTT messages to handlers based on topic patterns.
//! Uses a Trie internally for O(topic_depth) matching with +/# wildcards.
//!
//! Both Client and Broker can use Mux. No global instance.
//! Mux itself implements Handler (for composability).

const std = @import("std");
const Allocator = std.mem.Allocator;
const trie_mod = @import("trie.zig");
const packet = @import("packet.zig");

// ============================================================================
// Handler — type-erased message handler
// ============================================================================

pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handleMessage: *const fn (ptr: *anyopaque, client_id: []const u8, msg: *const packet.Message) anyerror!void,
    };

    pub fn handleMessage(self: Handler, client_id: []const u8, msg: *const packet.Message) !void {
        return self.vtable.handleMessage(self.ptr, client_id, msg);
    }

    /// Create Handler from a pointer type that has `handleMessage([]const u8, *const Message) !void`.
    pub fn from(ptr: anytype) Handler {
        const Ptr = @TypeOf(ptr);
        const impl = struct {
            fn handleMessage(raw: *anyopaque, client_id: []const u8, msg: *const packet.Message) anyerror!void {
                const self: Ptr = @ptrCast(@alignCast(raw));
                return self.handleMessage(client_id, msg);
            }
        };
        return .{
            .ptr = @ptrCast(@constCast(ptr)),
            .vtable = &.{ .handleMessage = impl.handleMessage },
        };
    }
};

// ============================================================================
// HandlerFn wrapper
// ============================================================================

/// Function handler signature: fn(client_id, message) !void
pub const HandlerFnType = *const fn ([]const u8, *const packet.Message) anyerror!void;

const FnHandler = struct {
    func: HandlerFnType,

    pub fn handleMessage(self: *const FnHandler, client_id: []const u8, msg: *const packet.Message) anyerror!void {
        return self.func(client_id, msg);
    }
};

// ============================================================================
// Mux
// ============================================================================

pub const Mux = struct {
    allocator: Allocator,
    trie: trie_mod.Trie(Entry),
    fn_handlers: std.ArrayListUnmanaged(*FnHandler),
    mutex: std.Thread.Mutex,

    const Entry = struct {
        handler: Handler,
    };

    pub fn init(allocator: Allocator) !Mux {
        return .{
            .allocator = allocator,
            .trie = try trie_mod.Trie(Entry).init(allocator),
            .fn_handlers = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Mux) void {
        for (self.fn_handlers.items) |fh| {
            self.allocator.destroy(fh);
        }
        self.fn_handlers.deinit(self.allocator);
        self.trie.deinit();
    }

    /// Register a Handler for a topic pattern (supports + and # wildcards).
    pub fn handle(self: *Mux, pattern: []const u8, h: Handler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.trie.insert(pattern, .{ .handler = h });
    }

    /// Register a function handler (convenience).
    pub fn handleFn(self: *Mux, pattern: []const u8, f: HandlerFnType) !void {
        const fh = try self.allocator.create(FnHandler);
        errdefer self.allocator.destroy(fh);
        fh.* = .{ .func = f };
        try self.fn_handlers.append(self.allocator, fh);

        const h = Handler{
            .ptr = @ptrCast(fh),
            .vtable = &.{
                .handleMessage = struct {
                    fn call(ptr: *anyopaque, client_id: []const u8, msg: *const packet.Message) anyerror!void {
                        const fh_ptr: *const FnHandler = @ptrCast(@alignCast(ptr));
                        return fh_ptr.func(client_id, msg);
                    }
                }.call,
            },
        };
        try self.handle(pattern, h);
    }

    /// Dispatch a message to ALL matching handlers (supports overlapping patterns).
    /// Holds mutex during dispatch to prevent trie mutation invalidating slices.
    pub fn handleMessage(self: *Mux, client_id: []const u8, msg: *const packet.Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var entries_buf: [64]Entry = undefined;
        const count = self.trie.matchAll(msg.topic, &entries_buf);
        for (entries_buf[0..count]) |entry| {
            try entry.handler.handleMessage(client_id, msg);
        }
    }

    /// Return self as a Handler (for passing to Broker, composing muxes).
    pub fn handler(self: *Mux) Handler {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .handleMessage = struct {
                    fn call(ptr: *anyopaque, client_id: []const u8, msg: *const packet.Message) anyerror!void {
                        const mux: *Mux = @ptrCast(@alignCast(ptr));
                        return mux.handleMessage(client_id, msg);
                    }
                }.call,
            },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Mux basic dispatch" {
    const callback = struct {
        fn handle(_: []const u8, _: *const packet.Message) anyerror!void {}
    }.handle;

    var mux = try Mux.init(std.testing.allocator);
    defer mux.deinit();

    try mux.handleFn("test/+", callback);

    const msg = packet.Message{ .topic = "test/hello", .payload = "world" };
    try mux.handleMessage("client-1", &msg);
}

test "Mux wildcard routing" {
    const callback = struct {
        fn handle(_: []const u8, _: *const packet.Message) anyerror!void {}
    }.handle;

    var mux = try Mux.init(std.testing.allocator);
    defer mux.deinit();

    try mux.handleFn("device/+/state", callback);
    try mux.handleFn("device/#", callback);

    const msg1 = packet.Message{ .topic = "device/001/state", .payload = "" };
    try mux.handleMessage("c1", &msg1);

    const msg2 = packet.Message{ .topic = "device/001/cmd", .payload = "" };
    try mux.handleMessage("c1", &msg2);
}

test "Mux as Handler" {
    var mux = try Mux.init(std.testing.allocator);
    defer mux.deinit();

    const h = mux.handler();
    const msg = packet.Message{ .topic = "test", .payload = "" };
    try h.handleMessage("", &msg);
}
