const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin.zig");

pub const x11 = @import("x11");
pub const win32 = switch (builtin.os.tag) {
    .windows => @import("win32").everything,
    else => struct {},
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
                    const oom_msg = "allocate error message failed";
                    const msg_z: [:0]const u8 = std.fmt.allocPrintSentinel(
                        arena.allocator(),
                        "{s}",
                        .{msg},
                        0,
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
// 2 ids for pixmaps (double-buffered via present extension)
// 1 id for the present event
const FixedWindowObject = enum {
    window,
    graphics_context,
    pixmap_0,
    pixmap_1,
    present_event,
};
const fixed_ids_per_window: comptime_int = @typeInfo(FixedWindowObject).@"enum".field_names.len;

pub const Connection = struct {
    sink: x11.RequestSink,
    source: x11.Source,
    id_range: x11.IdRange,
    depth: x11.Depth,
    keycode_range: if (support_key_events) x11.KeycodeRange else void,

    dpi_scale: ?DpiScale,
    keymap: if (support_key_events) ?x11.keymap.Full else void,
    present_opcode_base: ?u8 = null,
    /// The window manager's protocol for asking a window to close: windows
    /// list WM_DELETE_WINDOW in their WM_PROTOCOLS, and get a ClientMessage
    /// with it instead of being killed.
    wm_protocols: ?x11.Atom = null,
    wm_delete_window: ?x11.Atom = null,
    setup_sequences: std.EnumArray(SetupRequest, ?u16),

    // TODO: we'll need some better mechanism for ids so we can't run out
    next_id_offset: u32 = 0,

    dpi_get_property_sequence: ?u16 = null,

    status: enum {
        running,
        /// A write failed. Functions that can't return it, like show, leave
        /// it here for mainLoop to return.
        write_failed,
        /// quitMainLoop shut the socket down, zin doesn't write anymore.
        quit_requested,
        /// mainLoop or finishSetup returned an error, the app must disconnect.
        error_returned,
    } = .running,

    pub fn isSetupDone(conn: *const Connection) bool {
        for (conn.setup_sequences.values) |seq| if (seq != null) return false;
        return conn.dpi_scale != null;
    }
    fn setupRequestFromSequence(conn: *const Connection, sequence: u16) ?SetupRequest {
        for (conn.setup_sequences.values, 0..) |seq, index| {
            if (seq == sequence) return std.enums.EnumIndexer(SetupRequest).keyForIndex(index);
        }
        return null;
    }

    /// Whether zin sends requests: error.WriteFailed once a write failed
    /// or the app was given an error, false once the app quit.
    pub fn canWrite(conn: *const Connection) error{WriteFailed}!bool {
        return switch (conn.status) {
            .running => true,
            .quit_requested => false,
            .write_failed, .error_returned => error.WriteFailed,
        };
    }
    pub fn setWriteError(conn: *Connection, e: error{WriteFailed}) void {
        switch (e) {
            error.WriteFailed => {},
        }
        std.debug.assert(conn.status == .running);
        conn.status = .write_failed;
        log.err("write to X11 socket failed with {t}", .{global.i.socket_writer.err.?});
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
        const off = self.id_range.offset(@fromBackingInt(@intCast(@backingInt(window)))) orelse return null;
        if (off >= static_window_count * fixed_ids_per_window) return null;
        if (off % fixed_ids_per_window != @backingInt(FixedWindowObject.window)) return null;
        return @fromBackingInt(@intCast(@divTrunc(off, fixed_ids_per_window)));
    }
    fn staticWindowFromResource(self: *const Connection, id: u32) ?zin.StaticWindowId {
        const off = self.id_range.offset(@fromBackingInt(@intCast(id))) orelse return null;
        if (off >= static_window_count * fixed_ids_per_window) return null;
        return @fromBackingInt(@intCast(@divTrunc(off, fixed_ids_per_window)));
    }
    fn drawableFromX11Id(self: *const Connection, id: u32) union(enum) {
        not_drawable,
        static_window: zin.StaticWindowId,
        static_pixmap: zin.StaticWindowId,
    } {
        const off = self.id_range.offset(@fromBackingInt(@intCast(id))) orelse return .not_drawable;
        if (off >= static_window_count * fixed_ids_per_window) return .not_drawable;
        return switch (@as(FixedWindowObject, @fromBackingInt(@intCast(off % fixed_ids_per_window)))) {
            .window => .{ .static_window = @fromBackingInt(@intCast(@divTrunc(off, fixed_ids_per_window))) },
            .graphics_context => .not_drawable,
            .pixmap_0, .pixmap_1 => .{ .static_pixmap = @fromBackingInt(@intCast(@divTrunc(off, fixed_ids_per_window))) },
            .present_event => .not_drawable,
        };
    }

    pub fn staticWindowId(self: *const Connection, id: zin.StaticWindowId) x11.Window {
        return self.id_range.addAssumeCapacity(@as(u29, @backingInt(id)) * fixed_ids_per_window + @backingInt(FixedWindowObject.window)).window();
    }
    pub fn staticWindowGc(self: *const Connection, id: zin.StaticWindowId) x11.GraphicsContext {
        return self.id_range.addAssumeCapacity(@as(u29, @backingInt(id)) * fixed_ids_per_window + @backingInt(FixedWindowObject.graphics_context)).graphicsContext();
    }
    pub fn staticWindowPixmaps(self: *const Connection, id: zin.StaticWindowId) [2]x11.Pixmap {
        return .{
            self.id_range.addAssumeCapacity(@as(u29, @backingInt(id)) * fixed_ids_per_window + @backingInt(FixedWindowObject.pixmap_0)).pixmap(),
            self.id_range.addAssumeCapacity(@as(u29, @backingInt(id)) * fixed_ids_per_window + @backingInt(FixedWindowObject.pixmap_1)).pixmap(),
        };
    }
    pub fn staticWindowPresentEventId(self: *const Connection, id: zin.StaticWindowId) u32 {
        return @backingInt(self.id_range.addAssumeCapacity(@as(u29, @backingInt(id)) * fixed_ids_per_window + @backingInt(FixedWindowObject.present_event)));
    }

    pub fn reserveId(self: *Connection) ?x11.Resource {
        const resource = self.id_range.add(@intCast(static_window_count * fixed_ids_per_window + self.next_id_offset)) orelse return null;
        self.next_id_offset += 1;
        return resource;
    }
    fn releaseId(self: *Connection, id: x11.Resource) void {
        const off = self.id_range.offset(id) orelse @panic("releaseId: id not in range");
        const dynamic_offset = off - static_window_count * fixed_ids_per_window;
        if (self.next_id_offset == dynamic_offset + 1) {
            self.next_id_offset = @intCast(dynamic_offset);
        } else {
            @panic("todo");
        }
    }
};

pub fn processInit(opt: zin.ProcessInitOptions) zin.ProcessInitError!void {
    _ = opt;
    global.process_init_check.onProcessInit();
}
pub const ThreadInitError = struct {
    pub fn format(err: ThreadInitError, writer: *std.Io.Writer) error{WriteFailed}!void {
        _ = err;
        _ = writer;
        unreachable;
    }
};

pub fn threadInit(id: zin.ThreadId) ?ThreadInitError {
    global.process_init_check.enforce();
    global.thread_init_checks[@backingInt(id)].onThreadInit(id);
    return null;
}
pub fn threadDeinit(id: zin.ThreadId) void {
    global.thread_init_checks[@backingInt(id)].onThreadDeinit(id);
}
/// Panics with runtime safety unless called on the thread that called
/// threadInit with `id`.
pub fn enforceThread(id: zin.ThreadId) void {
    global.thread_init_checks[@backingInt(id)].enforce(id);
}

pub const ConnectError = union(enum) {
    connect_error: x11.ConnectError,
    bad_display,
    recv_error: (error{EndOfStream} || std.Io.net.Stream.Reader.Error),
    send_error: std.Io.net.Stream.Writer.Error,
    protocol_error: enum { setup, setup_dynamic, depth, id_range, id_range_capacity, keycode_range },
    cant_authenticate,
    no_screen,

    fn set(err: *ConnectError, value: ConnectError) error{X11Connect} {
        err.* = value;
        return error.X11Connect;
    }

    fn setRecv(err: *ConnectError, recv_err: error{ ReadFailed, EndOfStream }) error{X11Connect} {
        return err.set(.{ .recv_error = switch (recv_err) {
            error.ReadFailed => global.i.socket_reader.err.?,
            error.EndOfStream => error.EndOfStream,
        } });
    }

    pub fn format(err: ConnectError, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (err) {
            .bad_display => try writer.writeAll("bad DISPLAY"),
            .connect_error => |e| try writer.print("socket connect failed with {s}", .{@errorName(e)}),
            .recv_error => |e| try writer.print("socket receive failed with {s}", .{@errorName(e)}),
            .send_error => |e| try writer.print("socket send failed with {s}", .{@errorName(e)}),
            .protocol_error => |e| try writer.print("server protocol error: {s}", .{@tagName(e)}),
            .cant_authenticate => try writer.writeAll("failed to authenticate"),
            .no_screen => try writer.writeAll("server reported no screens"),
        }
    }
};
pub fn connect(thread: zin.ThreadId, io: std.Io, environ: std.process.Environ, out_err: *ConnectError) error{X11Connect}!void {
    enforceThread(thread);
    std.debug.assert(global.conn == null);
    errdefer {
        std.debug.assert(global.conn == null);
        global.i.socket_writer = undefined;
        global.i.screen = undefined;
        global.i.setup = undefined;
        global.i.socket_reader = undefined;
    }

    var display_buf: [x11.max_display_len]u8 = undefined;
    const display = x11.getDisplay(.init(environ), &display_buf) catch |err| {
        log.err("get X11 DISPLAY failed with {t}", .{err});
        return out_err.set(.bad_display);
    };
    log.info("X11 DISPLAY {f}", .{display});
    const parsed_display = x11.parseDisplay(display) catch |err| {
        log.err("invalid X11 DISPLAY {f}: {t}", .{ display, err });
        return out_err.set(.bad_display);
    };
    const host = x11.getHost(display, &parsed_display) catch {
        log.err("invalid X11 DISPLAY {f}", .{display});
        return out_err.set(.bad_display);
    };

    global.i.socket_reader, global.use_auth = blk: {
        const address, const initial_stream = x11.connect(io, &host) catch |err| {
            return out_err.set(.{ .connect_error = err });
        };
        errdefer x11.disconnect(io, initial_stream);
        log.info("connected to {f}", .{address});
        break :blk x11.draft.authenticate(
            io,
            .init(environ),
            display,
            &parsed_display,
            &host,
            &address,
            initial_stream,
            &global.read_buffer,
            .{ .order = if (global.use_auth) .auth_first else .no_auth_first },
        ) catch |err| switch (err) {
            error.AuthRejected => return out_err.set(.cant_authenticate),
        };
    };
    errdefer x11.disconnect(io, global.i.socket_reader.stream);

    global.i.setup = x11.readSetupSuccess(&global.i.socket_reader.interface) catch |err| switch (err) {
        error.Protocol => return out_err.set(.{ .protocol_error = .setup }),
        error.ReadFailed, error.EndOfStream => |e| return out_err.setRecv(e),
    };
    std.log.info("setup reply {f}", .{global.i.setup});
    var source: x11.Source = .initFinishSetup(&global.i.socket_reader.interface, &global.i.setup);

    var on_visual_adapter: x11.draft.OnVisual = if (zin.config.x11_on_visual) |f|
        .{ .func = struct {
            fn cb(_: *x11.draft.OnVisual, si: u8, d: u8, vi: u16, v: *const x11.VisualType) void {
                f(si, d, vi, v);
            }
        }.cb }
    else
        undefined;

    global.i.screen = (x11.draft.readSetupDynamic(&source, &global.i.setup, .{
        .on_visual = if (zin.config.x11_on_visual != null) &on_visual_adapter else null,
    }) catch |err| switch (err) {
        error.Protocol => return out_err.set(.{ .protocol_error = .setup_dynamic }),
        error.ReadFailed, error.EndOfStream => |e| return out_err.setRecv(e),
    }) orelse return out_err.set(.no_screen);
    global.i.socket_writer = global.i.socket_reader.stream.writer(io, &global.write_buffer);
    var sink: x11.RequestSink = .{ .writer = &global.i.socket_writer.interface };

    const id_range = x11.IdRange.init(global.i.setup.resource_id_base, global.i.setup.resource_id_mask) catch
        return out_err.set(.{ .protocol_error = .id_range });
    const needed_ids = static_window_count * fixed_ids_per_window;
    if (id_range.capacity() < needed_ids) {
        log.err("X server id range capacity {} is less than needed {}", .{ id_range.capacity(), needed_ids });
        return out_err.set(.{ .protocol_error = .id_range_capacity });
    }

    const depth = x11.Depth.init(global.i.screen.root_depth) orelse {
        log.err("unsupported screen depth {}", .{global.i.screen.root_depth});
        return out_err.set(.{ .protocol_error = .depth });
    };

    const keycode_range = if (support_key_events) x11.KeycodeRange.init(
        global.i.setup.min_keycode,
        global.i.setup.max_keycode,
    ) catch |err| switch (err) {
        error.Protocol => return out_err.set(.{ .protocol_error = .keycode_range }),
    } else {};

    // don't wait on replies here, over a remote connection each one is a round trip
    var setup_sequences: std.EnumArray(SetupRequest, ?u16) = .initFill(null);
    const dpi_get_property_sequence = writeFlushConnectRequests(&sink, keycode_range, &setup_sequences) catch
        return out_err.set(.{ .send_error = global.i.socket_writer.err.? });

    global.conn = .{
        .sink = sink,
        .source = source,
        .id_range = id_range,
        .depth = depth,
        .keycode_range = keycode_range,
        .dpi_scale = if (support_dpi_events) null else .{ .val = {} },
        .keymap = if (support_key_events) null else {},
        .setup_sequences = setup_sequences,
        .dpi_get_property_sequence = dpi_get_property_sequence,
    };
    global.onConnected();
}

const SetupRequest = enum {
    present_extension,
    wm_protocols_atom,
    wm_delete_window_atom,
    keymap,
};

/// Writes and flushes the setup requests, returns the DPI GetProperty's sequence.
fn writeFlushConnectRequests(
    sink: *x11.RequestSink,
    keycode_range: if (support_key_events) x11.KeycodeRange else void,
    sequences: *std.EnumArray(SetupRequest, ?u16),
) error{WriteFailed}!?u16 {
    try sink.QueryExtension(x11.present.name);
    sequences.set(.present_extension, sink.sequence);
    try sink.InternAtom(.{ .only_if_exists = false, .name = .initComptime("WM_PROTOCOLS") });
    sequences.set(.wm_protocols_atom, sink.sequence);
    try sink.InternAtom(.{ .only_if_exists = false, .name = .initComptime("WM_DELETE_WINDOW") });
    sequences.set(.wm_delete_window_atom, sink.sequence);
    if (support_key_events) {
        try sink.GetKeyboardMapping(keycode_range.min, keycode_range.count());
        sequences.set(.keymap, sink.sequence);
    }
    const dpi_get_property_sequence: ?u16 = blk: {
        if (!support_dpi_events) break :blk null;
        // Select PropertyChange events on the root window so we get PropertyNotify
        // when RESOURCE_MANAGER changes (e.g. via xrdb).
        try sink.ChangeWindowAttributes(global.i.screen.root, .{
            .event_mask = .{ .PropertyChange = 1 },
        });
        break :blk try sendDpiGetProperty(sink);
    };
    try sink.writer.flush();
    return dpi_get_property_sequence;
}

fn handleSetupReply(
    source: *x11.Source,
    reply: x11.servermsg.Reply,
    request: SetupRequest,
) !void {
    const conn = &global.conn.?;
    std.debug.assert(conn.setup_sequences.get(request) == reply.sequence);
    conn.setup_sequences.set(request, null);
    switch (request) {
        .present_extension => {
            const ext_reply, _ = try source.readReplyFull(reply, .QueryExtension);
            const ext = try x11.Extension.init(ext_reply) orelse {
                log.err("X server doesn't have the {s} extension, which zin requires", .{x11.present.name.nativeSlice()});
                return error.X11PresentNotAvailable;
            };
            log.info("extension '{s}': {}", .{ x11.present.name.nativeSlice(), ext });
            conn.present_opcode_base = ext.opcode_base;
        },
        .wm_protocols_atom => {
            const atom_reply, _ = try source.readReplyFull(reply, .InternAtom);
            conn.wm_protocols = atom_reply.atom;
        },
        .wm_delete_window_atom => {
            const atom_reply, _ = try source.readReplyFull(reply, .InternAtom);
            conn.wm_delete_window = atom_reply.atom;
        },
        .keymap => if (support_key_events) {
            conn.keymap = try readKeymapReply(source, reply);
        } else unreachable,
    }
    try onSetupProgress();
}

fn readKeymapReply(source: *x11.Source, reply: x11.servermsg.Reply) !x11.keymap.Full {
    const keyrange = global.conn.?.keycode_range;
    const keysyms_per_keycode = reply.flexible;
    try source.replyDiscard(24);
    const expected_size = @as(u35, keyrange.count()) * @as(u35, keysyms_per_keycode) * 4;
    const remaining_size = source.replyRemainingSize();
    if (remaining_size != expected_size) {
        log.err("expected GetKeyboardMapping reply to be {} bytes but got {}", .{ expected_size, remaining_size });
        try source.discardRemaining();
        return error.X11UnexpectedMessage;
    }
    var keymap: x11.keymap.Full = .initVoid();
    for (keyrange.min..@as(usize, keyrange.max) + 1) |keycode| {
        for (0..keysyms_per_keycode) |index| {
            const keysym_u32 = try source.takeReplyInt(u32);
            if (index < 4) {
                keymap.array[keycode - 8][index] = @fromBackingInt(@intCast(@as(u16, @truncate(keysym_u32))));
            }
        }
    }
    std.debug.assert(source.replyRemainingSize() == 0);
    return keymap;
}

fn onSetupProgress() error{WriteFailed}!void {
    if (!global.conn.?.isSetupDone()) return;
    log.debug("X11 setup done", .{});
    try writeQueuedWindows();
}

/// in the order the app did things
fn writeQueuedWindows() error{WriteFailed}!void {
    const Op = struct {
        order: u32,
        window_id: zin.StaticWindowId,
        kind: enum { create, show, foreground },
        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.order < b.order;
        }
    };
    var ops: [static_window_count * 3]Op = undefined;
    var op_count: usize = 0;
    for (&global.static_window_states, 0..) |*state, index| switch (state.*) {
        .not_created, .created, .server_destroyed, .destroyed => {},
        .queued => |*queued| {
            const window_id: zin.StaticWindowId = @fromBackingInt(@intCast(index));
            ops[op_count] = .{ .order = queued.create_order, .window_id = window_id, .kind = .create };
            op_count += 1;
            if (queued.show_order) |order| {
                ops[op_count] = .{ .order = order, .window_id = window_id, .kind = .show };
                op_count += 1;
            }
            if (queued.foreground_order) |order| {
                ops[op_count] = .{ .order = order, .window_id = window_id, .kind = .foreground };
                op_count += 1;
            }
        },
    };
    std.sort.insertion(Op, ops[0..op_count], {}, Op.lessThan);
    var replayed: [static_window_count]bool = @splat(false);
    for (ops[0..op_count]) |op| replayed[@backingInt(op.window_id)] = true;
    for (ops[0..op_count]) |op| switch (op.window_id) {
        inline else => |window_id| switch (op.kind) {
            .create => {
                const queued = global.static_window_states[@backingInt(window_id)].queued;
                try staticWindow(window_id).writeCreate(queued.size, queued.pos, &queued.platform, queued.damaged);
            },
            .show => try staticWindow(window_id).window().writeMap(),
            .foreground => try staticWindow(window_id).window().writeRaise(),
        },
    };
    // after every queued request is written, the app can call back into zin
    inline for (comptime std.meta.tags(zin.StaticWindowId)) |window_id| {
        if (comptime window_id.getConfig().window_size_events) {
            if (replayed[@backingInt(window_id)]) switch (global.static_window_states[@backingInt(window_id)]) {
                .created => staticCallback(window_id)(.created),
                // the app destroyed it in an earlier window's .created
                .destroyed => {},
                .not_created, .queued, .server_destroyed => unreachable,
            };
        }
    }
}

/// Waits for the replies to the requests connect sent, and sends the
/// requests for the windows the app created meanwhile.
pub fn finishSetup() !void {
    const conn = &global.conn.?;
    if (conn.status == .error_returned) @panic("the X11 connection failed, the app must disconnect");
    if (conn.isSetupDone()) return;
    // the socket is shut down, zin won't write anything that needs setup
    if (conn.status == .quit_requested) return;
    errdefer conn.status = .error_returned;
    if (try conn.canWrite()) conn.sink.writer.flush() catch |e| return conn.teeWriteError(e);
    while (!conn.isSetupDone()) {
        const msg_kind = conn.source.readKind() catch |err| switch (err) {
            error.EndOfStream => {
                log.err("X11 connection closed before setup was done", .{});
                return error.X11ConnectionClosed;
            },
            error.ReadFailed => return global.i.socket_reader.err.?,
        };
        try x11HandleMessage(&conn.source, msg_kind);
    }
}
pub fn disconnect(thread: zin.ThreadId) void {
    enforceThread(thread);
    std.debug.assert(global.conn != null);
    for (global.static_window_states, 0..) |state, index| switch (state) {
        .not_created, .destroyed => {},
        .queued, .created, .server_destroyed => std.debug.panic(
            "disconnect called while window {t} exists",
            .{@as(zin.StaticWindowId, @fromBackingInt(@intCast(index)))},
        ),
    };
    global.onDisconnect();
    global.conn.? = undefined;
    global.conn = null;

    x11.disconnect(global.i.socket_reader.io, global.i.socket_reader.stream);

    global.i.socket_writer = undefined;
    global.i.screen = undefined;
    global.i.setup = undefined;
    global.i.socket_reader = undefined;
}

const xft_dpi_prefix = "Xft.dpi:";

/// The longest Xft.dpi line accepted, after the whitespace that's skipped,
/// a power of 2 minus 1 so XftDpiIndex uses all its bits.
const max_xft_dpi_line_len = 63;
/// Outside these zin's window sizes overflow or round to 0, real ones are
/// 72 to 288.
const min_xft_dpi = 24;
const max_xft_dpi = 960;
const XftDpiIndex = std.math.IntFittingRange(0, max_xft_dpi_line_len);

const XftDpiResult = union(enum) {
    ok: f32,
    err: XftDpiError,
};
const XftDpiError = union(enum) {
    not_found,
    /// the line didn't fit in the line buffer, this is its start
    too_long: XftDpiText,
    not_a_number: XftDpiText,
    out_of_range: XftDpiText,

    /// `line_buf` is the one readXftDpi got
    fn fmt(err: XftDpiError, line_buf: []const u8) Fmt {
        return .{ .err = err, .line_buf = line_buf };
    }
    const Fmt = struct {
        err: XftDpiError,
        line_buf: []const u8,
        pub fn format(f: Fmt, writer: *std.Io.Writer) error{WriteFailed}!void {
            switch (f.err) {
                .not_found => try writer.writeAll("not found"),
                .too_long => |text| try writer.print(
                    "its line is longer than {} bytes: '{f}...'",
                    .{ max_xft_dpi_line_len, std.zig.fmtString(f.line_buf[text.start..text.limit]) },
                ),
                .not_a_number => |text| try writer.print("'{f}' isn't a number", .{std.zig.fmtString(f.line_buf[text.start..text.limit])}),
                .out_of_range => |text| try writer.print(
                    "'{f}' isn't between {} and {}",
                    .{ std.zig.fmtString(f.line_buf[text.start..text.limit]), min_xft_dpi, max_xft_dpi },
                ),
            }
        }
    };
};
const XftDpiText = struct { start: XftDpiIndex, limit: XftDpiIndex };

/// Reads a resource database value of `len` bytes up to its Xft.dpi line,
/// keeping only the current line, so the value can be bigger than the read
/// buffer. The caller discards the rest of the reply.
fn readXftDpi(
    source: *x11.Source,
    len: u35,
    line_buf: *[max_xft_dpi_line_len]u8,
) error{ ReadFailed, EndOfStream }!XftDpiResult {
    var line_len: XftDpiIndex = 0;
    var line_overflow = false;
    var remaining = len;
    while (remaining > 0) {
        const chunk = try source.takeReply(@min(remaining, source.reader.buffer.len));
        remaining -= @intCast(chunk.len);
        for (chunk) |c| {
            if (c == '\n') {
                if (parseXftDpiLine(line_buf[0..line_len], line_overflow)) |result| return result;
                line_len = 0;
                line_overflow = false;
            } else if ((c == ' ' or c == '\t') and (line_len == 0 or line_len == xft_dpi_prefix.len)) {
                // whitespace before the name or the value, not stored so it
                // doesn't count against the line buffer
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = c;
                line_len += 1;
            } else {
                line_overflow = true;
            }
        }
    }
    // the last line may not end with a newline
    if (line_len > 0) if (parseXftDpiLine(line_buf[0..line_len], line_overflow)) |result| return result;
    return .{ .err = .not_found };
}

/// null if it isn't the Xft.dpi line, `overflow` means it didn't fit in `line`
fn parseXftDpiLine(line: []const u8, overflow: bool) ?XftDpiResult {
    if (!std.mem.startsWith(u8, line, xft_dpi_prefix)) return null;
    if (overflow) return .{ .err = .{ .too_long = .{ .start = 0, .limit = @intCast(line.len) } } };
    const value_str = std.mem.trimEnd(u8, line[xft_dpi_prefix.len..], " \t\r\x00");
    const value: XftDpiText = .{ .start = xft_dpi_prefix.len, .limit = @intCast(xft_dpi_prefix.len + value_str.len) };
    const dpi = std.fmt.parseFloat(f32, value_str) catch |err| switch (err) {
        error.InvalidCharacter => return .{ .err = .{ .not_a_number = value } },
    };
    if (!(dpi >= min_xft_dpi and dpi <= max_xft_dpi)) return .{ .err = .{ .out_of_range = value } };
    return .{ .ok = dpi };
}

/// Reads the whole GetProperty reply for RESOURCE_MANAGER and parses Xft.dpi
/// from it. Returns the DPI scale factor, or null if Xft.dpi was not
/// found/parseable.
fn readDpiFromPropertyReply(source: *x11.Source, value_format: u8) error{ ReadFailed, EndOfStream, Protocol }!?f32 {
    const prop_header = try source.read3Header(.GetProperty);
    const result: ?f32 = blk: {
        if (value_format != 8) {
            log.err("Xft.dpi unexpected format {}", .{value_format});
            break :blk null;
        }
        if (prop_header.value_size_in_format_units == 0) {
            log.err("Xft.dpi value size is 0", .{});
            break :blk null;
        }
        if (prop_header.value_size_in_format_units > source.replyRemainingSize()) {
            log.err(
                "RESOURCE_MANAGER value is {} bytes but the reply only has {}",
                .{ prop_header.value_size_in_format_units, source.replyRemainingSize() },
            );
            return error.Protocol;
        }
        var line_buf: [max_xft_dpi_line_len]u8 = undefined;
        const xft_dpi = switch (try readXftDpi(source, prop_header.value_size_in_format_units, &line_buf)) {
            .ok => |dpi| dpi,
            .err => |err| {
                log.err("can't use Xft.dpi from RESOURCE_MANAGER: {f}", .{err.fmt(&line_buf)});
                break :blk null;
            },
        };
        const scale = xft_dpi / 96.0;
        log.debug("Xft.dpi={d:.2} scale={d:.2}", .{ xft_dpi, scale });
        break :blk scale;
    };
    try source.discardRemaining();
    return result;
}

fn sendDpiGetProperty(sink: *x11.RequestSink) error{WriteFailed}!u16 {
    try sink.GetProperty(global.i.screen.root, .{
        .property = .RESOURCE_MANAGER,
        .type = .STRING,
        .offset = 0,
        .len = 1024 * 1024, // up to 4MB
        .delete = false,
    });
    return sink.sequence;
}

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: this shouldn't be hardcoded, instead, it should be based on the app config
const support_key_events = true;

const support_dpi_events: bool = blk: {
    for (0..@typeInfo(zin.StaticWindowId).@"enum".field_names.len) |window_id_int| {
        const id: zin.StaticWindowId = @fromBackingInt(@intCast(window_id_int));
        if (id.getConfig().dpi_events) break :blk true;
    }
    break :blk false;
};
const DpiScale = struct {
    val: if (support_dpi_events) f32 else void,
    pub fn scale(d: DpiScale, comptime T: type, value: T) T {
        return if (support_dpi_events) zin.scale(T, value, d.val) else value;
    }
};

pub const WindowConfig = struct {};

pub const WindowClass = struct {
    callback: *const anyopaque,
    pub fn unregister(self: WindowClass) void {
        _ = self;
    }
};

const Window = struct {
    id: x11.Window,
    callback: *const anyopaque,

    pub fn destroy(self: Window) void {
        var msg: [x11.destroy_window.len]u8 = undefined;
        x11.destroy_window.serialize(&msg, self.id);
        global.connection.sendOneOrPanic(&msg);
    }
    fn writeMap(self: Window) error{WriteFailed}!void {
        if (!try global.conn.?.canWrite()) return;
        global.conn.?.sink.MapWindow(self.id) catch |e| return global.conn.?.teeWriteError(e);
    }
    fn writeUnmap(self: Window) error{WriteFailed}!void {
        if (!try global.conn.?.canWrite()) return;
        global.conn.?.sink.UnmapWindow(self.id) catch |e| return global.conn.?.teeWriteError(e);
    }
    /// Raises the window to the top of the stack. It doesn't take the input
    /// focus, which is left to the window manager.
    fn writeRaise(self: Window) error{WriteFailed}!void {
        if (!try global.conn.?.canWrite()) return;
        global.conn.?.sink.ConfigureWindow(self.id, .{ .stack_mode = .above }) catch |e| return global.conn.?.teeWriteError(e);
    }
};

const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".field_names.len;

pub const min_timer_id_int = 0;

pub const global = struct {
    var process_init_check: zin.ProcessInitCheck = .{};
    var thread_init_checks: [@typeInfo(zin.ThreadId).@"enum".field_names.len]zin.ThreadInitCheck = @splat(.{});
    var use_auth: bool = true;
    var write_buffer: [zin.config.x11_write_buffer_size]u8 = undefined;
    var read_buffer: [zin.config.x11_read_buffer_size]u8 = undefined;

    pub var conn: ?Connection = null;
    // all decls in the i namespace are guaranteed to be initialized while conn
    // is not null (after a successfull call to connect).
    pub const i = struct {
        pub var socket_reader: std.Io.net.Stream.Reader = undefined;
        pub var setup: x11.Setup = undefined;
        pub var screen: x11.ScreenHeader = undefined;
        pub var socket_writer: std.Io.net.Stream.Writer = undefined;
    };

    var static_callbacks: [static_window_count]?*const anyopaque = @splat(null);
    var static_window_states: [static_window_count]WindowState = @splat(.not_created);
    /// Set when a window is destroyed, to the last request sent then.
    /// Errors for the window's ids up to it are races, including after the
    /// app creates the window again.
    var race_errors_through: [static_window_count]?u16 = @splat(null);
    var next_queue_order: u32 = 0;
    var static_window_custom_states: StaticWindowCustomStates = .{};

    pub fn staticWindowCustomState(comptime window_id: zin.StaticWindowId) *StaticWindowCustomState(window_id) {
        return &@field(static_window_custom_states, @tagName(window_id));
    }
    pub fn onConnected() void {
        static_window_states = @splat(.not_created);
        race_errors_through = @splat(null);
        next_queue_order = 0;
        inline for (0..static_window_count) |window_id_int| {
            const state = staticWindowCustomState(@fromBackingInt(@intCast(window_id_int)));
            state.onConnected();
        }
    }
    pub fn onDisconnect() void {
        static_window_states = @splat(.not_created);
        race_errors_through = @splat(null);
        inline for (0..static_window_count) |window_id_int| {
            const state = staticWindowCustomState(@fromBackingInt(@intCast(window_id_int)));
            state.onDisconnect();
        }
    }
};

fn timerCount(comptime TimerId: type) usize {
    return switch (@typeInfo(TimerId)) {
        .noreturn => 0,
        .void => 1,
        .@"enum" => |info| info.field_names.len,
        .int => @compileError("todo"),
        else => @compileError("unsupported TimerId type: " ++ @typeName(TimerId)),
    };
}

/// The app has the window while it's queued, created or server_destroyed.
/// The server only has it while it's created.
///
/// A window the app destroys stays destroyed until the app disconnects:
/// events for it can still be in flight, and its X11 ids are never reused.
/// A window something else destroys goes back to not_created once the app
/// is told, and the app can create it again. zin got its DestroyNotify by
/// then, the last event the server sends for it, so only errors for
/// requests zin sent earlier can still arrive, see race_errors_through.
const WindowState = union(enum) {
    not_created,
    queued: QueuedWindow,
    created: CreatedWindow,
    /// something else destroyed it and the app doesn't have destroyed_events
    server_destroyed,
    destroyed,
};
const QueuedWindow = struct {
    size: zin.WindowSizeInit,
    pos: ?zin.XY(i32),
    platform: CreateWindowOptions,
    damaged: bool = false,
    create_order: u32,
    show_order: ?u32 = null,
    foreground_order: ?u32 = null,
};
const CreatedWindow = struct {
    size: zin.XY(i32),
    damaged: bool,
    presenter: ?x11.Presenter = null,
};

fn nextQueueOrder() u32 {
    defer global.next_queue_order += 1;
    return global.next_queue_order;
}

fn eventWindow(window: x11.Window) ?zin.StaticWindowId {
    const window_id = global.conn.?.staticWindowFromX11Id(window) orelse {
        log.debug("ignoring X11 event for window {} zin did not create", .{@backingInt(window)});
        return null;
    };
    return switch (global.static_window_states[@backingInt(window_id)]) {
        .created => window_id,
        // events still in flight when the app destroyed it
        .destroyed => null,
        // nothing else can create a window with zin's ids, and the server
        // sends nothing for a window after its DestroyNotify
        .not_created, .queued, .server_destroyed => null,
    };
}

/// Whether request `a` was sent before request `b`. Sequences are 16 bits
/// and wrap, so both are measured back from the last request sent, which
/// is right while they're within 65536 requests of it.
fn sequenceBefore(a: u16, b: u16) bool {
    const last = global.conn.?.sink.sequence;
    return (last -% a) > (last -% b);
}

/// Forgets the race marks the server is past, before they're 65536
/// requests old.
fn onServerSequence(sequence: u16) void {
    for (&global.race_errors_through) |*race| {
        if (race.*) |through| {
            if (sequenceBefore(through, sequence)) race.* = null;
        }
    }
}

fn readEvent(source: *x11.Source, comptime category: x11.ServerMsgCategory) !@field(x11.servermsg, @tagName(category)) {
    const event = try source.read2(category);
    onServerSequence(event.sequence);
    return event;
}

/// Something other than the app destroyed the window.
fn onServerDestroyed(comptime window_id: zin.StaticWindowId) error{WriteFailed}!void {
    const created = global.static_window_states[@backingInt(window_id)].created;
    // the pixmaps may never have been created, so their frees can fail too
    try freeWindowResources(window_id, created.presenter != null);
    global.race_errors_through[@backingInt(window_id)] = global.conn.?.sink.sequence;
    if (window_id.getConfig().destroyed_events) {
        global.static_window_states[@backingInt(window_id)] = .not_created;
        global.staticWindowCustomState(window_id).onDestroyed();
        staticCallback(window_id)(.{ .destroyed = .external });
    } else {
        log.info("X11 window {t} was destroyed by another client (enable destroyed_events to be told)", .{window_id});
        global.static_window_states[@backingInt(window_id)] = .server_destroyed;
    }
}

/// Frees the resources zin creates with a window, which outlive it.
fn freeWindowResources(comptime window_id: zin.StaticWindowId, has_pixmaps: bool) error{WriteFailed}!void {
    const conn = &global.conn.?;
    if (!try conn.canWrite()) return;
    if (has_pixmaps) {
        for (conn.staticWindowPixmaps(window_id)) |pixmap| {
            conn.sink.FreePixmap(pixmap) catch |e| return conn.teeWriteError(e);
        }
    }
    conn.sink.FreeGc(gcFromWindow(conn.staticWindowId(window_id))) catch |e| return conn.teeWriteError(e);
}
fn StaticWindowCustomState(window_id: zin.StaticWindowId) type {
    return struct {
        client_size: if (window_id.getConfig().window_size_events)
            zin.XY(i32)
        else
            void = if (window_id.getConfig().window_size_events)
            .{ .x = 0, .y = 0 }
        else {},
        timers: [timer_count]?Timer = @splat(null),

        pub const timer_count = timerCount(window_id.getConfig().TimerId());

        const Self = @This();
        pub fn onConnected(self: *Self) void {
            self.* = .{};
        }
        pub fn onDisconnect(self: *Self) void {
            self.* = .{};
        }
        pub fn onDestroyed(self: *Self) void {
            self.* = .{};
        }
    };
}
const StaticWindowCustomStates = blk: {
    var types: [static_window_count]type = undefined;
    var attrs: [static_window_count]std.lang.Type.Struct.FieldAttributes = undefined;
    for (&types, &attrs, std.meta.tags(zin.StaticWindowId)) |*T, *attr, window_id| {
        T.* = StaticWindowCustomState(window_id);
        attr.* = .{ .default_value_ptr = &(StaticWindowCustomState(window_id){}) };
    }
    break :blk @Struct(.auto, null, std.meta.fieldNames(zin.StaticWindowId), &types, &attrs);
};

const StaticWindowAndTimerId = blk: {
    var types: [static_window_count]type = undefined;
    var attrs: [static_window_count]std.lang.Type.Union.FieldAttributes = undefined;
    for (&types, &attrs, std.meta.tags(zin.StaticWindowId)) |*T, *attr, window_id| {
        T.* = window_id.getConfig().TimerId();
        attr.* = .{ .@"align" = if (T.* == noreturn) 1 else null };
    }
    break :blk @Union(.auto, zin.StaticWindowId, std.meta.fieldNames(zin.StaticWindowId), &types, &attrs);
};

const Timer = struct {
    start: std.Io.Timestamp,
    duration_nanos: u64,
};

// The raw access functions call finishSetup first, so the requests the app
// sends itself on its windows reach the server after zin creates them.
// Requests must go through x11Sink, zin matches server messages to its
// requests by counting them.

/// Access the global x11 socket.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11Socket() !std.Io.net.Socket.Handle {
    std.debug.assert(global.conn != null);
    try finishSetup();
    return global.i.socket_reader.stream.socket.handle;
}
/// Access the global request sink.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11Sink() !*x11.RequestSink {
    std.debug.assert(global.conn != null);
    try finishSetup();
    return &global.conn.?.sink;
}
/// Access the global socket reader.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11SocketReader() !*std.Io.net.Stream.Reader {
    std.debug.assert(global.conn != null);
    try finishSetup();
    return &global.i.socket_reader;
}
/// Access the global x11 Source.
/// This should only be called while connected (after a successfull call to connect).
pub fn x11Source() !*x11.Source {
    std.debug.assert(global.conn != null);
    try finishSetup();
    return &global.conn.?.source;
}

