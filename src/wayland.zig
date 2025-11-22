const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin.zig");

const log = std.log.scoped(.wayland);

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

comptime {
    std.debug.assert(@sizeOf(Header) == 8);
}
const Header = extern struct {
    object_id: u32,
    opcode_and_size: u32,

    pub fn init(object_id: u32, opcode_val: u16, size_val: u16) Header {
        return .{
            .object_id = object_id,
            .opcode_and_size = @as(u32, size_val) << 16 | opcode_val,
        };
    }

    pub fn opcode(self: Header) u16 {
        return @truncate(self.opcode_and_size);
    }

    pub fn size(self: Header) u16 {
        return @truncate(self.opcode_and_size >> 16);
    }
};

/// Round up to next multiple of 4 (Wayland alignment requirement)
fn roundUp4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

// Well-known object IDs
const DISPLAY_ID: u32 = 1;

// wl_display opcodes (requests)
const WL_DISPLAY_SYNC: u16 = 0;
const WL_DISPLAY_GET_REGISTRY: u16 = 1;

// wl_display opcodes (events)
const WL_DISPLAY_ERROR: u16 = 0;
const WL_DISPLAY_DELETE_ID: u16 = 1;

// wl_registry opcodes (requests)
const WL_REGISTRY_BIND: u16 = 0;

// wl_registry opcodes (events)
const WL_REGISTRY_GLOBAL: u16 = 0;
const WL_REGISTRY_GLOBAL_REMOVE: u16 = 1;

// wl_callback opcodes (events)
const WL_CALLBACK_DONE: u16 = 0;

// wl_compositor opcodes (requests)
const WL_COMPOSITOR_CREATE_SURFACE: u16 = 0;

// wl_shm opcodes (requests)
const WL_SHM_CREATE_POOL: u16 = 0;

// wl_shm opcodes (events)
const WL_SHM_FORMAT: u16 = 0;

// wl_shm_pool opcodes (requests)
const WL_SHM_POOL_CREATE_BUFFER: u16 = 0;
const WL_SHM_POOL_DESTROY: u16 = 1;

// wl_buffer opcodes (events)
const WL_BUFFER_RELEASE: u16 = 0;

// wl_surface opcodes (requests)
const WL_SURFACE_DESTROY: u16 = 0;
const WL_SURFACE_ATTACH: u16 = 1;
const WL_SURFACE_DAMAGE: u16 = 2;
const WL_SURFACE_FRAME: u16 = 3;
const WL_SURFACE_COMMIT: u16 = 6;
const WL_SURFACE_DAMAGE_BUFFER: u16 = 9;

// xdg_wm_base opcodes (requests)
const XDG_WM_BASE_DESTROY: u16 = 0;
const XDG_WM_BASE_CREATE_POSITIONER: u16 = 1;
const XDG_WM_BASE_GET_XDG_SURFACE: u16 = 2;
const XDG_WM_BASE_PONG: u16 = 3;

// xdg_wm_base opcodes (events)
const XDG_WM_BASE_PING: u16 = 0;

// xdg_surface opcodes (requests)
const XDG_SURFACE_DESTROY: u16 = 0;
const XDG_SURFACE_GET_TOPLEVEL: u16 = 1;
const XDG_SURFACE_ACK_CONFIGURE: u16 = 4;

// xdg_surface opcodes (events)
const XDG_SURFACE_CONFIGURE: u16 = 0;

// xdg_toplevel opcodes (requests)
const XDG_TOPLEVEL_DESTROY: u16 = 0;
const XDG_TOPLEVEL_SET_TITLE: u16 = 2;

// xdg_toplevel opcodes (events)
const XDG_TOPLEVEL_CONFIGURE: u16 = 0;
const XDG_TOPLEVEL_CLOSE: u16 = 1;

// Pixel formats
const WL_SHM_FORMAT_ARGB8888: u32 = 0;
const WL_SHM_FORMAT_XRGB8888: u32 = 1;

// ============================================================================
// Connection State
// ============================================================================

