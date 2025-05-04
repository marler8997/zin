const std = @import("std");
const zin = @import("zin.zig");
const c = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
    // @cInclude("CoreFoundation/CoreFoundation.h");
});
const objc = @import("objc");
const cg = @import("macos/cg.zig");

const log = std.log.scoped(.macos);

extern "c" fn NSApplicationLoad() c_char;

pub fn loadAppKit() error{NSApplicationLoadFailed}!void {
    if (0 == NSApplicationLoad()) return error.NSApplicationLoadFailed;
}

fn modalAlert(
    title: [*:0]const u8,
    msg: [*:0]const u8,
    button: [*:0]const u8,
) void {
    const alert = NSAlert.alloc();
    defer alert.release();
    alert.init();
    alert.setAlertStyle(.critical);
    {
        const info_ns = NSString.stringWithUTF8String(msg);
        defer info_ns.release();
        alert.setInformativeText(info_ns);
    }
    {
        const title_ns = NSString.stringWithUTF8String(title);
        defer title_ns.release();
        alert.setMessageText(title_ns);
    }
    {
        const ok_ns = NSString.stringWithUTF8String(button);
        defer ok_ns.release();
        alert.addButtonWithTitle(ok_ns);
    }

    {
        const shared_app = NSApplication.sharedApplication();
        _ = shared_app.activateIgnoringOtherApps(true);
        alert.window().makeKeyAndOrderFront();
    }

    alert.runModal();
}

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
                modalAlert(panic_opt.title, msg_z, "OK");
            }
            std.debug.defaultPanic(msg, ret_addr);
        }
    }.panic);
}

const static_window_count = @typeInfo(zin.StaticWindowId).@"enum".fields.len;
const global = struct {
    var static_classes: [static_window_count]?AnyZinView = @splat(null);
    var static_windows: [static_window_count]?NSWindow = @splat(null);
};

pub fn staticWindow(window_id: zin.StaticWindowId) type {
    const config = zin.WindowConfig{ .static = window_id };
    _ = config;
    return struct {
        const Self = @This();

        pub fn registerClass(comptime def: zin.WindowClassDefinition(.{ .static = window_id })) void {
            std.debug.assert(global.static_classes[@intFromEnum(window_id)] == null);
            const view = ZinView(.{ .static = window_id }, def).create();
            global.static_classes[@intFromEnum(window_id)] = view.any();
        }
        pub fn unregisterClass() void {}
        pub fn create(opt: zin.CreateWindowOptions) zin.CreateWindowError!void {
            std.debug.assert(global.static_windows[@intFromEnum(window_id)] == null);
            global.static_windows[@intFromEnum(window_id)] = try createWindow(
                // global.static_classes[@intFromEnum(window_id)] orelse zin.debugPanicOrUnreachable(
                //     "registerClass was not called for static window '{s}'",
                //     .{@tagName(window_id)},
                // ),
                &opt,
                global.static_classes[@intFromEnum(window_id)] orelse zin.debugPanicOrUnreachable(
                    "registerClass was not called for static window '{s}'",
                    .{@tagName(window_id)},
                ),
            );
        }
        pub fn destroy() void {}
        pub fn getClientSize() zin.XY {
            const view = global.static_windows[@intFromEnum(window_id)].?.contentView();
            return (AnyZinView{ .obj = view }).getClientSize();
        }
        pub fn show() void {
            //@panic("todo");
        }
        pub fn foreground() void {
            @panic("todo: implement foreground");
        }
        pub fn invalidate() void {
            const view = global.static_windows[@intFromEnum(window_id)].?.contentView();
            return (AnyZinView{ .obj = view }).setNeedsDisplay(true);
        }
        pub fn startTimer(id: usize, millis: u32) void {
            const view = global.static_windows[@intFromEnum(window_id)].?.contentView();
            const seconds = @as(f64, @floatFromInt(millis)) / 1000.0;
            const timer = getClass("NSTimer").msgSend(objc.Object, "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{
                seconds,
                view,
                objc.sel("handleTimer:"),
                // TODO: should we release this number?
                NSNumber.numberWithUnsignedLong(id).obj, // Store timer ID in userInfo
                true, // repeating
            });
            // Ensure the timer is retained and added to the current run loop
            const run_loop = getClass("NSRunLoop").msgSend(objc.Object, "currentRunLoop", .{});
            _ = run_loop.msgSend(void, "addTimer:forMode:", .{
                timer,
                NSString.stringWithUTF8String("NSRunLoopCommonModes").obj,
            });
        }
    };
}

