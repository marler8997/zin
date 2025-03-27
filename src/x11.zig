const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin.zig");

const x11 = @import("x11");
const win32 = switch (builtin.os.tag) {
    .windows => @import("win32").everything,
    else => @compileError("can't use win32 on non-windows OS"),
};

const log = std.log.scoped(.x11);

const SocketReader = std.io.Reader(std.posix.socket_t, std.posix.RecvFromError, readSocket);
fn readSocket(sock: std.posix.socket_t, buffer: []u8) !usize {
    return x11.readSock(sock, buffer, 0);
}

const this = @This();

const SendError = error{
    BrokenPipe,
    ConnectionResetByPeer,
    SystemResources,
    NetworkSubsystemFailed,
};
fn sendNoSequencing(sock: std.posix.socket_t, data: []const u8) SendError!void {
    var total_sent: usize = 0;
    while (total_sent < data.len) {
        const last_sent = x11.writeSock(sock, data[total_sent..], 0) catch |err| switch (err) {
            error.AccessDenied => unreachable,
            error.WouldBlock => unreachable,
            error.Unexpected => unreachable,
            error.FileDescriptorNotASocket => unreachable,
            error.FastOpenAlreadyInProgress => unreachable,
            error.MessageTooBig => unreachable, // probably UDP specific
            error.NetworkUnreachable => unreachable, // probably UDP specific
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.SystemResources,
            error.NetworkSubsystemFailed,
            => |e| return e,
        };
        total_sent += last_sent;
    }
}

// const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".fields.len;
// const StaticWindowClass = struct {
//     //callback: fn (ConnectionRef, CallbackWindow, Callback(window_config)) void,
//     callback: *anyopaque,
// };
// var static_window_classes: [static_window_count]?StaticWindowClass = @splat(null);

pub const Connection = struct {
    sock: std.posix.socket_t,
    setup: x11.ConnectSetup,
    screen: *align(4) x11.Screen,

    sequence: u16 = 0,

    // TODO: we'll need some better mechanism for ids so we can't run out
    next_id_offset: u32 = 0,

    fn reader(self: *const Connection) SocketReader {
        return .{ .context = self.sock };
    }
    fn sendOne(self: *Connection, data: []const u8) SendError!void {
        try this.sendNoSequencing(self.sock, data);
        self.sequence +%= 1;
    }
    // TODO: how should we do error handling here?
    fn sendOneOrPanic(self: *Connection, data: []const u8) void {
        self.sendOne(data) catch |e| std.debug.panic("send over X11 socket failed with {s}", .{@errorName(e)});
    }
    fn staticWindowId(self: *const Connection, id: zin.StaticWindowId) x11.Window {
        return self.setup.fixed().resource_id_base.add(@intFromEnum(id)).window();
    }
    fn reserveId(self: *Connection) x11.Resource {
        const resource = self.setup.fixed().resource_id_base.add(@intCast(static_window_count + self.next_id_offset));
        self.next_id_offset += 1;
        return resource;
    }
    fn releaseId(self: *Connection, id: x11.Resource) void {
        const offset = @intFromEnum(id) - static_window_count - @intFromEnum(self.setup.fixed().resource_id_base);
        if (self.next_id_offset == offset + 1) {
            self.next_id_offset = @intCast(offset);
        } else {
            @panic("todo");
        }
    }
};