const Connection = struct {
    socket: std.posix.socket_t,
    next_id: u32 = 2, // ID 1 is always wl_display

    // Bound globals
    registry_id: ?u32 = null,
    compositor_id: ?u32 = null,
    shm_id: ?u32 = null,
    xdg_wm_base_id: ?u32 = null,

    // Global names (for binding)
    compositor_name: ?u32 = null,
    shm_name: ?u32 = null,
    xdg_wm_base_name: ?u32 = null,

    read_buffer: [4096]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    write_buffer: [4096]u8 = undefined,
    write_pos: usize = 0,

    pub fn allocId(self: *Connection) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn flush(self: *Connection) !void {
        if (self.write_pos == 0) return;
        const written = try std.posix.write(self.socket, self.write_buffer[0..self.write_pos]);
        if (written != self.write_pos) return error.PartialWrite;
        self.write_pos = 0;
    }

    pub fn send(self: *Connection, data: []const u8) !void {
        if (self.write_pos + data.len > self.write_buffer.len) {
            try self.flush();
        }
        if (data.len > self.write_buffer.len) {
            _ = try std.posix.write(self.socket, data);
        } else {
            @memcpy(self.write_buffer[self.write_pos..][0..data.len], data);
            self.write_pos += data.len;
        }
    }

    pub fn sendMessage(self: *Connection, object_id: u32, opcode: u16, payload: []const u8) !void {
        const size: u16 = @intCast(8 + payload.len);
        const header = Header.init(object_id, opcode, size);
        try self.send(std.mem.asBytes(&header));
        if (payload.len > 0) {
            try self.send(payload);
        }
    }

    pub fn readMessage(self: *Connection) !?struct { header: Header, payload: []const u8 } {
        // Ensure we have at least a header
        while (self.read_len - self.read_pos < 8) {
            if (self.read_pos > 0 and self.read_len > self.read_pos) {
                std.mem.copyForwards(u8, &self.read_buffer, self.read_buffer[self.read_pos..self.read_len]);
                self.read_len -= self.read_pos;
                self.read_pos = 0;
            } else if (self.read_pos > 0) {
                self.read_pos = 0;
                self.read_len = 0;
            }

            const n = std.posix.read(self.socket, self.read_buffer[self.read_len..]) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            self.read_len += n;
        }

        const header: Header = @bitCast(self.read_buffer[self.read_pos..][0..8].*);
        const msg_size = header.size();
        if (msg_size < 8) return error.InvalidMessageSize;

        // Ensure we have the full message
        while (self.read_len - self.read_pos < msg_size) {
            const n = std.posix.read(self.socket, self.read_buffer[self.read_len..]) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            self.read_len += n;
        }

        const payload = self.read_buffer[self.read_pos + 8 ..][0 .. msg_size - 8];
        self.read_pos += msg_size;

        return .{ .header = header, .payload = payload };
    }
};

// ============================================================================
// Global State
// ============================================================================

pub const global = struct {
    var process_init_called: bool = false;
    var conn: ?Connection = null;
    var running: bool = false;
};

pub const ConnectError = union(enum) {
    //connect_error: x11.ConnectError,
    //recv_error: (error{EndOfStream} || x11.SocketReader.Error),
    //send_error: x11.SocketWriter.Error,
    //protocol_error: enum { setup, setup_dynamic, depth, keycode_range, unexpected_msg },
    //cant_authenticate,
    //no_screen,
    todo,

    fn set(err: *ConnectError, value: ConnectError) error{Connect} {
        err.* = value;
        return error.Connect;
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
        _ = writer;
        switch (err) {
            //     .connect_error => |e| try writer.print("socket connect failed with {s}", .{@errorName(e)}),
            //     .recv_error => |e| try writer.print("socket receive failed with {s}", .{@errorName(e)}),
            //     .send_error => |e| try writer.print("socket send failed with {s}", .{@errorName(e)}),
            //     .protocol_error => |e| try writer.print("server protocol error: {s}", .{@tagName(e)}),
            //     .cant_authenticate => try writer.writeAll("failed to authenticate"),
            //     .no_screen => try writer.writeAll("server reported no screens"),
            .todo => @panic("todo"),
        }
    }
};

