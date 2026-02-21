//! HTTP Library — Client and Server
//!
//! ## Server
//!
//! Lightweight HTTP/1.1 server with comptime-configurable buffer sizes.
//!
//! ```zig
//! const http = @import("http");
//!
//! const routes = [_]http.Route{
//!     http.get("/", serveIndex),
//!     http.get("/api/status", getStatus),
//!     http.post("/api/wifi/config", setWifiConfig),
//!     http.prefix("/static/", http.static.serveEmbedded(&files)),
//! };
//!
//! var server = http.Server(Socket, .{}).init(allocator, &routes);
//!
//! while (try listener.accept()) |conn| {
//!     wg.go(server.serveConn, .{conn});
//! }
//! ```
//!
//! ## Client
//!
//! ```zig
//! const Client = http.HttpClient(Socket, crypto.Suite, Rt, void);
//! var client = Client{ .allocator = allocator };
//! const resp = try client.get("https://example.com/api", &buffer);
//! ```

// -- Client --
pub const client = @import("client.zig");
pub const HttpClient = client.HttpClient;
pub const Client = client.Client;
pub const ClientError = client.ClientError;
pub const ClientResponse = client.Response;

pub const stream = @import("stream.zig");
pub const SocketStream = stream.SocketStream;

// -- Server --
pub const server_mod = @import("server.zig");
pub const Server = server_mod.Server;
pub const ServerConfig = server_mod.Config;

pub const request = @import("request.zig");
pub const Request = request.Request;
pub const Method = request.Method;
pub const HeaderIterator = request.HeaderIterator;
pub const ParseError = request.ParseError;

pub const response = @import("response.zig");
pub const Response = response.Response;
pub const statusText = response.statusText;

pub const router = @import("router.zig");
pub const Route = router.Route;
pub const Handler = router.Handler;
pub const MatchType = router.MatchType;
pub const get = router.get;
pub const post = router.post;
pub const put = router.put;
pub const delete = router.delete;
pub const prefix = router.prefix;

pub const static = @import("static.zig");
pub const EmbeddedFile = static.EmbeddedFile;

// Run all tests
test {
    _ = request;
    _ = response;
    _ = router;
    _ = server_mod;
    _ = static;
}
