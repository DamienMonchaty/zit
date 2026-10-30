//! Turning a flat commit list into the lanes and curves the graph draws.
//!
//! This is the one genuinely custom algorithm in Zit: everything else is
//! libgit2 or dvui. It is the standard gitk/tig approach — walk the commits in
//! topological order carrying a set of open lanes, and at each commit decide
//! which lane it sits in and where its parents go.
//!
//! On top, the way gitk and the metro-map graphs draw: a lane stays in its
//! column from its first commit to its last. One that ends leaves a gap, and
//! the next branch to open takes the first gap — a merge's second parent the
//! first one to its right. Lines run straight down their lanes instead of
//! stepping sideways each time a branch ends to their left.

const std = @import("std");
const git = @import("git.zig");

/// One line drawn in the gap below a row, from a lane on this row to a lane on
/// the next.
pub const Link = struct {
    from: u16,
    to: u16,
    /// Which colour to draw it in: the branch the line belongs to — the
    /// *destination* one — so a branch keeps one colour down its whole
    /// length instead of changing hue every time it passes a merge.
    color_lane: u16,
};

pub const Row = struct {
    /// The lane this commit's dot sits in.
    lane: u16,
    /// Its branch's colour, as `Link.color_lane`.
    color: u16 = 0,
    /// Half-open range into `Layout.links` for the gap below this row.
    link_start: u32,
    link_end: u32,
};

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    links: []Link = &.{},
    /// Widest the graph ever gets, for sizing the graph column.
    lane_count: u16 = 0,

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Lanes past this are folded onto the last one rather than widening the column
/// forever.
///
/// ponytail: a hard clamp, so a pathological history draws slightly wrong
/// instead of pushing the commit messages off screen. Replace with a scrollable
/// graph column if anyone ever has 64 concurrent branches.
pub const MAX_LANES: u16 = 64;

pub fn build(gpa: std.mem.Allocator, commits: []const git.Commit) !Layout {
    var out: Layout = .{ .arena = .init(gpa) };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();

    var rows = try arena.alloc(Row, commits.len);
    var links: std.ArrayList(Link) = .empty;

    // The lanes at the current row, by column: what each waits for (null for
    // a gap), and its branch's colour.
    var active: std.ArrayList(?git.Oid) = .empty;
    defer active.deinit(gpa);
    var colors: std.ArrayList(u16) = .empty;
    defer colors.deinit(gpa);
    var next_color: u16 = 0;
    // Which lanes were open when the row began: those flow on through it.
    var was_open: std.ArrayList(bool) = .empty;
    defer was_open.deinit(gpa);

    for (commits, 0..) |commit, i| {
        const link_start: u32 = @intCast(links.items.len);
        was_open.clearRetainingCapacity();
        for (active.items) |slot| try was_open.append(gpa, slot != null);

        // Its lane: the one waiting for it, or — a branch tip nothing above
        // leads to — the first gap.
        const my: u16 = findLane(active.items, commit.id, null) orelse try openLane(gpa, &active, &colors, &next_color, 0, commit.id);
        const my_color = colors.items[my];

        if (commit.parents.len == 0) {
            // A root commit: the lane ends here.
            active.items[my] = null;
        } else {
            const first = commit.parents[0];
            if (findLane(active.items, first, my)) |existing| {
                // The first parent is already carried by another lane, so
                // this branch rejoins it: end this lane and turn across.
                active.items[my] = null;
                try links.append(arena, .{ .from = my, .to = existing, .color_lane = colors.items[existing] });
            } else {
                active.items[my] = first;
                try links.append(arena, .{ .from = my, .to = my, .color_lane = my_color });
            }

            // Merge parents: the lane already waiting for one, or the first
            // gap to the right of this one — a branch forks off rightwards.
            for (commit.parents[1..]) |parent| {
                const lane = findLane(active.items, parent, null) orelse try openLane(gpa, &active, &colors, &next_color, my + 1, parent);
                try links.append(arena, .{ .from = my, .to = lane, .color_lane = colors.items[lane] });
            }
        }

        // Another lane waiting for this same commit — only after a fold at
        // MAX_LANES — would wait forever: it ends here.
        for (active.items, 0..) |*slot, k| {
            if (k == my) continue;
            if (slot.*) |held| {
                if (git.oidEql(held, commit.id)) slot.* = null;
            }
        }

        // Every other lane that came in from above and is still open flows
        // straight down through this row.
        for (was_open.items, 0..) |open, k| {
            if (!open or k == my or active.items[k] == null) continue;
            try links.append(arena, .{ .from = @intCast(k), .to = @intCast(k), .color_lane = colors.items[k] });
        }

        rows[i] = .{
            .lane = my,
            .color = my_color,
            .link_start = link_start,
            .link_end = @intCast(links.items.len),
        };

        out.lane_count = @max(out.lane_count, @as(u16, @intCast(active.items.len)));
        // Gaps at the right end are no column at all.
        while (active.items.len > 0 and active.items[active.items.len - 1] == null) {
            _ = active.pop();
            _ = colors.pop();
        }
    }

    out.rows = rows;
    out.links = try links.toOwnedSlice(arena);
    return out;
}

