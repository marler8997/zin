const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

const root = @import("root");

const BoundedArray = @import("bounded_array.zig").BoundedArray;
pub const Rgb8 = @import("Rgb8.zig");

const win32 = @import("win32.zig");
const x11 = @import("x11.zig");

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

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

pub const X11VisualType = switch (platform_kind) {
    .x11 => platform.x11.VisualType,
    else => void,
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

pub const ProcessInitError = error{
    NSApplicationLoadFailed,
    Win32NoDpiAwareness,
    Win32OnlySystemDpiAwareness,
    X11WsaStartupFailed,
    X11DisplayInvalidWtf8,
    X11BadDisplay,
    OutOfMemory,
};
pub const ProcessInitOptions = struct {
    /// By default the x11 backend calls WSAStartup on windows, set this to false
    /// to disable this behavior.
    x11_wsa_startup: if (platform_kind == .x11) bool else void = if (platform_kind == .x11) true else {},
};
// one-time process initialization
pub const processInit = platform.processInit;

/// For Windows, enforces that the executable is DPI-aware.  This is supposed
/// to be configured via a manifets file embedded inside the executable so rather
/// than provide a function that enables it, instead we provide a function that
/// will enforce that it's been properly configured.
pub fn enforceDpiAware() DpiAwarenessError!void {
    if (builtin.os.tag == .windows) try win32.enforceDpiAware();
}

pub const X11ConnectError = if (platform_kind == .x11) x11.ConnectError else struct {
    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    fn formatNew(err: X11ConnectError, writer: *std.Io.Writer) error{WriteFailed}!void {
        _ = err;
        _ = writer;
        unreachable;
    }
    fn formatLegacy(
        err: X11ConnectError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = err;
        _ = fmt;
        _ = options;
        _ = writer;
        unreachable;
    }
};
/// Connects to the X11 server, for non-X11 platforms does nothing.
pub const x11Connect = if (platform_kind == .x11) x11.connect else connectNoOp;
fn connectNoOp(err: *X11ConnectError) error{X11Connect}!void {
    _ = err;
}
pub const x11Disconnect = if (platform_kind == .x11) x11.disconnect else disconnectNoOp;
fn disconnectNoOp() void {}

pub const ConnectionPtr = if (platform_kind == .x11) *Connection else void;

pub const WindowClass = platform.WindowClass;
pub const DynamicWindow = platform.DynamicWindow;

pub const VirtualKey = platform.VirtualKey;
pub const ScanCode = platform.ScanCode;

pub const KeyState = enum { up, down };
pub const Win32ExtendedKey = switch (platform_kind) {
    .win32 => bool,
    else => void,
};
pub const X11KeyMask = switch (platform_kind) {
    .x11 => platform.x11.KeyButtonMask,
    else => void,
};
pub const MacOSKeyMods = switch (platform_kind) {
    .macos => platform.NSEventModifierFlags,
    else => void,
};

pub const UnicodeKeyboardState = struct {
    array: switch (platform_kind) {
        .win32 => [256]u8,
        .x11, .macos => void,
    },

    pub fn init() UnicodeKeyboardState {
        return switch (platform_kind) {
            .win32 => {
                var result: UnicodeKeyboardState = .{ .array = undefined };
                if (0 == platform.win32.GetKeyboardState(&result.array)) platform.win32.panicWin32(
                    "GetKeyboardState",
                    platform.win32.GetLastError(),
                );
                return result;
            },
            .x11, .macos => .{ .array = {} },
        };
    }

    pub fn ref(self: *UnicodeKeyboardState) UnicodeKeyboardStateRef {
        return switch (platform_kind) {
            .win32 => &self.array,
            .x11, .macos => {},
        };
    }
};
pub const UnicodeKeyboardStateRef = switch (platform_kind) {
    .win32 => *[256]u8,
    .x11, .macos => void,
};

pub const max_wtf16_per_key = 16;
// I think it's max 4 bytes per wtf16 character?
pub const max_utf8_per_key = max_wtf16_per_key * 4;

pub const Key = struct {
    kind: enum { up, down, down_repeat },
    vk: VirtualKey,
    scan_code: ScanCode,
    win32_extended: Win32ExtendedKey,
    x11_mask: X11KeyMask,
    macos_mods: MacOSKeyMods,

    pub fn utf8(
        key: *const Key,
        keyboard_state: UnicodeKeyboardStateRef,
    ) BoundedArray(u8, max_utf8_per_key) {
        switch (platform_kind) {
            .win32 => {
                var char_buf: [max_wtf16_per_key + 1]u16 = undefined;

                // release control key when getting the unicode character of this key
                const save_control_state = keyboard_state[@intFromEnum(platform.win32.VK_CONTROL)];
                keyboard_state[@intFromEnum(platform.win32.VK_CONTROL)] = 0;
                const unicode_result = platform.win32.ToUnicode(
                    @intFromEnum(key.vk),
                    @intFromEnum(key.scan_code),
                    keyboard_state,
                    @ptrCast(&char_buf),
                    max_wtf16_per_key,
                    0,
                );
                keyboard_state[@intFromEnum(platform.win32.VK_CONTROL)] = save_control_state;
                if (unicode_result < 0) return .{ .len = 0, .buffer = undefined }; // dead key
                if (unicode_result > max_wtf16_per_key) {
                    for (char_buf[0..@intCast(unicode_result)], 0..) |codepoint, i| {
                        std.log.err("UNICODE[{}] 0x{x} {d}", .{ i, codepoint, unicode_result });
                    }
                    std.debug.panic("ToUnicode returned {} characters", .{unicode_result});
                }
                var result: BoundedArray(u8, max_utf8_per_key) = .{ .len = 0, .buffer = undefined };
                const len = std.unicode.utf16LeToUtf8(&result.buffer, char_buf[0..@intCast(unicode_result)]) catch @panic("ToUnicode generated invalid utf16le");
                std.debug.assert(len <= max_utf8_per_key);
                result.len = len;
                return result;
            },
            .x11 => {
                if (x11.asciiFromKeysym(key.vk)) |ascii| {
                    var result: BoundedArray(u8, max_utf8_per_key) = .{ .len = 1, .buffer = undefined };
                    result.buffer[0] = ascii;
                    return result;
                }
                return .{};
            },
            .macos => {
                // For macOS, we'll provide a simple ASCII mapping for now
                // A more complete implementation would use the NSEvent's characters method
                var result: BoundedArray(u8, max_utf8_per_key) = .{ .len = 0, .buffer = undefined };

                // Only process key down events
                if (key.kind == .up) return result;

                // Simple ASCII mapping for common keys
                const ascii: ?u8 = switch (key.vk) {
                    .a => 'a',
                    .b => 'b',
                    .c => 'c',
                    .d => 'd',
                    .e => 'e',
                    .f => 'f',
                    .g => 'g',
                    .h => 'h',
                    .i => 'i',
                    .j => 'j',
                    .k => 'k',
                    .l => 'l',
                    .m => 'm',
                    .n => 'n',
                    .o => 'o',
                    .p => 'p',
                    .q => 'q',
                    .r => 'r',
                    .s => 's',
                    .t => 't',
                    .u => 'u',
                    .v => 'v',
                    .w => 'w',
                    .x => 'x',
                    .y => 'y',
                    .z => 'z',
                    .@"0" => '0',
                    .@"1" => '1',
                    .@"2" => '2',
                    .@"3" => '3',
                    .@"4" => '4',
                    .@"5" => '5',
                    .@"6" => '6',
                    .@"7" => '7',
                    .@"8" => '8',
                    .@"9" => '9',
                    .space => ' ',
                    .@"return" => '\n',
                    .tab => '\t',
                    .period => '.',
                    .comma => ',',
                    .semicolon => ';',
                    .slash => '/',
                    .backslash => '\\',
                    .minus => '-',
                    .equal => '=',
                    .left_bracket => '[',
                    .right_bracket => ']',
                    .quote => '\'',
                    .grave => '`',
                    else => null,
                };

                if (ascii) |ch| {
                    result.buffer[0] = ch;
                    result.len = 1;
                }

                return result;
            },
        }
    }
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
    down: MouseButtonsDown,
};
pub const MouseButtonsDown = struct {
    left: bool,
    right: bool,
    middle: bool,
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
    window_size_events: bool,
    key_events: bool,
    mouse_events: bool,
    timers: union(enum) {
        none,
        one,
        type: type,
    },
    background: Rgb8,
    dynamic_background: bool,
    win32: win32.WindowConfig,
    x11: x11.WindowConfig,

    pub fn TimerId(self: WindowConfigData) type {
        return switch (self.timers) {
            .none => noreturn,
            .one => void,
            .type => |t| {
                checkTimersType(t);
                return t;
            },
        };
    }
};

fn checkTimersType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"enum" => {
            const fields = std.meta.fields(T);
            if (fields.len == 0) @compileError("cannot set timers to enum type with 0 values, use .none instead");
            if (fields.len == 1) @compileError("cannot set timers to enum type with 1 value, use .one instead");
        },
        .int => {},
        else => @compileError("unsupported timers type: " ++ @tagName(T)),
    }
}

