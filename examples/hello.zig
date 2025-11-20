const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin");
const win32 = zin.platform.win32;

pub const zin_config: zin.Config = .{
    .StaticWindowId = StaticWindowId,
    // An optional callback if an x11 unhandled reply comes in.  Allows apps to
    // send their own X11 requests outside of what Zin supports.
    .x11_unhandled_reply = x11UnhandledReply,
};
const StaticWindowId = enum {
    main,
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

    try zin.staticWindow(.main).create(.{
        .title = "Hello Example",
        .size = .{ .client_points = .{ .x = 300, .y = 200 } },
        .pos = null,
    });
    defer zin.staticWindow(.main).destroy();
    zin.staticWindow(.main).show();
    zin.staticWindow(.main).startTimer({}, 14);

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
