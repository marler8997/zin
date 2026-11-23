const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin.zig");
pub const win32 = @import("win32").everything;
const windowmsg = @import("windowmsg.zig");

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
                const msg_z: [:0]const u8 = std.fmt.allocPrintSentinel(
                    arena.allocator(),
                    "{s}",
                    .{msg},
                    0,
                ) catch oom_msg;
                _ = @import("win32").everything.MessageBoxA(null, msg_z, panic_opt.title, panic_opt.win32_style);
            }
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic);
}

pub fn processInit(opt: zin.ProcessInitOptions) zin.ProcessInitError!void {
    _ = opt;
    global.process_init_check.onProcessInit();

    var awareness: win32.PROCESS_DPI_AWARENESS = undefined;
    {
        const hr = win32.GetProcessDpiAwareness(null, &awareness);
        if (hr.failed) std.debug.panic(
            "GetProcessDpiAwareness failed, hresult={f}",
            .{hr},
        );
    }
    switch (awareness) {
        .DPI_UNAWARE => return error.Win32NoDpiAwareness,
        .SYSTEM_DPI_AWARE => return error.Win32OnlySystemDpiAwareness,
        .PER_MONITOR_DPI_AWARE => {},
    }
}

pub const ThreadInitError = union(enum) {
    d2d_create_factory: win32.HRESULT,

    pub fn format(err: ThreadInitError, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (err) {
            .d2d_create_factory => |hr| try writer.print("D2D1CreateFactory failed, hresult={f}", .{hr}),
        }
    }
};

pub fn threadInit(id: zin.ThreadId) ?ThreadInitError {
    global.process_init_check.enforce();
    const check = &global.thread_init_checks[@backingInt(id)];
    check.onThreadInit(id);
    switch (id) {
        inline else => |comptime_id| if (comptime d2d_layout.factory_index[@backingInt(comptime_id)]) |index| {
            const hr = win32.D2D1CreateFactory(
                .SINGLE_THREADED,
                win32.IID_ID2D1Factory,
                null,
                @ptrCast(&global.d2d_factories[index]),
            );
            if (hr.failed) {
                check.onThreadDeinit(id);
                return .{ .d2d_create_factory = hr };
            }
        },
    }
    return null;
}
pub fn threadDeinit(id: zin.ThreadId) void {
    enforceThread(id);
    switch (id) {
        inline else => |comptime_id| if (comptime d2d_layout.factory_index[@backingInt(comptime_id)]) |index| {
            _ = global.d2d_factories[index].IUnknown.Release();
            global.d2d_factories[index] = undefined;
        },
    }
    global.thread_init_checks[@backingInt(id)].onThreadDeinit(id);
}
/// Panics with runtime safety unless called on the thread that called
/// threadInit with `id`.
pub fn enforceThread(id: zin.ThreadId) void {
    global.thread_init_checks[@backingInt(id)].enforce(id);
}

pub const min_timer_id_int = 1;

