const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin.zig");
pub const win32 = @import("win32").everything;
const windowmsg = @import("windowmsg.zig");

const zig_atleast_15 = builtin.zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

threadlocal var thread_is_panicing = false;
pub fn panic(panic_opt: zin.PanicOptions) type {
    return std.debug.FullPanic(struct {
        pub fn panic(
            msg: []const u8,
            ret_addr: ?usize,
        ) noreturn {
            if (!thread_is_panicing) {
                thread_is_panicing = true;
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                const oom_msg = "allocate error message failed";
                const msg_z: [:0]const u8 = if (zig_atleast_15) std.fmt.allocPrintSentinel(
                    arena.allocator(),
                    "{s}",
                    .{msg},
                    0,
                ) catch oom_msg else std.fmt.allocPrintZ(arena.allocator(), "{s}", .{msg}) catch oom_msg;
                _ = @import("win32").everything.MessageBoxA(null, msg_z, panic_opt.title, panic_opt.win32_style);
            }
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic);
}

pub fn enforceDpiAware() zin.DpiAwarenessError!void {
    var awareness: win32.PROCESS_DPI_AWARENESS = undefined;
    {
        const hr = win32.GetProcessDpiAwareness(null, &awareness);
        if (hr < 0) std.debug.panic(
            "GetProcessDpiAwareness failed, hresult=0x{x}",
            .{@as(u32, @bitCast(hr))},
        );
    }
    switch (awareness) {
        .DPI_UNAWARE => return error.NoDpiAwareness,
        .SYSTEM_DPI_AWARE => return error.OnlySystemDpiAwareness,
        .PER_MONITOR_DPI_AWARE => {},
    }
}

pub const min_timer_id_int = 1;

pub const WindowConfig = struct {
    render: union(enum) {
        gdi: struct {
            use_backbuffer: bool = true,
        },
    } = .{ .gdi = .{} },
    set_cursor_callback: bool = false,
    default_window_proc: ?fn (hwnd: win32.HWND, msg: u32, wparam: usize, lparam: isize) isize = null,
};

pub const WindowClass = struct {
    atom: u16,
    pub fn unregister(self: WindowClass) void {
        if (0 == win32.UnregisterClassW(
            @ptrFromInt(self.atom),
            win32.GetModuleHandleW(null),
        )) win32.panicWin32("UnregisterClass", win32.GetLastError());
    }
};
pub fn registerDynamicWindowClass(
    comptime config: zin.WindowConfigData,
    comptime def: zin.WindowClassDefinition(.{ .dynamic = config }),
    runtime_config: zin.WindowClassRuntimeConfig,
) WindowClass {
    return registerWindowClass(.{ .dynamic = config }, def, runtime_config);
}

fn registerWindowClass(
    comptime window_config: zin.WindowConfig,
    comptime def: zin.WindowClassDefinition(window_config),
    runtime_config: zin.WindowClassRuntimeConfig,
) WindowClass {
    var c: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        // TODO: create a option to enable/disable double clicks,
        //       enabling them will change how window events are sent
        // .DBLCLKS = 1
        .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
        .lpfnWndProc = makeWndProc(window_config, def),
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = runtime_config.win32_icon_large.handle,
        .hIconSm = runtime_config.win32_icon_small.handle,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = def.win32_name,
    };
    const atom = win32.RegisterClassExW(&c);
    if (atom == 0) win32.panicWin32(
        "RegisterClass",
        win32.GetLastError(),
    );
    return .{ .atom = atom };
}

pub const DynamicWindow = Window;
const Window = enum(usize) {
    _,
    fn asHwnd(self: Window) win32.HWND {
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn destroy(self: Window) void {
        if (0 == win32.DestroyWindow(self.asHwnd())) win32.panicWin32(
            "DestroyWindow",
            win32.GetLastError(),
        );
    }
    pub fn getClientSize(self: Window) zin.XY {
        const size = win32.getClientSize(self.asHwnd());
        return .{ .x = size.cx, .y = size.cy };
    }
    pub fn show(self: Window) void {
        _ = win32.ShowWindow(self.asHwnd(), .{ .SHOWNORMAL = 1 });
    }
    pub fn foreground(self: Window) void {
        if (0 == win32.SetForegroundWindow(self.asHwnd()))
            win32.panicWin32("SetForegroundWindow", win32.GetLastError());
    }
    pub fn invalidate(self: Window) void {
        win32.invalidateHwnd(self.asHwnd());
    }
    pub fn startTimer(self: Window, id: usize, millis: u32) void {
        if (0 == win32.SetTimer(self.asHwnd(), id, millis, null))
            win32.panicWin32("SetTimer", win32.GetLastError());
    }
};

fn windowFromHwnd(hwnd: win32.HWND) Window {
    return @enumFromInt(@intFromPtr(hwnd));
}

pub const max_window_title = 1000;
pub fn calcTitleLen(title: []const u8) usize {
    return std.unicode.calcWtf16LeLen(title) catch |e| std.debug.panic(
        "invalid window title ({s})",
        .{@errorName(e)},
    );
}

const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".fields.len;
const global = struct {
    var static_classes: [static_window_count]?WindowClass = @splat(null);
    var static_windows: [static_window_count]?Window = @splat(null);
};

pub fn staticWindow(comptime window_id: zin.StaticWindowId) type {
    return struct {
        const Self = @This();

        pub fn hwnd() win32.HWND {
            return global.static_windows[@intFromEnum(window_id)].?.asHwnd();
        }

        pub fn registerClass(
            comptime def: zin.WindowClassDefinition(.{ .static = window_id }),
            config: zin.WindowClassRuntimeConfig,
        ) void {
            std.debug.assert(global.static_classes[@intFromEnum(window_id)] == null);
            global.static_classes[@intFromEnum(window_id)] = registerWindowClass(.{ .static = window_id }, def, config);
        }
        pub fn unregisterClass() void {
            global.static_classes[@intFromEnum(window_id)].?.unregister();
        }
        pub fn create(opt: zin.CreateWindowOptions) zin.CreateWindowError!void {
            std.debug.assert(global.static_windows[@intFromEnum(window_id)] == null);
            global.static_windows[@intFromEnum(window_id)] = windowFromHwnd(try createWindow(
                global.static_classes[@intFromEnum(window_id)] orelse zin.debugPanicOrUnreachable(
                    "registerClass was not called for static window '{s}'",
                    .{@tagName(window_id)},
                ),
                &opt,
            ));
        }
        pub fn destroy() void {
            global.static_windows[@intFromEnum(window_id)].?.destroy();
        }
        pub fn getClientSize() zin.XY {
            return global.static_windows[@intFromEnum(window_id)].?.getClientSize();
        }
        pub fn show() void {
            global.static_windows[@intFromEnum(window_id)].?.show();
        }
        pub fn foreground() void {
            global.static_windows[@intFromEnum(window_id)].?.foreground();
        }
        pub fn invalidate() void {
            global.static_windows[@intFromEnum(window_id)].?.invalidate();
        }
        pub fn startTimer(id: window_id.getConfig().TimerId(), millis: u32) void {
            global.static_windows[@intFromEnum(window_id)].?.startTimer(
                zin.intFromTimerId(usize, window_id.getConfig().TimerId(), id),
                millis,
            );
        }
    };
}

fn windowSizeFromClient(
    client_size: zin.XY,
    style: win32.WINDOW_STYLE,
    style_ex: win32.WINDOW_EX_STYLE,
    dpi: u32,
) zin.XY {
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = client_size.x,
        .bottom = client_size.y,
    };
    if (0 == win32.AdjustWindowRectExForDpi(&rect, style, 0, style_ex, dpi)) win32.panicWin32(
        "AdjustWindowRect",
        win32.GetLastError(),
    );
    return .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
}

pub fn createDynamicWindow(class: WindowClass, opt: zin.CreateWindowOptions) zin.CreateWindowError!DynamicWindow {
    return windowFromHwnd(try createWindow(class, &opt));
}

fn createWindow(class: WindowClass, opt: *const zin.CreateWindowOptions) zin.CreateWindowError!win32.HWND {
    var title_buf: [max_window_title + 1]u16 = undefined;

    {
        const title_len = calcTitleLen(opt.title);
        if (title_len > max_window_title) @panic("window title is too long");
        const len = std.unicode.wtf8ToWtf16Le(
            title_buf[0..max_window_title],
            opt.title,
        ) catch unreachable;
        std.debug.assert(len == title_len);
        title_buf[title_len] = 0;
    }

    const style_ex: win32.WINDOW_EX_STYLE = .{};
    const style: win32.WINDOW_STYLE = .{
        .TABSTOP = 1,
        .GROUP = 1,
        .THICKFRAME = 1,
        .SYSMENU = 1,
        .DLGFRAME = 1,
        .BORDER = 1,
    };

    const create_size: zin.XY = blk: {
        break :blk switch (opt.size) {
            .default => .{ .x = win32.CW_USEDEFAULT, .y = win32.CW_USEDEFAULT },
            .client_pixels => |s| s,
            .client_points => |s| s, // we'll adjust the size below (after we know the REAL DPI)
            .window_pixels => |s| s,
            .window_points => |s| s, // we'll adjust the size below (after we know the REAL DPI)
        };
    };
    const create_pos: zin.XY = if (opt.pos) |pos|
        .{ .x = pos.x, .y = pos.y }
    else
        .{ .x = win32.CW_USEDEFAULT, .y = win32.CW_USEDEFAULT };

    const hwnd = win32.CreateWindowExW(
        style_ex,
        @ptrFromInt(class.atom),
        @ptrCast(&title_buf),
        style,
        create_pos.x,
        create_pos.y,
        create_size.x,
        create_size.y,
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse
        // I'm not sure if it's worth trying to propagate/handle CreateWindow errors
        win32.panicWin32("CreateWindow", win32.GetLastError());
    errdefer win32.destroyWindow(hwnd);

    const dpi = win32.dpiFromHwnd(hwnd);
    const maybe_window_size: ?zin.XY = blk: switch (opt.size) {
        .default => break :blk null,
        .client_pixels => |client_size| break :blk windowSizeFromClient(client_size, style, style_ex, dpi),
        .client_points => |client_size| {
            const dpi_scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
            break :blk windowSizeFromClient(.{
                .x = zin.scale(i32, client_size.x, dpi_scale),
                .y = zin.scale(i32, client_size.y, dpi_scale),
            }, style, style_ex, dpi);
        },
        .window_pixels => |window_size| break :blk window_size,
        .window_points => |window_size| {
            const dpi_scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
            break :blk .{
                .x = zin.scale(i32, window_size.x, dpi_scale),
                .y = zin.scale(i32, window_size.y, dpi_scale),
            };
        },
    };
    if (maybe_window_size) |window_size| {
        if (0 == win32.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            window_size.x,
            window_size.y,
            .{ .NOACTIVATE = 1, .NOMOVE = 1, .NOZORDER = 1 },
        )) win32.panicWin32("SetWindowPos", win32.GetLastError());
    }

    return hwnd;
}

pub fn quitMainLoop() void {
    win32.PostQuitMessage(0);
}
pub fn mainLoop() !void {
    while (true) {
        var msg: win32.MSG = undefined;
        const result = win32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) break;
        if (result == -1) win32.panicWin32("GetMessage", win32.GetLastError());
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

pub const VirtualKey = enum(u16) {
    // Mouse buttons
    left_button = @intFromEnum(win32.VK_LBUTTON),
    right_button = @intFromEnum(win32.VK_RBUTTON),
    cancel = @intFromEnum(win32.VK_CANCEL),
    middle_button = @intFromEnum(win32.VK_MBUTTON),
    xbutton1 = @intFromEnum(win32.VK_XBUTTON1),
    xbutton2 = @intFromEnum(win32.VK_XBUTTON2),

    // Basic keys
    backspace = @intFromEnum(win32.VK_BACK),
    tab = @intFromEnum(win32.VK_TAB),
    clear = @intFromEnum(win32.VK_CLEAR),
    @"return" = @intFromEnum(win32.VK_RETURN),

    // Modifier keys
    // NOTE: we always map VK_SHIFT to either shift_left or shift_right
    shift_left = @intFromEnum(win32.VK_LSHIFT),
    shift_right = @intFromEnum(win32.VK_RSHIFT),
    // NOTE: we always map VK_CONTROL to either control_left or control_right
    control_left = @intFromEnum(win32.VK_LCONTROL),
    control_right = @intFromEnum(win32.VK_RCONTROL),
    // NOTE: we always map VK_MENU to either alt_left or alt_right
    alt_left = @intFromEnum(win32.VK_LMENU),
    alt_right = @intFromEnum(win32.VK_RMENU),

    pause = @intFromEnum(win32.VK_PAUSE),
    caps_lock = @intFromEnum(win32.VK_CAPITAL),

    // IME keys
    kana = @intFromEnum(win32.VK_KANA),
    ime_on = @intFromEnum(win32.VK_IME_ON),
    junja = @intFromEnum(win32.VK_JUNJA),
    final = @intFromEnum(win32.VK_FINAL),
    hanja = @intFromEnum(win32.VK_HANJA),
    ime_off = @intFromEnum(win32.VK_IME_OFF),

    escape = @intFromEnum(win32.VK_ESCAPE),
    convert = @intFromEnum(win32.VK_CONVERT),
    nonconvert = @intFromEnum(win32.VK_NONCONVERT),
    accept = @intFromEnum(win32.VK_ACCEPT),
    modechange = @intFromEnum(win32.VK_MODECHANGE),

    // Navigation keys
    page_up = @intFromEnum(win32.VK_PRIOR),
    page_down = @intFromEnum(win32.VK_NEXT),
    end = @intFromEnum(win32.VK_END),
    home = @intFromEnum(win32.VK_HOME),
    left = @intFromEnum(win32.VK_LEFT),
    up = @intFromEnum(win32.VK_UP),
    right = @intFromEnum(win32.VK_RIGHT),
    down = @intFromEnum(win32.VK_DOWN),
    select = @intFromEnum(win32.VK_SELECT),
    print = @intFromEnum(win32.VK_PRINT),
    execute = @intFromEnum(win32.VK_EXECUTE),
    print_screen = @intFromEnum(win32.VK_SNAPSHOT), // Print screen
    insert = @intFromEnum(win32.VK_INSERT),
    delete = @intFromEnum(win32.VK_DELETE),
    help = @intFromEnum(win32.VK_HELP),

    super_left = @intFromEnum(win32.VK_LWIN),
    super_right = @intFromEnum(win32.VK_RWIN),
    apps = @intFromEnum(win32.VK_APPS), // Application key
    sleep = @intFromEnum(win32.VK_SLEEP),

    numpad0 = @intFromEnum(win32.VK_NUMPAD0),
    numpad1 = @intFromEnum(win32.VK_NUMPAD1),
    numpad2 = @intFromEnum(win32.VK_NUMPAD2),
    numpad3 = @intFromEnum(win32.VK_NUMPAD3),
    numpad4 = @intFromEnum(win32.VK_NUMPAD4),
    numpad5 = @intFromEnum(win32.VK_NUMPAD5),
    numpad6 = @intFromEnum(win32.VK_NUMPAD6),
    numpad7 = @intFromEnum(win32.VK_NUMPAD7),
    numpad8 = @intFromEnum(win32.VK_NUMPAD8),
    numpad9 = @intFromEnum(win32.VK_NUMPAD9),
    multiply = @intFromEnum(win32.VK_MULTIPLY),
    add = @intFromEnum(win32.VK_ADD),
    separator = @intFromEnum(win32.VK_SEPARATOR),
    subtract = @intFromEnum(win32.VK_SUBTRACT),
    decimal = @intFromEnum(win32.VK_DECIMAL),
    divide = @intFromEnum(win32.VK_DIVIDE),

    f1 = @intFromEnum(win32.VK_F1),
    f2 = @intFromEnum(win32.VK_F2),
    f3 = @intFromEnum(win32.VK_F3),
    f4 = @intFromEnum(win32.VK_F4),
    f5 = @intFromEnum(win32.VK_F5),
    f6 = @intFromEnum(win32.VK_F6),
    f7 = @intFromEnum(win32.VK_F7),
    f8 = @intFromEnum(win32.VK_F8),
    f9 = @intFromEnum(win32.VK_F9),
    f10 = @intFromEnum(win32.VK_F10),
    f11 = @intFromEnum(win32.VK_F11),
    f12 = @intFromEnum(win32.VK_F12),
    f13 = @intFromEnum(win32.VK_F13),
    f14 = @intFromEnum(win32.VK_F14),
    f15 = @intFromEnum(win32.VK_F15),
    f16 = @intFromEnum(win32.VK_F16),
    f17 = @intFromEnum(win32.VK_F17),
    f18 = @intFromEnum(win32.VK_F18),
    f19 = @intFromEnum(win32.VK_F19),
    f20 = @intFromEnum(win32.VK_F20),
    f21 = @intFromEnum(win32.VK_F21),
    f22 = @intFromEnum(win32.VK_F22),
    f23 = @intFromEnum(win32.VK_F23),
    f24 = @intFromEnum(win32.VK_F24),

    numlock = @intFromEnum(win32.VK_NUMLOCK),
    scroll_lock = @intFromEnum(win32.VK_SCROLL),

    browser_back = @intFromEnum(win32.VK_BROWSER_BACK),
    browser_forward = @intFromEnum(win32.VK_BROWSER_FORWARD),
    browser_refresh = @intFromEnum(win32.VK_BROWSER_REFRESH),
    browser_stop = @intFromEnum(win32.VK_BROWSER_STOP),
    browser_search = @intFromEnum(win32.VK_BROWSER_SEARCH),
    browser_favorites = @intFromEnum(win32.VK_BROWSER_FAVORITES),
    browser_home = @intFromEnum(win32.VK_BROWSER_HOME),

    // volume_mute = @intFromEnum(win32.VK_VOLUME_MUTE),
    // volume_down = @intFromEnum(win32.VK_VOLUME_DOWN),
    // volume_up = @intFromEnum(win32.VK_VOLUME_UP),

    // media_next_track = @intFromEnum(win32.VK_MEDIA_NEXT_TRACK),
    // media_prev_track = @intFromEnum(win32.VK_MEDIA_PREV_TRACK),
    // media_stop = @intFromEnum(win32.VK_MEDIA_STOP),
    // media_play_pause = @intFromEnum(win32.VK_MEDIA_PLAY_PAUSE),

    launch_mail = @intFromEnum(win32.VK_LAUNCH_MAIL),
    launch_media_select = @intFromEnum(win32.VK_LAUNCH_MEDIA_SELECT),
    launch_app1 = @intFromEnum(win32.VK_LAUNCH_APP1),
    launch_app2 = @intFromEnum(win32.VK_LAUNCH_APP2),

    oem_1 = @intFromEnum(win32.VK_OEM_1), // Semicolon/Colon on US ANSI
    oem_plus = @intFromEnum(win32.VK_OEM_PLUS), // Equals/Plus
    oem_comma = @intFromEnum(win32.VK_OEM_COMMA), // Comma/Less Than
    oem_minus = @intFromEnum(win32.VK_OEM_MINUS), // Dash/Underscore
    oem_period = @intFromEnum(win32.VK_OEM_PERIOD), // Period/Greater Than
    oem_2 = @intFromEnum(win32.VK_OEM_2), // Forward Slash/Question Mark on US ANSI
    oem_3 = @intFromEnum(win32.VK_OEM_3), // Grave Accent/Tilde on US ANSI
    oem_4 = @intFromEnum(win32.VK_OEM_4), // Left Brace on US ANSI
    oem_5 = @intFromEnum(win32.VK_OEM_5), // Backslash/Pipe on US ANSI
    oem_6 = @intFromEnum(win32.VK_OEM_6), // Right Brace on US ANSI
    oem_7 = @intFromEnum(win32.VK_OEM_7), // Apostrophe/Double Quote on US ANSI
    oem_8 = @intFromEnum(win32.VK_OEM_8), // Varies by keyboard
    oem_102 = @intFromEnum(win32.VK_OEM_102), // Backslash/Pipe on European ISO
    processkey = @intFromEnum(win32.VK_PROCESSKEY), // IME PROCESS key
    packet = @intFromEnum(win32.VK_PACKET), // Used for Unicode characters as keystrokes

    attn = @intFromEnum(win32.VK_ATTN),
    crsel = @intFromEnum(win32.VK_CRSEL),
    exsel = @intFromEnum(win32.VK_EXSEL),
    ereof = @intFromEnum(win32.VK_EREOF),
    play = @intFromEnum(win32.VK_PLAY),
    zoom = @intFromEnum(win32.VK_ZOOM),
    noname = @intFromEnum(win32.VK_NONAME), // Reserved
    pa1 = @intFromEnum(win32.VK_PA1),
    oem_clear = @intFromEnum(win32.VK_OEM_CLEAR),
    _,

    // the following are duplicates
    pub const hangul = @intFromEnum(win32.VK_HANGUL);
    pub const kanji = @intFromEnum(win32.VK_KANJI);
};
pub const ScanCode = enum(u8) {
    _,
};
const KeyFlags = packed struct(u32) {
    repeat_count: u16,
    scan_code: u8,
    extended: bool,
    reserved: u4,
    context: bool,
    previous: bool,
    transition: bool,
};
fn keyFromWin32(direction: enum { up, down }, wparam: win32.WPARAM, lparam: win32.LPARAM) zin.Key {
    const key_flags: KeyFlags = @bitCast(@as(u32, @intCast(0xffffffff & lparam)));
    return .{
        .kind = switch (direction) {
            .up => .up,
            .down => if (key_flags.previous) .down_repeat else .down,
        },
        .vk = switch (wparam) {
            @intFromEnum(win32.VK_SHIFT) => switch (key_flags.scan_code) {
                0x2a => .shift_left, // typical mapping
                0x36 => .shift_right, // typical mapping
                else => .shift_left, // otherwise, we'll just always map this to left shift
            },
            @intFromEnum(win32.VK_CONTROL) => if (key_flags.extended) .control_right else .control_left,
            @intFromEnum(win32.VK_MENU) => if (key_flags.extended) .alt_right else .alt_left,
            else => @enumFromInt(@as(u16, @intCast(0xffff & wparam))),
        },
        .scan_code = @enumFromInt(key_flags.scan_code),
        .win32_extended = key_flags.extended,
        .x11_mask = {},
        .macos_mods = {},
    };
}

var start_time: ?u32 = null;
fn getTime() u32 {
    const t = start_time orelse {
        start_time = win32.GetTickCount();
        return 0;
    };
    return win32.GetTickCount() - t;
}

const WndProc = fn (win32.HWND, u32, win32.WPARAM, win32.LPARAM) callconv(.winapi) win32.LRESULT;
fn makeWndProc(
    config: zin.WindowConfig,
    class: zin.WindowClassDefinition(config),
) WndProc {
    return (struct {
        pub fn wndProc(
            hwnd: win32.HWND,
            msg: u32,
            wparam: win32.WPARAM,
            lparam: win32.LPARAM,
        ) callconv(.winapi) win32.LRESULT {
            // var msg_tail: ?*windowmsg.MessageNode = null;
            // var msg_node: windowmsg.MessageNode = undefined;
            // msg_node.init(&msg_tail, hwnd, msg, wparam, lparam);
            // defer msg_node.deinit();
            // switch (msg) {
            //     win32.WM_NCHITTEST,
            //     win32.WM_SETCURSOR,
            //     win32.WM_GETICON,
            //     win32.WM_MOUSEMOVE,
            //     win32.WM_NCMOUSEMOVE,
            //     => {},
            //     else => if (true) std.log.info("{}: {}", .{ getTime(), msg_node.fmtPath() }),
            // }

            switch (msg) {
                win32.WM_ERASEBKGND => {
                    // TODO: we might want to call fill rect here in certain circumstances
                    return 0;
                },
                win32.WM_CLOSE => {
                    switch (config) {
                        .static => class.callback(.close),
                        .dynamic => class.callback(windowFromHwnd(hwnd), .close),
                    }
                    return 0;
                },
                win32.WM_SETCURSOR => {
                    if (config.data().win32.set_cursor_callback) {
                        var result: isize = 0;
                        class.callback(.{
                            .win32_set_cursor = .{ .result_ref = &result, .wparam = wparam, .lparam = lparam },
                        });
                        if (result != 0) return result;
                    }
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_PAINT => {
                    paint(config, class, hwnd);
                    return 0;
                },
                win32.WM_SIZE => {
                    if (config.data().window_size_events) {
                        const width = win32.loword(lparam);
                        const height = win32.hiword(lparam);
                        const client_size = win32.getClientSize(hwnd);
                        std.debug.assert(width == client_size.cx);
                        std.debug.assert(height == client_size.cy);
                        class.callback(.{ .window_size = .{ .x = width, .y = height } });
                    }
                    return 0;
                },
                win32.WM_TIMER => {
                    switch (config.data().timers) {
                        .none => {},
                        .one => {
                            std.debug.assert(wparam == 1);
                            switch (config) {
                                .static => class.callback(.{ .timer = {} }),
                                .dynamic => class.callback(windowFromHwnd(hwnd), .{ .timer = {} }),
                            }
                        },
                        .type => |TimerId| switch (config) {
                            .static => class.callback(.{
                                .timer = zin.timerIdFromInt(TimerId, wparam),
                            }),
                            .dynamic => class.callback(windowFromHwnd(hwnd), .{
                                .timer = zin.timerIdFromInt(TimerId, wparam),
                            }),
                        },
                    }
                    return 0;
                },
                win32.WM_MENUCHAR => {
                    // Return MAKELRESULT(0, MNC_CLOSE) to close menu and prevent beep
                    return 0 | (@as(win32.LRESULT, 1) << 16); // MNC_CLOSE = 1
                },
                win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
                    if (comptime config.data().key_events) switch (config) {
                        .static => class.callback(.{ .key = keyFromWin32(.down, wparam, lparam) }),
                        .dynamic => class.callback(
                            windowFromHwnd(hwnd),
                            .{ .key = keyFromWin32(.down, wparam, lparam) },
                        ),
                    };
                    if (msg == win32.WM_KEYDOWN) return 0;
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_KEYUP, win32.WM_SYSKEYUP => {
                    if (comptime config.data().key_events) switch (config) {
                        .static => class.callback(.{ .key = keyFromWin32(.up, wparam, lparam) }),
                        .dynamic => class.callback(
                            windowFromHwnd(hwnd),
                            .{ .key = keyFromWin32(.up, wparam, lparam) },
                        ),
                    };
                    if (msg == win32.WM_KEYUP) return 0;
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_MOUSEMOVE => {
                    if (comptime config.data().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        switch (config) {
                            .static => class.callback(
                                .{ .mouse = .{ .position = .{ .x = pos.x, .y = pos.y }, .button = null } },
                            ),
                            .dynamic => class.callback(
                                windowFromHwnd(hwnd),
                                .{ .mouse = .{ .position = .{ .x = pos.x, .y = pos.y }, .button = null } },
                            ),
                        }
                    }
                    return 0;
                },
                win32.WM_LBUTTONDOWN => {
                    if (comptime config.data().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        switch (config) {
                            .static => class.callback(
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .left, .state = .down },
                                } },
                            ),
                            .dynamic => class.callback(
                                windowFromHwnd(hwnd),
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .left, .state = .down },
                                } },
                            ),
                        }
                    }
                    return 0;
                },
                win32.WM_LBUTTONUP => {
                    if (comptime config.data().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        switch (config) {
                            .static => class.callback(
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .left, .state = .up },
                                } },
                            ),
                            .dynamic => class.callback(
                                windowFromHwnd(hwnd),
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .left, .state = .up },
                                } },
                            ),
                        }
                    }
                    return 0;
                },
                win32.WM_RBUTTONDOWN => {
                    if (comptime config.data().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        switch (config) {
                            .static => class.callback(
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .right, .state = .down },
                                } },
                            ),
                            .dynamic => class.callback(
                                windowFromHwnd(hwnd),
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .right, .state = .down },
                                } },
                            ),
                        }
                    }
                    return 0;
                },
                win32.WM_RBUTTONUP => {
                    if (comptime config.data().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        switch (config) {
                            .static => class.callback(
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .right, .state = .up },
                                } },
                            ),
                            .dynamic => class.callback(
                                windowFromHwnd(hwnd),
                                .{ .mouse = .{
                                    .position = .{ .x = pos.x, .y = pos.y },
                                    .button = .{ .id = .right, .state = .up },
                                } },
                            ),
                        }
                    }
                    return 0;
                },
                else => return if (config.data().win32.default_window_proc) |proc|
                    proc(hwnd, msg, wparam, lparam)
                else
                    win32.DefWindowProcW(hwnd, msg, wparam, lparam),
            }
        }
    }).wndProc;
}