pub const WindowClass = struct {};
pub fn registerDynamicWindowClass(
    comptime config: zin.WindowConfigData,
    comptime def: zin.WindowClassDefinition(.{ .dynamic = config }),
) WindowClass {
    _ = def;
    @panic("todo");
}

pub const DynamicWindow = struct {
    pub fn show(self: *const DynamicWindow) void {
        _ = self;
        @panic("todo");
    }
};

pub fn createDynamicWindow(class: WindowClass, opt: zin.CreateWindowOptions) zin.CreateWindowError!DynamicWindow {
    _ = class;
    _ = opt;
    @panic("todo");
}

fn createWindow(
    opt: *const zin.CreateWindowOptions,
    view: AnyZinView,
) zin.CreateWindowError!NSWindow {
    const window = NSWindow.alloc();
    errdefer window.release();

    const frame: NSRect = .{
        // TODO: support this as an option
        .origin = .{ .x = 0, .y = 0 },
        .size = switch (opt.size) {
            // TODO: how is default actually supposed work?
            .default => .{ .width = 100, .height = 100 },
            .client => |s| .{ .width = @floatFromInt(s.x), .height = @floatFromInt(s.y) },
            .window => @panic("todo"),
        },
    };
    const style_mask: NSWindow.StyleMask = .{
        .titled = 1,
        .closable = 1,
        .miniaturizable = 1,
        .resizable = 1,
    };
    {
        const result = window.obj.msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
            frame,
            style_mask,
            @as(u32, 2), // NSBackingStoreBuffered
            false,
        });
        std.debug.assert(result.value == window.obj.value);
    }

    // window.obj.msgSend(void, "setMinSize:", .{NSSize{ .width = 100, .height = 100 }});

    {
        const title = NSString.stringWithUTF8String(opt.title);
        defer title.release();
        window.setTitle(title);
    }
    window.obj.msgSend(void, "setContentView:", .{view.obj});
    window.makeKeyAndOrderFront();

    return window;
}

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
fn closeRequestHandler() bool {
    std.debug.print("Window is about to close. Allow close? (true/false)\n", .{});
    // Return true to allow the window to close, false to prevent closing
    return true;
}
fn closeNotificationHandler() void {
    std.debug.print("Window has been closed!\n", .{});
    // Perform cleanup or other actions after the window closes
}

pub const VirtualKey = enum(usize) {
    n = 0,
    _,
};

pub fn Draw(window_config: zin.WindowConfig) type {
    _ = window_config;
    return struct {
        const Self = @This();
        ctx: *c.CGContext,
        client_size: zin.XY,

        pub fn getDpiScale(self: *const Self) f32 {
            _ = self;
            return 1; // todo
        }

        pub fn clear(self: *const Self) void {
            // const rgb = if (comptime window_config.data().dynamic_background)
            //     self.background
            // else
            //     window_config.data().background;
            // TOOD: not sure if this is right or if we should just be calling FillRect?
            c.CGContextClearRect(self.ctx, .{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = @floatFromInt(self.client_size.x), .height = @floatFromInt(self.client_size.y) },
            });
            // c.CGContextSetRGBFillColor(
            //     self.ctx,
            //     fFrom8(rgb.r),
            //     fFrom8(rgb.g),
            //     fFrom8(rgb.b),
            //     1.0,
            // );
            // c.CGContextFillRect(self.ctx, self.client_rect);
        }

        pub fn rect(self: *const Self, r: zin.Rect, rgb: zin.Rgb8) void {
            c.CGContextSetRGBFillColor(
                self.ctx,
                fFrom8(rgb.r),
                fFrom8(rgb.g),
                fFrom8(rgb.b),
                1.0,
            );
            c.CGContextFillRect(self.ctx, cgRectFromZin(r, self.client_size.y));
        }

        pub fn text(self: *const Self, t: []const u8, x: i32, y: i32, rgb: zin.Rgb8) void {
            c.CGContextSetRGBFillColor(
                self.ctx,
                fFrom8(rgb.r),
                fFrom8(rgb.g),
                fFrom8(rgb.b),
                1.0,
            );
            const flipped_y = @as(c.CGFloat, @floatFromInt(self.client_size.y - y));
            c.CGContextSelectFont(self.ctx, "Helvetica", 12.0, c.kCGEncodingMacRoman);
            c.CGContextSetTextDrawingMode(self.ctx, c.kCGTextFill);
            c.CGContextSetTextPosition(self.ctx, @floatFromInt(x), flipped_y);
            c.CGContextShowText(self.ctx, t.ptr, t.len);
        }
    };
}

