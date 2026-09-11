const std = @import("std");

pub fn strip(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == 0x1b) {
            i = skipEsc(src, i);
            continue;
        }
        try out.append(allocator, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn dim(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var attrs: Attrs = .{};
    try attrs.emit(&out, allocator);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == 0x1b) {
            const start = i;
            const end = skipEsc(src, i);
            if (end > start + 2 and src[start + 1] == '[' and src[end - 1] == 'm') {
                applySgr(&attrs, src[start + 2 .. end - 1]);
                try attrs.emit(&out, allocator);
            }
            i = end;
            continue;
        }
        try out.append(allocator, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

const Attrs = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn emit(self: Attrs, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        try out.appendSlice(allocator, "\x1b[0;90");
        if (self.bold) try out.appendSlice(allocator, ";1");
        if (self.italic) try out.appendSlice(allocator, ";3");
        if (self.underline) try out.appendSlice(allocator, ";4");
        try out.append(allocator, 'm');
    }
};

fn skipEsc(s: []const u8, i: usize) usize {
    if (i + 1 >= s.len) return s.len;
    switch (s[i + 1]) {
        '[' => {
            var j = i + 2;
            while (j < s.len) : (j += 1) {
                if (s[j] >= 0x40 and s[j] <= 0x7E) return j + 1;
            }
            return s.len;
        },
        ']' => {
            var j = i + 2;
            while (j < s.len) : (j += 1) {
                if (s[j] == 0x07) return j + 1;
                if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
            }
            return s.len;
        },
        else => return i + 2,
    }
}

fn applySgr(attrs: *Attrs, body: []const u8) void {
    var params: [32]u32 = undefined;
    const n = parseParams(body, &params);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        switch (params[i]) {
            0 => attrs.* = .{},
            1 => attrs.bold = true,
            3 => attrs.italic = true,
            4 => attrs.underline = true,
            21, 22 => attrs.bold = false,
            23 => attrs.italic = false,
            24 => attrs.underline = false,
            38, 48 => {
                i += 1;
                if (i >= n) break;
                if (params[i] == 5) {
                    i += 1;
                } else if (params[i] == 2) {
                    i += 3;
                }
            },
            else => {},
        }
    }
}

fn parseParams(body: []const u8, params: *[32]u32) usize {
    if (body.len == 0) {
        params[0] = 0;
        return 1;
    }
    var n: usize = 0;
    var start: usize = 0;
    var k: usize = 0;
    while (k <= body.len) : (k += 1) {
        if (k != body.len and body[k] != ';') continue;
        if (n >= params.len) return n;
        const piece = body[start..k];
        params[n] = if (piece.len == 0) 0 else std.fmt.parseUnsigned(u32, piece, 10) catch 0;
        n += 1;
        start = k + 1;
    }
    return n;
}

fn expectStrip(src: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const got = try strip(gpa, src);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

fn expectDim(src: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const got = try dim(gpa, src);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "strip csi" {
    try expectStrip("ab", "ab");
    try expectStrip("a\x1b[31mb", "ab");
    try expectStrip("\x1b[0;1;31mhi\x1b[0m", "hi");
}

test "dim keeps bold italic underline" {
    try expectDim("hello", "\x1b[0;90mhello");
    try expectDim("\x1b[1mhi", "\x1b[0;90m\x1b[0;90;1mhi");
    try expectDim("\x1b[1;3;31mX", "\x1b[0;90m\x1b[0;90;1;3mX");
    try expectDim("\x1b[0mY", "\x1b[0;90m\x1b[0;90mY");
    try expectDim("\x1b[38;5;4mZ", "\x1b[0;90m\x1b[0;90mZ");
    try expectDim("\x1b[4mU", "\x1b[0;90m\x1b[0;90;4mU");
}
