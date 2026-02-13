//! Hardware Definition & Drivers: GoCool 改版立创实战派 ESP32-S3 (LiChuang GoCool)
//!
//! Based on the LiChuang ShiZhanPai (lichuang_szp) board with GoCool modifications.
//! Currently shares the same pin configuration as lichuang_szp.
//!
//! TODO: GoCool 板增加了一个额外按键，需要确认 GPIO 并添加驱动支持。
//!
//! Key features:
//! - ESP32-S3 with 16MB Flash, 8MB Octal PSRAM
//! - ES7210 (4-ch ADC) + ES8311 (DAC) audio codec
//! - PCA9557 I2C GPIO expander (PA_EN, LCD_CS, DVP_PWDN)
//! - QMI8658 6-axis IMU
//! - 320x240 SPI LCD
//! - MicroSD card slot
//!
//! Usage:
//!   const board = @import("esp").boards.lichuang_gocool;
//!   pub const ButtonDriver = board.BootButtonDriver;
//!   pub const WifiDriver = board.WifiDriver;

const std = @import("std");
const idf = @import("idf");
const impl = @import("impl");
const hal = @import("hal");
const audio_drivers = @import("audio_drivers");
const io_drivers = @import("io_drivers");
const imu_drivers = @import("imu_drivers");
const drivers = struct {
    pub const Es7210 = audio_drivers.es7210.Es7210;
    pub const Es8311 = audio_drivers.es8311.Es8311;
    pub const Qmi8658 = imu_drivers.qmi8658.Qmi8658;
    pub const Tca9554 = io_drivers.tca9554.Tca9554;
    pub const Tca9554Pin = io_drivers.tca9554.Pin;
};

// ============================================================================
// Thread-safe Queue (for HAL event queue)
// ============================================================================

/// FreeRTOS-based thread-safe queue for multi-task event handling
pub const Queue = idf.Queue;

// ============================================================================
// Board Identification
// ============================================================================

/// Board name
pub const name = "LiChuang-GoCool-ESP32S3";

/// Serial port for flashing (USB-JTAG built-in)
pub const serial_port = "/dev/cu.usbmodem1101";

// ============================================================================
// WiFi Configuration
// ============================================================================

/// WiFi driver implementation
pub const wifi = impl.wifi;
pub const WifiDriver = wifi.WifiDriver;

/// WiFi spec for HAL
pub const wifi_spec = wifi.wifi_spec;

// ============================================================================
// Net Configuration
// ============================================================================

/// Network interface driver implementation
pub const net = impl.net;
pub const NetDriver = net.NetDriver;

/// Net spec for HAL
pub const net_spec = net.net_spec;

// ============================================================================
// Crypto Configuration
// ============================================================================

/// Crypto implementation (mbedTLS-based)
pub const crypto = impl.crypto.Suite;

// ============================================================================
// I2C Configuration
// ============================================================================

/// I2C SDA GPIO
pub const i2c_sda: u8 = 1;

/// I2C SCL GPIO
pub const i2c_scl: u8 = 2;

/// I2C frequency (Hz)
pub const i2c_freq_hz: u32 = 100_000;

// ============================================================================
// I2S Audio Configuration
// ============================================================================

/// Audio sample rate (Hz)
pub const sample_rate: u32 = 16000;

/// I2S port
pub const i2s_port: u8 = 0;

/// I2S pins
pub const i2s_mclk: u8 = 38;
pub const i2s_bclk: u8 = 14;
pub const i2s_ws: u8 = 13;
pub const i2s_dout: u8 = 45; // Speaker output (ES8311)
pub const i2s_din: u8 = 12; // Mic input (ES7210)

// ============================================================================
// Audio Codec I2C Addresses
// ============================================================================

/// ES8311 DAC I2C address
pub const es8311_addr: u8 = 0x18;

/// ES7210 ADC I2C address
pub const es7210_addr: u8 = 0x41;

// ============================================================================
// PCA9557 GPIO Expander Configuration
// ============================================================================

/// PCA9557 I2C address
pub const pca9557_addr: u7 = 0x19;

