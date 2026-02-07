//! Mux — Topic-based message routing (like http.ServeMux)
//!
//! Two variants:
//! - Comptime Mux: routes known at compile time, zero runtime allocation
//! - Runtime Mux: routes registered at runtime, fixed-capacity pool
//!
//! ## Comptime Mux (recommended for clients)
//!
//! ```zig
//! const MyMux = mqtt0.mux.comptimeMux(.{
//!     .{ "sensor/+/data", handleSensor },
//!     .{ "device/#", handleDevice },
//! });
//!
//! client.onMessage(MyMux.handler());
//! ```
//!
//! ## Runtime Mux (for dynamic routing, brokers)
//!
//! ```zig
//! var rt_mux = mqtt0.mux.RuntimeMux(16).init();
//! try rt_mux.handle("sensor/#", myHandler);
//!
//! client.onMessage(rt_mux.handler());
//! ```

const pkt = @import("packet.zig");
const trie_mod = @import("trie.zig");

const Message = pkt.Message;
const Handler = pkt.Handler;
const topicMatches = trie_mod.topicMatches;

// ============================================================================
// Comptime Mux
// ============================================================================

/// Route entry for comptime mux
pub const Route = struct {
    pattern: []const u8,
    handler_fn: *const fn (*const Message) void,
};

/// Create a comptime mux from a list of routes.
/// All patterns are stored in .rodata. Dispatch is a comptime-unrolled loop.
///
/// Usage:
///   const MyMux = comptimeMux(.{
///       .{ "sensor/+/data", handleSensor },
///       .{ "device/#", handleDevice },
///   });
///   const h = MyMux.handler();
pub fn comptimeMux(comptime route_tuples: anytype) type {
    const routes = comptime blk: {
        var result: [route_tuples.len]Route = undefined;
        for (route_tuples, 0..) |tuple, i| {
            result[i] = .{
                .pattern = tuple[0],
                .handler_fn = tuple[1],
            };
        }
        break :blk result;
    };

    return struct {
        /// Returns a Handler that dispatches to the comptime-defined routes
        pub fn handler() Handler {
            return .{
                .ctx = null,
                .handleFn = dispatch,
            };
        }

        fn dispatch(_: ?*anyopaque, msg: *const Message) void {
            inline for (routes) |route| {
                if (topicMatches(route.pattern, msg.topic)) {
                    route.handler_fn(msg);
                }
            }
        }
    };
}

// ============================================================================
// Runtime Mux
// ============================================================================

