//! NDEF (NFC Data Exchange Format) Parser
//!
//! Implements NFC Forum NDEF specification for parsing and encoding
//! NDEF messages and records.
//!
//! Reference: NFC Forum NDEF 1.0 Specification

const std = @import("std");

/// Type Name Format (TNF) - 3 bits
pub const TypeNameFormat = enum(u3) {
    empty = 0x00, // Empty record
    well_known = 0x01, // NFC Forum well-known type (RTD)
    media = 0x02, // RFC 2046 media type
    absolute_uri = 0x03, // RFC 3986 absolute URI
    external = 0x04, // NFC Forum external type
    unknown = 0x05, // Unknown type
    unchanged = 0x06, // Unchanged (for chunked records)
    reserved = 0x07, // Reserved
};

/// Record Type Definition (RTD) for well-known types
pub const Rtd = struct {
    pub const TEXT: []const u8 = "T"; // Text record
    pub const URI: []const u8 = "U"; // URI record
    pub const SMART_POSTER: []const u8 = "Sp"; // Smart Poster
    pub const ALTERNATIVE_CARRIER: []const u8 = "ac";
    pub const HANDOVER_CARRIER: []const u8 = "Hc";
    pub const HANDOVER_REQUEST: []const u8 = "Hr";
    pub const HANDOVER_SELECT: []const u8 = "Hs";
    pub const SIGNATURE: []const u8 = "Sig";
};

/// URI Identifier Codes (for RTD_URI)
pub const UriPrefix = enum(u8) {
    none = 0x00,
    http_www = 0x01, // http://www.
    https_www = 0x02, // https://www.
    http = 0x03, // http://
    https = 0x04, // https://
    tel = 0x05, // tel:
    mailto = 0x06, // mailto:
    ftp_anon = 0x07, // ftp://anonymous:anonymous@
    ftp_ftp = 0x08, // ftp://ftp.
    ftps = 0x09, // ftps://
    sftp = 0x0A, // sftp://
    smb = 0x0B, // smb://
    nfs = 0x0C, // nfs://
    ftp = 0x0D, // ftp://
    dav = 0x0E, // dav://
    news = 0x0F, // news:
    telnet = 0x10, // telnet://
    imap = 0x11, // imap:
    rtsp = 0x12, // rtsp://
    urn = 0x13, // urn:
    pop = 0x14, // pop:
    sip = 0x15, // sip:
    sips = 0x16, // sips:
    tftp = 0x17, // tftp:
    btspp = 0x18, // btspp://
    btl2cap = 0x19, // btl2cap://
    btgoep = 0x1A, // btgoep://
    tcpobex = 0x1B, // tcpobex://
    irdaobex = 0x1C, // irdaobex://
    file = 0x1D, // file://
    urn_epc_id = 0x1E, // urn:epc:id:
    urn_epc_tag = 0x1F, // urn:epc:tag:
    urn_epc_pat = 0x20, // urn:epc:pat:
    urn_epc_raw = 0x21, // urn:epc:raw:
    urn_epc = 0x22, // urn:epc:
    urn_nfc = 0x23, // urn:nfc:

    pub fn toString(self: UriPrefix) []const u8 {
        return switch (self) {
            .none => "",
            .http_www => "http://www.",
            .https_www => "https://www.",
            .http => "http://",
            .https => "https://",
            .tel => "tel:",
            .mailto => "mailto:",
            .ftp => "ftp://",
            .file => "file://",
            else => "", // TODO: add more
        };
    }
};

/// NDEF Record Header flags
pub const RecordFlags = packed struct {
    tnf: TypeNameFormat, // bits 0-2: Type Name Format
    il: bool, // bit 3: ID Length present
    sr: bool, // bit 4: Short Record (1-byte payload length)
    cf: bool, // bit 5: Chunk Flag
    me: bool, // bit 6: Message End
    mb: bool, // bit 7: Message Begin
};

