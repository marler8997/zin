const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

const root = @import("root");

pub const Rgb8 = @import("Rgb8.zig");

const win32 = @import("win32.zig");
const x11 = @import("x11.zig");

const PlatformKind = enum {
    x11,
    win32,
    macos,
};
pub const platform_kind: PlatformKind = if (build_options.x11) .x11 else switch (builtin.os.tag) {
    .windows => .win32,
    .macos => .macos,
    else => @compileError("with x11 being false, unsupported OS: " ++ @tagName(builtin.os.tag)),
};

pub const platform = switch (platform_kind) {
    .x11 => @import("x11.zig"),
    .win32 => @import("win32.zig"),
    .macos => @import("macos.zig"),
};

pub const Config = @import("Config.zig");
pub const config = if (@hasDecl(root, "zin_config")) root.zin_config else .{};
pub const StaticWindowId = config.StaticWindowId;

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const PanicOptions = struct {
    title: [:0]const u8,
    win32_style: @import("win32").everything.MESSAGEBOX_STYLE = .{ .ICONASTERISK = 1 },
    // TODO: add option/logic to include the stacktrace in the messagebox
};
pub const panic = platform.panic;

pub fn getX11Display() []const u8 {
    return @import("x11").getDisplay();
}
pub const ConnectError = error{
    // The X11 DISPLAY is invalid, call getX11Display to get the display string
    BadX11Display,

    BadXauthEnv,
    XauthEnvFileNotFound,

    AccessDenied,
    SystemResources,
    InputOutput,
    SymLinkLoop,
    FileBusy,

    UnknownHostName,
    ConnectionRefused,
    ConnectResetByPeer,
    BrokenPipe,
    NetworkSubsystemFailed,

    Unexpected,

    OutOfMemory,
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
pub const Connection = if (platform_kind == .x11) x11.Connection else struct {
    pub fn deinit(self: Connection, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const staticWindow = platform.staticWindow;

pub const DpiAwarenessError = error{
    NoDpiAwareness,
    OnlySystemDpiAwareness,
};

pub fn loadAppKit() error{NSApplicationLoadFailed}!void {
    if (platform_kind == .macos) {
        try platform.loadAppKit();
    }
}

/// For Windows, enforces that the executable is DPI-aware.  This is supposed
/// to be configured via a manifets file embedded inside the executable so rather
/// than provide a function that enables it, instead we provide a function that
/// will enforce that it's been properly configured.
pub fn enforceDpiAware() DpiAwarenessError!void {
    if (builtin.os.tag == .windows) try win32.enforceDpiAware();
}

/// Connects to the X11 server, for non-X11 platforms does nothing.
pub const connect = if (platform_kind == .x11) x11.connect else connectNoOp;
fn connectNoOp(allocator: std.mem.Allocator, options: ConnectOptions) ConnectError!void {
    _ = allocator;
    _ = options;
}
pub const disconnect = if (platform_kind == .x11) x11.disconnect else disconnectNoOp;
fn disconnectNoOp(allocator: std.mem.Allocator) void {
    _ = allocator;
}

pub const ConnectionPtr = if (platform_kind == .x11) *Connection else void;

pub const WindowClass = platform.WindowClass;
pub const DynamicWindow = platform.DynamicWindow;

pub const KeyState = enum { up, down };
pub const Key = struct {
    state: KeyState,
    vk: platform.VirtualKey,
    // todo: scancode
};

pub const XY = struct {
    x: i32,
    y: i32,
};

pub const MouseButtonId = enum { left, right, middle };
pub const MouseButtonState = struct {
    id: MouseButtonId,
    state: KeyState,
};
pub const Mouse = struct {
    position: XY,
    button: ?MouseButtonState,
};

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
    background: Rgb8,
    dynamic_background: bool,
    win32: win32.WindowConfig,
};
pub fn Callback(window_config: WindowConfig) type {
    return makeTaggedUnion(
        &([_]Field{
            .{ .name = "close", .type = void },
            .{ .name = "draw", .type = Draw(window_config) },
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
            callback: *const fn (Callback(window_config)) void,
            win32_name: [*:0]const u16,
            macos_view: [*:0]const u8,
        },
        .dynamic => struct {
            callback: fn (DynamicWindow, Callback(window_config)) void,
            // every distinct window class must also have a distict win32 name
            win32_name: [*:0]const u16,
            macos_view: [*:0]const u8,
        },
    };
}

pub const registerDynamicWindowClass = platform.registerDynamicWindowClass;

pub const WindowSizeInit = union(enum) {
    default,
    client: XY,
    window: XY,
};
pub const CreateWindowOptions = struct {
    title: [:0]const u8,
    size: WindowSizeInit = .default,
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

// Good for checking API misuse that's likely to only ever happen during initial development
pub fn debugPanicOrUnreachable(comptime fmt: []const u8, args: anytype) noreturn {
    switch (builtin.mode) {
        .Debug => std.debug.panic(fmt, args),
        else => unreachable,
    }
}

pub fn scale(comptime T: type, value: T, s: f32) T {
    return switch (@typeInfo(T)) {
        .int => @intFromFloat(@round(@as(f32, @floatFromInt(value)) * s)),
        else => @compileError("scale does not support type " ++ @typeName(T)),
    };
}

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn ltrb(
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    ) Rect {
        return .{ .left = left, .top = top, .right = right, .bottom = bottom };
    }

    pub fn ltwh(
        left: i32,
        top: i32,
        width: i32,
        height: i32,
    ) Rect {
        return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
    }

    pub fn contains(self: Rect, p: XY) bool {
        return p.x >= self.left and p.x < self.right and p.y >= self.top and p.y < self.bottom;
    }
};
