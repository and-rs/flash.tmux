const std = @import("std");

const flash_tmux = @import("flash_tmux");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const q = try flash_tmux.tmux.query(arena, io);
    const text = try flash_tmux.tmux.capture(arena, io, q.pane_id);

    var screen = try flash_tmux.tty.Screen.enter(io);
    defer screen.restore();
    try screen.paint(text);
    try screen.waitQuit();
}
