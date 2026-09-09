const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const enter_seq = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[H\x1b[2J";
const leave_seq = "\x1b[?25h\x1b[?7h\x1b[?1049l";
const ctrl_c = 0x03;

pub const Screen = struct {
    io: Io,
    stdin: Io.File,
    stdout: Io.File,
    saved: posix.termios,

    pub fn enter(io: Io) !Screen {
        const stdin = Io.File.stdin();
        const stdout = Io.File.stdout();
        const saved = try posix.tcgetattr(stdin.handle);

        var raw = saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(stdin.handle, .FLUSH, raw);

        var screen: Screen = .{
            .io = io,
            .stdin = stdin,
            .stdout = stdout,
            .saved = saved,
        };
        errdefer screen.restore();
        try screen.writeAll(enter_seq);
        return screen;
    }

    pub fn restore(self: *Screen) void {
        self.writeAll(leave_seq) catch {};
        posix.tcsetattr(self.stdin.handle, .FLUSH, self.saved) catch {};
    }

    pub fn paint(self: *Screen, text: []const u8) !void {
        try self.writeAll("\x1b[H");
        try self.writeAll(std.mem.trimEnd(u8, text, "\n"));
    }

    pub fn waitQuit(self: *Screen) !void {
        var buf: [64]u8 = undefined;
        var reader = Io.File.Reader.initStreaming(self.stdin, self.io, &buf);
        while (true) {
            const b = try reader.interface.takeByte();
            if (b == ctrl_c) return;
        }
    }

    fn writeAll(self: *Screen, bytes: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = Io.File.Writer.init(self.stdout, self.io, &buf);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }
};
