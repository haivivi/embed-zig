const std = @import("std");

const esp = @cImport({
    @cInclude("sdkconfig.h");
    @cInclude("esp_err.h");
    @cInclude("esp_log.h");
});

const freertos = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
});

const ledstrip = struct {
    const LedStrip = opaque {};

    const StripConfig = extern struct {
        strip_gpio_num: c_int = 0,
        max_leds: u32 = 0,
        led_pixel_format: c_int = 0,
        led_model: c_int = 0,
        flags: u32 = 0,
    };

    const RmtConfig = extern struct {
        clk_src: c_int = 0,
        resolution_hz: u32 = 0,
        mem_block_symbols: usize = 0,
        flags: u32 = 0,
    };

    extern fn led_strip_set_pixel(strip: *ledstrip.LedStrip, index: u32, red: u32, green: u32, blue: u32) c_int;
    extern fn led_strip_refresh(strip: *ledstrip.LedStrip) c_int;
    extern fn led_strip_clear(strip: *ledstrip.LedStrip) c_int;
    extern fn led_strip_new_rmt_device(led_config: *const StripConfig, rmt_config: *const RmtConfig, ret_strip: **ledstrip.LedStrip) c_int;
};

const BLINK_GPIO = esp.CONFIG_BLINK_GPIO;

const LedStrip = struct {
    state: bool = false,
    handle: *ledstrip.LedStrip = undefined,

    pub fn init() !LedStrip {
        const strip_config: ledstrip.StripConfig = .{
            .strip_gpio_num = BLINK_GPIO,
            .max_leds = 1,
        };

        const rmt_config: ledstrip.RmtConfig = .{
            .resolution_hz = 10_000_000,
        };

        var self: LedStrip = .{};
        switch (ledstrip.led_strip_new_rmt_device(&strip_config, &rmt_config, &self.handle)) {
            esp.ESP_OK => {},
            else => |e| {
                std.log.err("init failed: {}", .{e});
                return error.Other;
            },
        }

        try self.clear();
        return self;
    }

    pub fn clear(self: LedStrip) !void {
        switch (ledstrip.led_strip_clear(self.handle)) {
            esp.ESP_OK => {},
            else => |e| {
                std.log.err("clear failed: {}", .{e});
                return error.Other;
            },
        }
    }

    pub fn setPixel(self: LedStrip, index: u32, red: u32, green: u32, blue: u32) !void {
        switch (ledstrip.led_strip_set_pixel(self.handle, index, red, green, blue)) {
            esp.ESP_OK => {},
            else => |e| {
                std.log.err("setPixel failed: {}\n", .{e});
                return error.Other;
            },
        }
    }

    pub fn refresh(self: LedStrip) !void {
        switch (ledstrip.led_strip_refresh(self.handle)) {
            esp.ESP_OK => {},
            else => |e| {
                std.log.err("refresh failed: {}\n", .{e});
                return error.Other;
            },
        }
    }

    pub fn enable(self: LedStrip) !void {
        try self.setPixel(0, 16, 16, 16);
        try self.refresh();
    }

    pub fn disable(self: LedStrip) !void {
        try self.clear();
    }

    pub fn toggle(self: *LedStrip) !void {
        if (self.state) {
            try self.disable();
        } else {
            try self.enable();
        }

        self.state = !self.state;
    }
};

fn espLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = switch (message_level) {
        .err => "\x1b[31m", // red
        .warn => "\x1b[33m", // yellow
        .info => "\x1b[32m", // green
        .debug => "",
    };

    const esp_level = switch (message_level) {
        .err => esp.ESP_LOG_ERROR,
        .warn => esp.ESP_LOG_WARN,
        .info => esp.ESP_LOG_INFO,
        .debug => esp.ESP_LOG_DEBUG,
    };

    const prefix = switch (message_level) {
        .err => "E",
        .warn => "W",
        .info => "I",
        .debug => "D",
    };

    const fmt = std.fmt.comptimePrint(color ++ prefix ++ " (%u): {s}\x1b[0m\n", .{format});
    const timestamp = esp.esp_log_timestamp();
    @call(.auto, esp.esp_log_write, .{ esp_level, @tagName(scope), fmt, timestamp } ++ args);
}

pub const std_options: std.Options = .{
    .logFn = espLogFn,
};

export fn app_main() void {
    var strip = LedStrip.init() catch {
        @panic("Failed to initialize LED strip");
    };

    while (true) {
        std.log.info("Toggling the LED %s!", .{@as([:0]const u8, if (strip.state) "ON" else "OFF").ptr});
        strip.toggle() catch {
            @panic("Toggling the LED failed");
        };
        freertos.vTaskDelay(esp.CONFIG_BLINK_PERIOD / freertos.portTICK_PERIOD_MS);
    }
}
