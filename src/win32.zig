const std = @import("std");
const zin = @import("zin.zig");
const win32 = @import("win32").everything;
const WINAPI = std.os.windows.WINAPI;

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
pub fn registerWindowClass(
    comptime window_config: zin.WindowConfig,
    comptime def: zin.WindowClassDefinition(window_config),
) WindowClass {
    var c: win32.WNDCLASSW = .{
        .style = .{ .VREDRAW = 1, .HREDRAW = 1, .DBLCLKS = 1 },
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
    pub fn getClientSize(self: Window) zin.Size {
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
    var static_windows: [static_window_count]?Window = @splat(null);
};

pub fn StaticWindow(window_id: zin.StaticWindowId) type {
    return struct {
        const Self = @This();
        pub fn create(
            self: Self,
            opt: zin.CreateWindowOptions,
        ) zin.CreateWindowError!void {
            _ = self;
            std.debug.assert(global.static_windows[@intFromEnum(window_id)] == null);
            global.static_windows[@intFromEnum(window_id)] = windowFromHwnd(try createWindow(&opt));
        }
        pub fn destroy(self: Self) void {
            _ = self;
            global.static_windows[@intFromEnum(window_id)].?.destroy();
        }
        pub fn getClientSize(self: Self) zin.Size {
            _ = self;
            return global.static_windows[@intFromEnum(window_id)].?.getClientSize();
        }
        pub fn show(self: Self) void {
            _ = self;
            global.static_windows[@intFromEnum(window_id)].?.show();
        }
        pub fn foreground(self: Self) void {
            _ = self;
            global.static_windows[@intFromEnum(window_id)].?.foreground();
        }
        pub fn invalidate(self: Self) void {
            _ = self;
            global.static_windows[@intFromEnum(window_id)].?.invalidate();
        }
        pub fn startTimer(self: Self, id: usize, millis: u32) void {
            _ = self;
            global.static_windows[@intFromEnum(window_id)].?.startTimer(id, millis);
        }
    };
}
pub fn staticWindow(comptime window_id: zin.StaticWindowId) StaticWindow(window_id) {
    return StaticWindow(window_id){};
}

pub fn createDynamicWindow(opt: zin.CreateWindowOptions) zin.CreateWindowError!DynamicWindow {
    return windowFromHwnd(try createWindow(&opt));
}

fn createWindow(opt: *const zin.CreateWindowOptions) zin.CreateWindowError!win32.HWND {
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
    const size: zin.XY(i32) = blk: {
        break :blk switch (opt.size) {
            .default => .{ .x = win32.CW_USEDEFAULT, .y = win32.CW_USEDEFAULT },
            .client => @panic("todo: need to call AdjustWindowRectEx"),
            .window => |s| s,
        };
    };

    return win32.CreateWindowExW(
        style_ex,
        @ptrFromInt(opt.class.atom),
        @ptrCast(&title_buf),
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        size.x,
        size.y,
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse
        // I'm not sure if it's worth trying to propagate/handle CreateWindow errors
        win32.panicWin32("CreateWindow", win32.GetLastError());
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

pub const MouseCoord = i32;
pub const SizeCoord = i32;

const WndProc = fn (win32.HWND, u32, win32.WPARAM, win32.LPARAM) callconv(WINAPI) win32.LRESULT;
pub fn makeWndProc(
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
            switch (msg) {
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
                                .{ .mouse = .{ .position = .{ .x = pos.x, .y = pos.y } } },
                            ),
                            .dynamic => class.callback(
                                windowFromHwnd(hwnd),
                                .{ .mouse = .{ .position = .{ .x = pos.x, .y = pos.y } } },
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
            switch (config) {
                .static => class.callback(
                    .{ .draw = .{ .hwnd = hwnd, .hdc = memdc } },
                ),
                .dynamic => class.callback(
                    windowFromHwnd(hwnd),
                    .{ .draw = .{ .hwnd = hwnd, .hdc = memdc } },
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
            switch (config) {
                .static => class.callback(
                    .{ .draw = .{ .hwnd = hwnd, .hdc = paintdc } },
                ),
                .dynamic => class.callback(
                    windowFromHwnd(hwnd),
                    .{ .draw = .{ .hwnd = hwnd, .hdc = paintdc } },
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

pub const Draw = struct {
    hwnd: win32.HWND,
    hdc: win32.HDC,

    pub fn clear(self: Draw, rgb: zin.Rgb8) void {
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

    pub fn text(self: Draw, t: []const u8, x: i32, y: i32) void {
        if (0 == win32.TextOutA(
            self.hdc,
            x,
            y,
            @ptrCast(t.ptr),
            @intCast(t.len),
        )) win32.panicWin32("TextOut", win32.GetLastError());
    }
};
