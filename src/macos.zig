const std = @import("std");
const objc = @import("mach_objc");

pub fn showErrorAlert(msg: [:0]const u8, informative_text: [:0]const u8) void {
    //const msg_nsstring = c.NSString.alloc(c.NSString.class(), c.sel_registerName("initWithUTF8String:"));
    const what_is_this = objc.foundation.String.alloc();
    // TODO: do I need to call release on what_is_this?
    const msg_nsstring = what_is_this.initWithUTF8String(msg.ptr);
    // defer c.objc_msgSend(msg_nsstring, c.sel_registerName("release"));
    defer msg_nsstring.release();

    const informative_nsstring = objc.foundation.String.alloc().initWithUTF8String(informative_text.ptr);
    defer informative_nsstring.release();

    // const alert = objc.appkit.Alert.alloc().init();
    // defer alert.release();

    // alert.setMessageText(msg_nsstring);
    // alert.setInformativeText(informative_nsstring);
    // alert.setAlertStyle(objc.appkit.AlertStyle.critical);
    // alert.runModal();
    @panic("todo");
}