fn staticCallback(comptime window_id: zin.StaticWindowId) *const fn (zin.Callback(window_id)) void {
    return @ptrCast(@alignCast(global.static_callbacks[@backingInt(window_id)].?));
}

pub fn staticWindow(window_id: zin.StaticWindowId) type {
    const config = window_id.getConfig();

    return struct {
        const Self = @This();

        fn window() Window {
            return .{
                .id = global.conn.?.staticWindowId(window_id),
                .callback = global.static_callbacks[@backingInt(window_id)].?,
            };
        }

        pub fn registerClass(
            comptime def: zin.WindowClassDefinition(window_id),
            runtime_config: zin.WindowClassRuntimeConfig,
        ) void {
            _ = runtime_config;
            std.debug.assert(global.static_callbacks[@backingInt(window_id)] == null);
            global.static_callbacks[@backingInt(window_id)] = @ptrCast(def.callback);
        }
        pub fn unregisterClass() void {
            std.debug.assert(global.static_callbacks[@backingInt(window_id)] != null);
            switch (state().*) {
                .not_created, .destroyed => {},
                .queued, .created, .server_destroyed => @panic("unregisterClass called while its window exists"),
            }
            global.static_callbacks[@backingInt(window_id)] = null;
        }
        fn state() *WindowState {
            return &global.static_window_states[@backingInt(window_id)];
        }
        fn panicIfErrorReturned() void {
            if (global.conn.?.status == .error_returned) @panic("the X11 connection failed, the app must disconnect");
        }
        fn panicIfAppDoesntHave(comptime api: []const u8) void {
            switch (state().*) {
                .not_created => @panic(api ++ " called on a window that's not created"),
                .destroyed => @panic(api ++ " called on a window that was destroyed"),
                .queued, .created, .server_destroyed => {},
            }
        }
        pub fn create(opt: zin.CreateWindowOptions) zin.CreateWindowError!void {
            panicIfErrorReturned();
            if (global.static_callbacks[@backingInt(window_id)] == null) @panic("create called before registerClass");
            switch (state().*) {
                .not_created => {},
                .queued, .created, .server_destroyed => @panic("create called on a window that's already created"),
                .destroyed => @panic("create called on a window the app destroyed, hide windows to show them again"),
            }
            _ = try global.conn.?.canWrite();
            // the window's size depends on the DPI, .created comes once zin knows it
            if (!global.conn.?.isSetupDone()) {
                state().* = .{ .queued = .{
                    .size = opt.size,
                    .pos = opt.pos,
                    .platform = opt.platform,
                    .create_order = nextQueueOrder(),
                } };
                return;
            }
            try writeCreate(opt.size, opt.pos, &opt.platform, false);
            if (comptime window_id.getConfig().window_size_events) staticCallback(window_id)(.created);
        }
        fn writeCreate(
            size_init: zin.WindowSizeInit,
            pos: ?zin.XY(i32),
            platform: *const CreateWindowOptions,
            damaged: bool,
        ) error{WriteFailed}!void {
            const bg = global.conn.?.x11FromRgb(config.background);
            const size = windowPixelSizeFromInit(size_init, global.conn.?.dpi_scale.?);
            try createWindow(&config, size, pos, bg, global.conn.?.staticWindowId(window_id), platform);
            state().* = .{ .created = .{ .size = size, .damaged = damaged } };
            if (comptime window_id.getConfig().window_size_events) global.staticWindowCustomState(window_id).client_size = size;
        }
        /// The window can't be created again, hide it instead to show it
        /// again later.
        pub fn destroy() void {
            panicIfAppDoesntHave("destroy");
            switch (state().*) {
                .not_created, .destroyed => unreachable,
                .queued => {},
                // the app's own requests on it up to now are races
                .server_destroyed => global.race_errors_through[@backingInt(window_id)] = global.conn.?.sink.sequence,
                .created => |created| {
                    // status has it, mainLoop returns it
                    freeWindowResources(window_id, created.presenter != null) catch |err| switch (err) {
                        error.WriteFailed => {},
                    };
                    if (global.conn.?.status == .running) {
                        global.conn.?.sink.DestroyWindow(
                            global.conn.?.staticWindowId(window_id),
                        ) catch |e| global.conn.?.setWriteError(e);
                    }
                    // requests sent before the server gets the DestroyWindow can fail
                    global.race_errors_through[@backingInt(window_id)] = global.conn.?.sink.sequence;
                },
            }
            state().* = .destroyed;
            global.staticWindowCustomState(window_id).onDestroyed();
            if (comptime window_id.getConfig().destroyed_events) staticCallback(window_id)(.{ .destroyed = .app });
        }
        pub fn getClientSize() zin.XY(i32) {
            if (!window_id.getConfig().window_size_events) @compileError("getClientSize disabled because window_size_events is false");
            panicIfAppDoesntHave("getClientSize");
            switch (state().*) {
                .not_created, .destroyed => unreachable,
                .queued => @panic("getClientSize called before the window's .created callback"),
                .created, .server_destroyed => {},
            }
            return global.staticWindowCustomState(window_id).client_size;
        }
        pub fn show() void {
            panicIfErrorReturned();
            panicIfAppDoesntHave("show");
            switch (state().*) {
                .not_created, .destroyed => unreachable,
                .queued => |*queued| if (queued.show_order == null) {
                    queued.show_order = nextQueueOrder();
                },
                // status has it, mainLoop returns it
                .created => window().writeMap() catch |err| switch (err) {
                    error.WriteFailed => {},
                },
                .server_destroyed => {},
            }
        }
        pub fn hide() void {
            panicIfErrorReturned();
            panicIfAppDoesntHave("hide");
            switch (state().*) {
                .not_created, .destroyed => unreachable,
                .queued => |*queued| queued.show_order = null,
                // status has it, mainLoop returns it
                .created => window().writeUnmap() catch |err| switch (err) {
                    error.WriteFailed => {},
                },
                .server_destroyed => {},
            }
        }
        /// Raises the window to the top of the stack. It doesn't take the input
        /// focus, which is left to the window manager.
        pub fn foreground() void {
            panicIfErrorReturned();
            panicIfAppDoesntHave("foreground");
            switch (state().*) {
                .not_created, .destroyed => unreachable,
                .queued => |*queued| queued.foreground_order = nextQueueOrder(),
                // status has it, mainLoop returns it
                .created => window().writeRaise() catch |err| switch (err) {
                    error.WriteFailed => {},
                },
                .server_destroyed => {},
            }
        }
        pub fn invalidate() void {
            panicIfErrorReturned();
            panicIfAppDoesntHave("invalidate");
            switch (state().*) {
                .not_created, .destroyed => unreachable,
                .queued => |*queued| queued.damaged = true,
                .created => |*created| created.damaged = true,
                .server_destroyed => {},
            }
        }
        pub fn startTimerMillis(id: window_id.getConfig().TimerId(), millis: u32) void {
            startTimerNanos(id, std.time.ns_per_ms * @as(u64, millis));
        }
        pub fn startTimerNanos(id: window_id.getConfig().TimerId(), nanos: u64) void {
            panicIfErrorReturned();
            panicIfAppDoesntHave("startTimer");
            const timers = &global.staticWindowCustomState(window_id).timers;
            timers[zin.intFromTimerId(usize, window_id.getConfig().TimerId(), id)] = .{
                .start = .now(global.i.socket_reader.io, .awake),
                .duration_nanos = nanos,
            };
        }
    };
}

