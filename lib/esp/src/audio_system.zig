//! Generic Audio System with AEC
//!
//! Provides a unified audio subsystem for ESP32 boards with ES8311 DAC and ES7210 ADC.
//! Supports Acoustic Echo Cancellation (AEC) for voice applications.
//!
//! ## Usage
//!
//! In your board file:
//! ```zig
//! const audio_system = @import("audio_system");
//!
//! pub const AudioSystem = audio_system.AudioSystem(.{
//!     .i2c_sda = 17,
//!     .i2c_scl = 18,
//!     .i2s_bclk = 9,
//!     .i2s_ws = 45,
//!     .i2s_din = 10,
//!     .i2s_dout = 8,
//!     .i2s_mclk = 16,
//!     .es8311_addr = 0x18,
//!     .es7210_addr = 0x40,
//! });
//! ```
//!
//! Then in your application:
//! ```zig
//! var audio = try AudioSystem.init();
//! defer audio.deinit();
//!
//! const samples = try audio.readMic(&buffer);
//! try audio.writeSpeaker(&output);
//! ```

const std = @import("std");
const idf = @import("idf");
const drivers = @import("drivers");

const log = std.log.scoped(.audio_system);

// ============================================================================
// C Helper Functions (from lib/esp/idf)
// ============================================================================

extern fn i2s_helper_init_std_duplex(port: c_int, sample_rate_arg: u32, bits_per_sample: c_int, bclk_pin: c_int, ws_pin: c_int, din_pin: c_int, dout_pin: c_int, mclk_pin: c_int) c_int;
extern fn i2s_helper_deinit(port: c_int) c_int;
extern fn i2s_helper_enable_rx(port: c_int) c_int;
extern fn i2s_helper_enable_tx(port: c_int) c_int;
extern fn i2s_helper_read(port: c_int, buffer: [*]u8, buffer_size: usize, bytes_read: *usize, timeout_ms: u32) c_int;
extern fn i2s_helper_write(port: c_int, buffer: [*]const u8, buffer_size: usize, bytes_written: *usize, timeout_ms: u32) c_int;

const AecHandle = opaque {};
extern fn aec_helper_create(input_format: [*:0]const u8, filter_length: c_int, aec_type: c_int, mode: c_int) ?*AecHandle;
extern fn aec_helper_process(handle: *AecHandle, indata: [*]const i16, outdata: [*]i16) c_int;
extern fn aec_helper_get_chunksize(handle: *AecHandle) c_int;
extern fn aec_helper_get_total_channels(handle: *AecHandle) c_int;
extern fn aec_helper_destroy(handle: *AecHandle) void;

// ============================================================================
// Audio System Configuration
// ============================================================================

/// Configuration for AudioSystem
/// Note: I2C is managed externally and passed to init()
pub const AudioConfig = struct {
    // I2S configuration
    i2s_port: u8 = 0,
    i2s_bclk: u8,
    i2s_ws: u8,
    i2s_din: u8,
    i2s_dout: u8,
    i2s_mclk: u8,
    sample_rate: u32 = 16000,

    // ES8311 DAC configuration
    es8311_addr: u8 = 0x18,
    es8311_volume: u8 = 150,

    // ES7210 ADC configuration
    es7210_addr: u8 = 0x40,
    mic_select: drivers.es7210.MicSelect = .{ .mic1 = true, .mic2 = true, .mic3 = true },
};

// ============================================================================
// Generic Audio System
// ============================================================================