fn cgRectFromZin(r: zin.Rect, client_height: i32) c.CGRect {
    return .{
        .origin = .{ .x = @floatFromInt(r.left), .y = @floatFromInt(client_height - r.bottom) },
        .size = .{ .width = @floatFromInt(r.right - r.left), .height = @floatFromInt(r.bottom - r.top) },
    };
}

fn fFrom8(color8: u8) c.CGFloat {
    return @as(c.CGFloat, @floatFromInt(color8)) / 255.0;
}

pub fn quitMainLoop() void {
    const shared_app = NSApplication.sharedApplication();
    _ = shared_app.stop();
}

pub fn mainLoop() !void {
    const shared_app = NSApplication.sharedApplication();
    _ = shared_app.activateIgnoringOtherApps(true);
    _ = shared_app.run();
}

pub const CloseRequestCallback = fn () bool; // Return true to allow closing, false to prevent
pub const CloseNotificationCallback = fn () void; // Called after window has been closed

const AnyZinView = struct {
    obj: objc.Object,

    pub fn setNeedsDisplay(self: AnyZinView, needs: bool) void {
        self.obj.msgSend(void, "setNeedsDisplay:", .{needs});
    }

    pub fn getClientSize(self: AnyZinView) zin.XY {
        const bounds = self.obj.msgSend(c.CGRect, "bounds", .{});
        std.debug.assert(bounds.origin.x == 0);
        std.debug.assert(bounds.origin.y == 0);
        const size: zin.XY = .{
            .x = @intFromFloat(bounds.size.width),
            .y = @intFromFloat(bounds.size.height),
        };
        if (@as(c.CGFloat, @floatFromInt(size.x)) != bounds.size.width or @as(c.CGFloat, @floatFromInt(size.y)) != bounds.size.height) std.debug.panic(
            "non-integer bounds size {d}x{d}?",
            .{ bounds.size.width, bounds.size.height },
        );
        return size;
    }
};
fn ZinView(
    config: zin.WindowConfig,
    classdef: zin.WindowClassDefinition(config),
) type {
    return struct {
        obj: objc.Object,

        const Self = @This();
        pub fn any(self: Self) AnyZinView {
            return .{ .obj = self.obj };
        }

        pub fn create() Self {
            const class = allocateClassPair(getClass("NSView"), classdef.macos_view) orelse @panic("allocateClassPair for ZinView failed");
            // TODO: is this right?
            errdefer objc.disposeClassPair(class);

            if (!try class.addMethod("drawRect:", drawRect)) @panic("addMethod drawRect failed");
            // ... add mouse methods as in previous example ...
            // Accept first responder status for input events
            //try objc.addMethod(class, "acceptsFirstResponder", acceptsFirstResponder, "B@:");
            if (!try class.addMethod("viewDidMoveToWindow", viewDidMoveToWindow)) @panic("addMethod viewDidMoveToWindow failed");
            if (!try class.addMethod("windowWillClose:", windowWillClose)) @panic("addMethod windowWillClose failed");
            if (!try class.addMethod("windowShouldClose:", windowShouldClose)) @panic("addMethod windowShouldClose failed");

            if (!try class.addMethod("acceptsFirstResponder", acceptsFirstResponder))
                @panic("addMethod acceptsFirstResponder failed");
            if (!try class.addMethod("becomeFirstResponder", becomeFirstResponder))
                @panic("addMethod becomeFirstResponder failed");
            if (!try class.addMethod("resignFirstResponder", resignFirstResponder))
                @panic("addMethod resignFirstResponder failed");

            if (config.data().mouse_events) {
                if (!try class.addMethod("mouseMoved:", mouseMoved)) @panic("addMethod mouseMoved failed");
                if (!try class.addMethod("mouseDragged:", mouseDragged)) @panic("addMethod mouseDragged failed");
                if (!try class.addMethod("rightMouseDragged:", rightMouseDragged)) @panic("addMethod rightMouseDragged failed");
                if (!try class.addMethod("otherMouseDragged:", otherMouseDragged)) @panic("addMethod otherMouseDragged failed");
                if (!try class.addMethod("mouseDown:", mouseDown)) @panic("addMethod mouseDown failed");
                if (!try class.addMethod("mouseUp:", mouseUp)) @panic("addMethod mouseUp failed");
                if (!try class.addMethod("rightMouseDown:", rightMouseDown)) @panic("addMethod rightMouseDown failed");
                if (!try class.addMethod("rightMouseUp:", rightMouseUp)) @panic("addMethod rightMouseUp failed");
                if (!try class.addMethod("otherMouseDown:", otherMouseDown)) @panic("addMethod otherMouseDown failed");
                if (!try class.addMethod("otherMouseUp:", otherMouseUp)) @panic("addMethod otherMouseUp failed");

                if (!try class.addMethod("cursorUpdate:", cursorUpdate)) @panic("addMethod cursorUpdate failed");
                if (!try class.addMethod("resetCursorRects", resetCursorRects)) @panic("addMethod resetCursorRects failed");
            }

            if (config.data().timers) {
                if (!try class.addMethod("handleTimer:", handleTimer)) @panic("addMethod handleTimer failed");
            }

            objc.registerClassPair(class);

            const obj = class.msgSend(objc.Object, "alloc", .{});
            if (obj.value == 0) @panic("ZinView.alloc failed");
            // errdefer obj.release(); // is this right?

            obj.msgSend(void, "init", .{});

            // obj.msgSend(void, "setAutoresizingMask:", .{
            //     @as(u32, 18), // NSViewWidthSizable | NSViewHeightSizable
            // });

            return .{ .obj = obj };
        }
        // pub fn release(self: *ZinView) void {
        //     self.obj.release();
        // }

        fn window(self: Self) NSWindow {
            const obj = self.obj.msgSend(objc.Object, "window", .{});
            if (obj.value == 0) unreachable;
            return .{ .obj = obj };
        }

        fn viewDidMoveToWindow(object_id: objc.c.id, sel: objc.c.SEL) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            _ = sel;

            const notification_center = getClass("NSNotificationCenter").msgSend(objc.Object, "defaultCenter", .{});

            const w = self.window();
            _ = notification_center.msgSend(void, "addObserver:selector:name:object:", .{
                self.obj,
                objc.sel("windowWillClose:"),
                NSString.stringWithUTF8String("NSWindowWillCloseNotification").obj,
                w,
            });
            // Register for window should close notification by becoming the window delegate
            w.obj.msgSend(void, "setDelegate:", .{self.obj});

            if (config.data().mouse_events) {
                // Enable mouse move tracking even when mouse button is not pressed
                _ = self.obj.msgSend(void, "setAcceptsTouchEvents:", .{true});
                // Set up tracking area to receive mouse move events
                const tracking_options: u64 =
                    (1 << 0) | // NSTrackingMouseEnteredAndExited
                    (1 << 1) | // NSTrackingMouseMoved
                    (1 << 2) | // NSTrackingCursorUpdate
                    (1 << 3) | // NSTrackingActiveInActiveApp
                    (1 << 4); // NSTrackingInVisibleRect
                const bounds = self.obj.msgSend(NSRect, "bounds", .{});
                const tracking_area = getClass("NSTrackingArea").msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
                    bounds,
                    tracking_options,
                    self.obj,
                    @as(?objc.Object, null),
                });
                defer tracking_area.release();
                self.obj.msgSend(void, "addTrackingArea:", .{tracking_area});
                _ = w.obj.msgSend(void, "setAcceptsMouseMovedEvents:", .{true});
            }
        }
        fn windowShouldClose(object_id: objc.c.id, sel: objc.c.SEL, sender: objc.c.id) callconv(.C) bool {
            _ = sel;
            _ = sender;
            const self: Self = .{ .obj = .{ .value = object_id } };
            _ = self;
            switch (config) {
                .static => classdef.callback(.close),
                .dynamic => @panic("todo"), //class.callback(windowFromHwnd(hwnd), .close),
            }
            return false;
        }
        fn windowWillClose(object_id: objc.c.id, sel: objc.c.SEL, notification: objc.c.id) callconv(.C) void {
            _ = object_id;
            _ = sel;
            _ = notification;
            std.debug.panic("TODO: windowWillClose", .{});
        }

        fn handleTimer(object_id: objc.c.id, sel: objc.c.SEL, timer_obj_id: objc.c.id) callconv(.C) void {
            _ = object_id;
            _ = sel;
            if (comptime config.data().timers) {
                const timer_obj = objc.Object{ .value = timer_obj_id };
                const user_info = timer_obj.msgSend(objc.Object, "userInfo", .{});
                const timer_id = (NSNumber{ .obj = user_info }).unsignedLongValue();
                // Invalidate the timer after it's fired to avoid memory leaks
                // _ = timer_obj.msgSend(void, "invalidate", .{});
                switch (config) {
                    .static => classdef.callback(.{ .timer = timer_id }),
                    .dynamic => @panic("todo"), // Implement for dynamic windows
                }
            } else unreachable;
        }

        fn drawRect(object_id: objc.c.id, _: objc.c.SEL, rect: NSRect) callconv(.C) void {
            _ = rect;
            const self: Self = .{ .obj = .{ .value = object_id } };

            const gc = NSGraphicsContext.currentContext() orelse @panic("possible?");
            // gc.saveGraphicsState();
            // defer gc.restoreGraphicsState();

            const ctx = gc.CGContext();
            switch (config) {
                .static => classdef.callback(.{
                    .draw = .{
                        .ctx = ctx,
                        .client_size = self.any().getClientSize(),
                    },
                }),
                .dynamic => @panic("todo"),
            }
            c.CGContextFlush(ctx);
        }

        fn acceptsFirstResponder(object_id: objc.c.id, sel: objc.c.SEL) callconv(.C) bool {
            _ = object_id;
            _ = sel;
            return true;
        }

        fn becomeFirstResponder(object_id: objc.c.id, sel: objc.c.SEL) callconv(.C) bool {
            _ = sel;
            const self: Self = .{ .obj = .{ .value = object_id } };
            _ = self;

            // Setup code when becoming first responder
            // e.g., show a focus ring

            return true; // Return true to accept becoming first responder
        }

        fn resignFirstResponder(object_id: objc.c.id, sel: objc.c.SEL) callconv(.C) bool {
            _ = sel;
            const self: Self = .{ .obj = .{ .value = object_id } };
            _ = self;

            // Cleanup code when resigning first responder
            // e.g., hide a focus ring

            return true; // Return true to accept resigning
        }

        fn getEventLoc(self: Self, event: objc.Object, client_height: i32) zin.XY {
            const window_point = event.msgSend(NSPoint, "locationInWindow", .{});
            const view_point = self.obj.msgSend(NSPoint, "convertPoint:fromView:", .{
                window_point,
                @as(?objc.Object, null), // null means window coordinates
            });
            return .{
                .x = @intFromFloat(view_point.x),
                .y = @intFromFloat(@as(f64, @floatFromInt(client_height)) - view_point.y),
            };
        }

        fn cursorUpdate(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            _ = event_id; // We don't need to use the event for basic cursor setting
            const self: Self = .{ .obj = .{ .value = object_id } };
            _ = self;

            const cursor = getClass("NSCursor").msgSend(objc.Object, "arrowCursor", .{});
            cursor.msgSend(void, "set", .{});

            // Alternatively, we could send a cursor_update event to the callback
            // to let the application code decide which cursor to use
            // const event = objc.Object{ .value = event_id };
            // const location = self.locationInView(event);
            // switch (config) {
            //     .static => classdef.callback(.{
            //         .cursor_update = .{
            //             .x = location.x,
            //             .y = location.y,
            //         },
            //     }),
            //     .dynamic => @panic("todo"),
            // }
        }

        // Override resetCursorRects to define cursor regions in your view
        fn resetCursorRects(object_id: objc.c.id, _: objc.c.SEL) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const bounds = self.obj.msgSend(NSRect, "bounds", .{});
            // Get the cursor you want to use
            const cursor = getClass("NSCursor").msgSend(objc.Object, "arrowCursor", .{});
            // Add a cursor rect for the entire view
            self.obj.msgSend(void, "addCursorRect:cursor:", .{
                bounds,
                cursor,
            });
        }

        fn mouseEvent(self: Self, event: objc.Object, button: ?zin.MouseButtonState) void {
            const client_size = self.any().getClientSize();
            const location = self.getEventLoc(event, client_size.y);
            switch (config) {
                .static => classdef.callback(.{ .mouse = .{
                    .position = .{
                        .x = location.x,
                        .y = location.y,
                    },
                    .button = button,
                } }),
                .dynamic => @panic("todo"),
            }
        }
        fn mouseMoved(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            self.mouseEvent(event, null);
        }
        fn mouseDragged(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            // TODO: verify the left mouse is down?
            self.mouseEvent(event, null);
        }
        fn rightMouseDragged(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            // TODO: verify the right mouse is down?
            self.mouseEvent(event, null);
        }
        fn otherMouseDragged(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            // TODO: verify the other mouse is down?
            self.mouseEvent(event, null);
        }
        fn mouseDown(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            self.mouseEvent(event, .{ .id = .left, .state = .down });
        }
        fn mouseUp(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            self.mouseEvent(event, .{ .id = .left, .state = .up });
        }
        fn rightMouseDown(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            self.mouseEvent(event, .{ .id = .right, .state = .down });
        }
        fn rightMouseUp(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            self.mouseEvent(event, .{ .id = .right, .state = .up });
        }
        fn otherMouseDown(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            // Get button number to check if it's middle button (usually 2)
            const buttonNumber = event.msgSend(c_int, "buttonNumber", .{});
            if (buttonNumber == 2) {
                self.mouseEvent(event, .{ .id = .middle, .state = .down });
            }
        }
        fn otherMouseUp(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            const self: Self = .{ .obj = .{ .value = object_id } };
            const event = objc.Object{ .value = event_id };
            // Get button number to check if it's middle button (usually 2)
            const buttonNumber = event.msgSend(c_int, "buttonNumber", .{});
            if (buttonNumber == 2) {
                self.mouseEvent(event, .{ .id = .middle, .state = .up });
            }
        }
    };
}

