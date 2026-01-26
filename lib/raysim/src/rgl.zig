//! RGL (rGuiLayout) Parser - Comptime
//!
//! Parses .rgl layout files at compile time.
//!
//! ## RGL Format
//!
//! ```
//! # Comment
//! r <ref_x> <ref_y> <width> <height>           # Reference window
//! a <id> <name> <x> <y> <visible>              # Anchor
//! c <id> <type> <name> <x> <y> <w> <h> <anchor> <text>  # Control
//! ```
//!
//! ## Control Types (from rGuiLayout)
//!
//! | ID | Type |
//! |----|------|
//! | 0  | WindowBox |
//! | 1  | GroupBox |
//! | 2  | Line |
//! | 3  | Panel / Label |
//! | 4  | Label |
//! | 5  | Button |
//! | 6  | LabelButton |
//! | 7  | Toggle |
//! | 8  | ToggleGroup / CheckBox |
//! | 9  | ComboBox |
//! | 10 | DropdownBox |
//! | 11 | TextBox |
//! | 12 | ValueBox |
//! | 13 | Spinner |
//! | 14 | Slider |
//! | 15 | SliderBar |
//! | 16 | ProgressBar |
//! | 17 | StatusBar |
//! | 18 | ScrollPanel |
//! | 19 | ListView |
//! | 20 | ColorPicker |
//! | 21 | DummyRec |
//!
//! ## Custom Extensions (100+)
//!
//! | ID  | Type |
//! |-----|------|
//! | 100 | LED (single) |
//! | 101 | LED Strip |
//! | 102 | Log Panel |

const std = @import("std");

/// Control types
pub const ControlType = enum(u8) {
    window_box = 0,
    group_box = 1,
    line = 2,
    panel = 3,
    label = 4,
    button = 5,
    label_button = 6,
    toggle = 7,
    checkbox = 8,
    combo_box = 9,
    dropdown_box = 10,
    text_box = 11,
    value_box = 12,
    spinner = 13,
    slider = 14,
    slider_bar = 15,
    progress_bar = 16,
    status_bar = 17,
    scroll_panel = 18,
    list_view = 19,
    color_picker = 20,
    dummy_rec = 21,
    
    // Custom extensions for hardware simulation
    led = 100,
    led_strip = 101,
    log_panel = 102,
    
    unknown = 255,
    
    pub fn fromInt(val: u8) ControlType {
        return std.meta.intToEnum(ControlType, val) catch .unknown;
    }
};

/// Parsed control
pub const Control = struct {
    id: u16,
    type: ControlType,
    name: []const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    anchor: u8,
    text: []const u8,
};

/// Parsed layout with N controls
pub fn Layout(comptime N: usize) type {
    return struct {
        const Self = @This();
        
        controls: [N]Control,
        count: usize,
        ref_x: i32 = 0,
        ref_y: i32 = 0,
        
        /// Find control index by name
        pub fn findControl(self: Self, comptime name: []const u8) ?usize {
            for (self.controls, 0..) |ctrl, i| {
                if (std.mem.eql(u8, ctrl.name, name)) {
                    return i;
                }
            }
            return null;
        }
    };
}

/// Count controls in RGL content (for sizing the Layout type)
pub fn countControls(comptime content: []const u8) usize {
    @setEvalBranchQuota(10000);
    comptime {
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and trimmed[0] == 'c') {
                count += 1;
            }
        }
        return if (count == 0) 1 else count; // At least 1 to avoid zero-size array
    }
}

/// Parse RGL content at comptime
pub fn parse(comptime content: []const u8) Layout(countControls(content)) {
    @setEvalBranchQuota(50000);
    comptime {
        const N = countControls(content);
        var result: Layout(N) = .{
            .controls = undefined,
            .count = 0,
        };
        
        var lines = std.mem.splitScalar(u8, content, '\n');
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            if (trimmed[0] == 'r') {
                // Reference window: r <x> <y> <w> <h>
                const ref = parseRefWindow(trimmed);
                result.ref_x = ref.x;
                result.ref_y = ref.y;
            } else if (trimmed[0] == 'c') {
                // Control: c <id> <type> <name> <x> <y> <w> <h> <anchor> <text>
                if (result.count < N) {
                    result.controls[result.count] = parseControl(trimmed);
                    result.count += 1;
                }
            }
        }
        
        return result;
    }
}

