const std = @import("std");
const flash_tmux = @import("flash_tmux");

test "popup open hides cursor without alt screen or clear" {
    const prefix = flash_tmux.tty.open_prefix;
    try std.testing.expect(std.mem.startsWith(u8, prefix, "\x1b[?25l"));
    try std.testing.expect(std.mem.indexOf(u8, prefix, "1049") == null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "2J") == null);
}

test "popup close stays hidden" {
    const suffix = flash_tmux.tty.close_suffix;
    try std.testing.expectEqualStrings("\x1b[?25l", suffix);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "1049") == null);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "?25h") == null);
}
