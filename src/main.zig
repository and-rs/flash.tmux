const std = @import("std");
const Io = std.Io;

const flash_tmux = @import("flash_tmux");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const text = try flash_tmux.tmuxDisplay(arena, io);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.writeAll(text);
    try stdout_writer.flush();
}
