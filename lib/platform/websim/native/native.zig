//! WebSim Native Launcher — webview-based hardware simulator.
//!
//! Replaces wasm.zig for native (non-WASM) targets. Uses the system webview
//! (WebKit on macOS, WebKitGTK on Linux, WebView2 on Windows) to render the
//! same board HTML/CSS/JS UI, with Zig running as a native process.
//!
//! Communication:
//!   JS → Zig: webview_bind callbacks (button presses, ADC values, mic data)
//!   Zig → JS: webview_eval / webview_dispatch (LED state, logs, display, status)
//!
//! ## Usage (in app's main.zig)
//!
//! ```zig
//! const websim = @import("websim");
//! const App = @import("app_logic.zig");
//!
//! pub fn main() !void {
//!     websim.native.run(App);
//! }
//! ```

const std = @import("std");
const state_mod = @import("../impl/state.zig");
pub const recorder_mod = @import("recorder.zig");

const shared = &state_mod.state;
const Recorder = recorder_mod.Recorder;

// Manual webview C bindings (avoid @cImport multi-module include path issues)
const c = struct {
    const webview_t = ?*anyopaque;
    const WEBVIEW_HINT_NONE: c_int = 0;
    const WEBVIEW_HINT_FIXED: c_int = 3;
    const WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW: c_int = 0;

    extern fn webview_create(debug: c_int, window: ?*anyopaque) webview_t;
    extern fn webview_destroy(w: webview_t) c_int;
    extern fn webview_run(w: webview_t) c_int;
    extern fn webview_terminate(w: webview_t) c_int;
    extern fn webview_set_title(w: webview_t, title: [*:0]const u8) c_int;
    extern fn webview_set_size(w: webview_t, width: c_int, height: c_int, hints: c_int) c_int;
    extern fn webview_set_html(w: webview_t, html: [*:0]const u8) c_int;
    extern fn webview_navigate(w: webview_t, url: [*:0]const u8) c_int;
    extern fn webview_eval(w: webview_t, js: [*:0]const u8) c_int;
    extern fn webview_bind(w: webview_t, name: [*:0]const u8, fn_ptr: *const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn webview_return(w: webview_t, id: [*c]const u8, status: c_int, result: [*:0]const u8) c_int;
    extern fn webview_get_native_handle(w: webview_t, kind: c_int) ?*anyopaque;

    // Platform helpers (clipboard_macos.m)
    extern fn websim_enable_media_capture(nswindow: ?*anyopaque) void;
};

// Recording dimensions
const REC_WIDTH = 960;
const REC_HEIGHT = 720;
const REC_FPS = 30;

var g_webview: c.webview_t = null;
var g_start_time: i64 = 0;
var g_http_html: []const u8 = "";
var g_http_listener: ?std.net.Server = null;
var g_http_thread: ?std.Thread = null;
var g_http_running: bool = true;
var g_recorder: ?Recorder = null;
var g_frame_rgba: ?[]u8 = null; // Reusable frame buffer
var g_rec_path: [256]u8 = undefined;
var g_rec_path_len: usize = 0;

// ============================================================================
// Public API
// ============================================================================

/// Start the WebSim native launcher.
/// `App` must provide `pub fn init() void` and `pub fn step() void`.
/// `html` is the full HTML page content (typically from @embedFile).
pub fn run(comptime App: type, html: [:0]const u8) void {
    // Create webview (debug=1 enables dev tools)
    const w = c.webview_create(1, null);
    if (w == null) {
        std.debug.print("[WebSim] ERROR: webview_create failed\n", .{});
        return;
    }
    g_webview = w;
    g_start_time = std.time.milliTimestamp();

    _ = c.webview_set_title(w, "embed-zig WebSim");
    _ = c.webview_set_size(w, REC_WIDTH, REC_HEIGHT, c.WEBVIEW_HINT_FIXED);

    // Bind input callbacks (JS → Zig)
    _ = c.webview_bind(w, "zigSetAdcValue", &onSetAdcValue, null);
    _ = c.webview_bind(w, "zigButtonPress", &onButtonPress, null);
    _ = c.webview_bind(w, "zigButtonRelease", &onButtonRelease, null);
    _ = c.webview_bind(w, "zigPowerPress", &onPowerPress, null);
    _ = c.webview_bind(w, "zigPowerRelease", &onPowerRelease, null);
    _ = c.webview_bind(w, "zigWifiForceDisconnect", &onWifiForceDisconnect, null);
    _ = c.webview_bind(w, "zigBleSimConnect", &onBleSimConnect, null);
    _ = c.webview_bind(w, "zigBleSimDisconnect", &onBleSimDisconnect, null);
    _ = c.webview_bind(w, "zigSetWifiRssi", &onSetWifiRssi, null);
    _ = c.webview_bind(w, "zigPushAudioInSample", &onPushAudioInSample, null);

    // Bind state query callbacks (JS polls Zig state)
    _ = c.webview_bind(w, "zigGetState", &onGetState, null);

    // Bind recording callbacks
    _ = c.webview_bind(w, "zigStartRecording", &onStartRecording, null);
    _ = c.webview_bind(w, "zigStopRecording", &onStopRecording, null);
    _ = c.webview_bind(w, "zigRecordFrame", &onRecordFrame, null);

    // Enable media capture (mic/camera) on macOS WKWebView
    const nswindow = c.webview_get_native_handle(w, c.WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW);
    c.websim_enable_media_capture(nswindow);

    // Start localhost HTTP server (secure context for getUserMedia)
    g_http_html = html;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    g_http_listener = addr.listen(.{ .reuse_address = true }) catch {
        std.debug.print("[WebSim] HTTP bind failed, falling back to set_html\n", .{});
        _ = c.webview_set_html(w, html.ptr);
        const app_thread_fb = std.Thread.spawn(.{}, appLoop, .{App}) catch return;
        _ = app_thread_fb;
        _ = c.webview_run(w);
        shared.running = false;
        _ = c.webview_destroy(w);
        return;
    };

    const http_port = g_http_listener.?.listen_address.getPort();
    g_http_running = true;
    g_http_thread = std.Thread.spawn(.{}, httpServeLoop, .{}) catch null;

    var url_buf: [64]u8 = undefined;
    const url_slice = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{http_port}) catch "http://127.0.0.1:8080";
    url_buf[url_slice.len] = 0;
    const url_z: [*:0]const u8 = @ptrCast(url_buf[0..url_slice.len :0]);

    std.debug.print("[WebSim] HTTP server on {s} (secure context)\n", .{url_z});
    _ = c.webview_navigate(w, url_z);

    // Spawn app thread (runs init + step loop)
    const app_thread = std.Thread.spawn(.{}, appLoop, .{App}) catch {
        std.debug.print("[WebSim] ERROR: failed to spawn app thread\n", .{});
        return;
    };
    _ = app_thread;

    // Run webview event loop (blocks until window is closed)
    _ = c.webview_run(w);

    // Cleanup
    shared.running = false;
    if (g_recorder) |*rec| {
        const path: [:0]const u8 = g_rec_path[0..g_rec_path_len :0];
        rec.stop(path);
        g_recorder = null;
    }
    if (g_frame_rgba) |buf| {
        std.heap.c_allocator.free(buf);
        g_frame_rgba = null;
    }
    // Stop HTTP server
    g_http_running = false;
    if (g_http_listener) |*l| l.deinit();
    if (g_http_thread) |t| t.join();
    _ = c.webview_destroy(w);
}