pub fn connect(out_err: *ConnectError) error{Connect}!void {
    std.debug.assert(global.process_init_called);
    std.debug.assert(global.conn == null);
    errdefer {
        std.debug.assert(global.conn == null);
        //global.i.socket_writer = undefined;
        //global.i.screen = undefined;
        //global.i.setup = undefined;
        //global.i.socket_reader = undefined;
    }

    return out_err.set(.todo);
    //     global.i.socket_reader, global.use_auth = blk: {
    //         const address, const initial_stream = x11.connect(&global.host) catch |err| {
    //             return out_err.set(.{ .connect_error = err });
    //         };
    //         errdefer x11.disconnect(initial_stream);
    //         if (zig_atleast_15)
    //             log.info("connected to {f}", .{address})
    //         else
    //             log.info("connected to {}", .{address});
    //         break :blk x11.draft.authenticate(
    //             global.display,
    //             &global.parsed_display,
    //             &global.host,
    //             &address,
    //             initial_stream,
    //             &global.read_buffer,
    //             .{ .order = if (global.use_auth) .auth_first else .no_auth_first },
    //         ) catch |err| switch (err) {
    //             error.X11Authentication => return out_err.set(.cant_authenticate),
    //         };
    //     };
    //     errdefer x11.disconnect(global.i.socket_reader.getStream());

    //     global.i.setup = x11.readSetupSuccess(global.i.socket_reader.interface()) catch |err| switch (err) {
    //         error.ReadFailed => return out_err.set(.{
    //             .recv_error = global.i.socket_reader.getError() orelse error.Unexpected,
    //         }),
    //         error.EndOfStream => return out_err.set(.{ .recv_error = error.EndOfStream }),
    //         error.X11Protocol => return out_err.set(.{ .protocol_error = .setup }),
    //     };
    //     std.log.info("setup reply {f}", .{global.i.setup});
    //     var source: x11.Source = .initFinishSetup(global.i.socket_reader.interface(), &global.i.setup);
    //     global.i.screen = (x11.draft.readSetupDynamic(&source, &global.i.setup, .{
    //         .on_visual = if (zin.config.x11_on_visual) |f| &f else null,
    //     }) catch |err| switch (err) {
    //         error.ReadFailed => return out_err.set(.{
    //             .recv_error = global.i.socket_reader.getError() orelse error.Unexpected,
    //         }),
    //         error.EndOfStream => return out_err.set(.{ .recv_error = error.EndOfStream }),
    //         error.X11Protocol => return out_err.set(.{ .protocol_error = .setup_dynamic }),
    //     }) orelse return out_err.set(.no_screen);
    //     global.i.socket_writer = x11.socketWriter(global.i.socket_reader.getStream(), &global.write_buffer);
    //     var sink: x11.RequestSink = .{ .writer = &global.i.socket_writer.interface };

    //     const dpi_scale_x = dpiScaleFromPixelMm(global.i.screen.pixel_width, global.i.screen.mm_width);
    //     const dpi_scale_y = dpiScaleFromPixelMm(global.i.screen.pixel_height, global.i.screen.mm_height);
    //     log.debug("DPI {d:.2}x{d:.2}", .{ dpi_scale_x, dpi_scale_y });
    //     const depth = x11.Depth.init(global.i.screen.root_depth) orelse {
    //         log.err("unsupported screen depth {}", .{global.i.screen.root_depth});
    //         return out_err.set(.{ .protocol_error = .depth });
    //     };

    //     const keymap: if (support_key_events) x11.keymap.Full else void = blk: {
    //         if (!support_key_events) break :blk {};
    //         const keyrange = x11.KeycodeRange.init(
    //             global.i.setup.min_keycode,
    //             global.i.setup.max_keycode,
    //         ) catch return out_err.set(.{ .protocol_error = .keycode_range });
    //         // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //         // TODO: should the initSynchronous function take the keymap by reference instead
    //         break :blk x11.keymap.Full.initSynchronous(&sink, &source, keyrange) catch |err| return switch (err) {
    //             error.WriteFailed => return out_err.set(.{ .send_error = global.i.socket_writer.err orelse error.Unexpected }),
    //             error.ReadFailed => return out_err.set(.{
    //                 .recv_error = global.i.socket_reader.getError() orelse error.Unexpected,
    //             }),
    //             error.EndOfStream => return out_err.set(.{ .recv_error = error.EndOfStream }),
    //             error.X11Protocol => return out_err.set(.{ .protocol_error = .setup_dynamic }),
    //             error.UnexpectedMessage => return out_err.set(.{ .protocol_error = .unexpected_msg }),
    //         };
    //     };
    //     global.conn = .{
    //         .sink = sink,
    //         .source = source,
    //         .dpi_scale_x = dpi_scale_x,
    //         .dpi_scale_y = dpi_scale_y,
    //         .depth = depth,
    //         .keymap = keymap,
    //         .write_error = null,
    //     };
    //     global.onConnected();
}

