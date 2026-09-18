const std = @import("std");
const flash_tmux = @import("flash_tmux");

test "parse --version" {
    const opts = try flash_tmux.args.parse(&.{ "flash_tmux", "--version" });
    try std.testing.expect(opts.version);
}

test "embedded version" {
    try std.testing.expect(flash_tmux.version.len > 0);
}