pub const WindowConfig = struct {
    render: union(enum) {
        gdi: struct {
            use_backbuffer: bool = true,
        },
        direct2d: struct {},
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
fn registerWindowClass(
    comptime window_id: zin.StaticWindowId,
    comptime def: zin.WindowClassDefinition(window_id),
    runtime_config: zin.WindowClassRuntimeConfig,
) WindowClass {
    var c: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        // TODO: create a option to enable/disable double clicks,
        //       enabling them will change how window events are sent
        // .DBLCLKS = 1
        .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
        .lpfnWndProc = if (runtime_config.win32_wndproc) |proc| proc else makeWndProc(window_id, def),
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

const Window = enum(usize) {
    _,
    fn asHwnd(self: Window) win32.HWND {
        return @ptrFromInt(@backingInt(self));
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
        _ = win32.ShowWindow(self.asHwnd(), .SHOWNORMAL);
    }
    pub fn foreground(self: Window) void {
        if (0 == win32.SetForegroundWindow(self.asHwnd()))
            win32.panicWin32("SetForegroundWindow", win32.GetLastError());
    }
    pub fn invalidate(self: Window) void {
        win32.invalidateHwnd(self.asHwnd());
    }
    pub fn startTimerMillis(self: Window, id: usize, millis: u32) void {
        if (0 == win32.SetTimer(self.asHwnd(), id, millis, null))
            win32.panicWin32("SetTimer", win32.GetLastError());
    }
    pub fn startTimerNanos(self: Window, id: usize, nanos: u64) void {
        self.startTimerMillis(id, @divTrunc(nanos + (std.time.ns_per_ms - 1), std.time.ns_per_ms));
    }
};

fn windowFromHwnd(hwnd: win32.HWND) Window {
    return @fromBackingInt(@intCast(@intFromPtr(hwnd)));
}

pub const max_window_title = 1000;
pub fn calcTitleLen(title: []const u8) usize {
    return std.unicode.calcWtf16LeLen(title) catch |e| std.debug.panic(
        "invalid window title ({s})",
        .{@errorName(e)},
    );
}

const thread_count = @typeInfo(zin.ThreadId).@"enum".field_names.len;
const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".field_names.len;
const global = struct {
    var process_init_check: zin.ProcessInitCheck = .{};
    var static_classes: [static_window_count]?WindowClass = @splat(null);
    var static_windows: [static_window_count]?Window = @splat(null);
    var thread_init_checks: [thread_count]zin.ThreadInitCheck = @splat(.{});
    /// The Direct2D factory of each thread that has a direct2d window, set
    /// between that thread's threadInit and threadDeinit.
    var d2d_factories: [d2d_layout.factory_count]*win32.ID2D1Factory = undefined;
    var dwrite_factory: std.atomic.Value(?*win32.IDWriteFactory) = .init(null);
    /// The stored texts of every direct2d window, one window after another.
    var d2d_stored_texts: [d2d_layout.text_count]D2dStoredText = @splat(.{});
    /// Each direct2d window's Direct2D objects, null until its first paint.
    var d2d_objects: [d2d_layout.window_count]?D2dObjects = @splat(null);

    fn updateD2dTarget(
        comptime window_id: zin.StaticWindowId,
        hwnd: win32.HWND,
        size: win32.SIZE,
    ) *win32.ID2D1HwndRenderTarget {
        if (global.d2d_objects[comptime d2dWindowIndex(window_id)]) |objects| {
            const hr = objects.target.Resize(&d2dSize(size));
            if (!hr.failed) return objects.target;
            if (hr != win32.D2DERR_RECREATE_TARGET) std.debug.panic(
                "ID2D1HwndRenderTarget.Resize to {d}x{d} failed, hresult={f}",
                .{ size.cx, size.cy, hr },
            );
            global.releaseD2dObjects(window_id);
        }
        var target: *win32.ID2D1HwndRenderTarget = undefined;
        const hr = d2dFactory(window_id.getConfig().thread).CreateHwndRenderTarget(
            &.{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .UNKNOWN, .alphaMode = .UNKNOWN },
                .dpiX = 0,
                .dpiY = 0,
                .usage = .{},
                .minLevel = .DEFAULT,
            },
            &.{ .hwnd = hwnd, .pixelSize = d2dSize(size), .presentOptions = .{} },
            &target,
        );
        if (hr.failed) std.debug.panic(
            "CreateHwndRenderTarget at {d}x{d} failed, hresult={f}",
            .{ size.cx, size.cy, hr },
        );
        {
            var device_context: *win32.ID2D1DeviceContext = undefined;
            const query_hr = target.IUnknown.QueryInterface(win32.IID_ID2D1DeviceContext, @ptrCast(&device_context));
            if (query_hr.failed) win32.panicHresult("QueryInterface for ID2D1DeviceContext", query_hr);
            defer _ = device_context.IUnknown.Release();
            device_context.SetUnitMode(.PIXELS);
        }
        global.d2d_objects[comptime d2dWindowIndex(window_id)] = .{ .target = target };
        return target;
    }

    /// A direct2d window's stored texts, indexed by its `TextId`.
    fn d2dStoredTexts(comptime window_id: zin.StaticWindowId) []D2dStoredText {
        const count = @typeInfo(window_id.getConfig().TextId).@"enum".field_names.len;
        return global.d2d_stored_texts[comptime d2d_layout.text_start[@backingInt(window_id)]..][0..count];
    }

    fn releaseD2dObjects(comptime window_id: zin.StaticWindowId) void {
        const objects = global.d2d_objects[comptime d2dWindowIndex(window_id)] orelse return;
        global.d2d_objects[comptime d2dWindowIndex(window_id)] = null;
        if (objects.brush) |brush| _ = brush.IUnknown.Release();
        _ = objects.target.IUnknown.Release();
    }
};

/// A window's render target and what was created from it, which a device loss
/// replaces together.
const D2dObjects = struct {
    target: *win32.ID2D1HwndRenderTarget,
    /// Created by the first `D2dDraw.solidBrush`.
    brush: ?*win32.ID2D1SolidColorBrush = null,
};

/// What a direct2d window keeps of one of its `TextId` texts between draws.
const D2dStoredText = struct {
    /// Null until the text is first drawn.
    layout: ?*win32.IDWriteTextLayout = null,
    /// Of the text's bytes.
    hash: u64 = 0,
    len: usize = 0,
    /// The DPI the text was laid out at.
    dpi: u32 = 0,

    fn release(stored: *D2dStoredText) void {
        if (stored.layout) |layout| _ = layout.IUnknown.Release();
        stored.* = .{};
    }
};

fn d2dSize(size: win32.SIZE) win32.D2D_SIZE_U {
    return .{ .width = @intCast(size.cx), .height = @intCast(size.cy) };
}

/// Where each direct2d window and thread keeps its Direct2D state in the
/// arrays of `global`, worked out in one pass over the windows.
const D2dLayout = struct {
    window_count: usize,
    /// A window's index in `global.d2d_objects`, null if it doesn't use direct2d.
    window_index: [static_window_count]?usize,
    text_count: usize,
    /// Where a window's texts start in `global.d2d_stored_texts`.
    text_start: [static_window_count]usize,
    factory_count: usize,
    /// A thread's index in `global.d2d_factories`, null if none of its
    /// windows use direct2d.
    factory_index: [thread_count]?usize,
};
const d2d_layout: D2dLayout = blk: {
    @setEvalBranchQuota(1000 + 20 * (static_window_count + thread_count));
    var layout: D2dLayout = .{
        .window_count = 0,
        .window_index = @splat(null),
        .text_count = 0,
        .text_start = @splat(0),
        .factory_count = 0,
        .factory_index = @splat(null),
    };
    var thread_has_d2d: [thread_count]bool = @splat(false);
    for (std.enums.values(zin.StaticWindowId)) |window_id| {
        const config = window_id.getConfig();
        layout.text_start[@backingInt(window_id)] = layout.text_count;
        switch (config.win32.render) {
            .gdi => {},
            .direct2d => {
                layout.window_index[@backingInt(window_id)] = layout.window_count;
                layout.window_count += 1;
                layout.text_count += @typeInfo(config.TextId).@"enum".field_names.len;
                thread_has_d2d[@backingInt(config.thread)] = true;
            },
        }
    }
    for (thread_has_d2d, &layout.factory_index) |has_d2d, *index| {
        if (!has_d2d) continue;
        index.* = layout.factory_count;
        layout.factory_count += 1;
    }
    break :blk layout;
};

fn d2dWindowIndex(comptime window_id: zin.StaticWindowId) usize {
    return d2d_layout.window_index[@backingInt(window_id)] orelse @compileError(
        "window '" ++ @tagName(window_id) ++ "' doesn't use direct2d",
    );
}

/// The factory of the render target of every direct2d window on thread `id`.
/// Geometries and stroke styles drawn on those targets must come from it. It is
/// single threaded, so it and everything made from it stay on that thread.
pub fn d2dFactory(comptime id: zin.ThreadId) *win32.ID2D1Factory {
    const index = comptime d2d_layout.factory_index[@backingInt(id)] orelse @compileError(
        "thread '" ++ @tagName(id) ++ "' has no Direct2D factory because none of its windows use direct2d",
    );
    enforceThread(id);
    return global.d2d_factories[index];
}

/// The process's shared DirectWrite factory, created on first use and usable
/// from any thread.
pub fn dwriteFactory() *win32.IDWriteFactory {
    if (global.dwrite_factory.load(.acquire)) |factory| return factory;
    var factory: *win32.IDWriteFactory = undefined;
    const hr = win32.DWriteCreateFactory(.SHARED, win32.IID_IDWriteFactory, @ptrCast(&factory));
    if (hr.failed) win32.panicHresult("DWriteCreateFactory", hr);
    if (global.dwrite_factory.cmpxchgStrong(null, factory, .acq_rel, .acquire)) |winner| {
        // another thread stored its reference first
        _ = factory.IUnknown.Release();
        return winner.?;
    }
    return factory;
}

pub fn staticWindow(comptime window_id: zin.StaticWindowId) type {
    return struct {
        const Self = @This();

        pub fn handle() win32.HWND {
            return global.static_windows[@backingInt(window_id)].?.asHwnd();
        }

        pub fn registerClass(
            comptime def: zin.WindowClassDefinition(window_id),
            config: zin.WindowClassRuntimeConfig,
        ) void {
            std.debug.assert(global.static_classes[@backingInt(window_id)] == null);
            global.static_classes[@backingInt(window_id)] = registerWindowClass(window_id, def, config);
        }
        pub fn unregisterClass() void {
            global.static_classes[@backingInt(window_id)].?.unregister();
        }
        pub fn create(opt: zin.CreateWindowOptions) zin.CreateWindowError!void {
            std.debug.assert(global.static_windows[@backingInt(window_id)] == null);
            const hwnd = try createWindow(
                global.static_classes[@backingInt(window_id)] orelse zin.debugPanicOrUnreachable(
                    "registerClass was not called for static window '{s}'",
                    .{@tagName(window_id)},
                ),
                &opt,
            );
            std.debug.assert(global.static_windows[@backingInt(window_id)] == windowFromHwnd(hwnd));
        }
        pub fn destroy() void {
            global.static_windows[@backingInt(window_id)].?.destroy();
        }
        pub fn getClientSize() zin.XY {
            return global.static_windows[@backingInt(window_id)].?.getClientSize();
        }
        pub fn show() void {
            global.static_windows[@backingInt(window_id)].?.show();
        }
        pub fn foreground() void {
            global.static_windows[@backingInt(window_id)].?.foreground();
        }
        pub fn invalidate() void {
            global.static_windows[@backingInt(window_id)].?.invalidate();
        }
        pub fn startTimerMillis(id: window_id.getConfig().TimerId(), millis: u32) void {
            global.static_windows[@backingInt(window_id)].?.startTimerMillis(
                zin.intFromTimerId(usize, window_id.getConfig().TimerId(), id),
                millis,
            );
        }
        pub fn startTimerNanos(id: window_id.getConfig().TimerId(), nanos: u64) void {
            global.static_windows[@backingInt(window_id)].?.startTimerNanos(
                zin.intFromTimerId(usize, window_id.getConfig().TimerId(), id),
                nanos,
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

pub const CreateWindowOptions = struct {};

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
    left_button = @backingInt(win32.VK_LBUTTON),
    right_button = @backingInt(win32.VK_RBUTTON),
    cancel = @backingInt(win32.VK_CANCEL),
    middle_button = @backingInt(win32.VK_MBUTTON),
    xbutton1 = @backingInt(win32.VK_XBUTTON1),
    xbutton2 = @backingInt(win32.VK_XBUTTON2),

    // Basic keys
    backspace = @backingInt(win32.VK_BACK),
    tab = @backingInt(win32.VK_TAB),
    clear = @backingInt(win32.VK_CLEAR),
    @"return" = @backingInt(win32.VK_RETURN),

    // Modifier keys
    // NOTE: we always map VK_SHIFT to either shift_left or shift_right
    shift_left = @backingInt(win32.VK_LSHIFT),
    shift_right = @backingInt(win32.VK_RSHIFT),
    // NOTE: we always map VK_CONTROL to either control_left or control_right
    control_left = @backingInt(win32.VK_LCONTROL),
    control_right = @backingInt(win32.VK_RCONTROL),
    // NOTE: we always map VK_MENU to either alt_left or alt_right
    alt_left = @backingInt(win32.VK_LMENU),
    alt_right = @backingInt(win32.VK_RMENU),

    pause = @backingInt(win32.VK_PAUSE),
    caps_lock = @backingInt(win32.VK_CAPITAL),

    // IME keys
    kana = @backingInt(win32.VK_KANA),
    ime_on = @backingInt(win32.VK_IME_ON),
    junja = @backingInt(win32.VK_JUNJA),
    final = @backingInt(win32.VK_FINAL),
    hanja = @backingInt(win32.VK_HANJA),
    ime_off = @backingInt(win32.VK_IME_OFF),

    escape = @backingInt(win32.VK_ESCAPE),
    convert = @backingInt(win32.VK_CONVERT),
    nonconvert = @backingInt(win32.VK_NONCONVERT),
    accept = @backingInt(win32.VK_ACCEPT),
    modechange = @backingInt(win32.VK_MODECHANGE),

    // Navigation keys
    page_up = @backingInt(win32.VK_PRIOR),
    page_down = @backingInt(win32.VK_NEXT),
    end = @backingInt(win32.VK_END),
    home = @backingInt(win32.VK_HOME),
    left = @backingInt(win32.VK_LEFT),
    up = @backingInt(win32.VK_UP),
    right = @backingInt(win32.VK_RIGHT),
    down = @backingInt(win32.VK_DOWN),
    select = @backingInt(win32.VK_SELECT),
    print = @backingInt(win32.VK_PRINT),
    execute = @backingInt(win32.VK_EXECUTE),
    print_screen = @backingInt(win32.VK_SNAPSHOT), // Print screen
    insert = @backingInt(win32.VK_INSERT),
    delete = @backingInt(win32.VK_DELETE),
    help = @backingInt(win32.VK_HELP),

    super_left = @backingInt(win32.VK_LWIN),
    super_right = @backingInt(win32.VK_RWIN),
    apps = @backingInt(win32.VK_APPS), // Application key
    sleep = @backingInt(win32.VK_SLEEP),

    numpad0 = @backingInt(win32.VK_NUMPAD0),
    numpad1 = @backingInt(win32.VK_NUMPAD1),
    numpad2 = @backingInt(win32.VK_NUMPAD2),
    numpad3 = @backingInt(win32.VK_NUMPAD3),
    numpad4 = @backingInt(win32.VK_NUMPAD4),
    numpad5 = @backingInt(win32.VK_NUMPAD5),
    numpad6 = @backingInt(win32.VK_NUMPAD6),
    numpad7 = @backingInt(win32.VK_NUMPAD7),
    numpad8 = @backingInt(win32.VK_NUMPAD8),
    numpad9 = @backingInt(win32.VK_NUMPAD9),
    multiply = @backingInt(win32.VK_MULTIPLY),
    add = @backingInt(win32.VK_ADD),
    separator = @backingInt(win32.VK_SEPARATOR),
    subtract = @backingInt(win32.VK_SUBTRACT),
    decimal = @backingInt(win32.VK_DECIMAL),
    divide = @backingInt(win32.VK_DIVIDE),

    f1 = @backingInt(win32.VK_F1),
    f2 = @backingInt(win32.VK_F2),
    f3 = @backingInt(win32.VK_F3),
    f4 = @backingInt(win32.VK_F4),
    f5 = @backingInt(win32.VK_F5),
    f6 = @backingInt(win32.VK_F6),
    f7 = @backingInt(win32.VK_F7),
    f8 = @backingInt(win32.VK_F8),
    f9 = @backingInt(win32.VK_F9),
    f10 = @backingInt(win32.VK_F10),
    f11 = @backingInt(win32.VK_F11),
    f12 = @backingInt(win32.VK_F12),
    f13 = @backingInt(win32.VK_F13),
    f14 = @backingInt(win32.VK_F14),
    f15 = @backingInt(win32.VK_F15),
    f16 = @backingInt(win32.VK_F16),
    f17 = @backingInt(win32.VK_F17),
    f18 = @backingInt(win32.VK_F18),
    f19 = @backingInt(win32.VK_F19),
    f20 = @backingInt(win32.VK_F20),
    f21 = @backingInt(win32.VK_F21),
    f22 = @backingInt(win32.VK_F22),
    f23 = @backingInt(win32.VK_F23),
    f24 = @backingInt(win32.VK_F24),

    numlock = @backingInt(win32.VK_NUMLOCK),
    scroll_lock = @backingInt(win32.VK_SCROLL),

    browser_back = @backingInt(win32.VK_BROWSER_BACK),
    browser_forward = @backingInt(win32.VK_BROWSER_FORWARD),
    browser_refresh = @backingInt(win32.VK_BROWSER_REFRESH),
    browser_stop = @backingInt(win32.VK_BROWSER_STOP),
    browser_search = @backingInt(win32.VK_BROWSER_SEARCH),
    browser_favorites = @backingInt(win32.VK_BROWSER_FAVORITES),
    browser_home = @backingInt(win32.VK_BROWSER_HOME),

    // volume_mute = @intFromEnum(win32.VK_VOLUME_MUTE),
    // volume_down = @intFromEnum(win32.VK_VOLUME_DOWN),
    // volume_up = @intFromEnum(win32.VK_VOLUME_UP),

    // media_next_track = @intFromEnum(win32.VK_MEDIA_NEXT_TRACK),
    // media_prev_track = @intFromEnum(win32.VK_MEDIA_PREV_TRACK),
    // media_stop = @intFromEnum(win32.VK_MEDIA_STOP),
    // media_play_pause = @intFromEnum(win32.VK_MEDIA_PLAY_PAUSE),

    launch_mail = @backingInt(win32.VK_LAUNCH_MAIL),
    launch_media_select = @backingInt(win32.VK_LAUNCH_MEDIA_SELECT),
    launch_app1 = @backingInt(win32.VK_LAUNCH_APP1),
    launch_app2 = @backingInt(win32.VK_LAUNCH_APP2),

    oem_1 = @backingInt(win32.VK_OEM_1), // Semicolon/Colon on US ANSI
    oem_plus = @backingInt(win32.VK_OEM_PLUS), // Equals/Plus
    oem_comma = @backingInt(win32.VK_OEM_COMMA), // Comma/Less Than
    oem_minus = @backingInt(win32.VK_OEM_MINUS), // Dash/Underscore
    oem_period = @backingInt(win32.VK_OEM_PERIOD), // Period/Greater Than
    oem_2 = @backingInt(win32.VK_OEM_2), // Forward Slash/Question Mark on US ANSI
    oem_3 = @backingInt(win32.VK_OEM_3), // Grave Accent/Tilde on US ANSI
    oem_4 = @backingInt(win32.VK_OEM_4), // Left Brace on US ANSI
    oem_5 = @backingInt(win32.VK_OEM_5), // Backslash/Pipe on US ANSI
    oem_6 = @backingInt(win32.VK_OEM_6), // Right Brace on US ANSI
    oem_7 = @backingInt(win32.VK_OEM_7), // Apostrophe/Double Quote on US ANSI
    oem_8 = @backingInt(win32.VK_OEM_8), // Varies by keyboard
    oem_102 = @backingInt(win32.VK_OEM_102), // Backslash/Pipe on European ISO
    processkey = @backingInt(win32.VK_PROCESSKEY), // IME PROCESS key
    packet = @backingInt(win32.VK_PACKET), // Used for Unicode characters as keystrokes

    attn = @backingInt(win32.VK_ATTN),
    crsel = @backingInt(win32.VK_CRSEL),
    exsel = @backingInt(win32.VK_EXSEL),
    ereof = @backingInt(win32.VK_EREOF),
    play = @backingInt(win32.VK_PLAY),
    zoom = @backingInt(win32.VK_ZOOM),
    noname = @backingInt(win32.VK_NONAME), // Reserved
    pa1 = @backingInt(win32.VK_PA1),
    oem_clear = @backingInt(win32.VK_OEM_CLEAR),
    _,

    // the following are duplicates
    pub const hangul = @backingInt(win32.VK_HANGUL);
    pub const kanji = @backingInt(win32.VK_KANJI);
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
            @backingInt(win32.VK_SHIFT) => switch (key_flags.scan_code) {
                0x2a => .shift_left, // typical mapping
                0x36 => .shift_right, // typical mapping
                else => .shift_left, // otherwise, we'll just always map this to left shift
            },
            @backingInt(win32.VK_CONTROL) => if (key_flags.extended) .control_right else .control_left,
            @backingInt(win32.VK_MENU) => if (key_flags.extended) .alt_right else .alt_left,
            else => @fromBackingInt(@intCast(@as(u16, @intCast(0xffff & wparam)))),
        },
        .scan_code = @fromBackingInt(@intCast(key_flags.scan_code)),
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

fn mouseDownFromWparam(wparam: win32.WPARAM) zin.MouseButtonsDown {
    const mk: win32.MODIFIERKEYS_FLAGS = @bitCast(@as(u32, @truncate(wparam)));
    return .{
        .left = mk.LBUTTON != 0,
        .right = mk.RBUTTON != 0,
        .middle = mk.MBUTTON != 0,
    };
}

const WndProc = fn (win32.HWND, u32, win32.WPARAM, win32.LPARAM) callconv(.winapi) win32.LRESULT;
pub fn makeWndProc(
    window_id: zin.StaticWindowId,
    class: zin.WindowClassDefinition(window_id),
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
                win32.WM_CREATE => {
                    std.debug.assert(null == global.static_windows[@backingInt(window_id)]);
                    global.static_windows[@backingInt(window_id)] = windowFromHwnd(hwnd);
                    return 0;
                },
                win32.WM_DESTROY => {
                    switch (window_id.getConfig().win32.render) {
                        .gdi => {},
                        .direct2d => {
                            global.releaseD2dObjects(window_id);
                            for (global.d2dStoredTexts(window_id)) |*stored| stored.release();
                        },
                    }
                    std.debug.assert(windowFromHwnd(hwnd) == global.static_windows[@backingInt(window_id)]);
                    global.static_windows[@backingInt(window_id)] = null;
                    return 0;
                },
                win32.WM_DISPLAYCHANGE => {
                    switch (window_id.getConfig().win32.render) {
                        .gdi => {},
                        // a paint is what finds a render target the change lost
                        .direct2d => win32.invalidateHwnd(hwnd),
                    }
                    return if (window_id.getConfig().win32.default_window_proc) |proc|
                        proc(hwnd, msg, wparam, lparam)
                    else
                        win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_ERASEBKGND => {
                    // TODO: we might want to call fill rect here in certain circumstances
                    return 0;
                },
                win32.WM_CLOSE => {
                    class.callback(.close);
                    return 0;
                },
                win32.WM_SETCURSOR => {
                    if (window_id.getConfig().win32.set_cursor_callback) {
                        var result: isize = 0;
                        class.callback(.{
                            .win32_set_cursor = .{ .result_ref = &result, .wparam = wparam, .lparam = lparam },
                        });
                        if (result != 0) return result;
                    }
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_PAINT => {
                    paint(window_id, class, hwnd);
                    return 0;
                },
                win32.WM_SIZE => {
                    if (window_id.getConfig().window_size_events) {
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
                    switch (window_id.getConfig().timers) {
                        .none => {},
                        .one => {
                            std.debug.assert(wparam == 1);
                            class.callback(.{ .timer = {} });
                        },
                        .type => |TimerId| class.callback(.{
                            .timer = zin.timerIdFromInt(TimerId, wparam),
                        }),
                    }
                    return 0;
                },
                win32.WM_DPICHANGED => {
                    const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    if (0 == win32.SetWindowPos(
                        hwnd,
                        null,
                        rect.left,
                        rect.top,
                        rect.right - rect.left,
                        rect.bottom - rect.top,
                        .{ .NOACTIVATE = 1, .NOZORDER = 1 },
                    )) win32.panicWin32("SetWindowPos", win32.GetLastError());
                    if (comptime window_id.getConfig().dpi_events) {
                        class.callback(.{ .dpi_change = {} });
                    }
                    return 0;
                },
                win32.WM_MENUCHAR => {
                    // Return MAKELRESULT(0, MNC_CLOSE) to close menu and prevent beep
                    return 0 | (@as(win32.LRESULT, 1) << 16); // MNC_CLOSE = 1
                },
                win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
                    if (comptime window_id.getConfig().key_events) class.callback(.{ .key = keyFromWin32(.down, wparam, lparam) });
                    if (msg == win32.WM_KEYDOWN) return 0;
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_KEYUP, win32.WM_SYSKEYUP => {
                    if (comptime window_id.getConfig().key_events) class.callback(.{ .key = keyFromWin32(.up, wparam, lparam) });
                    if (msg == win32.WM_KEYUP) return 0;
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                },
                win32.WM_MOUSEMOVE => {
                    if (comptime window_id.getConfig().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        class.callback(
                            .{ .mouse = .{
                                .position = .{ .x = pos.x, .y = pos.y },
                                .button = null,
                                .down = mouseDownFromWparam(wparam),
                            } },
                        );
                    }
                    return 0;
                },
                win32.WM_LBUTTONDOWN => {
                    if (comptime window_id.getConfig().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        class.callback(
                            .{ .mouse = .{
                                .position = .{ .x = pos.x, .y = pos.y },
                                .button = .{ .id = .left, .state = .down },
                                .down = mouseDownFromWparam(wparam),
                            } },
                        );
                    }
                    return 0;
                },
                win32.WM_LBUTTONUP => {
                    if (comptime window_id.getConfig().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        class.callback(
                            .{ .mouse = .{
                                .position = .{ .x = pos.x, .y = pos.y },
                                .button = .{ .id = .left, .state = .up },
                                .down = mouseDownFromWparam(wparam),
                            } },
                        );
                    }
                    return 0;
                },
                win32.WM_RBUTTONDOWN => {
                    if (comptime window_id.getConfig().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        class.callback(
                            .{ .mouse = .{
                                .position = .{ .x = pos.x, .y = pos.y },
                                .button = .{ .id = .right, .state = .down },
                                .down = mouseDownFromWparam(wparam),
                            } },
                        );
                    }
                    return 0;
                },
                win32.WM_RBUTTONUP => {
                    if (comptime window_id.getConfig().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        class.callback(
                            .{ .mouse = .{
                                .position = .{ .x = pos.x, .y = pos.y },
                                .button = .{ .id = .right, .state = .up },
                                .down = mouseDownFromWparam(wparam),
                            } },
                        );
                    }
                    return 0;
                },
                win32.WM_MBUTTONDOWN => {
                    if (comptime window_id.getConfig().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        class.callback(
                            .{ .mouse = .{
                                .position = .{ .x = pos.x, .y = pos.y },
                                .button = .{ .id = .middle, .state = .down },
                                .down = mouseDownFromWparam(wparam),
                            } },
                        );
                    }
                    return 0;
                },
                win32.WM_MBUTTONUP => {
                    if (comptime window_id.getConfig().mouse_events) {
                        const pos = win32.pointFromLparam(lparam);
                        class.callback(
                            .{ .mouse = .{
                                .position = .{ .x = pos.x, .y = pos.y },
                                .button = .{ .id = .middle, .state = .up },
                                .down = mouseDownFromWparam(wparam),
                            } },
                        );
                    }
                    return 0;
                },
                else => return if (window_id.getConfig().win32.default_window_proc) |proc|
                    proc(hwnd, msg, wparam, lparam)
                else
                    win32.DefWindowProcW(hwnd, msg, wparam, lparam),
            }
        }
    }).wndProc;
}

fn paint(
    comptime window_id: zin.StaticWindowId,
    class: zin.WindowClassDefinition(window_id),
    hwnd: win32.HWND,
) void {
    const paintdc, const ps = win32.beginPaint(hwnd);
    defer win32.endPaint(hwnd, &ps);
    var text_id_check: zin.TextIdCheck(window_id.getConfig().TextId) = .{};

    switch (window_id.getConfig().win32.render) {
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

            class.callback(
                .{ .draw = .{
                    .hwnd = hwnd,
                    .hdc = memdc,
                    .text_id_check = &text_id_check,
                    .background = if (comptime window_id.getConfig().dynamic_background) window_id.getConfig().background else {},
                } },
            );
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
            class.callback(
                .{ .draw = .{
                    .hwnd = hwnd,
                    .hdc = paintdc,
                    .text_id_check = &text_id_check,
                    .background = if (comptime window_id.getConfig().dynamic_background) window_id.getConfig().background else {},
                } },
            );
        },
        .direct2d => {
            const size = win32.getClientSize(hwnd);
            const target = global.updateD2dTarget(window_id, hwnd, size);
            target.ID2D1RenderTarget.BeginDraw();
            class.callback(.{ .draw = .{
                .hwnd = hwnd,
                .dpi = win32.dpiFromHwnd(hwnd),
                .text_id_check = &text_id_check,
                .d2d = &target.ID2D1RenderTarget,
                .client_size = .{ .x = size.cx, .y = size.cy },
                .background = if (comptime window_id.getConfig().dynamic_background) window_id.getConfig().background else {},
            } });
            const hr = target.ID2D1RenderTarget.EndDraw(null, null);
            if (hr.failed) {
                @branchHint(.unlikely);
                if (hr == win32.D2DERR_RECREATE_TARGET) {
                    global.releaseD2dObjects(window_id);
                    // the next paint makes a new target
                    win32.invalidateHwnd(hwnd);
                } else win32.panicHresult("ID2D1RenderTarget.EndDraw", hr);
            }
        },
    }
}

fn colorrefFromRgb8(rgb8: zin.Rgb8) win32.COLORREF {
    return .rgb(rgb8.r, rgb8.g, rgb8.b);
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

pub fn Draw(window_id: zin.StaticWindowId) type {
    return switch (window_id.getConfig().win32.render) {
        .gdi => GdiDraw(window_id),
        .direct2d => D2dDraw(window_id),
    };
}

fn GdiDraw(window_id: zin.StaticWindowId) type {
    return struct {
        hwnd: win32.HWND,
        hdc: win32.HDC,
        text_id_check: *zin.TextIdCheck(window_id.getConfig().TextId),
        background: if (window_id.getConfig().dynamic_background) zin.Rgb8 else void,

        const Self = @This();

        pub fn getDpiScale(self: *const Self) struct { x: f32, y: f32 } {
            const scale: f32 = @as(f32, @floatFromInt(win32.dpiFromHwnd(self.hwnd))) / 96.0;
            return .{ .x = scale, .y = scale };
        }

        pub fn clear(self: *const Self) void {
            const rgb = if (comptime window_id.getConfig().dynamic_background)
                self.background
            else
                window_id.getConfig().background;
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

        pub fn text(self: *const Self, id: window_id.getConfig().TextId, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            self.text_id_check.onText(id);
            if (win32.COLORREF.invalid == win32.SetTextColor(self.hdc, colorrefFromRgb8(rgb)))
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

fn d2dPoint(p: PolygonPoint) win32.D2D_POINT_2F {
    return .{ .x = @floatFromInt(p.point.x), .y = @floatFromInt(p.point.y) };
}

fn d2dColor(rgb: zin.Rgb8) win32.D2D_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
        .a = 1,
    };
}

fn D2dDraw(window_id: zin.StaticWindowId) type {
    return struct {
        hwnd: win32.HWND,
        dpi: u32,
        text_id_check: *zin.TextIdCheck(window_id.getConfig().TextId),
        /// The window's render target between BeginDraw and EndDraw, for the
        /// app's own Direct2D calls. Its units are pixels.
        d2d: *win32.ID2D1RenderTarget,
        /// The size of `d2d`.
        client_size: zin.XY,
        background: if (window_id.getConfig().dynamic_background) zin.Rgb8 else void,

        const Self = @This();

        pub fn getDpiScale(self: *const Self) struct { x: f32, y: f32 } {
            const scale: f32 = @as(f32, @floatFromInt(self.dpi)) / 96.0;
            return .{ .x = scale, .y = scale };
        }

        pub fn clear(self: *const Self) void {
            const rgb = if (comptime window_id.getConfig().dynamic_background)
                self.background
            else
                window_id.getConfig().background;
            self.d2d.Clear(&d2dColor(rgb));
        }

        /// The window's one solid color brush, set to `rgb`. The next call
        /// changes its color.
        pub fn solidBrush(self: *const Self, rgb: zin.Rgb8) *win32.ID2D1Brush {
            const objects = &global.d2d_objects[comptime d2dWindowIndex(window_id)].?;
            const brush = objects.brush orelse blk: {
                var brush: *win32.ID2D1SolidColorBrush = undefined;
                const hr = self.d2d.CreateSolidColorBrush(&d2dColor(rgb), null, &brush);
                if (hr.failed) win32.panicHresult("CreateSolidColorBrush", hr);
                objects.brush = brush;
                break :blk brush;
            };
            brush.SetColor(&d2dColor(rgb));
            return &brush.ID2D1Brush;
        }

        pub fn rect(self: *const Self, r: zin.Rect, rgb: zin.Rgb8) void {
            self.d2d.FillRectangle(&.{
                .left = @floatFromInt(r.left),
                .top = @floatFromInt(r.top),
                .right = @floatFromInt(r.right),
                .bottom = @floatFromInt(r.bottom),
            }, self.solidBrush(rgb));
        }

        /// 12 point Segoe UI in an unwrapped line, for the caller to release.
        fn createTextFormat(self: *const Self) *win32.IDWriteTextFormat {
            var format: *win32.IDWriteTextFormat = undefined;
            {
                const hr = dwriteFactory().CreateTextFormat(
                    win32.L("Segoe UI"),
                    null,
                    .NORMAL,
                    .NORMAL,
                    .NORMAL,
                    @as(f32, @floatFromInt(self.dpi)) * 12.0 / 72.0,
                    win32.L(""),
                    &format,
                );
                if (hr.failed) win32.panicHresult("CreateTextFormat", hr);
            }
            {
                const hr = format.SetWordWrapping(.NO_WRAP);
                if (hr.failed) win32.panicHresult("SetWordWrapping", hr);
            }
            return format;
        }

        /// The window keeps the layout of text `id`, so drawing the same text
        /// again at the same DPI doesn't lay it out again.
        pub fn text(self: *const Self, id: window_id.getConfig().TextId, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            self.text_id_check.onText(id);
            const stored = &global.d2dStoredTexts(window_id)[@backingInt(id)];
            const hash = std.hash.Wyhash.hash(0, t);
            const layout = blk: {
                if (stored.layout) |layout| {
                    if (stored.hash == hash and stored.len == t.len and stored.dpi == self.dpi) break :blk layout;
                    stored.release();
                }
                // CreateTextLayout takes UTF-16
                var buf: [1000]u16 = undefined;
                if (t.len >= buf.len) std.debug.panic("text is {d} bytes, the max is {d}", .{ t.len, buf.len - 1 });
                const len = std.unicode.wtf8ToWtf16Le(&buf, t) catch std.debug.panic("text isn't valid WTF-8: '{s}'", .{t});
                const format = self.createTextFormat();
                defer _ = format.IUnknown.Release();
                var layout: *win32.IDWriteTextLayout = undefined;
                const hr = dwriteFactory().CreateTextLayout(
                    @ptrCast(&buf),
                    @intCast(len),
                    format,
                    std.math.floatMax(f32),
                    std.math.floatMax(f32),
                    &layout,
                );
                if (hr.failed) win32.panicHresult("CreateTextLayout", hr);
                stored.* = .{ .layout = layout, .hash = hash, .len = t.len, .dpi = self.dpi };
                break :blk layout;
            };
            self.d2d.DrawTextLayout(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, layout, self.solidBrush(rgb), .{});
        }

        pub fn polygon(self: *const Self, points: []const PolygonPoint, color: zin.Rgb8) void {
            if (points.len < 3) std.debug.panic("a polygon needs 3 points, got {d}", .{points.len});
            var geometry: *win32.ID2D1PathGeometry = undefined;
            {
                const hr = d2dFactory(window_id.getConfig().thread).CreatePathGeometry(&geometry);
                if (hr.failed) win32.panicHresult("CreatePathGeometry", hr);
            }
            defer _ = geometry.IUnknown.Release();
            {
                var sink: *win32.ID2D1GeometrySink = undefined;
                const hr = geometry.Open(&sink);
                if (hr.failed) win32.panicHresult("ID2D1PathGeometry.Open", hr);
                defer _ = sink.IUnknown.Release();
                const simple = &sink.ID2D1SimplifiedGeometrySink;
                simple.BeginFigure(d2dPoint(points[0]), .FILLED);
                for (points[1..]) |p| sink.AddLine(d2dPoint(p));
                simple.EndFigure(.CLOSED);
                const close_hr = simple.Close();
                if (close_hr.failed) win32.panicHresult("ID2D1GeometrySink.Close", close_hr);
            }
            self.d2d.FillGeometry(&geometry.ID2D1Geometry, self.solidBrush(color), null);
        }
    };
}