/// Runtime topic→handler router with fixed capacity.
///
/// Usage:
///   var mux = RuntimeMux(16).init();
///   try mux.handle("sensor/#", myHandler);
///   const h = mux.handler();
pub fn RuntimeMux(comptime max_routes: usize) type {
    return struct {
        const Self = @This();
        const max_pattern_len = 256;

        const RouteEntry = struct {
            pattern_buf: [max_pattern_len]u8 = undefined,
            pattern_len: u16 = 0,
            route_handler: Handler = undefined,
            active: bool = false,

            fn pattern(self: *const RouteEntry) []const u8 {
                return self.pattern_buf[0..self.pattern_len];
            }
        };

        routes: [max_routes]RouteEntry = [_]RouteEntry{.{}} ** max_routes,
        count: u16 = 0,

        pub fn init() Self {
            return .{};
        }

        /// Register a handler for a topic pattern.
        /// Supports MQTT wildcards: + (single level), # (multi level).
        pub fn handle(self: *Self, pattern: []const u8, h: Handler) !void {
            if (self.count >= max_routes) return error.TooManyRoutes;
            if (pattern.len > max_pattern_len) return error.PatternTooLong;

            const idx = self.count;
            self.routes[idx].active = true;
            self.routes[idx].route_handler = h;
            self.routes[idx].pattern_len = @intCast(pattern.len);
            for (pattern, 0..) |b, i| {
                self.routes[idx].pattern_buf[i] = b;
            }
            self.count += 1;
        }

        /// Register a simple function as a handler (convenience).
        pub fn handleFunc(self: *Self, pattern: []const u8, comptime f: *const fn (*const Message) void) !void {
            try self.handle(pattern, pkt.handlerFn(f));
        }

        /// Returns a Handler that dispatches to all matching routes.
        pub fn handler(self: *Self) Handler {
            return .{
                .ctx = @ptrCast(self),
                .handleFn = dispatchRuntime,
            };
        }

        fn dispatchRuntime(ctx: ?*anyopaque, msg: *const Message) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.routes[0..self.count]) |*route| {
                if (route.active and topicMatches(route.pattern(), msg.topic)) {
                    route.route_handler.handle(msg);
                }
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

// Test helpers
var test_call_count: u32 = 0;
var test_last_topic: [256]u8 = undefined;
var test_last_topic_len: usize = 0;

fn resetTestState() void {
    test_call_count = 0;
    test_last_topic_len = 0;
}

fn testHandler1(msg: *const Message) void {
    test_call_count += 1;
    const len = @min(msg.topic.len, 256);
    for (msg.topic[0..len], 0..) |b, i| {
        test_last_topic[i] = b;
    }
    test_last_topic_len = len;
}

fn testHandler2(msg: *const Message) void {
    _ = msg;
    test_call_count += 10; // Different increment to distinguish
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

test "comptimeMux: basic dispatch" {
    resetTestState();

    const MyMux = comptimeMux(.{
        .{ "sensor/+/data", testHandler1 },
    });

    const h = MyMux.handler();
    const msg = Message{ .topic = "sensor/1/data", .payload = "hello", .retain = false };
    h.handle(&msg);

    if (test_call_count != 1) return error.TestExpectedEqual;
    if (!eql(test_last_topic[0..test_last_topic_len], "sensor/1/data")) return error.TestExpectedEqual;
}

test "comptimeMux: no match" {
    resetTestState();

    const MyMux = comptimeMux(.{
        .{ "sensor/+/data", testHandler1 },
    });

    const h = MyMux.handler();
    const msg = Message{ .topic = "other/topic", .payload = "", .retain = false };
    h.handle(&msg);

    if (test_call_count != 0) return error.TestExpectedEqual;
}

test "comptimeMux: multiple matches" {
    resetTestState();

    const MyMux = comptimeMux(.{
        .{ "sensor/+/data", testHandler1 },
        .{ "sensor/#", testHandler2 },
    });

    const h = MyMux.handler();
    const msg = Message{ .topic = "sensor/1/data", .payload = "", .retain = false };
    h.handle(&msg);

    // Both handlers should fire: 1 + 10 = 11
    if (test_call_count != 11) return error.TestExpectedEqual;
}

test "RuntimeMux: basic dispatch" {
    resetTestState();

    var mux = RuntimeMux(8).init();
    try mux.handleFunc("sensor/+/data", testHandler1);

    const h = mux.handler();
    const msg = Message{ .topic = "sensor/1/data", .payload = "test", .retain = false };
    h.handle(&msg);

    if (test_call_count != 1) return error.TestExpectedEqual;
}

test "RuntimeMux: multiple routes" {
    resetTestState();

    var mux = RuntimeMux(8).init();
    try mux.handleFunc("sensor/+/data", testHandler1);
    try mux.handleFunc("sensor/#", testHandler2);

    const h = mux.handler();
    const msg = Message{ .topic = "sensor/temp/data", .payload = "", .retain = false };
    h.handle(&msg);

    // Both should match: 1 + 10 = 11
    if (test_call_count != 11) return error.TestExpectedEqual;
}

test "RuntimeMux: no match" {
    resetTestState();

    var mux = RuntimeMux(8).init();
    try mux.handleFunc("sensor/#", testHandler1);

    const h = mux.handler();
    const msg = Message{ .topic = "device/status", .payload = "", .retain = false };
    h.handle(&msg);

    if (test_call_count != 0) return error.TestExpectedEqual;
}

test "RuntimeMux: capacity limit" {
    var mux = RuntimeMux(2).init();
    try mux.handleFunc("a", testHandler1);
    try mux.handleFunc("b", testHandler1);

    // Third should fail
    const result = mux.handleFunc("c", testHandler1);
    if (result) |_| {
        return error.TestExpectedEqual; // Should have errored
    } else |_| {
        // Expected error
    }
}