fn getClass(name: [*:0]const u8) objc.Class {
    return .{ .value = objc.c.objc_getClass(name) orelse std.debug.panic("getClass '{s}' failed", .{name}) };
}

fn allocateClassPair(superclass: ?objc.Class, name: [*:0]const u8) ?objc.Class {
    return .{ .value = objc.c.objc_allocateClassPair(
        if (superclass) |cls| cls.value else null,
        name,
        0,
    ) orelse return null };
}

const NSNumber = struct {
    obj: objc.Object,

    pub fn release(self: NSNumber) void {
        self.obj.release();
    }

    pub fn numberWithUnsignedLong(value: c_ulong) NSNumber {
        return .{ .obj = getClass("NSNumber").msgSend(objc.Object, "numberWithUnsignedLong:", .{value}) };
    }

    pub fn unsignedLongValue(self: NSNumber) c_ulong {
        return self.obj.msgSend(c_ulong, "unsignedLongValue", .{});
    }
};

const NSString = struct {
    obj: objc.Object,
    pub fn release(self: NSString) void {
        self.obj.release();
    }
    pub fn stringWithUTF8String(str: [*:0]const u8) NSString {
        const obj = getClass("NSString").msgSend(objc.Object, "stringWithUTF8String:", .{str});
        if (obj.value == 0) @panic("stringWithUTF8String failed");
        return .{ .obj = obj };
    }

    pub fn allocUtf8(bytes: []const u8) ?NSString {
        const str: NSString = .{ .obj = getClass("NSString").msgSend(objc.Object, "alloc", .{}) };
        if (str.obj.value == 0) @panic("NSString alloc returned null");
        const NSUTF8StringEncoding: c_ulong = 4;
        const result = str.obj.msgSend(objc.Object, "initWithBytes:length:encoding:", .{
            bytes.ptr,
            bytes.len,
            NSUTF8StringEncoding,
        });
        if (result.value != str.obj.value) {
            str.release();
        } else {
            @panic("untested codepath, make sure this has no leaks");
        }
        return if (result.value == 0) null else NSString{ .obj = result };
    }
};

