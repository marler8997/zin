const Rgb8 = @This();

r: u8,
g: u8,
b: u8,

pub const white: Rgb8 = .{ .r = 255, .g = 255, .b = 255 };
pub const black: Rgb8 = .{ .r = 0, .g = 0, .b = 0 };
pub const full_red: Rgb8 = .{ .r = 255, .g = 0, .b = 0 };
pub const full_green: Rgb8 = .{ .r = 0, .g = 255, .b = 0 };
pub const full_blue: Rgb8 = .{ .r = 0, .g = 0, .b = 255 };
