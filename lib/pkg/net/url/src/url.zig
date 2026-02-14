//! URL Parser — Zero-allocation URL parsing for freestanding environments.
//!
//! Parses URLs following RFC 3986 structure:
//!
//!   [scheme:][//[userinfo@]host[:port]][/path][?query][#fragment]
//!
//! All string fields are slices into the original input — zero heap allocation.
//! Port is parsed into a `u16` for convenience.
//!
//! Example:
//!
//!   const url = @import("url");
//!
//!   const u = try url.parse("mqtts://user:pass@example.com:8883/topic?qos=1#ref");
//!   u.scheme     // "mqtts"
//!   u.username   // "user"
//!   u.password   // "pass"
//!   u.host       // "example.com"
//!   u.port       // 8883
//!   u.path       // "/topic"
//!   u.raw_query  // "qos=1"
//!   u.fragment   // "ref"

/// Errors that can occur during URL parsing.
pub const ParseError = error{
    /// Port number is not a valid integer or exceeds 0–65535.
    InvalidPort,
    /// Host component is malformed (e.g., unclosed IPv6 bracket).
    InvalidHost,
};

/// A parsed URL. All slice fields point into the original input string.
pub const Url = struct {
    /// The original, unparsed URL string.
    raw: []const u8,

    /// URI scheme (e.g., "http", "mqtts", "ftp"). Lowercase by convention.
    scheme: ?[]const u8 = null,

    /// Username from the userinfo component.
    username: ?[]const u8 = null,

    /// Password from the userinfo component.
    password: ?[]const u8 = null,

    /// Host (domain or IP). IPv6 addresses include the brackets (e.g., "[::1]").
    host: ?[]const u8 = null,

    /// Port number, parsed as u16.
    port: ?u16 = null,

    /// Path component (includes the leading '/').
    /// Empty string if no path is present.
    path: []const u8 = "",

    /// Raw query string (after '?' and before '#'), without the leading '?'.
    raw_query: ?[]const u8 = null,

    /// Fragment (after '#'), without the leading '#'.
    fragment: ?[]const u8 = null,

    /// Returns the port, or the given default if no port was specified.
    ///
    /// Example:
    ///   const u = try url.parse("http://example.com/path");
    ///   u.portOrDefault(80) // 80
    pub fn portOrDefault(self: Url, default: u16) u16 {
        return self.port orelse default;
    }

    /// Returns the hostname without IPv6 brackets.
    ///
    /// For regular hosts, returns the host as-is.
    /// For IPv6 hosts like "[::1]", returns "::1".
    pub fn hostname(self: Url) ?[]const u8 {
        const h = self.host orelse return null;
        if (h.len >= 2 and h[0] == '[' and h[h.len - 1] == ']') {
            return h[1 .. h.len - 1];
        }
        return h;
    }

    /// Returns an iterator over query parameters (key=value pairs separated by '&').
    pub fn queryIterator(self: Url) QueryIterator {
        return .{ .raw = self.raw_query orelse "" };
    }
};

/// Iterator over query string parameters.
///
/// Splits on '&' and yields key/value pairs split on the first '='.
/// Empty segments between '&' delimiters are skipped.
///
/// Example:
///   const u = try url.parse("http://h/p?a=1&b=2&flag");
///   var it = u.queryIterator();
///   it.next() // .{ .key = "a", .value = "1" }
///   it.next() // .{ .key = "b", .value = "2" }
///   it.next() // .{ .key = "flag", .value = null }
///   it.next() // null
pub const QueryIterator = struct {
    raw: []const u8,
    pos: usize = 0,

    pub const Entry = struct {
        key: []const u8,
        value: ?[]const u8 = null,
    };

    /// Returns the next query parameter, or null when exhausted.
    pub fn next(self: *QueryIterator) ?Entry {
        while (self.pos < self.raw.len) {
            const rest = self.raw[self.pos..];

            // Find end of this parameter ('&' or end of string)
            const param_end = indexOf(rest, '&') orelse rest.len;
            const param = rest[0..param_end];

            // Advance past this segment (and the '&')
            self.pos += param_end;
            if (self.pos < self.raw.len) self.pos += 1; // skip '&'

            // Skip empty segments (e.g., "a=1&&b=2")
            if (param.len == 0) continue;

            // Split on first '='
            if (indexOf(param, '=')) |eq| {
                return .{
                    .key = param[0..eq],
                    .value = param[eq + 1 ..],
                };
            }
            return .{ .key = param };
        }
        return null;
    }

    /// Reset the iterator to the beginning.
    pub fn reset(self: *QueryIterator) void {
        self.pos = 0;
    }
};