pub fn intFromTimerId(comptime Int: type, comptime TimerId: type, id: TimerId) Int {
    return switch (@typeInfo(TimerId)) {
        .void => return platform.min_timer_id_int,
        .@"enum" => @intFromEnum(id),
        else => @compileError("unsupported TimerId type: " ++ @typeName(TimerId)),
    };
}
pub fn timerIdFromInt(comptime TimerId: type, int: anytype) TimerId {
    return switch (@typeInfo(TimerId)) {
        .void => {
            std.debug.assert(int == platform.min_timer_id_int);
            return {};
        },
        .@"enum" => @enumFromInt(int),
        else => @compileError("unsupported TimerId type: " ++ @typeName(TimerId)),
    };
}

pub fn Callback(window_config: WindowConfig) type {
    return makeTaggedUnion(
        &([_]Field{
            .{ .name = "close", .type = void },
            .{ .name = "draw", .type = Draw(window_config) },
        } ++ (if (window_config.data().window_size_events) [_]Field{
            .{ .name = "window_size", .type = XY },
        } else [_]Field{}) ++ (if (window_config.data().key_events) [_]Field{
            .{ .name = "key", .type = Key },
        } else [_]Field{}) ++ (if (window_config.data().mouse_events) [_]Field{
            .{ .name = "mouse", .type = Mouse },
        } else [_]Field{}) ++ (switch (window_config.data().timers) {
            .none => [_]Field{},
            .one => [_]Field{.{ .name = "timer", .type = void }},
            .type => |t| [_]Field{.{ .name = "timer", .type = t }},
        }) ++ (if (window_config.data().win32.set_cursor_callback) [_]Field{
            .{ .name = "win32_set_cursor", .type = struct { result_ref: *isize, wparam: usize, lparam: isize } },
        } else [_]Field{})),
    );
}

