//! WebSim Standalone Simulator
//!
//! A blank shell that:
//! 1. Opens a webview window showing "Waiting for firmware..."
//! 2. Listens on a TCP port for firmware uploads
//! 3. On firmware upload: reads board config + WASM, generates board UI, runs firmware
//!
//! Usage: bazel run //tools/websim
//!
//! Then flash firmware:
//!   bazel run :flash --//bazel:port=websim://localhost:PORT

const std = @import("std");
const HttpServer = @import("http_server.zig").HttpServer;
const Route = @import("http_server.zig").Route;
const RequestContext = @import("http_server.zig").RequestContext;
const FlashServer = @import("flash_server.zig").FlashServer;
const FirmwareBundle = @import("flash_server.zig").FirmwareBundle;

// ============================================================================
// webview C bindings
// ============================================================================

const wv = struct {
    const webview_t = ?*anyopaque;
    extern fn webview_create(debug: c_int, window: ?*anyopaque) webview_t;
    extern fn webview_destroy(w: webview_t) c_int;
    extern fn webview_run(w: webview_t) c_int;
    extern fn webview_set_title(w: webview_t, title: [*:0]const u8) c_int;
    extern fn webview_set_size(w: webview_t, width: c_int, height: c_int, hints: c_int) c_int;
    extern fn webview_navigate(w: webview_t, url: [*:0]const u8) c_int;
    extern fn webview_eval(w: webview_t, js: [*:0]const u8) c_int;
    extern fn webview_bind(w: webview_t, name: [*:0]const u8, fn_ptr: *const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn webview_return(w: webview_t, id: [*c]const u8, status: c_int, result: [*:0]const u8) c_int;
    extern fn webview_get_native_handle(w: webview_t, kind: c_int) ?*anyopaque;
};

// Objective-C runtime for NSWindow resize
const objc = struct {
    const SEL = ?*anyopaque;
    const id = ?*anyopaque;

    extern fn sel_registerName(name: [*:0]const u8) SEL;
    extern fn objc_msgSend() void; // variadic, cast to correct type

    const CGFloat = f64;
    const NSRect = extern struct { x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat };

    fn resizeWindow(nswindow: ?*anyopaque, width: u32, height: u32) void {
        if (nswindow == null) return;

        // [nswindow frame] -> NSRect
        const selFrame = sel_registerName("frame");
        const getFrame: *const fn (id, SEL) callconv(.c) NSRect = @ptrCast(&objc_msgSend);
        const frame = getFrame(nswindow, selFrame);

        // New frame: keep top-left position, change size
        const new_h: CGFloat = @floatFromInt(height);
        const new_w: CGFloat = @floatFromInt(width);
        const new_y = frame.y + frame.h - new_h; // keep top edge
        const new_frame = NSRect{ .x = frame.x, .y = new_y, .w = new_w, .h = new_h };

        // [nswindow setFrame:newFrame display:YES animate:YES]
        const selSetFrame = sel_registerName("setFrame:display:animate:");
        const setFrame: *const fn (id, SEL, NSRect, bool, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
        setFrame(nswindow, selSetFrame, new_frame, true, true);
    }
};

// ============================================================================
// Embedded assets
// ============================================================================

const waiting_html = @embedFile("waiting.html");
const renderer_js = @embedFile("renderer.js");
const board_template_html = @embedFile("board_template.html");

// ============================================================================
// Global state
// ============================================================================

var g_webview: wv.webview_t = null;
var g_http_server: ?HttpServer = null;
var g_flash_server: ?FlashServer = null;
var g_current_html: ?[]u8 = null; // dynamically generated board page
var g_wasm_base64: ?[]u8 = null; // base64-encoded WASM for JS injection
var g_flash_port: u16 = 0;

// Route table
const routes = [_]Route{
    .{ .method = "GET", .prefix = "/", .handler = &handlePage },
};

pub fn main() !void {
    std.debug.print(
        \\
        \\  ╔══════════════════════════════════╗
        \\  ║   embed-zig WebSim Simulator     ║
        \\  ╚══════════════════════════════════╝
        \\
        \\
    , .{});

    // Create webview
    const w = wv.webview_create(1, null);
    if (w == null) {
        std.debug.print("[WebSim] ERROR: webview_create failed\n", .{});
        return;
    }
    g_webview = w;
    _ = wv.webview_set_title(w, "embed-zig WebSim");
    _ = wv.webview_set_size(w, 520, 700, 0);

    // Enable auto-grant mic/camera permissions (bypasses WebKit permission dialog)
    {
        const enable_media = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "websim_enable_media" });
        const nswindow = wv.webview_get_native_handle(w, 0);
        enable_media(nswindow);
    }

    // Bind JS callbacks
    _ = wv.webview_bind(w, "zigClose", &onClose, null);
    _ = wv.webview_bind(w, "zigResizeWindow", &onResizeWindow, null);

    // Start HTTP server
    g_http_server = try HttpServer.init(&routes);
    try g_http_server.?.startThread();

    // Start flash server (port 0 = auto-assign)
    g_flash_server = try FlashServer.init(0, &onFirmwareReceived);
    g_flash_port = g_flash_server.?.port;
    try g_flash_server.?.startThread();

    // Navigate to waiting page
    var url_buf: [128]u8 = undefined;
    const url = try g_http_server.?.getUrl(&url_buf);
    std.debug.print("[WebSim] UI: {s}\n", .{url});
    std.debug.print("[WebSim] Flash port: {}\n", .{g_flash_port});
    std.debug.print("[WebSim] Use: bazel run :flash --//bazel:port=websim://localhost:{}\n", .{g_flash_port});
    _ = wv.webview_navigate(w, url.ptr);

    // Run webview event loop
    _ = wv.webview_run(w);

    // Cleanup
    if (g_flash_server) |*fs| fs.stop();
    if (g_http_server) |*s| s.stop();
    if (g_current_html) |h| std.heap.c_allocator.free(h);
    if (g_wasm_base64) |b| std.heap.c_allocator.free(b);
    _ = wv.webview_destroy(w);
    std.debug.print("[WebSim] Exited.\n", .{});
}

