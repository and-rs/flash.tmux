const std = @import("std");
const flash = @import("flash.zig");
const tty = @import("tty.zig");

pub const Outcome = union(enum) {
    abort,
    jump: flash.Match,
};

pub const Session = struct {
    screen: tty.Screen,

    pub fn enter(io: std.Io) !Session {
        return .{ .screen = try tty.Screen.enter(io) };
    }

    pub fn close(self: *Session) void {
        self.screen.restore();
    }

    pub fn present(io: std.Io, text: []const u8, cursor: flash.Pos) !Session {
        return .{ .screen = try tty.Screen.present(io, text, cursor.row, cursor.col) };
    }

    pub fn showWarmFrame(self: *Session, text: []const u8) !void {
        try self.screen.paint(text);
        try self.screen.flushHidden();
    }

    pub fn run(self: *Session, allocator: std.mem.Allocator, text: []const u8, grid: flash.Grid) !Outcome {
        var state = try flash.State.init(allocator, grid, .{});
        defer state.deinit();

        try paint(&self.screen, text, &state);
        while (true) {
            const b = try self.screen.readByte();
            if (b == 0x03 or !try state.step(b)) break;
            try paint(&self.screen, text, &state);
        }

        if (state.jumped) |match| return .{ .jump = match };
        return .abort;
    }
};

fn paint(screen: *tty.Screen, text: []const u8, state: *flash.State) !void {
    try screen.paint(text);
    for (state.results.items) |match| {
        const label = match.label orelse continue;
        if (match.pos.row >= state.grid.lines.len) continue;
        try screen.stamp(match.pos.row, flash.labelCol(match, state.grid.width), label);
    }
    try screen.park(state.grid.cursor.row, state.grid.cursor.col);
}