const AlertStyle = enum(c_ulong) {
    critical = 2,
};
const NSAlert = struct {
    obj: objc.Object,
    pub fn alloc() NSAlert {
        return .{ .obj = getClass("NSAlert").msgSend(objc.Object, "alloc", .{}) };
    }
    pub fn release(self: NSAlert) void {
        self.obj.release();
    }

    pub fn init(self: NSAlert) void {
        _ = self.obj.msgSend(objc.Object, "init", .{});
    }
    pub fn window(self: NSAlert) NSWindow {
        return .{ .obj = self.obj.msgSend(objc.Object, "window", .{}) };
    }
    pub fn setAlertStyle(self: NSAlert, style: AlertStyle) void {
        self.obj.msgSend(void, "setAlertStyle:", .{@intFromEnum(style)});
    }
    pub fn setInformativeText(self: NSAlert, s: NSString) void {
        self.obj.msgSend(void, "setInformativeText:", .{s.obj});
    }
    pub fn setMessageText(self: NSAlert, s: NSString) void {
        self.obj.msgSend(void, "setMessageText:", .{s.obj});
    }
    pub fn addButtonWithTitle(self: NSAlert, s: NSString) void {
        self.obj.msgSend(void, "addButtonWithTitle:", .{s.obj});
    }
    pub fn runModal(self: NSAlert) void {
        self.obj.msgSend(void, "runModal", .{});
    }
};