/// Parse a URL string into its components.
///
/// Supports the general URI syntax (RFC 3986):
///   [scheme:][//[userinfo@]host[:port]][/path][?query][#fragment]
///
/// All string fields are slices into the input — zero heap allocation.
pub fn parse(raw: []const u8) ParseError!Url {
    var result = Url{ .raw = raw };
    var rest = raw;

    // 1. Extract fragment (after '#')
    if (indexOf(rest, '#')) |i| {
        result.fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }

    // 2. Extract query (after '?')
    if (indexOf(rest, '?')) |i| {
        result.raw_query = rest[i + 1 ..];
        rest = rest[0..i];
    }

    // 3. Extract scheme
    if (getSchemeEnd(rest)) |scheme_end| {
        result.scheme = rest[0..scheme_end];
        rest = rest[scheme_end + 1 ..]; // skip ':'
    }

    // 4. Parse authority if present (starts with "//")
    if (rest.len >= 2 and rest[0] == '/' and rest[1] == '/') {
        rest = rest[2..]; // skip "//"

        // Authority ends at the first '/'
        const auth_end = indexOf(rest, '/') orelse rest.len;
        const authority = rest[0..auth_end];
        result.path = rest[auth_end..];

        try parseAuthority(&result, authority);
    } else {
        // No authority — rest is path (or opaque data for non-hierarchical URIs)
        result.path = rest;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Find the end of the scheme component.
/// Returns the index of ':' if a valid scheme precedes it, null otherwise.
///
/// RFC 3986 §3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
fn getSchemeEnd(s: []const u8) ?usize {
    if (s.len == 0) return null;

    // First character must be alphabetic
    if (!isAlpha(s[0])) return null;

    for (s, 0..) |c, i| {
        if (c == ':') return i;
        if (i == 0) continue; // already checked s[0]
        if (!isAlpha(c) and !isDigit(c) and c != '+' and c != '-' and c != '.') {
            return null;
        }
    }
    return null; // no ':' found
}

/// Parse the authority component: [userinfo@]host[:port]
fn parseAuthority(result: *Url, authority: []const u8) ParseError!void {
    if (authority.len == 0) return;

    var host_part = authority;

    // Extract userinfo (before last '@')
    // Using last '@' handles edge cases like "user@name:pass@host"
    if (lastIndexOf(authority, '@')) |at| {
        const userinfo = authority[0..at];
        host_part = authority[at + 1 ..];

        // Split userinfo on first ':'
        if (indexOf(userinfo, ':')) |colon| {
            result.username = userinfo[0..colon];
            result.password = userinfo[colon + 1 ..];
        } else {
            result.username = userinfo;
        }
    }

    if (host_part.len == 0) return;

    // IPv6: [host]:port
    if (host_part[0] == '[') {
        const bracket = indexOf(host_part, ']') orelse return error.InvalidHost;
        result.host = host_part[0 .. bracket + 1]; // include brackets

        const after = host_part[bracket + 1 ..];
        if (after.len == 0) return;
        if (after[0] != ':') return error.InvalidHost;
        result.port = parsePort(after[1..]) orelse return error.InvalidPort;
    } else {
        // Regular host — split on last ':' for port
        if (lastIndexOf(host_part, ':')) |colon| {
            // Only treat as port if there's something after ':'
            const port_str = host_part[colon + 1 ..];
            if (port_str.len > 0) {
                result.port = parsePort(port_str) orelse return error.InvalidPort;
                result.host = host_part[0..colon];
            } else {
                // Trailing colon, no port (e.g., "host:")
                result.host = host_part[0..colon];
            }
        } else {
            result.host = host_part;
        }
    }
}

/// Parse a decimal port string as u16. Returns null on invalid input.
fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var acc: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        acc = acc * 10 + (c - '0');
        if (acc > 65535) return null;
    }
    return @intCast(acc);
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn indexOf(s: []const u8, needle: u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

fn lastIndexOf(s: []const u8, needle: u8) ?usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == needle) return i;
    }
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = @import("std").testing;

test "full URL with all components" {
    const u = try parse("mqtts://user:pass@example.com:8883/topic?qos=1#ref");
    try testing.expectEqualStrings("mqtts", u.scheme.?);
    try testing.expectEqualStrings("user", u.username.?);
    try testing.expectEqualStrings("pass", u.password.?);
    try testing.expectEqualStrings("example.com", u.host.?);
    try testing.expectEqual(@as(u16, 8883), u.port.?);
    try testing.expectEqualStrings("/topic", u.path);
    try testing.expectEqualStrings("qos=1", u.raw_query.?);
    try testing.expectEqualStrings("ref", u.fragment.?);
}

test "HTTP URL without userinfo" {
    const u = try parse("https://www.example.com:443/path/to/resource?key=value");
    try testing.expectEqualStrings("https", u.scheme.?);
    try testing.expect(u.username == null);
    try testing.expect(u.password == null);
    try testing.expectEqualStrings("www.example.com", u.host.?);
    try testing.expectEqual(@as(u16, 443), u.port.?);
    try testing.expectEqualStrings("/path/to/resource", u.path);
    try testing.expectEqualStrings("key=value", u.raw_query.?);
    try testing.expect(u.fragment == null);
}

