const std = @import("std");
const flash = @import("../src/flash.zig");

test "parse grid and match" {
    const grid: flash.Grid = .{
        .lines = &.{ "hello world", "world hello" },
        .width = 11,
        .cursor = .{},
    };
    var state = try flash.State.init(std.testing.allocator, grid, .{});
    defer state.deinit();
    try std.testing.expect(try state.step('w'));
    try std.testing.expect(try state.step('o'));
    try std.testing.expectEqual(@as(usize, 2), state.results.items.len);
}

test "cursor rights skips wide cells" {
    try std.testing.expectEqual(@as(u32, 2), flash.cursorRights("a界b", 3));
}
