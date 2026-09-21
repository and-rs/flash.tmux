const std = @import("std");
const error_screen = @import("flash_tmux").error_screen;

test "error screen message names the error and explains Ctrl-C" {
    var buffer: [512]u8 = undefined;
    const message = error_screen.formatMessage(&buffer, error.TestFailure);
    try std.testing.expect(std.mem.indexOf(u8, message, "TestFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Ctrl-C") != null);
}
