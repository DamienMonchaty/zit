//! `zig build bench -- [repository] [--save FILE] [--vs FILE]`
//!
//! Zit's hot paths, timed on a real repository — the current one by default —
//! with no window: the history read and its graph, the working tree's status
//! (what the poll reads every 0.7 s), commits' diffs, and the lexer over their
//! lines. Each runs once to warm up — its allocations counted there, Zig's
//! own and not libgit2's mallocs — then until it has had half a second or
//! 200 runs, and the median is what counts. Two runs of one build differ by
//! a few percent: a change has to beat that to count.
//!
//! Two variants are compared by saving one and measuring the other against
//! it: `--save before.txt`, change something, `--vs before.txt`. Build with
//! `-Doptimize=` to compare release modes the same way.

const std = @import("std");
const git = @import("git.zig");
const graph = @import("graph.zig");
const syntax = @import("syntax.zig");

/// The commits whose diffs are read, newest first.
const DIFF_COMMITS = 50;
const MIN_RUNS = 5;
const MAX_RUNS = 200;
const BUDGET_NS: u64 = 500 * std.time.ns_per_ms;

/// The allocator every case runs on, counting what goes through it.
const Counting = struct {
    child: std.mem.Allocator,
    count: usize = 0,
    bytes: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.bytes += len;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len) self.bytes += new_len - mem.len;
        return self.child.rawResize(mem, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        if (new_len > mem.len) self.bytes += new_len - mem.len;
        return self.child.rawRemap(mem, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
    }
};

const Result = struct { name: []const u8, median_ns: u64, allocs: usize, bytes: usize };

/// What every case shares: the repository and what was read from it once.
const Ctx = struct {
    repo: git.Repo,
    history: git.History,
    /// The newest commits' diffs, read once, for the lexer alone to be timed.
    diffs: []git.Diff = &.{},
};

const Case = struct {
    name: []const u8,
    run: *const fn (ctx: *Ctx, a: std.mem.Allocator) anyerror!void,
};

