const std = @import("std");

pub const CR = '\r';
pub const ESC = 0x1b;
pub const BS = 0x08;
pub const DEL = 0x7f;

pub const Mode = enum { exact, search };
pub const Reuse = enum { lowercase, all, none };

pub const Pos = struct {
    row: u32 = 0,
    col: u32 = 0,

    pub fn eql(a: Pos, b: Pos) bool {
        return a.row == b.row and a.col == b.col;
    }

    pub fn lt(a: Pos, b: Pos) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }

    pub fn gt(a: Pos, b: Pos) bool {
        return b.lt(a);
    }

    pub fn id(p: Pos) u64 {
        return (@as(u64, p.row) << 32) | p.col;
    }

    fn dist(p: Pos, width: u32) u64 {
        return @as(u64, p.row) * width + p.col;
    }
};

pub const Match = struct {
    pos: Pos,
    end_pos: Pos,
    label: ?u8 = null,
};

pub const Cell = struct {
    col: u32,
    width: u8,
    bytes: []const u8,
};

pub const tabstop: u32 = 8;

pub const Grid = struct {
    lines: []const []const u8,
    width: u32,
    cursor: Pos = .{},
};

pub fn labelCol(m: Match, pane_width: u32) u32 {
    const after = m.end_pos.col + 1;
    if (pane_width != 0 and after >= pane_width) return m.end_pos.col;
    return after;
}

