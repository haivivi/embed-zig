//! Hello BK7258 — WiFi + DNS Test
//!
//! Simple connectivity test: connect to WiFi, get IP, resolve DNS.

const std = @import("std");
const hal = @import("hal");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const AppState = enum { connecting, connected, testing, done };

pub fn run(env: anytype) void {
    log.info("========================================", .{});
    log.info("=== Hello BK7258 (hal.Board pattern) ===", .{});
    log.info("========================================", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("Connecting to WiFi: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var state: AppState = .connecting;

    while (Board.isRunning()) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .connected => log.info("WiFi connected (waiting for IP...)", .{}),
                    .disconnected => |reason| {
                        log.warn("WiFi disconnected: {}", .{reason});
                        state = .connecting;
                    },
                    .connection_failed => |reason| {
                        log.err("WiFi failed: {}", .{reason});
                        return;
                    },
                    else => {},
                },
                .net => |net_event| switch (net_event) {
                    .dhcp_bound, .dhcp_renewed => |info| {
                        log.info("Got IP: {}.{}.{}.{}", .{ info.ip[0], info.ip[1], info.ip[2], info.ip[3] });
                        log.info("DNS: {}.{}.{}.{}", .{ info.dns_main[0], info.dns_main[1], info.dns_main[2], info.dns_main[3] });
                        state = .connected;
                    },
                    .ip_lost => {
                        log.warn("IP lost", .{});
                        state = .connecting;
                    },
                    else => {},
                },
                else => {},
            }
        }

        switch (state) {
            .connecting => {},
            .connected => {
                Board.time.sleepMs(500);
                log.info("WiFi OK! Hello from BK7258.", .{});
                state = .testing;
            },
            .testing => {
                state = .done;
            },
            .done => {},
        }

        Board.time.sleepMs(10);
    }
}