/// PCA9557 pin assignments
pub const pca9557_lcd_cs: u8 = 0; // IO0: LCD chip select
pub const pca9557_pa_en: u8 = 1; // IO1: Power amplifier enable
pub const pca9557_dvp_pwdn: u8 = 2; // IO2: Camera power down

// ============================================================================
// QMI8658 IMU Configuration
// ============================================================================

/// QMI8658 I2C address
pub const qmi8658_addr: u7 = 0x6A;

/// QMI8658 driver type (requires I2C and Time interfaces)
const Qmi8658ImuDriver = drivers.Qmi8658(*idf.I2c, impl.time.Time);

/// IMU driver for HAL integration
/// Wraps QMI8658 and provides the interface expected by hal.imu
pub const ImuDriver = struct {
    const Self = @This();

    inner: Qmi8658ImuDriver = undefined,
    i2c: ?*idf.I2c = null,
    initialized: bool = false,

    pub fn init() !Self {
        return Self{};
    }

    /// Initialize with external I2C bus
    pub fn initWithI2c(self: *Self, i2c: *idf.I2c) !void {
        if (self.initialized) return;

        self.i2c = i2c;
        self.inner = Qmi8658ImuDriver.init(i2c, .{
            .address = qmi8658_addr,
            .accel_range = .@"4g",
            .gyro_range = .@"512dps",
            .accel_odr = .@"125Hz",
            .gyro_odr = .@"125Hz",
        });

        try self.inner.open();
        log.info("ImuDriver: QMI8658 @ 0x{x} initialized", .{qmi8658_addr});
        self.initialized = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.inner.close() catch {};
            self.initialized = false;
        }
    }

    /// Read accelerometer data in g (required by hal.imu)
    pub fn readAccel(self: *Self) !hal.AccelData {
        if (!self.initialized) return error.NotInitialized;

        const data = try self.inner.readScaled();
        return .{
            .x = data.acc_x,
            .y = data.acc_y,
            .z = data.acc_z,
        };
    }

    /// Read gyroscope data in dps (required by hal.imu for has_gyro)
    pub fn readGyro(self: *Self) !hal.GyroData {
        if (!self.initialized) return error.NotInitialized;

        const data = try self.inner.readScaled();
        return .{
            .x = data.gyr_x,
            .y = data.gyr_y,
            .z = data.gyr_z,
        };
    }

    /// Read angles (optional, for convenience)
    pub fn readAngles(self: *Self) !struct { roll: f32, pitch: f32 } {
        if (!self.initialized) return error.NotInitialized;

        const angles = try self.inner.readAngles();
        return .{ .roll = angles.roll, .pitch = angles.pitch };
    }

    /// Read temperature
    pub fn readTemperature(self: *Self) !f32 {
        if (!self.initialized) return error.NotInitialized;
        return self.inner.readTemperature();
    }

    /// Check if data is ready
    pub fn isDataReady(self: *Self) !bool {
        if (!self.initialized) return false;
        return self.inner.isDataReady();
    }
};

/// IMU spec for HAL
pub const imu_spec = struct {
    pub const Driver = ImuDriver;
    pub const meta = .{ .id = "imu.qmi8658" };
};

// ============================================================================
// LCD Configuration (SPI)
// ============================================================================

/// LCD resolution
pub const lcd_width: u16 = 320;
pub const lcd_height: u16 = 240;

/// LCD SPI pins
pub const lcd_mosi: u8 = 40;
pub const lcd_clk: u8 = 41;
pub const lcd_dc: u8 = 39;
pub const lcd_backlight: u8 = 42;

// ============================================================================
// SD Card Configuration (SDMMC)
// ============================================================================

/// SD card pins
pub const sd_cmd: u8 = 48;
pub const sd_clk: u8 = 47;
pub const sd_dat0: u8 = 21;

// ============================================================================
// GPIO Definitions
// ============================================================================

/// BOOT button GPIO
pub const boot_button_gpio: u8 = 0;

// ============================================================================
// Platform Helpers
// ============================================================================

pub const log = std.log.scoped(.board);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }
    pub fn nowMs() u64 {
        return idf.time.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
}

// ============================================================================
// Audio System (via generic audio_system module)
// ============================================================================

const audio_system = @import("impl").audio_system;

