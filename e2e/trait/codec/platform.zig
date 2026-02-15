const board = @import("board");
pub const log = board.log;
pub const Codec = board.Codec;
pub const heap_allocator = if (@hasDecl(board, "heap_allocator")) board.heap_allocator else @import("std").heap.page_allocator;
