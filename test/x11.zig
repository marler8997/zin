//! Tests zin's X11 platform against a scripted fake X server. The test
//! connects zin to the fake server over TCP, then steps both sides by hand:
//! the server reads the requests zin flushed and sends replies and events,
//! and zin handles a known number of messages.
//!
//! Run with no arguments to run every scenario. With a `panic-*` argument
//! it runs one app bug that zin must panic on, see x11_panic_cases in build.zig.

const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin");
const x11 = zin.platform.x11;

pub const zin_config: zin.Config = .{
    .ThreadId = enum { main },
    .StaticWindowId = StaticWindowId,
};
pub const std_options: std.Options = .{ .log_level = .warn };

const StaticWindowId = enum {
    /// has every event
    a,
    /// has no events, so it isn't told when the server destroys it
    b,
    pub fn getConfig(self: StaticWindowId) zin.WindowConfigData {
        return switch (self) {
            .a => .{
                .thread = .main,
                .window_size_events = true,
                .key_events = true,
                .mouse_events = true,
                .dpi_events = true,
                .destroyed_events = true,
                .TextId = enum { text },
                .timers = .one,
                .background = .{ .r = 0, .g = 0, .b = 0 },
                .dynamic_background = false,
                .win32 = .{ .render = .{ .gdi = .{} } },
                .x11 = .{},
            },
            .b => .{
                .thread = .main,
                .window_size_events = false,
                .key_events = false,
                .mouse_events = false,
                .dpi_events = false,
                .destroyed_events = false,
                .TextId = enum { text },
                .timers = .none,
                .background = .{ .r = 0, .g = 0, .b = 0 },
                .dynamic_background = false,
                .win32 = .{ .render = .{ .gdi = .{} } },
                .x11 = .{},
            },
        };
    }
};

const io = std.Io.Threaded.global_single_threaded.io();
/// the fake server's accept thread runs while zin connects, so it has its own
var server_threaded: std.Io.Threaded = .init_single_threaded;
const server_io = (&server_threaded).io();

// --------------------------------------------------------------------------------
// the callbacks zin made
// --------------------------------------------------------------------------------
const Logged = union(enum) {
    created: StaticWindowId,
    close: StaticWindowId,
    draw: StaticWindowId,
    window_size: struct { StaticWindowId, zin.XY(i32) },
    key: StaticWindowId,
    mouse: StaticWindowId,
    timer: StaticWindowId,
    dpi_change: StaticWindowId,
    destroyed: struct { StaticWindowId, zin.DestroyedReason },
};
const callback_log = struct {
    var entries: [64]Logged = undefined;
    var len: usize = 0;
    fn add(entry: Logged) void {
        if (len == entries.len) @panic("callback log is full");
        entries[len] = entry;
        len += 1;
    }
    fn clear() void {
        len = 0;
    }
    fn slice() []const Logged {
        return entries[0..len];
    }
    fn expect(expected: []const Logged) void {
        if (len == expected.len) {
            for (slice(), expected) |actual, e| {
                if (!std.meta.eql(actual, e)) break;
            } else return;
        }
        std.debug.print("expected callbacks:\n", .{});
        for (expected) |e| std.debug.print("  {any}\n", .{e});
        std.debug.print("actual callbacks:\n", .{});
        for (slice()) |e| std.debug.print("  {any}\n", .{e});
        @panic("unexpected callbacks");
    }
};

/// called on a's next draw or timer, for apps that call back into zin
/// from a callback
var on_draw_a: ?*const fn (DrawA) void = null;
var on_timer_a: ?*const fn () void = null;
var on_close_a: ?*const fn () void = null;
var last_key_a: ?zin.Key = null;
const DrawA = @FieldType(zin.Callback(.a), "draw");
fn callbackA(cb: zin.Callback(.a)) void {
    switch (cb) {
        .draw => |d| if (on_draw_a) |f| {
            on_draw_a = null;
            f(d);
        },
        .timer => if (on_timer_a) |f| {
            on_timer_a = null;
            f();
        },
        .close => if (on_close_a) |f| {
            on_close_a = null;
            f();
        },
        else => {},
    }
    callback_log.add(switch (cb) {
        .created => .{ .created = .a },
        .close => .{ .close = .a },
        .draw => .{ .draw = .a },
        .window_size => |size| .{ .window_size = .{ .a, size } },
        .key => |key| blk: {
            last_key_a = key;
            break :blk .{ .key = .a };
        },
        .mouse => .{ .mouse = .a },
        .timer => .{ .timer = .a },
        .dpi_change => .{ .dpi_change = .a },
        .destroyed => |reason| .{ .destroyed = .{ .a, reason } },
    });
}
fn callbackB(cb: zin.Callback(.b)) void {
    callback_log.add(switch (cb) {
        .close => .{ .close = .b },
        .draw => .{ .draw = .b },
    });
}

// --------------------------------------------------------------------------------
// the fake X server
// --------------------------------------------------------------------------------
const root_window: u32 = 0x100;
const resource_id_base: u32 = 0x200000;
const resource_id_mask: u32 = 0x1fffff;
const present_opcode: u8 = 140;
const atom_wm_protocols: u32 = 300;
const atom_wm_delete_window: u32 = 301;
const min_keycode = 8;
const max_keycode = 255;
const keycode_a = 38;

/// The ids zin uses for each static window: 5 per window, the window first.
fn windowXid(window_id: StaticWindowId) u32 {
    return resource_id_base + @as(u32, @backingInt(window_id)) * 5;
}
fn gcXid(window_id: StaticWindowId) u32 {
    return windowXid(window_id) + 1;
}
fn pixmapXid(window_id: StaticWindowId, index: u1) u32 {
    return windowXid(window_id) + 2 + index;
}
fn presentEventXid(window_id: StaticWindowId) u32 {
    return windowXid(window_id) + 4;
}

const Opcode = struct {
    const CreateWindow = 1;
    const ChangeWindowAttributes = 2;
    const DestroyWindow = 4;
    const MapWindow = 8;
    const UnmapWindow = 10;
    const ConfigureWindow = 12;
    const InternAtom = 16;
    const ChangeProperty = 18;
    const GetProperty = 20;
    const CreatePixmap = 53;
    const FreePixmap = 54;
    const CreateGC = 55;
    const FreeGC = 60;
    const QueryExtension = 98;
    const GetKeyboardMapping = 101;
};

const Request = struct {
    opcode: u8,
    sequence: u16,
    bytes: [64]u8,
    len: usize,
    fn int(r: *const Request, comptime T: type, offset: usize) T {
        return std.mem.readInt(T, r.bytes[offset..][0..@sizeOf(T)], .little);
    }
};