/// Base AudioSystem type with board-specific configuration
/// I2C is managed externally and passed to AudioSystem.init()
const BaseAudioSystem = audio_system.AudioSystem(.{
    .i2s_port = i2s_port,
    .i2s_bclk = i2s_bclk,
    .i2s_ws = i2s_ws,
    .i2s_din = i2s_din,
    .i2s_dout = i2s_dout,
    .i2s_mclk = i2s_mclk,
    .sample_rate = sample_rate,
    .es8311_addr = es8311_addr,
    .es8311_volume = 220, // LiChuang uses higher volume
    .es7210_addr = es7210_addr,
    .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true },
});

// ============================================================================
// TCA9554/PCA9557 GPIO Expander Driver
// ============================================================================

/// TCA9554/PCA9557 GPIO expander driver type (compatible, same register set)
const Tca9554Driver = drivers.Tca9554(*idf.I2c);

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.time.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// Boot Button Driver (GPIO0)
// ============================================================================

pub const BootButtonDriver = struct {
    const Self = @This();
    const gpio = idf.gpio;

    initialized: bool = false,

    pub fn init() !Self {
        try gpio.configInput(boot_button_gpio, true); // with pull-up
        log.info("BootButtonDriver: GPIO{} initialized", .{boot_button_gpio});
        return Self{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
    }

    /// Returns true if button is pressed (active low)
    pub fn isPressed(_: *const Self) bool {
        return idf.gpio.getLevel(boot_button_gpio) == 0;
    }
};

// ============================================================================
// PA Switch Driver (via PCA9557/TCA9554 compatible GPIO expander)
// ============================================================================

pub const PaSwitchDriver = struct {
    const Self = @This();
    const Pin = drivers.Tca9554Pin;
    const PA_EN_PIN: Pin = @enumFromInt(pca9557_pa_en);

    is_on: bool = false,
    gpio: Tca9554Driver = undefined,

    /// Initialize PA switch driver with external I2C bus
    pub fn init(i2c: *idf.I2c) !Self {
        var self = Self{};

        // Initialize PCA9557 GPIO expander driver (compatible with TCA9554)
        self.gpio = Tca9554Driver.init(i2c, pca9557_addr);

        // Sync current state from device
        self.gpio.syncFromDevice() catch return error.GpioInitFailed;

        // Configure PA_EN pin as output with initial low (PA off)
        self.gpio.configureOutput(PA_EN_PIN, .low) catch return error.GpioInitFailed;

        log.info("PaSwitchDriver: PCA9557 @ 0x{x} initialized via driver", .{pca9557_addr});
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.is_on) self.off() catch |err| log.warn("PA off failed in deinit: {}", .{err});
        // I2C is managed externally, don't deinit here
    }

    pub fn on(self: *Self) !void {
        try self.gpio.setHigh(PA_EN_PIN);
        self.is_on = true;
        log.info("PA enabled", .{});
    }

    pub fn off(self: *Self) !void {
        try self.gpio.setLow(PA_EN_PIN);
        self.is_on = false;
    }

    pub fn isOn(self: *Self) bool {
        return self.is_on;
    }
};

// ============================================================================
// Speaker Driver (standalone, without AEC)
// ============================================================================

/// ES8311 DAC driver type for standalone speaker
const Es8311Driver = drivers.Es8311(*idf.I2c);

/// ESP Speaker type using ES8311
const EspSpeaker = idf.Speaker(Es8311Driver);

/// Standalone speaker driver for speaker-only applications (no AEC/mic)
/// Uses external I2C and I2S instances for flexibility
pub const SpeakerDriver = struct {
    const Self = @This();

    dac: Es8311Driver = undefined,
    speaker: EspSpeaker = undefined,
    initialized: bool = false,

    pub fn init() !Self {
        return Self{};
    }

    /// Initialize speaker using shared I2S and I2C
    pub fn initWithShared(self: *Self, i2c: *idf.I2c, i2s: *idf.I2s) !void {
        if (self.initialized) return;

        // Initialize ES8311 DAC via shared I2C
        self.dac = Es8311Driver.init(i2c, .{
            .address = es8311_addr,
            .codec_mode = .dac_only,
        });

        try self.dac.open();
        errdefer self.dac.close() catch {};

        try self.dac.setSampleRate(sample_rate);

        // Initialize speaker using shared I2S
        self.speaker = try EspSpeaker.init(&self.dac, i2s, .{
            .initial_volume = 200, // Higher volume for this board
        });
        errdefer self.speaker.deinit();

        log.info("SpeakerDriver: ES8311 + shared I2S initialized", .{});
        self.initialized = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.speaker.deinit();
            self.dac.close() catch {};
            self.initialized = false;
        }
    }

    pub fn write(self: *Self, buffer: []const i16) !usize {
        if (!self.initialized) return error.NotInitialized;
        return self.speaker.write(buffer);
    }

    pub fn setVolume(self: *Self, volume: u8) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.speaker.setVolume(volume);
    }
};