test "URL without port" {
    const u = try parse("http://example.com/path");
    try testing.expectEqualStrings("http", u.scheme.?);
    try testing.expectEqualStrings("example.com", u.host.?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("/path", u.path);
    try testing.expectEqual(@as(u16, 80), u.portOrDefault(80));
}

test "URL without path" {
    const u = try parse("http://example.com");
    try testing.expectEqualStrings("http", u.scheme.?);
    try testing.expectEqualStrings("example.com", u.host.?);
    try testing.expectEqualStrings("", u.path);
}

test "URL with only scheme and host" {
    const u = try parse("mqtt://broker.local");
    try testing.expectEqualStrings("mqtt", u.scheme.?);
    try testing.expectEqualStrings("broker.local", u.host.?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("", u.path);
}

test "username without password" {
    const u = try parse("ftp://admin@files.example.com/pub");
    try testing.expectEqualStrings("ftp", u.scheme.?);
    try testing.expectEqualStrings("admin", u.username.?);
    try testing.expect(u.password == null);
    try testing.expectEqualStrings("files.example.com", u.host.?);
    try testing.expectEqualStrings("/pub", u.path);
}

test "empty password" {
    const u = try parse("ftp://admin:@files.example.com/pub");
    try testing.expectEqualStrings("admin", u.username.?);
    try testing.expectEqualStrings("", u.password.?);
}

test "IPv6 host without port" {
    const u = try parse("http://[::1]/path");
    try testing.expectEqualStrings("[::1]", u.host.?);
    try testing.expectEqualStrings("::1", u.hostname().?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("/path", u.path);
}

test "IPv6 host with port" {
    const u = try parse("http://[2001:db8::1]:8080/path");
    try testing.expectEqualStrings("[2001:db8::1]", u.host.?);
    try testing.expectEqualStrings("2001:db8::1", u.hostname().?);
    try testing.expectEqual(@as(u16, 8080), u.port.?);
    try testing.expectEqualStrings("/path", u.path);
}

test "IPv6 unclosed bracket" {
    try testing.expectError(error.InvalidHost, parse("http://[::1/path"));
}

test "IPv6 junk after bracket" {
    try testing.expectError(error.InvalidHost, parse("http://[::1]x/path"));
}

test "file URI with empty authority" {
    const u = try parse("file:///etc/hosts");
    try testing.expectEqualStrings("file", u.scheme.?);
    try testing.expect(u.host == null);
    try testing.expectEqualStrings("/etc/hosts", u.path);
}

test "relative reference (no scheme)" {
    const u = try parse("/path/to/resource?q=1#frag");
    try testing.expect(u.scheme == null);
    try testing.expect(u.host == null);
    try testing.expectEqualStrings("/path/to/resource", u.path);
    try testing.expectEqualStrings("q=1", u.raw_query.?);
    try testing.expectEqualStrings("frag", u.fragment.?);
}

test "empty string" {
    const u = try parse("");
    try testing.expect(u.scheme == null);
    try testing.expect(u.host == null);
    try testing.expectEqualStrings("", u.path);
    try testing.expect(u.raw_query == null);
    try testing.expect(u.fragment == null);
}

test "fragment only" {
    const u = try parse("#section");
    try testing.expect(u.scheme == null);
    try testing.expectEqualStrings("section", u.fragment.?);
    try testing.expectEqualStrings("", u.path);
}

test "query only" {
    const u = try parse("?key=value");
    try testing.expect(u.scheme == null);
    try testing.expectEqualStrings("key=value", u.raw_query.?);
    try testing.expectEqualStrings("", u.path);
}

test "opaque URI (mailto)" {
    const u = try parse("mailto:user@example.com");
    try testing.expectEqualStrings("mailto", u.scheme.?);
    // No authority (no "//"), so "user@example.com" is the path
    try testing.expectEqualStrings("user@example.com", u.path);
    try testing.expect(u.host == null);
}

test "scheme with digits and special chars" {
    const u = try parse("coap+tcp://sensor.local:5683/temp");
    try testing.expectEqualStrings("coap+tcp", u.scheme.?);
    try testing.expectEqualStrings("sensor.local", u.host.?);
    try testing.expectEqual(@as(u16, 5683), u.port.?);
}

test "invalid port: non-numeric" {
    try testing.expectError(error.InvalidPort, parse("http://host:abc/path"));
}

test "invalid port: exceeds u16" {
    try testing.expectError(error.InvalidPort, parse("http://host:99999/path"));
}

test "trailing colon, no port" {
    const u = try parse("http://host:/path");
    try testing.expectEqualStrings("host", u.host.?);
    try testing.expect(u.port == null);
    try testing.expectEqualStrings("/path", u.path);
}

test "port boundary: 0" {
    const u = try parse("http://host:0/path");
    try testing.expectEqual(@as(u16, 0), u.port.?);
}

test "port boundary: 65535" {
    const u = try parse("http://host:65535/path");
    try testing.expectEqual(@as(u16, 65535), u.port.?);
}

test "port boundary: 65536 overflows" {
    try testing.expectError(error.InvalidPort, parse("http://host:65536/path"));
}

test "query with multiple params" {
    const u = try parse("http://h/p?a=1&b=2&c=3");
    try testing.expectEqualStrings("a=1&b=2&c=3", u.raw_query.?);
}

test "query iterator" {
    const u = try parse("http://h/p?a=1&b=2&flag&c=");
    var it = u.queryIterator();

    const e1 = it.next().?;
    try testing.expectEqualStrings("a", e1.key);
    try testing.expectEqualStrings("1", e1.value.?);

    const e2 = it.next().?;
    try testing.expectEqualStrings("b", e2.key);
    try testing.expectEqualStrings("2", e2.value.?);

    const e3 = it.next().?;
    try testing.expectEqualStrings("flag", e3.key);
    try testing.expect(e3.value == null);

    const e4 = it.next().?;
    try testing.expectEqualStrings("c", e4.key);
    try testing.expectEqualStrings("", e4.value.?);

    try testing.expect(it.next() == null);
}

test "query iterator: empty segments" {
    const u = try parse("http://h/p?a=1&&b=2");
    var it = u.queryIterator();

    const e1 = it.next().?;
    try testing.expectEqualStrings("a", e1.key);

    const e2 = it.next().?;
    try testing.expectEqualStrings("b", e2.key);

    try testing.expect(it.next() == null);
}

test "query iterator: reset" {
    const u = try parse("http://h/p?x=1");
    var it = u.queryIterator();
    _ = it.next();
    try testing.expect(it.next() == null);

    it.reset();
    const e = it.next().?;
    try testing.expectEqualStrings("x", e.key);
}

test "query iterator: no query" {
    const u = try parse("http://h/p");
    var it = u.queryIterator();
    try testing.expect(it.next() == null);
}

test "hostname: regular host" {
    const u = try parse("http://example.com/");
    try testing.expectEqualStrings("example.com", u.hostname().?);
}

test "hostname: no host" {
    const u = try parse("/path");
    try testing.expect(u.hostname() == null);
}

test "portOrDefault: port present" {
    const u = try parse("http://h:9090/");
    try testing.expectEqual(@as(u16, 9090), u.portOrDefault(80));
}

test "portOrDefault: port absent" {
    const u = try parse("http://h/");
    try testing.expectEqual(@as(u16, 80), u.portOrDefault(80));
}

test "raw field preserves original input" {
    const input = "http://example.com/path?q=1#f";
    const u = try parse(input);
    try testing.expectEqualStrings(input, u.raw);
}

test "query and fragment interaction" {
    // '?' in fragment should not be treated as query delimiter
    const u = try parse("http://h/p?q=1#frag?ment");
    try testing.expectEqualStrings("q=1", u.raw_query.?);
    try testing.expectEqualStrings("frag?ment", u.fragment.?);
}

test "fragment with '#' characters" {
    // Only the first '#' splits; rest is part of fragment
    const u = try parse("http://h/p#a#b#c");
    try testing.expectEqualStrings("a#b#c", u.fragment.?);
}

test "MQTT URL (primary use case)" {
    const u = try parse("mqtt://device:secret@broker.haivivi.com:1883");
    try testing.expectEqualStrings("mqtt", u.scheme.?);
    try testing.expectEqualStrings("device", u.username.?);
    try testing.expectEqualStrings("secret", u.password.?);
    try testing.expectEqualStrings("broker.haivivi.com", u.host.?);
    try testing.expectEqual(@as(u16, 1883), u.port.?);
    try testing.expectEqualStrings("", u.path);
}

test "MQTTS URL" {
    const u = try parse("mqtts://broker.haivivi.com:8883/telemetry");
    try testing.expectEqualStrings("mqtts", u.scheme.?);
    try testing.expectEqualStrings("broker.haivivi.com", u.host.?);
    try testing.expectEqual(@as(u16, 8883), u.port.?);
    try testing.expectEqualStrings("/telemetry", u.path);
}

test "WebSocket URL" {
    const u = try parse("wss://stream.example.com/v1/events?token=abc");
    try testing.expectEqualStrings("wss", u.scheme.?);
    try testing.expectEqualStrings("stream.example.com", u.host.?);
    try testing.expectEqualStrings("/v1/events", u.path);
    try testing.expectEqualStrings("token=abc", u.raw_query.?);
}
