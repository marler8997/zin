const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin");
const win32 = zin.platform.win32;

pub const zin_config: zin.Config = .{
    .StaticWindowId = StaticWindowId,
    .x11_on_visual = x11Visual,
    // An optional callback if an x11 unhandled reply comes in.  Allows apps to
    // send their own X11 requests outside of what Zin supports.
    .x11_on_unhandled_reply = x11UnhandledReply,
};
const StaticWindowId = enum {
    main,
    testWin32,
    pub fn getConfig(self: StaticWindowId) zin.WindowConfigData {
        return switch (self) {
            .main => .{
                .window_size_events = true,
                .key_events = true,
                .mouse_events = true,
                .timers = .one,
                .background = .{ .r = 49, .g = 49, .b = 49 },
                .dynamic_background = false,
                .win32 = .{ .render = .{ .gdi = .{} } },
                .x11 = .{ .render_kind = .double_buffered },
            },
            .testWin32 => .{
                .window_size_events = true,
                .key_events = false,
                .mouse_events = false,
                .timers = .none,
                .background = .{ .r = 49, .g = 49, .b = 49 },
                .dynamic_background = false,
                .win32 = .{ .render = .{ .gdi = .{} } },
                .x11 = .{ .render_kind = .immediate },
            },
        };
    }
};

pub const panic = zin.panic(.{ .title = "Hello Panic!" });

const extra_config: zin.WindowConfigData = .{
    .window_size_events = false,
    .key_events = false,
    .mouse_events = false,
    .timers = .none,
    .background = .{ .r = 255, .g = 0, .b = 0 },
    .dynamic_background = true,
    .win32 = .{ .render = .{ .gdi = .{ .use_backbuffer = false } } },
    .x11 = .{ .render_kind = .double_buffered },
};

const global = struct {
    var class_extra: ?zin.WindowClass = null;
    var last_animation: ?std.time.Instant = null;
    var text_position: f32 = 0;
    var mouse_position: ?zin.XY = null;
    var mouse_down: zin.MouseButtonsDown = .{
        .left = false,
        .right = false,
        .middle = false,
    };
    var test_win32_created: bool = false;
};

const test_win32_class: zin.WindowClassDefinition(.{ .static = .testWin32 }) = .{
    .callback = testWin32Callback,
    .win32_name = zin.L("TestWin32Window"),
    .macos_view = "TestWin32View",
};

pub fn main() !void {
    // one-time process initialization
    try zin.processInit(.{});

    {
        var err: zin.X11ConnectError = undefined;
        zin.x11Connect(&err) catch std.debug.panic("X11 connect failed: {f}", .{err});
    }
    defer zin.x11Disconnect();

    const icons = getIcons(96, 96);

    zin.staticWindow(.main).registerClass(.{
        .callback = callback,
        .win32_name = zin.L("HelloMainWindow"),
        .macos_view = "HelloView",
    }, .{
        .win32_icon_large = icons.large,
        .win32_icon_small = icons.small,
    });
    defer zin.staticWindow(.main).unregisterClass();
    zin.staticWindow(.testWin32).registerClass(test_win32_class, .{
        .win32_icon_large = icons.large,
        .win32_icon_small = icons.small,
        .win32_wndproc = switch (builtin.os.tag) {
            .windows => &testWin32Wndproc,
            else => {},
        },
    });
    defer zin.staticWindow(.testWin32).unregisterClass();

    try zin.staticWindow(.main).create(.{
        .title = "Hello Example",
        .size = .{ .client_points = .{ .x = 300, .y = 200 } },
        .pos = null,
    });
    defer zin.staticWindow(.main).destroy();
    zin.staticWindow(.main).show();
    zin.staticWindow(.main).startTimerMillis({}, 14);

    try zin.staticWindow(.testWin32).create(.{
        .title = "Test Win32",
        .size = .{ .client_points = .{ .x = 300, .y = 200 } },
        .pos = null,
    });
    global.test_win32_created = true;
    defer if (global.test_win32_created) zin.staticWindow(.testWin32).destroy();
    zin.staticWindow(.testWin32).show();

    try zin.mainLoop();
}