pub fn disconnect() void {
    std.debug.assert(global.conn != null);
    //global.onDisconnect();
    global.conn.? = undefined;
    global.conn = null;

    //x11.disconnect(global.i.socket_reader.getStream());

    //global.i.socket_writer = undefined;
    //global.i.screen = undefined;
    //global.i.setup = undefined;
    //global.i.socket_reader = undefined;
}

// ============================================================================
// Helper Functions
// ============================================================================

fn connectToCompositor() !std.posix.socket_t {
    const xdg_runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ xdg_runtime, wayland_display }) catch return error.PathTooLong;

    const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(socket);

    var addr: std.posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);

    try std.posix.connect(socket, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

    log.info("connected to Wayland compositor at {s}", .{path});
    return socket;
}

fn sendGetRegistry(conn: *Connection) !u32 {
    const registry_id = conn.allocId();
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, registry_id, .little);
    try conn.sendMessage(DISPLAY_ID, WL_DISPLAY_GET_REGISTRY, &payload);
    return registry_id;
}

fn sendSync(conn: *Connection) !u32 {
    const callback_id = conn.allocId();
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, callback_id, .little);
    try conn.sendMessage(DISPLAY_ID, WL_DISPLAY_SYNC, &payload);
    return callback_id;
}

fn sendRegistryBind(conn: *Connection, name: u32, interface: []const u8, version: u32, new_id: u32) !void {
    const interface_len_padded = roundUp4(interface.len + 1);
    const payload_size = 4 + 4 + interface_len_padded + 4 + 4;
    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    // name
    std.mem.writeInt(u32, payload[pos..][0..4], name, .little);
    pos += 4;

    // interface (string: length + data + null + padding)
    std.mem.writeInt(u32, payload[pos..][0..4], @intCast(interface.len + 1), .little);
    pos += 4;
    @memcpy(payload[pos..][0..interface.len], interface);
    pos += interface.len;
    payload[pos] = 0;
    pos += 1;
    while (pos % 4 != 0) : (pos += 1) {
        payload[pos] = 0;
    }

    // version
    std.mem.writeInt(u32, payload[pos..][0..4], version, .little);
    pos += 4;

    // new_id
    std.mem.writeInt(u32, payload[pos..][0..4], new_id, .little);
    pos += 4;

    try conn.sendMessage(conn.registry_id.?, WL_REGISTRY_BIND, payload[0..payload_size]);
}

fn handleRegistryGlobal(conn: *Connection, payload: []const u8) !void {
    if (payload.len < 12) return error.InvalidMessage;

    const name = std.mem.readInt(u32, payload[0..4], .little);
    const interface_len = std.mem.readInt(u32, payload[4..8], .little);

    if (interface_len == 0 or payload.len < 8 + interface_len) return error.InvalidMessage;

    const interface = payload[8..][0 .. interface_len - 1]; // -1 to exclude null terminator
    const version_offset = 8 + roundUp4(interface_len);
    if (payload.len < version_offset + 4) return error.InvalidMessage;
    const version = std.mem.readInt(u32, payload[version_offset..][0..4], .little);

    log.debug("registry global: name={}, interface={s}, version={}", .{ name, interface, version });

    if (std.mem.eql(u8, interface, "wl_compositor")) {
        conn.compositor_name = name;
    } else if (std.mem.eql(u8, interface, "wl_shm")) {
        conn.shm_name = name;
    } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
        conn.xdg_wm_base_name = name;
    }
}

fn bindGlobals(conn: *Connection) !void {
    if (conn.compositor_name) |name| {
        conn.compositor_id = conn.allocId();
        try sendRegistryBind(conn, name, "wl_compositor", 4, conn.compositor_id.?);
        log.info("bound wl_compositor id={}", .{conn.compositor_id.?});
    }
    if (conn.shm_name) |name| {
        conn.shm_id = conn.allocId();
        try sendRegistryBind(conn, name, "wl_shm", 1, conn.shm_id.?);
        log.info("bound wl_shm id={}", .{conn.shm_id.?});
    }
    if (conn.xdg_wm_base_name) |name| {
        conn.xdg_wm_base_id = conn.allocId();
        try sendRegistryBind(conn, name, "xdg_wm_base", 2, conn.xdg_wm_base_id.?);
        log.info("bound xdg_wm_base id={}", .{conn.xdg_wm_base_id.?});
    }
}

fn sendPong(conn: *Connection, serial: u32) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, serial, .little);
    try conn.sendMessage(conn.xdg_wm_base_id.?, XDG_WM_BASE_PONG, &payload);
}

