//! DNS Integration Test - Tests UDP, TCP, DoH on host
//!
//! Run with: zig build run-test

const std = @import("std");
const dns = @import("src/dns.zig");
const std_impl = @import("std_impl");
const crypto_suite = @import("crypto");

const print = std.debug.print;

/// Use std_impl socket (implements trait.socket interface)
const Socket = std_impl.socket.Socket;

const Resolver = dns.Resolver(Socket);
const ResolverWithTls = dns.ResolverWithTls(Socket, crypto_suite, std_impl.runtime);

/// Build a minimal TLS 1.3 ClientHello
fn buildMinimalClientHello(buf: []u8, hostname: []const u8) usize {
    var pos: usize = 0;
    
    // Handshake type: ClientHello (1)
    buf[pos] = 0x01;
    pos += 1;
    
    // Length placeholder (3 bytes)
    const len_pos = pos;
    pos += 3;
    
    // Client Version: TLS 1.2 (for compatibility)
    buf[pos] = 0x03;
    buf[pos + 1] = 0x03;
    pos += 2;
    
    // Random (32 bytes)
    std.crypto.random.bytes(buf[pos..][0..32]);
    pos += 32;
    
    // Session ID length: 0
    buf[pos] = 0;
    pos += 1;
    
    // Cipher suites
    const cipher_suites = [_]u16{
        0x1301, // TLS_AES_128_GCM_SHA256
        0x1302, // TLS_AES_256_GCM_SHA384
        0x1303, // TLS_CHACHA20_POLY1305_SHA256
    };
    buf[pos] = 0;
    buf[pos + 1] = @intCast(cipher_suites.len * 2);
    pos += 2;
    for (cipher_suites) |suite| {
        buf[pos] = @intCast((suite >> 8) & 0xFF);
        buf[pos + 1] = @intCast(suite & 0xFF);
        pos += 2;
    }
    
    // Compression methods: null only
    buf[pos] = 1;
    buf[pos + 1] = 0;
    pos += 2;
    
    // Extensions
    const ext_start = pos;
    pos += 2; // Extension length placeholder
    
    // SNI extension (type 0x0000)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;
    const sni_len: u16 = @intCast(hostname.len + 5);
    buf[pos] = @intCast((sni_len >> 8) & 0xFF);
    buf[pos + 1] = @intCast(sni_len & 0xFF);
    pos += 2;
    const sni_list_len: u16 = @intCast(hostname.len + 3);
    buf[pos] = @intCast((sni_list_len >> 8) & 0xFF);
    buf[pos + 1] = @intCast(sni_list_len & 0xFF);
    pos += 2;
    buf[pos] = 0; // host_name type
    pos += 1;
    buf[pos] = @intCast((hostname.len >> 8) & 0xFF);
    buf[pos + 1] = @intCast(hostname.len & 0xFF);
    pos += 2;
    @memcpy(buf[pos..][0..hostname.len], hostname);
    pos += hostname.len;
    
    // Supported Versions extension (type 0x002b)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x2b;
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x03; // length
    pos += 2;
    buf[pos] = 0x02; // versions length
    buf[pos + 1] = 0x03;
    buf[pos + 2] = 0x04; // TLS 1.3
    pos += 3;
    
    // Supported Groups extension (type 0x000a)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x0a;
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x04; // length
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x02; // groups length
    buf[pos + 2] = 0x00;
    buf[pos + 3] = 0x1d; // x25519
    pos += 4;
    
    // Signature Algorithms extension (type 0x000d)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x0d;
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x08; // length
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x06; // algorithms length
    pos += 2;
    // ecdsa_secp256r1_sha256
    buf[pos] = 0x04;
    buf[pos + 1] = 0x03;
    pos += 2;
    // rsa_pss_rsae_sha256
    buf[pos] = 0x08;
    buf[pos + 1] = 0x04;
    pos += 2;
    // rsa_pkcs1_sha256
    buf[pos] = 0x04;
    buf[pos + 1] = 0x01;
    pos += 2;
    
    // Key Share extension (type 0x0033) - x25519
    buf[pos] = 0x00;
    buf[pos + 1] = 0x33;
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x26; // length (38)
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x24; // key share length (36)
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x1d; // x25519
    pos += 2;
    buf[pos] = 0x00;
    buf[pos + 1] = 0x20; // key length (32)
    pos += 2;
    // Generate random public key (for testing)
    std.crypto.random.bytes(buf[pos..][0..32]);
    pos += 32;
    
    // Write extension length
    const ext_len = pos - ext_start - 2;
    buf[ext_start] = @intCast((ext_len >> 8) & 0xFF);
    buf[ext_start + 1] = @intCast(ext_len & 0xFF);
    
    // Write handshake length (3 bytes, big-endian)
    const hs_len = pos - 4;
    buf[len_pos] = @intCast((hs_len >> 16) & 0xFF);
    buf[len_pos + 1] = @intCast((hs_len >> 8) & 0xFF);
    buf[len_pos + 2] = @intCast(hs_len & 0xFF);
    
    return pos;
}

