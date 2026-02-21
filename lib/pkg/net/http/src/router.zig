const std = @import("std");
const mem = std.mem;
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const Request = request_mod.Request;
const Response = response_mod.Response;
const Method = request_mod.Method;

pub const Handler = *const fn (*Request, *Response) void;

pub const MatchType = enum {
    exact,
    prefix,
};

pub const Route = struct {
    method: ?Method,
    path: []const u8,
    handler: Handler,
    match_type: MatchType = .exact,
};

/// Convenience constructors for route definitions.
pub fn get(path: []const u8, handler: Handler) Route {
    return .{ .method = .GET, .path = path, .handler = handler };
}

pub fn post(path: []const u8, handler: Handler) Route {
    return .{ .method = .POST, .path = path, .handler = handler };
}

pub fn put(path: []const u8, handler: Handler) Route {
    return .{ .method = .PUT, .path = path, .handler = handler };
}

pub fn delete(path: []const u8, handler: Handler) Route {
    return .{ .method = .DELETE, .path = path, .handler = handler };
}

pub fn prefix(path: []const u8, handler: Handler) Route {
    return .{ .method = null, .path = path, .handler = handler, .match_type = .prefix };
}

pub const MatchResult = enum {
    found,
    not_found,
    method_not_allowed,
};

pub const RouteMatch = struct {
    result: MatchResult,
    handler: ?Handler = null,
};

/// Find a matching route for the given method and path.
pub fn match(routes: []const Route, method: Method, path: []const u8) RouteMatch {
    var path_matched = false;

    for (routes) |route| {
        const path_matches = switch (route.match_type) {
            .exact => mem.eql(u8, route.path, path),
            .prefix => mem.startsWith(u8, path, route.path),
        };

        if (path_matches) {
            if (route.method == null or route.method.? == method) {
                return .{ .result = .found, .handler = route.handler };
            }
            path_matched = true;
        }
    }

    if (path_matched) {
        return .{ .result = .method_not_allowed };
    }
    return .{ .result = .not_found };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn dummyHandler(_: *Request, _: *Response) void {}
fn dummyHandler2(_: *Request, _: *Response) void {}

test "exact match" {
    const routes = [_]Route{
        get("/api/status", dummyHandler),
        post("/api/data", dummyHandler2),
    };

    const m = match(&routes, .GET, "/api/status");
    try testing.expectEqual(MatchResult.found, m.result);
    try testing.expect(m.handler != null);
}

test "prefix match" {
    const routes = [_]Route{
        prefix("/static/", dummyHandler),
    };

    const m1 = match(&routes, .GET, "/static/app.js");
    try testing.expectEqual(MatchResult.found, m1.result);

    const m2 = match(&routes, .GET, "/static/css/style.css");
    try testing.expectEqual(MatchResult.found, m2.result);

    const m3 = match(&routes, .GET, "/api/other");
    try testing.expectEqual(MatchResult.not_found, m3.result);
}

test "prefix matches any method" {
    const routes = [_]Route{
        prefix("/api/", dummyHandler),
    };

    try testing.expectEqual(MatchResult.found, match(&routes, .GET, "/api/foo").result);
    try testing.expectEqual(MatchResult.found, match(&routes, .POST, "/api/foo").result);
    try testing.expectEqual(MatchResult.found, match(&routes, .PUT, "/api/foo").result);
    try testing.expectEqual(MatchResult.found, match(&routes, .DELETE, "/api/foo").result);
}

test "404 no match" {
    const routes = [_]Route{
        get("/api/status", dummyHandler),
    };

    const m = match(&routes, .GET, "/unknown");
    try testing.expectEqual(MatchResult.not_found, m.result);
    try testing.expect(m.handler == null);
}

test "method mismatch — 405" {
    const routes = [_]Route{
        get("/api/status", dummyHandler),
    };

    const m = match(&routes, .POST, "/api/status");
    try testing.expectEqual(MatchResult.method_not_allowed, m.result);
    try testing.expect(m.handler == null);
}
