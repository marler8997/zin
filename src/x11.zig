const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin.zig");

pub const x11 = @import("x11");
pub const win32 = switch (builtin.os.tag) {
    .windows => @import("win32").everything,
    else => struct {},
};

const log = std.log.scoped(.x11);

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

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
                    const oom_msg = "allocate error message failed";
                    const msg_z: [:0]const u8 = if (zig_atleast_15) std.fmt.allocPrintSentinel(
                        arena.allocator(),
                        "{s}",
                        .{msg},
                        0,
                    ) catch oom_msg else std.fmt.allocPrintZ(
                        arena.allocator(),
                        "{s}",
                        .{msg},
                    ) catch oom_msg;
                    _ = @import("win32").everything.MessageBoxA(null, msg_z, panic_opt.title, panic_opt.win32_style);
                }
            }
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic);
}

// 1 id for the window
// 1 id for the graphics context
// 1 id for the backbuffer (TODO: only some windows need a back buffer)
const FixedWindowObject = enum {
    window,
    graphics_context,
    back_buffer, // NOTE: only some windows need a back buffer
};
const fixed_ids_per_window: comptime_int = std.meta.fields(FixedWindowObject).len;

const Extension = struct {
    name: x11.Slice(u16, [*]const u8),
    state: union(enum) {
        not_queried,
        query_sent: struct { sequence: u16 },
        resolved: ?x11.Extension,
    },
    pub fn get(extension: *Extension, sink: *x11.RequestSink) error{WriteFailed}!?x11.Extension {
        return switch (extension.state) {
            .not_queried => {
                try sink.QueryExtension(extension.name);
                extension.state = .{ .query_sent = .{ .sequence = sink.sequence } };
                return null;
            },
            .query_sent => null,
            .resolved => |maybe_extension| maybe_extension,
        };
    }
    pub fn onReply(
        extension: *Extension,
        source: *x11.Source,
        reply: x11.servermsg.Reply,
    ) !void {
        if (reply.sequence != switch (extension.state) {
            .query_sent => |query| query.sequence,
            .not_queried, .resolved => return,
        }) return;
        const ext = try source.read3Full(.QueryExtension);
        const present = switch (ext.present) {
            .no => false,
            .yes => true,
            else => |v| {
                log.err(
                    "expected extension '{s}' present to be 0 or 1 but got {}",
                    .{ extension.name.nativeSlice(), v },
                );
                return error.X11Protocol;
            },
        };
        if (present) {
            log.info(
                "extension '{s}': bases opcode={} event={} error={}",
                .{ extension.name.nativeSlice(), ext.opcode_base, ext.event_base, ext.error_base },
            );
        } else {
            log.info("extension '{s}': not present", .{extension.name.nativeSlice()});
        }
        extension.state = .{ .resolved = x11.Extension{
            .opcode_base = ext.opcode_base,
            .event_base = ext.event_base,
            .error_base = ext.error_base,
        } };
    }
};

