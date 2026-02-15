//! DNS Domain Resolver Interface Definition
//!
//! Provides compile-time validation for custom domain resolution.
//! Used by DNS Resolver to intercept specific domains before querying upstream DNS.
//!
//! Use case: zgrnet intercepts `*.zigor.net` domains and returns FakeIP,
//! while other domains fall through to standard UDP/TCP/DoH resolution.
//!
//! Usage:
//! ```zig
//! const MyResolver = struct {
//!     peer_list: *PeerList,
//!
//!     pub fn resolve(self: *const @This(), host: []const u8) ?[4]u8 {
//!         if (self.peer_list.lookup(host)) |peer| return peer.fake_ip;
//!         return null; // not recognized, fallback to upstream DNS
//!     }
//! };
//!
//! // In DNS resolver: custom resolver is consulted first
//! const Resolver = dns.Resolver(Socket, MyResolver);
//! var resolver = Resolver{ .custom_resolver = &my_resolver, ... };
//!
//! // Backward compatible: pass void to disable custom resolution
//! const Resolver = dns.Resolver(Socket, void);
//! ```

const std = @import("std");

/// Validate and return DomainResolver type.
///
/// - `void`: no custom resolution (backward compatible, zero overhead)
/// - Any struct with `resolve(*const Self, []const u8) ?[4]u8`: custom resolver
pub fn from(comptime Impl: type) type {
    if (Impl == void) return void;

    comptime {
        if (!@hasDecl(Impl, "resolve")) {
            @compileError("DomainResolver must have fn resolve(*const @This(), []const u8) ?[4]u8");
        }
        const resolve_fn = @typeInfo(@TypeOf(Impl.resolve)).@"fn";
        if (resolve_fn.params.len != 2) {
            @compileError("DomainResolver.resolve must take (self, host) — 2 parameters");
        }
        // Validate return type is ?[4]u8
        if (resolve_fn.return_type) |ret| {
            if (ret != ?[4]u8) {
                @compileError("DomainResolver.resolve must return ?[4]u8");
            }
        }
    }
    return Impl;
}

/// Check if type implements DomainResolver interface
pub fn is(comptime T: type) bool {
    if (T == void) return true;
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "resolve")) return false;
    const resolve_info = @typeInfo(@TypeOf(T.resolve));
    if (resolve_info != .@"fn") return false;
    const params = resolve_info.@"fn".params;
    if (params.len != 2) return false;
    if (resolve_info.@"fn".return_type) |ret| {
        if (ret != ?[4]u8) return false;
    } else return false;
    return true;
}

// =========== Tests ===========

test "void is valid (backward compatible)" {
    try std.testing.expect(is(void));
    const V = from(void);
    try std.testing.expect(V == void);
}

test "valid DomainResolver" {
    const MockResolver = struct {
        prefix: []const u8,

        pub fn resolve(self: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.endsWith(u8, host, self.prefix)) {
                return .{ 10, 0, 0, 1 };
            }
            return null;
        }
    };

    try std.testing.expect(is(MockResolver));
    const Validated = from(MockResolver);
    try std.testing.expect(Validated == MockResolver);

    // Functional test
    const resolver = MockResolver{ .prefix = ".zigor.net" };
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 0, 1 }), resolver.resolve("abc.host.zigor.net"));
    try std.testing.expectEqual(@as(?[4]u8, null), resolver.resolve("www.google.com"));
}

test "is() rejects invalid types" {
    const NoResolve = struct {
        pub fn lookup(_: *const @This(), _: []const u8) ?[4]u8 {
            return null;
        }
    };
    const NotAStruct = u32;

    try std.testing.expect(!is(NoResolve));
    try std.testing.expect(!is(NotAStruct));
}
