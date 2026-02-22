const trait = @import("trait");
const http = @import("http");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);
const allocator = platform.allocator;

const HttpServer = http.Server(Socket, .{
    .read_buf_size = 4096,
    .write_buf_size = 2048,
    .max_requests_per_conn = 20,
});

fn handleStatus(_: *http.Request, resp: *http.Response) void {
    resp.json("{\"status\":\"ok\",\"server\":\"embed-zig-http\"}");
}

fn handleIndex(_: *http.Request, resp: *http.Response) void {
    _ = resp.contentType("text/html");
    resp.send("<h1>embed-zig HTTP Server</h1><p>Running on ESP32</p>");
}

const routes = [_]http.Route{
    http.get("/", handleIndex),
    http.get("/api/status", handleStatus),
};

const AppState = enum { connecting, wait_ip, serving, done };

pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  HTTP Server Test (Tier 1)", .{});
    log.info("==========================================", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("Connecting to WiFi: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var state: AppState = .connecting;
    var server = HttpServer.init(allocator, &routes);

    while (Board.isRunning() and state != .done) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .connected => {
                        log.info("WiFi connected", .{});
                        state = .wait_ip;
                    },
                    .disconnected => |reason| {
                        log.info("WiFi disconnected: {}", .{reason});
                        state = .connecting;
                    },
                    .connection_failed => |reason| {
                        log.err("WiFi failed: {}", .{reason});
                        state = .done;
                    },
                    else => {},
                },
                .net => |net_event| switch (net_event) {
                    .dhcp_bound => |info| {
                        log.info("IP: {}.{}.{}.{}", .{ info.ip[0], info.ip[1], info.ip[2], info.ip[3] });
                        state = .serving;
                    },
                    else => {},
                },
                else => {},
            }
        }

        if (state == .serving) {
            log.info("Starting HTTP server on port 80...", .{});
            var listener = Socket.tcp() catch {
                log.err("Failed to create listener socket", .{});
                state = .done;
                continue;
            };

            const bind_addr = [4]u8{ 0, 0, 0, 0 };
            listener.bind(bind_addr, 80) catch {
                log.err("Failed to bind to port 80", .{});
                listener.close();
                state = .done;
                continue;
            };

            listener.listen() catch {
                log.err("Failed to listen", .{});
                listener.close();
                state = .done;
                continue;
            };

            log.info("HTTP server listening on :80", .{});
            log.info("READY", .{});

            while (Board.isRunning()) {
                const conn = listener.accept() catch continue;
                server.serveConn(conn);
            }

            listener.close();
            state = .done;
        }

        Board.time.sleepMs(10);
    }
}
