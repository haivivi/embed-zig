//! ESP-IDF NVS (Non-Volatile Storage) wrapper
//!
//! Provides key-value storage in flash memory.

const std = @import("std");
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("nvs_flash.h");
    @cInclude("nvs.h");
});

pub const NvsError = error{
    NotInitialized,
    NotFound,
    TypeMismatch,
    ReadOnly,
    NotEnoughSpace,
    InvalidName,
    InvalidHandle,
    RemoveFailed,
    KeyTooLong,
    PageFull,
    InvalidState,
    InvalidLength,
    NoFreePages,
    NewVersionFound,
    Unknown,
};

/// Convert ESP NVS error to Zig error
fn espErrToNvs(err: c_int) NvsError!void {
    return switch (err) {
        c.ESP_OK => {},
        c.ESP_ERR_NVS_NOT_INITIALIZED => NvsError.NotInitialized,
        c.ESP_ERR_NVS_NOT_FOUND => NvsError.NotFound,
        c.ESP_ERR_NVS_TYPE_MISMATCH => NvsError.TypeMismatch,
        c.ESP_ERR_NVS_READ_ONLY => NvsError.ReadOnly,
        c.ESP_ERR_NVS_NOT_ENOUGH_SPACE => NvsError.NotEnoughSpace,
        c.ESP_ERR_NVS_INVALID_NAME => NvsError.InvalidName,
        c.ESP_ERR_NVS_INVALID_HANDLE => NvsError.InvalidHandle,
        c.ESP_ERR_NVS_REMOVE_FAILED => NvsError.RemoveFailed,
        c.ESP_ERR_NVS_KEY_TOO_LONG => NvsError.KeyTooLong,
        c.ESP_ERR_NVS_PAGE_FULL => NvsError.PageFull,
        c.ESP_ERR_NVS_INVALID_STATE => NvsError.InvalidState,
        c.ESP_ERR_NVS_INVALID_LENGTH => NvsError.InvalidLength,
        c.ESP_ERR_NVS_NO_FREE_PAGES => NvsError.NoFreePages,
        c.ESP_ERR_NVS_NEW_VERSION_FOUND => NvsError.NewVersionFound,
        else => NvsError.Unknown,
    };
}

/// Initialize NVS flash
pub fn init() NvsError!void {
    var ret = c.nvs_flash_init();
    if (ret == c.ESP_ERR_NVS_NO_FREE_PAGES or ret == c.ESP_ERR_NVS_NEW_VERSION_FOUND) {
        _ = c.nvs_flash_erase();
        ret = c.nvs_flash_init();
    }
    return espErrToNvs(ret);
}

/// Erase NVS flash
pub fn erase() NvsError!void {
    return espErrToNvs(c.nvs_flash_erase());
}

