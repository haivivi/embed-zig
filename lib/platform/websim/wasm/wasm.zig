//! WASM Export Helpers for WebSim
//!
//! Provides the standard WASM export functions that the JS shell expects.
//! Uses typed accessor exports instead of raw memory offsets — this ensures
//! correctness regardless of Zig's struct layout decisions.
//!
//! ## Usage (in app's wasm_main.zig)
//!
//! ```zig
//! const websim = @import("websim");
//!
//! comptime {
//!     websim.wasm.exportAll(@This());
//! }
//!
//! pub fn init() void { ... }
//! pub fn step() void { ... }
//! ```

const std = @import("std");
const state_mod = @import("../impl/state.zig");

const shared = &state_mod.state;

// ============================================================================
// Input exports (JS → WASM)
// ============================================================================

/// Set button pressed state (called by JS on mousedown)
export fn buttonPress() void {
    shared.setButtonPressed(true);
}

/// Set button released state (called by JS on mouseup)
export fn buttonRelease() void {
    shared.setButtonPressed(false);
}

/// Update time (called by JS each frame with performance.now())
export fn setTime(ms: u32) void {
    shared.time_ms = @as(u64, ms);
}

// ============================================================================
// State accessor exports (WASM → JS reads)
// ============================================================================

// ---- LEDs ----

export fn getLedCount() u32 {
    return shared.led_count;
}

/// Get LED color as packed u32: 0x00RRGGBB
export fn getLedColor(index: u32) u32 {
    if (index >= state_mod.MAX_LEDS) return 0;
    const c = shared.led_colors[index];
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b);
}

// ---- ADC button group ----

/// Set simulated ADC value (called by JS when a virtual button is pressed)
export fn setAdcValue(raw: u32) void {
    shared.adc_raw = @intCast(@min(raw, 4095));
}

// ---- Power button ----

export fn powerPress() void {
    shared.setPowerPressed(true);
}

export fn powerRelease() void {
    shared.setPowerPressed(false);
}

// ---- Display framebuffer ----

/// Get pointer to display framebuffer (240x240 RGB565)
export fn getDisplayFbPtr() [*]const u8 {
    return &shared.display_fb;
}

export fn getDisplayFbSize() u32 {
    return @as(u32, shared.display_width) * @as(u32, shared.display_height) * state_mod.DISPLAY_BPP;
}

export fn getDisplayWidth() u32 {
    return @as(u32, shared.display_width);
}

export fn getDisplayHeight() u32 {
    return @as(u32, shared.display_height);
}

export fn getDisplayDirty() u32 {
    return if (shared.display_dirty) 1 else 0;
}

export fn clearDisplayDirty() void {
    shared.display_dirty = false;
}

// ---- Log ----

export fn getLogCount() u32 {
    return shared.log_count;
}

export fn getLogDirty() u32 {
    return if (shared.log_dirty) 1 else 0;
}

export fn clearLogDirty() void {
    shared.log_dirty = false;
}

export fn getLogLinePtr(idx: u32) [*]const u8 {
    const total = @min(shared.log_count, state_mod.LOG_LINES_MAX);
    if (idx >= total) return @ptrCast(&shared.log_lines[0]);
    const actual_idx = if (shared.log_count < state_mod.LOG_LINES_MAX)
        idx
    else
        (shared.log_next + idx) % state_mod.LOG_LINES_MAX;
    return &shared.log_lines[actual_idx];
}

export fn getLogLineLen(idx: u32) u32 {
    const total = @min(shared.log_count, state_mod.LOG_LINES_MAX);
    if (idx >= total) return 0;
    const actual_idx = if (shared.log_count < state_mod.LOG_LINES_MAX)
        idx
    else
        (shared.log_next + idx) % state_mod.LOG_LINES_MAX;
    return @as(u32, shared.log_lens[actual_idx]);
}

// ============================================================================
// Audio exports (Speaker output + Mic input ring buffers)
// ============================================================================

// ---- Speaker output (Zig writes, JS reads) ----

/// Get pointer to speaker ring buffer (i16 samples)
export fn getAudioOutPtr() [*]const i16 {
    return &shared.audio_out_buf;
}

/// Get speaker ring buffer size (number of i16 samples)
export fn getAudioOutSize() u32 {
    return state_mod.AUDIO_BUF_SAMPLES;
}

/// Get speaker write cursor (Zig advances this)
export fn getAudioOutWrite() u32 {
    return shared.audio_out_write;
}

/// Get speaker read cursor
export fn getAudioOutRead() u32 {
    return shared.audio_out_read;
}

/// Advance speaker read cursor (JS calls after consuming samples)
export fn setAudioOutRead(pos: u32) void {
    shared.audio_out_read = pos;
}

// ---- Mic input (JS writes, Zig reads) ----

/// Get pointer to mic ring buffer (i16 samples)
export fn getAudioInPtr() [*]i16 {
    return &shared.audio_in_buf;
}

/// Get mic ring buffer size
export fn getAudioInSize() u32 {
    return state_mod.AUDIO_BUF_SAMPLES;
}

/// Get mic write cursor
export fn getAudioInWrite() u32 {
    return shared.audio_in_write;
}

/// Get mic read cursor (Zig advances this)
export fn getAudioInRead() u32 {
    return shared.audio_in_read;
}

