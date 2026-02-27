//! esp board implementation for tier2_audio_engine (LiChuang GoCool)
//!
//! Notes:
//! - Old `AudioSystem` is only a reference; this file wires mic/ref/speaker directly.
//! - `Mic.read` returns raw mic only.
//! - `RefReader.read` returns platform-aligned ref.
//! - `Speaker.write` only outputs playback.

const std = @import("std");
const idf = @import("idf");
const esp = @import("esp");
const audio_drivers = @import("audio_drivers");
const audio = @import("audio");

const hw = esp.boards.lichuang_gocool;

const Es8311Driver = audio_drivers.es8311.Es8311(*idf.I2c);
const Es7210Driver = audio_drivers.es7210.Es7210(*idf.I2c);

const I2S_BITS_PER_SAMPLE: c_int = 32;
const I2S_CHUNK_FRAMES: usize = 256;
const AEC_REF_DELAY_SAMPLES: usize = 0;

const FIFO_CAP: usize = 256 * 256;

extern fn i2s_helper_init_std_duplex(
    port: c_int,
    sample_rate: u32,
    bits_per_sample: c_int,
    bclk_pin: c_int,
    ws_pin: c_int,
    din_pin: c_int,
    dout_pin: c_int,
    mclk_pin: c_int,
) c_int;
extern fn i2s_helper_deinit(port: c_int) c_int;
extern fn i2s_helper_enable_rx(port: c_int) c_int;
extern fn i2s_helper_enable_tx(port: c_int) c_int;
extern fn i2s_helper_disable_rx(port: c_int) c_int;
extern fn i2s_helper_disable_tx(port: c_int) c_int;
extern fn i2s_helper_read(port: c_int, buffer: [*]u8, buffer_size: usize, bytes_read: *usize, timeout_ms: u32) c_int;
pub extern fn i2s_helper_write(port: c_int, buffer: [*]const u8, buffer_size: usize, bytes_written: *usize, timeout_ms: u32) c_int;

const AecHandle = opaque {};
extern fn aec_helper_create(input_format: [*:0]const u8, filter_length: c_int, aec_type: c_int, mode: c_int) ?*AecHandle;
extern fn aec_helper_process(handle: *AecHandle, indata: [*]const i16, outdata: [*]i16) c_int;
extern fn aec_helper_get_chunksize(handle: *AecHandle) c_int;
extern fn aec_helper_get_total_channels(handle: *AecHandle) c_int;
extern fn aec_helper_destroy(handle: *AecHandle) void;

pub const log = hw.log;
pub const time = hw.time;
pub const runtime = idf.runtime;
pub const idf_heap = idf.heap;
pub const Processor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    enabled: bool,
    frame_size: usize,
    total_channels: usize,
    handle: ?*AecHandle,
    interleaved_in: []i16,
    out_buf: []i16,

    pub fn init(alloc: std.mem.Allocator, cfg: audio.processor.Config) !Self {
        // 5.5.3: Log processor internal AEC/NS switch state
        log.info("[Processor] AEC={}, NS={}, frame_size={}, sample_rate={}", .{
            cfg.enable_aec, cfg.enable_ns, cfg.frame_size, cfg.sample_rate,
        });

        if (!cfg.enable_aec) {
            log.info("[Processor] AEC disabled — using passthrough", .{});
            return .{
                .allocator = alloc,
                .enabled = false,
                .frame_size = @intCast(cfg.frame_size),
                .total_channels = 0,
                .handle = null,
                .interleaved_in = &.{},
                .out_buf = &.{},
            };
        }

        // ESP AFE handles NS internally when AEC is active.
        // NS control is within the AFE — engine does not orchestrate NS.
        const handle = aec_helper_create("RM", 2, 1, 0) orelse return error.AecInitFailed;
        errdefer aec_helper_destroy(handle);

        const frame_size: usize = @intCast(aec_helper_get_chunksize(handle));
        if (frame_size == 0) return error.InvalidChunkSize;
        if (frame_size != cfg.frame_size) return error.FrameSizeMismatch;

        const total_channels: usize = @intCast(aec_helper_get_total_channels(handle));
        if (total_channels < 2) return error.InvalidChannelCount;

        log.info("[Processor] ESP AFE created: chunk_size={}, channels={}", .{
            frame_size, total_channels,
        });

        const interleaved_in = try alloc.alloc(i16, frame_size * total_channels);
        errdefer alloc.free(interleaved_in);
        const out_buf = try alloc.alloc(i16, frame_size);

        return .{
            .allocator = alloc,
            .enabled = true,
            .frame_size = frame_size,
            .total_channels = total_channels,
            .handle = handle,
            .interleaved_in = interleaved_in,
            .out_buf = out_buf,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.handle) |h| {
            aec_helper_destroy(h);
            self.handle = null;
        }
        if (self.interleaved_in.len > 0) self.allocator.free(self.interleaved_in);
        if (self.out_buf.len > 0) self.allocator.free(self.out_buf);
    }

    pub fn process(self: *Self, mic: []const i16, ref: []const i16, out: []i16) void {
        const n = @min(mic.len, @min(ref.len, out.len));
        if (n == 0) return;
        if (!self.enabled or self.handle == null) {
            @memcpy(out[0..n], mic[0..n]);
            return;
        }

        var i: usize = 0;
        while (i < self.frame_size) : (i += 1) {
            if (i < n) {
                self.interleaved_in[i * self.total_channels + 0] = ref[i];
                self.interleaved_in[i * self.total_channels + 1] = mic[i];
            } else {
                self.interleaved_in[i * self.total_channels + 0] = 0;
                self.interleaved_in[i * self.total_channels + 1] = 0;
            }
        }

        _ = aec_helper_process(self.handle.?, self.interleaved_in.ptr, self.out_buf.ptr);
        @memcpy(out[0..n], self.out_buf[0..n]);
    }
};
pub const engine_frame_size: u32 = 256;