fn paint(
    comptime config: zin.WindowConfig,
    class: zin.WindowClassDefinition(config),
    hwnd: win32.HWND,
) void {
    const paintdc, const ps = win32.beginPaint(hwnd);
    defer win32.endPaint(hwnd, &ps);

    switch (config.data().win32.render) {
        .gdi => |gdi| if (gdi.use_backbuffer) {
            const size = win32.getClientSize(hwnd);
            // todo: worth it to cache between frames?
            const memdc = win32.CreateCompatibleDC(paintdc);
            defer win32.deleteDc(memdc);
            // todo: worth it to cache between frames?
            const bmp = win32.CreateCompatibleBitmap(paintdc, size.cx, size.cy) orelse win32.panicWin32("CreateCompatibleBitmap", win32.GetLastError());
            defer win32.deleteObject(bmp);
            const old_bmp = win32.SelectObject(memdc, bmp);
            defer _ = win32.SelectObject(memdc, old_bmp);

            if (0 == win32.SetBkMode(memdc, .TRANSPARENT)) win32.panicWin32("SetBkMode", win32.GetLastError());

            switch (config) {
                .static => class.callback(
                    .{ .draw = .{
                        .hwnd = hwnd,
                        .hdc = memdc,
                        .background = if (comptime config.data().dynamic_background) config.data().background else {},
                    } },
                ),
                .dynamic => class.callback(
                    windowFromHwnd(hwnd),
                    .{
                        .draw = .{
                            .hwnd = hwnd,
                            .hdc = memdc,
                            .background = if (comptime config.data().dynamic_background) config.data().background else {},
                        },
                    },
                ),
            }
            if (0 == win32.BitBlt(
                paintdc,
                0,
                0,
                size.cx,
                size.cy,
                memdc,
                0,
                0,
                win32.SRCCOPY,
            )) win32.panicWin32(
                "BitBlt",
                win32.GetLastError(),
            );
        } else {
            if (0 == win32.SetBkMode(paintdc, .TRANSPARENT)) win32.panicWin32("SetBkMode", win32.GetLastError());
            switch (config) {
                .static => class.callback(
                    .{ .draw = .{
                        .hwnd = hwnd,
                        .hdc = paintdc,
                        .background = if (comptime config.data().dynamic_background) config.data().background else {},
                    } },
                ),
                .dynamic => class.callback(
                    windowFromHwnd(hwnd),
                    .{ .draw = .{
                        .hwnd = hwnd,
                        .hdc = paintdc,
                        .background = if (comptime config.data().dynamic_background) config.data().background else {},
                    } },
                ),
            }
        },
    }
}

