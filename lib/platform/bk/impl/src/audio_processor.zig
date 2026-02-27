//! BK AEC Processor — platform AEC adapter for AudioEngine
//!
//! Wrap BK Armino AEC as `process(mic, ref, out)` so engine keeps algorithm-agnostic.

const std = @import("std");
const audio_processor = @import("audio").processor;
const armino = @import("../../armino/src/armino.zig");

pub const AecProcessor = struct {
    const Self = @This();

    enabled: bool,
    frame_size: usize,
    aec: ?armino.aec.Aec,

    pub fn init(_: std.mem.Allocator, cfg: audio_processor.Config) !Self {
        if (!cfg.enable_aec) {
            return .{
                .enabled = false,
                .frame_size = @intCast(cfg.frame_size),
                .aec = null,
            };
        }

        var aec = try armino.aec.Aec.init(1000, @intCast(cfg.sample_rate));
        const frame_size = aec.getFrameSamples();
        if (frame_size != cfg.frame_size) {
            aec.deinit();
            return error.FrameSizeMismatch;
        }

        return .{
            .enabled = true,
            .frame_size = frame_size,
            .aec = aec,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.aec) |*aec| {
            aec.deinit();
            self.aec = null;
        }
    }

    pub fn process(self: *Self, mic: []const i16, ref: []const i16, out: []i16) void {
        const n_total = @min(mic.len, @min(ref.len, out.len));
        if (n_total == 0) return;

        if (!self.enabled) {
            @memcpy(out[0..n_total], mic[0..n_total]);
            return;
        }

        const aec = &(self.aec orelse {
            @memcpy(out[0..n_total], mic[0..n_total]);
            return;
        });

        var offset: usize = 0;
        while (offset < n_total) {
            const chunk = @min(self.frame_size, n_total - offset);
            if (chunk == self.frame_size) {
                aec.process(
                    ref[offset..][0..self.frame_size],
                    mic[offset..][0..self.frame_size],
                    out[offset..][0..self.frame_size],
                );
                offset += chunk;
                continue;
            }

            var ref_pad: [320]i16 = [_]i16{0} ** 320;
            var mic_pad: [320]i16 = [_]i16{0} ** 320;
            var out_pad: [320]i16 = [_]i16{0} ** 320;

            if (self.frame_size > ref_pad.len) {
                @memcpy(out[offset..][0..chunk], mic[offset..][0..chunk]);
                return;
            }

            @memcpy(ref_pad[0..chunk], ref[offset..][0..chunk]);
            @memcpy(mic_pad[0..chunk], mic[offset..][0..chunk]);
            aec.process(ref_pad[0..self.frame_size], mic_pad[0..self.frame_size], out_pad[0..self.frame_size]);
            @memcpy(out[offset..][0..chunk], out_pad[0..chunk]);

            offset += chunk;
        }
    }

    pub fn reset(_: *Self) void {}
};
