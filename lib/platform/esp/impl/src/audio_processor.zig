//! ESP AEC Processor — platform AEC adapter for AudioEngine
//!
//! Wrap ESP AFE AEC as `process(mic, ref, out)` so engine keeps algorithm-agnostic.

const std = @import("std");
const audio_processor = @import("audio").processor;

const AecHandle = opaque {};

extern fn aec_helper_create(
    input_format: [*:0]const u8,
    filter_length: c_int,
    aec_type: c_int,
    mode: c_int,
) ?*AecHandle;
extern fn aec_helper_process(handle: *AecHandle, indata: [*]const i16, outdata: [*]i16) c_int;
extern fn aec_helper_get_chunksize(handle: *AecHandle) c_int;
extern fn aec_helper_get_total_channels(handle: *AecHandle) c_int;
extern fn aec_helper_destroy(handle: *AecHandle) void;

pub const AecProcessor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    enabled: bool,
    frame_size: usize,
    total_channels: usize,
    handle: ?*AecHandle,
    interleaved_in: []i16,
    out_buf: []i16,

    pub fn init(allocator: std.mem.Allocator, cfg: audio_processor.Config) !Self {
        if (!cfg.enable_aec) {
            return .{
                .allocator = allocator,
                .enabled = false,
                .frame_size = @intCast(cfg.frame_size),
                .total_channels = 0,
                .handle = null,
                .interleaved_in = &.{},
                .out_buf = &.{},
            };
        }

        const handle = aec_helper_create("RM", 2, 1, 0) orelse return error.AecInitFailed;
        errdefer aec_helper_destroy(handle);

        const frame_size: usize = @intCast(aec_helper_get_chunksize(handle));
        if (frame_size == 0) return error.InvalidChunkSize;
        if (frame_size != cfg.frame_size) return error.FrameSizeMismatch;

        const total_channels: usize = @intCast(aec_helper_get_total_channels(handle));
        if (total_channels < 2) return error.InvalidChannelCount;

        const interleaved_in = try allocator.alloc(i16, frame_size * total_channels);
        errdefer allocator.free(interleaved_in);

        const out_buf = try allocator.alloc(i16, frame_size);

        return .{
            .allocator = allocator,
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
        self.interleaved_in = &.{};
        self.out_buf = &.{};
    }

    pub fn process(self: *Self, mic: []const i16, ref: []const i16, out: []i16) void {
        const n_total = @min(mic.len, @min(ref.len, out.len));
        if (n_total == 0) return;

        if (!self.enabled) {
            @memcpy(out[0..n_total], mic[0..n_total]);
            return;
        }

        const handle = self.handle orelse {
            @memcpy(out[0..n_total], mic[0..n_total]);
            return;
        };

        var offset: usize = 0;
        while (offset < n_total) {
            const chunk = @min(self.frame_size, n_total - offset);

            var i: usize = 0;
            while (i < self.frame_size) : (i += 1) {
                const src_i = offset + i;
                if (i < chunk) {
                    self.interleaved_in[i * self.total_channels + 0] = ref[src_i];
                    self.interleaved_in[i * self.total_channels + 1] = mic[src_i];
                } else {
                    self.interleaved_in[i * self.total_channels + 0] = 0;
                    self.interleaved_in[i * self.total_channels + 1] = 0;
                }
            }

            _ = aec_helper_process(handle, self.interleaved_in.ptr, self.out_buf.ptr);
            @memcpy(out[offset..][0..chunk], self.out_buf[0..chunk]);

            offset += chunk;
        }
    }

    pub fn reset(_: *Self) void {}
};