pub fn connect(allocator: std.mem.Allocator, options: zin.ConnectOptions) zin.ConnectError!void {
    if (builtin.os.tag == .windows) {
        var data: win32.WSAData = undefined;
        const result = win32.WSAStartup((@as(u16, 2) << 8) | 2, &data);
        if (result != 0) std.debug.panic("WSAStartup failed, error={}", .{result});
    }

    const display = x11.getDisplay();
    const parsed_display = x11.parseDisplay(display) catch return error.BadX11Display;

    const sock = try x11.connect(display, parsed_display);
    errdefer x11.disconnect(sock);

    var tmp_arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer tmp_arena_instance.deinit();
    const scratch = switch (options.scratch) {
        .tmp_arena => tmp_arena_instance.allocator(),
        .share => allocator,
        .custom => |a| a,
    };

    const setup_reply_len: u16 = blk: {
        if (x11.getAuthFilename(scratch) catch |err| switch (err) {
            error.InvalidWtf8 => @panic("todo: how to handle this error?"),
            else => |e| return e,
        }) |auth_filename| {
            defer auth_filename.deinit(scratch);
            if (connectSetupAuth(parsed_display.display_num, sock, auth_filename.str) catch |err| std.debug.panic(
                "todo: handle connectSetupAuth error '{s}'",
                .{@errorName(err)},
            )) |reply_len|
                break :blk reply_len;
        }

        // Try no authentication
        log.debug("trying no auth", .{});
        var msg_buf: [x11.connect_setup.getLen(0, 0)]u8 = undefined;
        if (connectSetup(
            sock,
            &msg_buf,
            .{ .ptr = undefined, .len = 0 },
            .{ .ptr = undefined, .len = 0 },
        ) catch |err| std.debug.panic(
            "todo: handle connectSetup error {s}",
            .{@errorName(err)},
        )) |reply_len| {
            break :blk reply_len;
        }

        log.err("the X server rejected our connect setup message", .{});
        std.process.exit(0xff);
    };

    const connect_setup = x11.ConnectSetup{
        .buf = try allocator.allocWithOptions(u8, setup_reply_len, 4, null),
    };
    log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    const reader = SocketReader{ .context = sock };
    x11.readFull(reader, connect_setup.buf) catch |e| std.debug.panic(
        "read x11 socket failed with {s}",
        .{@errorName(e)},
    );

    const fixed = connect_setup.fixed();
    inline for (@typeInfo(@TypeOf(fixed.*)).@"struct".fields) |field| {
        log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
    }
    log.debug("vendor: {s}", .{connect_setup.getVendorSlice(fixed.vendor_len) catch |e| switch (e) {
        error.XMalformedReply_VendorLenTooBig => @panic("X server malformed reply (vendor len too big)"),
    }});
    const format_list_offset = x11.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x11.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
    const formats = connect_setup.getFormatList(format_list_offset, format_list_limit) catch |e| switch (e) {
        error.XMalformedReply_FormatCountTooBig => @panic("X server malformed reply (format count too big)"),
    };
    for (formats, 0..) |format, i| {
        log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{ i, format.depth, format.bits_per_pixel, format.scanline_pad });
    }
    const screen = connect_setup.getFirstScreenPtr(format_list_limit);
    inline for (@typeInfo(@TypeOf(screen.*)).@"struct".fields) |field| {
        log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
    }
    global.connection = Connection{ .sock = sock, .setup = connect_setup, .screen = screen };
}
pub fn disconnect(allocator: std.mem.Allocator) void {
    allocator.free(global.connection.setup.buf);
    x11.disconnect(global.connection.sock);
}

fn connectSetupAuth(
    display_num: ?x11.DisplayNum,
    sock: std.posix.socket_t,
    auth_filename: []const u8,
) !?u16 {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: test bad auth
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //if (try connectSetupMaxAuth(sock, 1000, .{ .ptr = "wat", .len = 3}, .{ .ptr = undefined, .len = 0})) |_|
    //    @panic("todo");

    const auth_mapped = try x11.MappedFile.init(auth_filename, .{});
    defer auth_mapped.unmap();

    var auth_filter = x11.AuthFilter{
        .addr = .{ .family = .wild, .data = &[0]u8{} },
        .display_num = display_num,
    };

    var addr_buf: [x11.max_sock_filter_addr]u8 = undefined;
    if (auth_filter.applySocket(sock, &addr_buf)) {
        log.debug("applied address filter {}", .{auth_filter.addr});
    } else |err| {
        // not a huge deal, we'll just try all auth methods
        log.warn("failed to apply socket to auth filter with {s}", .{@errorName(err)});
    }

    var auth_it = x11.AuthIterator{ .mem = auth_mapped.mem };
    while (auth_it.next() catch {
        log.warn("auth file '{s}' is invalid", .{auth_filename});
        return null;
    }) |entry| {
        if (auth_filter.isFiltered(auth_mapped.mem, entry)) |reason| {
            log.debug("ignoring auth because {s} does not match: {}", .{ @tagName(reason), entry.fmt(auth_mapped.mem) });
            continue;
        }
        const name = entry.name(auth_mapped.mem);
        const data = entry.data(auth_mapped.mem);
        const name_x = x11.Slice(u16, [*]const u8){
            .ptr = name.ptr,
            .len = @intCast(name.len),
        };
        const data_x = x11.Slice(u16, [*]const u8){
            .ptr = data.ptr,
            .len = @intCast(data.len),
        };
        log.debug("trying auth {}", .{entry.fmt(auth_mapped.mem)});
        if (try connectSetupMaxAuth(sock, 1000, name_x, data_x)) |reply_len|
            return reply_len;
    }

    return null;
}