pub const Connection = struct {
    sink: x11.RequestSink,
    source: x11.Source,
    dpi_scale_x: f32,
    dpi_scale_y: f32,
    depth: x11.Depth,

    keymap: if (support_key_events) x11.keymap.Full else void,
    // TODO: we'll need some better mechanism for ids so we can't run out
    next_id_offset: u32 = 0,
    dbe: Extension = .{ .name = x11.dbe.name, .state = .not_queried },

    write_error: ?error{WriteFailed},
    pub fn setWriteError(conn: *Connection, e: error{WriteFailed}) void {
        std.debug.assert(conn.write_error == null);
        conn.write_error = e;
        if (global.i.socket_writer.err) |err| {
            log.err("write to X11 socket failed with {s}", .{@errorName(err)});
        } else {
            log.err("write to X11 socket failed with unknown error", .{});
        }
    }
    pub fn teeWriteError(conn: *Connection, e: error{WriteFailed}) error{WriteFailed} {
        conn.setWriteError(e);
        return e;
    }

    pub fn x11FromRgb(conn: *const Connection, rgb: zin.Rgb8) u32 {
        const rgb24: u24 = (@as(u24, rgb.r) << 16) | (@as(u24, rgb.g) << 8) | rgb.b;
        return conn.depth.rgbFrom24(rgb24);
    }

    fn windowFromId(self: *const Connection, id: x11.Window) Window {
        _ = self;
        _ = id;
        @panic("todo");
    }
    fn staticWindowFromX11Id(self: *const Connection, window: x11.Window) ?zin.StaticWindowId {
        _ = self;
        const id_offset = @intFromEnum(window) - @intFromEnum(global.i.setup.resource_id_base);
        if (id_offset < static_window_count * fixed_ids_per_window) return @as(zin.StaticWindowId, @enumFromInt(@divTrunc(id_offset, fixed_ids_per_window)));
        return null;
    }
    fn drawableFromX11Id(self: *const Connection, id: u32) union(enum) {
        not_drawable,
        static_window: zin.StaticWindowId,
        static_back_buffer: zin.StaticWindowId,
    } {
        if (id < @intFromEnum(self.setup.fixed().resource_id_base)) return .not_drawable;
        const offset = id - @intFromEnum(self.setup.fixed().resource_id_base);
        if (offset >= static_window_count * fixed_ids_per_window) return .not_drawable;
        return switch (@as(FixedWindowObject, @enumFromInt(offset % fixed_ids_per_window))) {
            .window => .{ .static_window = @as(zin.StaticWindowId, @enumFromInt(@divTrunc(offset, fixed_ids_per_window))) },
            .graphics_context => .not_drawable,
            .back_buffer => .{ .static_window = @as(zin.StaticWindowId, @enumFromInt(@divTrunc(offset - 2, fixed_ids_per_window))) },
        };
    }

    pub fn staticWindowId(self: *const Connection, id: zin.StaticWindowId) x11.Window {
        _ = self;
        return global.i.setup.resource_id_base.add(@as(u32, @intFromEnum(id)) * fixed_ids_per_window).window();
    }
    pub fn staticWindowGc(self: *const Connection, id: zin.StaticWindowId) x11.GraphicsContext {
        return self.setup.fixed().resource_id_base.add(@as(u32, @intFromEnum(id)) * fixed_ids_per_window + 1).graphicsContext();
    }

    fn reserveId(self: *Connection) x11.Resource {
        const resource = global.i.setup.resource_id_base.add(@intCast(static_window_count * fixed_ids_per_window + self.next_id_offset));
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

pub fn processInit(opt: zin.ProcessInitOptions) zin.ProcessInitError!void {
    std.debug.assert(!global.process_init_called);
    global.process_init_called = true;

    if (builtin.os.tag == .windows) {
        if (opt.x11_wsa_startup) {
            var data: win32.WSAData = undefined;
            const result = win32.WSAStartup((@as(u16, 2) << 8) | 2, &data);
            if (result != 0) {
                log.err("WSAStartup failed, error={}", .{result});
                return error.X11WsaStartupFailed;
            }
        }
    }
    global.display = x11.getDisplay() catch |err| switch (err) {
        error.InvalidWtf8 => return error.X11DisplayInvalidWtf8,
        error.OutOfMemory => return error.OutOfMemory,
    };
    log.info("X11 DISPLAY {f}", .{global.display});
    global.parsed_display = x11.parseDisplay(global.display) catch |err| {
        log.err("invalid X11 DISPLAY {f}: {s}", .{ global.display, @errorName(err) });
        return error.X11BadDisplay;
    };
    global.host = x11.getHost(global.display, &global.parsed_display) catch |err| switch (err) {
        error.X11BadDisplay => |e| {
            log.err("invalid X11 DISPLAY {f}", .{global.display});
            return e;
        },
    };
}

pub const ConnectError = union(enum) {
    connect_error: x11.ConnectError,
    recv_error: (error{EndOfStream} || x11.SocketReader.Error),
    send_error: x11.SocketWriter.Error,
    protocol_error: enum { setup, setup_dynamic, depth, keycode_range, unexpected_msg },
    cant_authenticate,
    no_screen,

    fn set(err: *ConnectError, value: ConnectError) error{X11Connect} {
        err.* = value;
        return error.X11Connect;
    }

    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    fn formatNew(err: ConnectError, writer: *std.Io.Writer) error{WriteFailed}!void {
        try err.formatLegacy("", .{}, writer);
    }
    fn formatLegacy(
        err: ConnectError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (err) {
            .connect_error => |e| try writer.print("socket connect failed with {s}", .{@errorName(e)}),
            .recv_error => |e| try writer.print("socket receive failed with {s}", .{@errorName(e)}),
            .send_error => |e| try writer.print("socket send failed with {s}", .{@errorName(e)}),
            .protocol_error => |e| try writer.print("server protocol error: {s}", .{@tagName(e)}),
            .cant_authenticate => try writer.writeAll("failed to authenticate"),
            .no_screen => try writer.writeAll("server reported no screens"),
        }
    }
};
pub fn connect(out_err: *ConnectError) error{X11Connect}!void {
    std.debug.assert(global.process_init_called);
    std.debug.assert(global.conn == null);
    errdefer {
        std.debug.assert(global.conn == null);
        global.i.socket_writer = undefined;
        global.i.screen = undefined;
        global.i.setup = undefined;
        global.i.socket_reader = undefined;
    }

    global.i.socket_reader, global.use_auth = blk: {
        const address, const initial_stream = x11.connect(&global.host) catch |err| {
            return out_err.set(.{ .connect_error = err });
        };
        errdefer x11.disconnect(initial_stream);
        if (zig_atleast_15)
            log.info("connected to {f}", .{address})
        else
            log.info("connected to {}", .{address});
        break :blk x11.draft.authenticate(
            global.display,
            &global.parsed_display,
            &global.host,
            &address,
            initial_stream,
            &global.read_buffer,
            .{ .order = if (global.use_auth) .auth_first else .no_auth_first },
        ) catch |err| switch (err) {
            error.X11Authentication => return out_err.set(.cant_authenticate),
        };
    };
    errdefer x11.disconnect(global.i.socket_reader.getStream());

    global.i.setup = x11.readSetupSuccess(global.i.socket_reader.interface()) catch |err| switch (err) {
        error.ReadFailed => return out_err.set(.{
            .recv_error = global.i.socket_reader.getError() orelse error.Unexpected,
        }),
        error.EndOfStream => return out_err.set(.{ .recv_error = error.EndOfStream }),
        error.X11Protocol => return out_err.set(.{ .protocol_error = .setup }),
    };
    std.log.info("setup reply {f}", .{global.i.setup});
    var source: x11.Source = .initFinishSetup(global.i.socket_reader.interface(), &global.i.setup);
    global.i.screen = (x11.draft.readSetupDynamic(&source, &global.i.setup, .{}) catch |err| switch (err) {
        error.ReadFailed => return out_err.set(.{
            .recv_error = global.i.socket_reader.getError() orelse error.Unexpected,
        }),
        error.EndOfStream => return out_err.set(.{ .recv_error = error.EndOfStream }),
        error.X11Protocol => return out_err.set(.{ .protocol_error = .setup_dynamic }),
    }) orelse return out_err.set(.no_screen);
    global.i.socket_writer = x11.socketWriter(global.i.socket_reader.getStream(), &global.write_buffer);
    var sink: x11.RequestSink = .{ .writer = &global.i.socket_writer.interface };

    const dpi_scale_x = dpiScaleFromPixelMm(global.i.screen.pixel_width, global.i.screen.mm_width);
    const dpi_scale_y = dpiScaleFromPixelMm(global.i.screen.pixel_height, global.i.screen.mm_height);
    log.debug("DPI {d:.2}x{d:.2}", .{ dpi_scale_x, dpi_scale_y });
    const depth = x11.Depth.init(global.i.screen.root_depth) orelse {
        log.err("unsupported screen depth {}", .{global.i.screen.root_depth});
        return out_err.set(.{ .protocol_error = .depth });
    };

    const keymap: if (support_key_events) x11.keymap.Full else void = blk: {
        if (!support_key_events) break :blk {};
        const keyrange = x11.KeycodeRange.init(
            global.i.setup.min_keycode,
            global.i.setup.max_keycode,
        ) catch return out_err.set(.{ .protocol_error = .keycode_range });
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: should the initSynchronous function take the keymap by reference instead
        break :blk x11.keymap.Full.initSynchronous(&sink, &source, keyrange) catch |err| return switch (err) {
            error.WriteFailed => return out_err.set(.{ .send_error = global.i.socket_writer.err orelse error.Unexpected }),
            error.ReadFailed => return out_err.set(.{
                .recv_error = global.i.socket_reader.getError() orelse error.Unexpected,
            }),
            error.EndOfStream => return out_err.set(.{ .recv_error = error.EndOfStream }),
            error.X11Protocol => return out_err.set(.{ .protocol_error = .setup_dynamic }),
            error.UnexpectedMessage => return out_err.set(.{ .protocol_error = .unexpected_msg }),
        };
    };
    global.conn = .{
        .sink = sink,
        .source = source,
        .dpi_scale_x = dpi_scale_x,
        .dpi_scale_y = dpi_scale_y,
        .depth = depth,
        .keymap = keymap,
        .write_error = null,
    };
}
pub fn disconnect() void {
    std.debug.assert(global.conn != null);
    global.conn.? = undefined;
    global.conn = null;

    x11.disconnect(global.i.socket_reader.getStream());

    global.i.socket_writer = undefined;
    global.i.screen = undefined;
    global.i.setup = undefined;
    global.i.socket_reader = undefined;
}

fn dpiScaleFromPixelMm(pixels: u16, millimeters: u16) f32 {
    const mm_per_inch = 25.4;
    return @as(f32, @floatFromInt(pixels)) * mm_per_inch / 96.0 / @as(f32, @floatFromInt(millimeters));
}

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: this shouldn't be hardcoded, instead, it should be based on the app config
const support_key_events = true;

pub fn registerDynamicWindowClass(
    comptime config: zin.WindowConfigData,
    comptime def: zin.WindowClassDefinition(.{ .dynamic = config }),
    runtime_config: zin.WindowClassRuntimeConfig,
) WindowClass {
    _ = def;
    _ = runtime_config;
    @panic("todo: dynamic x11 windows");
}

pub const WindowConfig = struct {
    render_kind: enum { immediate, double_buffered },
};

pub const WindowClass = struct {
    callback: *const anyopaque,
    pub fn unregister(self: WindowClass) void {
        _ = self;
    }
};

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
        if (global.conn.?.write_error == null) {
            global.conn.?.sink.MapWindow(self.id) catch |e| global.conn.?.setWriteError(e);
        }
    }
    pub fn startTimer(self: DynamicWindow, id: usize, millis: u32) void {
        _ = self;
        _ = id;
        _ = millis;
        @compileError("todo");
    }
};

