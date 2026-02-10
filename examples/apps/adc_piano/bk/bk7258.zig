//! BK7258 Board Configuration for ADC Piano
//!
//! Hardware:
//! - 4 matrix keys (K1-K4) on GPIO 6/7/8 (matrix scan)
//!   K1=GPIO6 (Do), K2=GPIO7 (Re), K3=GPIO8 (Mi), K4=matrix G6→G7 (Fa)
//! - Onboard DAC speaker (8kHz mono)

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const sample_rate: u32 = board.audio.sample_rate;
    pub const pa_enable_gpio: u8 = 0; // No external PA

    extern fn bk_zig_gpio_full_scan() void;
    pub fn debugScan() void {
        bk_zig_gpio_full_scan();
    }
};

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = board.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const pa_switch_spec = struct {
    pub const Driver = board.PaSwitchDriver;
    pub const meta = .{ .id = "switch.pa" };
};

pub const speaker_spec = struct {
    pub const Driver = board.SpeakerDriver;
    pub const meta = .{ .id = "speaker.onboard" };
    pub const config = hal.MonoSpeakerConfig{ .sample_rate = Hardware.sample_rate };
};

/// Matrix key driver: 4 keys using GPIO 6/7/8
/// K1 (Do) = GPIO6 direct, K2 (Re) = GPIO7 direct,
/// K3 (Mi) = GPIO8 direct, K4 (Fa) = GPIO6→GPIO7 matrix
pub const button_matrix_spec = struct {
    // GPIO 6/7/8 matrix (same as key_main.h KEY_S1/S2/S3)
    pub const Driver = board.MatrixKeyDriver(.{ 6, 7, 8 }, 4);
    pub const key_count = 4;
    pub const meta = .{ .id = "buttons.matrix" };
};