const FakeServer = struct {
    listener: std.Io.net.Server,
    display_num: u16,
    stream: std.Io.net.Stream = undefined,
    write_buffer: [4096]u8 = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    in: [8192]u8 = undefined,
    in_len: usize = 0,
    /// the sequence of the last request received
    sequence: u16 = 0,

    fn listen() FakeServer {
        for (100..400) |display_num| {
            const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", @intCast(6000 + display_num)) catch unreachable;
            const listener = address.listen(server_io, .{}) catch |err| switch (err) {
                error.AddressInUse => continue,
                else => |e| std.debug.panic("listen failed with {t}", .{e}),
            };
            return .{ .listener = listener, .display_num = @intCast(display_num) };
        }
        @panic("no free X display port");
    }

    /// Accepts zin's connection and answers its setup request.
    fn acceptThread(server: *FakeServer) void {
        server.stream = server.listener.accept(server_io) catch |err| std.debug.panic("accept failed with {t}", .{err});
        server.writer = server.stream.writer(server_io, &server.write_buffer);
        var setup_request: [12]u8 = undefined;
        server.readExact(&setup_request);
        const auth_name_len = std.mem.readInt(u16, setup_request[6..8], .little);
        const auth_data_len = std.mem.readInt(u16, setup_request[8..10], .little);
        var auth: [512]u8 = undefined;
        server.readExact(auth[0 .. pad4(auth_name_len) + pad4(auth_data_len)]);

        const words = (@sizeOf(x11.Setup) - 8 + @sizeOf(x11.ScreenHeader) + @sizeOf(x11.ScreenDepth) + @sizeOf(x11.VisualType)) / 4;
        const setup: x11.Setup = .{
            .status = .success,
            .unused1 = 0,
            .version_major = 11,
            .version_minor = 0,
            .word_count = words,
            .release_number = 0,
            .resource_id_base = @fromBackingInt(resource_id_base),
            .resource_id_mask = @fromBackingInt(resource_id_mask),
            .motion_buffer_size = 0,
            .vendor_len = 0,
            .max_request_len = 0xffff,
            .root_screen_count = 1,
            .format_count = 0,
            .image_byte_order = @fromBackingInt(0),
            .bitmap_format_bit_order = 0,
            .bitmap_format_scanline_unit = 32,
            .bitmap_format_scanline_pad = 32,
            .min_keycode = min_keycode,
            .max_keycode = max_keycode,
            .unused2 = 0,
        };
        const screen: x11.ScreenHeader = .{
            .root = @fromBackingInt(root_window),
            .colormap = @fromBackingInt(0x20),
            .white_pixel = 0xffffff,
            .black_pixel = 0,
            .input_masks = 0,
            .pixel_width = 1000,
            .pixel_height = 1000,
            .mm_width = 100,
            .mm_height = 100,
            .min_installed_maps = 1,
            .max_installed_maps = 1,
            .root_visual = @fromBackingInt(0x21),
            .backing_stores = 0,
            .save_unders = 0,
            .root_depth = 24,
            .allowed_depth_count = 1,
        };
        const depth: x11.ScreenDepth = .{ .depth = 24, .unused0 = 0, .visual_type_count = 1, .unused1 = 0 };
        var visual: [@sizeOf(x11.VisualType)]u8 = @splat(0);
        std.mem.writeInt(u32, visual[0..4], 0x21, .little);
        visual[4] = 4; // TrueColor
        visual[5] = 8;
        std.mem.writeInt(u16, visual[6..8], 256, .little);
        std.mem.writeInt(u32, visual[8..12], 0xff0000, .little);
        std.mem.writeInt(u32, visual[12..16], 0x00ff00, .little);
        std.mem.writeInt(u32, visual[16..20], 0x0000ff, .little);
        server.write(std.mem.asBytes(&setup));
        server.write(std.mem.asBytes(&screen));
        server.write(std.mem.asBytes(&depth));
        server.write(&visual);
        server.flush();
    }

    fn close(server: *FakeServer) void {
        server.stream.close(server_io);
        server.listener.deinit(server_io);
    }

    fn readExact(server: *FakeServer, buf: []u8) void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = std.posix.read(server.stream.socket.handle, buf[off..]) catch |err| std.debug.panic("read failed with {t}", .{err});
            if (n == 0) @panic("zin closed the connection");
            off += n;
        }
    }
    /// Reads what's available within timeout_ms, returns false if nothing was.
    fn readSome(server: *FakeServer, timeout_ms: i32) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = server.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (0 == (std.posix.poll(&fds, timeout_ms) catch |err| std.debug.panic("poll failed with {t}", .{err}))) return false;
        if (server.in_len == server.in.len) @panic("fake server input buffer is full");
        const n = std.posix.read(server.stream.socket.handle, server.in[server.in_len..]) catch |err| std.debug.panic("read failed with {t}", .{err});
        if (n == 0) @panic("zin closed the connection");
        server.in_len += n;
        return true;
    }
    fn nextRequest(server: *FakeServer, timeout_ms: i32) ?Request {
        while (true) {
            if (server.in_len >= 4) {
                const len = @as(usize, std.mem.readInt(u16, server.in[2..4], .little)) * 4;
                if (len == 0) @panic("big requests aren't supported");
                if (server.in_len >= len) {
                    server.sequence +%= 1;
                    var request: Request = .{ .opcode = server.in[0], .sequence = server.sequence, .bytes = undefined, .len = len };
                    const copy = @min(len, request.bytes.len);
                    @memcpy(request.bytes[0..copy], server.in[0..copy]);
                    std.mem.copyForwards(u8, server.in[0 .. server.in_len - len], server.in[len..server.in_len]);
                    server.in_len -= len;
                    return request;
                }
            }
            if (!server.readSome(timeout_ms)) return null;
        }
    }
    /// Receives the next requests, which must have these opcodes.
    fn expectRequests(server: *FakeServer, comptime opcodes: []const u8) [opcodes.len]Request {
        var requests: [opcodes.len]Request = undefined;
        for (&requests, opcodes, 0..) |*request, opcode, i| {
            request.* = server.nextRequest(1000) orelse std.debug.panic(
                "expected request {} (opcode {}) of {any} but zin sent nothing more",
                .{ i, opcode, opcodes },
            );
            if (request.opcode != opcode) std.debug.panic(
                "expected request {} of {any} to be opcode {} but got {}",
                .{ i, opcodes, opcode, request.opcode },
            );
        }
        return requests;
    }
    fn expectNoRequests(server: *FakeServer) void {
        if (server.nextRequest(100)) |request| std.debug.panic("expected no requests but got opcode {}", .{request.opcode});
    }
    /// Receives requests that aren't checked, e.g. padding.
    fn skipRequests(server: *FakeServer, count: usize) void {
        for (0..count) |i| _ = server.nextRequest(1000) orelse std.debug.panic("expected {} requests but got {}", .{ count, i });
    }

    fn write(server: *FakeServer, bytes: []const u8) void {
        server.writer.interface.writeAll(bytes) catch @panic("write failed");
    }
    fn flush(server: *FakeServer) void {
        server.writer.interface.flush() catch @panic("flush failed");
    }

    fn reply(server: *FakeServer, sequence: u16, flexible: u8, body: [24]u8, extra: []const u8) void {
        std.debug.assert(extra.len % 4 == 0);
        var header: [8]u8 = undefined;
        header[0] = 1;
        header[1] = flexible;
        std.mem.writeInt(u16, header[2..4], sequence, .little);
        std.mem.writeInt(u32, header[4..8], @intCast(extra.len / 4), .little);
        server.write(&header);
        server.write(&body);
        server.write(extra);
        server.flush();
    }
    fn event(server: *FakeServer, code: u8, sequence: u16, fields: []const Field) void {
        var msg: [32]u8 = @splat(0);
        msg[0] = code;
        std.mem.writeInt(u16, msg[2..4], sequence, .little);
        for (fields) |f| switch (f.value) {
            .u8 => |v| msg[f.offset] = v,
            .u16 => |v| std.mem.writeInt(u16, msg[f.offset..][0..2], v, .little),
            .u32 => |v| std.mem.writeInt(u32, msg[f.offset..][0..4], v, .little),
        };
        server.write(&msg);
        server.flush();
    }
    fn xerror(server: *FakeServer, code: u8, sequence: u16, resource: u32, major: u8) void {
        server.event(0, sequence, &.{
            .{ .offset = 1, .value = .{ .u8 = code } },
            .{ .offset = 4, .value = .{ .u32 = resource } },
            .{ .offset = 10, .value = .{ .u8 = major } },
        });
    }

    fn destroyNotify(server: *FakeServer, sequence: u16, window: u32) void {
        server.destroyNotifyFrom(sequence, window, window);
    }
    /// `from` is the window whose StructureNotify or SubstructureNotify sent it
    fn destroyNotifyFrom(server: *FakeServer, sequence: u16, from: u32, window: u32) void {
        server.event(17, sequence, &.{ .{ .offset = 4, .value = .{ .u32 = from } }, .{ .offset = 8, .value = .{ .u32 = window } } });
    }
    fn propertyNotifyResourceManager(server: *FakeServer, sequence: u16) void {
        server.event(28, sequence, &.{
            .{ .offset = 4, .value = .{ .u32 = root_window } },
            .{ .offset = 8, .value = .{ .u32 = 23 } }, // RESOURCE_MANAGER
        });
    }
    fn presentComplete(server: *FakeServer, sequence: u16, window_id: StaticWindowId, serial: u32) void {
        var msg: [40]u8 = @splat(0);
        msg[0] = 35; // GenericEvent
        msg[1] = present_opcode;
        std.mem.writeInt(u16, msg[2..4], sequence, .little);
        std.mem.writeInt(u32, msg[4..8], 2, .little); // words past 32 bytes
        std.mem.writeInt(u16, msg[8..10], 1, .little); // CompleteNotify
        std.mem.writeInt(u32, msg[12..16], presentEventXid(window_id), .little);
        std.mem.writeInt(u32, msg[16..20], windowXid(window_id), .little);
        std.mem.writeInt(u32, msg[20..24], serial, .little);
        server.write(&msg);
        server.flush();
    }
    fn presentIdle(server: *FakeServer, sequence: u16, window_id: StaticWindowId, serial: u32, pixmap: u1) void {
        var msg: [32]u8 = @splat(0);
        msg[0] = 35; // GenericEvent
        msg[1] = present_opcode;
        std.mem.writeInt(u16, msg[2..4], sequence, .little);
        std.mem.writeInt(u16, msg[8..10], 2, .little); // IdleNotify
        std.mem.writeInt(u32, msg[12..16], presentEventXid(window_id), .little);
        std.mem.writeInt(u32, msg[16..20], windowXid(window_id), .little);
        std.mem.writeInt(u32, msg[20..24], serial, .little);
        std.mem.writeInt(u32, msg[24..28], pixmapXid(window_id, pixmap), .little);
        server.write(&msg);
        server.flush();
    }
    fn configureNotify(server: *FakeServer, sequence: u16, window: u32, width: u16, height: u16) void {
        server.configureNotifyFrom(sequence, window, window, width, height);
    }
    fn configureNotifyFrom(server: *FakeServer, sequence: u16, from: u32, window: u32, width: u16, height: u16) void {
        server.event(22, sequence, &.{
            .{ .offset = 4, .value = .{ .u32 = from } },
            .{ .offset = 8, .value = .{ .u32 = window } },
            .{ .offset = 20, .value = .{ .u16 = width } },
            .{ .offset = 22, .value = .{ .u16 = height } },
        });
    }
    fn expose(server: *FakeServer, sequence: u16, window: u32) void {
        server.event(12, sequence, &.{ .{ .offset = 4, .value = .{ .u32 = window } }, .{ .offset = 12, .value = .{ .u16 = 10 } }, .{ .offset = 14, .value = .{ .u16 = 10 } } });
    }
    fn keyPress(server: *FakeServer, sequence: u16, window: u32) void {
        server.event(2, sequence, &.{
            .{ .offset = 1, .value = .{ .u8 = keycode_a } },
            .{ .offset = 8, .value = .{ .u32 = root_window } },
            .{ .offset = 12, .value = .{ .u32 = window } },
            .{ .offset = 30, .value = .{ .u8 = 1 } },
        });
    }
    fn mappingNotify(server: *FakeServer, sequence: u16, request: enum(u8) { modifier, keyboard, pointer, _ }) void {
        server.event(34, sequence, &.{
            .{ .offset = 4, .value = .{ .u8 = @backingInt(request) } },
            .{ .offset = 5, .value = .{ .u8 = min_keycode } },
            .{ .offset = 6, .value = .{ .u8 = max_keycode - min_keycode + 1 } },
        });
    }
    /// Replies to a GetKeyboardMapping, `keysym_a` is keycode_a's first
    /// keysym. Real servers send 7 per keycode.
    fn replyKeymap(server: *FakeServer, sequence: u16, keysym_a: u32, per_keycode: u8) void {
        var keysyms: [(max_keycode - min_keycode + 1) * 7]u32 = @splat(0);
        keysyms[(keycode_a - min_keycode) * @as(usize, per_keycode)] = keysym_a;
        const count = (max_keycode - min_keycode + 1) * @as(usize, per_keycode);
        server.reply(sequence, per_keycode, @splat(0), std.mem.sliceAsBytes(keysyms[0..count]));
    }
    /// Checks a GetKeyboardMapping asks for every keycode.
    fn expectGetKeymap(request: Request) void {
        expectEq(u8, request.opcode, Opcode.GetKeyboardMapping);
        expectEq(u8, request.bytes[4], min_keycode);
        expectEq(u8, request.bytes[5], max_keycode - min_keycode + 1);
    }
    fn deleteWindow(server: *FakeServer, sequence: u16, window: u32) void {
        server.event(33, sequence, &.{
            .{ .offset = 1, .value = .{ .u8 = 32 } },
            .{ .offset = 4, .value = .{ .u32 = window } },
            .{ .offset = 8, .value = .{ .u32 = atom_wm_protocols } },
            .{ .offset = 12, .value = .{ .u32 = atom_wm_delete_window } },
        });
    }

    /// Receives the requests zin's connect sends.
    fn expectSetupRequests(server: *FakeServer) [6]Request {
        return server.expectRequests(&.{
            Opcode.QueryExtension,
            Opcode.InternAtom,
            Opcode.InternAtom,
            Opcode.GetKeyboardMapping,
            Opcode.ChangeWindowAttributes,
            Opcode.GetProperty,
        });
    }
    /// Replies to the setup requests, with RESOURCE_MANAGER `resources` if
    /// set, else just Xft.dpi `dpi`.
    fn replySetup(server: *FakeServer, requests: *const [6]Request, opt: struct {
        dpi: u32 = 96,
        present: bool = true,
        resources: ?[]const u8 = null,
        /// the reply says its value is this much longer than it is
        resources_overstated: u32 = 0,
    }) void {
        server.replySetupBeforeKeymap(requests, opt.present);
        server.replyKeymap(requests[3].sequence, 'a', 1);
        if (opt.resources) |resources| {
            server.replyResources(requests[5].sequence, resources, opt.resources_overstated);
        } else server.replyDpi(requests[5].sequence, opt.dpi);
    }
    fn replySetupBeforeKeymap(server: *FakeServer, requests: *const [6]Request, present: bool) void {
        var body: [24]u8 = @splat(0);
        body[0] = @intFromBool(present);
        body[1] = present_opcode;
        server.reply(requests[0].sequence, 0, body, &.{});
        body = @splat(0);
        std.mem.writeInt(u32, body[0..4], atom_wm_protocols, .little);
        server.reply(requests[1].sequence, 0, body, &.{});
        std.mem.writeInt(u32, body[0..4], atom_wm_delete_window, .little);
        server.reply(requests[2].sequence, 0, body, &.{});
    }
    /// Replies to a GetProperty RESOURCE_MANAGER with this database.
    fn replyResources(server: *FakeServer, sequence: u16, value: []const u8, overstated: u32) void {
        var header: [32]u8 = @splat(0);
        header[0] = 1; // Reply
        header[1] = 8; // format
        std.mem.writeInt(u16, header[2..4], sequence, .little);
        std.mem.writeInt(u32, header[4..8], @intCast(pad4(value.len) / 4), .little);
        std.mem.writeInt(u32, header[8..12], 31, .little); // STRING
        std.mem.writeInt(u32, header[16..20], @as(u32, @intCast(value.len)) + overstated, .little);
        server.write(&header);
        server.write(value);
        const padding = [_]u8{ 0, 0, 0 };
        server.write(padding[0 .. pad4(value.len) - value.len]);
        server.flush();
    }
    /// Replies to a GetProperty RESOURCE_MANAGER with Xft.dpi.
    fn replyDpi(server: *FakeServer, sequence: u16, dpi: u32) void {
        var value_buf: [32]u8 = undefined;
        server.replyResources(sequence, std.fmt.bufPrint(&value_buf, "Xft.dpi:\t{d}\n", .{dpi}) catch unreachable, 0);
    }
};
const Field = struct {
    offset: usize,
    value: union(enum) { u8: u8, u16: u16, u32: u32 },
};
fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