// ============================================================================
// Localhost HTTP server (for secure context)
// ============================================================================

fn httpServeLoop() void {
    while (g_http_running) {
        const conn = g_http_listener.?.accept() catch {
            if (!g_http_running) return;
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer conn.stream.close();

        // Read request
        var req_buf: [4096]u8 = undefined;
        _ = conn.stream.read(&req_buf) catch continue;

        // Respond with HTML
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{g_http_html.len},
        ) catch continue;
        _ = conn.stream.writeAll(hdr) catch continue;
        _ = conn.stream.writeAll(g_http_html) catch continue;
    }
}

// ============================================================================
// App thread
// ============================================================================

fn appLoop(comptime App: type) void {
    shared.start_time_ms = getCurrentTimeMs();
    shared.time_ms = shared.start_time_ms;

    if (@hasDecl(App, "init")) {
        App.init();
    }

    while (shared.running) {
        shared.time_ms = getCurrentTimeMs();

        if (@hasDecl(App, "step")) {
            App.step();
        }

        // ~60fps
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}

fn getCurrentTimeMs() u64 {
    const now = std.time.milliTimestamp();
    return @intCast(@as(i64, now) - g_start_time);
}

// ============================================================================
// Input callbacks (JS → Zig)
// ============================================================================

fn onSetAdcValue(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const val = parseFirstArgU32(req) orelse return;
    shared.adc_raw = @intCast(@min(val, 4095));
    returnNull(id);
}

fn onButtonPress(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    shared.setButtonPressed(true);
    returnNull(id);
}

fn onButtonRelease(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    shared.setButtonPressed(false);
    returnNull(id);
}

fn onPowerPress(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    shared.setPowerPressed(true);
    returnNull(id);
}

fn onPowerRelease(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    shared.setPowerPressed(false);
    returnNull(id);
}

fn onWifiForceDisconnect(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    shared.wifi_force_disconnect = true;
    returnNull(id);
}

fn onBleSimConnect(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    shared.ble_sim_connect = true;
    returnNull(id);
}

fn onBleSimDisconnect(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    shared.ble_sim_disconnect = true;
    returnNull(id);
}

fn onSetWifiRssi(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const val = parseFirstArgI32(req) orelse return;
    shared.wifi_rssi = @intCast(@max(-127, @min(0, val)));
    returnNull(id);
}

fn onPushAudioInSample(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const val = parseFirstArgI32(req) orelse return;
    const avail = state_mod.AUDIO_BUF_SAMPLES - (shared.audio_in_write -% shared.audio_in_read);
    if (avail > 0) {
        shared.audio_in_buf[shared.audio_in_write & state_mod.AUDIO_BUF_MASK] = @intCast(@max(-32768, @min(32767, val)));
        shared.audio_in_write +%= 1;
    }
    returnNull(id);
}

// ============================================================================
// State query (JS polls full state as JSON)
// ============================================================================

fn onGetState(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("{{", .{}) catch return;

    // LEDs
    w.print("\"leds\":[", .{}) catch return;
    const led_count = shared.led_count;
    for (0..led_count) |i| {
        const col = shared.led_colors[i];
        const rgb = (@as(u32, col.r) << 16) | (@as(u32, col.g) << 8) | @as(u32, col.b);
        if (i > 0) w.writeByte(',') catch return;
        w.print("{}", .{rgb}) catch return;
    }
    w.print("],\"led_count\":{}", .{led_count}) catch return;

    // Log
    w.print(",\"log_dirty\":{}", .{@intFromBool(shared.log_dirty)}) catch return;
    if (shared.log_dirty) {
        shared.log_dirty = false;
        w.print(",\"logs\":[", .{}) catch return;
        const total = @min(shared.log_count, state_mod.LOG_LINES_MAX);
        for (0..total) |i| {
            if (shared.getLogLine(@intCast(i))) |line| {
                if (i > 0) w.writeByte(',') catch return;
                w.writeByte('"') catch return;
                // Escape JSON string
                for (line) |ch| {
                    switch (ch) {
                        '"' => w.writeAll("\\\"") catch return,
                        '\\' => w.writeAll("\\\\") catch return,
                        '\n' => w.writeAll("\\n") catch return,
                        '\r' => {},
                        else => {
                            if (ch >= 0x20) {
                                w.writeByte(ch) catch return;
                            }
                        },
                    }
                }
                w.writeByte('"') catch return;
            }
        }
        w.print("]", .{}) catch return;
    }

    // WiFi
    w.print(",\"wifi_connected\":{}", .{@intFromBool(shared.wifi_connected)}) catch return;
    if (shared.wifi_connected) {
        w.print(",\"wifi_ssid\":\"", .{}) catch return;
        const ssid_len = shared.wifi_ssid_len;
        if (ssid_len > 0) {
            w.writeAll(shared.wifi_ssid[0..ssid_len]) catch return;
        }
        w.print("\",\"wifi_rssi\":{}", .{@as(i32, shared.wifi_rssi)}) catch return;
    }

    // Net
    w.print(",\"net_has_ip\":{}", .{@intFromBool(shared.net_has_ip)}) catch return;
    if (shared.net_has_ip) {
        w.print(",\"net_ip\":\"{}.{}.{}.{}\"", .{
            shared.net_ip[0], shared.net_ip[1], shared.net_ip[2], shared.net_ip[3],
        }) catch return;
    }

    // BLE
    w.print(",\"ble_state\":{},\"ble_connected\":{}", .{
        @as(u32, shared.ble_state),
        @intFromBool(shared.ble_connected),
    }) catch return;

    // Display dirty flag (framebuffer sent separately if needed)
    w.print(",\"display_dirty\":{}", .{@intFromBool(shared.display_dirty)}) catch return;

    // Audio out available
    w.print(",\"audio_out_avail\":{}", .{shared.audioOutAvailable()}) catch return;

    w.print("}}", .{}) catch return;

    const json_len = fbs.getWritten().len;
    // Null-terminate in the same buffer (capacity is 8192, used at most ~4KB)
    buf[json_len] = 0;
    _ = c.webview_return(g_webview, id, 0, @ptrCast(buf[0..json_len :0]));
}

// ============================================================================
// Helpers
// ============================================================================

fn returnNull(id: [*c]const u8) void {
    _ = c.webview_return(g_webview, id, 0, "null");
}

/// Parse first argument from JSON array like "[42,...]"
fn parseFirstArgU32(req: [*c]const u8) ?u32 {
    const s = std.mem.span(req);
    // Skip '[' and find first number
    var i: usize = 0;
    while (i < s.len and s[i] != '[') : (i += 1) {}
    i += 1; // skip '['
    // Parse number
    var val: u32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        val = val * 10 + @as(u32, s[i] - '0');
    }
    return val;
}

