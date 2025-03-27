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
    .win32 = .{ .render = .{ .gdi = .{ .use_backbuffer = false } } },
};

const global = struct {
    var class_extra: ?zin.WindowClass = null;
    var last_animation: ?std.time.Instant = null;
    var text_position: f32 = 0;
    var mouse_position: ?zin.MousePosition = null;
};

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    try zin.connect(arena, .{});
    defer zin.disconnect(arena);

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: I don't think we need to call registerWindowClass for static windows
    //       also, static windows won't need certain data like the hwnd/etc,
    //       that could all be stored globally
    const class = zin.registerWindowClass(.{ .static = .main }, .{
        .callback = callback,
        .win32_name = zin.L("HelloMainWindow"),
    });
    defer class.unregister();
    try zin.staticWindow(.main).create(.{
        .class = class,
        .title = "Hello Example",
        .size = .{ .window = .{ .x = 300, .y = 200 } },
    });
    defer zin.staticWindow(.main).destroy();
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
            d.clear(.white);
            d.text("Press 'N' to create a new window.", 10, 50);
            d.text(
                "Weeee!!!",
                @intFromFloat(@round(@as(f32, @floatFromInt(size.x)) * global.text_position)),
                @intFromFloat(@round(@as(f32, @floatFromInt(size.y)) * global.text_position)),
            );
            if (global.mouse_position) |p| {
                d.text("Mouse", p.x, p.y);
            }
        },
        .timer => zin.staticWindow(.main).invalidate(),
        .key => |key| {
            if (key.vk == .n) {
                if (global.class_extra == null) {
                    global.class_extra = zin.registerWindowClass(.{ .dynamic = extra_config }, .{
                        .callback = extraCallback,
                        .win32_name = zin.L("HelloExtraWindow"),
                    });
                }
                const w = zin.createDynamicWindow(.{
                    .class = global.class_extra.?,
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
            d.clear(.full_red);
            //var buf: [100]u8 = undefined;
            //zin.text(@import("std").fmt.bufPrint(&buf, "ExtraWindow {}", .{i}), 10, 10);
            d.text("Extra", 10, 10);
        },
    }
}