// ============================================================================
// Public API (matches zin.zig interface)
// ============================================================================

pub fn panic(panic_opt: zin.PanicOptions) type {
    _ = panic_opt;
    return std.debug.FullPanic(struct {
        pub fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic);
}

pub fn processInit(opt: zin.ProcessInitOptions) zin.ProcessInitError!void {
    std.debug.assert(!global.process_init_called);
    global.process_init_called = true;

    _ = opt;
    //     if (builtin.os.tag == .windows) {
    //         @compileError("wayland not supported on windows");
    //         //     if (opt.x11_wsa_startup) {
    //         //         var data: win32.WSAData = undefined;
    //         //         const result = win32.WSAStartup((@as(u16, 2) << 8) | 2, &data);
    //         //         if (result != 0) {
    //         //             log.err("WSAStartup failed, error={}", .{result});
    //         //             return error.X11WsaStartupFailed;
    //         //         }
    //         //     }
    //     }
    //     const xdg_runtime_dir = std.posx.getenv("XDG_RUNTIME_DIR") orelse return error.WaylandNoXdgRuntimeDir;
    //     const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
}

pub const WindowConfig = struct {
    // Wayland-specific window config (currently empty)
};

pub const WindowClass = struct {
    callback: *const anyopaque,
    pub fn unregister(self: WindowClass) void {
        _ = self;
    }
};

pub const DynamicWindow = struct {
    id: u32,
    callback: *const anyopaque,

    pub fn destroy(self: DynamicWindow) void {
        _ = self;
        @panic("todo: DynamicWindow.destroy");
    }
    pub fn show(self: DynamicWindow) void {
        _ = self;
        @panic("todo: DynamicWindow.show");
    }
    pub fn startTimer(self: DynamicWindow, id: usize, millis: u32) void {
        _ = self;
        _ = id;
        _ = millis;
        @panic("todo: DynamicWindow.startTimer");
    }
};

pub const VirtualKey = enum(u16) {
    backspace = 8,
    tab = 9,
    @"return" = 13,
    escape = 27,
    space = 32,
    _,
};

pub const ScanCode = u8;

pub const CreateWindowOptions = struct {
    // Wayland-specific options (currently empty)
};

pub const min_timer_id_int = 0;

const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".fields.len;

var static_callbacks: [static_window_count]?*const anyopaque = @splat(null);

pub fn staticWindow(window_id: zin.StaticWindowId) type {
    const config = zin.WindowConfig{ .static = window_id };
    _ = config;

    return struct {
        pub fn registerClass(
            comptime def: zin.WindowClassDefinition(.{ .static = window_id }),
            runtime_config: zin.WindowClassRuntimeConfig,
        ) void {
            _ = runtime_config;
            std.debug.assert(static_callbacks[@intFromEnum(window_id)] == null);
            static_callbacks[@intFromEnum(window_id)] = @ptrCast(def.callback);
        }

        pub fn unregisterClass() void {
            std.debug.assert(static_callbacks[@intFromEnum(window_id)] != null);
            static_callbacks[@intFromEnum(window_id)] = null;
        }

        pub fn create(opt: zin.CreateWindowOptions) zin.CreateWindowError!void {
            _ = opt;
            log.info("staticWindow.create called for {s}", .{@tagName(window_id)});
            // TODO: Create Wayland surface
        }

        pub fn destroy() void {
            log.info("staticWindow.destroy called for {s}", .{@tagName(window_id)});
            // TODO: Destroy Wayland surface
        }

        pub fn getClientSize() zin.XY {
            if (!window_id.getConfig().window_size_events) @compileError("getClientSize disabled");
            return .{ .x = 800, .y = 600 }; // TODO: Return actual size
        }

        pub fn show() void {
            log.info("staticWindow.show called for {s}", .{@tagName(window_id)});
            // TODO: Map surface
        }

        pub fn foreground() void {
            // Wayland doesn't support forcing windows to foreground
        }

        pub fn invalidate() void {
            // TODO: Mark surface as needing redraw
        }

        pub fn startTimer(id: window_id.getConfig().TimerId(), millis: u32) void {
            _ = id;
            _ = millis;
            @panic("todo: startTimer");
        }
    };
}

pub fn registerDynamicWindowClass(
    comptime config: zin.WindowConfigData,
    comptime def: zin.WindowClassDefinition(.{ .dynamic = config }),
    runtime_config: zin.WindowClassRuntimeConfig,
) WindowClass {
    _ = def;
    _ = runtime_config;
    @panic("todo: registerDynamicWindowClass");
}

pub fn createDynamicWindow(class: WindowClass, opt: zin.CreateWindowOptions) zin.CreateWindowError!DynamicWindow {
    _ = class;
    _ = opt;
    @panic("todo: createDynamicWindow");
}

pub fn Draw(window_config: zin.WindowConfig) type {
    return struct {
        window_id: u32,
        client_size: if (window_config.data().window_size_events) zin.XY else void,
        background: if (window_config.data().dynamic_background) zin.Rgb8 else void,

        const Self = @This();

        pub fn getDpiScale(self: *const Self) struct { x: f32, y: f32 } {
            _ = self;
            return .{ .x = 1.0, .y = 1.0 }; // TODO: Get actual DPI scale
        }

        pub fn clear(self: *const Self) void {
            _ = self;
            // TODO: Clear surface
        }

        pub fn rect(self: *const Self, r: zin.Rect, rgb: zin.Rgb8) void {
            _ = self;
            _ = r;
            _ = rgb;
            // TODO: Draw rectangle
        }

        pub fn text(self: *const Self, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            _ = self;
            _ = t;
            _ = x;
            _ = y;
            _ = rgb;
            // TODO: Draw text
        }

        pub fn polygon(self: *const Self, points: []const PolygonPoint, rgb: zin.Rgb8) void {
            _ = self;
            _ = points;
            _ = rgb;
            // TODO: Draw polygon
        }
    };
}

pub const PolygonPoint = struct {
    x: i16,
    y: i16,
    pub fn xy(x: i32, y: i32) PolygonPoint {
        return .{ .x = @truncate(x), .y = @truncate(y) };
    }
};

pub fn clear(draw: anytype) void {
    draw.clear();
}

pub fn text(draw: anytype, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
    draw.text(t, x, y, rgb);
}

pub fn mainLoop() !void {
    // const socket = try connectToCompositor();
    // defer std.posix.close(socket);

    // var conn = Connection{ .socket = socket };
    // global.conn = &conn;
    // defer global.conn = null;

    // // Get registry
    // conn.registry_id = try sendGetRegistry(&conn);
    // const sync_callback = try sendSync(&conn);
    // try conn.flush();

    @panic("todo");
    // Read events until we get the sync callback done
    //     var got_sync = false;
    //     while (!got_sync) {
    //         const msg = try conn.readMessage() orelse continue;
    //         log.debug("recv: object={}, opcode={}, size={}", .{ msg.header.object_id, msg.header.opcode(), msg.header.size() });

    //         if (msg.header.object_id == conn.registry_id.? and msg.header.opcode() == WL_REGISTRY_GLOBAL) {
    //             try handleRegistryGlobal(&conn, msg.payload);
    //         } else if (msg.header.object_id == sync_callback and msg.header.opcode() == WL_CALLBACK_DONE) {
    //             got_sync = true;
    //         }
    //     }

    //     // Bind to required globals
    //     try bindGlobals(&conn);
    //     try conn.flush();

    //     if (conn.compositor_id == null) {
    //         log.err("wl_compositor not available", .{});
    //         return error.MissingGlobal;
    //     }
    //     if (conn.xdg_wm_base_id == null) {
    //         log.err("xdg_wm_base not available", .{});
    //         return error.MissingGlobal;
    //     }

    //     log.info("Wayland globals bound, entering main loop", .{});
    //     global.running = true;

    //     // Main event loop
    //     while (global.running) {
    //         try conn.flush();

    //         const msg = try conn.readMessage() orelse {
    //             // No message available, could do idle work here
    //             std.time.sleep(10 * std.time.ns_per_ms);
    //             continue;
    //         };

    //         // Handle ping/pong for xdg_wm_base
    //         if (msg.header.object_id == conn.xdg_wm_base_id.? and msg.header.opcode() == XDG_WM_BASE_PING) {
    //             const serial = std.mem.readInt(u32, msg.payload[0..4], .little);
    //             try sendPong(&conn, serial);
    //             log.debug("responded to xdg_wm_base ping serial={}", .{serial});
    //         }

    //         // TODO: Handle other events (surface configure, toplevel close, etc.)
    //     }
}

pub fn quitMainLoop() void {
    global.running = false;
}
