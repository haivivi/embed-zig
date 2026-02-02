//! Cross-Platform NTP Client
//!
//! Simple NTP (Network Time Protocol) client using UDP.
//! Returns server timestamps for user to calculate time offset.
//!
//! Example:
//!   const ntp = @import("ntp");
//!
//!   const Client = ntp.Client(Socket);
//!   var client = Client{ .server = .{ 162, 159, 200, 1 } }; // time.cloudflare.com
//!
//!   const t1 = Board.time.getTimeMs();
//!   const resp = try client.query(@intCast(t1));
//!   const t4 = Board.time.getTimeMs();
//!
//!   // Calculate offset: ((T2 - T1) + (T3 - T4)) / 2
//!   const offset = @divFloor((resp.receive_time_ms - @as(i64, @intCast(t1))) +
//!                            (resp.transmit_time_ms - @as(i64, @intCast(t4))), 2);
//!   const current_epoch_ms = @as(i64, @intCast(t4)) + offset;

const std = @import("std");
const trait = @import("trait");

pub const Ipv4Address = [4]u8;

/// NTP port
pub const NTP_PORT: u16 = 123;

/// Seconds between NTP epoch (1900-01-01) and Unix epoch (1970-01-01)
pub const NTP_UNIX_OFFSET: i64 = 2208988800;

pub const NtpError = error{
    SocketError,
    SendFailed,
    RecvFailed,
    Timeout,
    InvalidResponse,
    KissOfDeath,
};

/// NTP query response containing server timestamps
pub const Response = struct {
    /// T2: Server receive timestamp (Unix epoch milliseconds)
    receive_time_ms: i64,
    /// T3: Server transmit timestamp (Unix epoch milliseconds)
    transmit_time_ms: i64,
    /// Server stratum (1 = primary, 2-15 = secondary)
    stratum: u8,
    /// Round-trip delay estimate in milliseconds (T4 - T1, set by caller)
    round_trip_ms: u64 = 0,
};

/// Well-known NTP servers
pub const Servers = struct {
    // Global providers
    /// time.cloudflare.com - anycast, global
    pub const cloudflare: Ipv4Address = .{ 162, 159, 200, 1 };
    /// time.google.com
    pub const google: Ipv4Address = .{ 216, 239, 35, 0 };
    /// time2.google.com
    pub const google2: Ipv4Address = .{ 216, 239, 35, 4 };
    /// time3.google.com
    pub const google3: Ipv4Address = .{ 216, 239, 35, 8 };
    /// time4.google.com
    pub const google4: Ipv4Address = .{ 216, 239, 35, 12 };
    /// time.apple.com
    pub const apple: Ipv4Address = .{ 17, 253, 34, 123 };
    /// time.windows.com
    pub const microsoft: Ipv4Address = .{ 20, 101, 57, 9 };
    /// time.nist.gov (US NIST)
    pub const nist: Ipv4Address = .{ 129, 6, 15, 28 };

    // China providers
    /// ntp.aliyun.com
    pub const aliyun: Ipv4Address = .{ 203, 107, 6, 88 };
    /// ntp.tencent.com
    pub const tencent: Ipv4Address = .{ 111, 230, 189, 174 };
    /// ntp.ntsc.ac.cn (中科院国家授时中心)
    pub const ntsc: Ipv4Address = .{ 114, 118, 7, 161 };
};

/// Preset server lists for different network environments
pub const ServerLists = struct {
    /// Global - works in most regions (recommended default)
    pub const global = [_]Ipv4Address{
        Servers.cloudflare,
        Servers.google,
        Servers.aliyun,
    };

    /// China optimized - Chinese servers first
    pub const china = [_]Ipv4Address{
        Servers.aliyun,
        Servers.tencent,
        Servers.ntsc,
        Servers.cloudflare,
    };

    /// Overseas optimized - global providers
    pub const overseas = [_]Ipv4Address{
        Servers.cloudflare,
        Servers.google,
        Servers.google2,
        Servers.apple,
    };
};