// --------------------------------------------------------------------------------
// stepping zin
// --------------------------------------------------------------------------------
fn conn() *zin.Connection {
    return &zin.platform.global.conn.?;
}
fn clientFlush() void {
    conn().sink.writer.flush() catch @panic("zin flush failed");
}
/// zin handles the next `count` messages from the server.
fn clientHandle(count: usize) void {
    for (0..count) |_| {
        const kind = conn().source.readKind() catch |err| std.debug.panic("readKind failed with {t}", .{err});
        zin.platform.x11HandleMessage(&conn().source, kind) catch |err| std.debug.panic("x11HandleMessage failed with {t}", .{err});
    }
}
fn clientUpdate() void {
    _ = clientUpdateCount();
}
/// Returns how many windows zin drew.
fn clientUpdateCount() usize {
    const count = zin.platform.x11UpdateWindows() catch @panic("x11UpdateWindows failed");
    clientFlush();
    return count;
}

/// Connects zin to a new fake server. The server's writer points into it,
/// so it can't move.
fn connect(server: *FakeServer) void {
    server.* = .listen();
    const thread = std.Thread.spawn(.{}, FakeServer.acceptThread, .{server}) catch @panic("spawn failed");
    var display_buf: [64]u8 = undefined;
    const display = std.fmt.bufPrintSentinel(&display_buf, "DISPLAY=127.0.0.1:{}", .{server.display_num}, 0) catch unreachable;
    var env = [_:null]?[*:0]const u8{ display.ptr, "XAUTHORITY=/nonexistent" };
    var err: zin.X11ConnectError = undefined;
    zin.x11Connect(.main, io, .{ .block = .{ .slice = &env } }, &err) catch std.debug.panic("connect failed: {f}", .{err});
    thread.join();
}
/// Connects zin to a new fake server and completes setup.
fn connectReady(server: *FakeServer, opt: struct { dpi: u32 = 96 }) void {
    connect(server);
    const requests = server.expectSetupRequests();
    server.replySetup(&requests, .{ .dpi = opt.dpi });
    clientHandle(5);
    std.debug.assert(conn().state == .ready);
}
fn disconnect(server: *FakeServer) void {
    zin.x11Disconnect(.main);
    server.close();
}

const default_create: zin.CreateWindowOptions = .{
    .title = "test",
    .size = .{ .client_points = .{ .x = 300, .y = 200 } },
    .pos = null,
};
fn createAndExpect(server: *FakeServer, window_id: StaticWindowId) Request {
    const log_len = callback_log.len;
    switch (window_id) {
        inline else => |w| zin.staticWindow(w).create(default_create) catch @panic("create failed"),
    }
    // once setup is done, create calls .created before it returns
    switch (window_id) {
        .a => std.debug.assert(callback_log.len == log_len + 1 and callback_log.entries[log_len] == .created),
        .b => std.debug.assert(callback_log.len == log_len),
    }
    clientFlush();
    const requests = server.expectRequests(&.{ Opcode.CreateWindow, Opcode.ChangeProperty, Opcode.CreateGC });
    return requests[0];
}

/// Sends requests the server ignores until zin's last request is `target`.
fn padTo(server: *FakeServer, target: u16) void {
    while (conn().sink.sequence != target) {
        var chunk: usize = 0;
        while (chunk < 200 and conn().sink.sequence != target) : (chunk += 1) {
            conn().sink.MapWindow(@fromBackingInt(root_window)) catch unreachable;
        }
        clientFlush();
        server.skipRequests(chunk);
    }
}

// --------------------------------------------------------------------------------
// scenarios
// --------------------------------------------------------------------------------

