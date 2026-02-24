//! PortAudio blocking-mode audio I/O for std platform.
//!
//! DuplexAudio wraps a single blocking Stream into Mic, Speaker, and RefReader.
//! All three share the same stream opened in full-duplex mode.
//!
//! Loop:
//!   stream.read(&mic_buf)   → blocking, returns one frame of mic audio
//!   process(mic_buf, ref)   → AEC etc.
//!   stream.write(&out_buf)  → blocking, plays one frame
//!
//! RefReader returns the audio that was written to the speaker N frames ago,
//! acting as the AEC reference signal.

const std = @import("std");
const pa = @import("portaudio");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

// Ring buffer capacity: 128 frames (~1.28s)
const REF_CAP = FRAME_SIZE * 128;

pub const DuplexAudio = struct {
    stream: pa.Stream,
    allocator: std.mem.Allocator,

    // Reference ring: stores speaker output for AEC
    ref_ring: [REF_CAP]i16,
    ref_write: usize, // next write position (absolute)
    ref_read: usize, // next read position (absolute)

    running: bool,

    pub fn init(allocator: std.mem.Allocator) !DuplexAudio {
        var stream = try pa.Stream.open(allocator, .{
            .input_channels = 1,
            .output_channels = 1,
            .sample_rate = @floatFromInt(SAMPLE_RATE),
            .frames_per_buffer = FRAME_SIZE,
        });
        errdefer stream.close();
        try stream.start();

        return .{
            .stream = stream,
            .allocator = allocator,
            .ref_ring = [_]i16{0} ** REF_CAP,
            .ref_write = 0,
            .ref_read = 0,
            .running = true,
        };
    }

    pub fn stop(self: *DuplexAudio) void {
        self.running = false;
        self.stream.close();
    }

    // -------------------------------------------------------------------------
    // Mic: read one frame from the hardware
    // -------------------------------------------------------------------------
    pub const Mic = struct {
        parent: *DuplexAudio,

        pub fn read(self: *Mic, buf: []i16) !usize {
            return self.parent.stream.read(buf);
        }
    };

    // -------------------------------------------------------------------------
    // Speaker: write one frame to the hardware AND push to ref_ring
    // -------------------------------------------------------------------------
    pub const Speaker = struct {
        parent: *DuplexAudio,

        pub fn write(self: *Speaker, buf: []const i16) !usize {
            try self.parent.stream.write(buf);

            // Record what we played for RefReader
            const n = @min(buf.len, FRAME_SIZE);
            for (0..n) |i| {
                self.parent.ref_ring[(self.parent.ref_write + i) % REF_CAP] = buf[i];
            }
            self.parent.ref_write += n;

            return n;
        }

        pub fn setVolume(_: *Speaker, _: u8) !void {}
    };

    // -------------------------------------------------------------------------
    // RefReader: returns the last frame written to the speaker
    // (immediately: blocking mode means ref is already synchronous with mic)
    // -------------------------------------------------------------------------
    pub const RefReader = struct {
        parent: *DuplexAudio,

        pub fn read(self: *RefReader, buf: []i16) !usize {
            const n = @min(buf.len, FRAME_SIZE);

            // Not enough written yet — return silence
            if (self.parent.ref_write < n) {
                @memset(buf[0..n], 0);
                return n;
            }

            const start = self.parent.ref_write - n;
            for (0..n) |i| {
                buf[i] = self.parent.ref_ring[(start + i) % REF_CAP];
            }
            self.parent.ref_read = self.parent.ref_write;
            return n;
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

    pub fn getRefOffset(_: *DuplexAudio) i32 {
        return 0; // blocking mode: offset is always 0
    }
};