const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".fields.len;

pub const min_timer_id_int = 0;

pub const global = struct {
    var process_init_called: bool = false;
    pub var display: x11.Display = undefined;
    pub var parsed_display: x11.ParsedDisplay = undefined;
    pub var host: x11.Host = undefined;

    var use_auth: bool = true;
    var write_buffer: [zin.config.x11_write_buffer_size]u8 = undefined;
    var read_buffer: [zin.config.x11_read_buffer_size]u8 = undefined;

    pub var conn: ?Connection = null;
    // all decls in the i namespace are guaranteed to be initialized while conn
    // is not null (after a successfull call to connect).
    pub const i = struct {
        pub var socket_reader: x11.SocketReader = undefined;
        pub var setup: x11.Setup = undefined;
        pub var screen: x11.ScreenHeader = undefined;
        pub var socket_writer: x11.SocketWriter = undefined;
    };

    var static_callbacks: [static_window_count]?*const anyopaque = @splat(null);
    var static_window_common_states: [static_window_count]StaticWindowCommonState = @splat(.not_created);
    var static_window_custom_states: StaticWindowCustomStates = .{};

    pub fn staticWindowCustomState(comptime window_id: zin.StaticWindowId) *StaticWindowCustomState(window_id) {
        return &@field(static_window_custom_states, @tagName(window_id));
    }
};

fn timerCount(comptime TimerId: type) usize {
    return switch (@typeInfo(TimerId)) {
        .noreturn => 0,
        .void => 1,
        .@"enum" => |info| info.fields.len,
        .int => @compileError("todo"),
        else => @compileError("unsupported TimerId type: " ++ @typeName(TimerId)),
    };
}

const StaticWindowCommonState = union(enum) {
    not_created,
    created: struct {
        damaged: bool,
    },
};
fn StaticWindowCustomState(window_id: zin.StaticWindowId) type {
    return struct {
        client_size: if (window_id.getConfig().window_size_events)
            zin.XY
        else
            void = if (window_id.getConfig().window_size_events)
            .{ .x = 0, .y = 0 }
        else {},
        timers: [timer_count]?Timer = [1]?Timer{null} ** timer_count,
        back_buffer: switch (window_id.getConfig().x11.render_kind) {
            .immediate => struct {},
            .double_buffered => struct {
                allocated: bool = false,
            },
        } = .{},

        pub const timer_count = timerCount(window_id.getConfig().TimerId());

        const Self = @This();
        pub fn onDestroyed(self: *Self) void {
            self.* = .{};
        }
    };
}
const StaticWindowCustomStates = blk: {
    var fields: [static_window_count]std.builtin.Type.StructField = undefined;
    for (&fields, std.meta.fields(zin.StaticWindowId)) |*field, window_id_field| {
        const window_id: zin.StaticWindowId = @enumFromInt(window_id_field.value);
        field.* = .{
            .name = window_id_field.name,
            .type = StaticWindowCustomState(window_id),
            .default_value_ptr = &(StaticWindowCustomState(window_id){}),
            .is_comptime = false,
            .alignment = @alignOf(StaticWindowCustomState(window_id)),
        };
    }
    break :blk @Type(std.builtin.Type{
        .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
};

const StaticWindowAndTimerId = blk: {
    var fields: [static_window_count]std.builtin.Type.UnionField = undefined;
    for (&fields, std.meta.fields(zin.StaticWindowId)) |*field, window_id_field| {
        const window_id: zin.StaticWindowId = @enumFromInt(window_id_field.value);
        const TimerId = window_id.getConfig().TimerId();
        field.* = .{
            .name = window_id_field.name,
            .type = TimerId,
            .alignment = if (TimerId == noreturn) 0 else @alignOf(TimerId),
        };
    }
    break :blk @Type(std.builtin.Type{
        .@"union" = .{
            .layout = .auto,
            .tag_type = zin.StaticWindowId,
            .fields = &fields,
            .decls = &.{},
        },
    });
};

const Timer = struct {
    start: std.time.Instant,
    duration_ms: u64,
};

/// Access the global x11 socket.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11Socket() std.posix.socket_t {
    std.debug.assert(global.conn != null);
    return global.i.socket_reader.getStream().handle;
}
/// Access the global socket writer.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11SocketWriter() *x11.SocketWriter {
    std.debug.assert(global.conn != null);
    return &global.i.socket_writer;
}
/// Access the global socket reader.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11SocketReader() *x11.SocketReader {
    std.debug.assert(global.conn != null);
    return &global.i.socket_reader;
}
/// Access the global x11 Source.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11Source() *x11.Source {
    std.debug.assert(global.conn != null);
    return &global.conn.?.source;
}

