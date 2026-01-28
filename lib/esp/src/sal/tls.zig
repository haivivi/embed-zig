//! SAL TLS Implementation - mbedTLS (ESP-IDF)
//!
//! Implements sal.tls interface using ESP-IDF's mbedTLS.
//! This wraps the C mbedTLS API for use in Zig code.

const std = @import("std");

const net_socket = @import("../net/socket.zig");

const c = @cImport({
    @cInclude("stdbool.h");
    @cInclude("mbedtls/ssl.h");
    @cInclude("mbedtls/entropy.h");
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/error.h");
    @cInclude("mbedtls/net_sockets.h");
    @cInclude("mbedtls/x509_crt.h");
    @cInclude("esp_crt_bundle.h");
});

// ============================================================================
// Types (matching sal.tls interface)
// ============================================================================

/// TLS errors
pub const TlsError = error{
    InitFailed,
    HandshakeFailed,
    CertificateError,
    SendFailed,
    RecvFailed,
    Timeout,
    ConnectionClosed,
    OutOfMemory,
};

/// TLS configuration options
pub const Options = struct {
    /// Skip server certificate verification (insecure, for testing)
    skip_cert_verify: bool = false,
    /// Connection timeout in milliseconds
    timeout_ms: u32 = 30000,
    /// Custom CA certificate (PEM format, null-terminated)
    /// If provided, only this CA will be trusted (not the system bundle)
    ca_cert: ?[:0]const u8 = null,
};

// ============================================================================
// TLS Stream Implementation
// ============================================================================