pub fn cursorRights(line: []const u8, target_col: u32) u32 {
    var col: u32 = 0;
    var rights: u32 = 0;
    var i: usize = 0;
    while (i < line.len and col < target_col) {
        if (line[i] == 0x09) {
            const rem = col % tabstop;
            col += if (rem == 0) tabstop else tabstop - rem;
            rights += 1;
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch {
            col += 1;
            rights += 1;
            i += 1;
            continue;
        };
        if (i + n > line.len) {
            col += 1;
            rights += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(line[i .. i + n]) catch {
            col += 1;
            rights += 1;
            i += 1;
            continue;
        };
        i += n;
        const w = codeWidth(cp);
        if (w == 0) continue;
        col += w;
        rights += 1;
    }
    return rights;
}

pub const Opts = struct {
    labels: []const u8 = "asdfghjklqwertyuiopzxcvbnm",
    uppercase: bool = true,
    exclude: []const u8 = "",
    current: bool = true,
    reuse: Reuse = .lowercase,
    distance: bool = true,
    min_pattern_length: usize = 0,
    forward: bool = true,
    wrap: bool = true,
    mode: Mode = .exact,
    max_length: ?usize = null,
    autojump: bool = false,
    trigger: []const u8 = "",
    jump_on_max_length: bool = true,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    opts: Opts,
    grid: Grid,
    rows: [][]Cell = &.{},
    pattern: std.ArrayList(u8) = .empty,
    results: std.ArrayList(Match) = .empty,
    labeler: Labeler,
    target: ?Match = null,
    jumped: ?Match = null,
    aborted: bool = false,
    unconsumed: ?u8 = null,
    visible: bool = true,

    pub fn init(allocator: std.mem.Allocator, grid: Grid, opts: Opts) !State {
        var self: State = .{
            .allocator = allocator,
            .opts = opts,
            .grid = grid,
            .labeler = Labeler.init(allocator),
        };
        self.rows = try parseGrid(allocator, grid.lines);
        _ = try self.update(self.pattern.items, false);
        return self;
    }

    pub fn deinit(self: *State) void {
        for (self.rows) |row| self.allocator.free(row);
        self.allocator.free(self.rows);
        self.pattern.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.labeler.deinit();
    }

    pub fn hide(self: *State) void {
        self.visible = false;
    }

    /// Flash `State:loop`. Feed ASCII keys; ESC/null abort is `step(null)` or `ESC`.
    pub fn loop(self: *State, keys: []const u8) !void {
        for (keys) |k| {
            if (!try self.step(k)) break;
        }
        self.hide();
    }

    /// Flash `State:step`. `null` is `get_char` failure / ESC. `true` continues the loop.
    pub fn step(self: *State, c: ?u8) !bool {
        const ch = c orelse {
            self.aborted = true;
            return false;
        };
        if (ch == ESC) {
            self.aborted = true;
            return false;
        }
        if (ch == CR) {
            _ = self.jump(null);
            return false;
        }

        const orig = try self.allocator.dupe(u8, self.pattern.items);
        defer self.allocator.free(orig);
        const next = try extendAlloc(self.allocator, self.pattern.items, ch);
        defer self.allocator.free(next);

        if (try self.update(next, true)) return false;

        if (self.opts.max_length) |max| {
            if (self.pattern.items.len > max) {
                _ = try self.update(orig, false);
                if (self.opts.jump_on_max_length) _ = self.jump(null);
                self.unconsumed = ch;
                return false;
            }
        }

        if (self.results.items.len == 0 and self.pattern.items.len != 0 and self.opts.mode != .search) {
            return false;
        }

        if (self.results.items.len == 1 and self.opts.autojump) {
            _ = self.jump(null);
            return false;
        }
        return true;
    }

    /// Flash `State:update`. `true` means jumped (abort search).
    pub fn update(self: *State, pattern: []const u8, check_jump: bool) !bool {
        if (check_jump and self.checkJump(pattern)) return true;
        self.pattern.clearRetainingCapacity();
        try self.pattern.appendSlice(self.allocator, pattern);
        if (!self.visible) return false;
        try self.updateInner();
        return false;
    }

    /// Flash `State:check_jump`.
    pub fn checkJump(self: *State, pattern: []const u8) bool {
        if (!self.visible) return false;
        if (self.opts.trigger.len != 0) {
            if (self.pattern.items.len < self.opts.trigger.len or
                !std.mem.endsWith(u8, self.pattern.items, self.opts.trigger))
                return false;
        }
        if (!std.mem.startsWith(u8, pattern, self.pattern.items)) return false;
        if (pattern.len != self.pattern.items.len + 1) return false;
        return self.jump(pattern[pattern.len - 1]);
    }

    /// Flash `State:jump`. `label == null` jumps `target`.
    pub fn jump(self: *State, label: ?u8) bool {
        const match = if (label) |l| self.findLabel(l) else self.target;
        if (match) |m| {
            self.jumped = m;
            return true;
        }
        return false;
    }

    fn findLabel(self: *const State, label: u8) ?Match {
        for (self.results.items) |m| {
            if (m.label == label) return m;
        }
        return null;
    }

    fn updateInner(self: *State) !void {
        try collectMatches(self.allocator, self.rows, self.search(), &self.results);
        self.target = findMatch(self.results.items, self.grid.cursor, self.opts.forward, self.opts.wrap, 1);
        if (self.pattern.items.len >= self.opts.min_pattern_length) {
            try self.labeler.update(self);
        } else {
            for (self.results.items) |*m| m.label = null;
        }
    }

    fn search(self: *const State) []const u8 {
        const p = self.pattern.items;
        const trigger = self.opts.trigger;
        if (trigger.len != 0 and std.mem.endsWith(u8, p, trigger)) {
            return p[0 .. p.len - trigger.len];
        }
        return p;
    }
};

const Labeler = struct {
    allocator: std.mem.Allocator,
    used: std.AutoHashMap(u64, u8),
    labels: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) Labeler {
        return .{ .allocator = allocator, .used = .init(allocator) };
    }

    fn deinit(self: *Labeler) void {
        self.labels.deinit(self.allocator);
        self.used.deinit();
    }

    fn update(self: *Labeler, state: *State) !void {
        try self.reset(state);

        var ranked: std.ArrayList(usize) = .empty;
        defer ranked.deinit(state.allocator);
        try self.filter(state, &ranked);

        for (ranked.items) |i| {
            _ = self.label(state, &state.results.items[i], true);
        }
        for (ranked.items) |i| {
            if (!self.label(state, &state.results.items[i], false)) break;
        }
    }

    fn reset(self: *Labeler, state: *State) !void {
        const gpa = state.allocator;
        self.labels.clearRetainingCapacity();

        var seen: [256]bool = [_]bool{false} ** 256;
        for (state.opts.exclude) |c| seen[c] = true;

        try appendNew(&self.labels, gpa, state.opts.labels, &seen);
        if (state.opts.uppercase) {
            var upper_buf: [256]u8 = undefined;
            const n = @min(state.opts.labels.len, upper_buf.len);
            _ = std.ascii.upperString(upper_buf[0..n], state.opts.labels[0..n]);
            try appendNew(&self.labels, gpa, upper_buf[0..n], &seen);
        }

        const skip_labels = if (state.opts.max_length) |max|
            state.pattern.items.len < max
        else
            true;
        if (skip_labels) {
            try self.skip(state);
        }

        for (state.results.items) |*m| m.label = null;
    }

    fn skip(self: *Labeler, state: *State) !void {
        const needle = state.search();
        if (needle.len == 0) {
            self.labels.clearRetainingCapacity();
            return;
        }

        while (self.labels.items.len > 0) {
            const ch = nextCharAfterNeedle(state.rows, needle, self.labels.items) orelse return;
            const before = self.labels.items.len;
            self.use(ch);
            if (self.labels.items.len == before) {
                self.labels.clearRetainingCapacity();
                return;
            }
        }
    }

    fn filter(self: *Labeler, state: *State, ranked: *std.ArrayList(usize)) !void {
        _ = self;
        const gpa = state.allocator;
        const target = state.target;

        for (state.results.items, 0..) |m, i| {
            const skip_current = (target != null and Pos.eql(m.pos, target.?.pos) and !state.opts.current);
            if (!skip_current) try ranked.append(gpa, i);
        }

        const cursor = state.grid.cursor;
        const width = state.grid.width;
        const use_distance = state.opts.distance;
        std.mem.sort(usize, ranked.items, SortCtx{
            .matches = state.results.items,
            .cursor = cursor,
            .width = width,
            .use_distance = use_distance,
        }, SortCtx.lessThan);
    }

    fn label(self: *Labeler, state: *State, m: *Match, used: bool) bool {
        if (m.label != null) return true;
        const pos = Pos.id(m.pos);
        const candidate: ?u8 = if (used) self.used.get(pos) else self.first();
        if (candidate) |lab| {
            if (self.valid(lab)) {
                self.use(lab);
                const reuse = state.opts.reuse == .all or
                    (state.opts.reuse == .lowercase and std.ascii.isLower(lab));
                if (reuse) self.used.put(pos, lab) catch {};
                m.label = lab;
            }
        }
        return self.labels.items.len > 0;
    }

    fn first(self: *const Labeler) ?u8 {
        if (self.labels.items.len == 0) return null;
        return self.labels.items[0];
    }

    fn valid(self: *const Labeler, lab: u8) bool {
        return std.mem.indexOfScalar(u8, self.labels.items, lab) != null;
    }

    fn use(self: *Labeler, lab: u8) void {
        var w: usize = 0;
        for (self.labels.items) |c| {
            if (c != lab) {
                self.labels.items[w] = c;
                w += 1;
            }
        }
        self.labels.items.len = w;
    }
};

const SortCtx = struct {
    matches: []const Match,
    cursor: Pos,
    width: u32,
    use_distance: bool,

    fn lessThan(ctx: SortCtx, a: usize, b: usize) bool {
        const ma = ctx.matches[a];
        const mb = ctx.matches[b];
        if (ctx.use_distance) {
            const dfrom = Pos.dist(ctx.cursor, ctx.width);
            const da = Pos.dist(ma.pos, ctx.width);
            const db = Pos.dist(mb.pos, ctx.width);
            const aa = absDiff(dfrom, da);
            const bb = absDiff(dfrom, db);
            if (aa != bb) return aa < bb;
        }
        if (ma.pos.row != mb.pos.row) return ma.pos.row < mb.pos.row;
        return ma.pos.col < mb.pos.col;
    }
};

fn absDiff(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

fn appendNew(list: *std.ArrayList(u8), gpa: std.mem.Allocator, chars: []const u8, seen: *[256]bool) !void {
    for (chars) |c| {
        if (seen[c]) continue;
        seen[c] = true;
        try list.append(gpa, c);
    }
}

fn extendAlloc(allocator: std.mem.Allocator, pattern: []const u8, ch: u8) ![]u8 {
    if (ch == BS or ch == DEL) {
        if (pattern.len == 0) return allocator.dupe(u8, "");
        return allocator.dupe(u8, pattern[0 .. pattern.len - 1]);
    }
    var out = try allocator.alloc(u8, pattern.len + 1);
    @memcpy(out[0..pattern.len], pattern);
    out[pattern.len] = ch;
    return out;
}

fn parseGrid(allocator: std.mem.Allocator, lines: []const []const u8) ![][]Cell {
    const rows = try allocator.alloc([]Cell, lines.len);
    var n: usize = 0;
    errdefer {
        for (rows[0..n]) |row| allocator.free(row);
        allocator.free(rows);
    }
    for (lines, 0..) |line, i| {
        rows[i] = try parseLine(allocator, line);
        n += 1;
    }
    return rows;
}

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) ![]Cell {
    var list: std.ArrayList(Cell) = .empty;
    errdefer list.deinit(allocator);
    var col: u32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x09) {
            const rem = col % tabstop;
            col += if (rem == 0) tabstop else tabstop - rem;
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch {
            try list.append(allocator, .{ .col = col, .width = 1, .bytes = line[i .. i + 1] });
            col += 1;
            i += 1;
            continue;
        };
        if (i + n > line.len) {
            try list.append(allocator, .{ .col = col, .width = 1, .bytes = line[i .. i + 1] });
            col += 1;
            i += 1;
            continue;
        }
        const bytes = line[i .. i + n];
        const cp = std.unicode.utf8Decode(bytes) catch {
            try list.append(allocator, .{ .col = col, .width = 1, .bytes = line[i .. i + 1] });
            col += 1;
            i += 1;
            continue;
        };
        i += n;
        const w = codeWidth(cp);
        if (w == 0) continue;
        try list.append(allocator, .{ .col = col, .width = @intCast(w), .bytes = bytes });
        col += w;
    }
    return list.toOwnedSlice(allocator);
}

