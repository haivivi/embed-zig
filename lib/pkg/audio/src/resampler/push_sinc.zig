//! PushSincResampler — fixed-block pure Zig resampler

const std = @import("std");
const sinc = @import("sinc.zig");

const SincResampler = sinc.SincResampler;
pub const KERNEL_SIZE = sinc.KERNEL_SIZE;

pub const PushSincResampler = struct {
    resampler: SincResampler,
    destination_frames: usize,
    needs_prime: bool,
    scratch: []f32,
    allocator: std.mem.Allocator,

    pub fn new(allocator: std.mem.Allocator, source_frames: usize, destination_frames: usize) !PushSincResampler {
        if (source_frames == 0) return error.InvalidSourceFrames;
        if (destination_frames == 0) return error.InvalidDestinationFrames;
        const io_ratio = @as(f64, @floatFromInt(source_frames)) / @as(f64, @floatFromInt(destination_frames));
        const resampler = try SincResampler.new(allocator, io_ratio, source_frames);
        var self = PushSincResampler{
            .resampler = resampler,
            .destination_frames = destination_frames,
            .needs_prime = true,
            .scratch = &.{},
            .allocator = allocator,
        };
        const required = @max(self.destination_frames, self.resampler.chunkSize());
        try self.ensureScratch(required);
        self.ensurePrime();
        return self;
    }

    pub fn deinit(self: *PushSincResampler) void {
        self.resampler.deinit();
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
    }

    pub fn reset(self: *PushSincResampler) void {
        self.resampler.flush();
        self.needs_prime = true;
        self.ensurePrime();
    }

    pub fn sourceFrames(self: *const PushSincResampler) usize {
        return self.resampler.requestFrames();
    }

    pub fn destinationFrames(self: *const PushSincResampler) usize {
        return self.destination_frames;
    }

    pub fn resampleI16(self: *PushSincResampler, source: []const i16, destination: []i16) !usize {
        std.debug.assert(source.len == self.resampler.requestFrames());
        std.debug.assert(destination.len >= self.destination_frames);
        const required = @max(self.destination_frames, self.resampler.chunkSize());
        try self.ensureScratch(required);
        self.ensurePrime();

        var ctx = I16SourceCtx{ .source = source };
        self.resampler.resample(self.destination_frames, self.scratch[0..self.destination_frames], &ctx, I16SourceCtx.fill);
        std.debug.assert(ctx.consumed == source.len);
        floatS16ToI16(self.scratch[0..self.destination_frames], destination[0..self.destination_frames]);
        return self.destination_frames;
    }

    fn ensurePrime(self: *PushSincResampler) void {
        if (!self.needs_prime) return;
        const chunk = self.resampler.chunkSize();
        if (chunk > 0) {
            self.ensureScratch(chunk) catch unreachable;

            var ctx = ZeroCtx{};
            self.resampler.resample(chunk, self.scratch[0..chunk], &ctx, ZeroCtx.fill);
        }
        self.needs_prime = false;
    }

    fn ensureScratch(self: *PushSincResampler, required: usize) !void {
        if (self.scratch.len >= required) return;
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.scratch = try self.allocator.alloc(f32, required);
        @memset(self.scratch, 0.0);
    }
};

const I16SourceCtx = struct {
    source: []const i16,
    consumed: usize = 0,

    fn fill(ctx: *anyopaque, dest: []f32) void {
        const self: *I16SourceCtx = @ptrCast(@alignCast(ctx));
        i16ToFloatS16(self.source[self.consumed .. self.consumed + dest.len], dest);
        self.consumed += dest.len;
    }
};

const ZeroCtx = struct {
    fn fill(_: *anyopaque, dest: []f32) void {
        @memset(dest, 0.0);
    }
};

fn i16ToFloatS16(src: []const i16, dst: []f32) void {
    std.debug.assert(dst.len >= src.len);
    for (src, 0..) |s, i| {
        dst[i] = @as(f32, @floatFromInt(s));
    }
}

fn floatS16ToI16(src: []const f32, dst: []i16) void {
    std.debug.assert(dst.len >= src.len);
    for (src, 0..) |v, i| {
        const clamped = std.math.clamp(v, -32768.0, 32767.0);
        dst[i] = @intFromFloat(@round(clamped));
    }
}
