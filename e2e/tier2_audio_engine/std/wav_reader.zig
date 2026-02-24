//! Simple WAV file reader for 16-bit mono PCM
const std = @import("std");

pub const WavReader = struct {
    file: std.fs.File,
    num_samples: u32,
    current_sample: u32,
    sample_rate: u32,

    pub fn init(path: []const u8) !WavReader {
        const file = try std.fs.cwd().openFile(path, .{});

        // Read and validate WAV header
        var header_buf: [44]u8 = undefined;
        _ = try file.readAll(&header_buf);

        // Check RIFF header
        if (!std.mem.eql(u8, header_buf[0..4], "RIFF")) {
            return error.InvalidWavHeader;
        }
        // Check WAVE format
        if (!std.mem.eql(u8, header_buf[8..12], "WAVE")) {
            return error.InvalidWavHeader;
        }

        // Get sample rate (bytes 24-27, little endian)
        const sample_rate = readU32LE(header_buf[24..28]);

        // Get data size (bytes 40-43)
        const data_size = readU32LE(header_buf[40..44]);
        const num_samples = data_size / 2;  // 2 bytes per i16 sample

        return WavReader{
            .file = file,
            .num_samples = num_samples,
            .current_sample = 0,
            .sample_rate = sample_rate,
        };
    }

    pub fn readSamples(self: *WavReader, buffer: []i16) !usize {
        if (self.current_sample >= self.num_samples) return 0;

        const remaining = self.num_samples - self.current_sample;
        const to_read = @min(buffer.len, remaining);

        // Support up to 2048 samples (4096 bytes) for FFT analysis
        var bytes_buf: [4096]u8 = undefined;
        const bytes_to_read = to_read * 2;
        const n = try self.file.readAll(bytes_buf[0..bytes_to_read]);

        if (n < bytes_to_read) return 0;

        for (0..to_read) |i| {
            const b0: u16 = bytes_buf[i * 2];
            const b1: u16 = bytes_buf[i * 2 + 1];
            const uval: u16 = b0 | (b1 << 8);
            buffer[i] = @bitCast(uval);
        }

        self.current_sample += to_read;
        return to_read;
    }

    pub fn deinit(self: *WavReader) void {
        self.file.close();
    }

    fn readU32LE(bytes: []const u8) u32 {
        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
    }
};