/// A lane for `id`, in a new colour: the first gap from `from` rightwards,
/// else a new column at the right — else, past `MAX_LANES`, folded into the
/// last one.
fn openLane(gpa: std.mem.Allocator, active: *std.ArrayList(?git.Oid), colors: *std.ArrayList(u16), next_color: *u16, from: usize, id: git.Oid) !u16 {
    var k = from;
    while (k < active.items.len and active.items[k] != null) k += 1;
    if (k == active.items.len) {
        if (active.items.len >= MAX_LANES) {
            // Folded: given this one to wait for if it has just ended, or the
            // line leads nowhere.
            if (active.items[MAX_LANES - 1] == null) active.items[MAX_LANES - 1] = id;
            return MAX_LANES - 1;
        }
        try active.append(gpa, null);
        try colors.append(gpa, 0);
    }
    active.items[k] = id;
    colors.items[k] = next_color.*;
    next_color.* +%= 1;
    return @intCast(k);
}

/// The lane already waiting for `id`, ignoring `skip` if given.
fn findLane(active: []const ?git.Oid, id: git.Oid, skip: ?u16) ?u16 {
    for (active, 0..) |slot, i| {
        if (skip) |s| {
            if (i == s) continue;
        }
        const held = slot orelse continue;
        if (git.oidEql(held, id)) return @intCast(i);
    }
    return null;
}

// === Tests ===

fn oid(byte: u8) git.Oid {
    var o: git.Oid = std.mem.zeroes(git.Oid);
    o.id[0] = byte;
    return o;
}

/// Where the test commits' parents live, never reused: a test's commits
/// keep pointing into it. Out of room is an index panic, not a mix-up.
var parent_pool: [4096]git.Oid = undefined;
var pool_used: usize = 0;

fn mkCommit(id: u8, parents: []const u8) git.Commit {
    const slot = parent_pool[pool_used..][0..parents.len];
    pool_used += parents.len;
    for (parents, slot) |p, *to| to.* = oid(p);
    return .{ .id = oid(id), .summary = "", .author = "", .time = 0, .parents = slot };
}

test "a straight history uses one lane" {
    const commits = [_]git.Commit{
        mkCommit(3, &.{2}),
        mkCommit(2, &.{1}),
        mkCommit(1, &.{}),
    };

    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();

    try std.testing.expectEqual(@as(u16, 1), layout.lane_count);
    for (layout.rows) |row| try std.testing.expectEqual(@as(u16, 0), row.lane);

    // The root commit ends its lane, so it draws nothing below itself.
    const last = layout.rows[2];
    try std.testing.expectEqual(last.link_start, last.link_end);
}

test "a merge opens a second lane and the branch rejoins it" {
    // 4 merges 3 and 2; both descend from 1.
    const commits = [_]git.Commit{
        mkCommit(4, &.{ 3, 2 }),
        mkCommit(3, &.{1}),
        mkCommit(2, &.{1}),
        mkCommit(1, &.{}),
    };

    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();

    try std.testing.expectEqual(@as(u16, 2), layout.lane_count);
    try std.testing.expectEqual(@as(u16, 0), layout.rows[0].lane);

    // The merge draws one line down its own lane and one across to the second
    // parent's new lane.
    const merge = layout.rows[0];
    const merge_links = layout.links[merge.link_start..merge.link_end];
    try std.testing.expectEqual(@as(usize, 2), merge_links.len);
    try std.testing.expect(merge_links[0].from == 0 and merge_links[0].to == 0);
    try std.testing.expect(merge_links[1].from == 0 and merge_links[1].to == 1);

    // Commit 2 sits in that second lane and collapses back onto lane 0, which
    // is already waiting for commit 1.
    try std.testing.expectEqual(@as(u16, 1), layout.rows[2].lane);
    const collapse = layout.links[layout.rows[2].link_start..layout.rows[2].link_end];
    try std.testing.expect(collapse[0].from == 1 and collapse[0].to == 0);
}

test "a freed lane is reused rather than the graph drifting right" {
    // Two independent roots, then a third branch after the first has ended.
    const commits = [_]git.Commit{
        mkCommit(5, &.{3}),
        mkCommit(4, &.{}),
        mkCommit(3, &.{}),
    };

    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();

    // 5 takes lane 0, 4 is unrelated so it takes lane 1, 3 was already claimed
    // by 5's parent link and stays in lane 0.
    try std.testing.expectEqual(@as(u16, 0), layout.rows[0].lane);
    try std.testing.expectEqual(@as(u16, 1), layout.rows[1].lane);
    try std.testing.expectEqual(@as(u16, 0), layout.rows[2].lane);
    try std.testing.expectEqual(@as(u16, 2), layout.lane_count);
}