/// Creates an AudioSystem type with the given configuration.
/// The configuration is applied at compile time.
pub fn AudioSystem(comptime config: AudioConfig) type {
    // Driver types
    const Es8311Driver = drivers.Es8311(*idf.I2c);
    const Es7210Driver = drivers.Es7210(*idf.I2c);

    return struct {
        const Self = @This();

        initialized: bool = false,
        aec_handle: ?*AecHandle = null,
        aec_frame_size: usize = 256,

        // Audio codec drivers (I2C is managed externally)
        i2c_ptr: *idf.I2c = undefined,
        es8311: Es8311Driver = undefined,
        es7210: Es7210Driver = undefined,

        // Buffers allocated in PSRAM
        raw_buffer_32: ?[]i32 = null,
        aec_input: ?[]i16 = null,
        aec_output: ?[]i16 = null,
        tx_buffer_32: ?[]i32 = null,

        /// Initialize the audio system with external I2C bus
        /// I2C must be initialized by caller and remains owned by caller
        pub fn init(i2c: *idf.I2c) !Self {
            var self = Self{};
            self.i2c_ptr = i2c;

            log.info("AudioSystem: Init with external I2C", .{});
            log.info("AudioSystem: Init ES8311 (DAC @ 0x{x})", .{config.es8311_addr});
            self.es8311 = Es8311Driver.init(self.i2c_ptr, .{ .address = config.es8311_addr });
            self.es8311.open() catch |err| {
                log.err("ES8311 open failed: {}", .{err});
                return error.CodecInitFailed;
            };

            log.info("AudioSystem: Init ES7210 (ADC @ 0x{x})", .{config.es7210_addr});
            self.es7210 = Es7210Driver.init(self.i2c_ptr, .{
                .address = config.es7210_addr,
                .mic_select = config.mic_select,
            });
            idf.time.sleepMs(10); // Delay after ES8311 init
            self.es7210.open() catch |err| {
                log.err("ES7210 open failed: {}", .{err});
                return error.CodecInitFailed;
            };

            log.info("AudioSystem: Init I2S duplex (MCLK={}, BCLK={}, WS={}, DIN={}, DOUT={})", .{
                config.i2s_mclk, config.i2s_bclk, config.i2s_ws, config.i2s_din, config.i2s_dout,
            });
            if (i2s_helper_init_std_duplex(
                config.i2s_port,
                config.sample_rate,
                32,
                config.i2s_bclk,
                config.i2s_ws,
                config.i2s_din,
                config.i2s_dout,
                config.i2s_mclk,
            ) != 0) {
                return error.I2sInitFailed;
            }
            errdefer _ = i2s_helper_deinit(config.i2s_port);

            _ = i2s_helper_enable_rx(config.i2s_port);
            _ = i2s_helper_enable_tx(config.i2s_port);

            log.info("AudioSystem: Enable ES8311", .{});
            self.es8311.enable(true) catch |err| {
                log.err("ES8311 enable failed: {}", .{err});
                return error.CodecInitFailed;
            };
            self.es8311.setVolume(config.es8311_volume) catch {};

            idf.time.sleepMs(10);

            log.info("AudioSystem: Enable ES7210", .{});
            self.es7210.enable(true) catch |err| {
                log.err("ES7210 enable failed: {}", .{err});
                return error.CodecInitFailed;
            };

            log.info("AudioSystem: Init AEC", .{});
            // "RM" = Reference first, Mic second
            // type=1 (AFE_TYPE_VC), mode=0 (AFE_MODE_LOW_COST)
            // filter_length=2 (smaller = less artifacts but weaker echo cancellation)
            self.aec_handle = aec_helper_create("RM", 2, 1, 0);
            if (self.aec_handle == null) {
                return error.AecInitFailed;
            }
            errdefer if (self.aec_handle) |h| aec_helper_destroy(h);

            self.aec_frame_size = @intCast(aec_helper_get_chunksize(self.aec_handle.?));
            const total_ch: usize = @intCast(aec_helper_get_total_channels(self.aec_handle.?));
            log.info("AudioSystem: AEC frame={}, ch={}", .{ self.aec_frame_size, total_ch });

            // Verify AEC is configured for at least 2 channels (ref + mic)
            // readMic assumes total_ch >= 2 when packing data as "RM" format
            if (total_ch < 2) {
                log.err("AEC total_ch={} < 2, expected at least ref + mic channels", .{total_ch});
                return error.AecConfigInvalid;
            }

            // Allocate buffers in PSRAM
            const allocator = idf.heap.psram;

            self.raw_buffer_32 = allocator.alloc(i32, self.aec_frame_size * 2) catch {
                log.err("Failed to alloc raw_buffer", .{});
                return error.OutOfMemory;
            };
            errdefer if (self.raw_buffer_32) |b| allocator.free(b);

            self.aec_input = allocator.alloc(i16, self.aec_frame_size * total_ch) catch {
                log.err("Failed to alloc aec_input", .{});
                return error.OutOfMemory;
            };
            errdefer if (self.aec_input) |b| allocator.free(b);

            // AEC output needs 16-byte alignment
            self.aec_output = allocator.alignedAlloc(i16, .@"16", self.aec_frame_size) catch {
                log.err("Failed to alloc aec_output", .{});
                return error.OutOfMemory;
            };
            errdefer if (self.aec_output) |b| allocator.free(b);

            self.tx_buffer_32 = allocator.alloc(i32, self.aec_frame_size * 2) catch {
                log.err("Failed to alloc tx_buffer", .{});
                return error.OutOfMemory;
            };

            self.initialized = true;
            log.info("AudioSystem: Ready!", .{});
            return self;
        }

        /// Deinitialize the audio system and free all resources
        pub fn deinit(self: *Self) void {
            if (!self.initialized) return;

            const allocator = idf.heap.psram;
            if (self.aec_handle) |h| {
                aec_helper_destroy(h);
                self.aec_handle = null;
            }
            if (self.raw_buffer_32) |b| allocator.free(b);
            if (self.aec_input) |b| allocator.free(b);
            if (self.aec_output) |b| allocator.free(b);
            if (self.tx_buffer_32) |b| allocator.free(b);
            self.raw_buffer_32 = null;
            self.aec_input = null;
            self.aec_output = null;
            self.tx_buffer_32 = null;
            _ = i2s_helper_deinit(config.i2s_port);
            self.es7210.close() catch |err| log.warn("ES7210 close failed: {}", .{err});
            self.es8311.close() catch |err| log.warn("ES8311 close failed: {}", .{err});
            // I2C is managed externally, don't deinit here
            self.initialized = false;
            log.info("AudioSystem: Deinitialized", .{});
        }

        // ====================================================================
        // Microphone Operations (with AEC)
        // ====================================================================

        /// Read AEC-processed audio from microphone
        /// Returns number of samples read
        ///
        /// I2S data format: L[31:16] = mic1, L[15:0] = ref
        /// AEC input format: "RM" = Reference first, Mic second
        pub fn readMic(self: *Self, buffer: []i16) !usize {
            if (!self.initialized) return error.NotInitialized;

            const aec_handle = self.aec_handle orelse return error.NoAec;
            const raw_buf = self.raw_buffer_32 orelse return error.NoBuffer;
            const aec_in = self.aec_input orelse return error.NoBuffer;
            const aec_out = self.aec_output orelse return error.NoBuffer;
            const frame_size = self.aec_frame_size;

            const to_read = frame_size * 2 * @sizeOf(i32);
            var bytes_read: usize = 0;
            const raw_bytes = std.mem.sliceAsBytes(raw_buf[0 .. frame_size * 2]);
            const ret = i2s_helper_read(config.i2s_port, raw_bytes.ptr, to_read, &bytes_read, 1000);

            if (ret != 0) {
                log.warn("i2s read failed with code: {}", .{ret});
                return error.ReadFailed;
            }
            if (bytes_read == 0) {
                return 0;
            }

            const frames_read = bytes_read / @sizeOf(i32) / 2;

            // Extract MIC1 and REF - pack as "RM" (ref first, mic second)
            // I2S format: L[31:16] = mic1, L[15:0] = ref
            for (0..frames_read) |i| {
                const L = raw_buf[i * 2];
                const mic1: i16 = @truncate(L >> 16);
                const ref: i16 = @truncate(L & 0xFFFF);
                aec_in[i * 2 + 0] = ref; // Reference first
                aec_in[i * 2 + 1] = mic1; // Mic second
            }

            // Run AEC
            _ = aec_helper_process(aec_handle, aec_in.ptr, aec_out.ptr);

            const copy_len = @min(buffer.len, frames_read);
            @memcpy(buffer[0..copy_len], aec_out[0..copy_len]);

            return copy_len;
        }

        /// Get the AEC frame size (optimal read buffer size)
        pub fn getFrameSize(self: *const Self) usize {
            return self.aec_frame_size;
        }

        // ====================================================================
        // Speaker Operations
        // ====================================================================

        /// Write audio to speaker
        /// Returns number of samples written
        pub fn writeSpeaker(self: *Self, buffer: []const i16) !usize {
            if (!self.initialized) return error.NotInitialized;

            const tx_buf = self.tx_buffer_32 orelse return error.NoBuffer;
            const frame_size = self.aec_frame_size;
            const mono_samples = @min(buffer.len, frame_size);

            // Convert mono i16 to stereo i32 (shift to upper 16 bits for 32-bit I2S)
            for (0..mono_samples) |i| {
                const sample32: i32 = @as(i32, buffer[i]) << 16;
                tx_buf[i * 2] = sample32;
                tx_buf[i * 2 + 1] = sample32;
            }

            var bytes_written: usize = 0;
            const tx_bytes = std.mem.sliceAsBytes(tx_buf[0 .. mono_samples * 2]);
            const ret = i2s_helper_write(config.i2s_port, tx_bytes.ptr, tx_bytes.len, &bytes_written, 1000);

            if (ret != 0) {
                log.warn("i2s write failed with code: {}", .{ret});
                return error.WriteFailed;
            }

            return bytes_written / 8;
        }

        /// Set speaker volume (0-255)
        pub fn setVolume(self: *Self, volume: u8) void {
            self.es8311.setVolume(volume) catch {};
        }
    };
}