pub fn gcFromWindow(id: x11.Window) x11.GraphicsContext {
    const off = global.conn.?.id_range.offset(@fromBackingInt(@intCast(@backingInt(id)))).?;
    return global.conn.?.id_range.addAssumeCapacity(off + 1).graphicsContext();
}
fn windowPixelSizeFromInit(init: zin.WindowSizeInit, dpi_scale: DpiScale) zin.XY(i32) {
    return switch (init) {
        .default => @panic("todo"),
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: the client size is not right
        .client_pixels => |s| s,
        .client_points => |s| .{
            .x = dpi_scale.scale(i32, s.x),
            .y = dpi_scale.scale(i32, s.y),
        },
        .window_pixels => |s| s,
        .window_points => |s| .{
            .x = dpi_scale.scale(i32, s.x),
            .y = dpi_scale.scale(i32, s.y),
        },
    };
}

pub const CreateWindowOptions = struct {
    depth: u8 = 0, // 0 means copy_from_parent
    border_width: u16 = 0, // not sure what this is
    class: x11.window.Class = .input_output,
    visual: x11.Visual = .copy_from_parent,
    // the rest are also optional values in the underlying X11 CreateWindow request
    bg_pixmap: x11.window.BgPixmap = .none,
    border_pixmap: x11.window.BorderPixmap = .copy_from_parent,
    border_pixel: ?u32 = null,
    bit_gravity: x11.BitGravity = .north_west,
    win_gravity: x11.WinGravity = .north_west,
    backing_store: x11.window.BackingStore = .not_useful,
    backing_planes: u32 = 0xffffffff,
    backing_pixel: u32 = 0,
    override_redirect: bool = false,
    save_under: bool = false,
    dont_propagate: u32 = 0,
    colormap: x11.Colormap = .copy_from_parent,
    cursor: x11.Cursor = .none,
};

