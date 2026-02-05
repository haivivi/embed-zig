//! LiChuang SZP Board Configuration for Speaker Test
//!
//! Uses pre-configured drivers from esp.boards.lichuang_szp
//! Note: Speaker-only test uses standalone I2S (no AEC/mic)

const std = @import("std");

const drivers = @import("drivers");
const esp = @import("esp");
const idf = esp.idf;
const board = esp.boards.lichuang_szp;
pub const time = board.time;
const I2c = idf.I2c;
const I2s = idf.I2s;
pub const RtcDriver = board.RtcDriver;
pub const PaSwitchDriver = board.PaSwitchDriver;
const hal = @import("hal");

// Re-export platform primitives
pub const log = std.log.scoped(.app);
pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// Hardware Info (re-export from central board)
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const sample_rate: u32 = board.sample_rate;

    // I2C pins
    pub const i2c_sda: u8 = board.i2c_sda;
    pub const i2c_scl: u8 = board.i2c_scl;

    // I2S pins for speaker
    pub const i2s_port: u8 = board.i2s_port;
    pub const i2s_bclk: u8 = board.i2s_bclk;
    pub const i2s_ws: u8 = board.i2s_ws;
    pub const i2s_dout: u8 = board.i2s_dout;
    pub const i2s_mclk: u8 = board.i2s_mclk;

    // PA enable (via I2C GPIO expander PCA9557, pin 1)
    pub const pa_enable_gpio: u8 = 0xFF; // Virtual: controlled via I2C

    // ES8311 I2C address
    pub const es8311_addr: u7 = board.es8311_addr;
};

// ============================================================================
// Type aliases for standalone speaker (no AEC)
// ============================================================================

const Es8311 = drivers.Es8311(*I2c);
const EspSpeaker = idf.Speaker(Es8311);

// ============================================================================
// RTC Driver (re-export)
// ============================================================================

// ============================================================================
// PA Switch Driver (re-export)
// ============================================================================

// ============================================================================
// Speaker Driver (standalone, uses idf.Speaker for speaker-only test)
// ============================================================================

pub const SpeakerDriver = struct {
    const Self = @This();

    dac: Es8311,
    speaker: EspSpeaker,
    initialized: bool = false,

    pub fn init() !Self {
        return Self{
            .dac = undefined,
            .speaker = undefined,
            .initialized = false,
        };
    }

    /// Initialize speaker using shared I2S and I2C
    pub fn initWithShared(self: *Self, i2c: *I2c, i2s: *I2s) !void {
        if (self.initialized) return;

        // Initialize ES8311 DAC via shared I2C
        self.dac = Es8311.init(i2c, .{
            .address = Hardware.es8311_addr,
            .codec_mode = .dac_only,
        });

        try self.dac.open();
        errdefer self.dac.close() catch {};

        try self.dac.setSampleRate(Hardware.sample_rate);

        // Initialize speaker using shared I2S
        self.speaker = try EspSpeaker.init(&self.dac, i2s, .{
            .initial_volume = 200, // Higher volume for this board
        });
        errdefer self.speaker.deinit();

        std.log.info("SpeakerDriver: ES8311 + shared I2S initialized", .{});
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
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const pa_switch_spec = struct {
    pub const Driver = PaSwitchDriver;
    pub const meta = .{ .id = "switch.pa" };
};

pub const speaker_spec = struct {
    pub const Driver = SpeakerDriver;
    pub const meta = .{ .id = "speaker.es8311" };
    pub const config = hal.MonoSpeakerConfig{
        .sample_rate = Hardware.sample_rate,
    };
};
