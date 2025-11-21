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

pub fn processInit(opt: zin.ProcessInitOptions) zin.ProcessInitError!void {
    _ = opt;
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
        // First, activate the application and bring it to front
        shared_app.activateIgnoringOtherApps(true);

        // Set the alert window level to be above normal windows
        const alert_window = alert.window();
        alert_window.obj.msgSend(void, "setLevel:", .{
            @as(i64, 8), // NSModalPanelWindowLevel = 8 (highest for modal dialogs)
        });

        // Make the window key and order it to the front
        alert_window.makeKeyAndOrderFront();

        // Center the window on screen
        alert_window.obj.msgSend(void, "center", .{});
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

pub const min_timer_id_int = 0;

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

        pub fn registerClass(
            comptime def: zin.WindowClassDefinition(.{ .static = window_id }),
            runtime_config: zin.WindowClassRuntimeConfig,
        ) void {
            _ = runtime_config;
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
        pub fn startTimer(id: window_id.getConfig().TimerId(), millis: u32) void {
            const view = global.static_windows[@intFromEnum(window_id)].?.contentView();
            const seconds = @as(f64, @floatFromInt(millis)) / 1000.0;
            const id_int = zin.intFromTimerId(u32, window_id.getConfig().TimerId(), id);
            const timer = getClass("NSTimer").msgSend(objc.Object, "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{
                seconds,
                view,
                objc.sel("handleTimer:"),
                // TODO: should we release this number?
                NSNumber.numberWithUnsignedLong(id_int).obj, // Store timer ID in userInfo
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
    runtime_config: zin.WindowClassRuntimeConfig,
) WindowClass {
    _ = def;
    _ = runtime_config;
    @panic("todo");
}

pub const DynamicWindow = struct {
    pub fn show(self: *const DynamicWindow) void {
        _ = self;
        @panic("todo");
    }
};

pub const CreateWindowOptions = struct {};

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

    const style_mask: NSWindow.StyleMask = .{
        .titled = 1,
        .closable = 1,
        .miniaturizable = 1,
        .resizable = 1,
    };

    const origin = NSPoint{ .x = 0, .y = 0 };
    const content_rect: NSRect = blk: switch (opt.size) {
        // TODO: how is default actually supposed work?
        .default => break :blk .{
            .origin = origin,
            .size = NSSize{ .width = 100, .height = 100 },
        },
        // TODO: treat pixels/points differently
        .client_pixels, .client_points => |s| break :blk .{
            .origin = origin,
            .size = NSSize{
                .width = @floatFromInt(s.x),
                .height = @floatFromInt(s.y),
            },
        },
        .window_pixels, .window_points => |s| {
            // TODO: treat pixels/points differently
            const window_rect = NSRect{
                .origin = origin,
                .size = .{ .width = @floatFromInt(s.x), .height = @floatFromInt(s.y) },
            };
            break :blk getClass("NSWindow").msgSend(
                NSRect,
                "contentRectForFrameRect:styleMask:",
                .{ window_rect, style_mask },
            );
        },
    };

    {
        const result = window.obj.msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
            content_rect,
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

    window.obj.msgSend(void, "makeFirstResponder:", .{view.obj});
    window.obj.msgSend(void, "setAcceptsMouseMovedEvents:", .{true});
    window.makeKeyAndOrderFront();
    window.obj.msgSend(void, "makeKeyWindow", .{});
    window.obj.msgSend(void, "makeMainWindow", .{});

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

pub const NSEventModifierFlags = packed struct(c_ulong) {
    // Lower bits (0-15) are reserved/unused in our context
    _reserved_low: u16 = 0,

    // Modifier key flags (bits 16-23)
    caps_lock: bool = false, // bit 16: NSEventModifierFlagCapsLock
    shift: bool = false, // bit 17: NSEventModifierFlagShift
    control: bool = false, // bit 18: NSEventModifierFlagControl
    option: bool = false, // bit 19: NSEventModifierFlagOption (Alt)
    command: bool = false, // bit 20: NSEventModifierFlagCommand
    numeric_pad: bool = false, // bit 21: NSEventModifierFlagNumericPad
    help: bool = false, // bit 22: NSEventModifierFlagHelp
    function: bool = false, // bit 23: NSEventModifierFlagFunction

    // Upper bits (24-63) contain device-independent flags and other data
    _reserved_high: u40 = 0,
};

pub const VirtualKey = enum(u16) {
    // Letter keys (ANSI layout)
    a = 0x00,
    s = 0x01,
    d = 0x02,
    f = 0x03,
    h = 0x04,
    g = 0x05,
    z = 0x06,
    x = 0x07,
    c = 0x08,
    v = 0x09,
    iso_section = 0x0A, // ISO keyboard only
    b = 0x0B,
    q = 0x0C,
    w = 0x0D,
    e = 0x0E,
    r = 0x0F,
    y = 0x10,
    t = 0x11,

    // Number keys
    @"1" = 0x12,
    @"2" = 0x13,
    @"3" = 0x14,
    @"4" = 0x15,
    @"6" = 0x16,
    @"5" = 0x17,
    @"9" = 0x19,
    @"7" = 0x1A,
    @"8" = 0x1C,
    @"0" = 0x1D,

    // Symbol keys
    equal = 0x18,
    minus = 0x1B,
    right_bracket = 0x1E,
    o = 0x1F,
    u = 0x20,
    left_bracket = 0x21,
    i = 0x22,
    p = 0x23,
    @"return" = 0x24,
    l = 0x25,
    j = 0x26,
    quote = 0x27,
    k = 0x28,
    semicolon = 0x29,
    backslash = 0x2A,
    comma = 0x2B,
    slash = 0x2C,
    n = 0x2D,
    m = 0x2E,
    period = 0x2F,

    // Navigation and control keys
    tab = 0x30,
    space = 0x31,
    grave = 0x32,
    backspace = 0x33, // This is the Delete key on macOS (but acts as backspace)
    escape = 0x35,
    super_right = 0x36, // Right command key
    super_left = 0x37, // Left command key
    shift_left = 0x38,
    caps_lock = 0x39,
    alt_left = 0x3A, // Left option key
    control_left = 0x3B,
    shift_right = 0x3C,
    alt_right = 0x3D, // Right option key
    control_right = 0x3E,
    function = 0x3F,

    // Function keys
    f17 = 0x40,
    decimal = 0x41, // Keypad decimal
    multiply = 0x43, // Keypad multiply
    add = 0x45, // Keypad plus
    keypad_clear = 0x47,
    volume_up = 0x48,
    volume_down = 0x49,
    mute = 0x4A,
    divide = 0x4B, // Keypad divide
    keypad_enter = 0x4C,
    subtract = 0x4E, // Keypad minus
    f18 = 0x4F,
    f19 = 0x50,
    separator = 0x51, // Keypad equals (used as separator)

    // Numpad keys
    numpad0 = 0x52,
    numpad1 = 0x53,
    numpad2 = 0x54,
    numpad3 = 0x55,
    numpad4 = 0x56,
    numpad5 = 0x57,
    numpad6 = 0x58,
    numpad7 = 0x59,
    f20 = 0x5A,
    numpad8 = 0x5B,
    numpad9 = 0x5C,

    // JIS keyboard specific
    jis_yen = 0x5D,
    jis_underscore = 0x5E,
    jis_keypad_comma = 0x5F,

    // More function keys
    f5 = 0x60,
    f6 = 0x61,
    f7 = 0x62,
    f3 = 0x63,
    f8 = 0x64,
    f9 = 0x65,
    jis_eisu = 0x66,
    f11 = 0x67,
    jis_kana = 0x68,
    f13 = 0x69,
    f16 = 0x6A,
    f14 = 0x6B,
    f10 = 0x6D,
    contextual_menu = 0x6E,
    f12 = 0x6F,
    f15 = 0x71,
    insert = 0x72, // Help key (used as Insert)
    home = 0x73,
    page_up = 0x74,
    delete = 0x75, // Forward delete key
    f4 = 0x76,
    end = 0x77,
    f2 = 0x78,
    page_down = 0x79,
    f1 = 0x7A,

    // Arrow keys
    left = 0x7B,
    right = 0x7C,
    down = 0x7D,
    up = 0x7E,

    // Keys that don't have standard macOS mappings
    // Using unused/reserved codes or approximations
    pause = 0x90, // No direct equivalent on Mac
    print_screen = 0x91, // No direct equivalent on Mac
    numlock = 0x92, // No direct equivalent on Mac
    scroll_lock = 0x93, // No direct equivalent on Mac
    f21 = 0x80, // Extended function keys (non-standard)
    f22 = 0x81,
    f23 = 0x82,
    f24 = 0x83,

    _,
};
pub const ScanCode = void;

pub fn Draw(window_config: zin.WindowConfig) type {
    _ = window_config;
    return struct {
        const Self = @This();
        ctx: *c.CGContext,
        client_size: zin.XY,

        pub fn getDpiScale(self: *const Self) struct { x: f32, y: f32 } {
            _ = self;
            return .{ .x = 1, .y = 1 }; // todo
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
    shared_app.obj.msgSend(void, "setActivationPolicy:", .{@as(i64, 0)}); // NSApplicationActivationPolicyRegular = 0
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

            if (config.data().key_events) {
                if (!try class.addMethod("keyDown:", keyDown)) @panic("addMethod keyDown failed");
                if (!try class.addMethod("keyUp:", keyUp)) @panic("addMethod keyUp failed");
                if (!try class.addMethod("flagsChanged:", flagsChanged)) @panic("addMethod flagsChanged failed");
            }

            switch (config.data().timers) {
                .none => {},
                .one, .type => {
                    if (!try class.addMethod("handleTimer:", handleTimer)) @panic("addMethod handleTimer failed");
                },
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

            _ = w.obj.msgSend(void, "makeFirstResponder:", .{self.obj});

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

            switch (config.data().timers) {
                .none => unreachable,
                .one, .type => {},
            }
            const timer_obj = objc.Object{ .value = timer_obj_id };
            const user_info = timer_obj.msgSend(objc.Object, "userInfo", .{});
            const timer_id = (NSNumber{ .obj = user_info }).unsignedLongValue();
            // Invalidate the timer after it's fired to avoid memory leaks
            // _ = timer_obj.msgSend(void, "invalidate", .{});
            switch (config) {
                .static => classdef.callback(.{ .timer = zin.timerIdFromInt(config.data().TimerId(), timer_id) }),
                .dynamic => @panic("todo"), // Implement for dynamic windows
            }
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
            _ = object_id;
            log.debug("View became first responder", .{});
            return true; // Return true to accept becoming first responder
        }

        fn resignFirstResponder(object_id: objc.c.id, sel: objc.c.SEL) callconv(.C) bool {
            _ = sel;
            _ = object_id;
            log.debug("View resigned first responder", .{});
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

        fn getMouseButtonsDown(event: objc.Object, button_event: ?zin.MouseButtonState) zin.MouseButtonsDown {
            const pressed_mask = event.msgSend(c_ulong, "pressedMouseButtons", .{});
            var down: zin.MouseButtonsDown = .{
                .left = (pressed_mask & 1) != 0,
                .right = (pressed_mask & 2) != 0,
                .middle = (pressed_mask & 4) != 0,
            };
            // For button down/up events, pressedMouseButtons may not reflect the current event yet
            if (button_event) |btn| {
                switch (btn.id) {
                    .left => down.left = (btn.state == .down),
                    .right => down.right = (btn.state == .down),
                    .middle => down.middle = (btn.state == .down),
                }
            }
            return down;
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
                    .down = getMouseButtonsDown(event, button),
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

        fn keyDown(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            _ = object_id;
            const event = objc.Object{ .value = event_id };

            const key_code = event.msgSend(u16, "keyCode", .{});
            const is_repeat = event.msgSend(bool, "isARepeat", .{});
            const modifier_flags: NSEventModifierFlags = @bitCast(event.msgSend(c_ulong, "modifierFlags", .{}));

            log.debug("keyDown: keyCode={}, repeat={}, modifiers=0x{x}", .{ key_code, is_repeat, @as(c_ulong, @bitCast(modifier_flags)) });

            const key_event: zin.Key = .{
                .kind = if (is_repeat) .down_repeat else .down,
                .vk = @enumFromInt(key_code),
                .scan_code = {},
                .win32_extended = {},
                .x11_mask = {},
                .macos_mods = switch (zin.platform_kind) {
                    .macos => modifier_flags,
                    else => {},
                },
            };

            switch (config) {
                .static => classdef.callback(.{ .key = key_event }),
                .dynamic => @panic("todo"),
            }
        }

        fn keyUp(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            _ = object_id;
            const event = objc.Object{ .value = event_id };

            const key_code = event.msgSend(u16, "keyCode", .{});
            const modifier_flags: NSEventModifierFlags = @bitCast(event.msgSend(c_ulong, "modifierFlags", .{}));

            const key_event: zin.Key = .{
                .kind = .up,
                .vk = @enumFromInt(key_code),
                .scan_code = {},
                .win32_extended = {},
                .x11_mask = {},
                .macos_mods = switch (zin.platform_kind) {
                    .macos => modifier_flags,
                    else => {},
                },
            };

            switch (config) {
                .static => classdef.callback(.{ .key = key_event }),
                .dynamic => @panic("todo"),
            }
        }

        fn flagsChanged(object_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.C) void {
            _ = object_id;
            const event = objc.Object{ .value = event_id };

            const key_code = event.msgSend(u16, "keyCode", .{});
            const modifier_flags: NSEventModifierFlags = @bitCast(event.msgSend(c_ulong, "modifierFlags", .{}));

            // Determine the VirtualKey based on the key code
            const vk: VirtualKey = @enumFromInt(key_code);

            // Determine if this is a key down or up based on modifier flags
            // This is complex because flagsChanged doesn't directly tell us up/down
            // We need to check the specific flag for each modifier key
            var is_down = false;

            switch (vk) {
                .shift_left, .shift_right => is_down = modifier_flags.shift,
                .control_left, .control_right => is_down = modifier_flags.control,
                .alt_left, .alt_right => is_down = modifier_flags.option,
                .super_left, .super_right => is_down = modifier_flags.command,
                .caps_lock => is_down = modifier_flags.caps_lock,
                .function => is_down = modifier_flags.function,
                else => return, // Not a modifier we track
            }

            const key_event: zin.Key = .{
                .kind = if (is_down) .down else .up,
                .vk = vk,
                .scan_code = {},
                .win32_extended = {},
                .x11_mask = {},
                .macos_mods = switch (zin.platform_kind) {
                    .macos => modifier_flags,
                    else => {},
                },
            };

            switch (config) {
                .static => classdef.callback(.{ .key = key_event }),
                .dynamic => @panic("todo"),
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