fn staticCallback(comptime window_id: zin.StaticWindowId) *const fn (zin.Callback(.{ .static = window_id })) void {
    return @ptrCast(@alignCast(global.static_callbacks[@intFromEnum(window_id)].?));
}

pub fn staticWindow(window_id: zin.StaticWindowId) type {
    const config = zin.WindowConfig{ .static = window_id };

    return struct {
        const Self = @This();

        fn window() Window {
            return .{
                .id = global.conn.?.staticWindowId(window_id),
                .callback = global.static_callbacks[@intFromEnum(window_id)].?,
            };
        }

        pub fn registerClass(
            comptime def: zin.WindowClassDefinition(.{ .static = window_id }),
            runtime_config: zin.WindowClassRuntimeConfig,
        ) void {
            _ = runtime_config;
            std.debug.assert(global.static_callbacks[@intFromEnum(window_id)] == null);
            global.static_callbacks[@intFromEnum(window_id)] = @ptrCast(def.callback);
        }
        pub fn unregisterClass() void {
            std.debug.assert(global.static_callbacks[@intFromEnum(window_id)] != null);
            global.static_callbacks[@intFromEnum(window_id)] = null;
        }
        pub fn create(opt: zin.CreateWindowOptions) zin.CreateWindowError!void {
            //std.debug.assert(global.static_windows[@intFromEnum(window_id)] == null);
            const bg = global.conn.?.x11FromRgb(config.data().background);
            const size = windowPixelSizeFromInit(opt.size, global.conn.?.dpi_scale_x, global.conn.?.dpi_scale_y);
            try createWindow(&config.data(), size, bg, global.conn.?.staticWindowId(window_id));
            global.static_window_common_states[@intFromEnum(window_id)] = .{ .created = .{
                .damaged = false,
            } };
            if (window_id.getConfig().window_size_events) {
                global.staticWindowCustomState(window_id).client_size = size;
            }
        }
        pub fn destroy() void {
            switch (global.static_window_common_states[@intFromEnum(window_id)]) {
                .not_created => @panic("destroy called on windows that's not created"),
                .created => {},
            }

            switch (window_id.getConfig().x11.render_kind) {
                .immediate => {},
                .double_buffered => if (global.staticWindowCustomState(window_id).back_buffer.allocated) {
                    if (global.conn.?.write_error != null) {
                        x11.dbe.Deallocate(
                            &global.conn.?.sink,
                            global.conn.?.dbe.state.resolved.?.opcode_base,
                            backBufferFromWindow(global.conn.?.staticWindowId(window_id)),
                        ) catch |e| global.conn.?.setWriteError(e);
                    }
                },
            }

            if (global.conn.?.write_error == null) {
                global.conn.?.sink.FreeGc(
                    gcFromWindow(global.conn.?.staticWindowId(window_id)),
                ) catch |e| global.conn.?.setWriteError(e);
            }
            if (global.conn.?.write_error == null) {
                global.conn.?.sink.DestroyWindow(
                    global.conn.?.staticWindowId(window_id),
                ) catch |e| global.conn.?.setWriteError(e);
            }
            global.static_window_common_states[@intFromEnum(window_id)] = .not_created;
            global.staticWindowCustomState(window_id).onDestroyed();
        }
        pub fn getClientSize() zin.XY {
            if (!window_id.getConfig().window_size_events) @compileError("getClientSize disabled because window_size_events is false");
            return global.staticWindowCustomState(window_id).client_size;
        }
        pub fn show() void {
            return window().show();
        }
        pub fn foreground() void {
            @panic("todo");
            // global.static_windows[@intFromEnum(window_id)].?.foreground();
        }
        pub fn invalidate() void {
            switch (global.static_window_common_states[@intFromEnum(window_id)]) {
                .not_created => {},
                .created => |*created| created.damaged = true,
            }
        }
        pub fn startTimer(id: window_id.getConfig().TimerId(), millis: u32) void {
            const timers = &global.staticWindowCustomState(window_id).timers;
            timers[zin.intFromTimerId(usize, window_id.getConfig().TimerId(), id)] = .{
                .start = std.time.Instant.now() catch unreachable,
                .duration_ms = millis,
            };
        }
    };
}

pub fn gcFromWindow(id: x11.Window) x11.GraphicsContext {
    return @enumFromInt(@intFromEnum(id) + 1);
}
pub fn backBufferFromWindow(id: x11.Window) x11.Drawable {
    return @enumFromInt(@intFromEnum(id) + 2);
}

fn windowPixelSizeFromInit(init: zin.WindowSizeInit, dpi_scale_x: f32, dpi_scale_y: f32) zin.XY {
    return switch (init) {
        .default => @panic("todo"),
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: the client size is not right
        .client_pixels => |s| s,
        .client_points => |s| .{
            .x = zin.scale(i32, s.x, dpi_scale_x),
            .y = zin.scale(i32, s.y, dpi_scale_y),
        },
        .window_pixels => |s| s,
        .window_points => |s| .{
            .x = zin.scale(i32, s.x, dpi_scale_x),
            .y = zin.scale(i32, s.y, dpi_scale_y),
        },
    };
}

