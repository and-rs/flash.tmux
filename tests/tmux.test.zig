const std = @import("std");
const tmux = @import("flash_tmux").tmux;

test "parse query" {
    const q = try tmux.parseQuery("%2|118|31|1|26|0|||0\n");
    try std.testing.expectEqualStrings("%2", q.pane_id);
    try std.testing.expectEqual(@as(u32, 118), q.width);
    try std.testing.expectEqual(@as(u32, 31), q.height);
    try std.testing.expectEqual(@as(u32, 1), q.cursor_x);
    try std.testing.expectEqual(@as(u32, 26), q.cursor_y);
    try std.testing.expectEqual(false, q.in_mode);
    try std.testing.expectEqual(@as(u32, 0), q.copy_cursor_x);
    try std.testing.expectEqual(@as(u32, 0), q.copy_cursor_y);
    try std.testing.expectEqual(false, q.selection_present);
}

test "parse query trailing empty fields" {
    const q = try tmux.parseQuery("%0|121|31|1|26|0|||\n");
    try std.testing.expectEqualStrings("%0", q.pane_id);
    try std.testing.expectEqual(@as(u32, 121), q.width);
    try std.testing.expectEqual(false, q.in_mode);
    try std.testing.expectEqual(false, q.selection_present);
}

test "parse query in copy mode" {
    const q = try tmux.parseQuery("%0|80|24|0|0|1|12|7|1");
    try std.testing.expectEqual(true, q.in_mode);
    try std.testing.expectEqual(@as(u32, 12), q.copy_cursor_x);
    try std.testing.expectEqual(@as(u32, 7), q.copy_cursor_y);
    try std.testing.expectEqual(true, q.selection_present);
    try std.testing.expectEqual(@as(u32, 0), q.scroll_position);
}

test "parse query scroll" {
    const q = try tmux.parseQuery("%0|80|24|0|0|1|12|7|0|15");
    try std.testing.expectEqual(@as(u32, 15), q.scroll_position);
}

test "jumpKind" {
    try std.testing.expectEqual(tmux.JumpKind.enter, tmux.jumpKind(false, false));
    try std.testing.expectEqual(tmux.JumpKind.enter, tmux.jumpKind(false, true));
    try std.testing.expectEqual(tmux.JumpKind.move, tmux.jumpKind(true, false));
    try std.testing.expectEqual(tmux.JumpKind.extend, tmux.jumpKind(true, true));
}