fn matchFrom(cells: []const Cell, needle: []const u8) ?usize {
    var got: usize = 0;
    for (cells, 0..) |cell, j| {
        const b = cell.bytes;
        if (b.len == 0) continue;
        if (got + b.len > needle.len) return null;
        if (!std.mem.eql(u8, b, needle[got .. got + b.len])) return null;
        got += b.len;
        if (got == needle.len) return j;
    }
    return null;
}

fn collectMatches(
    allocator: std.mem.Allocator,
    rows: []const []Cell,
    needle: []const u8,
    out: *std.ArrayList(Match),
) !void {
    out.clearRetainingCapacity();
    if (needle.len == 0) return;
    for (rows, 0..) |cells, row| {
        var i: usize = 0;
        while (i < cells.len) : (i += 1) {
            const last_off = matchFrom(cells[i..], needle) orelse continue;
            const last = cells[i + last_off];
            const start = cells[i];
            const end_col = last.col + last.width - 1;
            try out.append(allocator, .{
                .pos = .{ .row = @intCast(row), .col = start.col },
                .end_pos = .{ .row = @intCast(row), .col = end_col },
            });
        }
    }
}

fn nextCharAfterNeedle(rows: []const []Cell, needle: []const u8, labels: []const u8) ?u8 {
    for (rows) |cells| {
        var i: usize = 0;
        while (i < cells.len) : (i += 1) {
            const last_off = matchFrom(cells[i..], needle) orelse continue;
            const next_i = i + last_off + 1;
            if (next_i >= cells.len) continue;
            const b = cells[next_i].bytes;
            if (b.len != 1) continue;
            if (std.mem.indexOfScalar(u8, labels, b[0]) != null) return b[0];
        }
    }
    return null;
}