fn parseFirstArgI32(req: [*c]const u8) ?i32 {
    const s = std.mem.span(req);
    var i: usize = 0;
    while (i < s.len and s[i] != '[') : (i += 1) {}
    i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    var val: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        val = val * 10 + @as(i32, s[i] - '0');
    }
    return if (neg) -val else val;
}

/// Parse first argument as a JSON string: ["base64data",...]
fn parseFirstArgString(req: [*c]const u8) ?[]const u8 {
    const s = std.mem.span(req);
    // Find opening ["
    var i: usize = 0;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (i >= s.len) return null;
    i += 1; // skip opening "
    const start = i;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (i >= s.len) return null;
    return s[start..i];
}

// ============================================================================
// Recording callbacks
// ============================================================================

fn onStartRecording(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (g_recorder != null) {
        _ = c.webview_return(g_webview, id, 0, "\"already recording\"");
        return;
    }

    // Generate output path with timestamp
    const ts = std.time.timestamp();
    const path_slice = std.fmt.bufPrint(&g_rec_path, "/tmp/websim_{}.mp4", .{ts}) catch {
        _ = c.webview_return(g_webview, id, 1, "\"path error\"");
        return;
    };
    g_rec_path_len = path_slice.len;
    g_rec_path[g_rec_path_len] = 0;
    const path: [:0]const u8 = g_rec_path[0..g_rec_path_len :0];

    g_recorder = Recorder.start(path, REC_WIDTH, REC_HEIGHT, REC_FPS);
    if (g_recorder == null) {
        _ = c.webview_return(g_webview, id, 1, "\"encoder init failed\"");
        return;
    }

    // Allocate frame buffer for RGBA data
    if (g_frame_rgba == null) {
        g_frame_rgba = std.heap.c_allocator.alloc(u8, REC_WIDTH * REC_HEIGHT * 4) catch {
            const p: [:0]const u8 = g_rec_path[0..g_rec_path_len :0];
            g_recorder.?.stop(p);
            g_recorder = null;
            _ = c.webview_return(g_webview, id, 1, "\"alloc failed\"");
            return;
        };
    }

    // Return the output path to JS
    var result_buf: [300]u8 = undefined;
    const result_len = std.fmt.bufPrint(&result_buf, "\"{s}\"", .{path}) catch {
        _ = c.webview_return(g_webview, id, 0, "\"ok\"");
        return;
    };
    result_buf[result_len.len] = 0;
    _ = c.webview_return(g_webview, id, 0, @ptrCast(result_buf[0..result_len.len :0]));
}