const NSApplication = struct {
    obj: objc.Object,
    pub fn sharedApplication() NSApplication {
        const obj = getClass("NSApplication").msgSend(objc.Object, "sharedApplication", .{});
        if (obj.value == 0) unreachable;
        return .{ .obj = obj };
    }
    pub fn activateIgnoringOtherApps(self: NSApplication, ignoringOtherApps: bool) void {
        self.obj.msgSend(void, "activateIgnoringOtherApps:", .{ignoringOtherApps});
    }
    pub fn run(self: NSApplication) void {
        self.obj.msgSend(void, "run", .{});
    }
    pub fn stop(self: NSApplication) void {
        self.obj.msgSend(void, "stop:", .{null});
    }
};

const NSPoint = extern struct {
    x: f64,
    y: f64,
};
const NSSize = extern struct {
    width: f64,
    height: f64,
};
const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

const NSWindow = struct {
    obj: objc.Object,
    pub fn alloc() NSWindow {
        return .{ .obj = getClass("NSWindow").msgSend(objc.Object, "alloc", .{}) };
    }
    pub fn release(self: NSWindow) void {
        self.obj.release();
    }
    pub fn setTitle(self: NSWindow, title: NSString) void {
        self.obj.msgSend(void, "setTitle:", .{title.obj});
    }
    pub fn makeKeyAndOrderFront(self: NSWindow) void {
        self.obj.msgSend(void, "makeKeyAndOrderFront:", .{0});
    }
    pub fn contentView(self: NSWindow) objc.Object {
        const obj = self.obj.msgSend(objc.Object, "contentView", .{});
        if (obj.value == 0) @panic("null contentView");
        return obj;
    }

    pub const StyleMask = packed struct(u32) {
        titled: u1 = 0,
        closable: u1 = 0,
        miniaturizable: u1 = 0,
        resizable: u1 = 0,
        texturedBackground: u1 = 0, // Deprecated
        unifiedTitleAndToolbar: u1 = 0, // No effect
        reserved_0: u1 = 0, // Reserved
        reserved_1: u1 = 0, // Reserved
        utilityWindow: u1 = 0,
        docModalWindow: u1 = 0,
        nonactivatingPanel: u1 = 0,
        hudWindow: u1 = 0,
        fullScreen: u1 = 0,
        fullSizeContentView: u1 = 0,
        reserved_2: u1 = 0, // Reserved
        borderless: u1 = 0,
        reserved_3: u16 = 0, // Reserved
    };
};

const NSGraphicsContext = struct {
    obj: objc.Object,

    pub fn currentContext() ?NSGraphicsContext {
        const context_obj = getClass("NSGraphicsContext").msgSend(objc.Object, "currentContext", .{});
        if (context_obj.value == 0) return null;
        return NSGraphicsContext{ .obj = context_obj };
    }

    pub fn CGContext(self: NSGraphicsContext) *c.CGContext {
        const obj = self.obj.msgSend([*c]objc.c.struct_objc_object, "CGContext", .{});
        if (obj == 0) @panic("null cgContext");
        return @ptrCast(obj);
    }
};