/// Write a single sample to mic ring buffer (JS calls from audio worklet)
export fn pushAudioInSample(sample: i32) void {
    const avail = state_mod.AUDIO_BUF_SAMPLES - (shared.audio_in_write -% shared.audio_in_read);
    if (avail > 0) {
        shared.audio_in_buf[shared.audio_in_write & state_mod.AUDIO_BUF_MASK] = @intCast(@max(-32768, @min(32767, sample)));
        shared.audio_in_write +%= 1;
    }
}

// ============================================================================
// WiFi / Net state exports (WASM → JS reads, JS → WASM writes)
// ============================================================================

/// Get WiFi connected state (0 or 1)
export fn getWifiConnected() u32 {
    return if (shared.wifi_connected) 1 else 0;
}

/// Get WiFi SSID pointer (for JS to read string)
export fn getWifiSsidPtr() [*]const u8 {
    return &shared.wifi_ssid;
}

/// Get WiFi SSID length
export fn getWifiSsidLen() u32 {
    return @as(u32, shared.wifi_ssid_len);
}

/// Get WiFi RSSI
export fn getWifiRssi() i32 {
    return @as(i32, shared.wifi_rssi);
}

/// Set WiFi RSSI (JS → WASM, for simulation)
export fn setWifiRssi(rssi: i32) void {
    shared.wifi_rssi = @intCast(@max(-127, @min(0, rssi)));
}

/// Force WiFi disconnect (JS → WASM)
export fn wifiForceDisconnect() void {
    shared.wifi_force_disconnect = true;
}

/// Get Net has-IP state (0 or 1)
export fn getNetHasIp() u32 {
    return if (shared.net_has_ip) 1 else 0;
}

/// Get Net IP address as packed u32: (a<<24)|(b<<16)|(c<<8)|d
export fn getNetIp() u32 {
    return (@as(u32, shared.net_ip[0]) << 24) |
        (@as(u32, shared.net_ip[1]) << 16) |
        (@as(u32, shared.net_ip[2]) << 8) |
        @as(u32, shared.net_ip[3]);
}

// ============================================================================
// BLE state exports (WASM → JS reads, JS → WASM writes)
// ============================================================================

/// Get BLE state (u8 mapping to hal.ble.State enum)
export fn getBleState() u32 {
    return @as(u32, shared.ble_state);
}

/// Get BLE connected flag
export fn getBleConnected() u32 {
    return if (shared.ble_connected) 1 else 0;
}

/// Simulate a BLE peer connecting (JS → WASM)
export fn bleSimConnect() void {
    shared.ble_sim_connect = true;
}

/// Simulate a BLE peer disconnecting (JS → WASM)
export fn bleSimDisconnect() void {
    shared.ble_sim_disconnect = true;
}

// ============================================================================
// App init/step generation
// ============================================================================

/// Generate standard WASM exports for an app module.
///
/// The app module must provide:
/// - `fn init() void`
/// - `fn step() void`
///
/// This creates the `init` and `step` exports that the JS shell calls.
pub fn exportAll(comptime App: type) void {
    // Force all accessor exports to be included in the WASM binary
    _ = &buttonPress;
    _ = &buttonRelease;
    _ = &powerPress;
    _ = &powerRelease;
    _ = &setTime;
    _ = &setAdcValue;
    _ = &getLedCount;
    _ = &getLedColor;
    _ = &getDisplayFbPtr;
    _ = &getDisplayFbSize;
    _ = &getDisplayWidth;
    _ = &getDisplayHeight;
    _ = &getDisplayDirty;
    _ = &clearDisplayDirty;
    _ = &getLogCount;
    _ = &getLogDirty;
    _ = &clearLogDirty;
    _ = &getLogLinePtr;
    _ = &getLogLineLen;

    // Audio
    _ = &getAudioOutPtr;
    _ = &getAudioOutSize;
    _ = &getAudioOutWrite;
    _ = &getAudioOutRead;
    _ = &setAudioOutRead;
    _ = &getAudioInPtr;
    _ = &getAudioInSize;
    _ = &getAudioInWrite;
    _ = &getAudioInRead;
    _ = &pushAudioInSample;

    // BLE
    _ = &getBleState;
    _ = &getBleConnected;
    _ = &bleSimConnect;
    _ = &bleSimDisconnect;

    // WiFi / Net
    _ = &getWifiConnected;
    _ = &getWifiSsidPtr;
    _ = &getWifiSsidLen;
    _ = &getWifiRssi;
    _ = &setWifiRssi;
    _ = &wifiForceDisconnect;
    _ = &getNetHasIp;
    _ = &getNetIp;

    // Create app-specific exports
    const S = struct {
        fn wasmInit() callconv(.c) void {
            shared.start_time_ms = shared.time_ms;
            if (@hasDecl(App, "init")) {
                App.init();
            }
        }

        fn wasmStep() callconv(.c) void {
            if (@hasDecl(App, "step")) {
                App.step();
            }
        }
    };
    @export(&S.wasmInit, .{ .name = "init" });
    @export(&S.wasmStep, .{ .name = "step" });

    // WASI libc requires main(argc, argv). Provide a no-op — JS calls init/step directly.
    const M = struct {
        fn wasmMain(_: c_int, _: [*]const [*]const u8) callconv(.c) c_int {
            return 0;
        }
    };
    @export(&M.wasmMain, .{ .name = "main" });
}