/// connect sends every setup request without waiting for a reply, and
/// windows the app creates meanwhile are created once the DPI is known, in
/// the order the app did things.
fn testSetupIsPipelined() void {
    var server: FakeServer = undefined;
    connect(&server);
    // connect returned before any reply was sent
    const setup_requests = server.expectSetupRequests();

    zin.staticWindow(.a).create(default_create) catch unreachable;
    zin.staticWindow(.a).show();
    zin.staticWindow(.b).create(default_create) catch unreachable;
    zin.staticWindow(.b).show();
    zin.staticWindow(.a).foreground();
    clientFlush();
    server.expectNoRequests();

    callback_log.clear();
    server.replySetup(&setup_requests, .{ .dpi = 192 });
    clientHandle(5);
    // after every queued request
    callback_log.expect(&.{.{ .created = .a }});
    clientFlush();
    const requests = server.expectRequests(&.{
        Opcode.CreateWindow,    Opcode.ChangeProperty, Opcode.CreateGC, Opcode.MapWindow,
        Opcode.CreateWindow,    Opcode.ChangeProperty, Opcode.CreateGC, Opcode.MapWindow,
        Opcode.ConfigureWindow,
    });
    expectEq(u32, requests[0].int(u32, 4), windowXid(.a));
    expectEq(u16, requests[0].int(u16, 16), 600);
    expectEq(u16, requests[0].int(u16, 18), 400);
    expectEq(u32, requests[1].int(u32, 8), atom_wm_protocols);
    expectEq(u32, requests[1].int(u32, 24), atom_wm_delete_window);
    expectEq(u32, requests[3].int(u32, 4), windowXid(.a));
    expectEq(u32, requests[4].int(u32, 4), windowXid(.b));
    expectEq(u32, requests[7].int(u32, 4), windowXid(.b));
    expectEq(u32, requests[8].int(u32, 4), windowXid(.a));

    // created at the DPI's size
    callback_log.clear();
    clientUpdate();
    callback_log.expect(&.{});
    expectSize(zin.staticWindow(.a).getClientSize(), .{ .x = 600, .y = 400 });

    zin.staticWindow(.a).destroy();
    zin.staticWindow(.b).destroy();
    disconnect(&server);
}

/// Events and errors still in flight for a window the app destroyed are
/// dropped, its ids are never used again.
fn testEventsForDestroyedWindowAreDropped() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    const create = createAndExpect(&server, .a);
    zin.staticWindow(.a).show();
    zin.staticWindow(.a).destroy();
    clientFlush();
    const requests = server.expectRequests(&.{ Opcode.MapWindow, Opcode.FreeGC, Opcode.DestroyWindow });
    callback_log.clear();

    const a = windowXid(.a);
    server.deleteWindow(create.sequence, a);
    server.configureNotify(create.sequence, a, 50, 50);
    server.expose(requests[0].sequence, a);
    server.keyPress(requests[0].sequence, a);
    server.xerror(3, requests[0].sequence, a, Opcode.MapWindow); // BadWindow
    server.destroyNotify(requests[2].sequence, a);
    server.keyPress(requests[2].sequence, a);
    clientHandle(7);
    clientUpdate();
    callback_log.expect(&.{});
    server.expectNoRequests();
    disconnect(&server);
}

/// When another client destroys a window, an app with destroyed_events is
/// told, and zin stops using a window whose app isn't. Errors for requests
/// the server got after the destroy are races, not app bugs.
fn testServerDestroysWindow() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    _ = createAndExpect(&server, .a);
    _ = createAndExpect(&server, .b);
    callback_log.clear();

    zin.staticWindow(.a).startTimerMillis({}, 1000);
    // requests zin sent before it learned the window was destroyed
    zin.staticWindow(.a).show();
    zin.staticWindow(.b).show();
    clientFlush();
    const maps = server.expectRequests(&.{ Opcode.MapWindow, Opcode.MapWindow });

    server.destroyNotify(server.sequence -% 2, windowXid(.a));
    server.destroyNotify(server.sequence -% 2, windowXid(.b));
    clientHandle(2);
    callback_log.expect(&.{.{ .destroyed = .{ .a, .external } }});
    // the window's timers go with it
    expectEq(bool, zin.platform.global.staticWindowCustomState(.a).timers[0] == null, true);
    // zin frees the resources it created with each window
    clientFlush();
    const frees = server.expectRequests(&.{ Opcode.FreeGC, Opcode.FreeGC });
    expectEq(u32, frees[0].int(u32, 4), gcXid(.a));
    expectEq(u32, frees[1].int(u32, 4), gcXid(.b));

    server.xerror(3, maps[0].sequence, windowXid(.a), Opcode.MapWindow); // BadWindow
    server.xerror(3, maps[1].sequence, windowXid(.b), Opcode.MapWindow);
    clientHandle(2);

    // b still exists for the app, zin sends nothing for it
    zin.staticWindow(.b).show();
    zin.staticWindow(.b).foreground();
    zin.staticWindow(.b).invalidate();
    clientUpdate();
    zin.staticWindow(.b).destroy();
    clientFlush();
    server.expectNoRequests();

    disconnect(&server);
}

/// Another client can destroy a window before the server gets the app's own
/// DestroyWindow. Errors for the app's requests are races.
fn testExternalDestroyRacesAppDestroy() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    _ = createAndExpect(&server, .a);
    zin.staticWindow(.a).show();
    zin.staticWindow(.a).destroy();
    clientFlush();
    const requests = server.expectRequests(&.{ Opcode.MapWindow, Opcode.FreeGC, Opcode.DestroyWindow });
    callback_log.clear();

    // the other client's destroy reached the server before MapWindow
    const a = windowXid(.a);
    server.destroyNotify(requests[0].sequence -% 1, a);
    server.xerror(3, requests[0].sequence, a, Opcode.MapWindow); // BadWindow
    server.xerror(3, requests[2].sequence, a, Opcode.DestroyWindow);
    clientHandle(3);
    callback_log.expect(&.{});
    disconnect(&server);
}

/// Another client can destroy a window before the server creates the
/// window's pixmaps, so zin's frees of them can fail too.
fn testExternalDestroyBeforePixmaps() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    const create = createAndExpect(&server, .a);
    const a = windowXid(.a);
    server.expose(server.sequence, a);
    clientHandle(1);
    clientUpdate();
    // the presenter's SelectInput, CreatePixmap x2, then PresentPixmap
    const draw = server.expectRequests(&.{ present_opcode, Opcode.CreatePixmap, Opcode.CreatePixmap, present_opcode });

    callback_log.clear();
    server.destroyNotify(create.sequence, a);
    clientHandle(1);
    callback_log.expect(&.{.{ .destroyed = .{ .a, .external } }});
    clientFlush();
    const frees = server.expectRequests(&.{ Opcode.FreePixmap, Opcode.FreePixmap, Opcode.FreeGC });

    server.xerror(3, draw[0].sequence, a, present_opcode); // BadWindow
    server.xerror(9, draw[1].sequence, a, Opcode.CreatePixmap); // BadDrawable
    server.xerror(9, draw[2].sequence, a, Opcode.CreatePixmap);
    server.xerror(3, draw[3].sequence, a, present_opcode);
    server.xerror(4, frees[0].sequence, frees[0].int(u32, 4), Opcode.FreePixmap); // BadPixmap
    server.xerror(4, frees[1].sequence, frees[1].int(u32, 4), Opcode.FreePixmap);
    clientHandle(6);
    disconnect(&server);
}

/// A write error the app didn't see yet (show swallows it) stops a resize.
fn testResizeAfterWriteError() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    const create = createAndExpect(&server, .a);
    const a = windowXid(.a);
    server.expose(server.sequence, a);
    clientHandle(1);
    clientUpdate();
    _ = server.expectRequests(&.{ present_opcode, Opcode.CreatePixmap, Opcode.CreatePixmap, present_opcode });

    conn().status = .write_failed;
    server.configureNotify(create.sequence, a, 50, 50);
    const kind = conn().source.readKind() catch |err| std.debug.panic("readKind failed with {t}", .{err});
    expectError(error.WriteFailed, zin.platform.x11HandleMessage(&conn().source, kind));
    conn().status = .running;
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// The app can destroy its window while drawing it.
fn testDestroyWhileDrawing() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    _ = createAndExpect(&server, .a);
    server.expose(server.sequence, windowXid(.a));
    clientHandle(1);
    callback_log.clear();
    on_draw_a = struct {
        fn f(_: DrawA) void {
            zin.staticWindow(.a).destroy();
        }
    }.f;
    clientUpdate();
    callback_log.expect(&.{ .{ .destroyed = .{ .a, .app } }, .{ .draw = .a } });
    // no PresentPixmap for the destroyed window
    _ = server.expectRequests(&.{
        present_opcode,       Opcode.CreatePixmap, Opcode.CreatePixmap,
        Opcode.FreePixmap,    Opcode.FreePixmap,   Opcode.FreeGC,
        Opcode.DestroyWindow,
    });
    server.expectNoRequests();
    disconnect(&server);
}