/// NVS Handle for a namespace
pub const Nvs = struct {
    handle: c.nvs_handle_t,

    /// Open NVS namespace
    pub fn open(namespace: [:0]const u8) NvsError!Nvs {
        var handle: c.nvs_handle_t = undefined;
        try espErrToNvs(c.nvs_open(namespace.ptr, c.NVS_READWRITE, &handle));
        return Nvs{ .handle = handle };
    }

    /// Open NVS namespace (read-only)
    pub fn openReadOnly(namespace: [:0]const u8) NvsError!Nvs {
        var handle: c.nvs_handle_t = undefined;
        try espErrToNvs(c.nvs_open(namespace.ptr, c.NVS_READONLY, &handle));
        return Nvs{ .handle = handle };
    }

    /// Close NVS handle
    pub fn close(self: *Nvs) void {
        c.nvs_close(self.handle);
    }

    /// Commit changes to flash
    pub fn commit(self: *Nvs) NvsError!void {
        return espErrToNvs(c.nvs_commit(self.handle));
    }

    /// Erase a key
    pub fn eraseKey(self: *Nvs, key: [:0]const u8) NvsError!void {
        return espErrToNvs(c.nvs_erase_key(self.handle, key.ptr));
    }

    /// Erase all keys in namespace
    pub fn eraseAll(self: *Nvs) NvsError!void {
        return espErrToNvs(c.nvs_erase_all(self.handle));
    }

    // ========== Integer types ==========

    pub fn setI8(self: *Nvs, key: [:0]const u8, value: i8) NvsError!void {
        return espErrToNvs(c.nvs_set_i8(self.handle, key.ptr, value));
    }

    pub fn getI8(self: *Nvs, key: [:0]const u8) NvsError!i8 {
        var value: i8 = undefined;
        try espErrToNvs(c.nvs_get_i8(self.handle, key.ptr, &value));
        return value;
    }

    pub fn setU8(self: *Nvs, key: [:0]const u8, value: u8) NvsError!void {
        return espErrToNvs(c.nvs_set_u8(self.handle, key.ptr, value));
    }

    pub fn getU8(self: *Nvs, key: [:0]const u8) NvsError!u8 {
        var value: u8 = undefined;
        try espErrToNvs(c.nvs_get_u8(self.handle, key.ptr, &value));
        return value;
    }

    pub fn setI16(self: *Nvs, key: [:0]const u8, value: i16) NvsError!void {
        return espErrToNvs(c.nvs_set_i16(self.handle, key.ptr, value));
    }

    pub fn getI16(self: *Nvs, key: [:0]const u8) NvsError!i16 {
        var value: i16 = undefined;
        try espErrToNvs(c.nvs_get_i16(self.handle, key.ptr, &value));
        return value;
    }

    pub fn setU16(self: *Nvs, key: [:0]const u8, value: u16) NvsError!void {
        return espErrToNvs(c.nvs_set_u16(self.handle, key.ptr, value));
    }

    pub fn getU16(self: *Nvs, key: [:0]const u8) NvsError!u16 {
        var value: u16 = undefined;
        try espErrToNvs(c.nvs_get_u16(self.handle, key.ptr, &value));
        return value;
    }

    pub fn setI32(self: *Nvs, key: [:0]const u8, value: i32) NvsError!void {
        return espErrToNvs(c.nvs_set_i32(self.handle, key.ptr, value));
    }

    pub fn getI32(self: *Nvs, key: [:0]const u8) NvsError!i32 {
        var value: i32 = undefined;
        try espErrToNvs(c.nvs_get_i32(self.handle, key.ptr, &value));
        return value;
    }

    pub fn setU32(self: *Nvs, key: [:0]const u8, value: u32) NvsError!void {
        return espErrToNvs(c.nvs_set_u32(self.handle, key.ptr, value));
    }

    pub fn getU32(self: *Nvs, key: [:0]const u8) NvsError!u32 {
        var value: u32 = undefined;
        try espErrToNvs(c.nvs_get_u32(self.handle, key.ptr, &value));
        return value;
    }

    pub fn setI64(self: *Nvs, key: [:0]const u8, value: i64) NvsError!void {
        return espErrToNvs(c.nvs_set_i64(self.handle, key.ptr, value));
    }

    pub fn getI64(self: *Nvs, key: [:0]const u8) NvsError!i64 {
        var value: i64 = undefined;
        try espErrToNvs(c.nvs_get_i64(self.handle, key.ptr, &value));
        return value;
    }

    pub fn setU64(self: *Nvs, key: [:0]const u8, value: u64) NvsError!void {
        return espErrToNvs(c.nvs_set_u64(self.handle, key.ptr, value));
    }

    pub fn getU64(self: *Nvs, key: [:0]const u8) NvsError!u64 {
        var value: u64 = undefined;
        try espErrToNvs(c.nvs_get_u64(self.handle, key.ptr, &value));
        return value;
    }

    // ========== String ==========

    pub fn setString(self: *Nvs, key: [:0]const u8, value: [:0]const u8) NvsError!void {
        return espErrToNvs(c.nvs_set_str(self.handle, key.ptr, value.ptr));
    }

    /// Get string length (not including null terminator)
    pub fn getStringLen(self: *Nvs, key: [:0]const u8) NvsError!usize {
        var len: usize = 0;
        try espErrToNvs(c.nvs_get_str(self.handle, key.ptr, null, &len));
        return if (len > 0) len - 1 else 0; // exclude null terminator
    }

    /// Get string into buffer
    pub fn getString(self: *Nvs, key: [:0]const u8, buf: []u8) NvsError![]u8 {
        var len: usize = buf.len;
        try espErrToNvs(c.nvs_get_str(self.handle, key.ptr, buf.ptr, &len));
        return if (len > 0) buf[0 .. len - 1] else buf[0..0];
    }

    // ========== Blob (binary data) ==========

    pub fn setBlob(self: *Nvs, key: [:0]const u8, data: []const u8) NvsError!void {
        return espErrToNvs(c.nvs_set_blob(self.handle, key.ptr, data.ptr, data.len));
    }

    /// Get blob length
    pub fn getBlobLen(self: *Nvs, key: [:0]const u8) NvsError!usize {
        var len: usize = 0;
        try espErrToNvs(c.nvs_get_blob(self.handle, key.ptr, null, &len));
        return len;
    }

    /// Get blob into buffer
    pub fn getBlob(self: *Nvs, key: [:0]const u8, buf: []u8) NvsError![]u8 {
        var len: usize = buf.len;
        try espErrToNvs(c.nvs_get_blob(self.handle, key.ptr, buf.ptr, &len));
        return buf[0..len];
    }
};