// ============================================================================
// HTTP handler — serves current page (waiting or board)
// ============================================================================

fn onClose(id: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("[WebSim] Close: returning to waiting page\n", .{});

    // Clear WASM state
    if (g_wasm_base64) |b| {
        std.heap.c_allocator.free(b);
        g_wasm_base64 = null;
    }

    // Clear current page (back to waiting)
    if (g_current_html) |h| {
        std.heap.c_allocator.free(h);
        g_current_html = null;
    }

    // Navigate back to waiting page (with ?ready=1 to skip splash)
    if (g_webview) |w| {
        var url_buf: [128]u8 = undefined;
        const base_url = g_http_server.?.getUrl(&url_buf) catch {
            _ = wv.webview_return(g_webview, id, 1, "\"url error\"");
            return;
        };
        // Append ?ready=1
        var ready_buf: [140]u8 = undefined;
        const ready_url = std.fmt.bufPrint(&ready_buf, "{s}?ready=1", .{base_url}) catch {
            _ = wv.webview_navigate(w, base_url.ptr);
            _ = wv.webview_return(g_webview, id, 0, "\"ok\"");
            return;
        };
        ready_buf[ready_url.len] = 0;
        _ = wv.webview_navigate(w, @ptrCast(ready_buf[0..ready_url.len :0]));
    }

    _ = wv.webview_return(g_webview, id, 0, "\"ok\"");
}

fn onResizeWindow(id: [*c]const u8, req: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    // zigResizeWindow(width, height)
    const s = std.mem.span(req);
    // Parse [width, height] from JSON array
    var nums: [2]u32 = .{ 520, 700 };
    var idx: usize = 0;
    var i: usize = 0;
    while (i < s.len and idx < 2) {
        if (s[i] >= '0' and s[i] <= '9') {
            var val: u32 = 0;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                val = val * 10 + @as(u32, s[i] - '0');
            }
            nums[idx] = val;
            idx += 1;
        } else {
            i += 1;
        }
    }

    const w_val: c_int = @intCast(@min(nums[0], 1920));
    const h_val: c_int = @intCast(@min(nums[1], 1200));

    if (g_webview) |w| {
        // Use NSWindow setFrame directly (webview_set_size doesn't resize on macOS)
        const nswindow = wv.webview_get_native_handle(w, 0); // WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW
        objc.resizeWindow(nswindow, nums[0], nums[1]);
    }
    std.debug.print("[WebSim] Window resized to {}x{}\n", .{ w_val, h_val });
    _ = wv.webview_return(g_webview, id, 0, "null");
}

fn handlePage(ctx: *RequestContext) void {
    if (g_current_html) |html| {
        ctx.respondHtml(html);
    } else {
        // Replace {{PORT}} placeholder with actual port number
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{g_flash_port}) catch "?";
        const placeholder = "{{PORT}}";
        var out: [8192]u8 = undefined;
        var out_pos: usize = 0;
        var i: usize = 0;
        while (i < waiting_html.len) {
            if (i + placeholder.len <= waiting_html.len and
                std.mem.eql(u8, waiting_html[i..][0..placeholder.len], placeholder))
            {
                @memcpy(out[out_pos..][0..port_str.len], port_str);
                out_pos += port_str.len;
                i += placeholder.len;
            } else {
                out[out_pos] = waiting_html[i];
                out_pos += 1;
                i += 1;
            }
        }
        ctx.respondHtml(out[0..out_pos]);
    }
}