// ============================================================================
// LCD Backlight Driver (as LED substitute)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();
    pub const Color = hal.Color;

    const gpio = idf.gpio;

    initialized: bool = false,
    brightness: u8 = 0,

    pub fn init() !Self {
        try gpio.configOutput(lcd_backlight);
        try gpio.setLevel(lcd_backlight, 0);
        log.info("LedDriver: LCD backlight @ GPIO{} initialized", .{lcd_backlight});
        return Self{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            gpio.setLevel(lcd_backlight, 0) catch |err| log.warn("LCD backlight off failed: {}", .{err});
            self.initialized = false;
        }
    }

    /// Set pixel color - maps brightness to backlight on/off
    pub fn setPixel(self: *Self, index: u32, color: Color) void {
        if (index > 0 or !self.initialized) return;

        const brightness = @max(color.r, @max(color.g, color.b));
        self.brightness = brightness;

        // Simple on/off control (threshold at 30)
        const level: u1 = if (brightness >= 30) 1 else 0;
        gpio.setLevel(lcd_backlight, level) catch {};
    }

    pub fn getPixelCount(_: *Self) u32 {
        return 1;
    }

    pub fn refresh(_: *Self) void {
        // No-op: GPIO updates are synchronous
    }

    pub fn clear(self: *Self) void {
        if (self.initialized) {
            gpio.setLevel(lcd_backlight, 0) catch {};
            self.brightness = 0;
        }
    }

    /// Set backlight directly
    pub fn setBacklight(self: *Self, on: bool) void {
        if (self.initialized) {
            gpio.setLevel(lcd_backlight, if (on) 1 else 0) catch {};
            self.brightness = if (on) 255 else 0;
        }
    }
};

// ============================================================================
// Temperature Sensor Driver (Internal)
// ============================================================================

pub const TempSensorDriver = struct {
    const Self = @This();

    sensor: idf.adc.TempSensor,
    enabled: bool = false,

    pub fn init() !Self {
        var sensor = try idf.adc.TempSensor.init(.{
            .range = .{ .min = -10, .max = 80 },
        });
        try sensor.enable();
        log.info("TempSensorDriver: Internal sensor initialized", .{});
        return Self{ .sensor = sensor, .enabled = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.enabled) {
            self.sensor.disable() catch {};
        }
        self.sensor.deinit();
    }

    pub fn enable(self: *Self) !void {
        if (!self.enabled) {
            try self.sensor.enable();
            self.enabled = true;
        }
    }

    pub fn disable(self: *Self) !void {
        if (self.enabled) {
            try self.sensor.disable();
            self.enabled = false;
        }
    }

    pub fn readCelsius(self: *Self) !f32 {
        if (!self.enabled) {
            try self.enable();
        }
        return self.sensor.readCelsius();
    }
};

// ============================================================================
// Audio System (re-export from generic audio_system)
// ============================================================================

/// AudioSystem manages the complete audio subsystem for LiChuang SZP.
/// Uses the generic AudioSystem with board-specific configuration.
///
/// Usage with shared I2C (recommended):
/// ```
/// var i2c = try idf.I2c.init(.{ .sda = i2c_sda, .scl = i2c_scl, .freq_hz = i2c_freq_hz });
/// var audio = try AudioSystem.initWithI2c(&i2c);
/// var pa = try PaSwitchDriver.init(&i2c);
/// ```
pub const AudioSystem = BaseAudioSystem;

