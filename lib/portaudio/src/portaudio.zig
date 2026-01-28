//! PortAudio Zig Bindings
//!
//! Cross-platform audio I/O library.
//!
//! Example:
//! ```zig
//! const pa = @import("portaudio");
//!
//! pub fn main() !void {
//!     try pa.init();
//!     defer pa.deinit();
//!
//!     var stream = try pa.OutputStream(i16).open(.{
//!         .sample_rate = 44100,
//!         .channels = 2,
//!         .frames_per_buffer = 256,
//!     });
//!     defer stream.close();
//!
//!     try stream.start();
//!     // ... write audio data ...
//!     try stream.stop();
//! }
//! ```

const std = @import("std");

const c = @cImport({
    @cInclude("portaudio.h");
});

// ============================================================================
// Error Handling
// ============================================================================

pub const Error = error{
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
    NullCallback,
    BadStreamPtr,
    TimedOut,
    InternalError,
    DeviceUnavailable,
    IncompatibleHostApiSpecificStreamInfo,
    StreamIsStopped,
    StreamIsNotStopped,
    InputOverflowed,
    OutputUnderflowed,
    HostApiNotFound,
    InvalidHostApi,
    CanNotReadFromACallbackStream,
    CanNotWriteToACallbackStream,
    CanNotReadFromAnOutputOnlyStream,
    CanNotWriteToAnInputOnlyStream,
    IncompatibleStreamHostApi,
    BadBufferPtr,
    Unknown,
};

fn errorFromCode(code: c.PaError) Error {
    return switch (code) {
        c.paNotInitialized => Error.NotInitialized,
        c.paUnanticipatedHostError => Error.UnanticipatedHostError,
        c.paInvalidChannelCount => Error.InvalidChannelCount,
        c.paInvalidSampleRate => Error.InvalidSampleRate,
        c.paInvalidDevice => Error.InvalidDevice,
        c.paInvalidFlag => Error.InvalidFlag,
        c.paSampleFormatNotSupported => Error.SampleFormatNotSupported,
        c.paBadIODeviceCombination => Error.BadIODeviceCombination,
        c.paInsufficientMemory => Error.InsufficientMemory,
        c.paBufferTooBig => Error.BufferTooBig,
        c.paBufferTooSmall => Error.BufferTooSmall,
        c.paNullCallback => Error.NullCallback,
        c.paBadStreamPtr => Error.BadStreamPtr,
        c.paTimedOut => Error.TimedOut,
        c.paInternalError => Error.InternalError,
        c.paDeviceUnavailable => Error.DeviceUnavailable,
        c.paIncompatibleHostApiSpecificStreamInfo => Error.IncompatibleHostApiSpecificStreamInfo,
        c.paStreamIsStopped => Error.StreamIsStopped,
        c.paStreamIsNotStopped => Error.StreamIsNotStopped,
        c.paInputOverflowed => Error.InputOverflowed,
        c.paOutputUnderflowed => Error.OutputUnderflowed,
        c.paHostApiNotFound => Error.HostApiNotFound,
        c.paInvalidHostApi => Error.InvalidHostApi,
        c.paCanNotReadFromACallbackStream => Error.CanNotReadFromACallbackStream,
        c.paCanNotWriteToACallbackStream => Error.CanNotWriteToACallbackStream,
        c.paCanNotReadFromAnOutputOnlyStream => Error.CanNotReadFromAnOutputOnlyStream,
        c.paCanNotWriteToAnInputOnlyStream => Error.CanNotWriteToAnInputOnlyStream,
        c.paIncompatibleStreamHostApi => Error.IncompatibleStreamHostApi,
        c.paBadBufferPtr => Error.BadBufferPtr,
        else => Error.Unknown,
    };
}

fn check(code: c.PaError) Error!void {
    if (code != c.paNoError) {
        return errorFromCode(code);
    }
}

// ============================================================================
// Initialization
// ============================================================================

/// Initialize PortAudio. Must be called before any other PortAudio functions.
pub fn init() Error!void {
    try check(c.Pa_Initialize());
}

