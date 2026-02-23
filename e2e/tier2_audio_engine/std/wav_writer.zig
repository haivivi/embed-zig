//! Simple WAV file writer for 16-bit mono PCM
const std = @import("std");

pub const WavWriter = struct {
    file: std.fs.File,
    sample_rate: u32,
    num_samples: u32,

    pub fn init(path: []const u8, sample_rate: u32) !WavWriter {
        const file = try std.fs.cwd().createFile(path, .{});

        // Write WAV header placeholder (44 bytes)
        // We'll update num_samples when closing
        const header = [_]u8{0} ** 44;
        try file.writeAll(&header);

        return WavWriter{
            .file = file,
            .sample_rate = sample_rate,
            .num_samples = 0,
        };
    }

    pub fn writeSamples(self: *WavWriter, samples: []const i16) !void {
        // Write little-endian i16 samples
        for (samples) |s| {
            const bytes = [_]u8{
                @intCast(s & 0xFF),
                @intCast((s >> 8) & 0xFF),
            };
            try self.file.writeAll(&bytes);
        }
        self.num_samples += @intCast(samples.len);
    }

    pub fn close(self: *WavWriter) !void {
        // Update WAV header with actual data
        const data_size = self.num_samples * 2;  // 2 bytes per i16 sample
        const file_size = data_size + 36;

        // Seek to beginning and write header
        try self.file.seekTo(0);

        // "RIFF" chunk
        try self.file.writeAll("RIFF");
        try writeU32LE(self.file, file_size);
        try self.file.writeAll("WAVE");

        // "fmt " subchunk
        try self.file.writeAll("fmt ");
        try writeU32LE(self.file, 16);  // Subchunk1Size
        try writeU16LE(self.file, 1);   // AudioFormat (PCM)
        try writeU16LE(self.file, 1);   // NumChannels (mono)
        try writeU32LE(self.file, self.sample_rate);
        try writeU32LE(self.file, self.sample_rate * 2);  // ByteRate
        try writeU16LE(self.file, 2);   // BlockAlign
        try writeU16LE(self.file, 16);  // BitsPerSample

        // "data" subchunk
        try self.file.writeAll("data");
        try writeU32LE(self.file, data_size);

        self.file.close();
    }

    fn writeU16LE(file: std.fs.File, value: u16) !void {
        const bytes = [_]u8{
            @intCast(value & 0xFF),
            @intCast((value >> 8) & 0xFF),
        };
        try file.writeAll(&bytes);
    }

    fn writeU32LE(file: std.fs.File, value: u32) !void {
        const bytes = [_]u8{
            @intCast(value & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast((value >> 16) & 0xFF),
            @intCast((value >> 24) & 0xFF),
        };
        try file.writeAll(&bytes);
    }
};
