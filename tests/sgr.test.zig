const std = @import("std");
const sgr = @import("flash_tmux").sgr;

fn expectStrip(src: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const got = try sgr.strip(gpa, src);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

fn expectDim(src: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const got = try sgr.dim(gpa, src);
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

test "block elements become spaces" {
    try expectStrip("a\u{2580}\u{2588}b", "a  b");
    try expectStrip("\x1b[31m\u{2580}\x1b[0mx", " x");
    try expectDim("a\u{2580}b", "\x1b[0;90ma b");
}