test "a branch forks off to the right, into the first gap there" {
    // 6 merges 5 (its own line, on lane 0) and 4; 4 descends from 3, which
    // 5 also reaches; then a lone root 2 under the lot, and 1.
    //   6 = merge(5, 4); 5 -> 3; 4 -> 3; 3 -> 1; 2 root (a second tip); 1 root.
    const commits = [_]git.Commit{
        mkCommit(7, &.{1}),
        mkCommit(6, &.{ 5, 4 }),
        mkCommit(5, &.{3}),
        mkCommit(4, &.{3}),
        mkCommit(3, &.{1}),
        mkCommit(1, &.{}),
    };
    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();

    // 7 is a tip on lane 0; 6, another tip, comes in at the right, lane 1.
    try std.testing.expectEqual(@as(u16, 0), layout.rows[0].lane);
    try std.testing.expectEqual(@as(u16, 1), layout.rows[1].lane);
    // 6's second parent forks off to its right: lane 2, not a free lane to
    // its left.
    var to_right = false;
    for (layout.links[layout.rows[1].link_start..layout.rows[1].link_end]) |l| {
        if (l.from == 1 and l.to == 2) to_right = true;
    }
    try std.testing.expect(to_right);
    // 4 (lane 2) rejoins 5's lane at 3, which stays on lane 1.
    try std.testing.expectEqual(@as(u16, 1), layout.rows[4].lane);
    // And 1 gathers lane 0's and lane 1's lines on lane 0.
    try std.testing.expectEqual(@as(u16, 0), layout.rows[5].lane);
}

test "a lane that ends leaves a gap, and the lanes beside it stay put" {
    // Lane 0 ends at a root while lane 1 carries on: lane 1's branch stays in
    // its column, straight down, in its colour.
    const commits = [_]git.Commit{
        mkCommit(4, &.{2}),
        mkCommit(3, &.{1}),
        mkCommit(2, &.{}),
        mkCommit(1, &.{}),
    };
    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();
    try std.testing.expectEqual(@as(u16, 1), layout.rows[1].lane);
    try std.testing.expectEqual(@as(u16, 1), layout.rows[3].lane);
    try std.testing.expectEqual(layout.rows[1].color, layout.rows[3].color);
    for (layout.links[layout.rows[2].link_start..layout.rows[2].link_end]) |l| {
        try std.testing.expect(l.from == l.to);
    }
}

test "a new branch takes the first gap rather than widening the graph" {
    // 5 waits for 3 on lane 0 and 4 for 1 on lane 1; 3 is a root and frees
    // lane 0 while lane 1 still runs; then 6, a new tip, takes lane 0.
    const commits = [_]git.Commit{
        mkCommit(5, &.{3}),
        mkCommit(4, &.{1}),
        mkCommit(3, &.{}),
        mkCommit(6, &.{1}),
        mkCommit(1, &.{}),
    };
    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();
    try std.testing.expectEqual(@as(u16, 0), layout.rows[3].lane);
    try std.testing.expectEqual(@as(u16, 2), layout.lane_count);
}

// The dangling line in the graph: a side branch rejoins lane 0, which is still
// flowing down from the merge above it. Lane 0 has to carry on through that
// row, not stop at it.
test "a lane a branch rejoins keeps flowing through that row" {
    // 4 merges 2 into 3; 2 sits on lane 1 and rejoins lane 0, which is waiting
    // for 1 — and 3 is between them, on lane 0.
    const commits = [_]git.Commit{
        mkCommit(4, &.{ 3, 2 }),
        mkCommit(2, &.{1}),
        mkCommit(3, &.{1}),
        mkCommit(1, &.{}),
    };

    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();

    // Row of commit 2, on lane 1: its own curve back to lane 0 — and lane 0,
    // coming down from 4 towards 3, straight through.
    const row = layout.rows[1];
    try std.testing.expectEqual(@as(u16, 1), row.lane);
    const links = layout.links[row.link_start..row.link_end];
    var through = false;
    for (links) |l| {
        if (l.from == 0 and l.to == 0) through = true;
    }
    try std.testing.expect(through);

    // And a lane a merge opens is not drawn from above its first row: the
    // merge's own row has no straight line on lane 1.
    for (layout.links[layout.rows[0].link_start..layout.rows[0].link_end]) |l| {
        try std.testing.expect(!(l.from == 1 and l.to == 1));
    }
}

test "a merge folded into a last lane that just ended keeps that lane for its parent" {
    // 63 branch tips, each on its own lane; then a merge on the 64th whose
    // first parent rejoins tip 1's lane, ending its own — the last — and whose
    // second parent, 200, has no lane left but that one.
    var commits: [64 + 1 + 63]git.Commit = undefined;
    for (0..63) |k| commits[k] = mkCommit(@intCast(1 + k), &.{@intCast(64 + k)});
    commits[63] = mkCommit(127, &.{ 64, 200 });
    commits[64] = mkCommit(200, &.{});
    for (0..63) |k| commits[65 + k] = mkCommit(@intCast(64 + k), &.{});

    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();

    // The line the merge drew to 200's lane arrives in that lane's colour:
    // the lane went on to 200, rather than the line ending in a gap that a
    // fresh lane for 200 happened to fill.
    const merge = layout.rows[63];
    const parent = layout.rows[64];
    for (layout.links[merge.link_start..merge.link_end]) |l| {
        if (l.from == merge.lane and l.to == parent.lane) break try std.testing.expectEqual(l.color_lane, parent.color);
    } else return error.NoLineToParent;
}