/// hide unmaps a window, and undoes a show still queued.
fn testHide() void {
    var server: FakeServer = undefined;
    connect(&server);
    const setup_requests = server.expectSetupRequests();
    // a write failure reaches create before zin can send anything
    conn().status = .write_failed;
    expectError(error.WriteFailed, zin.staticWindow(.a).create(default_create));
    conn().status = .running;
    zin.staticWindow(.a).create(default_create) catch unreachable;
    zin.staticWindow(.a).show();
    zin.staticWindow(.a).hide();
    zin.staticWindow(.b).create(default_create) catch unreachable;
    zin.staticWindow(.b).destroy();
    server.replySetup(&setup_requests, .{});
    clientHandle(5);
    clientFlush();
    // b was destroyed before zin sent anything for it
    _ = server.expectRequests(&.{ Opcode.CreateWindow, Opcode.ChangeProperty, Opcode.CreateGC });
    server.expectNoRequests();

    zin.staticWindow(.a).show();
    zin.staticWindow(.a).hide();
    clientFlush();
    _ = server.expectRequests(&.{ Opcode.MapWindow, Opcode.UnmapWindow });
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// The app can create a window again after something else destroyed it.
/// Errors for requests zin sent before it knew are still races.
fn testRecreateAfterExternalDestroy() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    _ = createAndExpect(&server, .a);
    zin.staticWindow(.a).show();
    clientFlush();
    const map = server.expectRequests(&.{Opcode.MapWindow})[0];
    callback_log.clear();

    const a = windowXid(.a);
    server.destroyNotify(map.sequence -% 1, a);
    clientHandle(1);
    callback_log.expect(&.{.{ .destroyed = .{ .a, .external } }});
    zin.staticWindow(.a).create(default_create) catch unreachable;
    zin.staticWindow(.a).show();
    clientFlush();
    const requests = server.expectRequests(&.{
        Opcode.FreeGC,    Opcode.CreateWindow, Opcode.ChangeProperty, Opcode.CreateGC,
        Opcode.MapWindow,
    });

    // the old window's MapWindow failed after the new window was created
    server.xerror(3, map.sequence, a, Opcode.MapWindow); // BadWindow
    clientHandle(1);
    callback_log.clear();
    server.keyPress(requests[4].sequence, a);
    clientHandle(1);
    callback_log.expect(&.{.{ .key = .a }});
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

fn repeat(comptime c: u8, comptime n: usize) *const [n]u8 {
    return comptime &@as([n]u8, @splat(c));
}

/// Connects with this resource database and returns the width zin creates
/// a 300 point wide window at, 300 at 96 DPI.
fn widthWithResources(resources: []const u8) u16 {
    var server: FakeServer = undefined;
    connect(&server);
    const setup_requests = server.expectSetupRequests();
    server.replySetup(&setup_requests, .{ .resources = resources });
    clientHandle(5);
    std.debug.assert(conn().state == .ready);
    // zin read all of the reply
    server.keyPress(setup_requests[5].sequence, root_window);
    clientHandle(1);
    const width = createAndExpect(&server, .a).int(u16, 16);
    zin.staticWindow(.a).destroy();
    disconnect(&server);
    return width;
}

/// zin finds Xft.dpi in the resource database however big it is, and says
/// what's wrong with a bad value instead of using it.
fn testResourceDatabase() void {
    // bigger than zin's read buffer, with the Xft.dpi line across its end
    {
        const buffer_size = zin.config.x11_read_buffer_size;
        var buf: [buffer_size * 3]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        while (w.end + "Xcursor.theme:\tAdwaita\n".len <= buffer_size - 10) w.writeAll("Xcursor.theme:\tAdwaita\n") catch unreachable;
        w.splatByteAll('z', buffer_size - 5 - w.end - ": 1\n".len) catch unreachable;
        w.writeAll(": 1\n") catch unreachable;
        std.debug.assert(w.end == buffer_size - 5);
        w.writeAll("Xft.dpi:\t144\n") catch unreachable;
        while (w.end + "Xcursor.size:\t24\n".len <= buf.len) w.writeAll("Xcursor.size:\t24\n") catch unreachable;
        expectEq(u16, widthWithResources(w.buffered()), 450);
        // and without one
        w.end = 0;
        while (w.end + "Xcursor.size:\t24\n".len <= buf.len) w.writeAll("Xcursor.size:\t24\n") catch unreachable;
        expectEq(u16, widthWithResources(w.buffered()), 300);
    }
    // a reply that says its value is longer than it is
    {
        var server: FakeServer = undefined;
        connect(&server);
        const setup_requests = server.expectSetupRequests();
        server.replySetup(&setup_requests, .{ .resources = "Xft.dpi:\t144\n", .resources_overstated = 40 });
        clientHandle(4);
        const kind = conn().source.readKind() catch |err| std.debug.panic("readKind failed with {t}", .{err});
        expectError(error.Protocol, zin.platform.x11HandleMessage(&conn().source, kind));
        zin.x11Disconnect(.main);
        server.close();
    }
    const cases = [_]struct { []const u8, u16 }{
        .{ "Xft.dpi:\t144", 450 }, // no newline at the end
        .{ "Xft.dpi:\t144\nXft.dpi:\t96\n", 450 }, // the first wins
        .{ "Xft.dpi:\t144  \r\n", 450 },
        .{ "Xft.dpi:\t144\t\n", 450 },
        .{ "Xft.dpi:\t24\n", 75 },
        .{ "Xft.dpi:\t960\n", 3000 },
        .{ "Xft.dpi:\t144\x00", 450 },
        .{ repeat(' ', 40) ++ "\t" ++ repeat(' ', 40) ++ "Xft.dpi:" ++ repeat(' ', 80) ++ "144\n", 450 },
        .{ "Xcursor.theme:" ++ repeat('x', 100) ++ "\nXft.dpi:\t144\n", 450 },
        // the longest line zin accepts is 63 bytes
        .{ "Xft.dpi:" ++ repeat('0', 63 - "Xft.dpi:144".len) ++ "144\n", 450 },
        // not found, or not a positive number: 96
        .{ "Xcursor.size:\t24\n", 300 },
        .{ "Xft.dpi:\tabc\n", 300 },
        .{ "Xft.dpi:" ++ repeat('0', 64 - "Xft.dpi:144".len) ++ "144\n", 300 },
        // the first 63 bytes would parse
        .{ "Xft.dpi:\t144" ++ repeat(' ', 100) ++ "7\n", 300 },
        .{ "Xft.dpi:\tabc\nXft.dpi:\t144\n", 300 }, // the first wins even if it's bad
        .{ "foo: " ++ repeat('x', 70) ++ "Xft.dpi:\t200\n", 300 }, // the rest of a long line isn't a line
        .{ "Xft.dpi:\t23.9\n", 300 },
        .{ "Xft.dpi:\t960.1\n", 300 },
        .{ "Xft.dpi:\t0.001\n", 300 },
        .{ "Xft.dpi:\t30000\n", 300 },
        .{ "Xft.dpi:\t3e9\n", 300 },
        .{ "Xft.dpi:\t0\n", 300 },
        .{ "Xft.dpi:\t-96\n", 300 },
        .{ "Xft.dpi:\tnan\n", 300 },
        .{ "Xft.dpi:\t1e40\n", 300 },
    };
    for (cases) |case| {
        const width = widthWithResources(case[0]);
        if (width != case[1]) std.debug.panic("resources '{s}': expected width {} but got {}", .{ case[0], case[1], width });
    }
}

/// zin reads the keymap again when it changes.
fn testKeymapChange() void {
    var server: FakeServer = undefined;
    // during setup, the setup GetKeyboardMapping's reply has the new map
    connect(&server);
    const setup_requests = server.expectSetupRequests();
    FakeServer.expectGetKeymap(setup_requests[3]);
    server.mappingNotify(0, .keyboard);
    clientHandle(1);
    clientFlush();
    server.expectNoRequests();
    server.replySetup(&setup_requests, .{});
    clientHandle(5);
    const create = createAndExpect(&server, .a);
    last_key_a = null;
    server.keyPress(create.sequence, windowXid(.a));
    clientHandle(1);
    expectEq(u32, @backingInt(last_key_a.?.vk), 'a');

    // the modifier and pointer maps aren't used
    server.mappingNotify(create.sequence, .modifier);
    server.mappingNotify(create.sequence, .pointer);
    clientHandle(2);
    clientFlush();
    server.expectNoRequests();

    server.mappingNotify(create.sequence, .keyboard);
    clientHandle(1);
    clientFlush();
    const get = server.expectRequests(&.{Opcode.GetKeyboardMapping})[0];
    FakeServer.expectGetKeymap(get);
    // a change while the reply is pending is in the reply
    server.mappingNotify(create.sequence, .keyboard);
    clientHandle(1);
    clientFlush();
    server.expectNoRequests();
    server.replyKeymap(get.sequence, 'b', 7);
    clientHandle(1);

    last_key_a = null;
    server.keyPress(get.sequence, windowXid(.a));
    clientHandle(1);
    expectEq(u32, @backingInt(last_key_a.?.vk), 'b');

    // a change after a write failed
    conn().status = .write_failed;
    server.mappingNotify(get.sequence, .keyboard);
    const write_failed_kind = conn().source.readKind() catch |err| std.debug.panic("readKind failed with {t}", .{err});
    expectError(error.WriteFailed, zin.platform.x11HandleMessage(&conn().source, write_failed_kind));
    conn().status = .running;

    // a failed GetKeyboardMapping
    server.mappingNotify(get.sequence, .keyboard);
    clientHandle(1);
    clientFlush();
    const failed = server.expectRequests(&.{Opcode.GetKeyboardMapping})[0];
    server.xerror(2, failed.sequence, 0, Opcode.GetKeyboardMapping); // BadValue
    const kind = conn().source.readKind() catch |err| std.debug.panic("readKind failed with {t}", .{err});
    expectError(error.X11GetKeymapFailed, zin.platform.x11HandleMessage(&conn().source, kind));

    // a request value zin doesn't know
    server.mappingNotify(failed.sequence, @fromBackingInt(@intCast(3)));
    const kind2 = conn().source.readKind() catch |err| std.debug.panic("readKind failed with {t}", .{err});
    expectError(error.X11UnexpectedMessage, zin.platform.x11HandleMessage(&conn().source, kind2));
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// The window manager's WM_DELETE_WINDOW is the app's close.
fn testClose() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    const create = createAndExpect(&server, .a);
    callback_log.clear();
    server.deleteWindow(create.sequence, windowXid(.a));
    clientHandle(1);
    callback_log.expect(&.{.{ .close = .a }});
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// A change to RESOURCE_MANAGER re-reads the DPI, and a new DPI tells the
/// windows with dpi_events.
fn testDpiChange() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    const create = createAndExpect(&server, .a);
    _ = createAndExpect(&server, .b);
    callback_log.clear();
    server.propertyNotifyResourceManager(create.sequence);
    clientHandle(1);
    clientFlush();
    const get = server.expectRequests(&.{Opcode.GetProperty})[0];
    server.replyDpi(get.sequence, 192);
    clientHandle(1);
    callback_log.expect(&.{.{ .dpi_change = .a }});

    // a failed GetProperty
    server.propertyNotifyResourceManager(get.sequence);
    clientHandle(1);
    clientFlush();
    const failed = server.expectRequests(&.{Opcode.GetProperty})[0];
    server.xerror(2, failed.sequence, 0, Opcode.GetProperty); // BadValue
    const kind = conn().source.readKind() catch |err| std.debug.panic("readKind failed with {t}", .{err});
    expectError(error.X11GetDpiFailed, zin.platform.x11HandleMessage(&conn().source, kind));
    zin.staticWindow(.a).destroy();
    zin.staticWindow(.b).destroy();
    disconnect(&server);
}

/// Present tells zin when the frame it presented is done and its pixmap is
/// idle, so the next frame can draw.
fn testPresentNextFrame() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    _ = createAndExpect(&server, .a);
    server.expose(server.sequence, windowXid(.a));
    clientHandle(1);
    callback_log.clear();
    expectEq(usize, clientUpdateCount(), 1);
    const first = server.expectRequests(&.{ present_opcode, Opcode.CreatePixmap, Opcode.CreatePixmap, present_opcode });

    // the first frame is still presenting
    zin.staticWindow(.a).invalidate();
    expectEq(usize, clientUpdateCount(), 0);
    server.expectNoRequests();

    server.presentComplete(first[3].sequence, .a, 1);
    server.presentIdle(first[3].sequence, .a, 1, 0);
    clientHandle(2);
    expectEq(usize, clientUpdateCount(), 1);
    _ = server.expectRequests(&.{present_opcode});
    callback_log.expect(&.{ .{ .draw = .a }, .{ .draw = .a } });
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// A DestroyNotify or ConfigureNotify zin gets from another window's
/// StructureNotify isn't about its window, e.g. if the app selected
/// SubstructureNotify on the root itself.
fn testStructureEventsFromOtherWindows() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    const create = createAndExpect(&server, .a);
    callback_log.clear();
    server.destroyNotifyFrom(create.sequence, root_window, windowXid(.a));
    server.configureNotifyFrom(create.sequence, root_window, windowXid(.a), 50, 50);
    clientHandle(2);
    clientUpdate();
    // still a's window, at its size
    server.keyPress(create.sequence, windowXid(.a));
    clientHandle(1);
    callback_log.expect(&.{.{ .key = .a }});
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// zin writes nothing once the app quit or a write failed, and the app's
/// create gets the write failure.
fn testNoWritesAfterQuitOrWriteFailure() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    const create = createAndExpect(&server, .a);
    server.expose(create.sequence, windowXid(.a));
    clientHandle(1);
    on_draw_a = struct {
        fn f(d: DrawA) void {
            const before = conn().sink.sequence;
            conn().status = .write_failed;
            d.clear();
            d.rect(.{ .left = 0, .top = 0, .right = 1, .bottom = 1 }, .{ .r = 0, .g = 0, .b = 0 });
            expectEq(u16, conn().sink.sequence, before);
            conn().status = .quit_requested;
        }
    }.f;
    clientUpdate();
    // the presenter's SelectInput and CreatePixmap x2, no PresentPixmap
    _ = server.expectRequests(&.{ present_opcode, Opcode.CreatePixmap, Opcode.CreatePixmap });
    server.expectNoRequests();

    // a damaged window isn't drawn after a write failure, mainLoop returns it
    conn().status = .write_failed;
    callback_log.clear();
    zin.staticWindow(.a).invalidate();
    if (zin.platform.x11UpdateWindows()) |_| @panic("x11UpdateWindows succeeded") else |err| expectEq(anyerror, err, error.WriteFailed);
    callback_log.expect(&.{});
    conn().status = .quit_requested;

    const before = conn().sink.sequence;
    zin.staticWindow(.a).show();
    zin.staticWindow(.a).hide();
    zin.staticWindow(.a).foreground();
    zin.staticWindow(.a).invalidate();
    clientUpdate();
    server.propertyNotifyResourceManager(create.sequence);
    server.mappingNotify(create.sequence, .keyboard);
    clientHandle(2);
    // and the app gets no more callbacks
    callback_log.clear();
    server.configureNotify(create.sequence, windowXid(.a), 50, 50);
    clientHandle(1);
    expectEq(usize, clientUpdateCount(), 0);
    callback_log.expect(&.{});
    conn().status = .write_failed;
    expectError(error.WriteFailed, zin.staticWindow(.b).create(default_create));
    conn().status = .quit_requested;
    zin.staticWindow(.b).create(default_create) catch unreachable;
    zin.staticWindow(.b).destroy();
    zin.staticWindow(.a).destroy();
    expectEq(u16, conn().sink.sequence, before);
    conn().status = .running;
    disconnect(&server);
}