pub fn createDynamicWindow(class: WindowClass, opt: zin.CreateWindowOptions) zin.CreateWindowError!DynamicWindow {
    const window_id = global.conn.?.reserveId().window();
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
    if (global.conn.?.write_error) |e| return e;
    global.conn.?.sink.CreateWindow(.{
        .window_id = id,
        .parent_window_id = global.i.screen.root,
        .depth = 0, // we don't care, just inherit from the parent
        .x = 0,
        .y = 0,
        .width = @intCast(size.x),
        .height = @intCast(size.y),
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        .visual_id = global.i.screen.root_visual,
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
            .KeyPress = 1,
            .KeyRelease = 1,
            .ButtonPress = if (config.mouse_events) 1 else 0,
            .ButtonRelease = if (config.mouse_events) 1 else 0,
            // .EnterWindow = if (config.mouse_events) 1 else 0,
            // .LeaveWindow = if (config.mouse_events) 1 else 0,
            .PointerMotion = if (config.mouse_events) 1 else 0,
            .Exposure = 1,
            // results CirculateNotify, GravityNotify, ConfigureNotify, ReparentNotify, MapNotify
            // UnmapNotify, DestroyNotify
            .StructureNotify = if (config.window_size_events) 1 else 0,
        },
        // .dont_propagate = 1,
    }) catch |e| return global.conn.?.teeWriteError(e);
    global.conn.?.sink.CreateGc(
        gcFromWindow(id),
        id.drawable(),
        .{
            .background = bg,
            .foreground = 0x224477bb,
        },
    ) catch |e| return global.conn.?.teeWriteError(e);
}

pub const VirtualKey = enum(u16) {
    backspace = @intFromEnum(x11.charset.Combined.kbd_backspace_back_space_back_char),
    tab = @intFromEnum(x11.charset.Combined.kbd_tab),
    @"return" = @intFromEnum(x11.charset.Combined.kbd_return_enter),

    shift_left = @intFromEnum(x11.charset.Combined.kbd_left_shift),
    shift_right = @intFromEnum(x11.charset.Combined.kbd_right_shift),
    control_left = @intFromEnum(x11.charset.Combined.kbd_left_control),
    control_right = @intFromEnum(x11.charset.Combined.kbd_right_control),
    alt_left = @intFromEnum(x11.charset.Combined.kbd_left_alt),
    alt_right = @intFromEnum(x11.charset.Combined.kbd_right_alt),
    pause = @intFromEnum(x11.charset.Combined.kbd_pause_hold),
    caps_lock = @intFromEnum(x11.charset.Combined.kbd_caps_lock),
    escape = @intFromEnum(x11.charset.Combined.kbd_escape),
    page_up = @intFromEnum(x11.charset.Combined.kbd_page_up),
    page_down = @intFromEnum(x11.charset.Combined.kbd_page_down),
    end = @intFromEnum(x11.charset.Combined.kbd_end_eol),
    home = @intFromEnum(x11.charset.Combined.kbd_home),
    left = @intFromEnum(x11.charset.Combined.kbd_left),
    up = @intFromEnum(x11.charset.Combined.kbd_up),
    right = @intFromEnum(x11.charset.Combined.kbd_right),
    down = @intFromEnum(x11.charset.Combined.kbd_down),
    print_screen = @intFromEnum(x11.charset.Combined._3170__3270_printscreen),
    insert = @intFromEnum(x11.charset.Combined.kbd_insert_insert_here),
    delete = @intFromEnum(x11.charset.Combined.kbd_delete_rubout),
    super_left = @intFromEnum(x11.charset.Combined.kbd_left_super),
    super_right = @intFromEnum(x11.charset.Combined.kbd_right_super),

    numpad0 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_zero),
    numpad1 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_one),
    numpad2 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_two),
    numpad3 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_three),
    numpad4 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_four),
    numpad5 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_five),
    numpad6 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_six),
    numpad7 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_seven),
    numpad8 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_eight),
    numpad9 = @intFromEnum(x11.charset.Combined.kbd_keypad_digit_nine),

    multiply = @intFromEnum(x11.charset.Combined.kbd_keypad_multiplication_sign_asterisk),
    add = @intFromEnum(x11.charset.Combined.kbd_keypad_plus_sign),
    separator = @intFromEnum(x11.charset.Combined.kbd_keypad_separator_comma),
    subtract = @intFromEnum(x11.charset.Combined.kbd_keypad_minus_sign_hyphen),
    decimal = @intFromEnum(x11.charset.Combined.kbd_keypad_decimal_point_period),

    f1 = @intFromEnum(x11.charset.Combined.kbd_f1),
    f2 = @intFromEnum(x11.charset.Combined.kbd_f2),
    f3 = @intFromEnum(x11.charset.Combined.kbd_f3),
    f4 = @intFromEnum(x11.charset.Combined.kbd_f4),
    f5 = @intFromEnum(x11.charset.Combined.kbd_f5),
    f6 = @intFromEnum(x11.charset.Combined.kbd_f6),
    f7 = @intFromEnum(x11.charset.Combined.kbd_f7),
    f8 = @intFromEnum(x11.charset.Combined.kbd_f8),
    f9 = @intFromEnum(x11.charset.Combined.kbd_f9),
    f10 = @intFromEnum(x11.charset.Combined.kbd_f10),
    f11 = @intFromEnum(x11.charset.Combined.kbd_f11_l1),
    f12 = @intFromEnum(x11.charset.Combined.kbd_f12_l2),
    f13 = @intFromEnum(x11.charset.Combined.kbd_f13_l3),
    f14 = @intFromEnum(x11.charset.Combined.kbd_f14_l4),
    f15 = @intFromEnum(x11.charset.Combined.kbd_f15_l5),
    f16 = @intFromEnum(x11.charset.Combined.kbd_f16_l6),
    f17 = @intFromEnum(x11.charset.Combined.kbd_f17_l7),
    f18 = @intFromEnum(x11.charset.Combined.kbd_f18_l8),
    f19 = @intFromEnum(x11.charset.Combined.kbd_f19_l9),
    f20 = @intFromEnum(x11.charset.Combined.kbd_f20_l10),
    f21 = @intFromEnum(x11.charset.Combined.kbd_f21_r1),
    f22 = @intFromEnum(x11.charset.Combined.kbd_f22_r2),
    f23 = @intFromEnum(x11.charset.Combined.kbd_f23_r3),
    f24 = @intFromEnum(x11.charset.Combined.kbd_f24_r4),

    numlock = @intFromEnum(x11.charset.Combined.kbd_num_lock),
    scroll_lock = @intFromEnum(x11.charset.Combined.kbd_scroll_lock),

    _,
};
pub const ScanCode = u8;
pub const Coord = i16;

pub fn asciiFromKeysym(vk: VirtualKey) ?u8 {
    return switch (@intFromEnum(vk)) {
        ' '...'~' => |a| @intCast(a),
        else => null,
    };
}

fn mouseButtonFromMsg(detail: u8) zin.MouseButtonId {
    return switch (detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => |d| std.debug.panic("todo: map button {} to zin", .{d}),
    };
}

