const std = @import("std");
const Io = std.Io;

pub const flash = @import("flash.zig");
pub const tmux = @import("tmux.zig");

test {
    _ = flash;
    _ = tmux;
}