fn createWindow(
    config: *const zin.WindowConfigData,
    size: zin.XY(i32),
    maybe_pos: ?zin.XY(i32),
    bg: u32,
    id: x11.Window,
    opt: *const CreateWindowOptions,
) error{WriteFailed}!void {
    if (!try global.conn.?.canWrite()) return;
    global.conn.?.sink.CreateWindow(.{
        .window_id = id,
        .parent_window_id = global.i.screen.root,
        .depth = opt.depth,
        .x = if (maybe_pos) |*p| clampFromI32(i16, p.x) else 0,
        .y = if (maybe_pos) |*p| clampFromI32(i16, p.y) else 0,
        .width = clampFromI32(u16, size.x),
        .height = clampFromI32(u16, size.y),
        .border_width = opt.border_width,
        .class = opt.class,
        .visual_id = opt.visual,
    }, .{
        .bg_pixmap = opt.bg_pixmap,
        .bg_pixel = bg,
        .border_pixmap = opt.border_pixmap,
        .border_pixel = opt.border_pixel,
        .bit_gravity = opt.bit_gravity,
        .win_gravity = opt.win_gravity,
        .backing_store = opt.backing_store,
        .backing_planes = opt.backing_planes,
        .backing_pixel = opt.backing_pixel,
        .override_redirect = opt.override_redirect,
        .save_under = opt.save_under,
        .event_mask = .{
            .KeyPress = 1,
            .KeyRelease = 1,
            .ButtonPress = if (config.mouse_events) 1 else 0,
            .ButtonRelease = if (config.mouse_events) 1 else 0,
            // .EnterWindow = if (config.mouse_events) 1 else 0,
            // .LeaveWindow = if (config.mouse_events) 1 else 0,
            .PointerMotion = if (config.mouse_events) 1 else 0,
            .Exposure = 1,
            // CirculateNotify, ConfigureNotify, DestroyNotify, GravityNotify,
            // MapNotify, ReparentNotify and UnmapNotify, zin needs DestroyNotify
            // and ConfigureNotify for every window
            .StructureNotify = 1,
        },
        .dont_propagate = opt.dont_propagate,
        .colormap = opt.colormap,
        .cursor = opt.cursor,
    }) catch |e| return global.conn.?.teeWriteError(e);
    global.conn.?.sink.ChangeProperty(
        .replace,
        id,
        global.conn.?.wm_protocols.?,
        .ATOM,
        u32,
        .init(&[_]u32{@backingInt(global.conn.?.wm_delete_window.?)}, 1),
    ) catch |e| return global.conn.?.teeWriteError(e);
    global.conn.?.sink.CreateGc(
        gcFromWindow(id),
        id.drawable(),
        .{
            .background = bg,
            .foreground = 0x224477bb,
        },
    ) catch |e| return global.conn.?.teeWriteError(e);
}

