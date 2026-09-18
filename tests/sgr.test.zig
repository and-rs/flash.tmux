const std = @import("std");
const sgr = @import("../src/sgr.zig");

test "strip sgr" {
    const actual = try sgr.strip(std.testing.allocator, "\x1b[31mred\x1b[0m");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("red", actual);
}

test "dim preserves text" {
    const actual = try sgr.dim(std.testing.allocator, "\x1b[1mtext\x1b[0m");
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "text") != null);
}
