//! TLS Extensions
//!
//! Implements TLS extension parsing and serialization.
//! Supports extensions required for TLS 1.2 and 1.3.

const std = @import("std");
const common = @import("common.zig");

const ExtensionType = common.ExtensionType;
const NamedGroup = common.NamedGroup;
const SignatureScheme = common.SignatureScheme;
const ProtocolVersion = common.ProtocolVersion;
const CipherSuite = common.CipherSuite;
const PskKeyExchangeMode = common.PskKeyExchangeMode;

// ============================================================================
// Extension Errors
// ============================================================================

pub const ExtensionError = error{
    BufferTooSmall,
    InvalidExtension,
    ExtensionTooLarge,
    MissingRequiredExtension,
    DuplicateExtension,
    UnsupportedExtension,
};

// ============================================================================
// Extension Builder
// ============================================================================

/// Helper for building TLS extensions
pub const ExtensionBuilder = struct {
    buffer: []u8,
    pos: usize,

    pub fn init(buffer: []u8) ExtensionBuilder {
        return ExtensionBuilder{
            .buffer = buffer,
            .pos = 0,
        };
    }

    /// Add a raw extension
    pub fn addExtension(self: *ExtensionBuilder, ext_type: ExtensionType, data: []const u8) !void {
        const needed = 4 + data.len; // 2 type + 2 length + data
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ext_type), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(data.len), .big);
        self.pos += 2;
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    /// Add Server Name Indication (SNI) extension
    pub fn addServerName(self: *ExtensionBuilder, hostname: []const u8) !void {
        if (hostname.len > 255) return error.ExtensionTooLarge;

        // SNI format: list_length (2) + name_type (1) + name_length (2) + name
        const ext_len = 2 + 1 + 2 + hostname.len;
        const needed = 4 + ext_len;
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        // Extension type and length
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.server_name), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
        self.pos += 2;

        // Server name list length
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(1 + 2 + hostname.len), .big);
        self.pos += 2;

        // Name type (host_name = 0)
        self.buffer[self.pos] = 0;
        self.pos += 1;

        // Host name length and data
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(hostname.len), .big);
        self.pos += 2;
        @memcpy(self.buffer[self.pos..][0..hostname.len], hostname);
        self.pos += hostname.len;
    }

    /// Add Supported Versions extension
    pub fn addSupportedVersions(self: *ExtensionBuilder, versions: []const ProtocolVersion) !void {
        const list_len = versions.len * 2;
        const ext_len = 1 + list_len;
        const needed = 4 + ext_len;
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.supported_versions), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
        self.pos += 2;

        self.buffer[self.pos] = @intCast(list_len);
        self.pos += 1;

        for (versions) |v| {
            std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(v), .big);
            self.pos += 2;
        }
    }

    /// Add EC Point Formats extension (required for TLS 1.2 ECDHE)
    pub fn addEcPointFormats(self: *ExtensionBuilder) !void {
        // Only uncompressed (0) is required
        const needed = 4 + 2; // type(2) + length(2) + formats_length(1) + format(1)
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.ec_point_formats), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], 2, .big); // extension length
        self.pos += 2;
        self.buffer[self.pos] = 1; // formats length
        self.pos += 1;
        self.buffer[self.pos] = 0; // uncompressed
        self.pos += 1;
    }

    /// Add Supported Groups extension
    pub fn addSupportedGroups(self: *ExtensionBuilder, groups: []const NamedGroup) !void {
        const list_len = groups.len * 2;
        const ext_len = 2 + list_len;
        const needed = 4 + ext_len;
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.supported_groups), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
        self.pos += 2;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
        self.pos += 2;

        for (groups) |g| {
            std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(g), .big);
            self.pos += 2;
        }
    }

    /// Add Signature Algorithms extension
    pub fn addSignatureAlgorithms(self: *ExtensionBuilder, algorithms: []const SignatureScheme) !void {
        const list_len = algorithms.len * 2;
        const ext_len = 2 + list_len;
        const needed = 4 + ext_len;
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.signature_algorithms), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
        self.pos += 2;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
        self.pos += 2;

        for (algorithms) |a| {
            std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(a), .big);
            self.pos += 2;
        }
    }

    /// Add Key Share extension (client)
    pub fn addKeyShareClient(self: *ExtensionBuilder, entries: []const KeyShareEntry) !void {
        // Calculate total size
        var list_len: usize = 0;
        for (entries) |e| {
            list_len += 4 + e.key_exchange.len; // 2 group + 2 length + data
        }

        const ext_len = 2 + list_len;
        const needed = 4 + ext_len;
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.key_share), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
        self.pos += 2;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
        self.pos += 2;

        for (entries) |e| {
            std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(e.group), .big);
            self.pos += 2;
            std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(e.key_exchange.len), .big);
            self.pos += 2;
            @memcpy(self.buffer[self.pos..][0..e.key_exchange.len], e.key_exchange);
            self.pos += e.key_exchange.len;
        }
    }

    /// Add PSK Key Exchange Modes extension
    pub fn addPskKeyExchangeModes(self: *ExtensionBuilder, modes: []const PskKeyExchangeMode) !void {
        const ext_len = 1 + modes.len;
        const needed = 4 + ext_len;
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.psk_key_exchange_modes), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
        self.pos += 2;

        self.buffer[self.pos] = @intCast(modes.len);
        self.pos += 1;

        for (modes) |m| {
            self.buffer[self.pos] = @intFromEnum(m);
            self.pos += 1;
        }
    }

    /// Add ALPN extension
    pub fn addAlpn(self: *ExtensionBuilder, protocols: []const []const u8) !void {
        // Calculate list length
        var list_len: usize = 0;
        for (protocols) |p| {
            list_len += 1 + p.len;
        }

        const ext_len = 2 + list_len;
        const needed = 4 + ext_len;
        if (self.pos + needed > self.buffer.len) return error.BufferTooSmall;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intFromEnum(ExtensionType.application_layer_protocol_negotiation), .big);
        self.pos += 2;
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(ext_len), .big);
        self.pos += 2;

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], @intCast(list_len), .big);
        self.pos += 2;

        for (protocols) |p| {
            self.buffer[self.pos] = @intCast(p.len);
            self.pos += 1;
            @memcpy(self.buffer[self.pos..][0..p.len], p);
            self.pos += p.len;
        }
    }

    /// Get the built extensions data
    pub fn getData(self: *ExtensionBuilder) []const u8 {
        return self.buffer[0..self.pos];
    }
};