pub fn connectSetupMaxAuth(
    sock: std.posix.socket_t,
    comptime max_auth_len: usize,
    auth_name: x11.Slice(u16, [*]const u8),
    auth_data: x11.Slice(u16, [*]const u8),
) !?u16 {
    var buf: [x11.connect_setup.auth_offset + max_auth_len]u8 = undefined;
    const len = x11.connect_setup.getLen(auth_name.len, auth_data.len);
    if (len > max_auth_len)
        return error.AuthTooBig;
    return connectSetup(sock, buf[0..len], auth_name, auth_data);
}

pub fn connectSetup(
    sock: std.posix.socket_t,
    msg: []u8,
    auth_name: x11.Slice(u16, [*]const u8),
    auth_data: x11.Slice(u16, [*]const u8),
) !?u16 {
    std.debug.assert(msg.len == x11.connect_setup.getLen(auth_name.len, auth_data.len));

    x11.connect_setup.serialize(msg.ptr, 11, 0, auth_name, auth_data);
    try sendNoSequencing(sock, msg);

    const reader = SocketReader{ .context = sock };
    const connect_setup_header = try x11.readConnectSetupHeader(reader, .{});
    switch (connect_setup_header.status) {
        .failed => {
            log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            return error.ConnectSetupFailed;
        },
        .authenticate => {
            log.err("AUTHENTICATE! not implemented", .{});
            return error.NotImplemetned;
        },
        .success => {
            // TODO: check version?
            log.debug("SUCCESS! version {}.{}", .{ connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver });
            return connect_setup_header.getReplyLen();
        },
        else => |status| {
            log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.MalformedXReply;
        },
    }
}

pub fn registerWindowClass(
    comptime window_config: zin.WindowConfig,
    comptime def: zin.WindowClassDefinition(window_config),
) WindowClass {
    switch (window_config) {
        .static => {
            // if (global.static_window_callbacks[@intFromEnum(window_id)] != null) std.debug.panic(
            //     "window {s} class has already been registered",
            //     .{@tagName(window_id)},
            // );
            // global.static_window_callbacks[@intFromEnum(window_id)] = def.callback;
            return .{ .callback = def.callback };
        },
        .dynamic => @panic("todo: dynamic x11 windows"),
    }
}

pub const WindowClass = struct {
    callback: *const anyopaque,
    pub fn unregister(self: WindowClass) void {
        _ = self;
    }
};
// pub fn registerDynamicWindowClass(
//     comptime config: zin.WindowConfig,
//     comptime def: zin.WindowClassDefinition(config),
// ) WindowClass {
//     return .{ .callback = makeCallback(config, def) };
// }

pub fn makeCallback(
    comptime config: zin.WindowConfig,
    comptime class: zin.WindowClassDefinition(config),
) *const fn () void {
    _ = class;
    return (struct {
        pub fn callback() void {
            @panic("todo");
        }
    }).callback;
}

pub const DynamicWindow = Window;
const Window = struct {
    id: x11.Window,
    callback: *const anyopaque,

    // fn asX11Window(self: DynamicWindow) x11.Window {
    //     return @enumFromInt(@intFromEnum(self));
    // }
    pub fn destroy(self: DynamicWindow) void {
        _ = self;
        @panic("todo");
    }
    pub fn show(self: DynamicWindow) void {
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, self.id);
        global.connection.sendOneOrPanic(&msg);
    }
    pub fn startTimer(self: DynamicWindow, id: usize, millis: u32) void {
        _ = self;
        _ = id;
        _ = millis;
        log.err("TODO: implement startTimer for x11", .{});
    }
};

const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".fields.len;
const global = struct {
    var connection: Connection = undefined;
    var static_window_callbacks: [static_window_count]?*const anyopaque = @splat(null);
};

pub fn StaticWindow(window_id: zin.StaticWindowId) type {
    return struct {
        const Self = @This();
        callback: *const anyopaque,

        fn window(self: Self) Window {
            return .{ .id = global.connection.staticWindowId(window_id), .callback = self.callback };
        }

        pub fn create(
            self: Self,
            opt: zin.CreateWindowOptions,
        ) zin.CreateWindowError!void {
            _ = self;
            //std.debug.assert(global.static_windows[@intFromEnum(window_id)] == null);
            try createWindow(&opt, global.connection.staticWindowId(window_id));
        }
        pub fn destroy(self: Self) void {
            _ = self;
            @panic("todo");
            // global.static_windows[@intFromEnum(window_id)].?.destroy();
        }
        pub fn getClientSize(self: Self) zin.Size {
            _ = self;
            @panic("todo");
            // return global.static_windows[@intFromEnum(window_id)].?.getClientSize();
        }
        pub fn show(self: Self) void {
            return self.window().show();
        }
        pub fn foreground(self: Self) void {
            _ = self;
            @panic("todo");
            // global.static_windows[@intFromEnum(window_id)].?.foreground();
        }
        pub fn invalidate(self: Self) void {
            _ = self;
            @panic("todo");
            // global.static_windows[@intFromEnum(window_id)].?.invalidate();
        }
        pub fn startTimer(self: Self, id: usize, millis: u32) void {
            _ = self;
            _ = id;
            _ = millis;
            @panic("todo");
            // global.static_windows[@intFromEnum(window_id)].?.startTimer(id, millis);
        }
    };
}