fn callback(cb: zin.Callback(.{ .static = .main })) void {
    switch (cb) {
        .close => zin.quitMainLoop(),
        .window_size => {},
        .draw => |d| {
            {
                const now = std.time.Instant.now() catch @panic("?");
                const elapsed_ns = if (global.last_animation) |l| now.since(l) else 0;
                global.last_animation = now;

                const speed: f32 = 0.0000000001;
                global.text_position = @mod(global.text_position + speed * @as(f32, @floatFromInt(elapsed_ns)), 1.0);
            }

            const size = zin.staticWindow(.main).getClientSize();
            d.clear();
            const animate: zin.XY = .{
                .x = @intFromFloat(@round(@as(f32, @floatFromInt(size.x)) * global.text_position)),
                .y = @intFromFloat(@round(@as(f32, @floatFromInt(size.y)) * global.text_position)),
            };
            const dpi_scale = d.getDpiScale();

            // currenly only supported on windows
            if (zin.platform_kind == .win32 or zin.platform_kind == .x11) {
                var pentagon = [5]zin.PolygonPoint{
                    .xy(zin.scale(i32, 200, dpi_scale.x), zin.scale(i32, 127, dpi_scale.y)), // top
                    .xy(zin.scale(i32, 232, dpi_scale.x), zin.scale(i32, 150, dpi_scale.y)), // top right
                    .xy(zin.scale(i32, 220, dpi_scale.x), zin.scale(i32, 187, dpi_scale.y)), // bottom right
                    .xy(zin.scale(i32, 180, dpi_scale.x), zin.scale(i32, 187, dpi_scale.y)), // bottom left
                    .xy(zin.scale(i32, 168, dpi_scale.x), zin.scale(i32, 150, dpi_scale.y)), // top left
                };
                d.polygon(&pentagon, .blue);
            }

            const rect_size = zin.scale(i32, 10, dpi_scale.x);
            d.rect(.ltwh(animate.x, size.y - animate.y, rect_size, rect_size), .red);
            const margin_left = zin.scale(i32, 10, dpi_scale.x);
            const top = zin.scale(i32, 50, dpi_scale.y);
            d.text("Press 'n' to create a new window.", margin_left, top, .white);
            {
                var str_buf: [100]u8 = undefined;
                const str = std.fmt.bufPrint(&str_buf, "Mouse left:{s} right:{s} middle:{s}", .{
                    if (global.mouse_down.left) "1" else "0",
                    if (global.mouse_down.right) "1" else "0",
                    if (global.mouse_down.middle) "1" else "0",
                }) catch unreachable;
                d.text(str, margin_left, top + zin.scale(i32, 20, dpi_scale.y), .white);
            }
            d.text("Weeee!!!", animate.x, animate.y, .white);
            if (global.mouse_position) |p| {
                d.text("Mouse", p.x, p.y, .white);
            }
        },
        .timer => zin.staticWindow(.main).invalidate(),
        .key => |key| {
            var keyboard_state: zin.UnicodeKeyboardState = .init();
            const utf8 = key.utf8(keyboard_state.ref());
            if (null != std.mem.indexOfScalar(u8, utf8.slice(), 'n')) {
                if (global.class_extra == null) {
                    global.class_extra = zin.registerDynamicWindowClass(extra_config, .{
                        .callback = extraCallback,
                        .win32_name = zin.L("HelloExtraWindow"),
                        .macos_view = "HelloExtraView",
                    }, .{
                        .win32_icon_large = .none,
                        .win32_icon_small = .none,
                    });
                }
                const w = zin.createDynamicWindow(global.class_extra.?, .{
                    .title = "Extra Window!",
                    .size = .{ .window_points = .{ .x = 200, .y = 150 } },
                    .pos = null,
                }) catch |e| std.debug.panic("createWindow failed with {s}", .{@errorName(e)});
                // TODO: place the new window on top of the current
                //       one but don't have it take the input focus
                w.show();
                zin.staticWindow(.main).foreground();
            }
        },
        .mouse => |mouse| {
            global.mouse_position = mouse.position;
            global.mouse_down = mouse.down;
            zin.staticWindow(.main).invalidate();
        },
    }
}