// ============================================================================
// Key Share Entry
// ============================================================================

pub const KeyShareEntry = struct {
    group: NamedGroup,
    key_exchange: []const u8,
};

// ============================================================================
// Extension Parser
// ============================================================================

/// Parsed extension
pub const Extension = struct {
    ext_type: ExtensionType,
    data: []const u8,
};

/// Parse extensions from a buffer
pub fn parseExtensions(data: []const u8, allocator: std.mem.Allocator) ![]Extension {
    var extensions = std.ArrayList(Extension).init(allocator);
    errdefer extensions.deinit();

    var pos: usize = 0;
    while (pos + 4 <= data.len) {
        const ext_type: ExtensionType = @enumFromInt(std.mem.readInt(u16, data[pos..][0..2], .big));
        pos += 2;
        const ext_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;

        if (pos + ext_len > data.len) return error.InvalidExtension;

        try extensions.append(.{
            .ext_type = ext_type,
            .data = data[pos..][0..ext_len],
        });
        pos += ext_len;
    }

    return extensions.toOwnedSlice();
}

/// Parse server name from SNI extension data
pub fn parseServerName(data: []const u8) !?[]const u8 {
    if (data.len < 5) return error.InvalidExtension;

    const list_len = std.mem.readInt(u16, data[0..2], .big);
    if (list_len + 2 > data.len) return error.InvalidExtension;

    var pos: usize = 2;
    while (pos < 2 + list_len) {
        const name_type = data[pos];
        pos += 1;
        const name_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;

        if (name_type == 0) { // host_name
            if (pos + name_len > data.len) return error.InvalidExtension;
            return data[pos..][0..name_len];
        }
        pos += name_len;
    }

    return null;
}

/// Parse supported version from server's supported_versions extension
pub fn parseSupportedVersion(data: []const u8) !ProtocolVersion {
    if (data.len < 2) return error.InvalidExtension;
    return @enumFromInt(std.mem.readInt(u16, data[0..2], .big));
}

/// Parse key share from server's key_share extension
pub fn parseKeyShareServer(data: []const u8) !KeyShareEntry {
    if (data.len < 4) return error.InvalidExtension;

    const group: NamedGroup = @enumFromInt(std.mem.readInt(u16, data[0..2], .big));
    const key_len = std.mem.readInt(u16, data[2..4], .big);

    if (data.len < 4 + key_len) return error.InvalidExtension;

    return KeyShareEntry{
        .group = group,
        .key_exchange = data[4..][0..key_len],
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ExtensionBuilder server name" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    try builder.addServerName("example.com");

    const data = builder.getData();
    try std.testing.expect(data.len > 0);

    // Verify extension type
    const ext_type = std.mem.readInt(u16, data[0..2], .big);
    try std.testing.expectEqual(@as(u16, 0), ext_type); // server_name = 0
}

test "ExtensionBuilder supported versions" {
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);

    const versions = [_]ProtocolVersion{ .tls_1_3, .tls_1_2 };
    try builder.addSupportedVersions(&versions);

    const data = builder.getData();
    try std.testing.expect(data.len > 0);
}

test "parseServerName" {
    // Build an SNI extension
    var buf: [256]u8 = undefined;
    var builder = ExtensionBuilder.init(&buf);
    try builder.addServerName("test.example.com");

    // Parse it (skip the extension header)
    const ext_data = builder.getData()[4..]; // Skip type and length
    const hostname = try parseServerName(ext_data);
    try std.testing.expectEqualStrings("test.example.com", hostname.?);
}
