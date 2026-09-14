const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const enter_seq = "\x1b[?7l";
const leave_seq = "\x1b[?7h";
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";

pub const Screen = struct {
    io: Io,
    stdin: Io.File,
    stdout: Io.File,
    saved: posix.termios,
    buf: [131072]u8 = undefined,
    len: usize = 0,

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
        try screen.flush();
        return screen;
    }

    pub fn restore(self: *Screen) void {
        self.writeAll(show_cursor ++ leave_seq) catch {};
        self.flush() catch {};
        posix.tcsetattr(self.stdin.handle, .FLUSH, self.saved) catch {};
    }

    pub fn clear(self: *Screen) !void {
        try self.writeAll(hide_cursor ++ "\x1b[H\x1b[2J");
        try self.flush();
    }

    pub fn paint(self: *Screen, text: []const u8) !void {
        try self.writeAll(hide_cursor ++ "\x1b[H");
        try self.writeAll(std.mem.trimEnd(u8, text, "\n"));
    }

    pub fn park(self: *Screen, row: u32, col: u32) !void {
        var seq: [32]u8 = undefined;
        const n = std.fmt.bufPrint(&seq, "\x1b[{d};{d}H{s}", .{ row + 1, col + 1, show_cursor }) catch unreachable;
        try self.writeAll(n);
        try self.flush();
    }

    pub fn readByte(self: *Screen) !u8 {
        try self.flush();
        var buf: [64]u8 = undefined;
        var reader = Io.File.Reader.initStreaming(self.stdin, self.io, &buf);
        return reader.interface.takeByte();
    }

    pub fn stamp(self: *Screen, row: u32, col: u32, ch: u8) !void {
        const color: u8 = '1' + @as(u8, @intCast(ch % 6));
        var seq: [48]u8 = undefined;
        const n = std.fmt.bufPrint(&seq, "\x1b[{d};{d}H\x1b[0;30;4{c}m{c}", .{
            row + 1,
            col + 1,
            color,
            ch,
        }) catch unreachable;
        try self.writeAll(n);
    }

    fn writeAll(self: *Screen, bytes: []const u8) !void {
        if (bytes.len >= self.buf.len) {
            try self.flush();
            try self.writeStdout(bytes);
            return;
        }
        if (self.len + bytes.len > self.buf.len) try self.flush();
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *Screen) !void {
        if (self.len == 0) return;
        try self.writeStdout(self.buf[0..self.len]);
        self.len = 0;
    }

    fn writeStdout(self: *Screen, bytes: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = Io.File.Writer.init(self.stdout, self.io, &buf);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }
};
