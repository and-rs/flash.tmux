const std = @import("std");
const tmux = @import("flash_tmux").tmux;

test "copy state rejects missing required cursor fields" {
    try std.testing.expectError(error.InvalidQuery, tmux.parseCopyQuery("%1|80|24|1||||0|0|||||0||\n"));
}

test "copy state accepts inactive selection with optional tmux fields" {
    const state = try tmux.parseCopyQuery("%1|80|24|1|4|5|6|0|0|||||0||\n");
    try std.testing.expectEqual(@as(u32, 4), state.cursor.x);
    try std.testing.expect(state.selection_anchor_x == null);
    try std.testing.expect(state.refresh_active == null);
}

test "cursor position verification requires the exact target" {
    const state = try tmux.parseCopyQuery("%1|80|24|1|4|5|6|0|0|||||0||\n");
    try std.testing.expect(tmux.cursorAt(state, 5, 4));
    try std.testing.expect(!tmux.cursorAt(state, 5, 5));
    try std.testing.expect(!tmux.cursorAt(state, 4, 4));
}
