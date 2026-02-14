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
    _ = c.webview_bind(w, "zigPushAudioBatch", &onPushAudioBatch, null);
    _ = c.webview_bind(w, "zigPullAudioOut", &onPullAudioOut, null);

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
    const val = parseFirstArgU32(req) orelse {
        returnNull(id);
        return;
    };
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
    const val = parseFirstArgI32(req) orelse {
        returnNull(id);
        return;
    };
    shared.wifi_rssi = @intCast(@max(-127, @min(0, val)));
    returnNull(id);
}

fn onPushAudioInSample(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const val = parseFirstArgI32(req) orelse {
        returnNull(id);
        return;
    };
    const avail = state_mod.AUDIO_BUF_SAMPLES - (shared.audio_in_write -% shared.audio_in_read);
    if (avail > 0) {
        shared.audio_in_buf[shared.audio_in_write & state_mod.AUDIO_BUF_MASK] = @intCast(@max(-32768, @min(32767, val)));
        shared.audio_in_write +%= 1;
    }
    returnNull(id);
}

/// Batch push audio samples: zigPushAudioBatch("base64_of_i16le_samples")
/// One binding call for an entire ScriptProcessorNode buffer (e.g. 256 samples)
/// instead of 256 individual zigPushAudioInSample calls.
fn onPushAudioBatch(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const b64_data = parseFirstArgString(req) orelse {
        returnNull(id);
        return;
    };

    // Decode base64 to i16 samples (little-endian)
    var decode_buf: [2048]u8 = undefined; // 1024 samples * 2 bytes
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_data) catch {
        returnNull(id);
        return;
    };
    if (decoded_len > decode_buf.len or decoded_len < 2) {
        returnNull(id);
        return;
    }
    std.base64.standard.Decoder.decode(&decode_buf, b64_data) catch {
        returnNull(id);
        return;
    };

    const sample_count = decoded_len / 2;
    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const avail = state_mod.AUDIO_BUF_SAMPLES - (shared.audio_in_write -% shared.audio_in_read);
        if (avail == 0) break;
        const lo: u16 = decode_buf[i * 2];
        const hi: u16 = decode_buf[i * 2 + 1];
        const sample: i16 = @bitCast(lo | (hi << 8));
        shared.audio_in_buf[shared.audio_in_write & state_mod.AUDIO_BUF_MASK] = sample;
        shared.audio_in_write +%= 1;
    }

    returnNull(id);
}

/// Pull speaker samples: zigPullAudioOut(maxSamples) → base64 of i16le
/// Returns available speaker samples (up to maxSamples) as base64-encoded
/// little-endian i16 data. Advances audio_out_read. One binding call per
/// ScriptProcessorNode buffer instead of per-sample polling.
fn onPullAudioOut(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    const max_samples = parseFirstArgU32(req) orelse 1024;
    const avail = shared.audioOutAvailable();
    if (avail == 0) {
        // Return empty string (no samples)
        _ = c.webview_return(g_webview, id, 0, "\"\"");
        return;
    }

    const to_read = @min(avail, max_samples);
    // Encode i16le samples to base64
    var raw_buf: [2048]u8 = undefined; // 1024 samples * 2 bytes
    const byte_count = to_read * 2;
    if (byte_count > raw_buf.len) {
        _ = c.webview_return(g_webview, id, 0, "\"\"");
        return;
    }

    var i: u32 = 0;
    while (i < to_read) : (i += 1) {
        const sample = shared.audio_out_buf[(shared.audio_out_read +% i) & state_mod.AUDIO_BUF_MASK];
        const u_sample: u16 = @bitCast(sample);
        raw_buf[i * 2] = @truncate(u_sample);
        raw_buf[i * 2 + 1] = @truncate(u_sample >> 8);
    }
    shared.audio_out_read +%= to_read;

    // Base64 encode
    const b64_len = std.base64.standard.Encoder.calcSize(byte_count);
    var b64_buf: [4096]u8 = undefined; // ~2730 chars for 2048 bytes
    if (b64_len + 2 > b64_buf.len) {
        _ = c.webview_return(g_webview, id, 0, "\"\"");
        return;
    }

    // Build JSON string: "base64data"
    b64_buf[0] = '"';
    _ = std.base64.standard.Encoder.encode(b64_buf[1..][0..b64_len], raw_buf[0..byte_count]);
    b64_buf[b64_len + 1] = '"';
    b64_buf[b64_len + 2] = 0;
    _ = c.webview_return(g_webview, id, 0, @ptrCast(b64_buf[0 .. b64_len + 2 :0]));
}