/// NDEF Record
pub const Record = struct {
    flags: RecordFlags,
    type_data: []const u8,
    id: []const u8,
    payload: []const u8,

    // Internal storage for parsed record
    _type_buf: [256]u8 = undefined,
    _id_buf: [256]u8 = undefined,
    _payload_buf: [1024]u8 = undefined,

    /// Get TNF
    pub fn getTnf(self: *const Record) TypeNameFormat {
        return self.flags.tnf;
    }

    /// Check if this is a well-known type record
    pub fn isWellKnown(self: *const Record) bool {
        return self.flags.tnf == .well_known;
    }

    /// Check if this is a URI record
    pub fn isUri(self: *const Record) bool {
        return self.isWellKnown() and std.mem.eql(u8, self.type_data, Rtd.URI);
    }

    /// Check if this is a Text record
    pub fn isText(self: *const Record) bool {
        return self.isWellKnown() and std.mem.eql(u8, self.type_data, Rtd.TEXT);
    }

    /// Get URI from URI record
    pub fn getUri(self: *const Record, buf: []u8) ?[]const u8 {
        if (!self.isUri() or self.payload.len < 1) return null;

        const prefix_code: UriPrefix = @enumFromInt(self.payload[0]);
        const prefix_str = prefix_code.toString();
        const uri_part = self.payload[1..];

        if (prefix_str.len + uri_part.len > buf.len) return null;

        @memcpy(buf[0..prefix_str.len], prefix_str);
        @memcpy(buf[prefix_str.len..][0..uri_part.len], uri_part);

        return buf[0 .. prefix_str.len + uri_part.len];
    }

    /// Get text content from Text record
    pub fn getText(self: *const Record) ?[]const u8 {
        if (!self.isText() or self.payload.len < 1) return null;

        const status_byte = self.payload[0];
        const lang_len = status_byte & 0x3F;

        if (self.payload.len < 1 + lang_len) return null;

        return self.payload[1 + lang_len ..];
    }

    /// Get language code from Text record
    pub fn getTextLanguage(self: *const Record, buf: []u8) ?[]const u8 {
        if (!self.isText() or self.payload.len < 1) return null;

        const status_byte = self.payload[0];
        const lang_len = status_byte & 0x3F;

        if (self.payload.len < 1 + lang_len or lang_len > buf.len) return null;

        @memcpy(buf[0..lang_len], self.payload[1..][0..lang_len]);
        return buf[0..lang_len];
    }
};

/// NDEF Message (collection of records)
pub const Message = struct {
    records: []Record,
    record_count: usize = 0,

    _records_buf: [16]Record = undefined,

    /// Parse NDEF message from raw bytes
    pub fn parse(data: []const u8) !Message {
        var msg = Message{
            .records = &.{},
        };

        var offset: usize = 0;
        var record_idx: usize = 0;

        while (offset < data.len and record_idx < msg._records_buf.len) {
            const record = try parseRecord(data[offset..], &msg._records_buf[record_idx]);
            offset += getRecordSize(data[offset..]) orelse return error.InvalidFormat;
            record_idx += 1;
            _ = record;

            // Check for Message End flag
            if (msg._records_buf[record_idx - 1].flags.me) break;
        }

        msg.record_count = record_idx;
        msg.records = msg._records_buf[0..record_idx];

        return msg;
    }

    /// Get first record
    pub fn getFirst(self: *const Message) ?*const Record {
        if (self.record_count > 0) {
            return &self.records[0];
        }
        return null;
    }

    /// Find first record by type
    pub fn findByType(self: *const Message, type_data: []const u8) ?*const Record {
        for (self.records[0..self.record_count]) |*rec| {
            if (std.mem.eql(u8, rec.type_data, type_data)) {
                return rec;
            }
        }
        return null;
    }
};

/// Parse a single NDEF record
fn parseRecord(data: []const u8, out: *Record) !*Record {
    if (data.len < 3) return error.BufferTooSmall;

    const flags: RecordFlags = @bitCast(data[0]);
    const type_len = data[1];

    var offset: usize = 2;

    // Payload length (1 or 4 bytes)
    var payload_len: u32 = 0;
    if (flags.sr) {
        payload_len = data[offset];
        offset += 1;
    } else {
        if (offset + 4 > data.len) return error.BufferTooSmall;
        payload_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
    }

    // ID length (optional)
    var id_len: u8 = 0;
    if (flags.il) {
        id_len = data[offset];
        offset += 1;
    }

    // Type field
    if (offset + type_len > data.len) return error.BufferTooSmall;
    @memcpy(out._type_buf[0..type_len], data[offset..][0..type_len]);
    out.type_data = out._type_buf[0..type_len];
    offset += type_len;

    // ID field (optional)
    if (id_len > 0) {
        if (offset + id_len > data.len) return error.BufferTooSmall;
        @memcpy(out._id_buf[0..id_len], data[offset..][0..id_len]);
        out.id = out._id_buf[0..id_len];
        offset += id_len;
    } else {
        out.id = &.{};
    }

    // Payload
    if (offset + payload_len > data.len) return error.BufferTooSmall;
    if (payload_len > out._payload_buf.len) return error.PayloadTooLarge;
    @memcpy(out._payload_buf[0..payload_len], data[offset..][0..payload_len]);
    out.payload = out._payload_buf[0..payload_len];

    out.flags = flags;

    return out;
}