fn testWin32Wndproc(
    hwnd: zin.HWND,
    msg: u32,
    wparam: zin.WPARAM,
    lparam: zin.LPARAM,
) callconv(.winapi) zin.LRESULT {
    std.log.info("TestWin32: msg={} wparam={} lparam={}", .{ msg, lparam, wparam });
    return zin.platform.makeWndProc(.{ .static = .testWin32 }, test_win32_class)(
        hwnd,
        msg,
        wparam,
        lparam,
    );
}

fn testWin32Callback(cb: zin.Callback(.{ .static = .testWin32 })) void {
    switch (cb) {
        .close => {
            zin.staticWindow(.testWin32).destroy();
            global.test_win32_created = false;
        },
        .window_size => {},
        .draw => |d| {
            d.clear();
            d.text("Test Win32 Window", 10, 10, .red);
        },
    }
}

fn extraCallback(
    window: zin.DynamicWindow,
    cb: zin.Callback(.{ .dynamic = extra_config }),
) void {
    switch (cb) {
        .close => window.destroy(),
        .draw => |d| {
            //d.clear(.full_red);
            d.clear();
            //var buf: [100]u8 = undefined;
            //zin.text(@import("std").fmt.bufPrint(&buf, "ExtraWindow {}", .{i}), 10, 10);
            d.text("Extra", 10, 10, .white);
        },
    }
}

fn x11Visual(screen_index: u8, depth: u8, visual_index: u16, visual: *const zin.X11VisualType) void {
    std.log.info(
        "X11 Visual screen[{}] depth {} visual[{}] id={} class={f} bits-per-ch={} map_cnt={} red=0x{x} grn=0x{x} blu=0x{x}",
        .{
            screen_index,
            depth,
            visual_index,
            @intFromEnum(visual.id),
            zin.fmtEnum(visual.class),
            visual.bits_per_rgb_value,
            visual.colormap_entries,
            visual.red_mask,
            visual.green_mask,
            visual.blue_mask,
        },
    );
}
fn x11UnhandledReply(flex: u8, seq: u16, words: u32) error{ X11Protocol, ReadFailed, EndOfStream }!void {
    std.log.err("not handling x11 reply (flex={}, seq={}, {} words)", .{ flex, seq, words });
}

const Icons = struct {
    small: zin.MaybeWin32Icon,
    large: zin.MaybeWin32Icon,
};
fn getIcons(dpi_x: u32, dpi_y: u32) Icons {
    if (builtin.os.tag == .windows) {
        const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi_x);
        const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi_y);
        const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi_x);
        const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi_y);
        std.log.info("icons small={}x{} large={}x{} at dpi {}x{}", .{
            small_x, small_y,
            large_x, large_y,
            dpi_x,   dpi_y,
        });
        const small = win32.LoadImageW(
            win32.GetModuleHandleW(null),
            @ptrFromInt(1), // resource id
            .ICON,
            small_x,
            small_y,
            win32.LR_SHARED,
        );
        if (small == null)
            std.debug.panic("LoadImage for small icon failed, error={f}", .{win32.GetLastError()});
        const large = win32.LoadImageW(
            win32.GetModuleHandleW(null),
            @ptrFromInt(1), // resource id
            .ICON,
            large_x,
            large_y,
            win32.LR_SHARED,
        );
        if (large == null)
            std.debug.panic("LoadImage for large icon failed, error={f}", .{win32.GetLastError()});
        return .{
            .small = .init(@ptrCast(small)),
            .large = .init(@ptrCast(large)),
        };
    }
    return .{ .small = .none, .large = .none };
}
