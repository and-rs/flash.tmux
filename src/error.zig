const std = @import("std");
const tty = @import("tty.zig");

pub fn showAndWait(io: std.Io, err: anyerror) !void {
    var screen = try tty.Screen.enter(io);
    defer screen.restore();
    try show(&screen, err);
    try waitForCtrlC(&screen);
}

pub fn show(screen: *tty.Screen, err: anyerror) !void {
    var message: [512]u8 = undefined;
    const text = formatMessage(&message, err);
    try screen.clear();
    try screen.paint(text);
    try screen.park(0, 0);
}

pub fn formatMessage(buffer: []u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "\x1b[1;37mflash.tmux error\x1b[0m\n\n{s}\n\n\x1b[1mPress Ctrl-C to close and restore.\x1b[0m",
        .{@errorName(err)},
    ) catch "flash.tmux error\n\nPress Ctrl-C to close and restore.";
}

pub fn waitForCtrlC(screen: *tty.Screen) !void {
    while (true) {
        if (try screen.readByte() == 0x03) return;
    }
}

pub fn reportStderr(io: std.Io, err: anyerror) void {
    var out_buf: [1024]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stderr(), io, &out_buf);
    writer.interface.print("flash.tmux error: {s}\n", .{@errorName(err)}) catch {};
    writer.interface.flush() catch {};
}
