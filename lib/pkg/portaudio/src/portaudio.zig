//! PortAudio Zig Bindings — Blocking I/O
//!
//! Uses Pa_ReadStream / Pa_WriteStream (blocking mode).
//! Same pattern as giztoy Go/Rust implementations.
//!
//! Example:
//! ```zig
//! const pa = @import("portaudio");
//! try pa.init();
//! defer pa.deinit();
//!
//! var stream = try pa.Stream.open(allocator, .{
//!     .input_channels  = 1,
//!     .output_channels = 1,
//!     .sample_rate     = 16000,
//!     .frames_per_buffer = 160,
//! });
//! defer stream.close();
//! try stream.start();
//!
//! var buf: [160]i16 = undefined;
//! while (true) {
//!     _ = try stream.read(&buf);   // blocking
//!     try stream.write(&buf);      // blocking
//! }
//! ```

const std = @import("std");

const c = @cImport(@cInclude("portaudio.h"));

// ============================================================================
// Error
// ============================================================================

pub const PaError = error{
    NotInitialized,
    UnanticipatedHostError,
    InvalidChannelCount,
    InvalidSampleRate,
    InvalidDevice,
    InvalidFlag,
    SampleFormatNotSupported,
    BadIODeviceCombination,
    InsufficientMemory,
    BufferTooBig,
    BufferTooSmall,
    BadStreamPtr,
    TimedOut,
    InternalError,
    DeviceUnavailable,
    StreamIsStopped,
    StreamIsNotStopped,
    InputOverflowed,
    OutputUnderflowed,
    HostApiNotFound,
    InvalidHostApi,
    BadBufferPtr,
    Unknown,
};

fn check(code: c.PaError) PaError!void {
    if (code == c.paNoError) return;
    return switch (code) {
        c.paNotInitialized => error.NotInitialized,
        c.paUnanticipatedHostError => error.UnanticipatedHostError,
        c.paInvalidChannelCount => error.InvalidChannelCount,
        c.paInvalidSampleRate => error.InvalidSampleRate,
        c.paInvalidDevice => error.InvalidDevice,
        c.paInvalidFlag => error.InvalidFlag,
        c.paSampleFormatNotSupported => error.SampleFormatNotSupported,
        c.paBadIODeviceCombination => error.BadIODeviceCombination,
        c.paInsufficientMemory => error.InsufficientMemory,
        c.paBufferTooBig => error.BufferTooBig,
        c.paBufferTooSmall => error.BufferTooSmall,
        c.paBadStreamPtr => error.BadStreamPtr,
        c.paTimedOut => error.TimedOut,
        c.paInternalError => error.InternalError,
        c.paDeviceUnavailable => error.DeviceUnavailable,
        c.paStreamIsStopped => error.StreamIsStopped,
        c.paStreamIsNotStopped => error.StreamIsNotStopped,
        c.paInputOverflowed => error.InputOverflowed,
        c.paOutputUnderflowed => error.OutputUnderflowed,
        c.paHostApiNotFound => error.HostApiNotFound,
        c.paInvalidHostApi => error.InvalidHostApi,
        c.paBadBufferPtr => error.BadBufferPtr,
        else => error.Unknown,
    };
}

// ============================================================================
// Init / Deinit
// ============================================================================

pub fn init() PaError!void {
    try check(c.Pa_Initialize());
}

pub fn deinit() void {
    _ = c.Pa_Terminate();
}

pub fn versionText() []const u8 {
    return std.mem.span(c.Pa_GetVersionText());
}

// ============================================================================
// Device Info
// ============================================================================

pub const DeviceIndex = c.PaDeviceIndex;

pub const DeviceInfo = struct {
    name: []const u8,
    max_input_channels: i32,
    max_output_channels: i32,
    default_sample_rate: f64,
    default_low_input_latency: f64,
    default_low_output_latency: f64,
};

pub fn defaultInputDevice() DeviceIndex {
    return c.Pa_GetDefaultInputDevice();
}

pub fn defaultOutputDevice() DeviceIndex {
    return c.Pa_GetDefaultOutputDevice();
}