// ============================================================================
// Firmware received callback
// ============================================================================

fn onFirmwareReceived(bundle: FirmwareBundle) void {
    std.debug.print("[WebSim] Firmware: wasm={} bytes\n", .{bundle.wasm_data.len});

    // Generate board HTML (config is embedded in WASM, read by JS after instantiation)
    const html = generateBoardHtml() catch |err| {
        std.debug.print("[WebSim] HTML gen failed: {}\n", .{err});
        return;
    };

    if (g_current_html) |old| std.heap.c_allocator.free(old);
    g_current_html = html;

    // Base64 encode WASM for JS injection
    const b64_len = std.base64.standard.Encoder.calcSize(bundle.wasm_data.len);
    const b64 = std.heap.c_allocator.alloc(u8, b64_len) catch {
        std.debug.print("[WebSim] Base64 alloc failed\n", .{});
        return;
    };
    _ = std.base64.standard.Encoder.encode(b64, bundle.wasm_data);

    if (g_wasm_base64) |old| std.heap.c_allocator.free(old);
    g_wasm_base64 = b64;

    std.debug.print("[WebSim] WASM base64: {} bytes\n", .{b64.len});

    // Navigate to board page
    if (g_webview) |w| {
        var url_buf: [128]u8 = undefined;
        const url = g_http_server.?.getUrl(&url_buf) catch return;
        _ = wv.webview_navigate(w, url.ptr);
    }

    // Inject WASM after page loads (delay for navigation)
    const inject_thread = std.Thread.spawn(.{}, injectWasm, .{}) catch {
        std.debug.print("[WebSim] Inject thread failed\n", .{});
        return;
    };
    _ = inject_thread;
}

fn injectWasm() void {
    // Wait for page to load
    std.Thread.sleep(1000 * std.time.ns_per_ms);

    const b64 = g_wasm_base64 orelse return;
    const w = g_webview orelse return;

    std.debug.print("[WebSim] Injecting WASM ({} base64 bytes)...\n", .{b64.len});

    // Build JS: decode base64 → instantiate WebAssembly → run
    // Split into chunks because webview_eval has a practical size limit
    // First inject the base64 string, then the loader code

    // Inject base64 data as a global variable (chunked if needed)
    // For 846KB WASM → ~1.1MB base64. webview_eval should handle this.
    const prefix = "window._wasmB64='";
    const suffix = "';window._wasmReady=true;";
    const total = prefix.len + b64.len + suffix.len + 1;
    const js = std.heap.c_allocator.alloc(u8, total) catch {
        std.debug.print("[WebSim] JS alloc failed\n", .{});
        return;
    };
    defer std.heap.c_allocator.free(js);

    @memcpy(js[0..prefix.len], prefix);
    @memcpy(js[prefix.len..][0..b64.len], b64);
    @memcpy(js[prefix.len + b64.len ..][0..suffix.len], suffix);
    js[total - 1] = 0;

    _ = wv.webview_eval(w, @ptrCast(js[0 .. total - 1 :0]));
    std.debug.print("[WebSim] WASM data injected, triggering loader...\n", .{});

    // Now trigger the WASM loader
    std.Thread.sleep(200 * std.time.ns_per_ms);
    _ = wv.webview_eval(w, "if(typeof loadWasmFirmware==='function')loadWasmFirmware();");
    std.debug.print("[WebSim] Firmware started!\n", .{});
}

// ============================================================================
// Generate board HTML from config JSON
// ============================================================================

fn generateBoardHtml() ![]u8 {
    // Template has %%RENDERER_JS%% placeholder — board config comes from WASM exports
    const template = board_template_html;
    const rjs_placeholder = "%%RENDERER_JS%%";

    const output_size = template.len + renderer_js.len;
    var output = try std.heap.c_allocator.alloc(u8, output_size);
    var pos: usize = 0;

    var i: usize = 0;
    while (i < template.len) {
        if (i + rjs_placeholder.len <= template.len and
            std.mem.eql(u8, template[i..][0..rjs_placeholder.len], rjs_placeholder))
        {
            @memcpy(output[pos..][0..renderer_js.len], renderer_js);
            pos += renderer_js.len;
            i += rjs_placeholder.len;
        } else {
            output[pos] = template[i];
            pos += 1;
            i += 1;
        }
    }

    // Shrink to actual size
    if (pos < output.len) {
        const final = try std.heap.c_allocator.realloc(output, pos);
        return final;
    }
    return output[0..pos];
}