fn drawStaticWindow(comptime window_id: zin.StaticWindowId) error{WriteFailed}!enum { not_created, success } {
    if (global.conn.?.write_error) |e| return e;

    switch (global.static_window_common_states[@intFromEnum(window_id)]) {
        .not_created => return .not_created,
        .created => {},
    }

    const config = zin.WindowConfig{ .static = window_id };
    const window = global.conn.?.staticWindowId(window_id);
    const UseBackBuffer = switch (window_id.getConfig().x11.render_kind) {
        .immediate => void,
        .double_buffered => bool,
    };
    const use_back_buffer: UseBackBuffer = blk: switch (window_id.getConfig().x11.render_kind) {
        .immediate => break :blk {},
        .double_buffered => {
            if (global.staticWindowCustomState(window_id).back_buffer.allocated)
                break :blk true;
            if (try global.conn.?.dbe.get(&global.conn.?.sink)) |dbe| {
                try x11.dbe.Allocate(
                    &global.conn.?.sink,
                    dbe.opcode_base,
                    window,
                    backBufferFromWindow(window),
                    .background,
                );
                global.staticWindowCustomState(window_id).back_buffer.allocated = true;
                break :blk true;
            }
            break :blk false;
        },
    };

    staticCallback(window_id)(.{ .draw = .{
        .window = window,
        .use_back_buffer = use_back_buffer,
        .client_size = if (config.data().window_size_events) global.staticWindowCustomState(window_id).client_size else {},
        .background = if (comptime config.data().dynamic_background) config.data().background else {},
    } });
    if (global.conn.?.write_error) |e| return e;

    switch (window_id.getConfig().x11.render_kind) {
        .immediate => {},
        .double_buffered => if (use_back_buffer) {
            try x11.dbe.Swap(&global.conn.?.sink, global.conn.?.dbe.state.resolved.?.opcode_base, .initAssume(&.{
                .{ .window = window, .action = .background },
            }));
        },
    }
    return .success;
}

pub fn x11UpdateWindows() error{WriteFailed}!usize {
    var update_count: usize = 0;

    for (&global.static_window_common_states, 0..) |*window, static_window_id_raw| switch (window.*) {
        .not_created => {},
        .created => |*created| {
            if (created.damaged) {
                const static_window_id: zin.StaticWindowId = @enumFromInt(static_window_id_raw);
                switch (static_window_id) {
                    inline else => |window_id| switch (try drawStaticWindow(window_id)) {
                        .not_created => unreachable,
                        .success => {},
                    },
                }
                created.damaged = false;
                update_count += 1;
            }
        },
    };

    return update_count;
}

fn pollSocketReader(socket_reader: *x11.SocketReader, timeout_ms: i32) !enum { ready, timeout } {
    if (socket_reader.interface().bufferedLen() > 0) return .ready;
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = socket_reader.getStream().handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    return switch (try std.posix.poll(&poll_fds, timeout_ms)) {
        0 => .timeout,
        1 => .ready,
        else => unreachable,
    };
}

const Timeout = union(enum) {
    none,
    ms: i32,
    expired: StaticWindowAndTimerId,
    pub fn initExpired(comptime window_id: zin.StaticWindowId, timer_id: window_id.getConfig().TimerId()) Timeout {
        return switch (window_id) {
            inline else => |case_window_id| .{ .expired = @unionInit(StaticWindowAndTimerId, @tagName(case_window_id), timer_id) },
        };
    }
};
fn minTimeoutMs(maybe_previous: ?i32, ms: i32) i32 {
    return @min(maybe_previous orelse return ms, ms);
}
fn resolveNow(maybe_now_ref: *?std.time.Instant) std.time.Instant {
    if (maybe_now_ref.* == null) {
        maybe_now_ref.* = std.time.Instant.now() catch unreachable;
    }
    return maybe_now_ref.*.?;
}

fn debugPanic(comptime fmt: []const u8, args: anytype) void {
    switch (builtin.mode) {
        .Debug => std.debug.panic(fmt, args),
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => log.err(fmt, args),
    }
}

fn getTimerMinTimeout(maybe_now_ref: *?std.time.Instant) Timeout {
    var maybe_min_ms: ?i32 = null;
    inline for (std.meta.fields(zin.StaticWindowId)) |field| {
        const window_id: zin.StaticWindowId = @enumFromInt(field.value);
        const timers = &global.staticWindowCustomState(window_id).timers;
        for (timers, 0..) |maybe_timer, timer_index| {
            const timer = maybe_timer orelse continue;
            const diff_ns = resolveNow(maybe_now_ref).since(timer.start);
            const diff_ms: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(diff_ns)) / @as(f32, std.time.ns_per_ms)));
            const TimerId = window_id.getConfig().TimerId();
            const is_negative = diff_ms < 0;
            if (is_negative) {
                debugPanic("timer diff is negative? {}", .{diff_ms});
            }
            if (is_negative or diff_ms >= timer.duration_ms) {
                timers[timer_index].?.start = maybe_now_ref.*.?;
                return .initExpired(window_id, zin.timerIdFromInt(TimerId, timer_index));
            }
            maybe_min_ms = minTimeoutMs(maybe_min_ms, @intCast(timer.duration_ms - @as(u32, @intCast(diff_ms))));
        }
    }
    return if (maybe_min_ms) |min_ms| .{ .ms = min_ms } else .none;
}

