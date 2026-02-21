//! PortAudio full-duplex audio I/O for std platform.
//!
//! DuplexAudio wraps a PortAudio DuplexStream callback into three driver
//! interfaces (Mic, Speaker, RefReader) that the AudioEngine can consume.
//!
//! Usage:
//!   const da = @import("std_impl").audio_engine;
//!   const audio = @import("audio");
//!
//!   // Duplex mode (RefReader gives precisely aligned ref)
//!   const Engine = audio.AudioEngine(Rt, da.DuplexAudio.Mic, da.DuplexAudio.Speaker, .{
//!       .RefReader = da.DuplexAudio.RefReader,
//!       .enable_aec = true,
//!   });
//!
//!   // Separate mode (buffer_depth compensates delay)
//!   const mic_drv = @import("std_impl").mic;
//!   const spk_drv = @import("std_impl").speaker;
//!   const Engine = audio.AudioEngine(Rt, mic_drv.Driver, spk_drv.Driver, .{
//!       .speaker_buffer_depth = 5,
//!       .enable_aec = true,
//!   });

const std = @import("std");
const pa = @import("portaudio");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

pub const DuplexAudio = struct {
    const RingCap = FRAME_SIZE * 64;

    mic_ring: [RingCap]i16,
    mic_write: usize,
    mic_read: usize,
    spk_ring: [RingCap]i16,
    spk_write: usize,
    spk_read: usize,
    ref_ring: [RingCap]i16,
    ref_write: usize,
    ref_read: usize,
    mutex: std.Thread.Mutex,
    mic_ready: std.Thread.Condition,
    spk_ready: std.Thread.Condition,
    duplex: pa.DuplexStream(i16),

    pub fn init() DuplexAudio {
        return .{
            .mic_ring = [_]i16{0} ** RingCap,
            .mic_write = 0,
            .mic_read = 0,
            .spk_ring = [_]i16{0} ** RingCap,
            .spk_write = 0,
            .spk_read = 0,
            .ref_ring = [_]i16{0} ** RingCap,
            .ref_write = 0,
            .ref_read = 0,
            .mutex = .{},
            .mic_ready = .{},
            .spk_ready = .{},
            .duplex = undefined,
        };
    }

    pub fn start(self: *DuplexAudio) !void {
        self.duplex.init(.{
            .sample_rate = @floatFromInt(SAMPLE_RATE),
            .channels = 1,
            .frames_per_buffer = FRAME_SIZE,
        }, duplexCallback, @ptrCast(self)) catch return error.PortAudioError;
        try self.duplex.start();
    }

    pub fn stop(self: *DuplexAudio) void {
        self.duplex.stop() catch {};
        self.duplex.close();
        self.mutex.lock();
        self.mic_ready.broadcast();
        self.spk_ready.broadcast();
        self.mutex.unlock();
    }

    pub fn deinit(_: *DuplexAudio) void {}

    fn duplexCallback(
        input: []const i16,
        output: []i16,
        _: usize,
        user_data: ?*anyopaque,
    ) pa.CallbackResult {
        const self: *DuplexAudio = @ptrCast(@alignCast(user_data));

        self.mutex.lock();
        defer self.mutex.unlock();

        // Push mic samples
        const n = @min(input.len, RingCap);
        for (0..n) |i| {
            self.mic_ring[(self.mic_write + i) % RingCap] = input[i];
        }
        self.mic_write += n;
        self.mic_ready.signal();

        // Pop speaker samples → output
        const avail = self.spk_write -| self.spk_read;
        const to_play = @min(avail, output.len);
        for (0..to_play) |i| {
            output[i] = self.spk_ring[(self.spk_read + i) % RingCap];
        }
        for (to_play..output.len) |i| {
            output[i] = 0;
        }
        self.spk_read += to_play;
        self.spk_ready.signal();

        // Copy actual output → ref_ring for AEC
        for (0..output.len) |i| {
            self.ref_ring[(self.ref_write + i) % RingCap] = output[i];
        }
        self.ref_write += output.len;

        return .Continue;
    }

    /// Mic driver: blocking read from duplex input ring
    pub const Mic = struct {
        parent: *DuplexAudio,

        pub fn read(self: *Mic, buf: []i16) !usize {
            self.parent.mutex.lock();
            defer self.parent.mutex.unlock();
            while (true) {
                const a = self.parent.mic_write -| self.parent.mic_read;
                if (a >= buf.len) {
                    for (0..buf.len) |i| {
                        buf[i] = self.parent.mic_ring[(self.parent.mic_read + i) % RingCap];
                    }
                    self.parent.mic_read += buf.len;
                    return buf.len;
                }
                self.parent.mic_ready.wait(&self.parent.mutex);
            }
        }
    };

    /// Speaker driver: blocking write to duplex output ring
    pub const Speaker = struct {
        parent: *DuplexAudio,

        pub fn write(self: *Speaker, buf: []const i16) !usize {
            self.parent.mutex.lock();
            defer self.parent.mutex.unlock();
            var offset: usize = 0;
            while (offset < buf.len) {
                const used = self.parent.spk_write -| self.parent.spk_read;
                const space = RingCap - used;
                if (space == 0) {
                    self.parent.spk_ready.wait(&self.parent.mutex);
                    continue;
                }
                const chunk = @min(buf.len - offset, space);
                for (0..chunk) |i| {
                    self.parent.spk_ring[(self.parent.spk_write + i) % RingCap] = buf[offset + i];
                }
                self.parent.spk_write += chunk;
                offset += chunk;
            }
            return buf.len;
        }

        pub fn setVolume(_: *Speaker, _: u8) !void {}
    };

    /// RefReader: reads the exact samples played by the speaker (callback-aligned)
    pub const RefReader = struct {
        parent: *DuplexAudio,

        pub fn read(self: *RefReader, buf: []i16) !usize {
            self.parent.mutex.lock();
            defer self.parent.mutex.unlock();
            while (true) {
                const a = self.parent.ref_write -| self.parent.ref_read;
                if (a >= buf.len) {
                    for (0..buf.len) |i| {
                        buf[i] = self.parent.ref_ring[(self.parent.ref_read + i) % RingCap];
                    }
                    self.parent.ref_read += buf.len;
                    return buf.len;
                }
                self.parent.mic_ready.wait(&self.parent.mutex);
            }
        }
    };

    pub fn mic(self: *DuplexAudio) Mic {
        return .{ .parent = self };
    }

    pub fn speaker(self: *DuplexAudio) Speaker {
        return .{ .parent = self };
    }

    pub fn refReader(self: *DuplexAudio) RefReader {
        return .{ .parent = self };
    }
};
