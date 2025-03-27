const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin.zig");

const x11 = @import("x11");
const win32 = switch (builtin.os.tag) {
    .windows => @import("win32").everything,
    else => @compileError("can't use win32 on non-windows OS"),
};

const log = std.log.scoped(.x11);

threadlocal var thread_is_panicing = false;
pub fn panic(panic_opt: zin.PanicOptions) type {
    return std.debug.FullPanic(struct {
        pub fn panic(
            msg: []const u8,
            ret_addr: ?usize,
        ) noreturn {
            if (builtin.os.tag == .windows) {
                if (!thread_is_panicing) {
                    thread_is_panicing = true;
                    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
                        arena.allocator(),
                        "{s}",
                        .{msg},
                    )) |msg_z| msg_z else |_| "failed allocate error message";
                    _ = @import("win32").everything.MessageBoxA(null, msg_z, panic_opt.title, panic_opt.win32_style);
                }
            }
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic);
}

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

const fixed_ids_per_window = 2; // 1 for the window and 1 for the graphics context

pub const Connection = struct {
    sock: std.posix.socket_t,
    setup: x11.ConnectSetup,
    screen: *align(4) x11.Screen,

    sequence: u16 = 0,

    // TODO: we'll need some better mechanism for ids so we can't run out
    next_id_offset: u32 = 0,

    fn windowFromId(self: *const Connection, id: x11.Window) Window {
        _ = self;
        _ = id;
        @panic("todo");
    }
    fn staticWindowFromX11Id(self: *const Connection, window: x11.Window) ?zin.StaticWindowId {
        const id_offset = @intFromEnum(window) - @intFromEnum(self.setup.fixed().resource_id_base);
        if (id_offset < static_window_count * fixed_ids_per_window) return @as(zin.StaticWindowId, @enumFromInt(@divTrunc(id_offset, fixed_ids_per_window)));
        return null;
    }

    fn reader(self: *const Connection) SocketReader {
        return .{ .context = self.sock };
    }
    fn sendOne(self: *Connection, data: []const u8) SendError!void {
        try this.sendNoSequencing(self.sock, data);
        self.sequence +%= 1;
    }
    fn sendMultiple(self: *Connection, message_count: u16, data: []const u8) SendError!void {
        try this.sendNoSequencing(self.sock, data);
        self.sequence +%= message_count;
    }
    // TODO: how should we do error handling here?
    fn sendOneOrPanic(self: *Connection, data: []const u8) void {
        self.sendOne(data) catch |e| std.debug.panic("send over X11 socket failed with {s}", .{@errorName(e)});
    }
    fn staticWindowId(self: *const Connection, id: zin.StaticWindowId) x11.Window {
        return self.setup.fixed().resource_id_base.add(@as(u32, @intFromEnum(id)) * fixed_ids_per_window).window();
    }
    fn staticWindowGc(self: *const Connection, id: zin.StaticWindowId) x11.GraphicsContext {
        return self.setup.fixed().resource_id_base.add(@as(u32, @intFromEnum(id)) * fixed_ids_per_window + 1).graphicsContext();
    }

    fn reserveId(self: *Connection) x11.Resource {
        const resource = self.setup.fixed().resource_id_base.add(@intCast(static_window_count * fixed_ids_per_window + self.next_id_offset));
        self.next_id_offset += 1;
        return resource;
    }
    fn releaseId(self: *Connection, id: x11.Resource) void {
        const offset = @intFromEnum(id) - static_window_count * fixed_ids_per_window - @intFromEnum(self.setup.fixed().resource_id_base);
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

pub fn registerDynamicWindowClass(
    comptime config: zin.WindowConfigData,
    comptime def: zin.WindowClassDefinition(.{ .dynamic = config }),
) WindowClass {
    _ = def;
    @panic("todo: dynamic x11 windows");
}

pub const WindowClass = struct {
    callback: *const anyopaque,
    pub fn unregister(self: WindowClass) void {
        _ = self;
    }
};

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
        var msg: [x11.destroy_window.len]u8 = undefined;
        x11.destroy_window.serialize(&msg, self.id);
        global.connection.sendOneOrPanic(&msg);
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

const StaticWindow = struct {
    damaged: bool = false,
    client_size: zin.XY = .{ .x = 0, .y = 0 },
};

const global = struct {
    var connection: Connection = undefined;
    var static_callbacks: [static_window_count]?*const anyopaque = @splat(null);
    var static_windows: [static_window_count]StaticWindow = @splat(.{});
};

fn staticCallback(comptime window_id: zin.StaticWindowId) *const fn (zin.Callback(.{ .static = window_id })) void {
    return @alignCast(@ptrCast(global.static_callbacks[@intFromEnum(window_id)].?));
}

pub fn staticWindow(window_id: zin.StaticWindowId) type {
    const config = zin.WindowConfig{ .static = window_id };

    return struct {
        const Self = @This();

        fn window() Window {
            return .{
                .id = global.connection.staticWindowId(window_id),
                .callback = global.static_callbacks[@intFromEnum(window_id)].?,
            };
        }

        pub fn registerClass(comptime def: zin.WindowClassDefinition(.{ .static = window_id })) void {
            std.debug.assert(global.static_callbacks[@intFromEnum(window_id)] == null);
            global.static_callbacks[@intFromEnum(window_id)] = @ptrCast(def.callback);
        }
        pub fn unregisterClass() void {
            std.debug.assert(global.static_callbacks[@intFromEnum(window_id)] != null);
            global.static_callbacks[@intFromEnum(window_id)] = null;
        }
        pub fn create(opt: zin.CreateWindowOptions) zin.CreateWindowError!void {
            //std.debug.assert(global.static_windows[@intFromEnum(window_id)] == null);
            const bg = x11FromRgb(config.data().background);
            const size = windowSizeFromInit(opt.size);
            try createWindow(&config.data(), size, bg, global.connection.staticWindowId(window_id));
            global.static_windows[@intFromEnum(window_id)].client_size = size;
        }
        pub fn destroy() void {
            var msg: [x11.destroy_window.len]u8 = undefined;
            x11.destroy_window.serialize(&msg, global.connection.staticWindowId(window_id));
            global.connection.sendOneOrPanic(&msg);
        }
        pub fn getClientSize() zin.XY {
            return global.static_windows[@intFromEnum(window_id)].client_size;
        }
        pub fn show() void {
            return window().show();
        }
        pub fn foreground() void {
            @panic("todo");
            // global.static_windows[@intFromEnum(window_id)].?.foreground();
        }
        pub fn invalidate() void {
            global.static_windows[@intFromEnum(window_id)].damaged = true;
        }
        pub fn startTimer(id: usize, millis: u32) void {
            _ = id;
            _ = millis;
            std.log.warn("TODO: implement timers for x11", .{});
            //@panic("todo");
            // global.static_windows[@intFromEnum(window_id)].?.startTimer(id, millis);
        }
    };
}

fn gcFromWindow(id: x11.Window) x11.GraphicsContext {
    return @enumFromInt(@intFromEnum(id) + 1);
}

fn windowSizeFromInit(init: zin.WindowSizeInit) zin.XY {
    return switch (init) {
        .default => @panic("todo"),
        .client => |s| s,
        .window => |s| s,
    };
}

pub fn createDynamicWindow(class: WindowClass, opt: zin.CreateWindowOptions) zin.CreateWindowError!DynamicWindow {
    const window_id = global.connection.reserveId().window();
    errdefer global.connection.releaseId(window_id.resource());
    //const bg = x11FromRgb((zin.WindowConfig{ .static = window_id }).data().background);
    if (true) @panic("todo: get the background from the window config");
    try createWindow(&opt, window_id);
    return .{ .id = window_id, .callback = class.callback };
}

fn createWindow(
    config: *const zin.WindowConfigData,
    size: zin.XY,
    bg: u32,
    id: x11.Window,
) zin.CreateWindowError!void {
    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
            .window_id = id,
            .parent_window_id = global.connection.screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0,
            .y = 0,
            .width = @intCast(size.x),
            .height = @intCast(size.y),
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = global.connection.screen.root_visual,
        }, .{
            // .bg_pixmap = .copy_from_parent,
            .bg_pixel = bg,
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
                .button_press = if (config.mouse_events) 1 else 0,
                .button_release = if (config.mouse_events) 1 else 0,
                .enter_window = if (config.mouse_events) 1 else 0,
                .leave_window = if (config.mouse_events) 1 else 0,
                .pointer_motion = if (config.mouse_events) 1 else 0,
                .keymap_state = 1,
                .exposure = 1,
            },
            // .dont_propagate = 1,
        });
        try global.connection.sendOne(msg_buf[0..len]);
    }

    // TODO: send both the create_window/create_gc messages in the same buffer
    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = gcFromWindow(id),
            .drawable_id = id.drawable(),
        }, .{
            .background = bg,
            .foreground = 0x224477bb,
        });
        try global.connection.sendOne(msg_buf[0..len]);
    }
}