/// Terminate PortAudio. Call when done using PortAudio.
pub fn deinit() void {
    _ = c.Pa_Terminate();
}

/// Get PortAudio version string.
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
    default_high_input_latency: f64,
    default_high_output_latency: f64,
};

/// Get the number of available devices.
pub fn deviceCount() i32 {
    return c.Pa_GetDeviceCount();
}

/// Get the default input device index.
pub fn defaultInputDevice() DeviceIndex {
    return c.Pa_GetDefaultInputDevice();
}

/// Get the default output device index.
pub fn defaultOutputDevice() DeviceIndex {
    return c.Pa_GetDefaultOutputDevice();
}

/// Get information about a device.
pub fn deviceInfo(index: DeviceIndex) ?DeviceInfo {
    const info = c.Pa_GetDeviceInfo(index);
    if (info == null) return null;

    return DeviceInfo{
        .name = std.mem.span(info.*.name),
        .max_input_channels = info.*.maxInputChannels,
        .max_output_channels = info.*.maxOutputChannels,
        .default_sample_rate = info.*.defaultSampleRate,
        .default_low_input_latency = info.*.defaultLowInputLatency,
        .default_low_output_latency = info.*.defaultLowOutputLatency,
        .default_high_input_latency = info.*.defaultHighInputLatency,
        .default_high_output_latency = info.*.defaultHighOutputLatency,
    };
}

// ============================================================================
// Stream Configuration
// ============================================================================

pub const StreamConfig = struct {
    sample_rate: f64 = 44100,
    channels: i32 = 2,
    frames_per_buffer: u32 = 256,
    device: DeviceIndex = c.paNoDevice,
};

// ============================================================================
// Output Stream (blocking write)
// ============================================================================

pub fn OutputStream(comptime SampleType: type) type {
    return struct {
        const Self = @This();

        stream: ?*c.PaStream,
        config: StreamConfig,

        pub fn open(cfg: StreamConfig) Error!Self {
            var self = Self{
                .stream = null,
                .config = cfg,
            };

            const device = if (cfg.device == c.paNoDevice) defaultOutputDevice() else cfg.device;

            const output_params = c.PaStreamParameters{
                .device = device,
                .channelCount = cfg.channels,
                .sampleFormat = sampleFormat(SampleType),
                .suggestedLatency = 0.050,
                .hostApiSpecificStreamInfo = null,
            };

            try check(c.Pa_OpenStream(
                &self.stream,
                null, // no input
                &output_params,
                cfg.sample_rate,
                @intCast(cfg.frames_per_buffer),
                c.paClipOff,
                null, // no callback (blocking)
                null,
            ));

            return self;
        }

        pub fn close(self: *Self) void {
            if (self.stream) |s| {
                _ = c.Pa_CloseStream(s);
                self.stream = null;
            }
        }

        pub fn start(self: *Self) Error!void {
            if (self.stream) |s| {
                try check(c.Pa_StartStream(s));
            }
        }

        pub fn stop(self: *Self) Error!void {
            if (self.stream) |s| {
                try check(c.Pa_StopStream(s));
            }
        }

        pub fn write(self: *Self, buffer: []const SampleType) Error!void {
            if (self.stream) |s| {
                const frames = @divExact(buffer.len, @as(usize, @intCast(self.config.channels)));
                try check(c.Pa_WriteStream(s, buffer.ptr, @intCast(frames)));
            }
        }
    };
}

// ============================================================================
// Input Stream (blocking read)
// ============================================================================

