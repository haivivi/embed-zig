//! HAL Board Abstraction (v5)
//!
//! Automatically manages HAL peripherals, drivers, and event queue.
//!
//! ## Required Fields
//!
//! Every board spec MUST have:
//! - `rtc` (RtcReader) - time source
//! - `log` - logging type (info/err/warn/debug methods)
//! - `time` - time type (sleepMs/getTimeMs methods)
//! - `isRunning` - run check function: fn() bool
//!
//! ## Optional Traits
//!
//! - `socket` - socket type (tcp/udp/send/recv methods) for network operations
//!
//! Optional peripherals: buttons, rgb_leds, led, temp, kvs, mic, wifi, etc.
//!
//! ## Minimal platform.zig
//!
//! ```zig
//! const hal = @import("hal");
//! const hw = @import("boards/xxx.zig");
//!
//! const spec = struct {
//!     // Required: time source
//!     pub const rtc = hal.RtcReader(hw.rtc_spec);
//!
//!     // Required: platform primitives
//!     pub const log = hw.log;
//!     pub const time = hw.time;
//!     pub const isRunning = hw.isRunning;
//!
//!     // Optional peripherals
//!     pub const ButtonId = enum(u8) { vol_up, vol_down };
//!     pub const buttons = hal.ButtonGroup(hw.button_spec, ButtonId);
//!     pub const rgb_leds = hal.RgbLedStrip(hw.led_spec);
//! };
//!
//! pub const Board = hal.Board(spec);
//! ```
//!
//! ## app.zig Usage
//!
//! ```zig
//! const platform = @import("platform.zig");
//! const Board = platform.Board;
//! const log = Board.log;
//!
//! pub fn run() void {
//!     var board: Board = undefined;
//!     board.init() catch return;
//!     defer board.deinit();
//!
//!     while (Board.isRunning()) {
//!         // For button apps: board.pollButtons();
//!         while (board.nextEvent()) |event| {
//!             switch (event) {
//!                 .button => |btn| handleButton(btn),
//!                 else => {},
//!             }
//!         }
//!         Board.time.sleepMs(10);
//!     }
//! }
//! ```

const std = @import("std");
const trait = @import("trait");

const button_group_mod = @import("button_group.zig");
const button_mod = @import("button.zig");
const event_mod = @import("event.zig");
const rgb_led_strip_mod = @import("led_strip.zig");
const led_mod = @import("led.zig");
const rtc_mod = @import("rtc.zig");
const wifi_mod = @import("wifi.zig");
const net_mod = @import("net.zig");
const temp_sensor_mod = @import("temp_sensor.zig");
const kvs_mod = @import("kvs.zig");
const mic_mod = @import("mic.zig");
const mono_speaker_mod = @import("mono_speaker.zig");
const switch_mod = @import("switch.zig");
const imu_mod = @import("imu.zig");
const motion_mod = @import("motion.zig");

// ============================================================================
// Simple Queue (Default implementation)
// ============================================================================

pub fn SimpleQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        size: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn trySend(self: *Self, item: T) bool {
            if (self.size >= capacity) return false;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;
            return true;
        }

        pub fn tryReceive(self: *Self) ?T {
            if (self.size == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.size -= 1;
            return item;
        }

        pub fn count(self: *const Self) usize {
            return self.size;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.size == 0;
        }

        pub fn reset(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.size = 0;
        }
    };
}

// ============================================================================
// Spec Analysis
// ============================================================================

const PeripheralKind = enum { button_group, button, rgb_led_strip, led, wifi, net, temp_sensor, kvs, mic, mono_speaker, switch_, imu, motion, unknown };

fn getPeripheralKind(comptime T: type) PeripheralKind {
    if (@typeInfo(T) != .@"struct") return .unknown;
    if (!@hasDecl(T, "_hal_marker")) return .unknown;
    if (button_group_mod.is(T)) return .button_group;
    if (button_mod.is(T)) return .button;
    if (rgb_led_strip_mod.is(T)) return .rgb_led_strip;
    if (led_mod.is(T)) return .led;
    if (wifi_mod.is(T)) return .wifi;
    if (net_mod.is(T)) return .net;
    if (temp_sensor_mod.is(T)) return .temp_sensor;
    if (kvs_mod.is(T)) return .kvs;
    if (mic_mod.is(T)) return .mic;
    if (mono_speaker_mod.is(T)) return .mono_speaker;
    if (switch_mod.is(T)) return .switch_;
    if (imu_mod.is(T)) return .imu;
    if (motion_mod.is(T)) return .motion;
    return .unknown;
}

