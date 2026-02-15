//! WebSim H106 Board wiring — includes EmbedFs with UI assets

const websim = @import("websim");
const board = websim.boards.h106;

pub const ButtonId = board.ButtonId;
pub const adc_button_spec = board.adc_button_spec;
pub const log = board.log;
pub const time = board.time;

/// EmbedFs file table — assets embedded at compile time.
/// On ESP32, these same paths would be served by SPIFFS.
pub const FsDriver = websim.EmbedFs(&.{
    .{ .path = "/assets/bg.rgb565", .data = @embedFile("../assets/bg.rgb565") },
    .{ .path = "/assets/ultraman.rgb565", .data = @embedFile("../assets/ultraman.rgb565") },
    .{ .path = "/assets/menu_item0.rgb565", .data = @embedFile("../assets/menu_item0.rgb565") },
    .{ .path = "/assets/menu_item1.rgb565", .data = @embedFile("../assets/menu_item1.rgb565") },
    .{ .path = "/assets/menu_item2.rgb565", .data = @embedFile("../assets/menu_item2.rgb565") },
    .{ .path = "/assets/menu_item3.rgb565", .data = @embedFile("../assets/menu_item3.rgb565") },
    .{ .path = "/assets/menu_item4.rgb565", .data = @embedFile("../assets/menu_item4.rgb565") },
});

pub const fs_spec = struct {
    pub const Driver = FsDriver;
    pub const meta = .{ .id = "fs.assets" };
};