fn colorrefFromRgb8(rgb8: zin.Rgb8) u32 {
    return (@as(u32, rgb8.b) << 16) |
        (@as(u32, rgb8.g) << 8) |
        (@as(u32, rgb8.r) << 0);
}

comptime {
    std.debug.assert(@sizeOf(PolygonPoint) == @sizeOf(win32.POINT));
    std.debug.assert(@alignOf(PolygonPoint) == @alignOf(win32.POINT));
}
pub const PolygonPoint = extern struct {
    point: win32.POINT,
    pub fn xy(x: i32, y: i32) PolygonPoint {
        return .{ .point = .{ .x = x, .y = y } };
    }
};

pub fn Draw(window_config: zin.WindowConfig) type {
    return struct {
        hwnd: win32.HWND,
        hdc: win32.HDC,
        background: if (window_config.data().dynamic_background) zin.Rgb8 else void,

        const Self = @This();

        pub fn getDpiScale(self: *const Self) struct { x: f32, y: f32 } {
            const scale: f32 = @as(f32, @floatFromInt(win32.dpiFromHwnd(self.hwnd))) / 96.0;
            return .{ .x = scale, .y = scale };
        }

        pub fn clear(self: *const Self) void {
            const rgb = if (comptime window_config.data().dynamic_background)
                self.background
            else
                window_config.data().background;
            const brush = win32.createSolidBrush(colorrefFromRgb8(rgb));
            defer win32.deleteObject(brush);
            const size = win32.getClientSize(self.hwnd);
            win32.fillRect(self.hdc, .{
                .left = 0,
                .top = 0,
                .right = size.cx,
                .bottom = size.cy,
            }, brush);
        }

        pub fn rect(self: *const Self, r: zin.Rect, rgb: zin.Rgb8) void {
            const brush = win32.createSolidBrush(colorrefFromRgb8(rgb));
            defer win32.deleteObject(brush);
            win32.fillRect(self.hdc, .{
                .left = r.left,
                .top = r.top,
                .right = r.right,
                .bottom = r.bottom,
            }, brush);
        }

        pub fn text(self: *const Self, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            if (win32.CLR_INVALID == win32.SetTextColor(self.hdc, colorrefFromRgb8(rgb)))
                win32.panicWin32("SetTextColor", win32.GetLastError());
            if (0 == win32.TextOutA(
                self.hdc,
                x,
                y,
                @ptrCast(t.ptr),
                @intCast(t.len),
            )) win32.panicWin32("TextOut", win32.GetLastError());
        }

        pub fn polygon(self: *const Self, points: []const PolygonPoint, color: zin.Rgb8) void {
            const brush = win32.createSolidBrush(colorrefFromRgb8(color));
            defer win32.deleteObject(brush);
            const old_brush = win32.SelectObject(self.hdc, brush);
            defer _ = win32.SelectObject(self.hdc, old_brush);
            if (0 == win32.Polygon(self.hdc, @ptrCast(points.ptr), @intCast(points.len))) win32.panicWin32(
                "Polygon",
                win32.GetLastError(),
            );
        }
    };
}
