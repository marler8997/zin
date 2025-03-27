const std = @import("std");
const zin = @import("zin.zig");
const win32 = @import("win32").everything;
const WINAPI = std.os.windows.WINAPI;
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

pub const WindowConfig = struct {
    render: union(enum) {
        gdi: struct {
            use_backbuffer: bool = true,
        },
    } = .{ .gdi = .{} },
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
) WindowClass {
    return registerWindowClass(.{ .dynamic = config }, def);
}

fn registerWindowClass(
    comptime window_config: zin.WindowConfig,
    comptime def: zin.WindowClassDefinition(window_config),
) WindowClass {
    var c: win32.WNDCLASSW = .{
        // TODO: create a option to enable/disable double clicks,
        //       enabling them will change how window events are sent
        // .DBLCLKS = 1
        .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
        .lpfnWndProc = makeWndProc(window_config, def),
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = def.win32_name,
    };
    const atom = win32.RegisterClassW(&c);
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
        pub fn registerClass(comptime def: zin.WindowClassDefinition(.{ .static = window_id })) void {
            std.debug.assert(global.static_classes[@intFromEnum(window_id)] == null);
            global.static_classes[@intFromEnum(window_id)] = registerWindowClass(.{ .static = window_id }, def);
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
        pub fn startTimer(id: usize, millis: u32) void {
            global.static_windows[@intFromEnum(window_id)].?.startTimer(id, millis);
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
            .client => |s| s, // we'll adjust the size below
            .window => |s| s,
        };
    };

    const hwnd = win32.CreateWindowExW(
        style_ex,
        @ptrFromInt(class.atom),
        @ptrCast(&title_buf),
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
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

    switch (opt.size) {
        .default => {},
        .client => |client_size| {
            const dpi = win32.dpiFromHwnd(hwnd);
            const window_size = windowSizeFromClient(client_size, style, style_ex, dpi);
            if (0 == win32.SetWindowPos(
                hwnd,
                null,
                0,
                0,
                window_size.x,
                window_size.y,
                .{ .NOACTIVATE = 1, .NOMOVE = 1, .NOZORDER = 1 },
            )) win32.panicWin32("SetWindowPos", win32.GetLastError());
        },
        .window => {},
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

pub const VirtualKey = enum(usize) {
    n = @intFromEnum(win32.VK_N),
    _,
};

var start_time: ?u32 = null;
fn getTime() u32 {
    const t = start_time orelse {
        start_time = win32.GetTickCount();
        return 0;
    };
    return win32.GetTickCount() - t;
}

const WndProc = fn (win32.HWND, u32, win32.WPARAM, win32.LPARAM) callconv(WINAPI) win32.LRESULT;
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
        ) callconv(WINAPI) win32.LRESULT {
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
                win32.WM_PAINT => {
                    paint(config, class, hwnd);
                    return 0;
                },
                win32.WM_TIMER => {
                    if (comptime config.data().timers) switch (config) {
                        .static => class.callback(.{ .timer = wparam }),
                        .dynamic => class.callback(windowFromHwnd(hwnd), .{ .timer = wparam }),
                    };
                    return 0;
                },
                win32.WM_KEYDOWN => {
                    if (comptime config.data().key_events) switch (config) {
                        .static => class.callback(
                            .{ .key = .{ .state = .down, .vk = @enumFromInt(wparam) } },
                        ),
                        .dynamic => class.callback(
                            windowFromHwnd(hwnd),
                            .{ .key = .{ .state = .down, .vk = @enumFromInt(wparam) } },
                        ),
                    };
                    return 0;
                },
                win32.WM_KEYUP => {
                    if (comptime config.data().key_events) switch (config) {
                        .static => class.callback(
                            .{ .key = .{ .state = .up, .vk = @enumFromInt(wparam) } },
                        ),
                        .dynamic => class.callback(
                            windowFromHwnd(hwnd),
                            .{ .key = .{ .state = .up, .vk = @enumFromInt(wparam) } },
                        ),
                    };
                    return 0;
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
                else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
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

pub fn Draw(window_config: zin.WindowConfig) type {
    return struct {
        hwnd: win32.HWND,
        hdc: win32.HDC,
        background: if (window_config.data().dynamic_background) zin.Rgb8 else void,

        const Self = @This();

        pub fn getDpiScale(self: *const Self) f32 {
            return @as(f32, @floatFromInt(win32.dpiFromHwnd(self.hwnd))) / 96.0;
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
    };
}