const cases = [_]Case{
    .{ .name = "history", .run = struct {
        fn f(ctx: *Ctx, a: std.mem.Allocator) !void {
            var h = try ctx.repo.readHistoryFiltered(a, .{});
            h.deinit();
        }
    }.f },
    .{ .name = "graph", .run = struct {
        fn f(ctx: *Ctx, a: std.mem.Allocator) !void {
            var l = try graph.build(a, ctx.history.commits, ctx.history.head_oid);
            l.deinit();
        }
    }.f },
    .{ .name = "status", .run = struct {
        fn f(ctx: *Ctx, a: std.mem.Allocator) !void {
            var w = try ctx.repo.readWork(a);
            w.deinit();
        }
    }.f },
    .{ .name = "commit diffs", .run = struct {
        fn f(ctx: *Ctx, a: std.mem.Allocator) !void {
            for (ctx.history.commits[0..@min(DIFF_COMMITS, ctx.history.commits.len)]) |c| {
                var d = try ctx.repo.readCommitDiff(a, c.id);
                d.deinit();
            }
        }
    }.f },
    .{ .name = "lexer", .run = struct {
        fn f(ctx: *Ctx, a: std.mem.Allocator) !void {
            _ = a;
            var tokens: [128]syntax.Token = undefined;
            var n: usize = 0;
            for (ctx.diffs) |d| for (d.files) |file| {
                const lang = syntax.langOf(file.path);
                for (file.lines) |line| n += syntax.tokenize(lang, line.text, &tokens).len;
            };
            std.mem.doNotOptimizeAway(n);
        }
    }.f },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var repo_path: []const u8 = ".";
    var save: ?[]const u8 = null;
    var vs: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--save") and i + 1 < args.len) {
            i += 1;
            save = args[i];
        } else if (std.mem.eql(u8, arg, "--vs") and i + 1 < args.len) {
            i += 1;
            vs = args[i];
        } else repo_path = arg;
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    try git.init();
    defer git.shutdown();
    var ctx: Ctx = .{ .repo = try git.Repo.open(repo_path), .history = undefined };
    defer ctx.repo.deinit();
    ctx.history = try ctx.repo.readHistoryFiltered(gpa, .{});
    defer ctx.history.deinit();
    var diffs: std.ArrayList(git.Diff) = .empty;
    defer {
        for (diffs.items) |*d| d.deinit();
        diffs.deinit(gpa);
    }
    for (ctx.history.commits[0..@min(DIFF_COMMITS, ctx.history.commits.len)]) |c| try diffs.append(gpa, try ctx.repo.readCommitDiff(gpa, c.id));
    ctx.diffs = diffs.items;

    const before = if (vs) |path| try readSaved(io, gpa, path) else &.{};
    defer if (vs != null) gpa.free(before);

    try w.print("{s}: {d} commits, {s}\n\n", .{ repo_path, ctx.history.commits.len, @tagName(@import("builtin").mode) });
    try w.print("{s:<14} {s:>10} {s:>9} {s:>11}", .{ "case", "median", "allocs", "bytes" });
    if (vs != null) try w.print(" {s:>9}", .{"vs"});
    try w.writeAll("\n");

    var results: [cases.len]Result = undefined;
    for (cases, 0..) |case, ci| {
        results[ci] = try measure(io, gpa, &ctx, case);
        const r = results[ci];
        try w.print("{s:<14} {d:>8.2}ms {d:>9} {d:>9}KB", .{ r.name, @as(f64, @floatFromInt(r.median_ns)) / 1e6, r.allocs, r.bytes / 1024 });
        for (before) |b| if (std.mem.eql(u8, b.name, r.name)) {
            const pct = (@as(f64, @floatFromInt(r.median_ns)) / @as(f64, @floatFromInt(@max(b.median_ns, 1))) - 1) * 100;
            var pct_buf: [16]u8 = undefined;
            try w.print(" {s:>9}", .{std.fmt.bufPrint(&pct_buf, "{s}{d:.1}%", .{ if (pct >= 0) "+" else "-", @abs(pct) }) catch "?"});
        };
        try w.writeAll("\n");
    }
    try w.flush();

    if (save) |path| try writeSaved(io, gpa, path, &results);
}

fn measure(io: std.Io, gpa: std.mem.Allocator, ctx: *Ctx, case: Case) !Result {
    var times: [MAX_RUNS]u64 = undefined;
    var runs: usize = 0;
    var total: u64 = 0;
    // One run unmeasured, counting the allocations: the first pays for cold
    // caches — the pack index, the page cache — which the rest do not.
    var first: Counting = .{ .child = gpa };
    try case.run(ctx, first.allocator());
    while (runs < MAX_RUNS and (runs < MIN_RUNS or total < BUDGET_NS)) : (runs += 1) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        try case.run(ctx, gpa);
        const t1 = std.Io.Timestamp.now(io, .awake);
        times[runs] = @intCast(t1.nanoseconds - t0.nanoseconds);
        total += times[runs];
    }
    std.mem.sort(u64, times[0..runs], {}, std.sort.asc(u64));
    return .{ .name = case.name, .median_ns = times[runs / 2], .allocs = first.count, .bytes = first.bytes };
}

/// One line a case: its name, a tab, its median in nanoseconds.
fn writeSaved(io: std.Io, gpa: std.mem.Allocator, path: []const u8, results: []const Result) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (results) |r| try text.print(gpa, "{s}\t{d}\n", .{ r.name, r.median_ns });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items });
}

fn readSaved(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]Result {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16));
    defer gpa.free(text);
    var list: std.ArrayList(Result) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        // The names are the cases' own, which outlive this list.
        const name = for (cases) |c| {
            if (std.mem.eql(u8, c.name, line[0..tab])) break c.name;
        } else continue;
        try list.append(gpa, .{ .name = name, .median_ns = std.fmt.parseInt(u64, line[tab + 1 ..], 10) catch continue, .allocs = 0, .bytes = 0 });
    }
    return list.toOwnedSlice(gpa);
}