pub fn clampFromI32(comptime T: type, i: i32) T {
    if (i > std.math.maxInt(T)) return std.math.maxInt(T);
    if (i < std.math.minInt(T)) return std.math.minInt(T);
    return @intCast(i);
}

pub const VirtualKey = enum(u16) {
    backspace = @backingInt(x11.charset.Combined.kbd_backspace_back_space_back_char),
    tab = @backingInt(x11.charset.Combined.kbd_tab),
    @"return" = @backingInt(x11.charset.Combined.kbd_return_enter),

    shift_left = @backingInt(x11.charset.Combined.kbd_left_shift),
    shift_right = @backingInt(x11.charset.Combined.kbd_right_shift),
    control_left = @backingInt(x11.charset.Combined.kbd_left_control),
    control_right = @backingInt(x11.charset.Combined.kbd_right_control),
    alt_left = @backingInt(x11.charset.Combined.kbd_left_alt),
    alt_right = @backingInt(x11.charset.Combined.kbd_right_alt),
    pause = @backingInt(x11.charset.Combined.kbd_pause_hold),
    caps_lock = @backingInt(x11.charset.Combined.kbd_caps_lock),
    escape = @backingInt(x11.charset.Combined.kbd_escape),
    page_up = @backingInt(x11.charset.Combined.kbd_page_up),
    page_down = @backingInt(x11.charset.Combined.kbd_page_down),
    end = @backingInt(x11.charset.Combined.kbd_end_eol),
    home = @backingInt(x11.charset.Combined.kbd_home),
    left = @backingInt(x11.charset.Combined.kbd_left),
    up = @backingInt(x11.charset.Combined.kbd_up),
    right = @backingInt(x11.charset.Combined.kbd_right),
    down = @backingInt(x11.charset.Combined.kbd_down),
    print_screen = @backingInt(x11.charset.Combined._3170__3270_printscreen),
    insert = @backingInt(x11.charset.Combined.kbd_insert_insert_here),
    delete = @backingInt(x11.charset.Combined.kbd_delete_rubout),
    super_left = @backingInt(x11.charset.Combined.kbd_left_super),
    super_right = @backingInt(x11.charset.Combined.kbd_right_super),

    numpad0 = @backingInt(x11.charset.Combined.kbd_keypad_digit_zero),
    numpad1 = @backingInt(x11.charset.Combined.kbd_keypad_digit_one),
    numpad2 = @backingInt(x11.charset.Combined.kbd_keypad_digit_two),
    numpad3 = @backingInt(x11.charset.Combined.kbd_keypad_digit_three),
    numpad4 = @backingInt(x11.charset.Combined.kbd_keypad_digit_four),
    numpad5 = @backingInt(x11.charset.Combined.kbd_keypad_digit_five),
    numpad6 = @backingInt(x11.charset.Combined.kbd_keypad_digit_six),
    numpad7 = @backingInt(x11.charset.Combined.kbd_keypad_digit_seven),
    numpad8 = @backingInt(x11.charset.Combined.kbd_keypad_digit_eight),
    numpad9 = @backingInt(x11.charset.Combined.kbd_keypad_digit_nine),

    multiply = @backingInt(x11.charset.Combined.kbd_keypad_multiplication_sign_asterisk),
    add = @backingInt(x11.charset.Combined.kbd_keypad_plus_sign),
    separator = @backingInt(x11.charset.Combined.kbd_keypad_separator_comma),
    subtract = @backingInt(x11.charset.Combined.kbd_keypad_minus_sign_hyphen),
    decimal = @backingInt(x11.charset.Combined.kbd_keypad_decimal_point_period),

    f1 = @backingInt(x11.charset.Combined.kbd_f1),
    f2 = @backingInt(x11.charset.Combined.kbd_f2),
    f3 = @backingInt(x11.charset.Combined.kbd_f3),
    f4 = @backingInt(x11.charset.Combined.kbd_f4),
    f5 = @backingInt(x11.charset.Combined.kbd_f5),
    f6 = @backingInt(x11.charset.Combined.kbd_f6),
    f7 = @backingInt(x11.charset.Combined.kbd_f7),
    f8 = @backingInt(x11.charset.Combined.kbd_f8),
    f9 = @backingInt(x11.charset.Combined.kbd_f9),
    f10 = @backingInt(x11.charset.Combined.kbd_f10),
    f11 = @backingInt(x11.charset.Combined.kbd_f11_l1),
    f12 = @backingInt(x11.charset.Combined.kbd_f12_l2),
    f13 = @backingInt(x11.charset.Combined.kbd_f13_l3),
    f14 = @backingInt(x11.charset.Combined.kbd_f14_l4),
    f15 = @backingInt(x11.charset.Combined.kbd_f15_l5),
    f16 = @backingInt(x11.charset.Combined.kbd_f16_l6),
    f17 = @backingInt(x11.charset.Combined.kbd_f17_l7),
    f18 = @backingInt(x11.charset.Combined.kbd_f18_l8),
    f19 = @backingInt(x11.charset.Combined.kbd_f19_l9),
    f20 = @backingInt(x11.charset.Combined.kbd_f20_l10),
    f21 = @backingInt(x11.charset.Combined.kbd_f21_r1),
    f22 = @backingInt(x11.charset.Combined.kbd_f22_r2),
    f23 = @backingInt(x11.charset.Combined.kbd_f23_r3),
    f24 = @backingInt(x11.charset.Combined.kbd_f24_r4),

    numlock = @backingInt(x11.charset.Combined.kbd_num_lock),
    scroll_lock = @backingInt(x11.charset.Combined.kbd_scroll_lock),

    _,
};
pub const ScanCode = u8;
pub const Coord = i16;