/// Calculate record size in bytes
fn getRecordSize(data: []const u8) ?usize {
    if (data.len < 3) return null;

    const flags: RecordFlags = @bitCast(data[0]);
    const type_len = data[1];

    var size: usize = 2;

    // Payload length field
    if (flags.sr) {
        if (data.len < size + 1) return null;
        size += 1 + data[size]; // 1 byte length + payload
    } else {
        if (data.len < size + 4) return null;
        const payload_len = std.mem.readInt(u32, data[size..][0..4], .big);
        size += 4 + payload_len;
    }

    // ID length field
    if (flags.il) {
        if (data.len < size + 1) return null;
        size += 1 + data[size - 1]; // Already counted, adjust
    }

    size += type_len;

    return size;
}

/// Create a URI record
pub fn createUriRecord(uri: []const u8, buf: []u8) ![]const u8 {
    // Simple implementation: prefix code 0x00 (no abbreviation)
    if (uri.len + 7 > buf.len) return error.BufferTooSmall;

    var offset: usize = 0;

    // Flags: MB=1, ME=1, SR=1, TNF=well_known
    buf[offset] = 0xD1;
    offset += 1;

    // Type length
    buf[offset] = 1; // "U"
    offset += 1;

    // Payload length
    buf[offset] = @intCast(uri.len + 1);
    offset += 1;

    // Type
    buf[offset] = 'U';
    offset += 1;

    // Payload: prefix code + URI
    buf[offset] = 0x00; // No prefix
    offset += 1;
    @memcpy(buf[offset..][0..uri.len], uri);
    offset += uri.len;

    return buf[0..offset];
}

/// Create a Text record
pub fn createTextRecord(text: []const u8, lang: []const u8, buf: []u8) ![]const u8 {
    if (text.len + lang.len + 8 > buf.len) return error.BufferTooSmall;

    var offset: usize = 0;

    // Flags: MB=1, ME=1, SR=1, TNF=well_known
    buf[offset] = 0xD1;
    offset += 1;

    // Type length
    buf[offset] = 1; // "T"
    offset += 1;

    // Payload length
    buf[offset] = @intCast(1 + lang.len + text.len);
    offset += 1;

    // Type
    buf[offset] = 'T';
    offset += 1;

    // Payload: status byte (UTF-8, lang length) + lang + text
    buf[offset] = @intCast(lang.len & 0x3F); // UTF-8
    offset += 1;
    @memcpy(buf[offset..][0..lang.len], lang);
    offset += lang.len;
    @memcpy(buf[offset..][0..text.len], text);
    offset += text.len;

    return buf[0..offset];
}

// =========== Tests ===========

test "parse URI record" {
    // NDEF URI record: https://example.com
    const data = [_]u8{
        0xD1, // MB=1, ME=1, CF=0, SR=1, IL=0, TNF=001 (well-known)
        0x01, // Type length = 1
        0x0C, // Payload length = 12 (1 prefix + 11 chars)
        'U', // Type = "U" (URI)
        0x04, // Prefix: https://
        'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm',
    };

    const msg = try Message.parse(&data);
    try std.testing.expectEqual(@as(usize, 1), msg.record_count);

    const rec = msg.getFirst().?;
    try std.testing.expect(rec.isUri());

    var uri_buf: [256]u8 = undefined;
    const uri = rec.getUri(&uri_buf);
    try std.testing.expectEqualStrings("https://example.com", uri.?);
}

test "parse Text record" {
    // NDEF Text record: "Hello" in English
    const data = [_]u8{
        0xD1, // Flags
        0x01, // Type length = 1
        0x08, // Payload length = 8
        'T', // Type = "T" (Text)
        0x02, // Status: UTF-8, lang len = 2
        'e', 'n', // Language = "en"
        'H', 'e', 'l', 'l', 'o', // Text
    };

    const msg = try Message.parse(&data);
    const rec = msg.getFirst().?;

    try std.testing.expect(rec.isText());
    try std.testing.expectEqualStrings("Hello", rec.getText().?);

    var lang_buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("en", rec.getTextLanguage(&lang_buf).?);
}

test "create URI record" {
    var buf: [256]u8 = undefined;
    const record = try createUriRecord("example.com", &buf);

    try std.testing.expectEqual(@as(u8, 0xD1), record[0]); // Flags
    try std.testing.expectEqual(@as(u8, 'U'), record[3]); // Type
}