fn findMatch(matches: []const Match, pos: Pos, forward: bool, wrap: bool, count: u32) ?Match {
    if (matches.len == 0) return null;
    if (count == 0) {
        for (matches) |m| {
            if (Pos.eql(m.pos, pos)) return m;
        }
        return null;
    }

    var idx: ?usize = null;
    if (forward) {
        for (matches, 0..) |m, i| {
            if (Pos.gt(m.pos, pos)) {
                idx = i;
                break;
            }
        }
    } else {
        var i = matches.len;
        while (i > 0) {
            i -= 1;
            if (Pos.lt(matches[i].pos, pos)) {
                idx = i;
                break;
            }
        }
    }

    if (idx == null) {
        if (!wrap) return null;
        idx = if (forward) 0 else matches.len - 1;
    }

    var i: i64 = @intCast(idx.?);
    if (forward) {
        i += count - 1;
    } else {
        i -= count - 1;
    }

    const n: i64 = @intCast(matches.len);
    if (wrap) {
        i = @mod(i, n);
        if (i < 0) i += n;
    } else if (i < 0 or i >= n) {
        return null;
    }
    return matches[@intCast(i)];
}

/// Display column of the codepoint that starts at `byte_col`.
pub fn displayCol(line: []const u8, byte_col: u32) u32 {
    var i: usize = 0;
    var col: u32 = 0;
    while (i < line.len and i < byte_col) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch {
            i += 1;
            col += 1;
            continue;
        };
        if (i + n > line.len or i + n > byte_col) break;
        const cp = std.unicode.utf8Decode(line[i..][0..n]) catch {
            i += 1;
            col += 1;
            continue;
        };
        i += n;
        col += codeWidth(cp);
    }
    return col;
}

fn codeWidth(cp: u21) u32 {
    if (cp == 0 or cp < 0x20 or cp == 0x7f) return 0;
    if (isCombining(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F) or
        cp == 0x200B or cp == 0xFEFF;
}

fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2329 and cp <= 0x232A) or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}