/// A signal handler running while mainLoop waits isn't an error.
fn testSignalWhileWaiting() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    _ = createAndExpect(&server, .a);
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = struct {
            fn f(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {}
        }.f },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(.USR1, &act, null);
    const main_tid = std.os.linux.gettid();
    const thread = std.Thread.spawn(.{}, struct {
        fn f(tid: std.os.linux.pid_t) void {
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            _ = std.os.linux.tgkill(std.os.linux.getpid(), tid, .USR1);
        }
    }.f, .{main_tid}) catch @panic("spawn failed");
    zin.staticWindow(.a).startTimerMillis({}, 200);
    on_timer_a = struct {
        fn f() void {
            zin.quitMainLoop();
        }
    }.f;
    zin.mainLoop() catch |err| std.debug.panic("mainLoop failed with {t}", .{err});
    thread.join();
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// The app's own destroy tells the app too.
fn testAppDestroyIsReported() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    _ = createAndExpect(&server, .a);
    callback_log.clear();
    zin.staticWindow(.a).destroy();
    callback_log.expect(&.{.{ .destroyed = .{ .a, .app } }});
    disconnect(&server);
}

/// Any client can send events to any window.
fn testEventsForUnknownWindowsAreIgnored() void {
    var server: FakeServer = undefined;
    connectReady(&server, .{});
    callback_log.clear();
    server.keyPress(server.sequence, 0x123);
    server.keyPress(server.sequence, windowXid(.a)); // not created
    server.deleteWindow(server.sequence, windowXid(.a));
    server.destroyNotify(server.sequence, windowXid(.a));
    clientHandle(4);
    callback_log.expect(&.{});
    disconnect(&server);
}

