const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;

pub const open_prefix = "\x1b[?25l\x1b[?7l\x1b[H";
pub const close_suffix = "\x1b[?25l";
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
        var screen = try openTerm(io);
        errdefer screen.restore();
        try screen.writeAll(hide_cursor ++ "\x1b[?7l");
        try screen.flush();
        try screen.enableRaw();
        return screen;
    }

    pub fn present(io: Io, text: []const u8, row: u32, col: u32) !Screen {
        var screen = try openTerm(io);
        errdefer screen.restore();
        try screen.writePrepared(text, row, col);
        try screen.enableRaw();
        return screen;
    }

    pub fn restore(self: *Screen) void {
        self.writeAll(close_suffix) catch {};
        self.flush() catch {};
        posix.tcsetattr(self.stdin.handle, .FLUSH, self.saved) catch {};
    }

    pub fn clear(self: *Screen) !void {
        try self.writeAll("\x1b[0m" ++ hide_cursor ++ "\x1b[H\x1b[2J");
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

    pub fn flushHidden(self: *Screen) !void {
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

    fn enableRaw(self: *Screen) !void {
        var raw = self.saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(self.stdin.handle, .FLUSH, raw);
    }

    fn writePrepared(self: *Screen, text: []const u8, row: u32, col: u32) !void {
        const body = std.mem.trimEnd(u8, text, "\n");
        var suffix_buf: [40]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "\x1b[{d};{d}H{s}", .{
            row + 1,
            col + 1,
            show_cursor,
        }) catch unreachable;
        var vecs: [3]posix.iovec_const = undefined;
        var n: usize = 0;
        vecs[n] = .{ .base = open_prefix.ptr, .len = open_prefix.len };
        n += 1;
        if (body.len > 0) {
            vecs[n] = .{ .base = body.ptr, .len = body.len };
            n += 1;
        }
        vecs[n] = .{ .base = suffix.ptr, .len = suffix.len };
        n += 1;
        try writevAll(self.stdout.handle, vecs[0..n]);
    }

    fn writeStdout(self: *Screen, bytes: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = Io.File.Writer.init(self.stdout, self.io, &buf);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }
};

fn openTerm(io: Io) !Screen {
    const stdin = Io.File.stdin();
    const stdout = Io.File.stdout();
    return .{
        .io = io,
        .stdin = stdin,
        .stdout = stdout,
        .saved = try posix.tcgetattr(stdin.handle),
    };
}

fn writevAll(fd: posix.fd_t, iov: []posix.iovec_const) !void {
    var vecs = iov;
    while (vecs.len > 0) {
        const n = try writevOnce(fd, vecs);
        var left = n;
        while (left > 0 and vecs.len > 0) {
            if (left < vecs[0].len) {
                vecs[0].base += left;
                vecs[0].len -= left;
                break;
            }
            left -= vecs[0].len;
            vecs = vecs[1..];
        }
    }
}

fn writevOnce(fd: posix.fd_t, iov: []posix.iovec_const) !usize {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        while (true) {
            const rc = std.os.linux.writev(fd, iov.ptr, iov.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.WriteFailed;
                    return @intCast(rc);
                },
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }
    while (true) {
        const n = std.c.writev(fd, iov.ptr, @intCast(iov.len));
        if (n > 0) return @intCast(n);
        if (std.c.errno(n) == .INTR) continue;
        return error.WriteFailed;
    }
}