const RefWindow = struct { x: i32, y: i32 };

fn parseRefWindow(comptime line: []const u8) RefWindow {
    comptime {
        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next(); // skip 'r'
        const x_str = parts.next() orelse "0";
        const y_str = parts.next() orelse "0";
        return .{
            .x = parseInt(x_str),
            .y = parseInt(y_str),
        };
    }
}

fn parseControl(comptime line: []const u8) Control {
    comptime {
        var parts = std.mem.splitScalar(u8, line, ' ');
        
        _ = parts.next(); // skip 'c'
        const id_str = parts.next() orelse "0";
        const type_str = parts.next() orelse "0";
        const name = parts.next() orelse "unnamed";
        const x_str = parts.next() orelse "0";
        const y_str = parts.next() orelse "0";
        const w_str = parts.next() orelse "0";
        const h_str = parts.next() orelse "0";
        const anchor_str = parts.next() orelse "0";
        
        // Rest is text (may contain spaces)
        var text: []const u8 = "";
        if (parts.next()) |first| {
            text = first;
            // Concatenate remaining parts
            while (parts.next()) |part| {
                // In comptime we can't do runtime concat, so just use first part
                _ = part;
            }
        }
        
        return .{
            .id = parseU16(id_str),
            .type = ControlType.fromInt(parseU8(type_str)),
            .name = name,
            .x = parseInt(x_str),
            .y = parseInt(y_str),
            .width = parseInt(w_str),
            .height = parseInt(h_str),
            .anchor = parseU8(anchor_str),
            .text = text,
        };
    }
}

fn parseInt(comptime s: []const u8) i32 {
    comptime {
        if (s.len == 0) return 0;
        
        var neg = false;
        var start: usize = 0;
        if (s[0] == '-') {
            neg = true;
            start = 1;
        }
        
        var result: i32 = 0;
        for (s[start..]) |c| {
            if (c >= '0' and c <= '9') {
                result = result * 10 + @as(i32, c - '0');
            }
        }
        
        return if (neg) -result else result;
    }
}

fn parseU8(comptime s: []const u8) u8 {
    const v = parseInt(s);
    return if (v < 0) 0 else if (v > 255) 255 else @intCast(v);
}

fn parseU16(comptime s: []const u8) u16 {
    const v = parseInt(s);
    return if (v < 0) 0 else if (v > 65535) 65535 else @intCast(v);
}

// ============================================================================
// Tests
// ============================================================================

test "countControls" {
    const content =
        \\# Comment
        \\r 0 0 800 600
        \\c 000 5 btn1 10 20 100 30 0 Button1
        \\c 001 5 btn2 10 60 100 30 0 Button2
    ;
    try std.testing.expectEqual(@as(usize, 2), countControls(content));
}

test "parse basic" {
    const content =
        \\c 000 5 test_btn 50 100 120 40 0 Click
    ;
    const layout = parse(content);
    try std.testing.expectEqual(@as(usize, 1), layout.count);
    try std.testing.expectEqual(ControlType.button, layout.controls[0].type);
    try std.testing.expectEqualStrings("test_btn", layout.controls[0].name);
    try std.testing.expectEqual(@as(i32, 50), layout.controls[0].x);
    try std.testing.expectEqual(@as(i32, 100), layout.controls[0].y);
}

test "parse LED" {
    const content =
        \\c 000 100 led_main 100 100 30 30 0 LED
    ;
    const layout = parse(content);
    try std.testing.expectEqual(ControlType.led, layout.controls[0].type);
}

test "findControl" {
    const content =
        \\c 000 5 btn_a 0 0 10 10 0 A
        \\c 001 5 btn_b 0 0 10 10 0 B
    ;
    const layout = parse(content);
    try std.testing.expectEqual(@as(?usize, 0), layout.findControl("btn_a"));
    try std.testing.expectEqual(@as(?usize, 1), layout.findControl("btn_b"));
    try std.testing.expectEqual(@as(?usize, null), layout.findControl("btn_c"));
}
