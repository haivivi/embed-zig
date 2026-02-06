//! Zig bindings for libogg
//!
//! libogg is a library for reading and writing Ogg bitstreams.
//! This module provides a Zig-friendly interface to the C library.
//!
//! Ogg is a multimedia container format that can multiplex audio, video,
//! and other data streams.

const std = @import("std");
const c = @cImport({
    @cInclude("ogg/ogg.h");
});

// =============================================================================
// Type aliases
// =============================================================================

/// Sync state for reading Ogg streams
pub const SyncState = c.ogg_sync_state;

/// Stream state for a logical bitstream
pub const StreamState = c.ogg_stream_state;

/// An Ogg page (header + body)
pub const Page = c.ogg_page;

/// An Ogg packet
pub const Packet = c.ogg_packet;

// =============================================================================
// Sync (for reading Ogg streams)
// =============================================================================

/// Ogg sync state wrapper for reading streams
pub const Sync = struct {
    state: SyncState,

    const Self = @This();

    /// Initialize sync state
    pub fn init() Self {
        var self = Self{ .state = undefined };
        _ = c.ogg_sync_init(&self.state);
        return self;
    }

    /// Clean up sync state
    pub fn deinit(self: *Self) void {
        _ = c.ogg_sync_clear(&self.state);
    }

    /// Reset sync state
    pub fn reset(self: *Self) void {
        _ = c.ogg_sync_reset(&self.state);
    }

    /// Get a buffer to write data into
    ///
    /// Returns a slice of the requested size that you can write to.
    /// Call `wrote()` after writing to indicate how many bytes were written.
    pub fn buffer(self: *Self, size: usize) ?[]u8 {
        const ptr = c.ogg_sync_buffer(&self.state, @intCast(size));
        if (ptr == null) return null;
        return ptr[0..size];
    }

    /// Tell the sync state how many bytes were written
    pub fn wrote(self: *Self, bytes: usize) !void {
        if (c.ogg_sync_wrote(&self.state, @intCast(bytes)) != 0) {
            return error.SyncWroteFailed;
        }
    }

    /// Try to extract a page from the sync buffer
    pub fn pageOut(self: *Self, page: *Page) PageOutResult {
        const ret = c.ogg_sync_pageout(&self.state, page);
        return switch (ret) {
            1 => .page_ready,
            0 => .need_more_data,
            else => .sync_lost,
        };
    }

    pub const PageOutResult = enum {
        /// A complete page is ready
        page_ready,
        /// More data is needed
        need_more_data,
        /// Sync was lost, garbage skipped
        sync_lost,
    };
};

// =============================================================================
// Stream (for encoding/decoding logical bitstreams)
// =============================================================================

/// Ogg stream state wrapper for a logical bitstream
pub const Stream = struct {
    state: StreamState,

    const Self = @This();

    /// Initialize stream state with serial number
    ///
    /// Each logical bitstream needs a unique serial number.
    pub fn init(serial: i32) Self {
        var self = Self{ .state = undefined };
        _ = c.ogg_stream_init(&self.state, serial);
        return self;
    }

    /// Clean up stream state
    pub fn deinit(self: *Self) void {
        _ = c.ogg_stream_clear(&self.state);
    }

    /// Reset stream state
    pub fn reset(self: *Self) void {
        _ = c.ogg_stream_reset(&self.state);
    }

    /// Reset stream state with new serial number
    pub fn resetSerial(self: *Self, serial: i32) void {
        _ = c.ogg_stream_reset_serialno(&self.state, serial);
    }

    // -------------------------------------------------------------------------
    // Decoding
    // -------------------------------------------------------------------------

    /// Add a page to the stream
    pub fn pageIn(self: *Self, page: *Page) !void {
        if (c.ogg_stream_pagein(&self.state, page) != 0) {
            return error.PageInFailed;
        }
    }

    /// Extract a packet from the stream
    pub fn packetOut(self: *Self, packet: *Packet) PacketOutResult {
        const ret = c.ogg_stream_packetout(&self.state, packet);
        return switch (ret) {
            1 => .packet_ready,
            0 => .need_more_data,
            else => .error_or_hole,
        };
    }

    /// Peek at the next packet without removing it
    pub fn packetPeek(self: *Self, packet: *Packet) PacketOutResult {
        const ret = c.ogg_stream_packetpeek(&self.state, packet);
        return switch (ret) {
            1 => .packet_ready,
            0 => .need_more_data,
            else => .error_or_hole,
        };
    }

    pub const PacketOutResult = enum {
        /// A complete packet is ready
        packet_ready,
        /// More data is needed
        need_more_data,
        /// Error or hole in data
        error_or_hole,
    };

    // -------------------------------------------------------------------------
    // Encoding
    // -------------------------------------------------------------------------

    /// Add a packet to the stream (for encoding)
    pub fn packetIn(self: *Self, packet: *Packet) !void {
        if (c.ogg_stream_packetin(&self.state, packet) != 0) {
            return error.PacketInFailed;
        }
    }

    /// Get a page from the stream (for encoding)
    ///
    /// Returns true if a page was produced.
    pub fn pageOut(self: *Self, page: *Page) bool {
        return c.ogg_stream_pageout(&self.state, page) != 0;
    }

    /// Force a page out (for encoding)
    ///
    /// Forces any remaining packets into a page even if not full.
    pub fn flush(self: *Self, page: *Page) bool {
        return c.ogg_stream_flush(&self.state, page) != 0;
    }
};

// =============================================================================
// Page helper functions
// =============================================================================

/// Get the Ogg version from a page
pub fn pageVersion(page: *const Page) c_int {
    return c.ogg_page_version(@constCast(page));
}

/// Check if page is a continuation of a packet
pub fn pageContinued(page: *const Page) bool {
    return c.ogg_page_continued(@constCast(page)) != 0;
}

/// Check if page is beginning of stream (BOS)
pub fn pageBos(page: *const Page) bool {
    return c.ogg_page_bos(@constCast(page)) != 0;
}

/// Check if page is end of stream (EOS)
pub fn pageEos(page: *const Page) bool {
    return c.ogg_page_eos(@constCast(page)) != 0;
}

/// Get granule position from page
pub fn pageGranulePos(page: *const Page) i64 {
    return c.ogg_page_granulepos(@constCast(page));
}

/// Get serial number from page
pub fn pageSerialNo(page: *const Page) c_int {
    return c.ogg_page_serialno(@constCast(page));
}

/// Get page number
pub fn pagePageNo(page: *const Page) c_long {
    return c.ogg_page_pageno(@constCast(page));
}

/// Get number of packets in page
pub fn pagePackets(page: *const Page) c_int {
    return c.ogg_page_packets(@constCast(page));
}

// =============================================================================
// Tests
// =============================================================================

test "sync state lifecycle" {
    var sync = Sync.init();
    defer sync.deinit();

    sync.reset();
}

test "stream state lifecycle" {
    var stream = Stream.init(12345);
    defer stream.deinit();

    stream.reset();
    stream.resetSerial(67890);
}

test "sync buffer" {
    var sync = Sync.init();
    defer sync.deinit();

    const buf = sync.buffer(4096);
    try std.testing.expect(buf != null);
    try std.testing.expect(buf.?.len == 4096);
}
