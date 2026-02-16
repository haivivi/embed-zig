//! WebSim H106 Board wiring — includes EmbedFs with all UI assets

const websim = @import("websim");
const board = websim.boards.h106;

pub const ButtonId = board.ButtonId;
pub const adc_button_spec = board.adc_button_spec;
pub const log = board.log;
pub const time = board.time;

pub const FsDriver = websim.EmbedFs(&.{
    // Background + desktop
    .{ .path = "/assets/bg.rgb565", .data = @embedFile("../assets/bg.rgb565") },
    .{ .path = "/assets/ultraman.rgb565", .data = @embedFile("../assets/ultraman.rgb565") },
    // Menu icons (160x160)
    .{ .path = "/assets/menu_item0.rgb565", .data = @embedFile("../assets/menu_item0.rgb565") },
    .{ .path = "/assets/menu_item1.rgb565", .data = @embedFile("../assets/menu_item1.rgb565") },
    .{ .path = "/assets/menu_item2.rgb565", .data = @embedFile("../assets/menu_item2.rgb565") },
    .{ .path = "/assets/menu_item3.rgb565", .data = @embedFile("../assets/menu_item3.rgb565") },
    .{ .path = "/assets/menu_item4.rgb565", .data = @embedFile("../assets/menu_item4.rgb565") },
    // List selection background (224x56)
    .{ .path = "/assets/btn_list_item.rgb565", .data = @embedFile("../assets/btn_list_item.rgb565") },
    // Game icons (32x32)
    .{ .path = "/assets/icon_game_0.rgb565", .data = @embedFile("../assets/icon_game_0.rgb565") },
    .{ .path = "/assets/icon_game_1.rgb565", .data = @embedFile("../assets/icon_game_1.rgb565") },
    .{ .path = "/assets/icon_game_2.rgb565", .data = @embedFile("../assets/icon_game_2.rgb565") },
    .{ .path = "/assets/icon_game_3.rgb565", .data = @embedFile("../assets/icon_game_3.rgb565") },
    // Settings list icons (32x32)
    .{ .path = "/assets/listicon_0.rgb565", .data = @embedFile("../assets/listicon_0.rgb565") },
    .{ .path = "/assets/listicon_1.rgb565", .data = @embedFile("../assets/listicon_1.rgb565") },
    .{ .path = "/assets/listicon_2.rgb565", .data = @embedFile("../assets/listicon_2.rgb565") },
    .{ .path = "/assets/listicon_3.rgb565", .data = @embedFile("../assets/listicon_3.rgb565") },
    .{ .path = "/assets/listicon_4.rgb565", .data = @embedFile("../assets/listicon_4.rgb565") },
    .{ .path = "/assets/listicon_5.rgb565", .data = @embedFile("../assets/listicon_5.rgb565") },
    .{ .path = "/assets/listicon_6.rgb565", .data = @embedFile("../assets/listicon_6.rgb565") },
    .{ .path = "/assets/listicon_7.rgb565", .data = @embedFile("../assets/listicon_7.rgb565") },
    .{ .path = "/assets/listicon_8.rgb565", .data = @embedFile("../assets/listicon_8.rgb565") },
    // Font
    .{ .path = "/fonts/NotoSansSC-Bold.ttf", .data = @embedFile("../assets/NotoSansSC-Bold.ttf") },
    // Intro page assets
    .{ .path = "/assets/icon_haivivi.rgb565", .data = @embedFile("../assets/icon_haivivi.rgb565") },
    .{ .path = "/assets/intro_setting.rgb565", .data = @embedFile("../assets/intro_setting.rgb565") },
    .{ .path = "/assets/intro_list.rgb565", .data = @embedFile("../assets/intro_list.rgb565") },
    .{ .path = "/assets/intro_device.rgb565", .data = @embedFile("../assets/intro_device.rgb565") },
    .{ .path = "/assets/intro_arrow.rgb565", .data = @embedFile("../assets/intro_arrow.rgb565") },
    // Startup animation
    .{ .path = "/anim/startup.anim", .data = @embedFile("../assets/tiga_startup.anim") },
});

pub const fs_spec = struct {
    pub const Driver = FsDriver;
    pub const meta = .{ .id = "fs.assets" };
};