fn testConnectionClosed() void {
    // during setup
    {
        var server: FakeServer = undefined;
        connect(&server);
        _ = server.expectSetupRequests();
        server.stream.close(server_io);
        expectError(error.X11ConnectionClosed, zin.mainLoop());
        zin.x11Disconnect(.main);
        server.listener.deinit(server_io);
    }
    // after setup
    {
        var server: FakeServer = undefined;
        connectReady(&server, .{});
        server.stream.close(server_io);
        expectError(error.X11ConnectionClosed, zin.mainLoop());
        zin.x11Disconnect(.main);
        server.listener.deinit(server_io);
    }
    // after quitMainLoop it's not an error
    {
        var server: FakeServer = undefined;
        connectReady(&server, .{});
        zin.quitMainLoop();
        zin.mainLoop() catch |err| std.debug.panic("mainLoop failed with {t}", .{err});
        disconnect(&server);
    }
    // the requests the app made before quitting are sent, and it gets no
    // more callbacks
    {
        var server: FakeServer = undefined;
        connectReady(&server, .{});
        const create = createAndExpect(&server, .a);
        callback_log.clear();
        server.deleteWindow(create.sequence, windowXid(.a));
        server.keyPress(create.sequence, windowXid(.a));
        on_close_a = struct {
            fn f() void {
                zin.staticWindow(.a).show();
                zin.quitMainLoop();
                zin.staticWindow(.a).hide();
            }
        }.f;
        zin.mainLoop() catch |err| std.debug.panic("mainLoop failed with {t}", .{err});
        callback_log.expect(&.{.{ .close = .a }});
        _ = server.expectRequests(&.{Opcode.MapWindow});
        zin.staticWindow(.a).destroy();
        disconnect(&server);
    }
    // before setup is done
    {
        var server: FakeServer = undefined;
        connect(&server);
        _ = server.expectSetupRequests();
        zin.quitMainLoop();
        _ = zin.platform.x11Sink() catch |err| std.debug.panic("x11Sink failed with {t}", .{err});
        zin.mainLoop() catch |err| std.debug.panic("mainLoop failed with {t}", .{err});
        disconnect(&server);
    }
    // a write error before the app quits doesn't matter anymore
    {
        var server: FakeServer = undefined;
        connectReady(&server, .{});
        conn().status = .write_failed;
        zin.quitMainLoop();
        zin.mainLoop() catch |err| std.debug.panic("mainLoop failed with {t}", .{err});
        disconnect(&server);
    }
}

fn testSetupErrors() void {
    {
        var server: FakeServer = undefined;
        connect(&server);
        const requests = server.expectSetupRequests();
        server.xerror(2, requests[0].sequence, 0, Opcode.QueryExtension); // BadValue
        expectError(error.X11SetupRequestFailed, zin.mainLoop());
        disconnect(&server);
    }
    {
        var server: FakeServer = undefined;
        connect(&server);
        const requests = server.expectSetupRequests();
        server.replySetup(&requests, .{ .present = false });
        expectError(error.X11PresentNotAvailable, zin.mainLoop());
        disconnect(&server);
    }
    {
        var server: FakeServer = undefined;
        connect(&server);
        const requests = server.expectSetupRequests();
        server.replySetupBeforeKeymap(&requests, true);
        server.xerror(2, requests[3].sequence, 0, Opcode.GetKeyboardMapping); // BadValue
        expectError(error.X11SetupRequestFailed, zin.mainLoop());
        disconnect(&server);
    }
    {
        var server: FakeServer = undefined;
        connect(&server);
        const requests = server.expectSetupRequests();
        server.replySetupBeforeKeymap(&requests, true);
        server.replyKeymap(requests[3].sequence, 'a', 1);
        server.xerror(2, requests[5].sequence, 0, Opcode.GetProperty); // BadValue
        expectError(error.X11SetupRequestFailed, zin.mainLoop());
        disconnect(&server);
    }
}