pub fn asciiFromKeysym(vk: VirtualKey) ?u8 {
    return switch (@backingInt(vk)) {
        ' '...'~' => |a| @intCast(a),
        else => null,
    };
}

fn mouseButtonFromMsg(detail: u8) ?zin.MouseButtonId {
    return switch (detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => null,
    };
}

/// The X server reports a wheel as presses of buttons 4 to 7, one per notch.
fn mouseScrollFromMsg(detail: u8) ?zin.XY(f32) {
    return switch (detail) {
        4 => .{ .x = 0, .y = 1 },
        5 => .{ .x = 0, .y = -1 },
        6 => .{ .x = -1, .y = 0 },
        7 => .{ .x = 1, .y = 0 },
        else => null,
    };
}

fn drawStaticWindow(comptime window_id: zin.StaticWindowId) error{WriteFailed}!enum { rendered, not_ready } {
    if (!try global.conn.?.canWrite()) return .not_ready;
    const created = &global.static_window_states[@backingInt(window_id)].created;
    const config = window_id.getConfig();
    const window = global.conn.?.staticWindowId(window_id);

    if (created.presenter == null) {
        created.presenter = .{
            .opcode_base = global.conn.?.present_opcode_base.?,
            .depth = global.conn.?.depth,
            .window_id = window,
            .event_id = global.conn.?.staticWindowPresentEventId(window_id),
            .pixmaps = global.conn.?.staticWindowPixmaps(window_id),
        };
        created.presenter.?.init(&global.conn.?.sink, @intCast(created.size.x), @intCast(created.size.y)) catch |e|
            return global.conn.?.teeWriteError(e);
    }

    const back_pixmap = created.presenter.?.beginFrame() orelse return .not_ready;
    created.damaged = false;

    var text_id_check: zin.TextIdCheck(config.TextId) = .{};
    staticCallback(window_id)(.{ .draw = .{
        .window = window,
        .pixmap = back_pixmap,
        .text_id_check = &text_id_check,
        .client_size = if (config.window_size_events) global.staticWindowCustomState(window_id).client_size else {},
        .background = if (comptime config.dynamic_background) config.background else {},
    } });
    if (!try global.conn.?.canWrite()) return .rendered;

    switch (global.static_window_states[@backingInt(window_id)]) {
        .created => |*still_created| still_created.presenter.?.endFrame(&global.conn.?.sink) catch |e|
            return global.conn.?.teeWriteError(e),
        // the app destroyed it while drawing
        .destroyed => {},
        .not_created, .queued, .server_destroyed => unreachable,
    }
    return .rendered;
}

/// Tells the app about server-side changes to its windows, then draws the
/// damaged ones. Returns how many it drew.
pub fn x11UpdateWindows() error{WriteFailed}!usize {
    var update_count: usize = 0;
    inline for (comptime std.meta.tags(zin.StaticWindowId)) |window_id| {
        // the app quit, it gets no more callbacks
        if (global.conn.?.status == .quit_requested) return update_count;
        if (window_id.getConfig().window_size_events) {
            switch (global.static_window_states[@backingInt(window_id)]) {
                .not_created, .queued, .server_destroyed, .destroyed => {},
                .created => |created| {
                    const client_size = &global.staticWindowCustomState(window_id).client_size;
                    if (client_size.x != created.size.x or client_size.y != created.size.y) {
                        client_size.* = created.size;
                        staticCallback(window_id)(.{ .window_size = created.size });
                    }
                },
            }
        }
        switch (global.static_window_states[@backingInt(window_id)]) {
            .not_created, .queued, .server_destroyed, .destroyed => {},
            .created => |created| if (created.damaged) switch (try drawStaticWindow(window_id)) {
                .rendered => update_count += 1,
                .not_ready => {},
            },
        }
    }
    return update_count;
}

fn pollSocketReader(socket_reader: *std.Io.net.Stream.Reader, timeout_nanos: ?u64) !enum { ready, timeout, interrupted } {
    if (socket_reader.interface.bufferedLen() > 0) return .ready;
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = socket_reader.stream.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const timeout_ts: std.posix.timespec = if (timeout_nanos) |t| .{
        .sec = @intCast(@divTrunc(t, std.time.ns_per_s)),
        .nsec = @intCast(t % std.time.ns_per_s),
    } else undefined;
    const count = std.posix.ppoll(&poll_fds, if (timeout_nanos != null) &timeout_ts else null, null) catch |err| switch (err) {
        // a signal handler ran, the caller checks its timers again
        error.SignalInterrupt => return .interrupted,
        else => |e| return e,
    };
    return switch (count) {
        0 => .timeout,
        1 => .ready,
        else => unreachable,
    };
}

const Timeout = union(enum) {
    none,
    nanos: u64,
    expired: StaticWindowAndTimerId,
    pub fn initExpired(comptime window_id: zin.StaticWindowId, timer_id: window_id.getConfig().TimerId()) Timeout {
        return switch (window_id) {
            inline else => |case_window_id| .{ .expired = @unionInit(StaticWindowAndTimerId, @tagName(case_window_id), timer_id) },
        };
    }
};
fn minTimeoutNanos(maybe_previous: ?u64, nanos: u64) u64 {
    return @min(maybe_previous orelse return nanos, nanos);
}
fn resolveNow(maybe_now_ref: *?std.Io.Timestamp) std.Io.Timestamp {
    if (maybe_now_ref.* == null) {
        maybe_now_ref.* = .now(global.i.socket_reader.io, .awake);
    }
    return maybe_now_ref.*.?;
}

fn debugPanic(comptime fmt: []const u8, args: anytype) void {
    switch (builtin.mode) {
        .Debug => std.debug.panic(fmt, args),
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => log.err(fmt, args),
    }
}

fn getTimerMinTimeout(maybe_now_ref: *?std.Io.Timestamp) Timeout {
    var maybe_min_nanos: ?u64 = null;
    inline for (comptime std.meta.tags(zin.StaticWindowId)) |window_id| {
        const timers = &global.staticWindowCustomState(window_id).timers;
        for (timers, 0..) |maybe_timer, timer_index| {
            const timer = maybe_timer orelse continue;
            const diff_nanos: u64 = @intCast(timer.start.durationTo(resolveNow(maybe_now_ref)).toNanoseconds());
            const TimerId = window_id.getConfig().TimerId();
            if (diff_nanos >= timer.duration_nanos) {
                timers[timer_index].?.start = maybe_now_ref.*.?;
                return .initExpired(window_id, zin.timerIdFromInt(TimerId, timer_index));
            }
            maybe_min_nanos = minTimeoutNanos(maybe_min_nanos, timer.duration_nanos - diff_nanos);
        }
    }
    return if (maybe_min_nanos) |nanos| .{ .nanos = nanos } else .none;
}

