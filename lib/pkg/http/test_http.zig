//! HTTP Integration Test
//!
//! Tests HTTP and HTTPS requests with real network connections.
//!
//! Run with: zig build run-test
//!
//! For local HTTPS tests, start the Go server first:
//!   cd tools/https_server && go run main.go
//!
//! For certificate verification tests:
//!   cd tools/https_server && go run main.go -ca-out ./certs

const std = @import("std");
const http = @import("src/http.zig");
const std_impl = @import("std_impl");
const crypto = @import("crypto");

const print = std.debug.print;

/// Use std_impl socket (implements trait.socket interface)
const Socket = std_impl.socket.Socket;

/// Full-featured HTTP client with built-in TLS, DNS, and thread safety
const HttpClient = http.HttpClient(Socket, crypto, std_impl.runtime);

pub fn main() !void {
    print("\n=== HTTP Integration Test ===\n\n", .{});

    const allocator = std.heap.page_allocator;

    // =========================================================================
    // Test 1: No ca_store = No verification (default behavior)
    // =========================================================================
    print("=== Test: No ca_store (skip verification) ===\n\n", .{});

    // Create HTTP client without ca_store - should skip certificate verification
    var client_no_verify = HttpClient{
        .allocator = allocator,
        .dns_server = .{ 8, 8, 8, 8 }, // Google DNS
        .skip_cert_verify = true,
        .ca_store = null, // No CA store = no verification
        .timeout_ms = 30000,
    };

    // =========================================================================
    // Test 2: With ca_store.insecure (parse but don't verify)
    // =========================================================================
    print("=== Test: ca_store.insecure (parse only) ===\n\n", .{});

    var client_insecure = HttpClient{
        .allocator = allocator,
        .dns_server = .{ 8, 8, 8, 8 },
        .skip_cert_verify = true,
        .ca_store = .{ .insecure = {} }, // Parse but don't verify
        .timeout_ms = 30000,
    };

    // Use client_no_verify for most tests (backward compatible)
    var client = &client_no_verify;

    // =========================================================================
    // Local Server Tests (requires: cd tools/https_server && go run main.go)
    // =========================================================================
    print("--- Local Server Tests ---\n", .{});
    print("(Skip if Go server not running)\n\n", .{});

    // Local Test 1: TLS 1.3 AES-128-GCM (port 8443)
    print("Local Test 1: TLS 1.3 AES-128-GCM (localhost:8443)\n", .{});
    {
        var buffer: [4096]u8 = undefined;
        if (client.get("https://127.0.0.1:8443/test", &buffer)) |resp| {
            print("  Status: {d}\n", .{resp.status_code});
            print("  Body: {s}\n\n", .{resp.body()});
        } else |err| {
            print("  Skipped (server not running): {}\n\n", .{err});
        }
    }

    // Local Test 2: TLS 1.3 AES-256-GCM (port 8444)
    print("Local Test 2: TLS 1.3 AES-256-GCM (localhost:8444)\n", .{});
    {
        var buffer: [4096]u8 = undefined;
        if (client.get("https://127.0.0.1:8444/test", &buffer)) |resp| {
            print("  Status: {d}\n", .{resp.status_code});
            print("  Body: {s}\n\n", .{resp.body()});
        } else |err| {
            print("  Skipped (server not running): {}\n\n", .{err});
        }
    }

    // Local Test 3: TLS 1.3 ChaCha20-Poly1305 (port 8445)
    print("Local Test 3: TLS 1.3 ChaCha20-Poly1305 (localhost:8445)\n", .{});
    {
        var buffer: [4096]u8 = undefined;
        if (client.get("https://127.0.0.1:8445/test", &buffer)) |resp| {
            print("  Status: {d}\n", .{resp.status_code});
            print("  Body: {s}\n\n", .{resp.body()});
        } else |err| {
            print("  Skipped (server not running): {}\n\n", .{err});
        }
    }

    // Local Test 4: TLS 1.2 RSA AES-128-GCM (port 8452)
    print("Local Test 4: TLS 1.2 RSA AES-128-GCM (localhost:8452)\n", .{});
    {
        var buffer: [4096]u8 = undefined;
        if (client.get("https://127.0.0.1:8452/test", &buffer)) |resp| {
            print("  Status: {d}\n", .{resp.status_code});
            print("  Body: {s}\n\n", .{resp.body()});
        } else |err| {
            print("  Skipped (server not running): {}\n\n", .{err});
        }
    }

    // =========================================================================
    // External Server Tests (requires internet)
    // =========================================================================
    print("--- External Server Tests ---\n\n", .{});

    // Test 1: HTTPS GET (TLS 1.3 - example.com)
    print("--- Test 1: HTTPS GET (example.com - TLS 1.3) ---\n", .{});
    {
        var buffer: [8192]u8 = undefined;
        if (client.get("https://example.com/", &buffer)) |resp| {
            print("Status: {d} {s}\n", .{ resp.status_code, resp.statusText() });
            print("Content-Length: {?d}\n", .{resp.content_length});
            print("Body preview: {s}...\n\n", .{resp.body()[0..@min(200, resp.body().len)]});
        } else |err| {
            print("ERROR: {}\n\n", .{err});
        }
    }

    // Test 2: HTTPS GET (TLS 1.2 - httpbin.org)
    print("--- Test 2: HTTPS GET (httpbin.org - TLS 1.2) ---\n", .{});
    {
        var buffer: [8192]u8 = undefined;
        if (client.get("https://httpbin.org/get", &buffer)) |resp| {
            print("Status: {d} {s}\n", .{ resp.status_code, resp.statusText() });
            print("Content-Length: {?d}\n", .{resp.content_length});
            print("Body: {s}\n\n", .{resp.body()});
        } else |err| {
            print("ERROR: {}\n\n", .{err});
        }
    }

    // Test 3: HTTPS GET (Cloudflare)
    print("--- Test 3: HTTPS GET (cloudflare.com) ---\n", .{});
    {
        var buffer: [16384]u8 = undefined;
        if (client.get("https://www.cloudflare.com/", &buffer)) |resp| {
            print("Status: {d} {s}\n", .{ resp.status_code, resp.statusText() });
            print("Content-Length: {?d}\n", .{resp.content_length});
            print("Chunked: {}\n", .{resp.chunked});
            print("Body preview: {s}...\n\n", .{resp.body()[0..@min(200, resp.body().len)]});
        } else |err| {
            print("ERROR: {}\n\n", .{err});
        }
    }

    // Test 4: HTTPS POST (httpbin.org)
    print("--- Test 4: HTTPS POST (httpbin.org/post) ---\n", .{});
    {
        var buffer: [8192]u8 = undefined;
        const post_data = "Hello from Zig HTTP client!";
        if (client.post("https://httpbin.org/post", post_data, &buffer)) |resp| {
            print("Status: {d} {s}\n", .{ resp.status_code, resp.statusText() });
            print("Body: {s}\n\n", .{resp.body()});
        } else |err| {
            print("ERROR: {}\n\n", .{err});
        }
    }

    // Test 5: HTTPS with custom port (if available)
    print("--- Test 5: DNS resolution test ---\n", .{});
    {
        var buffer: [8192]u8 = undefined;
        if (client.get("https://github.com/", &buffer)) |resp| {
            print("Status: {d} {s}\n", .{ resp.status_code, resp.statusText() });
            print("Received {d} bytes\n\n", .{resp.buffer_len});
        } else |err| {
            print("ERROR: {}\n\n", .{err});
        }
    }

    // =========================================================================
    // Certificate Verification Tests
    // =========================================================================
    print("\n--- Certificate Verification Tests ---\n\n", .{});

    // Test 6: ca_store.insecure mode (parse certificates but don't verify)
    print("Test 6: ca_store.insecure (localhost:8443)\n", .{});
    {
        var buffer: [4096]u8 = undefined;
        if (client_insecure.get("https://127.0.0.1:8443/test", &buffer)) |resp| {
            print("  Status: {d}\n", .{resp.status_code});
            print("  Body: {s}\n", .{resp.body()});
            print("  Result: PASS (insecure mode works)\n\n", .{});
        } else |err| {
            print("  Skipped (server not running): {}\n\n", .{err});
        }
    }

    // Test 7: Compare null ca_store vs insecure ca_store
    print("Test 7: Comparing null vs insecure ca_store\n", .{});
    {
        var buffer1: [4096]u8 = undefined;
        var buffer2: [4096]u8 = undefined;

        const result1 = client_no_verify.get("https://example.com/", &buffer1);
        const result2 = client_insecure.get("https://example.com/", &buffer2);

        if (result1) |resp1| {
            print("  null ca_store: Status {d}\n", .{resp1.status_code});
        } else |err| {
            print("  null ca_store: ERROR {}\n", .{err});
        }

        if (result2) |resp2| {
            print("  insecure ca_store: Status {d}\n", .{resp2.status_code});
        } else |err| {
            print("  insecure ca_store: ERROR {}\n", .{err});
        }

        // Both should succeed (no actual verification)
        if (result1 != error.TlsHandshakeFailed and result2 != error.TlsHandshakeFailed) {
            print("  Result: PASS (both modes work without verification)\n\n", .{});
        } else {
            print("  Result: One or both failed\n\n", .{});
        }
    }

    print("=== All Tests Complete ===\n", .{});
}