pub const VirtualKey = enum {
    n,
};
pub const Coord = i16;

fn mouseButtonFromMsg(detail: u8) zin.MouseButton {
    return switch (detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => |d| std.debug.panic("todo: map button {} to zin", .{d}),
    };
}

pub fn mainLoop() !void {
    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    while (true) {
        for (&global.static_windows, 0..) |*window, static_window_id_raw| {
            if (window.damaged) {
                const static_window_id: zin.StaticWindowId = @enumFromInt(static_window_id_raw);
                switch (static_window_id) {
                    inline else => |window_id| {
                        const config = zin.WindowConfig{ .static = window_id };
                        staticCallback(window_id)(.{ .draw = .{
                            .window = global.connection.staticWindowId(static_window_id),
                            .client_size = global.static_windows[@intFromEnum(window_id)].client_size,
                            .background = if (comptime config.data().dynamic_background) config.data().background else {},
                        } });
                    },
                }
                window.damaged = false;
            }
        }

        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.debug.panic("buffer size {} not big enough! (todo: probably just increase it?)", .{buf.half_len});
            }

            // TODO: read the socket with a timeout
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
                    const button_id = mouseButtonFromMsg(msg.detail);
                    const pos: zin.XY = .{
                        .x = @intCast(msg.event_x),
                        .y = @intCast(msg.event_y),
                    };
                    if (global.connection.staticWindowFromX11Id(msg.event)) |w| switch (w) {
                        inline else => |window_id| {
                            const config = zin.WindowConfig{ .static = window_id };
                            if (config.data().mouse_events) {
                                staticCallback(window_id)(.{ .mouse = .{
                                    .position = pos,
                                    .button = .{ .id = button_id, .state = .down },
                                } });
                            }
                        },
                    } else @panic("todo: button_press on dynamic windows");
                },
                .button_release => |msg| {
                    const button_id = mouseButtonFromMsg(msg.detail);
                    const pos: zin.XY = .{
                        .x = @intCast(msg.event_x),
                        .y = @intCast(msg.event_y),
                    };
                    if (global.connection.staticWindowFromX11Id(msg.event)) |w| switch (w) {
                        inline else => |window_id| {
                            const config = zin.WindowConfig{ .static = window_id };
                            if (config.data().mouse_events) {
                                staticCallback(window_id)(.{ .mouse = .{
                                    .position = pos,
                                    .button = .{ .id = button_id, .state = .up },
                                } });
                            }
                        },
                    } else @panic("todo: button_release on dynamic windows");
                },
                .enter_notify => |msg| {
                    log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    const pos: zin.XY = .{
                        .x = @intCast(msg.event_x),
                        .y = @intCast(msg.event_y),
                    };
                    if (global.connection.staticWindowFromX11Id(msg.event)) |w| switch (w) {
                        inline else => |window_id| {
                            const config = zin.WindowConfig{ .static = window_id };
                            if (config.data().mouse_events) {
                                staticCallback(window_id)(.{ .mouse = .{ .position = pos, .button = null } });
                            }
                        },
                    } else @panic("todo: motion_notify on dynamic windows");
                },
                .keymap_notify => |msg| {
                    log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    if (global.connection.staticWindowFromX11Id(msg.window)) |w| switch (w) {
                        inline else => |window_id| {
                            const config = zin.WindowConfig{ .static = window_id };
                            staticCallback(window_id)(.{ .draw = .{
                                .window = msg.window,
                                .client_size = global.static_windows[@intFromEnum(window_id)].client_size,
                                .background = if (comptime config.data().dynamic_background) config.data().background else {},
                            } });
                            global.static_windows[@intFromEnum(window_id)].damaged = false;
                        },
                    } else @panic("todo: expose on dynamic windows");
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

fn giveup(what: []const u8, e: anyerror) noreturn {
    std.debug.panic("{s} failed with {s}", .{ what, @errorName(e) });
}

pub fn Draw(window_config: zin.WindowConfig) type {
    return struct {
        window: x11.Window,
        client_size: zin.XY,
        background: if (window_config.data().dynamic_background) zin.Rgb8 else void,
        // gc_background: Rgb,
        // gc_foreground: Rgb,

        const Self = @This();

        pub fn getDpiScale(self: *const Self) f32 {
            _ = self;
            return 1.0;
        }

        pub fn clear(self: *const Self) void {
            const rgb = if (comptime window_config.data().dynamic_background)
                self.background
            else
                window_config.data().background;
            var messages: [x11.change_gc.max_len + x11.clear_area.len]u8 = undefined;
            const after_change_gc: usize = x11.change_gc.serialize(&messages, gcFromWindow(self.window), .{
                .background = x11FromRgb(rgb),
            });
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: get the actual width/height
            x11.clear_area.serialize(messages[after_change_gc..].ptr, false, self.window, .{
                .x = 0,
                .y = 0,
                .width = @intCast(self.client_size.x),
                .height = @intCast(self.client_size.y),
            });
            const total_len: usize = after_change_gc + x11.clear_area.len;
            global.connection.sendMultiple(2, messages[0..total_len]) catch |e| giveup("send change-gc/clear", e);
        }

        pub fn rect(self: *const Self, r: zin.Rect, rgb: zin.Rgb8) void {
            var messages: [x11.change_gc.max_len + x11.poly_fill_rectangle.getLen(1)]u8 = undefined;
            const after_change_gc: usize = x11.change_gc.serialize(&messages, gcFromWindow(self.window), .{
                .foreground = x11FromRgb(rgb),
            });
            x11.poly_fill_rectangle.serialize(messages[after_change_gc..].ptr, .{
                .drawable_id = self.window.drawable(),
                .gc_id = gcFromWindow(self.window),
            }, &[_]x11.Rectangle{
                .{
                    .x = @intCast(r.left),
                    .y = @intCast(r.top),
                    .width = @intCast(r.right - r.left),
                    .height = @intCast(r.bottom - r.top),
                },
            });
            const total_len: usize = after_change_gc + x11.poly_fill_rectangle.getLen(1);
            global.connection.sendMultiple(2, messages[0..total_len]) catch |e| giveup("send change-gc/fill-rect", e);
        }

        pub fn text(self: *const Self, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            const slice = x11.Slice(u8, [*]const u8){
                .ptr = t.ptr,
                .len = std.math.cast(u8, t.len) orelse std.debug.panic("TODO: handle text with {} bytes", .{t.len}),
            };
            var messages: [x11.change_gc.max_len + x11.image_text8.max_len]u8 = undefined;
            const after_change_gc: usize = x11.change_gc.serialize(&messages, gcFromWindow(self.window), .{
                .background = 0, // TODO: how do we declare this as transparent
                .foreground = x11FromRgb(rgb),
            });
            x11.image_text8.serialize(messages[after_change_gc..].ptr, slice, .{
                .drawable_id = self.window.drawable(),
                .gc_id = gcFromWindow(self.window),
                .x = std.math.cast(i16, x) orelse std.debug.panic("TODO: what to do with x value of {}", .{x}),
                .y = std.math.cast(i16, y) orelse std.debug.panic("TODO: what to do with y value of {}", .{y}),
            });
            const total_len: usize = after_change_gc + x11.image_text8.getLen(slice.len);
            global.connection.sendMultiple(2, messages[0..total_len]) catch |e| giveup("send ImageText", e);
        }
    };
}

fn x11FromRgb(rgb: zin.Rgb8) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 0);
}
