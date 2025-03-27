const Rgb8 = @This();

r: u8,
g: u8,
b: u8,

pub fn eql(self: Rgb8, other: Rgb8) bool {
    return self.r == other.r and self.g == other.g and self.b == other.b;
}

pub const white: Rgb8 = .{ .r = 255, .g = 255, .b = 255 };
pub const black: Rgb8 = .{ .r = 0, .g = 0, .b = 0 };
pub const red: Rgb8 = .{ .r = 255, .g = 0, .b = 0 };
pub const green: Rgb8 = .{ .r = 0, .g = 255, .b = 0 };
pub const blue: Rgb8 = .{ .r = 0, .g = 0, .b = 255 };
