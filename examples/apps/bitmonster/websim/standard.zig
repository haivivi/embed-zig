//! WebSim BitMonster Board wiring

const websim = @import("websim");
const board = websim.boards.bitmonster;

pub const ButtonId = board.ButtonId;
pub const adc_button_spec = board.adc_button_spec;
pub const power_button_spec = board.power_button_spec;
pub const rtc_spec = board.rtc_spec;

pub const FsDriver = websim.EmbedFs(&.{
    // Font
    .{ .path = "/fonts/NotoSansSC-Bold.ttf", .data = @embedFile("../assets/NotoSansSC-Bold.ttf") },
    // Main map icons (32x32)
    .{ .path = "/icons/house.icon", .data = @embedFile("../assets/icons/house.icon") },
    .{ .path = "/icons/fork-knife.icon", .data = @embedFile("../assets/icons/fork-knife.icon") },
    .{ .path = "/icons/book-open.icon", .data = @embedFile("../assets/icons/book-open.icon") },
    .{ .path = "/icons/first-aid.icon", .data = @embedFile("../assets/icons/first-aid.icon") },
    .{ .path = "/icons/paw-print.icon", .data = @embedFile("../assets/icons/paw-print.icon") },
    .{ .path = "/icons/barbell.icon", .data = @embedFile("../assets/icons/barbell.icon") },
    .{ .path = "/icons/game-controller.icon", .data = @embedFile("../assets/icons/game-controller.icon") },
    .{ .path = "/icons/clover.icon", .data = @embedFile("../assets/icons/clover.icon") },
    .{ .path = "/icons/shopping-bag.icon", .data = @embedFile("../assets/icons/shopping-bag.icon") },
    .{ .path = "/icons/arrow-left.icon", .data = @embedFile("../assets/icons/arrow-left.icon") },
    // Home sub-menu icons (24x24)
    .{ .path = "/icons/moon-stars.icon", .data = @embedFile("../assets/icons/moon-stars.icon") },
    .{ .path = "/icons/cooking-pot.icon", .data = @embedFile("../assets/icons/cooking-pot.icon") },
    .{ .path = "/icons/shower.icon", .data = @embedFile("../assets/icons/shower.icon") },
    .{ .path = "/icons/toilet.icon", .data = @embedFile("../assets/icons/toilet.icon") },
    .{ .path = "/icons/broom.icon", .data = @embedFile("../assets/icons/broom.icon") },
    .{ .path = "/icons/puzzle-piece.icon", .data = @embedFile("../assets/icons/puzzle-piece.icon") },
    .{ .path = "/icons/television.icon", .data = @embedFile("../assets/icons/television.icon") },
    .{ .path = "/icons/users.icon", .data = @embedFile("../assets/icons/users.icon") },
});

pub const fs_spec = struct {
    pub const Driver = FsDriver;
    pub const meta = .{ .id = "fs.assets" };
};
