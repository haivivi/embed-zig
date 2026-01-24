//! ESP-IDF System types and error codes

const c = @cImport({
    @cInclude("sdkconfig.h");
    @cInclude("esp_err.h");
});

// Re-export C types
pub const esp_err_t = c.esp_err_t;

// Error codes
pub const ESP_OK = c.ESP_OK;
pub const ESP_FAIL = c.ESP_FAIL;
pub const ESP_ERR_NO_MEM = c.ESP_ERR_NO_MEM;
pub const ESP_ERR_INVALID_ARG = c.ESP_ERR_INVALID_ARG;
pub const ESP_ERR_INVALID_STATE = c.ESP_ERR_INVALID_STATE;
pub const ESP_ERR_INVALID_SIZE = c.ESP_ERR_INVALID_SIZE;
pub const ESP_ERR_NOT_FOUND = c.ESP_ERR_NOT_FOUND;
pub const ESP_ERR_NOT_SUPPORTED = c.ESP_ERR_NOT_SUPPORTED;
pub const ESP_ERR_TIMEOUT = c.ESP_ERR_TIMEOUT;

/// Zig error type for ESP-IDF errors
pub const EspError = error{
    Fail,
    NoMem,
    InvalidArg,
    InvalidState,
    InvalidSize,
    NotFound,
    NotSupported,
    Timeout,
    Unknown,
};

/// Convert esp_err_t to Zig error
pub fn espErrToZig(err: esp_err_t) EspError!void {
    return switch (err) {
        ESP_OK => {},
        ESP_FAIL => error.Fail,
        ESP_ERR_NO_MEM => error.NoMem,
        ESP_ERR_INVALID_ARG => error.InvalidArg,
        ESP_ERR_INVALID_STATE => error.InvalidState,
        ESP_ERR_INVALID_SIZE => error.InvalidSize,
        ESP_ERR_NOT_FOUND => error.NotFound,
        ESP_ERR_NOT_SUPPORTED => error.NotSupported,
        ESP_ERR_TIMEOUT => error.Timeout,
        else => error.Unknown,
    };
}