pub const MaybeWin32Icon = struct {
    handle: Handle,

    pub const Handle = switch (builtin.os.tag) {
        .windows => ?platform.win32.HICON,
        else => void,
    };

    pub const none: MaybeWin32Icon = switch (builtin.os.tag) {
        .windows => .{ .handle = null },
        else => .{ .handle = {} },
    };
    pub fn init(handle: Handle) MaybeWin32Icon {
        return .{ .handle = handle };
    }
};

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

pub const HWND = switch (builtin.os.tag) {
    .windows => platform.win32.HWND,
    else => *anyopaque,
};
pub const WPARAM = switch (builtin.os.tag) {
    .windows => platform.win32.WPARAM,
    else => *anyopaque,
};
pub const LPARAM = switch (builtin.os.tag) {
    .windows => platform.win32.LPARAM,
    else => *anyopaque,
};
pub const LRESULT = switch (builtin.os.tag) {
    .windows => platform.win32.LRESULT,
    else => *anyopaque,
};
const MaybeWndProc = switch (builtin.os.tag) {
    .windows => ?*const fn (
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) callconv(.winapi) LRESULT,
    else => void,
};
pub const WindowClassRuntimeConfig = struct {
    win32_icon_large: MaybeWin32Icon,
    win32_icon_small: MaybeWin32Icon,
    win32_wndproc: MaybeWndProc = switch (builtin.os.tag) {
        .windows => null,
        else => {},
    },

    pub const win32_no_icons: WindowClassRuntimeConfig = .{
        .win32_icon_large = .none,
        .win32_icon_small = .none,
    };
};