fn SpecAnalysis(comptime spec: type) type {
    return struct {
        pub const button_group_count = countType(spec, .button_group);
        pub const button_count = countType(spec, .button);
        pub const rgb_led_strip_count = countType(spec, .rgb_led_strip);
        pub const led_count = countType(spec, .led);
        pub const wifi_count = countType(spec, .wifi);
        pub const net_count = countType(spec, .net);
        pub const temp_sensor_count = countType(spec, .temp_sensor);
        pub const kvs_count = countType(spec, .kvs);
        pub const mic_count = countType(spec, .mic);
        pub const mono_speaker_count = countType(spec, .mono_speaker);
        pub const switch_count = countType(spec, .switch_);
        pub const imu_count = countType(spec, .imu);
        pub const motion_count = countType(spec, .motion);
        pub const has_buttons = button_group_count > 0 or button_count > 0;
        pub const ButtonId = extractButtonId(spec);

        // RtcReader type (required) - spec.rtc is already a HAL type
        pub const RtcReaderType = spec.rtc;
        pub const RtcDriverType = RtcReaderType.DriverType;

        fn countType(comptime s: type, comptime kind: PeripheralKind) comptime_int {
            var n: comptime_int = 0;
            for (@typeInfo(s).@"struct".decls) |decl| {
                if (@hasDecl(s, decl.name)) {
                    const F = @TypeOf(@field(s, decl.name));
                    if (@typeInfo(F) == .type) {
                        if (getPeripheralKind(@field(s, decl.name)) == kind) n += 1;
                    }
                }
            }
            return n;
        }

        fn extractButtonId(comptime s: type) type {
            // First check if spec defines ButtonId directly
            if (@hasDecl(s, "ButtonId")) {
                const F = @TypeOf(@field(s, "ButtonId"));
                if (@typeInfo(F) == .type) {
                    return @field(s, "ButtonId");
                }
            }
            // Then try to extract from ButtonGroup
            for (@typeInfo(s).@"struct".decls) |decl| {
                if (@hasDecl(s, decl.name)) {
                    const F = @TypeOf(@field(s, decl.name));
                    if (@typeInfo(F) == .type) {
                        const T = @field(s, decl.name);
                        if (button_group_mod.is(T)) return T.ButtonIdType;
                    }
                }
            }
            // Default: single button with id 0
            return enum(u8) { default = 0 };
        }
    };
}

// ============================================================================
// Board (v4) - Only needs spec, extracts everything from it
// ============================================================================

