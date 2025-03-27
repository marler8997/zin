const std = @import("std");
const zin = @import("zin");

pub const zin_config: zin.Config = .{
    .StaticWindowId = StaticWindowId,
};
const StaticWindowId = enum {
    main,
    pub fn getConfig(self: StaticWindowId) zin.WindowConfigData {
        return switch (self) {
            .main => .{
                .key_events = true,
                .mouse_events = true,
                .timers = true,
                .background = .{ .r = 49, .g = 49, .b = 49 },
                .dynamic_background = false,
                .win32 = .{ .render = .{ .gdi = .{} } },
            },
        };
    }
};

pub const panic = zin.panic(.{ .title = "Hello Panic!" });

const extra_config: zin.WindowConfigData = .{
    .key_events = false,
    .mouse_events = false,
    .timers = false,
    .background = .{ .r = 255, .g = 0, .b = 0 },
    .dynamic_background = true,
    .win32 = .{ .render = .{ .gdi = .{ .use_backbuffer = false } } },
};

const global = struct {
    var class_extra: ?zin.WindowClass = null;
    var last_animation: ?std.time.Instant = null;
    var text_position: f32 = 0;
    var mouse_position: ?zin.XY = null;
};

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    try zin.loadAppKit();
    try zin.enforceDpiAware();

    try zin.connect(arena, .{});
    defer zin.disconnect(arena);

    zin.staticWindow(.main).registerClass(.{
        .callback = callback,
        .win32_name = zin.L("HelloMainWindow"),
        .macos_view = "HelloView",
    });
    defer zin.staticWindow(.main).unregisterClass();
    try zin.staticWindow(.main).create(.{
        .title = "Hello Example",
        .size = .{ .client = .{ .x = 300, .y = 200 } },
    });
    // TODO: not working for x11 yet, closing the window
    //       seems to close the entire X11 connection right now?
    defer if (zin.platform_kind != .x11) zin.staticWindow(.main).destroy();
    zin.staticWindow(.main).show();
    zin.staticWindow(.main).startTimer(0, 14);

    try zin.mainLoop();
}

fn callback(cb: zin.Callback(.{ .static = .main })) void {
    switch (cb) {
        .close => zin.quitMainLoop(),
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
            d.rect(.ltwh(animate.x, size.y - animate.y, 10, 10), .red);
            d.text("Press 'N' to create a new window.", 10, 50, .white);
            d.text("Weeee!!!", animate.x, animate.y, .white);
            if (global.mouse_position) |p| {
                d.text("Mouse", p.x, p.y, .white);
            }
        },
        .timer => zin.staticWindow(.main).invalidate(),
        .key => |key| {
            if (key.vk == .n) {
                if (global.class_extra == null) {
                    global.class_extra = zin.registerDynamicWindowClass(extra_config, .{
                        .callback = extraCallback,
                        .win32_name = zin.L("HelloExtraWindow"),
                        .macos_view = "HelloExtraView",
                    });
                }
                const w = zin.createDynamicWindow(global.class_extra.?, .{
                    .title = "Extra Window!",
                    .size = .{ .window = .{ .x = 200, .y = 150 } },
                }) catch |e| std.debug.panic("createWindow failed with {s}", .{@errorName(e)});
                // TODO: place the new window on top of the current
                //       one but don't have it take the input focus
                w.show();
                zin.staticWindow(.main).foreground();
            }
        },
        .mouse => |mouse| {
            global.mouse_position = mouse.position;
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