pub fn allocator() std.mem.Allocator {
    return idf.heap.psram;
}

pub fn initAudio() !void {}

pub fn deinitAudio() void {}

pub const DuplexAudio = struct {
    const Self = @This();

    pub const Mic = struct {
        parent: *Self,

        pub fn read(self: *Mic, buf: []i16) !usize {
            return self.parent.readMicRaw(buf);
        }
    };

    pub const Speaker = struct {
        parent: *Self,

        pub fn write(self: *Speaker, buf: []const i16) !usize {
            if (!self.parent.active) return error.NotInitialized;
            return self.parent.writeSpeakerRaw(buf);
        }
    };

    pub const RefReader = struct {
        parent: *Self,

        pub fn read(self: *RefReader, buf: []i16) !usize {
            return self.parent.readRefAligned(buf);
        }
    };

    allocator: std.mem.Allocator,
    i2c: idf.I2c,
    es8311: Es8311Driver,
    es7210: Es7210Driver,
    pa_switch: hw.PaSwitchDriver,

    raw_i2s: []i32,
    tx_i2s: []i32,

    mic_fifo: []i16,
    mic_read: usize,
    mic_write: usize,
    mic_count: usize,

    ref_fifo: []i16,
    ref_read: usize,
    ref_write: usize,
    ref_count: usize,

    ref_delay_ring: []i16,
    ref_delay_pos: usize,

    drops_mic: u64,
    drops_ref: u64,

    // 5.4.5: Per-second observable metrics
    stat_mic_samples: u64,
    stat_ref_samples: u64,
    stat_spk_samples: u64,
    stat_mic_zero_fill: u64,
    stat_ref_zero_fill: u64,
    stat_last_report_ms: u64,

    active: bool,

    pub fn init(alloc: std.mem.Allocator) !Self {
        var i2c = try idf.I2c.init(.{
            .sda = hw.i2c_sda,
            .scl = hw.i2c_scl,
            .freq_hz = hw.i2c_freq_hz,
        });
        errdefer i2c.deinit();

        var es8311 = Es8311Driver.init(&i2c, .{ .address = 0x18 });
        try es8311.open();
        errdefer es8311.close() catch {};

        idf.time.sleepMs(10);

        var es7210 = Es7210Driver.init(&i2c, .{
            .address = 0x41,
            .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true },
        });
        try es7210.open();
        errdefer es7210.close() catch {};

        if (i2s_helper_init_std_duplex(
            hw.i2s_port,
            hw.sample_rate,
            I2S_BITS_PER_SAMPLE,
            hw.i2s_bclk,
            hw.i2s_ws,
            hw.i2s_din,
            hw.i2s_dout,
            hw.i2s_mclk,
        ) != 0) return error.I2sInitFailed;
        errdefer _ = i2s_helper_deinit(hw.i2s_port);

        if (i2s_helper_enable_rx(hw.i2s_port) != 0) return error.I2sEnableFailed;
        if (i2s_helper_enable_tx(hw.i2s_port) != 0) return error.I2sEnableFailed;

        try es8311.enable(true);
        try es7210.enable(true);
        try es8311.setVolume(220);

        log.info("[DuplexAudio] init: i2s_bits={}, chunk_frames={}, ref_delay={}, fifo_cap={}", .{
            I2S_BITS_PER_SAMPLE, I2S_CHUNK_FRAMES, AEC_REF_DELAY_SAMPLES, FIFO_CAP,
        });

        var pa_switch = try hw.PaSwitchDriver.init();
        errdefer pa_switch.deinit();
        pa_switch.on() catch {};

        // Use PSRAM (same as old AudioSystem) — DMA not required for user buffers,
        // ESP-IDF i2s_channel_write copies to its own internal DMA buffers.
        const raw_i2s = try alloc.alloc(i32, I2S_CHUNK_FRAMES * 2);
        errdefer alloc.free(raw_i2s);
        const tx_i2s = try alloc.alloc(i32, I2S_CHUNK_FRAMES * 2);
        errdefer alloc.free(tx_i2s);

        const mic_fifo = try alloc.alloc(i16, FIFO_CAP);
        errdefer alloc.free(mic_fifo);
        const ref_fifo = try alloc.alloc(i16, FIFO_CAP);
        errdefer alloc.free(ref_fifo);
        const ref_delay_ring = if (AEC_REF_DELAY_SAMPLES > 0)
            try alloc.alloc(i16, AEC_REF_DELAY_SAMPLES)
        else
            &.{};
        errdefer if (ref_delay_ring.len > 0) alloc.free(ref_delay_ring);
        if (ref_delay_ring.len > 0) @memset(ref_delay_ring, 0);

        return .{
            .allocator = alloc,
            .i2c = i2c,
            .es8311 = es8311,
            .es7210 = es7210,
            .pa_switch = pa_switch,
            .raw_i2s = raw_i2s,
            .tx_i2s = tx_i2s,
            .mic_fifo = mic_fifo,
            .mic_read = 0,
            .mic_write = 0,
            .mic_count = 0,
            .ref_fifo = ref_fifo,
            .ref_read = 0,
            .ref_write = 0,
            .ref_count = 0,
            .ref_delay_ring = ref_delay_ring,
            .ref_delay_pos = 0,
            .drops_mic = 0,
            .drops_ref = 0,
            .stat_mic_samples = 0,
            .stat_ref_samples = 0,
            .stat_spk_samples = 0,
            .stat_mic_zero_fill = 0,
            .stat_ref_zero_fill = 0,
            .stat_last_report_ms = time.nowMs(),
            .active = true,
        };
    }

    pub fn start(self: *Self) !void {
        if (!self.active) return error.NotInitialized;
    }

    pub fn stop(self: *Self) void {
        if (!self.active) return;
        self.active = false;

        self.pa_switch.off() catch {};
        self.pa_switch.deinit();

        _ = i2s_helper_disable_rx(hw.i2s_port);
        _ = i2s_helper_disable_tx(hw.i2s_port);
        _ = i2s_helper_deinit(hw.i2s_port);

        self.es7210.enable(false) catch {};
        self.es8311.enable(false) catch {};
        self.es7210.close() catch {};
        self.es8311.close() catch {};
        self.i2c.deinit();

        self.allocator.free(self.raw_i2s);
        self.allocator.free(self.tx_i2s);
        self.allocator.free(self.mic_fifo);
        self.allocator.free(self.ref_fifo);
        if (self.ref_delay_ring.len > 0) self.allocator.free(self.ref_delay_ring);
    }

    pub fn mic(self: *Self) Mic {
        return .{ .parent = self };
    }

    pub fn speaker(self: *Self) Speaker {
        return .{ .parent = self };
    }

    pub fn refReader(self: *Self) RefReader {
        return .{ .parent = self };
    }

    fn readMicRaw(self: *Self, out: []i16) !usize {
        if (out.len == 0) return 0;

        while (self.mic_count < out.len) {
            try self.pullCaptureChunk();
            if (self.mic_count == 0) break;
        }

        const n = @min(out.len, self.mic_count);
        for (0..n) |i| {
            out[i] = self.mic_fifo[self.mic_read];
            self.mic_read = (self.mic_read + 1) % self.mic_fifo.len;
        }
        self.mic_count -= n;

        // Zero-fill if not enough data
        if (n < out.len) {
            @memset(out[n..], 0);
            self.stat_mic_zero_fill += out.len - n;
        }

        self.stat_mic_samples += out.len;
        self.maybeReportStats();
        return out.len;
    }

    fn readRefAligned(self: *Self, out: []i16) !usize {
        if (out.len == 0) return 0;

        const n = @min(out.len, self.ref_count);
        if (n == 0) {
            @memset(out, 0);
            self.stat_ref_zero_fill += out.len;
            self.stat_ref_samples += out.len;
            return out.len;
        }

        for (0..n) |i| {
            out[i] = self.ref_fifo[self.ref_read];
            self.ref_read = (self.ref_read + 1) % self.ref_fifo.len;
        }
        self.ref_count -= n;

        if (n < out.len) {
            @memset(out[n..], 0);
            self.stat_ref_zero_fill += out.len - n;
        }

        self.stat_ref_samples += out.len;
        return out.len;
    }

    fn writeSpeakerRaw(self: *Self, in_buf: []const i16) !usize {
        if (in_buf.len == 0) return 0;

        // OLD structure: outer while + @min — this is what crashed before
        var done: usize = 0;
        while (done < in_buf.len) {
            const mono_n = @min(in_buf.len - done, I2S_CHUNK_FRAMES);
            const stereo_n = mono_n * 2;
            if (self.tx_i2s.len < stereo_n) return error.TxBufferTooSmall;

            var i: usize = 0;
            while (i < mono_n) : (i += 1) {
                const sample_bits: u16 = @bitCast(in_buf[done + i]);
                const packed_bits: u32 = @as(u32, sample_bits) << 16;
                const s32: i32 = @bitCast(packed_bits);
                self.tx_i2s[i * 2] = s32;
                self.tx_i2s[i * 2 + 1] = s32;
            }

            done += mono_n;
        }
        const mono_samples = in_buf.len;

        // Write to I2S
        const tx_bytes = std.mem.sliceAsBytes(self.tx_i2s[0 .. mono_samples * 2]);
        var written_total: usize = 0;
        while (written_total < tx_bytes.len) {
            var bytes_written: usize = 0;
            const ret = i2s_helper_write(
                hw.i2s_port,
                tx_bytes[written_total..].ptr,
                tx_bytes.len - written_total,
                &bytes_written,
                1000,
            );
            if (ret != 0 or bytes_written == 0) return error.WriteFailed;
            written_total += bytes_written;
        }

        self.stat_spk_samples += mono_samples;
        return mono_samples;
    }

    fn pullCaptureChunk(self: *Self) !void {
        const target_bytes = I2S_CHUNK_FRAMES * 2 * @sizeOf(i32);
        const raw_bytes = std.mem.sliceAsBytes(self.raw_i2s[0 .. I2S_CHUNK_FRAMES * 2]);

        var total_read: usize = 0;
        while (total_read < target_bytes) {
            var bytes_read: usize = 0;
            const ret = i2s_helper_read(
                hw.i2s_port,
                raw_bytes[total_read..].ptr,
                target_bytes - total_read,
                &bytes_read,
                1000,
            );
            if (ret != 0) {
                if (total_read == 0) return error.ReadFailed;
                break;
            }
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        const frames = total_read / (@sizeOf(i32) * 2);
        for (0..frames) |i| {
            const L = self.raw_i2s[i * 2 + 0];
            const mic_sample: i16 = @truncate(L >> 16);
            const ref_raw: i16 = @truncate(L & 0xFFFF);
            const ref = self.applyRefDelay(ref_raw);

            self.pushSample(&self.mic_fifo, &self.mic_write, &self.mic_count, mic_sample, &self.drops_mic);
            self.pushSample(&self.ref_fifo, &self.ref_write, &self.ref_count, ref, &self.drops_ref);
        }
    }

    fn applyRefDelay(self: *Self, ref_sample: i16) i16 {
        if (self.ref_delay_ring.len == 0) return ref_sample;
        const delayed = self.ref_delay_ring[self.ref_delay_pos];
        self.ref_delay_ring[self.ref_delay_pos] = ref_sample;
        self.ref_delay_pos = (self.ref_delay_pos + 1) % self.ref_delay_ring.len;
        return delayed;
    }

    fn pushSample(
        self: *Self,
        fifo: *[]i16,
        write_pos: *usize,
        count: *usize,
        s: i16,
        drops: *u64,
    ) void {
        _ = self;
        const buf = fifo.*;
        if (count.* == buf.len) {
            // Drop oldest to keep stream progressing.
            drops.* += 1;
            return;
        }
        buf[write_pos.*] = s;
        write_pos.* = (write_pos.* + 1) % buf.len;
        count.* += 1;
    }

    /// 5.4.5: Periodic stats report — logs every 1 second.
    fn maybeReportStats(self: *Self) void {
        const now = time.nowMs();
        const elapsed = now -| self.stat_last_report_ms;
        if (elapsed < 1000) return;

        log.info("[DuplexAudio] stats: mic={} ref={} spk={} drops_mic={} drops_ref={} mic_zfill={} ref_zfill={} ref_delay={} fifo_mic={} fifo_ref={}", .{
            self.stat_mic_samples,
            self.stat_ref_samples,
            self.stat_spk_samples,
            self.drops_mic,
            self.drops_ref,
            self.stat_mic_zero_fill,
            self.stat_ref_zero_fill,
            AEC_REF_DELAY_SAMPLES,
            self.mic_count,
            self.ref_count,
        });

        // Reset counters for next interval
        self.stat_mic_samples = 0;
        self.stat_ref_samples = 0;
        self.stat_spk_samples = 0;
        self.stat_mic_zero_fill = 0;
        self.stat_ref_zero_fill = 0;
        self.drops_mic = 0;
        self.drops_ref = 0;
        self.stat_last_report_ms = now;
    }
};