pub fn main() !void {
    print("\n=== DNS Integration Test ===\n\n", .{});

    const test_domains = [_][]const u8{
        "www.google.com",
        "www.baidu.com",
        "cloudflare.com",
        "github.com",
    };

    // Test 1: UDP DNS
    print("--- Test 1: UDP DNS (223.5.5.5 AliDNS) ---\n", .{});
    {
        var resolver = Resolver{
            .server = .{ 223, 5, 5, 5 },
            .protocol = .udp,
            .timeout_ms = 5000,
        };

        for (test_domains) |domain| {
            if (resolver.resolve(domain)) |ip| {
                print("{s} => {d}.{d}.{d}.{d}\n", .{ domain, ip[0], ip[1], ip[2], ip[3] });
            } else |err| {
                print("{s} => ERROR: {}\n", .{ domain, err });
            }
        }
    }

    print("\n--- Test 2: TCP DNS (223.5.5.5 AliDNS) ---\n", .{});
    {
        var resolver = Resolver{
            .server = .{ 223, 5, 5, 5 },
            .protocol = .tcp,
            .timeout_ms = 5000,
        };

        for (test_domains) |domain| {
            if (resolver.resolve(domain)) |ip| {
                print("{s} => {d}.{d}.{d}.{d}\n", .{ domain, ip[0], ip[1], ip[2], ip[3] });
            } else |err| {
                print("{s} => ERROR: {}\n", .{ domain, err });
            }
        }
    }

    print("\n--- Test 3: TLS Library Test ---\n", .{});
    {
        const tls = @import("net/tls");
        const TlsClient = tls.Client(Socket, crypto_suite, std_impl.runtime);
        const allocator = std.heap.page_allocator;

        // Test HTTPS with example.com (TLS 1.3)
        const target_host = "example.com";
        print("Resolving {s}...\n", .{target_host});
        var udp_resolver = Resolver{
            .server = .{ 8, 8, 8, 8 },
            .protocol = .udp,
            .timeout_ms = 5000,
        };
        const target_ip = udp_resolver.resolve(target_host) catch |err| {
            print("DNS failed: {}\n", .{err});
            return;
        };
        print("{s} => {d}.{d}.{d}.{d}\n", .{ target_host, target_ip[0], target_ip[1], target_ip[2], target_ip[3] });

        print("Creating TCP socket...\n", .{});
        var sock = Socket.tcp() catch |err| {
            print("Socket create failed: {}\n", .{err});
            return;
        };
        defer sock.close();

        sock.setRecvTimeout(30000);
        sock.setSendTimeout(30000);

        print("TCP connecting...\n", .{});
        sock.connect(target_ip, 443) catch |err| {
            print("Connect failed: {}\n", .{err});
            return;
        };
        print("TCP connected!\n", .{});

        print("Initializing TLS...\n", .{});
        var tls_client = TlsClient.init(&sock, .{
            .allocator = allocator,
            .hostname = "example.com",
            .skip_verify = true,
            .timeout_ms = 30000,
        }) catch |err| {
            print("TLS init failed: {}\n", .{err});
            return;
        };
        defer tls_client.deinit();

        print("TLS handshake...\n", .{});
        tls_client.connect() catch |err| {
            print("TLS handshake FAILED: {}\n", .{err});
            return;
        };
        print("TLS handshake SUCCESS!\n", .{});

        print("Sending HTTP request...\n", .{});
        const request = "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
        _ = tls_client.send(request) catch |err| {
            print("TLS send failed: {}\n", .{err});
            return;
        };

        print("Receiving response...\n", .{});
        var response_buf: [4096]u8 = undefined;
        const n = tls_client.recv(&response_buf) catch |err| {
            print("TLS recv failed: {}\n", .{err});
            return;
        };
        print("Received {d} bytes:\n{s}\n", .{ n, response_buf[0..@min(n, 500)] });
    }

    print("\n--- Test 4: DoH (DNS over HTTPS) ---\n", .{});
    {
        const allocator = std.heap.page_allocator;

        // Test DoH with different providers
        const doh_tests = [_]struct {
            name: []const u8,
            server: [4]u8,
            host: []const u8,
        }{
            .{ .name = "AliDNS", .server = .{ 223, 5, 5, 5 }, .host = "dns.alidns.com" },
            .{ .name = "Google DNS", .server = .{ 8, 8, 8, 8 }, .host = "dns.google" },
            .{ .name = "Cloudflare", .server = .{ 1, 1, 1, 1 }, .host = "cloudflare-dns.com" },
        };

        for (doh_tests) |doh_config| {
            print("\nDoH via {s} ({s}):\n", .{ doh_config.name, doh_config.host });

            var resolver = ResolverWithTls{
                .server = doh_config.server,
                .protocol = .https,
                .doh_host = doh_config.host,
                .allocator = allocator,
                .timeout_ms = 10000,
                .skip_cert_verify = true,
            };

            for (test_domains) |domain| {
                if (resolver.resolve(domain)) |ip| {
                    print("  {s} => {d}.{d}.{d}.{d}\n", .{ domain, ip[0], ip[1], ip[2], ip[3] });
                } else |err| {
                    print("  {s} => ERROR: {}\n", .{ domain, err });
                }
            }
        }
    }

    print("\n=== All Tests Complete ===\n", .{});
}