pub fn deviceInfo(index: DeviceIndex) ?DeviceInfo {
    const info = c.Pa_GetDeviceInfo(index) orelse return null;
    return .{
        .name = std.mem.span(info.name),
        .max_input_channels = info.maxInputChannels,
        .max_output_channels = info.maxOutputChannels,
        .default_sample_rate = info.defaultSampleRate,
        .default_low_input_latency = info.defaultLowInputLatency,
        .default_low_output_latency = info.defaultLowOutputLatency,
    };
}

// ============================================================================
// Stream — Blocking I/O
// ============================================================================

pub const StreamConfig = struct {
    input_channels: u32 = 1,
    output_channels: u32 = 1,
    sample_rate: f64 = 16000.0,
    frames_per_buffer: u32 = 160,
};

pub const Stream = struct {
    pa_stream: ?*c.PaStream,
    cfg: StreamConfig,
    buf: []i16,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, cfg: StreamConfig) (PaError || std.mem.Allocator.Error)!Stream {
        var in_params: ?c.PaStreamParameters = null;
        var out_params: ?c.PaStreamParameters = null;

        if (cfg.input_channels > 0) {
            const dev = c.Pa_GetDefaultInputDevice();
            if (dev == c.paNoDevice) return error.InvalidDevice;
            const info = c.Pa_GetDeviceInfo(dev) orelse return error.InvalidDevice;
            in_params = .{
                .device = dev,
                .channelCount = @intCast(cfg.input_channels),
                .sampleFormat = c.paInt16,
                .suggestedLatency = info.defaultLowInputLatency,
                .hostApiSpecificStreamInfo = null,
            };
        }

        if (cfg.output_channels > 0) {
            const dev = c.Pa_GetDefaultOutputDevice();
            if (dev == c.paNoDevice) return error.InvalidDevice;
            const info = c.Pa_GetDeviceInfo(dev) orelse return error.InvalidDevice;
            out_params = .{
                .device = dev,
                .channelCount = @intCast(cfg.output_channels),
                .sampleFormat = c.paInt16,
                .suggestedLatency = info.defaultLowOutputLatency,
                .hostApiSpecificStreamInfo = null,
            };
        }

        var pa_stream: ?*c.PaStream = null;
        try check(c.Pa_OpenStream(
            &pa_stream,
            if (in_params) |*p| p else null,
            if (out_params) |*p| p else null,
            cfg.sample_rate,
            cfg.frames_per_buffer,
            c.paClipOff,
            null, // no callback
            null,
        ));

        const max_ch = @max(cfg.input_channels, cfg.output_channels);
        const buf = try allocator.alloc(i16, cfg.frames_per_buffer * max_ch);

        return .{
            .pa_stream = pa_stream,
            .cfg = cfg,
            .buf = buf,
            .allocator = allocator,
        };
    }

    pub fn start(self: *Stream) PaError!void {
        try check(c.Pa_StartStream(self.pa_stream));
    }

    pub fn stop(self: *Stream) PaError!void {
        try check(c.Pa_StopStream(self.pa_stream));
    }

    pub fn close(self: *Stream) void {
        if (self.pa_stream) |s| {
            _ = c.Pa_StopStream(s);
            _ = c.Pa_CloseStream(s);
            self.pa_stream = null;
        }
        self.allocator.free(self.buf);
    }

    /// Blocking read — fills buf with frames_per_buffer * input_channels samples.
    pub fn read(self: *Stream, buf: []i16) PaError!usize {
        const n = self.cfg.frames_per_buffer * self.cfg.input_channels;
        if (buf.len < n) return error.BufferTooSmall;
        try check(c.Pa_ReadStream(self.pa_stream, self.buf.ptr, self.cfg.frames_per_buffer));
        @memcpy(buf[0..n], self.buf[0..n]);
        return n;
    }

    /// Blocking write — sends frames_per_buffer * output_channels samples.
    pub fn write(self: *Stream, buf: []const i16) PaError!void {
        const n = self.cfg.frames_per_buffer * self.cfg.output_channels;
        if (buf.len < n) return error.BufferTooSmall;
        @memcpy(self.buf[0..n], buf[0..n]);
        try check(c.Pa_WriteStream(self.pa_stream, self.buf.ptr, self.cfg.frames_per_buffer));
    }
};
