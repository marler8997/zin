StaticWindowId: type = enum {},
x11_write_buffer_size: usize = 3000,
x11_read_buffer_size: usize = 1000,
x11_on_visual: ?fn (screen_index: u8, depth: u8, visual_index: u16, *const zin.X11VisualType) void = null,
x11_on_unhandled_reply: ?fn (flexible: u8, sequence: u16, word_count: u32) error{ ReadFailed, EndOfStream, Protocol }!void = null,

const zin = @import("zin.zig");
