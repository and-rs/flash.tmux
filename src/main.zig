const std = @import("std");
const Io = std.Io;

const flash_tmux = @import("flash_tmux");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const q = try flash_tmux.tmux.query(arena, io);
    const text = try flash_tmux.tmux.capture(arena, io, q.pane_id);
    const ends = firstLast(text);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.print(
        "pane_id={s} width={d} height={d} cursor={d},{d} in_mode={d} copy_cursor={d},{d}\n{s}\n{s}\n",
        .{
            q.pane_id,
            q.width,
            q.height,
            q.cursor_x,
            q.cursor_y,
            @intFromBool(q.in_mode),
            q.copy_cursor_x,
            q.copy_cursor_y,
            ends.first,
            ends.last,
        },
    );
    try stdout_writer.flush();
}

fn firstLast(text: []const u8) struct { first: []const u8, last: []const u8 } {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    const first_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const last_start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return .{ .first = trimmed[0..first_end], .last = trimmed[last_start..] };
}
