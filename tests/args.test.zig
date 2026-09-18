const std = @import("std");
const args = @import("../src/args.zig");

test "parse default" {
    const actual = try args.parse(&.{"flash_tmux"});
    try std.testing.expect(!actual.version);
    try std.testing.expect(!actual.inspect);
    try std.testing.expect(actual.pane == null);
    try std.testing.expect(actual.session == null);
}

test "parse pane and session" {
    const actual = try args.parse(&.{ "flash_tmux", "--pane=%42", "--session=overlay" });
    try std.testing.expectEqualStrings("%42", actual.pane.?);
    try std.testing.expectEqualStrings("overlay", actual.session.?);
}

test "parse inspect" {
    const actual = try args.parse(&.{ "flash_tmux", "--inspect" });
    try std.testing.expect(actual.inspect);
}

test "parse unknown" {
    try std.testing.expectError(error.InvalidArgument, args.parse(&.{ "flash_tmux", "--wat" }));
}