/// Create a Board type from spec
///
/// Required fields (all must be HAL/trait types):
/// - rtc: hal.rtc.reader.from(hw.rtc_spec)
/// - log: trait.log.from(hw.log)
/// - time: trait.time.from(hw.time)
/// - meta: .{ .id = "board_name" }
///
/// Optional traits:
/// - socket: TCP/UDP socket type
/// - crypto: Crypto suite (validated via trait.crypto)
/// - cert_store: Certificate store type for TLS
///
/// Optional peripherals: buttons, button, led, rgb_leds, wifi, temp, kvs, mic
pub fn Board(comptime spec: type) type {
    comptime {
        // Verify required: rtc (must be hal.rtc.reader type)
        if (!rtc_mod.reader.is(spec.rtc)) {
            @compileError("spec.rtc must be hal.rtc.reader.from(rtc_spec)");
        }

        // Verify required: log (validates via trait.log.from)
        _ = trait.log.from(spec.log);

        // Verify required: time (validates via trait.time.from)
        _ = trait.time.from(spec.time);

        // Verify required: meta.id
        _ = @as([]const u8, spec.meta.id);

        // Optional: crypto (validates via trait.crypto.from with default required set)
        if (@hasDecl(spec, "crypto")) {
            _ = trait.crypto.from(spec.crypto, .{});
        }

        // Optional: cert_store (just verify it's a type)
        if (@hasDecl(spec, "cert_store")) {
            _ = @as(type, spec.cert_store);
        }
    }

    const analysis = SpecAnalysis(spec);

    // Get Queue implementation from spec or use default
    const QueueImpl = if (@hasDecl(spec, "Queue")) spec.Queue else SimpleQueue;

    // RTC types (required)
    const RtcReaderType = analysis.RtcReaderType;
    const RtcDriverType = analysis.RtcDriverType;

    // Extract types from HAL components in spec (optional)
    const ButtonGroupType = if (analysis.button_group_count > 0) getButtonGroupType(spec) else void;
    const ButtonGroupDriverType = if (analysis.button_group_count > 0) ButtonGroupType.DriverType else void;
    const ButtonType = if (analysis.button_count > 0) getButtonType(spec) else void;
    const ButtonDriverType = if (analysis.button_count > 0) ButtonType.DriverType else void;
    const RgbLedStripType = if (analysis.rgb_led_strip_count > 0) getRgbLedStripType(spec) else void;
    const RgbLedStripDriverType = if (analysis.rgb_led_strip_count > 0) RgbLedStripType.DriverType else void;
    const LedType = if (analysis.led_count > 0) getLedType(spec) else void;
    const LedDriverType = if (analysis.led_count > 0) LedType.DriverType else void;
    const WifiType = if (analysis.wifi_count > 0) getWifiType(spec) else void;
    const WifiDriverType = if (analysis.wifi_count > 0) WifiType.DriverType else void;
    const NetType = if (analysis.net_count > 0) getNetType(spec) else void;
    const NetDriverType = if (analysis.net_count > 0) NetType.DriverType else void;
    const TempSensorType = if (analysis.temp_sensor_count > 0) getTempSensorType(spec) else void;
    const TempSensorDriverType = if (analysis.temp_sensor_count > 0) TempSensorType.DriverType else void;
    const KvsType = if (analysis.kvs_count > 0) getKvsType(spec) else void;
    const KvsDriverType = if (analysis.kvs_count > 0) KvsType.DriverType else void;
    const MicType = if (analysis.mic_count > 0) getMicType(spec) else void;
    const MicDriverType = if (analysis.mic_count > 0) MicType.DriverType else void;
    const MonoSpeakerType = if (analysis.mono_speaker_count > 0) getMonoSpeakerType(spec) else void;
    const MonoSpeakerDriverType = if (analysis.mono_speaker_count > 0) MonoSpeakerType.DriverType else void;
    const SwitchType = if (analysis.switch_count > 0) getSwitchType(spec) else void;
    const SwitchDriverType = if (analysis.switch_count > 0) SwitchType.DriverType else void;
    const ImuType = if (analysis.imu_count > 0) getImuType(spec) else void;
    const ImuDriverType = if (analysis.imu_count > 0) ImuType.DriverType else void;
    const MotionType = if (analysis.motion_count > 0) getMotionType(spec) else void;
    const MotionImuType = if (analysis.motion_count > 0) MotionType.ImuDriverType else void;

    // Generate Event type
    const Event = union(enum) {
        button: if (analysis.has_buttons) ButtonEventPayload(analysis.ButtonId) else void,
        system: event_mod.SystemEvent,
        timer: event_mod.TimerEvent,
        wifi: if (analysis.wifi_count > 0) wifi_mod.WifiEvent else void,
        net: if (analysis.net_count > 0) net_mod.NetEvent else void,
        motion: if (analysis.motion_count > 0) motion_mod.MotionEventPayload else void,
    };

    return struct {
        const Self = @This();

        // ================================================================
        // Exported Types
        // ================================================================

        pub const EventType = Event;
        pub const EventQueueType = QueueImpl(Event, 64);
        pub const ButtonId = analysis.ButtonId;
        pub const ButtonAction = button_mod.ButtonAction;
        pub const ButtonGroup = ButtonGroupType;
        pub const Button = ButtonType;
        pub const RgbLedStrip = RgbLedStripType;
        pub const Led = LedType;
        pub const Wifi = WifiType;
        pub const TempSensor = TempSensorType;
        pub const Kvs = KvsType;
        pub const RtcReader = RtcReaderType;
        pub const Microphone = MicType;
        pub const MonoSpeaker = MonoSpeakerType;
        pub const Switch = SwitchType;
        pub const Imu = ImuType;
        pub const Motion = MotionType;

        // ================================================================
        // Board Metadata
        // ================================================================

        pub const meta = spec.meta;

        // ================================================================
        // Platform Primitives (from spec, wrapped by trait)
        // ================================================================

        pub const log = trait.log.from(spec.log);
        pub const time = trait.time.from(spec.time);

        /// Check if application should continue running
        pub const isRunning = if (@hasDecl(spec, "isRunning"))
            spec.isRunning
        else
            struct {
                fn always() bool {
                    return true;
                }
            }.always;

        /// Socket type (optional - for network operations)
        pub const socket = if (@hasDecl(spec, "socket"))
            trait.socket.from(spec.socket)
        else
            void;

        /// Crypto type (optional - for TLS/crypto operations)
        pub const crypto = if (@hasDecl(spec, "crypto")) spec.crypto else void;

        /// Certificate store type (optional - for TLS certificate verification)
        pub const cert_store = if (@hasDecl(spec, "cert_store")) spec.cert_store else void;

        /// Network impl module (optional - for static convenience functions like getDns)
        /// Use board.net (instance) for HAL wrapper methods
        pub const net_impl = if (@hasDecl(spec, "net_impl")) spec.net_impl else void;

        // ================================================================
        // Fields
        // ================================================================

        // Event queue
        events: QueueImpl(Event, 64),

        // RTC (required - provides time source)
        rtc_driver: RtcDriverType,
        rtc: RtcReaderType,

        // ButtonGroup (if present)
        buttons_driver: if (analysis.button_group_count > 0) ButtonGroupDriverType else void,
        buttons: if (analysis.button_group_count > 0) ButtonGroupType else void,

        // Button (if present)
        button_driver: if (analysis.button_count > 0) ButtonDriverType else void,
        button: if (analysis.button_count > 0) ButtonType else void,

        // RgbLedStrip (if present)
        rgb_leds_driver: if (analysis.rgb_led_strip_count > 0) RgbLedStripDriverType else void,
        rgb_leds: if (analysis.rgb_led_strip_count > 0) RgbLedStripType else void,

        // Led (if present)
        led_driver: if (analysis.led_count > 0) LedDriverType else void,
        led: if (analysis.led_count > 0) LedType else void,

        // Wifi (if present)
        wifi_driver: if (analysis.wifi_count > 0) WifiDriverType else void,
        wifi: if (analysis.wifi_count > 0) WifiType else void,

        // Net (if present)
        net_driver: if (analysis.net_count > 0) NetDriverType else void,
        net: if (analysis.net_count > 0) NetType else void,

        // TempSensor (if present)
        temp_driver: if (analysis.temp_sensor_count > 0) TempSensorDriverType else void,
        temp: if (analysis.temp_sensor_count > 0) TempSensorType else void,

        // Kvs (if present)
        kvs_driver: if (analysis.kvs_count > 0) KvsDriverType else void,
        kvs: if (analysis.kvs_count > 0) KvsType else void,

        // Microphone (if present)
        mic_driver: if (analysis.mic_count > 0) MicDriverType else void,
        mic: if (analysis.mic_count > 0) MicType else void,

        // Mono Speaker (if present)
        speaker_driver: if (analysis.mono_speaker_count > 0) MonoSpeakerDriverType else void,
        speaker: if (analysis.mono_speaker_count > 0) MonoSpeakerType else void,

        // PA Switch (if present)
        pa_switch_driver: if (analysis.switch_count > 0) SwitchDriverType else void,
        pa_switch: if (analysis.switch_count > 0) SwitchType else void,

        // IMU sensor (if present)
        imu_driver: if (analysis.imu_count > 0) ImuDriverType else void,
        imu: if (analysis.imu_count > 0) ImuType else void,

        // Motion detection (if present)
        motion_imu: if (analysis.motion_count > 0) MotionImuType else void,
        motion: if (analysis.motion_count > 0) MotionType else void,

        // ================================================================
        // Lifecycle
        // ================================================================

        /// Initialize board in-place - use this pattern:
        /// ```
        /// var board: Board = undefined;
        /// try board.init();
        /// defer board.deinit();
        /// ```
        pub fn init(self: *Self) !void {
            self.events = QueueImpl(Event, 64).init();

            // Initialize RTC first (required - provides time source)
            self.rtc_driver = try RtcDriverType.init();
            errdefer self.rtc_driver.deinit();

            // Initialize ButtonGroup driver
            if (analysis.button_group_count > 0) {
                self.buttons_driver = try ButtonGroupDriverType.init();
                errdefer self.buttons_driver.deinit();
            }

            // Initialize Button driver
            if (analysis.button_count > 0) {
                self.button_driver = try ButtonDriverType.init();
                errdefer self.button_driver.deinit();
            }

            // Initialize RgbLedStrip driver
            if (analysis.rgb_led_strip_count > 0) {
                self.rgb_leds_driver = try RgbLedStripDriverType.init();
                errdefer {
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Led driver
            if (analysis.led_count > 0) {
                self.led_driver = try LedDriverType.init();
                errdefer {
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Wifi driver
            if (analysis.wifi_count > 0) {
                self.wifi_driver = try WifiDriverType.init();
                errdefer {
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Net driver (with direct callback to push events to board queue)
            if (analysis.net_count > 0) {
                // Use callback-based init if available for direct event push
                if (@hasDecl(NetDriverType, "initWithCallback")) {
                    self.net_driver = try NetDriverType.initWithCallback(
                        netEventCallback,
                        @ptrCast(&self.events),
                    );
                } else {
                    // Fallback to polling mode
                    self.net_driver = try NetDriverType.init();
                }
                errdefer {
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize TempSensor driver
            if (analysis.temp_sensor_count > 0) {
                self.temp_driver = try TempSensorDriverType.init();
                errdefer {
                    if (analysis.net_count > 0) self.net_driver.deinit();
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Kvs driver
            if (analysis.kvs_count > 0) {
                self.kvs_driver = try KvsDriverType.init();
                errdefer {
                    if (analysis.temp_sensor_count > 0) self.temp_driver.deinit();
                    if (analysis.net_count > 0) self.net_driver.deinit();
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Microphone driver
            if (analysis.mic_count > 0) {
                self.mic_driver = try MicDriverType.init();
                errdefer {
                    if (analysis.kvs_count > 0) self.kvs_driver.deinit();
                    if (analysis.temp_sensor_count > 0) self.temp_driver.deinit();
                    if (analysis.net_count > 0) self.net_driver.deinit();
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
                // Call initInPlace if driver supports it (for pointer-based init)
                if (@hasDecl(MicDriverType, "initInPlace")) {
                    try self.mic_driver.initInPlace();
                }
            }

            // Initialize Mono Speaker driver
            if (analysis.mono_speaker_count > 0) {
                self.speaker_driver = try MonoSpeakerDriverType.init();
                errdefer {
                    if (analysis.mic_count > 0) self.mic_driver.deinit();
                    if (analysis.kvs_count > 0) self.kvs_driver.deinit();
                    if (analysis.temp_sensor_count > 0) self.temp_driver.deinit();
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
                // Call initInPlace if driver supports it (for pointer-based init)
                if (@hasDecl(MonoSpeakerDriverType, "initInPlace")) {
                    try self.speaker_driver.initInPlace();
                }
            }

            // Initialize PA Switch driver
            if (analysis.switch_count > 0) {
                self.pa_switch_driver = try SwitchDriverType.init();
                errdefer {
                    if (analysis.mono_speaker_count > 0) self.speaker_driver.deinit();
                    if (analysis.mic_count > 0) self.mic_driver.deinit();
                    if (analysis.kvs_count > 0) self.kvs_driver.deinit();
                    if (analysis.temp_sensor_count > 0) self.temp_driver.deinit();
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize IMU driver
            if (analysis.imu_count > 0) {
                self.imu_driver = try ImuDriverType.init();
                errdefer {
                    if (analysis.switch_count > 0) self.pa_switch_driver.deinit();
                    if (analysis.mono_speaker_count > 0) self.speaker_driver.deinit();
                    if (analysis.mic_count > 0) self.mic_driver.deinit();
                    if (analysis.kvs_count > 0) self.kvs_driver.deinit();
                    if (analysis.temp_sensor_count > 0) self.temp_driver.deinit();
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Motion IMU driver (separate from board.imu for independent sampling)
            if (analysis.motion_count > 0) {
                self.motion_imu = try MotionImuType.init();
                errdefer {
                    if (analysis.imu_count > 0) self.imu_driver.deinit();
                    if (analysis.switch_count > 0) self.pa_switch_driver.deinit();
                    if (analysis.mono_speaker_count > 0) self.speaker_driver.deinit();
                    if (analysis.mic_count > 0) self.mic_driver.deinit();
                    if (analysis.kvs_count > 0) self.kvs_driver.deinit();
                    if (analysis.temp_sensor_count > 0) self.temp_driver.deinit();
                    if (analysis.wifi_count > 0) self.wifi_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize HAL wrappers with driver pointers (now pointing to correct locations)
            self.rtc = RtcReaderType.init(&self.rtc_driver);
            if (analysis.button_group_count > 0) {
                self.buttons = ButtonGroupType.init(&self.buttons_driver, &uptimeWrapper);
                // Register callback for direct event push
                self.buttons.setCallback(buttonEventCallback, @ptrCast(&self.events));
            }
            if (analysis.button_count > 0) {
                self.button = ButtonType.init(&self.button_driver);
            }
            if (analysis.rgb_led_strip_count > 0) {
                self.rgb_leds = RgbLedStripType.init(&self.rgb_leds_driver);
            }
            if (analysis.led_count > 0) {
                self.led = LedType.init(&self.led_driver);
            }
            if (analysis.wifi_count > 0) {
                self.wifi = WifiType.init(&self.wifi_driver);
            }
            if (analysis.net_count > 0) {
                self.net = NetType.init(&self.net_driver);
            }
            if (analysis.temp_sensor_count > 0) {
                self.temp = TempSensorType.init(&self.temp_driver);
            }
            if (analysis.kvs_count > 0) {
                self.kvs = KvsType.init(&self.kvs_driver);
            }
            if (analysis.mic_count > 0) {
                self.mic = MicType.init(&self.mic_driver);
            }
            if (analysis.mono_speaker_count > 0) {
                self.speaker = MonoSpeakerType.init(&self.speaker_driver);
            }
            if (analysis.switch_count > 0) {
                self.pa_switch = SwitchType.init(&self.pa_switch_driver);
            }
            if (analysis.imu_count > 0) {
                self.imu = ImuType.init(&self.imu_driver);
            }
            if (analysis.motion_count > 0) {
                self.motion = MotionType.init(&self.motion_imu, &uptimeWrapper);
                // Register callback for direct event push
                self.motion.setCallback(motionEventCallback, @ptrCast(&self.events));
            }

            // Set static RTC driver for uptimeWrapper (used by ButtonGroup and Motion)
            static_rtc_driver = &self.rtc_driver;
        }

        // Static wrapper for uptime (used by ButtonGroup and Motion)
        var static_rtc_driver: ?*RtcDriverType = null;

        fn uptimeWrapper() u64 {
            if (static_rtc_driver) |drv| {
                return drv.uptime();
            }
            return 0;
        }

        /// Deinitialize board
        pub fn deinit(self: *Self) void {
            // Deinit in reverse order
            if (analysis.motion_count > 0) {
                self.motion_imu.deinit();
            }
            if (analysis.imu_count > 0) {
                self.imu_driver.deinit();
            }
            if (analysis.switch_count > 0) {
                self.pa_switch_driver.deinit();
            }
            if (analysis.mono_speaker_count > 0) {
                self.speaker_driver.deinit();
            }
            if (analysis.mic_count > 0) {
                self.mic_driver.deinit();
            }
            if (analysis.kvs_count > 0) {
                self.kvs_driver.deinit();
            }
            if (analysis.temp_sensor_count > 0) {
                self.temp_driver.deinit();
            }
            if (analysis.net_count > 0) {
                self.net_driver.deinit();
            }
            if (analysis.wifi_count > 0) {
                self.wifi_driver.deinit();
            }
            if (analysis.led_count > 0) {
                self.led.off();
                self.led_driver.deinit();
            }
            if (analysis.rgb_led_strip_count > 0) {
                self.rgb_leds.clear();
                self.rgb_leds_driver.deinit();
            }
            if (analysis.button_count > 0) {
                self.button_driver.deinit();
            }
            if (analysis.button_group_count > 0) {
                self.buttons_driver.deinit();
            }
            self.rtc_driver.deinit();
            self.events.deinit();
            static_rtc_driver = null;
        }

        // ================================================================
        // Event Queue
        // ================================================================

        /// Get next event from the queue.
        /// Also polls WiFi and Net drivers for pending events (push into queue first).
        pub fn nextEvent(self: *Self) ?Event {
            // Poll WiFi driver for events
            if (analysis.wifi_count > 0) {
                if (self.wifi.pollEvent()) |wifi_event| {
                    _ = self.events.trySend(.{ .wifi = wifi_event });
                }
            }
            // Poll Net driver for events (if not using callback mode)
            if (analysis.net_count > 0) {
                if (self.net.pollEvent()) |net_event| {
                    _ = self.events.trySend(.{ .net = net_event });
                }
            }
            return self.events.tryReceive();
        }

        /// Send an event to the queue (thread-safe if using FreeRTOS queue)
        /// This is used by background tasks and callbacks to push events
        pub fn sendEvent(self: *Self, event: Event) bool {
            return self.events.trySend(event);
        }

        /// Check if there are pending events
        pub fn hasEvents(self: *const Self) bool {
            return !self.events.isEmpty();
        }

        /// Get pointer to the event queue (for peripherals that need direct access)
        pub fn getEventQueue(self: *Self) *QueueImpl(Event, 64) {
            return &self.events;
        }

        /// Net event callback for direct push (called from ESP-IDF event context)
        /// This converts driver NetEvent to HAL NetEvent and pushes to board queue
        const NetCallbackType = if (analysis.net_count > 0 and @hasDecl(NetDriverType, "CallbackType"))
            NetDriverType.CallbackType
        else
            *const fn (?*anyopaque, void) void;

        fn netEventCallback(ctx: ?*anyopaque, driver_event: if (analysis.net_count > 0 and @hasDecl(NetDriverType, "EventType")) NetDriverType.EventType else void) void {
            if (analysis.net_count == 0) return;
            if (ctx == null) return;
            const queue: *EventQueueType = @ptrCast(@alignCast(ctx));

            // Convert driver event to HAL NetEvent
            const hal_event: net_mod.NetEvent = switch (driver_event) {
                .dhcp_bound => |data| .{ .dhcp_bound = .{
                    .interface = data.interface,
                    .ip = data.ip,
                    .netmask = data.netmask,
                    .gateway = data.gateway,
                    .dns_main = data.dns_main,
                    .dns_backup = data.dns_backup,
                    .lease_time = data.lease_time,
                } },
                .dhcp_renewed => |data| .{ .dhcp_renewed = .{
                    .interface = data.interface,
                    .ip = data.ip,
                    .netmask = data.netmask,
                    .gateway = data.gateway,
                    .dns_main = data.dns_main,
                    .dns_backup = data.dns_backup,
                    .lease_time = data.lease_time,
                } },
                .ip_lost => |data| .{ .ip_lost = .{
                    .interface = data.interface,
                } },
                .static_ip_set => |data| .{ .static_ip_set = .{
                    .interface = data.interface,
                } },
                .ap_sta_assigned => |data| .{ .ap_sta_assigned = .{
                    .mac = data.mac,
                    .ip = data.ip,
                } },
            };

            // Push to board's event queue
            if (!queue.trySend(.{ .net = hal_event })) {
                log.warn("Event queue full, Net event dropped", .{});
            }
        }

        /// Button event callback for direct push (called from ButtonGroup.poll)
        /// This converts ButtonGroup.Event to Board.Event and pushes to board queue
        fn buttonEventCallback(ctx: ?*anyopaque, btn_event: if (analysis.button_group_count > 0) ButtonGroupType.Event else void) void {
            if (analysis.button_group_count == 0) return;
            if (ctx == null) return;
            const queue: *EventQueueType = @ptrCast(@alignCast(ctx));

            // Convert to Board.Event and push
            if (!queue.trySend(.{ .button = .{
                .source = btn_event.source,
                .id = btn_event.id,
                .action = btn_event.action,
                .timestamp_ms = btn_event.timestamp_ms,
                .click_count = btn_event.click_count,
                .duration_ms = btn_event.duration_ms,
            } })) {
                log.warn("Event queue full, Button event dropped", .{});
            }
        }

        /// Motion event callback for direct push (called from Motion.poll)
        fn motionEventCallback(ctx: ?*anyopaque, motion_event: if (analysis.motion_count > 0) MotionType.Event else void) void {
            if (analysis.motion_count == 0) return;
            if (ctx == null) return;
            const queue: *EventQueueType = @ptrCast(@alignCast(ctx));

            // Push directly - MotionEventPayload is the same type
            if (!queue.trySend(.{ .motion = motion_event })) {
                log.warn("Event queue full, Motion event dropped", .{});
            }
        }

        // ================================================================
        // Time (via RTC)
        // ================================================================

        /// Get monotonic uptime in milliseconds
        pub fn uptime(self: *Self) u64 {
            return self.rtc.uptime();
        }

        /// Get wall-clock time (if synced)
        pub fn now(self: *Self) ?rtc_mod.Timestamp {
            return self.rtc.now();
        }
    };
}

// ============================================================================
// Type Helpers
// ============================================================================

fn getButtonGroupType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (button_group_mod.is(T)) return T;
            }
        }
    }
    @compileError("No ButtonGroup found in spec");
}

fn getButtonType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (button_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Button found in spec");
}

fn getRgbLedStripType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (rgb_led_strip_mod.is(T)) return T;
            }
        }
    }
    @compileError("No RgbLedStrip found in spec");
}

fn getLedType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (led_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Led found in spec");
}

fn getWifiType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (wifi_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Wifi found in spec");
}

fn getNetType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (net_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Net found in spec");
}

fn getTempSensorType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (temp_sensor_mod.is(T)) return T;
            }
        }
    }
    @compileError("No TempSensor found in spec");
}

fn getKvsType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (kvs_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Kvs found in spec");
}

fn getMicType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (mic_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Microphone found in spec");
}

fn getMonoSpeakerType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (mono_speaker_mod.is(T)) return T;
            }
        }
    }
    @compileError("No MonoSpeaker found in spec");
}

fn getSwitchType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (switch_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Switch found in spec");
}

fn getImuType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (imu_mod.is(T)) return T;
            }
        }
    }
    @compileError("No IMU found in spec");
}