// ============================================================================
// State query (JS polls full state as JSON)
// ============================================================================

fn onGetState(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    var buf: [8192]u8 = undefined;
    const json_result = buildStateJson(&buf) catch {
        // On any write error, return empty object so JS Promise resolves
        _ = c.webview_return(g_webview, id, 0, "{}");
        return;
    };
    buf[json_result] = 0;
    _ = c.webview_return(g_webview, id, 0, @ptrCast(buf[0..json_result :0]));
}

/// Build the state JSON into `buf`, returning the length written.
/// Separated from onGetState so errors propagate cleanly via `!`.
fn buildStateJson(buf: *[8192]u8) !usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.print("{{", .{});

    // LEDs
    try w.print("\"leds\":[", .{});
    const led_count = shared.led_count;
    for (0..led_count) |i| {
        const col = shared.led_colors[i];
        const rgb = (@as(u32, col.r) << 16) | (@as(u32, col.g) << 8) | @as(u32, col.b);
        if (i > 0) try w.writeByte(',');
        try w.print("{}", .{rgb});
    }
    try w.print("],\"led_count\":{}", .{led_count});

    // Log
    try w.print(",\"log_dirty\":{}", .{@intFromBool(shared.log_dirty)});
    if (shared.log_dirty) {
        shared.log_dirty = false;
        try w.print(",\"logs\":[", .{});
        const total = @min(shared.log_count, state_mod.LOG_LINES_MAX);
        for (0..total) |i| {
            if (shared.getLogLine(@intCast(i))) |line| {
                if (i > 0) try w.writeByte(',');
                try w.writeByte('"');
                // Escape JSON string
                for (line) |ch| {
                    switch (ch) {
                        '"' => try w.writeAll("\\\""),
                        '\\' => try w.writeAll("\\\\"),
                        '\n' => try w.writeAll("\\n"),
                        '\r' => {},
                        else => {
                            if (ch >= 0x20) {
                                try w.writeByte(ch);
                            }
                        },
                    }
                }
                try w.writeByte('"');
            }
        }
        try w.print("]", .{});
    }

    // WiFi
    try w.print(",\"wifi_connected\":{}", .{@intFromBool(shared.wifi_connected)});
    if (shared.wifi_connected) {
        try w.print(",\"wifi_ssid\":\"", .{});
        const ssid_len = shared.wifi_ssid_len;
        if (ssid_len > 0) {
            try w.writeAll(shared.wifi_ssid[0..ssid_len]);
        }
        try w.print("\",\"wifi_rssi\":{}", .{@as(i32, shared.wifi_rssi)});
    }

    // Net
    try w.print(",\"net_has_ip\":{}", .{@intFromBool(shared.net_has_ip)});
    if (shared.net_has_ip) {
        try w.print(",\"net_ip\":\"{}.{}.{}.{}\"", .{
            shared.net_ip[0], shared.net_ip[1], shared.net_ip[2], shared.net_ip[3],
        });
    }

    // BLE
    try w.print(",\"ble_state\":{},\"ble_connected\":{}", .{
        @as(u32, shared.ble_state),
        @intFromBool(shared.ble_connected),
    });

    // Display dirty flag (framebuffer sent separately if needed)
    try w.print(",\"display_dirty\":{}", .{@intFromBool(shared.display_dirty)});

    // Audio out available
    try w.print(",\"audio_out_avail\":{}", .{shared.audioOutAvailable()});

    try w.print("}}", .{});

    return fbs.getWritten().len;
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
    // Skip to '[' delimiter
    var i: usize = 0;
    while (i < s.len and s[i] != '[') : (i += 1) {}
    if (i >= s.len) return null;
    i += 1; // skip '['
    // Must have at least one digit
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
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
    if (i >= s.len) return null;
    i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    // Must have at least one digit
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
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