pub fn mainLoop() !void {
    while (true) {
        // we prioritize socket messages over timeout, so we only start checking the
        // timeout if the socket has no messages
        while (true) {
            _ = try x11UpdateWindows();
            try global.conn.?.sink.writer.flush();
            switch (try pollSocketReader(&global.i.socket_reader, 0)) {
                .ready => break,
                .timeout => {},
            }
            var maybe_now: ?std.time.Instant = null;
            const expired = blk_expired: switch (getTimerMinTimeout(&maybe_now)) {
                .none => {
                    std.debug.assert(.ready == try pollSocketReader(&global.i.socket_reader, -1));
                    break;
                },
                .ms => |ms| switch (try pollSocketReader(&global.i.socket_reader, ms)) {
                    .ready => break,
                    .timeout => {
                        var new_now: ?std.time.Instant = null;
                        break :blk_expired switch (getTimerMinTimeout(&new_now)) {
                            .none => unreachable,
                            .ms => unreachable,
                            .expired => |expired| expired,
                        };
                    },
                },
                .expired => |expired| break :blk_expired expired,
            };

            switch (expired) {
                inline else => |timer_id, window_id| switch (@typeInfo(@TypeOf(timer_id))) {
                    .void => staticCallback(window_id)(.{ .timer = {} }),
                    .@"enum" => {
                        @panic("todo");
                    },
                    else => |TimerId| @compileError("todo: handle TimerId type: " ++ @tagName(TimerId)),
                },
            }
        }

        const msg_kind = global.conn.?.source.readKind() catch |err| return switch (err) {
            error.EndOfStream => {
                log.info("X11 connection closed (EndOfStream)", .{});
                return;
            },
            else => |e| switch (global.i.socket_reader.getError() orelse e) {
                error.ConnectionResetByPeer => {
                    log.info("X11 connection closed (ConnectionReset)", .{});
                    return;
                },
                else => |e2| e2,
            },
        };
        try x11HandleMessage(&global.conn.?.source, msg_kind);
    }
}
pub fn quitMainLoop() void {
    if (global.conn != null) {
        std.posix.shutdown(global.i.socket_reader.getStream().handle, .both) catch |err| switch (err) {
            error.BlockingOperationInProgress => unreachable,
            error.SystemResources,
            error.NetworkSubsystemFailed,
            error.Unexpected,
            => |e| std.debug.panic("shutdown failed with {s}", .{@errorName(e)}),
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            error.ConnectionAborted,
            => {},
        };
    }
}

