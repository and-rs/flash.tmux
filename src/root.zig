const std = @import("std");
const Io = std.Io;

const pane_format = "#{session_name} #{pane_id} #{pane_width}x#{pane_height}";

pub fn tmuxDisplay(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "tmux", "display-message", "-p", pane_format },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.TmuxFailed,
        else => return error.TmuxFailed,
    }
    return result.stdout;
}