pub fn staticWindow(window_id: zin.StaticWindowId) StaticWindow(window_id) {
    return StaticWindow(window_id){};
}

pub fn createStaticWindow(
    window: zin.StaticWindowId,
    opt: zin.CreateWindowOptions,
) zin.CreateWindowError!void {
    try createWindow(&opt, global.connection.staticWindowId(window));
}

pub fn createDynamicWindow(opt: zin.CreateWindowOptions) zin.CreateWindowError!DynamicWindow {
    const window_id = global.connection.reserveId().window();
    errdefer global.connection.releaseId(window_id.resource());
    try createWindow(&opt, window_id);
    return .{ .id = window_id, .callback = opt.class.callback };
}

fn createWindow(opt: *const zin.CreateWindowOptions, id: x11.Window) zin.CreateWindowError!void {
    const size: zin.Size = switch (opt.size) {
        .default => @panic("todo"),
        .client => @panic("todo"),
        .window => |s| s,
    };

    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
            .window_id = id,
            .parent_window_id = global.connection.screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0,
            .y = 0,
            .width = size.x,
            .height = size.y,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = global.connection.screen.root_visual,
        }, .{
            // .bg_pixmap = .copy_from_parent,
            .bg_pixel = 0xaabbccdd,
            // .border_pixmap =
            // .border_pixel = 0x01fa8ec9,
            // .bit_gravity = .north_west,
            // .win_gravity = .east,
            // .backing_store = .when_mapped,
            // .backing_planes = 0x1234,
            // .backing_pixel = 0xbbeeeeff,
            // .override_redirect = true,
            // .save_under = true,
            .event_mask = .{
                .key_press = 1,
                .key_release = 1,
                .button_press = 1,
                .button_release = 1,
                .enter_window = 1,
                .leave_window = 1,
                .pointer_motion = 1,
                .keymap_state = 1,
                .exposure = 1,
            },
            // .dont_propagate = 1,
        });
        try global.connection.sendOne(msg_buf[0..len]);
    }

    // return .{
    //     .id = id,
    //     .class = opt.class,
    // };
}

pub const VirtualKey = enum {
    n,
};
pub const MouseCoord = u16;
pub const SizeCoord = u16;

pub fn mainLoop() !void {
    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.debug.panic("buffer size {} not big enough! (todo: probably just increase it?)", .{buf.half_len});
            }
            const len = try x11.readSock(global.connection.sock, recv_buf, 0);
            if (len == 0) {
                log.info("X server connection closed", .{});
                return;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = x11.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x11.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| std.debug.panic("X11 error: {}", .{msg}),
                .reply => |msg| {
                    log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    log.info("key_press: keycode={}", .{msg.keycode});
                },
                .key_release => |msg| {
                    log.info("key_release: keycode={}", .{msg.keycode});
                },
                .button_press => |msg| {
                    log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    _ = msg;
                    //log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    // TODO: maybe use a buffered writer for the socket data?

                    {
                        var clear_msg: [x11.clear_area.len]u8 = undefined;
                        x11.clear_area.serialize(&clear_msg, false, msg.window, .{
                            .x = 150,
                            .y = 150,
                            .width = 100,
                            .height = 100,
                        });
                        try global.connection.sendOne(&clear_msg);
                    }

                    @panic("todo");
                    //class.callback.draw();
                },
                .mapping_notify => |msg| {
                    log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .map_notify,
                .reparent_notify,
                .configure_notify,
                => unreachable, // did not register for these
            }
        }
    }
}
pub fn quitMainLoop() void {
    @panic("todo");
}

pub const Draw = struct {
    placeholder: u32,
    pub fn clear(self: Draw, rgb: zin.Rgb8) void {
        _ = self;
        _ = rgb;
        @panic("todo");
    }
    pub fn text(self: Draw, t: []const u8, x: i32, y: i32) void {
        _ = self;
        _ = t;
        _ = x;
        _ = y;
        @panic("todo");
    }
};