fn getMotionType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (motion_mod.is(T)) return T;
            }
        }
    }
    @compileError("No Motion found in spec");
}

fn ButtonEventPayload(comptime ButtonId: type) type {
    return struct {
        source: []const u8,
        id: ButtonId,
        action: button_mod.ButtonAction,
        timestamp_ms: u64,
        click_count: u8 = 1,
        duration_ms: u32 = 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "SimpleQueue basic operations" {
    var q = SimpleQueue(u32, 4).init();

    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.trySend(1));
    try std.testing.expect(q.trySend(2));
    try std.testing.expect(!q.isEmpty());
    try std.testing.expectEqual(@as(usize, 2), q.count());

    try std.testing.expectEqual(@as(?u32, 1), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, 2), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, null), q.tryReceive());
}

test "SimpleQueue overflow" {
    var q = SimpleQueue(u32, 2).init();

    try std.testing.expect(q.trySend(1));
    try std.testing.expect(q.trySend(2));
    try std.testing.expect(!q.trySend(3)); // Should fail - full

    try std.testing.expectEqual(@as(?u32, 1), q.tryReceive());
    try std.testing.expect(q.trySend(3)); // Now should work
}

test "SpecAnalysis with rtc only" {
    const MockRtcDriver = struct {
        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn uptime(_: *@This()) u64 {
            return 0;
        }
        pub fn nowMs(_: *@This()) ?i64 {
            return null;
        }
    };

    const rtc_spec = struct {
        pub const Driver = MockRtcDriver;
        pub const meta = .{ .id = "rtc" };
    };

    const MockLog = struct {
        pub fn info(comptime _: []const u8, _: anytype) void {}
        pub fn err(comptime _: []const u8, _: anytype) void {}
        pub fn warn(comptime _: []const u8, _: anytype) void {}
        pub fn debug(comptime _: []const u8, _: anytype) void {}
    };

    const MockTime = struct {
        pub fn sleepMs(_: u32) void {}
        pub fn getTimeMs() u64 {
            return 0;
        }
    };

    const minimal_spec = struct {
        pub const meta = .{ .id = "test.board" };
        pub const rtc = rtc_spec;
        pub const log = MockLog;
        pub const time = MockTime;
    };
    const analysis = SpecAnalysis(minimal_spec);

    try std.testing.expectEqual(@as(comptime_int, 0), analysis.button_group_count);
    try std.testing.expectEqual(@as(comptime_int, 0), analysis.button_count);
    try std.testing.expectEqual(@as(comptime_int, 0), analysis.rgb_led_strip_count);
    try std.testing.expectEqual(@as(comptime_int, 0), analysis.wifi_count);
    try std.testing.expect(!analysis.has_buttons);
}