/// A change during setup needs no request while setup's request for it is
/// pending, since its reply comes after the change.
fn testChangesDuringSetup() void {
    var server: FakeServer = undefined;
    connect(&server);
    const requests = server.expectSetupRequests();
    server.replySetupBeforeKeymap(&requests, true);
    server.mappingNotify(requests[2].sequence, .keyboard);
    server.propertyNotifyResourceManager(requests[2].sequence);
    clientHandle(5);
    clientFlush();
    server.expectNoRequests();

    // after setup's keymap reply, a change needs a new request
    server.replyKeymap(requests[3].sequence, 'a', 1);
    server.mappingNotify(requests[3].sequence, .keyboard);
    server.propertyNotifyResourceManager(requests[3].sequence);
    clientHandle(3);
    clientFlush();
    const get = server.expectRequests(&.{Opcode.GetKeyboardMapping})[0];
    server.replyDpi(requests[5].sequence, 96);
    server.replyKeymap(get.sequence, 'b', 1);
    clientHandle(2);
    std.debug.assert(conn().state == .ready);
    const create = createAndExpect(&server, .a);
    last_key_a = null;
    server.keyPress(create.sequence, windowXid(.a));
    clientHandle(1);
    expectEq(u32, @backingInt(last_key_a.?.vk), 'b');
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

/// The server answers requests in order, so a setup reply or error that
/// skips one is a protocol error.
fn testSetupOutOfOrder() void {
    {
        var server: FakeServer = undefined;
        connect(&server);
        const requests = server.expectSetupRequests();
        server.replySetupBeforeKeymap(&requests, true);
        server.replyDpi(requests[5].sequence, 96);
        expectError(error.X11UnexpectedMessage, zin.mainLoop());
        disconnect(&server);
    }
    {
        var server: FakeServer = undefined;
        connect(&server);
        const requests = server.expectSetupRequests();
        server.xerror(2, requests[3].sequence, 0, Opcode.GetKeyboardMapping); // BadValue
        expectError(error.X11UnexpectedMessage, zin.mainLoop());
        disconnect(&server);
    }
    {
        var server: FakeServer = undefined;
        connect(&server);
        const requests = server.expectSetupRequests();
        server.replySetupBeforeKeymap(&requests, true);
        server.replyKeymap(requests[3].sequence, 'a', 1);
        // ChangeWindowAttributes has no reply
        server.reply(requests[4].sequence, 0, @splat(0), &.{});
        expectError(error.X11UnexpectedMessage, zin.mainLoop());
        disconnect(&server);
    }
}

/// The raw access functions create the queued windows first, so a request
/// the app sends itself on its window reaches the server after CreateWindow.
fn testRawAccessFinishesSetup() void {
    var server: FakeServer = undefined;
    connect(&server);
    const setup_requests = server.expectSetupRequests();
    zin.staticWindow(.a).create(default_create) catch unreachable;
    server.replySetup(&setup_requests, .{});
    const sink = zin.platform.x11Sink() catch |err| std.debug.panic("x11Sink failed with {t}", .{err});
    sink.MapWindow(conn().staticWindowId(.a)) catch unreachable;
    clientFlush();
    _ = server.expectRequests(&.{ Opcode.CreateWindow, Opcode.ChangeProperty, Opcode.CreateGC, Opcode.MapWindow });
    zin.staticWindow(.a).destroy();
    disconnect(&server);
}

// --------------------------------------------------------------------------------
// app bugs zin panics on, one per process, see build.zig
// --------------------------------------------------------------------------------
fn runPanicCase(name: []const u8) void {
    const Case = enum {
        @"panic-show-not-created",
        @"panic-invalidate-not-created",
        @"panic-get-client-size-not-created",
        @"panic-start-timer-not-created",
        @"panic-create-twice",
        @"panic-create-unregistered",
        @"panic-unregister-while-created",
        @"panic-disconnect-while-created",
        @"panic-use-after-failure",
        @"panic-show-after-destroyed",
        @"panic-hide-not-created",
        @"panic-create-after-destroy",
        @"panic-show-after-app-destroy",
        @"panic-error-after-recreate",
        @"panic-error-after-recreate-wrap",
        @"panic-error-after-race-cleared",
        @"panic-error-not-naming-resource",
        @"panic-draw-after-destroy",
        @"panic-create-after-failure",
        @"panic-raw-access-after-failure",
        @"panic-main-loop-after-setup-failed",
        @"panic-show-after-failure",
        @"panic-get-client-size-before-created",
        @"panic-error-after-app-destroy-race",
        @"panic-setup-error-without-reply",
    };
    const case = std.meta.stringToEnum(Case, name) orelse std.debug.panic("unknown case '{s}'", .{name});
    var server: FakeServer = undefined;
    switch (case) {
        .@"panic-main-loop-after-setup-failed",
        .@"panic-get-client-size-before-created",
        .@"panic-setup-error-without-reply",
        => connect(&server),
        else => connectReady(&server, .{}),
    }
    switch (case) {
        .@"panic-show-not-created" => zin.staticWindow(.a).show(),
        .@"panic-invalidate-not-created" => zin.staticWindow(.a).invalidate(),
        .@"panic-get-client-size-not-created" => _ = zin.staticWindow(.a).getClientSize(),
        // the size depends on the DPI, which isn't known yet
        .@"panic-get-client-size-before-created" => {
            _ = server.expectSetupRequests();
            zin.staticWindow(.a).create(default_create) catch unreachable;
            _ = zin.staticWindow(.a).getClientSize();
        },
        .@"panic-start-timer-not-created" => zin.staticWindow(.a).startTimerMillis({}, 10),
        .@"panic-create-twice" => {
            _ = createAndExpect(&server, .a);
            zin.staticWindow(.a).create(default_create) catch unreachable;
        },
        .@"panic-create-unregistered" => {
            zin.staticWindow(.b).unregisterClass();
            zin.staticWindow(.b).create(default_create) catch unreachable;
        },
        .@"panic-unregister-while-created" => {
            _ = createAndExpect(&server, .a);
            zin.staticWindow(.a).unregisterClass();
        },
        .@"panic-disconnect-while-created" => {
            _ = createAndExpect(&server, .a);
            zin.x11Disconnect(.main);
        },
        .@"panic-use-after-failure",
        .@"panic-create-after-failure",
        .@"panic-raw-access-after-failure",
        .@"panic-show-after-failure",
        => {
            if (case == .@"panic-show-after-failure") _ = createAndExpect(&server, .a);
            server.stream.close(server_io);
            expectError(error.X11ConnectionClosed, zin.mainLoop());
            switch (case) {
                .@"panic-use-after-failure" => zin.mainLoop() catch {},
                .@"panic-create-after-failure" => zin.staticWindow(.a).create(default_create) catch {},
                .@"panic-raw-access-after-failure" => _ = zin.platform.x11Sink() catch {},
                .@"panic-show-after-failure" => zin.staticWindow(.a).show(),
                else => unreachable,
            }
        },
        // finishSetup returning an error ends the connection too
        .@"panic-main-loop-after-setup-failed" => {
            const requests = server.expectSetupRequests();
            server.replySetup(&requests, .{ .present = false });
            if (zin.platform.x11Sink()) |_| @panic("x11Sink succeeded") else |err| expectEq(anyerror, err, error.X11PresentNotAvailable);
            zin.mainLoop() catch {};
        },
        .@"panic-show-after-destroyed" => {
            _ = createAndExpect(&server, .a);
            server.destroyNotify(server.sequence, windowXid(.a));
            clientHandle(1);
            zin.staticWindow(.a).show();
        },
        .@"panic-hide-not-created" => zin.staticWindow(.a).hide(),
        .@"panic-create-after-destroy" => {
            _ = createAndExpect(&server, .a);
            zin.staticWindow(.a).destroy();
            zin.staticWindow(.a).create(default_create) catch unreachable;
        },
        .@"panic-show-after-app-destroy" => {
            _ = createAndExpect(&server, .a);
            zin.staticWindow(.a).destroy();
            zin.staticWindow(.a).show();
        },
        // the race mark doesn't cover the window created again
        .@"panic-error-after-recreate", .@"panic-error-after-recreate-wrap" => {
            // puts the race mark at 65535 and the new ChangeProperty at 1
            if (case == .@"panic-error-after-recreate-wrap") padTo(&server, 65531);
            const create = createAndExpect(&server, .a);
            server.destroyNotify(create.sequence, windowXid(.a));
            clientHandle(1);
            zin.staticWindow(.a).create(default_create) catch unreachable;
            clientFlush();
            const requests = server.expectRequests(&.{ Opcode.FreeGC, Opcode.CreateWindow, Opcode.ChangeProperty, Opcode.CreateGC });
            if (case == .@"panic-error-after-recreate-wrap") std.debug.assert(requests[2].sequence == 1);
            server.xerror(3, requests[2].sequence, windowXid(.a), Opcode.ChangeProperty); // BadWindow
            clientHandle(1);
        },
        // Once the server is past the race mark it's forgotten, so a full
        // wrap later it doesn't cover a newer error that looks older.
        .@"panic-error-after-race-cleared" => {
            const create = createAndExpect(&server, .a);
            server.destroyNotify(create.sequence, windowXid(.a));
            clientHandle(1);
            zin.staticWindow(.a).create(default_create) catch unreachable;
            clientFlush();
            const requests = server.expectRequests(&.{ Opcode.FreeGC, Opcode.CreateWindow, Opcode.ChangeProperty, Opcode.CreateGC });
            const mark = requests[0].sequence;
            server.keyPress(requests[1].sequence, windowXid(.a));
            clientHandle(1);
            padTo(&server, mark +% 5);
            server.xerror(3, mark -% 2, windowXid(.a), Opcode.MapWindow); // BadWindow
            clientHandle(1);
        },
        // once the server is past the app's DestroyWindow, an error for the
        // window is for a request the app sent after destroying it
        .@"panic-error-after-app-destroy-race" => {
            _ = createAndExpect(&server, .a);
            zin.staticWindow(.a).destroy();
            clientFlush();
            _ = server.expectRequests(&.{ Opcode.FreeGC, Opcode.DestroyWindow });
            const sink = zin.platform.x11Sink() catch unreachable;
            sink.MapWindow(conn().staticWindowId(.a)) catch unreachable;
            clientFlush();
            const map = server.expectRequests(&.{Opcode.MapWindow})[0];
            server.keyPress(map.sequence, windowXid(.a));
            clientHandle(1);
            server.xerror(3, map.sequence, windowXid(.a), Opcode.MapWindow); // BadWindow
            clientHandle(1);
        },
        // only Window, Pixmap, Drawable and GC errors name a resource
        // an error for a setup request without a reply isn't a setup reply
        .@"panic-setup-error-without-reply" => {
            const requests = server.expectSetupRequests();
            server.replySetupBeforeKeymap(&requests, true);
            server.replyKeymap(requests[3].sequence, 'a', 1);
            server.xerror(3, requests[4].sequence, root_window, Opcode.ChangeWindowAttributes); // BadWindow
            clientHandle(5);
        },
        .@"panic-error-not-naming-resource" => {
            const create = createAndExpect(&server, .a);
            zin.staticWindow(.a).destroy();
            server.xerror(8, create.sequence, windowXid(.a), Opcode.CreateWindow); // BadMatch
            clientHandle(1);
        },
        .@"panic-draw-after-destroy" => {
            _ = createAndExpect(&server, .a);
            server.expose(server.sequence, windowXid(.a));
            clientHandle(1);
            on_draw_a = struct {
                fn f(d: DrawA) void {
                    zin.staticWindow(.a).destroy();
                    d.clear();
                }
            }.f;
            clientUpdate();
        },
    }
    std.debug.panic("case '{s}' didn't panic", .{name});
}

// --------------------------------------------------------------------------------
fn expectEq(comptime T: type, actual: T, expected: T) void {
    if (actual != expected) std.debug.panic("expected {} but got {}", .{ expected, actual });
}
fn expectSize(actual: zin.XY(i32), expected: zin.XY(i32)) void {
    if (actual.x != expected.x or actual.y != expected.y) std.debug.panic(
        "expected size {}x{} but got {}x{}",
        .{ expected.x, expected.y, actual.x, actual.y },
    );
}
fn expectError(expected: anyerror, actual: anyerror!void) void {
    if (actual) |_| {
        std.debug.panic("expected error {t} but succeeded", .{expected});
    } else |err| if (err != expected) std.debug.panic("expected error {t} but got {t}", .{ expected, err });
}

pub fn main(init: std.process.Init.Minimal) void {
    zin.processInit(.{}) catch |err| std.debug.panic("processInit failed with {t}", .{err});
    if (zin.threadInit(.main)) |err| std.debug.panic("{f}", .{err});
    defer zin.threadDeinit(.main);

    zin.staticWindow(.a).registerClass(.{ .callback = callbackA, .win32_name = zin.L("A"), .macos_view = "A" }, .win32_no_icons);
    zin.staticWindow(.b).registerClass(.{ .callback = callbackB, .win32_name = zin.L("B"), .macos_view = "B" }, .win32_no_icons);

    var args = init.args.iterate();
    _ = args.next();
    if (args.next()) |case| return runPanicCase(case);

    const scenarios = .{
        .{ "setup is pipelined", testSetupIsPipelined, .{} },
        .{ "events for a destroyed window are dropped", testEventsForDestroyedWindowAreDropped, .{} },
        .{ "server destroys window", testServerDestroysWindow, .{} },
        .{ "external destroy races app destroy", testExternalDestroyRacesAppDestroy, .{} },
        .{ "external destroy before pixmaps", testExternalDestroyBeforePixmaps, .{} },
        .{ "resize after a write error", testResizeAfterWriteError, .{} },
        .{ "recreate after external destroy", testRecreateAfterExternalDestroy, .{} },
        .{ "resource database", testResourceDatabase, .{} },
        .{ "keymap change", testKeymapChange, .{} },
        .{ "close", testClose, .{} },
        .{ "dpi change", testDpiChange, .{} },
        .{ "present next frame", testPresentNextFrame, .{} },
        .{ "structure events from other windows", testStructureEventsFromOtherWindows, .{} },
        .{ "destroy while drawing", testDestroyWhileDrawing, .{} },
        .{ "hide", testHide, .{} },
        .{ "no writes after quit or a write failure", testNoWritesAfterQuitOrWriteFailure, .{} },
        .{ "signal while waiting", testSignalWhileWaiting, .{} },
        .{ "app destroy is reported", testAppDestroyIsReported, .{} },
        .{ "events for unknown windows are ignored", testEventsForUnknownWindowsAreIgnored, .{} },
        .{ "connection closed", testConnectionClosed, .{} },
        .{ "setup errors", testSetupErrors, .{} },
        .{ "setup out of order", testSetupOutOfOrder, .{} },
        .{ "changes during setup", testChangesDuringSetup, .{} },
        .{ "raw access finishes setup", testRawAccessFinishesSetup, .{} },
    };
    inline for (scenarios) |scenario| {
        std.debug.print("x11 test: {s}\n", .{scenario[0]});
        @call(.auto, scenario[1], scenario[2]);
    }
    std.debug.print("x11 tests passed\n", .{});
}