/// NTP Client - generic over socket type
pub fn Client(comptime Socket: type) type {
    const socket = trait.socket.from(Socket);

    return struct {
        const Self = @This();

        /// NTP server address
        server: Ipv4Address = Servers.cloudflare,

        /// Timeout in milliseconds
        timeout_ms: u32 = 5000,

        /// Query NTP server and return timestamps
        ///
        /// User should record local time before calling (T1) and after receiving (T4)
        /// to calculate precise time offset.
        ///
        /// Args:
        ///   t1_local_ms: Local monotonic time when starting query (for origin timestamp)
        ///
        /// Returns:
        ///   Response containing server receive (T2) and transmit (T3) timestamps
        pub fn query(self: *const Self, t1_local_ms: i64) NtpError!Response {
            var sock = socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            // Build NTP request packet
            var request: [48]u8 = undefined;
            buildRequest(&request, t1_local_ms);

            // Send request
            _ = sock.sendTo(self.server, NTP_PORT, &request) catch return error.SendFailed;

            // Receive response
            var response: [48]u8 = undefined;
            const recv_len = sock.recvFrom(&response) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.RecvFailed,
                };
            };

            if (recv_len < 48) return error.InvalidResponse;

            // Parse response
            return parseResponse(&response);
        }

        /// Simple time query - returns current Unix epoch milliseconds
        ///
        /// This is a convenience method that uses T3 (transmit time) directly.
        /// For higher precision, use query() and calculate offset manually.
        pub fn getTime(self: *const Self) NtpError!i64 {
            const resp = try self.query(0);
            return resp.transmit_time_ms;
        }

        /// Query multiple servers simultaneously, return first response
        ///
        /// Sends NTP requests to all servers at once and returns the first
        /// valid response. This is useful for devices that need to work in
        /// different network environments (e.g., China vs overseas).
        ///
        /// The fastest responding server wins - no location detection needed.
        ///
        /// Args:
        ///   t1_local_ms: Local monotonic time when starting query
        ///   servers: Array of server addresses to query
        ///
        /// Returns:
        ///   Response from the first server to reply
        pub fn queryRace(self: *const Self, t1_local_ms: i64, servers: []const Ipv4Address) NtpError!Response {
            if (servers.len == 0) return error.InvalidResponse;

            var sock = socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            // Build request packet once
            var request: [48]u8 = undefined;
            buildRequest(&request, t1_local_ms);

            // Send to all servers simultaneously
            var sent_count: usize = 0;
            for (servers) |server| {
                if (sock.sendTo(server, NTP_PORT, &request)) |_| {
                    sent_count += 1;
                } else |_| {
                    // Ignore send failures, try next server
                }
            }

            if (sent_count == 0) return error.SendFailed;

            // Wait for first valid response
            var response: [48]u8 = undefined;
            const recv_len = sock.recvFrom(&response) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.RecvFailed,
                };
            };

            if (recv_len < 48) return error.InvalidResponse;

            // Parse response
            return parseResponse(&response);
        }

        /// Simple race query - returns time using global server list
        ///
        /// Convenience method that queries multiple servers and returns
        /// the time from whichever responds first.
        pub fn getTimeRace(self: *const Self) NtpError!i64 {
            const resp = try self.queryRace(0, &ServerLists.global);
            return resp.transmit_time_ms;
        }
    };
}

/// Build NTP request packet (48 bytes)
fn buildRequest(buf: *[48]u8, origin_time_ms: i64) void {
    @memset(buf, 0);

    // LI (0) | VN (4) | Mode (3 = client)
    // LI = 0 (no warning), VN = 4 (NTPv4), Mode = 3 (client)
    buf[0] = 0b00_100_011; // 0x23

    // Stratum: 0 (unspecified)
    buf[1] = 0;

    // Poll interval: 6 (2^6 = 64 seconds)
    buf[2] = 6;

    // Precision: -20 (about 1 microsecond)
    buf[3] = 0xEC; // -20 as signed byte

    // Root delay, root dispersion, reference ID: leave as 0

    // Reference timestamp: leave as 0

    // Origin timestamp (T1): our local time converted to NTP format
    // This helps server calculate network delay
    if (origin_time_ms != 0) {
        const ntp_ts = unixMsToNtp(origin_time_ms);
        writeTimestamp(buf[24..32], ntp_ts);
    }

    // Receive timestamp: leave as 0
    // Transmit timestamp: leave as 0 (server will fill T3)
}

/// Parse NTP response packet
fn parseResponse(buf: *const [48]u8) NtpError!Response {
    // Check LI (Leap Indicator) - if 3, server is not synchronized
    const li = (buf[0] >> 6) & 0x03;
    if (li == 3) return error.InvalidResponse;

    // Check mode - should be 4 (server) or 5 (broadcast)
    const mode = buf[0] & 0x07;
    if (mode != 4 and mode != 5) return error.InvalidResponse;

    // Check stratum
    const stratum = buf[1];
    if (stratum == 0) {
        // Kiss-o'-Death packet - server is telling us to go away
        return error.KissOfDeath;
    }

    // Parse receive timestamp (T2) - bytes 32-39
    const t2_ntp = readTimestamp(buf[32..40]);
    const t2_unix_ms = ntpToUnixMs(t2_ntp);

    // Parse transmit timestamp (T3) - bytes 40-47
    const t3_ntp = readTimestamp(buf[40..48]);
    const t3_unix_ms = ntpToUnixMs(t3_ntp);

    return .{
        .receive_time_ms = t2_unix_ms,
        .transmit_time_ms = t3_unix_ms,
        .stratum = stratum,
    };
}