pub const registerDynamicWindowClass = platform.registerDynamicWindowClass;

pub const WindowSizeInit = union(enum) {
    default,
    client_pixels: XY,
    client_points: XY,
    window_pixels: XY,
    window_points: XY,
};
pub const CreateWindowOptions = struct {
    title: [:0]const u8,
    size: WindowSizeInit,
    pos: ?XY,
    platform: platform.CreateWindowOptions = .{},
};

pub const CreateWindowError = error{
    WriteFailed,
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

pub const PolygonPoint = platform.PolygonPoint;

/// Helper for managing mouse targets and button states
pub fn MouseState(comptime MouseTarget: type, comptime opt: struct {
    left: bool,
    right: bool,
    middle: bool,
}) type {
    return struct {
        maybe_interaction: ?TargetInteraction = null,

        pub const Buttons = struct {
            left: if (opt.left) KeyState else void = if (opt.left) .up else {},
            right: if (opt.right) KeyState else void = if (opt.right) .up else {},
            middle: if (opt.middle) KeyState else void = if (opt.middle) .up else {},
        };
        const TargetInteraction = struct {
            target: MouseTarget,
            buttons: Buttons = .{},
        };

        const Self = @This();

        pub fn getLeft(state: *const Self) KeyState {
            const interaction = &(state.maybe_interaction orelse return .up);
            return interaction.left;
        }
        pub fn getTarget(state: *const Self) ?MouseTarget {
            const interaction = &(state.maybe_interaction orelse return null);
            return interaction.target;
        }

        /// returns true if target has changed
        pub fn updateTarget(state: *Self, maybe_target: ?MouseTarget) bool {
            if (maybe_target) |target| {
                if (state.maybe_interaction) |*interaction| {
                    if (std.meta.eql(interaction.target, target)) return false; // no update
                }
                state.maybe_interaction = .{ .target = target };
                return true; // updated
            }
            if (null == state.maybe_interaction) return false; // no update
            state.maybe_interaction = null;
            return true; // updated
        }

        pub fn updateLeft(state: *Self, key_state: KeyState) bool {
            const interaction = &(state.maybe_interaction orelse return false);
            if (interaction.buttons.left == key_state) return false;
            interaction.buttons.left = key_state;
            return true;
        }
    };
}

/// returns a formatter that will print the enum value name if it exists,
/// otherwise, it prints a question mark followed by the value, i.e. ?(123)
pub fn fmtEnum(enum_value: anytype) FmtEnum(@TypeOf(enum_value)) {
    return .{ .value = enum_value };
}
pub fn FmtEnum(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        pub const format = if (zig_atleast_15) formatNew else formatLegacy;
        fn formatNew(self: Self, writer: *std.Io.Writer) error{WriteFailed}!void {
            if (@typeInfo(T).@"enum".is_exhaustive) {
                try writer.print("{s}", .{@tagName(self.value)});
            } else {
                @setEvalBranchQuota(@typeInfo(T).@"enum".fields.len);
                if (std.enums.tagName(T, self.value)) |name| {
                    try writer.print("{s}", .{name});
                } else {
                    try writer.print("?({d})", .{@intFromEnum(self.value)});
                }
            }
        }
        fn formatLegacy(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            if (@typeInfo(T).@"enum".is_exhaustive) {
                try writer.print("{s}", .{@tagName(self.value)});
            } else if (std.enums.tagName(T, self.value)) |name| {
                try writer.print("{s}", .{name});
            } else {
                try writer.print("?({d})", .{@intFromEnum(self.value)});
            }
        }
    };
}
