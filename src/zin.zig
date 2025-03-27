const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

const root = @import("root");

pub const Rgb8 = @import("Rgb8.zig");

const macos = @import("macos.zig");
const win32 = @import("win32.zig");
const x11 = @import("x11.zig");

pub const using_x11 = build_options.x11;

pub const platform = if (build_options.x11) @import("x11.zig") else switch (builtin.os.tag) {
    .windows => @import("win32.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("todo"),
};

pub const Config = @import("Config.zig");
pub const config = if (@hasDecl(root, "zin_config")) root.zin_config else .{};
pub const StaticWindowId = config.StaticWindowId;

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

threadlocal var thread_is_panicing = false;
pub fn panic(
    panic_opt: struct {
        title: [:0]const u8,
        win32_style: @import("win32").everything.MESSAGEBOX_STYLE = .{ .ICONASTERISK = 1 },
        // TODO: add option/logic to include the stacktrace in the messagebox
    },
) type {
    return std.debug.FullPanic(struct {
        pub fn panic(
            msg: []const u8,
            ret_addr: ?usize,
        ) noreturn {
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
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic);
}

pub fn getX11Display() []const u8 {
    return @import("x11").getDisplay();
}
pub const ConnectError = error{
    OutOfMemory,
    // The X11 DISPLAY is invalid, call getX11Display to get the display string
    BadX11Display,
    AccessDenied,
    SystemResources,
    UnknownHostName,
    ConnectFailed,
    ConnectResetByPeer,
    BrokenPipe,
    NetworkSubsystemFailed,
};
pub const ConnectOptions = struct {
    scratch: union(enum) {
        // use a separate scrach arena backed by the standard page allocator
        tmp_arena,
        // share the persistent allocator
        share,
        custom: std.mem.Allocator,
    } = .tmp_arena,
};
pub const Connection = if (using_x11) x11.Connection else struct {
    pub fn deinit(self: Connection, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const StaticWindow = platform.StaticWindow;
pub const createStaticWindow = platform.createStaticWindow;
pub const staticWindow = platform.staticWindow;

/// Connects to the X11 server, for non-X11 platforms does nothing.
pub const connect = if (using_x11) x11.connect else connectNoOp;
fn connectNoOp(allocator: std.mem.Allocator, options: ConnectOptions) ConnectError!void {
    _ = allocator;
    _ = options;
}
pub const disconnect = if (using_x11) x11.disconnect else disconnectNoOp;
fn disconnectNoOp(allocator: std.mem.Allocator) void {
    _ = allocator;
}

pub const ConnectionPtr = if (using_x11) *Connection else void;

pub const WindowClass = platform.WindowClass;
pub const DynamicWindow = platform.DynamicWindow;

pub const KeyState = enum { up, down };
pub const Key = struct {
    state: KeyState,
    vk: platform.VirtualKey,
    // todo: scancode
};

pub fn XY(comptime T: type) type {
    return struct { x: T, y: T };
}

pub const MousePosition = XY(platform.MouseCoord);
pub const Mouse = struct {
    position: MousePosition,
};

pub const Size = XY(platform.SizeCoord);

const Field = struct {
    name: [:0]const u8,
    type: type,
};
fn makeTaggedUnion(fields: []const Field) type {
    const EnumField = std.builtin.Type.EnumField;
    const UnionField = std.builtin.Type.UnionField;

    var enum_fields: [fields.len]EnumField = undefined;
    var union_fields: [fields.len]UnionField = undefined;

    for (fields, 0..) |field, i| {
        enum_fields[i] = .{ .name = field.name, .value = i };
        union_fields[i] = .{ .name = field.name, .type = field.type, .alignment = @alignOf(field.type) };
    }

    return @Type(std.builtin.Type{
        .@"union" = .{
            .layout = .auto,
            .tag_type = @Type(std.builtin.Type{ .@"enum" = .{
                .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                .fields = &enum_fields,
                .decls = &.{},
                .is_exhaustive = true,
            } }),
            .fields = &union_fields,
            .decls = &.{},
        },
    });
}

pub const WindowConfig = union(enum) {
    static: StaticWindowId,
    dynamic: WindowConfigData,
    pub fn data(self: WindowConfig) WindowConfigData {
        return switch (self) {
            .static => |id| id.getConfig(),
            .dynamic => |d| d,
        };
    }
};

pub const WindowConfigData = struct {
    key_events: bool,
    mouse_events: bool,
    timers: bool,
    win32: win32.WindowConfig,
};
pub fn Callback(window_config: WindowConfig) type {
    return makeTaggedUnion(
        &([_]Field{
            .{ .name = "close", .type = void },
            .{ .name = "draw", .type = Draw },
        } ++ (if (window_config.data().key_events) [_]Field{
            .{ .name = "key", .type = Key },
        } else [_]Field{}) ++ (if (window_config.data().mouse_events) [_]Field{
            .{ .name = "mouse", .type = Mouse },
        } else [_]Field{}) ++ (if (window_config.data().timers) [_]Field{
            .{ .name = "timer", .type = usize },
        } else [_]Field{})),
    );
}

pub fn WindowClassDefinition(window_config: WindowConfig) type {
    return switch (window_config) {
        .static => struct {
            callback: fn (Callback(window_config)) void,
            win32_name: [*:0]const u16,
        },
        .dynamic => struct {
            callback: fn (DynamicWindow, Callback(window_config)) void,
            // every distinct window class must also have a distict win32 name
            win32_name: [*:0]const u16,
        },
    };
}

pub const registerWindowClass = platform.registerWindowClass;

pub const CreateWindowOptions = struct {
    class: WindowClass,
    title: []const u8,
    size: union(enum) {
        default,
        client: XY(platform.SizeCoord),
        window: XY(platform.SizeCoord),
    } = .default,
};
pub const CreateWindowError = error{
    BrokenPipe,
    ConnectionResetByPeer,
    SystemResources,
    NetworkSubsystemFailed,
};
pub const createDynamicWindow = platform.createDynamicWindow;

pub const Draw = platform.Draw;

pub const mainLoop = platform.mainLoop;
pub const quitMainLoop = platform.quitMainLoop;

pub const clear = platform.clear;
pub const text = platform.text;