/// TLS Stream - wraps a socket with TLS encryption using mbedTLS
pub const TlsStream = struct {
    // mbedTLS contexts
    ssl: c.mbedtls_ssl_context,
    conf: c.mbedtls_ssl_config,
    entropy: c.mbedtls_entropy_context,
    ctr_drbg: c.mbedtls_ctr_drbg_context,
    cacert: c.mbedtls_x509_crt,

    // Underlying socket
    socket_fd: c_int,

    // Options
    options: Options,

    // Initialization state
    initialized: bool = false,
    has_custom_ca: bool = false,

    const Self = @This();

    /// Initialize TLS context for a socket
    pub fn init(sock: net_socket.Socket, options: Options) TlsError!Self {
        var self = Self{
            .ssl = undefined,
            .conf = undefined,
            .entropy = undefined,
            .ctr_drbg = undefined,
            .cacert = undefined,
            .socket_fd = sock.fd,
            .options = options,
        };

        // Initialize mbedTLS contexts
        c.mbedtls_ssl_init(&self.ssl);
        c.mbedtls_ssl_config_init(&self.conf);
        c.mbedtls_entropy_init(&self.entropy);
        c.mbedtls_ctr_drbg_init(&self.ctr_drbg);
        c.mbedtls_x509_crt_init(&self.cacert);

        // Seed random number generator
        const ret = c.mbedtls_ctr_drbg_seed(
            &self.ctr_drbg,
            c.mbedtls_entropy_func,
            &self.entropy,
            null,
            0,
        );
        if (ret != 0) {
            self.deinit();
            return error.InitFailed;
        }

        // Setup SSL config defaults
        const config_ret = c.mbedtls_ssl_config_defaults(
            &self.conf,
            c.MBEDTLS_SSL_IS_CLIENT,
            c.MBEDTLS_SSL_TRANSPORT_STREAM,
            c.MBEDTLS_SSL_PRESET_DEFAULT,
        );
        if (config_ret != 0) {
            self.deinit();
            return error.InitFailed;
        }

        // Force TLS 1.2
        c.mbedtls_ssl_conf_min_tls_version(&self.conf, c.MBEDTLS_SSL_VERSION_TLS1_2);
        c.mbedtls_ssl_conf_max_tls_version(&self.conf, c.MBEDTLS_SSL_VERSION_TLS1_2);

        // Set authentication mode and CA
        if (options.skip_cert_verify) {
            c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_NONE);
        } else if (options.ca_cert) |ca_pem| {
            // Use custom CA certificate
            c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_REQUIRED);
            std.log.info("Parsing CA cert: {} bytes", .{ca_pem.len});
            const parse_ret = c.mbedtls_x509_crt_parse(&self.cacert, ca_pem.ptr, ca_pem.len + 1);
            if (parse_ret != 0) {
                std.log.err("CA cert parse failed: {}", .{parse_ret});
                self.deinit();
                return error.CertificateError;
            }
            std.log.info("CA cert parsed successfully", .{});
            c.mbedtls_ssl_conf_ca_chain(&self.conf, &self.cacert, null);
            self.has_custom_ca = true;
        } else {
            // Use ESP certificate bundle
            c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_REQUIRED);
            _ = c.esp_crt_bundle_attach(&self.conf);
        }

        // Set RNG
        c.mbedtls_ssl_conf_rng(&self.conf, c.mbedtls_ctr_drbg_random, &self.ctr_drbg);

        // Setup SSL context with config
        const setup_ret = c.mbedtls_ssl_setup(&self.ssl, &self.conf);
        if (setup_ret != 0) {
            self.deinit();
            return error.InitFailed;
        }

        self.initialized = true;
        return self;
    }

    /// Perform TLS handshake with server
    pub fn handshake(self: *Self, hostname: []const u8) TlsError!void {
        if (!self.initialized) return error.InitFailed;

        // Set hostname for SNI
        var hostname_buf: [256]u8 = undefined;
        const len = @min(hostname.len, hostname_buf.len - 1);
        @memcpy(hostname_buf[0..len], hostname[0..len]);
        hostname_buf[len] = 0;

        const sni_ret = c.mbedtls_ssl_set_hostname(&self.ssl, &hostname_buf);
        if (sni_ret != 0) {
            return error.HandshakeFailed;
        }

        // Set BIO callbacks for socket I/O
        c.mbedtls_ssl_set_bio(
            &self.ssl,
            @ptrFromInt(@as(usize, @intCast(self.socket_fd))),
            mbedtlsNetSend,
            mbedtlsNetRecv,
            null, // No timeout recv
        );

        // Perform handshake
        while (true) {
            const ret = c.mbedtls_ssl_handshake(&self.ssl);
            if (ret == 0) break;
            if (ret != c.MBEDTLS_ERR_SSL_WANT_READ and ret != c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                return error.HandshakeFailed;
            }
        }
    }

    /// Send encrypted data
    pub fn send(self: *Self, data: []const u8) TlsError!usize {
        if (!self.initialized) return error.InitFailed;

        var total_sent: usize = 0;
        while (total_sent < data.len) {
            const ret = c.mbedtls_ssl_write(&self.ssl, data.ptr + total_sent, data.len - total_sent);
            if (ret < 0) {
                if (ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) continue;
                return error.SendFailed;
            }
            total_sent += @intCast(ret);
        }
        return total_sent;
    }

    /// Get last error code (for debugging)
    pub var last_error: c_int = 0;

    /// Receive decrypted data
    pub fn recv(self: *Self, buf: []u8) TlsError!usize {
        if (!self.initialized) return error.InitFailed;

        while (true) {
            const ret = c.mbedtls_ssl_read(&self.ssl, buf.ptr, buf.len);
            if (ret > 0) {
                return @intCast(ret);
            } else if (ret == 0) {
                return error.ConnectionClosed;
            } else if (ret == c.MBEDTLS_ERR_SSL_WANT_READ) {
                continue;
            } else if (ret == c.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
                return error.ConnectionClosed;
            } else if (ret == c.MBEDTLS_ERR_NET_RECV_FAILED) {
                // Network receive failed - check errno
                const lwip = @cImport(@cInclude("lwip/sockets.h"));
                const errno_val = lwip.__errno().*;
                if (errno_val == lwip.EAGAIN or errno_val == lwip.EWOULDBLOCK) {
                    return error.Timeout;
                }
                last_error = ret;
                return error.RecvFailed;
            } else {
                // Store error code for debugging
                last_error = ret;
                return error.RecvFailed;
            }
        }
    }

    /// Close TLS connection and free resources
    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            // Send close_notify
            _ = c.mbedtls_ssl_close_notify(&self.ssl);
        }

        c.mbedtls_ssl_free(&self.ssl);
        c.mbedtls_ssl_config_free(&self.conf);
        c.mbedtls_ctr_drbg_free(&self.ctr_drbg);
        c.mbedtls_entropy_free(&self.entropy);
        if (self.has_custom_ca) {
            c.mbedtls_x509_crt_free(&self.cacert);
        }

        self.initialized = false;
        self.has_custom_ca = false;
    }

    // ========================================================================
    // mbedTLS BIO callbacks (socket I/O)
    // ========================================================================

    fn mbedtlsNetSend(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
        const fd: c_int = @intCast(@intFromPtr(ctx));
        const lwip = @cImport(@cInclude("lwip/sockets.h"));
        const ret = lwip.send(fd, buf, len, 0);
        if (ret < 0) {
            return c.MBEDTLS_ERR_NET_SEND_FAILED;
        }
        return @intCast(ret);
    }

    fn mbedtlsNetRecv(ctx: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) c_int {
        const fd: c_int = @intCast(@intFromPtr(ctx));
        const lwip = @cImport(@cInclude("lwip/sockets.h"));
        const ret = lwip.recv(fd, buf, len, 0);
        if (ret < 0) {
            const errno_val = lwip.__errno().*;
            if (errno_val == lwip.EAGAIN or errno_val == lwip.EWOULDBLOCK) {
                return c.MBEDTLS_ERR_SSL_WANT_READ;
            }
            return c.MBEDTLS_ERR_NET_RECV_FAILED;
        }
        return @intCast(ret);
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Create TLS stream from socket
pub fn create(sock: net_socket.Socket, options: Options) TlsError!TlsStream {
    return TlsStream.init(sock, options);
}