fn drainSocket() !enum { quit, handled_messages, no_messages } {
    var handled_message: bool = false;
    while (true) switch (try pollSocketReader(&global.i.socket_reader, 0)) {
        // the app quit, it gets no more callbacks
        .ready => if (global.conn.?.status == .quit_requested) return .quit else {
            const msg_kind = global.conn.?.source.readKind() catch |err| {
                const reason: anyerror = switch (err) {
                    error.EndOfStream => err,
                    error.ReadFailed => switch (global.i.socket_reader.err.?) {
                        error.ConnectionResetByPeer => |e| e,
                        else => |e| return e,
                    },
                };
                log.err("X11 connection closed by the server ({t})", .{reason});
                return error.X11ConnectionClosed;
            };
            try x11HandleMessage(&global.conn.?.source, msg_kind);
            handled_message = true;
        },
        .timeout, .interrupted => return if (handled_message) .handled_messages else .no_messages,
    };
}

pub fn mainLoop() !void {
    if (global.conn.?.status == .error_returned) @panic("the X11 connection failed, the app must disconnect");
    mainLoopInner() catch |err| {
        global.conn.?.status = .error_returned;
        return err;
    };
}
fn mainLoopInner() !void {
    var check_windows: bool = true;
    while (true) {
        if (try global.conn.?.canWrite()) global.conn.?.sink.writer.flush() catch |e| return global.conn.?.teeWriteError(e);

        switch (try drainSocket()) {
            .quit => return,
            .handled_messages => check_windows = true,
            .no_messages => {},
        }

        var maybe_now: ?std.Io.Timestamp = null;
        const timer: union(enum) {
            expired: StaticWindowAndTimerId,
            wait_nanos: ?u64,
        } = switch (getTimerMinTimeout(&maybe_now)) {
            .none => .{ .wait_nanos = null },
            .nanos => |nanos| .{ .wait_nanos = nanos },
            .expired => |expired| .{ .expired = expired },
        };

        const expired: StaticWindowAndTimerId = blk_expired: switch (timer) {
            .wait_nanos => |timeout_nanos| {
                if (check_windows) {
                    _ = try x11UpdateWindows();
                    check_windows = false;
                    continue;
                }
                switch (try pollSocketReader(&global.i.socket_reader, timeout_nanos)) {
                    .ready, .interrupted => continue,
                    .timeout => {
                        var new_now: ?std.Io.Timestamp = null;
                        break :blk_expired switch (getTimerMinTimeout(&new_now)) {
                            .none => unreachable,
                            .nanos => unreachable,
                            .expired => |expired| expired,
                        };
                    },
                }
            },
            .expired => |expired| expired,
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
        check_windows = true;
    }
}
pub fn quitMainLoop() void {
    if (global.conn != null) {
        switch (global.conn.?.status) {
            .running => {
                // the requests the app made before quitting, a failure doesn't matter anymore
                global.conn.?.sink.writer.flush() catch |err| switch (err) {
                    error.WriteFailed => {},
                };
                global.conn.?.status = .quit_requested;
            },
            // doesn't matter anymore
            .write_failed => global.conn.?.status = .quit_requested,
            .quit_requested, .error_returned => {},
        }
        const reader = &global.i.socket_reader;
        reader.stream.shutdown(reader.io, .both) catch |err| switch (err) {
            error.SystemResources,
            error.NetworkDown,
            error.Unexpected,
            error.Canceled,
            => |e| std.debug.panic("shutdown failed with {s}", .{@errorName(e)}),
            error.ConnectionResetByPeer,
            error.SocketUnconnected,
            error.ConnectionAborted,
            => {},
        };
    }
}

pub fn x11HandleMessage(source: *x11.Source, msg_kind: x11.ServerMsgKind) !void {
    switch (msg_kind) {
        .Error => {
            const err = try source.read2(.Error);
            defer onServerSequence(err.sequence);
            if (global.conn.?.setupRequestFromSequence(err.sequence)) |request| {
                log.err("X11 setup request {t} failed: {f}", .{ request, err });
                return error.X11SetupRequestFailed;
            }
            if (support_dpi_events and global.conn.?.dpi_get_property_sequence == err.sequence) {
                log.err("X11 GetProperty RESOURCE_MANAGER (for the DPI) failed: {f}", .{err});
                return if (global.conn.?.dpi_scale == null) error.X11SetupRequestFailed else error.X11GetDpiFailed;
            }
            // only these errors name a resource in generic
            const resource_error = switch (err.code) {
                .window, .pixmap, .drawable, .gcontext => true,
                else => false,
            };
            if (resource_error) if (global.conn.?.staticWindowFromResource(err.generic)) |window_id| {
                const index = @backingInt(window_id);
                const race = switch (global.static_window_states[index]) {
                    // zin sends nothing for it and the app wasn't told, so
                    // every error is for a request sent before the destroy
                    .server_destroyed => true,
                    .not_created, .queued, .created, .destroyed => if (global.race_errors_through[index]) |through|
                        !sequenceBefore(through, err.sequence)
                    else
                        false,
                };
                if (race) {
                    log.debug("ignoring X11 error for window {t}, which was destroyed: {f}", .{ window_id, err });
                    return;
                }
            };
            std.debug.panic("Unhandled X11 Error: {f}", .{err});
        },
        .Reply => {
            const reply = try source.read2(.Reply);
            onServerSequence(reply.sequence);

            if (global.conn.?.setupRequestFromSequence(reply.sequence)) |request| {
                return handleSetupReply(source, reply, request);
            }

            if (support_dpi_events) {
                if (global.conn.?.dpi_get_property_sequence) |seq| {
                    if (reply.sequence == seq) {
                        global.conn.?.dpi_get_property_sequence = null;
                        const maybe_scale = try readDpiFromPropertyReply(source, reply.flexible);
                        const old = global.conn.?.dpi_scale orelse {
                            global.conn.?.dpi_scale = .{ .val = maybe_scale orelse 1.0 };
                            return onSetupProgress();
                        };
                        if (maybe_scale) |scale| {
                            global.conn.?.dpi_scale = .{ .val = scale };
                            if (old.val != scale) {
                                inline for (comptime std.meta.tags(zin.StaticWindowId)) |window_id| {
                                    if (global.conn.?.status == .quit_requested) return;
                                    if (window_id.getConfig().dpi_events) {
                                        switch (global.static_window_states[@backingInt(window_id)]) {
                                            .not_created, .destroyed => {},
                                            .queued, .created, .server_destroyed => staticCallback(window_id)(.dpi_change),
                                        }
                                    }
                                }
                            }
                        }
                        return;
                    }
                }
            }

            const remaining = source.replyRemainingSize();
            if (zin.config.x11_on_unhandled_reply) |func| {
                try func(reply.flexible, reply.sequence, reply.word_count);
                const new_remaining = source.replyRemainingSize();
                if (new_remaining != remaining) {
                    try source.discardRemaining();
                    return;
                }
                log.info("unhandled X11 {f}", .{source.readFmtDropError()});
            } else {
                log.info("unhandled X11 {f} (set zin_config.x11_unhandled_reply to handle it)", .{source.readFmtDropError()});
            }
            try source.discardRemaining();
            return error.X11UnhandledReply;
        },
        inline .KeyPress, .KeyRelease => |_, kind| {
            const event = try readEvent(source, kind);
            const w = eventWindow(event.event) orelse return;
            switch (w) {
                inline else => |window_id| if (window_id.getConfig().key_events) {
                    if (global.conn.?.keymap.?.getKeysym(event.keycode, event.state.mod())) |keysym| {
                        staticCallback(window_id)(.{ .key = keyFromX11(
                            if (kind == .KeyPress) .down else .up,
                            event.keycode,
                            event.state,
                            keysym,
                        ) });
                    } else |e| switch (e) {
                        error.KeycodeTooSmall => log.err("{t} keycode {} is too small", .{ kind, event.keycode }),
                    }
                },
            }
        },
        .ButtonPress => {
            const event = try readEvent(source, .ButtonPress);
            const w = eventWindow(event.event) orelse return;
            const pos: zin.XY(i32) = .{ .x = @intCast(event.event_x), .y = @intCast(event.event_y) };
            if (mouseScrollFromMsg(event.button)) |scroll| {
                switch (w) {
                    inline else => |window_id| if (window_id.getConfig().mouse_events) {
                        staticCallback(window_id)(.{ .mouse = .{
                            .position = pos,
                            .kind = .{ .scroll = scroll },
                            .down = .{
                                .left = event.state.button1,
                                .right = event.state.button3,
                                .middle = event.state.button2,
                            },
                        } });
                    },
                }
                return;
            }
            const button_id = mouseButtonFromMsg(event.button) orelse {
                log.warn("no mapping for X11 button {} to zin (ButtonPress)", .{event.button});
                return;
            };
            switch (w) {
                inline else => |window_id| if (window_id.getConfig().mouse_events) {
                    staticCallback(window_id)(.{ .mouse = .{
                        .position = pos,
                        .kind = .{ .button = .{ .id = button_id, .state = .down } },
                        .down = .{
                            .left = event.state.button1 or (button_id == .left),
                            .right = event.state.button3 or (button_id == .right),
                            .middle = event.state.button2 or (button_id == .middle),
                        },
                    } });
                },
            }
        },
        .ButtonRelease => {
            const event = try readEvent(source, .ButtonRelease);
            const w = eventWindow(event.event) orelse return;
            // the press of a wheel button is the whole event
            if (mouseScrollFromMsg(event.button) != null) return;
            const button_id = mouseButtonFromMsg(event.button) orelse {
                log.warn("no mapping for X11 button {} to zin (ButtonRelease)", .{event.button});
                return;
            };
            switch (w) {
                inline else => |window_id| if (window_id.getConfig().mouse_events) {
                    staticCallback(window_id)(.{ .mouse = .{
                        .position = .{ .x = @intCast(event.event_x), .y = @intCast(event.event_y) },
                        .kind = .{ .button = .{ .id = button_id, .state = .up } },
                        .down = .{
                            .left = event.state.button1 and (button_id != .left),
                            .right = event.state.button3 and (button_id != .right),
                            .middle = event.state.button2 and (button_id != .middle),
                        },
                    } });
                },
            }
        },
        .MotionNotify => {
            const event = try readEvent(source, .MotionNotify);
            const w = eventWindow(event.event) orelse return;
            switch (w) {
                inline else => |window_id| if (window_id.getConfig().mouse_events) {
                    staticCallback(window_id)(.{ .mouse = .{
                        .position = .{ .x = @intCast(event.event_x), .y = @intCast(event.event_y) },
                        .kind = .move,
                        .down = .{
                            .left = event.state.button1,
                            .right = event.state.button3,
                            .middle = event.state.button2,
                        },
                    } });
                },
            }
        },
        .Expose => {
            const event = try readEvent(source, .Expose);
            const w = eventWindow(event.window) orelse return;
            global.static_window_states[@backingInt(w)].created.damaged = true;
        },
        .MappingNotify,
        .UnmapNotify,
        .MapNotify,
        .ReparentNotify,
        .GravityNotify,
        .CirculateNotify,
        => {
            log.debug("ignoring X11 {f}", .{source.readFmtDropError()});
            // ensures we still discard the rest of the message if logging is disabled
            try source.discardRemaining();
        },
        .DestroyNotify => {
            const event = try readEvent(source, .DestroyNotify);
            // from StructureNotify on another window, e.g. one the app selected itself
            if (event.event != event.window) return;
            // the app's own destroys are filtered out here, the window is destroyed already
            const w = eventWindow(event.window) orelse return;
            switch (w) {
                inline else => |window_id| try onServerDestroyed(window_id),
            }
        },
        .ClientMessage => {
            const event = try readEvent(source, .ClientMessage);
            const w = eventWindow(event.window) orelse return;
            const protocol = std.mem.readInt(u32, event.data[0..4], builtin.cpu.arch.endian());
            if (event.format == 32 and event.type == global.conn.?.wm_protocols.? and protocol == @backingInt(global.conn.?.wm_delete_window.?)) {
                switch (w) {
                    inline else => |window_id| staticCallback(window_id)(.close),
                }
            } else log.debug("ignoring X11 ClientMessage type={} format={}", .{ @backingInt(event.type), event.format });
        },
        .ConfigureNotify => {
            const event = try readEvent(source, .ConfigureNotify);
            if (event.event != event.window) return;
            const w = eventWindow(event.window) orelse return;
            const created = &global.static_window_states[@backingInt(w)].created;
            if (event.width == created.size.x and event.height == created.size.y) return;
            created.size = .{ .x = event.width, .y = event.height };
            if (created.presenter) |*presenter| {
                if (!try global.conn.?.canWrite()) return;
                presenter.resize(&global.conn.?.sink, event.width, event.height) catch |e| return global.conn.?.teeWriteError(e);
                created.damaged = true;
            }
        },
        .GenericEvent => {
            const event = try source.read2(.GenericEvent);
            onServerSequence(event.sequence);
            const present_opcode_base = global.conn.?.present_opcode_base orelse {
                log.err("GenericEvent ext_opcode={} type={} before the Present extension is known", .{ event.ext_opcode_base, event.type });
                try source.discardRemaining();
                return error.X11UnexpectedMessage;
            };
            if (event.isPresentCompleteNotify(present_opcode_base)) {
                const complete = try source.read3Full(.present_CompleteNotify);
                const presenter = eventPresenter(complete.window) orelse return;
                if (!try presenter.handleCompleteNotify(complete)) {
                    log.err("Present CompleteNotify for window {} has an unexpected event id {}", .{ @backingInt(complete.window), complete.event_id });
                    return error.X11UnexpectedMessage;
                }
            } else if (event.isPresentIdleNotify(present_opcode_base)) {
                const idle = try source.read3Full(.present_IdleNotify);
                const presenter = eventPresenter(idle.window) orelse return;
                if (!try presenter.handleIdleNotify(idle)) {
                    log.err("Present IdleNotify for window {} has an unexpected event id {}", .{ @backingInt(idle.window), idle.event_id });
                    return error.X11UnexpectedMessage;
                }
            } else {
                log.err("unexpected GenericEvent ext_opcode={} type={}", .{ event.ext_opcode_base, event.type });
                try source.discardRemaining();
            }
        },
        .PropertyNotify => {
            const event = try readEvent(source, .PropertyNotify);
            if (support_dpi_events) {
                if (@backingInt(event.window) == @backingInt(global.i.screen.root) and event.atom == .RESOURCE_MANAGER) {
                    // The server sends replies and events in the order it
                    // handles them, so a GetProperty still pending was handled
                    // after this change and its reply already has the new value.
                    if (global.conn.?.dpi_get_property_sequence != null) return;
                    if (!try global.conn.?.canWrite()) return;
                    global.conn.?.dpi_get_property_sequence = sendDpiGetProperty(&global.conn.?.sink) catch |e|
                        return global.conn.?.teeWriteError(e);
                    return;
                }
            }
            log.debug("ignoring PropertyNotify: window={any} atom={any}", .{ event.window, event.atom });
        },
        else => {
            log.err("Unexpected X11 {f}", .{source.readFmtDropError()});
            try source.discardRemaining();
            return error.X11UnexpectedMessage;
        },
    }
}

fn eventPresenter(window: x11.Window) ?*x11.Presenter {
    const w = eventWindow(window) orelse return null;
    const created = &global.static_window_states[@backingInt(w)].created;
    if (created.presenter) |*presenter| return presenter;
    log.debug("ignoring Present event for window {t}, which has no presenter", .{w});
    return null;
}

fn keyFromX11(direction: enum { up, down }, keycode: u8, mask: x11.KeyButtonMask, keysym: x11.charset.Combined) zin.Key {
    return .{
        .kind = switch (direction) {
            .up => .up,
            .down => .down,
        },
        .vk = @fromBackingInt(@intCast(@backingInt(keysym))),
        .scan_code = keycode,
        .win32_extended = {},
        .x11_mask = mask,
        .macos_mods = {},
    };
}

fn giveup(what: []const u8, e: anyerror) noreturn {
    std.debug.panic("{s} failed with {s}", .{ what, @errorName(e) });
}

pub const PolygonPoint = struct {
    x_point: x11.XY(i16),
    pub fn xy(x: i32, y: i32) PolygonPoint {
        return .{ .x_point = .{ .x = @truncate(x), .y = @truncate(y) } };
    }
};

pub fn Draw(window_id: zin.StaticWindowId) type {
    return struct {
        window: x11.Window,
        pixmap: x11.Pixmap,
        text_id_check: *zin.TextIdCheck(window_id.getConfig().TextId),
        client_size: if (window_id.getConfig().window_size_events) zin.XY(i32) else void,
        background: if (window_id.getConfig().dynamic_background) zin.Rgb8 else void,

        const Self = @This();

        pub fn x11Drawable(self: *const Self) x11.Drawable {
            return self.pixmap.drawable();
        }

        pub fn getDpiScale(self: *const Self) zin.XY(f32) {
            _ = self;
            if (!support_dpi_events) @compileError("cannot call getDpiScale without setting dpi_events to true");
            const dpi_scale = global.conn.?.dpi_scale.?;
            return .{ .x = dpi_scale.val, .y = dpi_scale.val };
        }

        fn shouldDraw() bool {
            switch (global.static_window_states[@backingInt(window_id)]) {
                .created => {},
                .destroyed => @panic("drawing on a window the app destroyed"),
                .not_created, .queued, .server_destroyed => @panic("drawing outside the window's draw callback"),
            }
            return global.conn.?.status == .running;
        }

        pub fn clear(self: *const Self) void {
            if (!shouldDraw()) return;
            const rgb = if (comptime window_id.getConfig().dynamic_background)
                self.background
            else
                window_id.getConfig().background;
            const drawable = self.x11Drawable();
            global.conn.?.sink.ChangeGc(gcFromWindow(self.window), .{
                .foreground = global.conn.?.x11FromRgb(rgb),
            }) catch |e| return global.conn.?.setWriteError(e);
            global.conn.?.sink.PolyFillRectangle(
                drawable,
                gcFromWindow(self.window),
                .initAssume(&[_]x11.Rectangle{.{
                    .x = 0,
                    .y = 0,
                    .width = @intCast(self.client_size.x),
                    .height = @intCast(self.client_size.y),
                }}),
            ) catch |e| return global.conn.?.setWriteError(e);
        }

        pub fn rect(self: *const Self, r: zin.Rect, rgb: zin.Rgb8) void {
            if (!shouldDraw()) return;
            global.conn.?.sink.ChangeGc(gcFromWindow(self.window), .{
                .foreground = global.conn.?.x11FromRgb(rgb),
            }) catch |e| return global.conn.?.setWriteError(e);
            global.conn.?.sink.PolyFillRectangle(
                self.x11Drawable(),
                gcFromWindow(self.window),
                .initAssume(&[_]x11.Rectangle{.{
                    .x = @intCast(r.left),
                    .y = @intCast(r.top),
                    .width = @intCast(r.right - r.left),
                    .height = @intCast(r.bottom - r.top),
                }}),
            ) catch |e| return global.conn.?.setWriteError(e);
        }

        pub fn text(self: *const Self, id: window_id.getConfig().TextId, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            self.text_id_check.onText(id);
            if (!shouldDraw()) return;
            const slice = x11.SliceWithMaxLen(u8, [*]const u8, 254){
                .ptr = t.ptr,
                .len = std.math.cast(u8, t.len) orelse std.debug.panic("TODO: handle text with {} bytes", .{t.len}),
            };
            global.conn.?.sink.ChangeGc(gcFromWindow(self.window), .{
                .background = 0, // TODO: how do we declare this as transparent?
                .foreground = global.conn.?.x11FromRgb(rgb),
            }) catch |e| return global.conn.?.setWriteError(e);
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
            ) catch |e| return global.conn.?.setWriteError(e);
        }

        pub fn polygon(self: *const Self, points: []const PolygonPoint, rgb: zin.Rgb8) void {
            if (!shouldDraw()) return;
            if (points.len <= 1) return;
            global.conn.?.sink.ChangeGc(gcFromWindow(self.window), .{
                .foreground = global.conn.?.x11FromRgb(rgb),
            }) catch |e| return global.conn.?.setWriteError(e);
            var point_sink: x11.PolyPointSink = .{
                .kind = .{ .fill = .non_convex },
                .coordinate_mode = .origin,
                .drawable = self.x11Drawable(),
                .gc = gcFromWindow(self.window),
            };
            defer point_sink.endSetMsgSize(global.conn.?.sink.writer);
            for (points) |p| {
                point_sink.write(
                    &global.conn.?.sink,
                    p.x_point,
                ) catch |e| return global.conn.?.setWriteError(e);
            }
        }
    };
}