pub fn InputStream(comptime SampleType: type) type {
    return struct {
        const Self = @This();

        stream: ?*c.PaStream,
        config: StreamConfig,

        pub fn open(cfg: StreamConfig) Error!Self {
            var self = Self{
                .stream = null,
                .config = cfg,
            };

            const device = if (cfg.device == c.paNoDevice) defaultInputDevice() else cfg.device;

            const input_params = c.PaStreamParameters{
                .device = device,
                .channelCount = cfg.channels,
                .sampleFormat = sampleFormat(SampleType),
                .suggestedLatency = 0.050,
                .hostApiSpecificStreamInfo = null,
            };

            try check(c.Pa_OpenStream(
                &self.stream,
                &input_params,
                null, // no output
                cfg.sample_rate,
                @intCast(cfg.frames_per_buffer),
                c.paClipOff,
                null, // no callback (blocking)
                null,
            ));

            return self;
        }

        pub fn close(self: *Self) void {
            if (self.stream) |s| {
                _ = c.Pa_CloseStream(s);
                self.stream = null;
            }
        }

        pub fn start(self: *Self) Error!void {
            if (self.stream) |s| {
                try check(c.Pa_StartStream(s));
            }
        }

        pub fn stop(self: *Self) Error!void {
            if (self.stream) |s| {
                try check(c.Pa_StopStream(s));
            }
        }

        pub fn read(self: *Self, buffer: []SampleType) Error!void {
            if (self.stream) |s| {
                const frames = @divExact(buffer.len, @as(usize, @intCast(self.config.channels)));
                try check(c.Pa_ReadStream(s, buffer.ptr, @intCast(frames)));
            }
        }
    };
}

// ============================================================================
// Callback Stream
// ============================================================================

pub const CallbackResult = enum(c_int) {
    Continue = c.paContinue,
    Complete = c.paComplete,
    Abort = c.paAbort,
};

pub fn CallbackStream(comptime SampleType: type) type {
    return struct {
        const Self = @This();

        pub const Callback = *const fn (
            output: []SampleType,
            frames: usize,
            user_data: ?*anyopaque,
        ) CallbackResult;

        stream: ?*c.PaStream,
        config: StreamConfig,

        pub fn open(cfg: StreamConfig, callback: Callback, user_data: ?*anyopaque) Error!Self {
            var self = Self{
                .stream = null,
                .config = cfg,
            };

            const device = if (cfg.device == c.paNoDevice) defaultOutputDevice() else cfg.device;

            const output_params = c.PaStreamParameters{
                .device = device,
                .channelCount = cfg.channels,
                .sampleFormat = sampleFormat(SampleType),
                .suggestedLatency = 0.050,
                .hostApiSpecificStreamInfo = null,
            };

            const CallbackWrapper = struct {
                fn cb(
                    _: ?*const anyopaque,
                    output: ?*anyopaque,
                    frame_count: c_ulong,
                    _: [*c]const c.PaStreamCallbackTimeInfo,
                    _: c.PaStreamCallbackFlags,
                    user: ?*anyopaque,
                ) callconv(.c) c_int {
                    const cb_ptr: Callback = @ptrCast(@alignCast(user));
                    const out_ptr: [*]SampleType = @ptrCast(@alignCast(output));
                    const total_samples = frame_count * @as(c_ulong, @intCast(cfg.channels));
                    const result = cb_ptr(out_ptr[0..total_samples], frame_count, null);
                    return @intFromEnum(result);
                }
            };

            try check(c.Pa_OpenStream(
                &self.stream,
                null,
                &output_params,
                cfg.sample_rate,
                @intCast(cfg.frames_per_buffer),
                c.paClipOff,
                CallbackWrapper.cb,
                @ptrCast(@constCast(callback)),
            ));

            _ = user_data;
            return self;
        }

        pub fn close(self: *Self) void {
            if (self.stream) |s| {
                _ = c.Pa_CloseStream(s);
                self.stream = null;
            }
        }

        pub fn start(self: *Self) Error!void {
            if (self.stream) |s| {
                try check(c.Pa_StartStream(s));
            }
        }

        pub fn stop(self: *Self) Error!void {
            if (self.stream) |s| {
                try check(c.Pa_StopStream(s));
            }
        }
    };
}

// ============================================================================
// Helpers
// ============================================================================

fn sampleFormat(comptime T: type) c.PaSampleFormat {
    return switch (T) {
        f32 => c.paFloat32,
        i32 => c.paInt32,
        i16 => c.paInt16,
        i8 => c.paInt8,
        u8 => c.paUInt8,
        else => @compileError("Unsupported sample type"),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "version" {
    const version = versionText();
    try std.testing.expect(version.len > 0);
}
