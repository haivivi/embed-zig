//! LVGL Table widget
const c = @import("lvgl").c;
const Obj = @import("obj.zig");
const Self = @This();
obj: Obj,

pub fn create(parent: Obj) ?Self {
    const p = c.lv_table_create(parent.ptr) orelse return null;
    return .{ .obj = .{ .ptr = p } };
}
pub fn setRowCount(self: Self, cnt: u32) Self { c.lv_table_set_row_count(self.obj.ptr, @intCast(cnt)); return self; }
pub fn setColumnCount(self: Self, cnt: u32) Self { c.lv_table_set_column_count(self.obj.ptr, @intCast(cnt)); return self; }
pub fn setColumnWidth(self: Self, col: u32, w: i32) Self { c.lv_table_set_column_width(self.obj.ptr, @intCast(col), w); return self; }
pub fn setCellValue(self: Self, row: u32, col: u32, txt: [*:0]const u8) Self {
    c.lv_table_set_cell_value(self.obj.ptr, @intCast(row), @intCast(col), txt);
    return self;
}
pub fn size(self: Self, w: i32, h: i32) Self { _ = self.obj.size(w, h); return self; }
pub fn raw(self: Self) *c.lv_obj_t { return self.obj.ptr; }