pub fn x11HandleMessage(source: *x11.Source, msg_kind: x11.ServerMsgKind) !void {
    switch (msg_kind) {
        .Error => {
            const err = try source.read2(.Error);
            switch (err.code) {
                // .drawable => {
                //     // these errors are expected, if a window is destroyed while we are rendering
                //     // to it which I think is a non-preventable error.
                //     const bad_id = msg.generic;
                //     switch (global.connection.drawableFromX11Id(msg.generic)) {
                //         .not_drawable => std.debug.panic(
                //             "X11 bad drawable error for non-drawable id {} (base={}): {}",
                //             .{ bad_id, @intFromEnum(global.connection.setup.fixed().resource_id_base), msg },
                //         ),
                //         .static_window => |window_id| {
                //             log.info("X11 bad drawable for static window {s}", .{@tagName(window_id)});
                //             // TODO: we should verify that during this
                //             //       sequence the static window was destroyed or something?
                //         },
                //         .static_back_buffer => |window_id| {
                //             log.info("X11 bad drawable for back_buffer of static window {s}", .{@tagName(window_id)});
                //             // TODO: we should verify that during this
                //             //       sequence the static window was destroyed or something?
                //         },
                //     }
                // },
                // TODO: handle more errors, errors should be recoverable
                else => std.debug.panic("Unhandled X11 Error: {f}", .{err}),
            }
        },
        .Reply => {
            const reply = try source.read2(.Reply);
            const remaining = source.replyRemainingSize();
            try global.conn.?.dbe.onReply(source, reply);
            if (source.replyRemainingSize() != remaining) return;
            log.info("todo: handle a reply message {f}", .{source.readFmt()});
            try source.discardRemaining();
            return error.TodoHandleReplyMessage;
        },
        .KeyPress => {
            const event = try source.read2(.KeyPress);
            if (global.conn.?.staticWindowFromX11Id(event.event)) |w| switch (w) {
                inline else => |window_id| {
                    const config = zin.WindowConfig{ .static = window_id };
                    if (config.data().key_events) {
                        if (global.conn.?.keymap.getKeysym(event.keycode, event.state.mod())) |keysym| {
                            staticCallback(window_id)(.{ .key = keyFromX11(.down, event.keycode, event.state, keysym) });
                        } else |err| switch (err) {
                            error.KeycodeTooSmall => {
                                log.err("KeyPress keycode {} is too small", .{event.keycode});
                            },
                        }
                    }
                },
            } else @panic("todo: motion_notify on dynamic windows");
        },
        .KeyRelease => {
            const event = try source.read2(.KeyRelease);
            if (global.conn.?.staticWindowFromX11Id(event.event)) |w| switch (w) {
                inline else => |window_id| {
                    const config = zin.WindowConfig{ .static = window_id };
                    if (config.data().key_events) {
                        if (global.conn.?.keymap.getKeysym(event.keycode, event.state.mod())) |keysym| {
                            staticCallback(window_id)(.{ .key = keyFromX11(.up, event.keycode, event.state, keysym) });
                        } else |err| switch (err) {
                            error.KeycodeTooSmall => {
                                log.err("KeyRelease keycode {} is too small", .{event.keycode});
                            },
                        }
                    }
                },
            } else @panic("todo: motion_notify on dynamic windows");
        },
        .ButtonPress => {
            const event = try source.read2(.ButtonPress);
            const button_id = mouseButtonFromMsg(event.button);
            const pos: zin.XY = .{
                .x = @intCast(event.event_x),
                .y = @intCast(event.event_y),
            };
            if (global.conn.?.staticWindowFromX11Id(event.event)) |w| switch (w) {
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
        .ButtonRelease => {
            const event = try source.read2(.ButtonRelease);
            const button_id = mouseButtonFromMsg(event.button);
            const pos: zin.XY = .{
                .x = @intCast(event.event_x),
                .y = @intCast(event.event_y),
            };
            if (global.conn.?.staticWindowFromX11Id(event.event)) |w| switch (w) {
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
        // .enter_notify => |msg| {
        //     log.info("enter_window: {}", .{msg});
        // },
        // .leave_notify => |msg| {
        //     log.info("leave_window: {}", .{msg});
        // },
        .MotionNotify => {
            const event = try source.read2(.MotionNotify);
            const pos: zin.XY = .{
                .x = @intCast(event.event_x),
                .y = @intCast(event.event_y),
            };
            if (global.conn.?.staticWindowFromX11Id(event.event)) |w| switch (w) {
                inline else => |window_id| {
                    const config = zin.WindowConfig{ .static = window_id };
                    if (config.data().mouse_events) {
                        staticCallback(window_id)(.{ .mouse = .{ .position = pos, .button = null } });
                    }
                },
            } else @panic("todo: motion_notify on dynamic windows");
        },
        .Expose => {
            const expose = try source.read2(.Expose);
            if (global.conn.?.staticWindowFromX11Id(expose.window)) |w| switch (w) {
                inline else => |window_id| switch (try drawStaticWindow(window_id)) {
                    .not_created => {}, // ok means we destroyed this window
                    .success => {},
                },
            } else @panic("todo: expose on dynamic windows");
        },

        // messages we ignoring but still logging
        .MappingNotify,
        .UnmapNotify,
        .MapNotify,
        .ReparentNotify,
        => {
            log.debug("ignoring X11 {f}", .{source.readFmt()});
            // ensures we still discard the rest of the message if logging is disabled
            try source.discardRemaining();
        },
        .DestroyNotify => {
            const msg = try source.read2(.DestroyNotify);
            if (global.conn.?.staticWindowFromX11Id(msg.window)) |window_id| {
                switch (global.static_window_common_states[@intFromEnum(window_id)]) {
                    .not_created => {}, // ok, means the user must have closed the window
                    .created => @panic("todo: notify app that a window was destroyed"),
                }
            } else @panic("todo: expose on dynamic windows");
        },
        .ConfigureNotify => {
            const msg = try source.read2(.ConfigureNotify);
            if (global.conn.?.staticWindowFromX11Id(msg.window)) |w| switch (w) {
                inline else => |window_id| {
                    std.debug.assert(window_id.getConfig().window_size_events);
                    const current_size = global.staticWindowCustomState(window_id).client_size;
                    if (msg.width != current_size.x or msg.height != current_size.y) {
                        global.staticWindowCustomState(window_id).client_size = .{ .x = msg.width, .y = msg.height };
                        staticCallback(window_id)(.{ .window_size = .{ .x = msg.width, .y = msg.height } });
                    }
                },
            } else @panic("todo: configure_notify on dynamic windows");
        },
        // .generic_extension_event => |msg| std.debug.panic("unexpected generic_extension_event {}", .{msg}),
        else => {
            log.err("Unexpected X11 {f}", .{source.readFmt()});
            try source.discardRemaining();
            return error.X11UnexpectedMessage;
        },
    }
}

fn keyFromX11(direction: enum { up, down }, keycode: u8, mask: x11.KeyButtonMask, keysym: x11.charset.Combined) zin.Key {
    return .{
        .kind = switch (direction) {
            .up => .up,
            .down => .down,
        },
        .vk = @enumFromInt(@intFromEnum(keysym)),
        .scan_code = keycode,
        .win32_extended = {},
        .x11_mask = mask,
        .macos_mods = {},
    };
}

fn giveup(what: []const u8, e: anyerror) noreturn {
    std.debug.panic("{s} failed with {s}", .{ what, @errorName(e) });
}

pub fn Draw(window_config: zin.WindowConfig) type {
    return struct {
        window: x11.Window,
        use_back_buffer: switch (window_config.data().x11.render_kind) {
            .immediate => void,
            .double_buffered => bool,
        },
        client_size: if (window_config.data().window_size_events) zin.XY else void,
        background: if (window_config.data().dynamic_background) zin.Rgb8 else void,

        const Self = @This();

        pub fn x11Drawable(self: *const Self) x11.Drawable {
            return switch (window_config.data().x11.render_kind) {
                .immediate => self.window.drawable(),
                .double_buffered => if (self.use_back_buffer)
                    backBufferFromWindow(self.window)
                else
                    self.window.drawable(),
            };
        }

        pub fn getDpiScale(self: *const Self) struct { x: f32, y: f32 } {
            _ = self;
            return .{ .x = global.conn.?.dpi_scale_x, .y = global.conn.?.dpi_scale_y };
        }

        pub fn clear(self: *const Self) void {
            if (global.conn.?.write_error != null) return;
            switch (window_config.data().x11.render_kind) {
                .immediate => {},
                .double_buffered => if (self.use_back_buffer) return,
            }
            const rgb = if (comptime window_config.data().dynamic_background)
                self.background
            else
                window_config.data().background;
            global.conn.?.sink.ChangeGc(gcFromWindow(self.window), .{
                .background = global.conn.?.x11FromRgb(rgb),
            }) catch |e| return global.conn.?.setWriteError(e);
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: get the actual width/height
            global.conn.?.sink.ClearArea(self.window, .{
                .x = 0,
                .y = 0,
                .width = @intCast(self.client_size.x),
                .height = @intCast(self.client_size.y),
            }, .{ .exposures = false }) catch |e| return global.conn.?.setWriteError(e);
        }

        pub fn rect(self: *const Self, r: zin.Rect, rgb: zin.Rgb8) void {
            if (global.conn.?.write_error != null) return;
            global.conn.?.sink.ChangeGc(gcFromWindow(self.window), .{
                .foreground = global.conn.?.x11FromRgb(rgb),
            }) catch |e| global.conn.?.setWriteError(e);
            global.conn.?.sink.PolyFillRectangle(
                self.x11Drawable(),
                gcFromWindow(self.window),
                .initAssume(&[_]x11.Rectangle{.{
                    .x = @intCast(r.left),
                    .y = @intCast(r.top),
                    .width = @intCast(r.right - r.left),
                    .height = @intCast(r.bottom - r.top),
                }}),
            ) catch |e| global.conn.?.setWriteError(e);
        }

        pub fn text(self: *const Self, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            if (global.conn.?.write_error != null) return;
            const slice = x11.SliceWithMaxLen(u8, [*]const u8, 254){
                .ptr = t.ptr,
                .len = std.math.cast(u8, t.len) orelse std.debug.panic("TODO: handle text with {} bytes", .{t.len}),
            };
            global.conn.?.sink.ChangeGc(gcFromWindow(self.window), .{
                .background = 0, // TODO: how do we declare this as transparent?
                .foreground = global.conn.?.x11FromRgb(rgb),
            }) catch |e| global.conn.?.setWriteError(e);
            global.conn.?.sink.PolyText8(
                self.x11Drawable(),
                gcFromWindow(self.window),
                .{
                    .x = std.math.cast(i16, x) orelse std.debug.panic("TODO: what to do with x value of {}", .{x}),
                    .y = std.math.cast(i16, y) orelse std.debug.panic("TODO: what to do with y value of {}", .{y}),
                },
                &[_]x11.TextItem8{
                    .{ .text_element = .{ .delta = 0, .string = slice } },
                },
            ) catch |e| global.conn.?.setWriteError(e);
        }
    };
}