fn onStopRecording(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (g_recorder) |*rec| {
        const path: [:0]const u8 = g_rec_path[0..g_rec_path_len :0];
        rec.stop(path);
        g_recorder = null;
        _ = c.webview_return(g_webview, id, 0, "\"copied to clipboard\"");
    } else {
        _ = c.webview_return(g_webview, id, 0, "\"not recording\"");
    }
}

/// Receive a video frame from JS as base64-encoded RGBA data.
/// JS calls: zigRecordFrame(base64String)
fn onRecordFrame(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    var rec = if (g_recorder) |*r| r else {
        returnNull(id);
        return;
    };
    const frame_buf = g_frame_rgba orelse {
        returnNull(id);
        return;
    };

    // Parse base64 data from JSON args
    const b64_data = parseFirstArgString(req) orelse {
        returnNull(id);
        return;
    };

    // Decode base64 to RGBA
    const expected_size = REC_WIDTH * REC_HEIGHT * 4;
    const decoded = std.base64.standard.Decoder.decode(frame_buf[0..expected_size], b64_data) catch {
        returnNull(id);
        return;
    };
    _ = decoded;

    // Add frame to recorder
    rec.addFrame(frame_buf[0..expected_size]);

    // Also capture audio from speaker ring buffer
    var audio_buf: [1024]i16 = undefined;
    const audio_avail = shared.audioOutAvailable();
    if (audio_avail > 0) {
        const to_read = @min(audio_avail, 1024);
        var i: u32 = 0;
        while (i < to_read) : (i += 1) {
            audio_buf[i] = shared.audio_out_buf[(shared.audio_out_read +% i) & state_mod.AUDIO_BUF_MASK];
        }
        shared.audio_out_read +%= to_read;
        rec.addAudio(audio_buf[0..to_read]);
    }

    returnNull(id);
}