/// NTP timestamp (64-bit: 32-bit seconds + 32-bit fraction)
const NtpTimestamp = struct {
    seconds: u32,
    fraction: u32,
};

/// Read NTP timestamp from buffer (big-endian)
fn readTimestamp(buf: *const [8]u8) NtpTimestamp {
    return .{
        .seconds = (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) |
            (@as(u32, buf[2]) << 8) | buf[3],
        .fraction = (@as(u32, buf[4]) << 24) | (@as(u32, buf[5]) << 16) |
            (@as(u32, buf[6]) << 8) | buf[7],
    };
}

/// Write NTP timestamp to buffer (big-endian)
fn writeTimestamp(buf: *[8]u8, ts: NtpTimestamp) void {
    buf[0] = @intCast((ts.seconds >> 24) & 0xFF);
    buf[1] = @intCast((ts.seconds >> 16) & 0xFF);
    buf[2] = @intCast((ts.seconds >> 8) & 0xFF);
    buf[3] = @intCast(ts.seconds & 0xFF);
    buf[4] = @intCast((ts.fraction >> 24) & 0xFF);
    buf[5] = @intCast((ts.fraction >> 16) & 0xFF);
    buf[6] = @intCast((ts.fraction >> 8) & 0xFF);
    buf[7] = @intCast(ts.fraction & 0xFF);
}

/// Convert NTP timestamp to Unix milliseconds
fn ntpToUnixMs(ntp: NtpTimestamp) i64 {
    // NTP seconds since 1900 -> Unix seconds since 1970
    const unix_secs: i64 = @as(i64, ntp.seconds) - NTP_UNIX_OFFSET;
    // Fraction to milliseconds: fraction * 1000 / 2^32
    const ms: i64 = (@as(i64, ntp.fraction) * 1000) >> 32;
    return unix_secs * 1000 + ms;
}

/// Convert Unix milliseconds to NTP timestamp
fn unixMsToNtp(unix_ms: i64) NtpTimestamp {
    const unix_secs = @divFloor(unix_ms, 1000);
    const ms = @mod(unix_ms, 1000);

    // Unix seconds -> NTP seconds
    const ntp_secs: u32 = @intCast(unix_secs + NTP_UNIX_OFFSET);
    // Milliseconds to fraction: ms * 2^32 / 1000
    const fraction: u32 = @intCast((@as(u64, @intCast(ms)) << 32) / 1000);

    return .{
        .seconds = ntp_secs,
        .fraction = fraction,
    };
}

/// Format Unix epoch milliseconds as ISO 8601 string
pub fn formatTime(epoch_ms: i64, buf: []u8) []const u8 {
    const secs = @divFloor(epoch_ms, 1000);
    var days = @divFloor(secs, 86400);
    var day_secs = @mod(secs, 86400);
    if (day_secs < 0) {
        day_secs += 86400;
        days -= 1;
    }

    const hour: u8 = @intCast(@divFloor(day_secs, 3600));
    const minute: u8 = @intCast(@divFloor(@mod(day_secs, 3600), 60));
    const second: u8 = @intCast(@mod(day_secs, 60));

    // Calculate year, month, day from days since 1970
    var year: i32 = 1970;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const leap = isLeapYear(year);
    const month_days = if (leap) leap_month_days else normal_month_days;

    var month: u8 = 1;
    while (month <= 12) : (month += 1) {
        if (days < month_days[month - 1]) break;
        days -= month_days[month - 1];
    }

    const day: u8 = @intCast(days + 1);
    const year_u: u16 = @intCast(year);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_u, month, day, hour, minute, second,
    }) catch "????-??-??T??:??:??Z";
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

const normal_month_days = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const leap_month_days = [12]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

// ============================================================================
// Tests
// ============================================================================

test "NTP timestamp conversion" {
    // Test round-trip conversion
    const test_ms: i64 = 1706000000000; // 2024-01-23 roughly
    const ntp = unixMsToNtp(test_ms);
    const back = ntpToUnixMs(ntp);

    // Should be within 1ms due to fraction precision
    try std.testing.expect(@abs(back - test_ms) <= 1);
}

test "NTP request packet format" {
    var buf: [48]u8 = undefined;
    buildRequest(&buf, 0);

    // Check LI|VN|Mode byte
    try std.testing.expectEqual(@as(u8, 0x23), buf[0]);
    // Check poll interval
    try std.testing.expectEqual(@as(u8, 6), buf[2]);
}

test "formatTime" {
    // 2024-01-23 12:14:56 UTC (Unix timestamp: 1706012096)
    const epoch_ms: i64 = 1706012096000;
    var buf: [32]u8 = undefined;
    const formatted = formatTime(epoch_ms, &buf);

    try std.testing.expect(formatted.len > 0);
    try std.testing.expectEqualStrings("2024-01-23T12:14:56Z", formatted);
}
