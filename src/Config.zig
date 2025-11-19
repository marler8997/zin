StaticWindowId: type = enum {},
x11_write_buffer_size: usize = 3000,
x11_read_buffer_size: usize = 1000,
x11_unhandled_reply: ?fn (flexible: u8, sequence: u16, word_count: u32) error{ X11Protocol, ReadFailed, EndOfStream }!void = null,
