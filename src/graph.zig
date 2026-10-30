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

/// `trunk` is the commit HEAD is on: its first-parent line is kept straight
/// down lane 0, as GitComet keeps it, whatever order the other branches come
/// in. Null for none. Of `refs`, the local branches' tips: one that sits on
/// another branch's line gets a whisker, as in GitComet.
pub fn build(gpa: std.mem.Allocator, commits: []const git.Commit, trunk: ?git.Oid, refs: []const git.Ref) !Layout {
    var out: Layout = .{ .arena = .init(gpa) };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();

    var rows = try arena.alloc(Row, commits.len);
    var links: std.ArrayList(Link) = .empty;

    var index: std.AutoHashMapUnmanaged(git.Oid, u32) = .empty;
    defer index.deinit(gpa);
    try index.ensureTotalCapacity(gpa, @intCast(commits.len));
    for (commits, 0..) |c, k| index.putAssumeCapacity(c.id, @intCast(k));

    const is_head = try arena.alloc(bool, commits.len);
    @memset(is_head, false);
    for (refs) |r| if (r.kind == .local) if (index.get(r.target)) |k| {
        is_head[k] = true;
    };

    // The trunk: HEAD's commit and its first parents, as far as the list goes.
    const on_trunk = try arena.alloc(bool, commits.len);
    @memset(on_trunk, false);
    var trunk_tip: ?usize = null;
    if (trunk) |tip| {
        trunk_tip = if (index.get(tip)) |k| k else null;
        var at = index.get(tip);
        while (at) |k| {
            on_trunk[k] = true;
            const c = commits[k];
            at = if (c.parents.len > 0) index.get(c.parents[0]) else null;
        }
    }
    const has_trunk = std.mem.indexOfScalar(bool, on_trunk, true) != null;
    // Lane 0 is the trunk's, from the top: no other branch takes it, even
    // before the trunk's first commit comes.
    const first_free: usize = if (has_trunk) 1 else 0;

    // The lanes at the current row, by column: what each waits for (null for
    // a gap), and its branch's colour.
    var active: std.ArrayList(?git.Oid) = .empty;
    defer active.deinit(gpa);
    var colors: std.ArrayList(u16) = .empty;
    defer colors.deinit(gpa);
    var next_color: u16 = 0;
    if (has_trunk) {
        try active.append(gpa, null);
        try colors.append(gpa, 0);
    }
    // Which lanes were open when the row began: those flow on through it.
    var was_open: std.ArrayList(bool) = .empty;
    defer was_open.deinit(gpa);
    var prev_start: u32 = 0;

    for (commits, 0..) |commit, i| {
        var link_start: u32 = @intCast(links.items.len);
        was_open.clearRetainingCapacity();
        for (active.items) |slot| try was_open.append(gpa, slot != null);
        // How many lanes come down into this commit.
        var hits: usize = 0;
        for (active.items) |slot| {
            if (slot) |held| hits += @intFromBool(git.oidEql(held, commit.id));
        }

        // Its lane: the trunk's own for a trunk commit; otherwise the one
        // waiting for it, or — a branch tip nothing above leads to — the
        // first gap.
        const my: u16 = if (on_trunk[i]) blk: {
            if (active.items[0] == null) {
                active.items[0] = commit.id;
                colors.items[0] = next_color;
                next_color +%= 1;
            }
            break :blk 0;
        } else findLane(active.items, commit.id, null) orelse try openLane(gpa, &active, &colors, &next_color, first_free, commit.id);
        var my_color = colors.items[my];

        // GitComet's whisker: a branch's tip on a line already coming down —
        // one lane, no merge — is marked by a short line of its own colour
        // from the column to its right, where that column is free, so it
        // crosses nothing. Off the trunk the line below takes that colour too;
        // HEAD's own commit needs no mark.
        if (is_head[i] and hits == 1 and commit.parents.len <= 1 and i > 0 and !(trunk_tip == i)) {
            const col = my + 1;
            const free = col >= active.items.len or active.items[col] == null;
            if (free and col < MAX_LANES) {
                const color = next_color;
                next_color +%= 1;
                // In the gap above, coming into this row's node.
                try links.append(arena, .{ .from = col, .to = my, .color_lane = color });
                rows[i - 1].link_end += 1;
                link_start += 1;
                out.lane_count = @max(out.lane_count, col + 1);
                if (!(has_trunk and my == 0)) {
                    colors.items[my] = color;
                    my_color = color;
                }
            }
        }

        // Every other lane waiting for this commit comes into it: the line
        // drawn down it on the row above turns into this node instead.
        for (active.items, 0..) |*slot, k| {
            if (k == my) continue;
            const held = slot.* orelse continue;
            if (!git.oidEql(held, commit.id)) continue;
            slot.* = null;
            for (links.items[prev_start..link_start]) |*l| {
                if (l.to == k) l.to = my;
            }
        }

        if (commit.parents.len == 0) {
            // A root commit: the lane ends here.
            active.items[my] = null;
        } else {
            const first = commit.parents[0];
            const existing = if (on_trunk[i]) null else findLane(active.items, first, my);
            if (existing) |lane| {
                // The first parent is already carried by another lane, so
                // this branch rejoins it: end this lane and turn across.
                active.items[my] = null;
                try links.append(arena, .{ .from = my, .to = lane, .color_lane = colors.items[lane] });
            } else {
                active.items[my] = first;
                try links.append(arena, .{ .from = my, .to = my, .color_lane = my_color });
            }

            // Merge parents: the lane already waiting for one, or the first
            // gap to the right of this one — a branch forks off rightwards.
            for (commit.parents[1..]) |parent| {
                // Not in the list — a first-parent history, or past its end:
                // no line to draw to it.
                if (!index.contains(parent)) continue;
                const lane = findLane(active.items, parent, null) orelse try openLane(gpa, &active, &colors, &next_color, @max(my + 1, first_free), parent);
                try links.append(arena, .{ .from = my, .to = lane, .color_lane = colors.items[lane] });
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
        prev_start = link_start;

        out.lane_count = @max(out.lane_count, @as(u16, @intCast(active.items.len)));
        // Gaps at the right end are no column at all — save the trunk's.
        while (active.items.len > first_free and active.items[active.items.len - 1] == null) {
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

    var layout = try build(std.testing.allocator, &commits, null, &.{});
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

    var layout = try build(std.testing.allocator, &commits, null, &.{});
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

    var layout = try build(std.testing.allocator, &commits, null, &.{});
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
    var layout = try build(std.testing.allocator, &commits, null, &.{});
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
    var layout = try build(std.testing.allocator, &commits, null, &.{});
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
    var layout = try build(std.testing.allocator, &commits, null, &.{});
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

    var layout = try build(std.testing.allocator, &commits, null, &.{});
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

    var layout = try build(std.testing.allocator, &commits, null, &.{});
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

test "HEAD's line runs down lane 0, and a branch newer than it joins it there" {
    // 9 is a branch tip newer than HEAD (3); both come from 2. Read first, 9
    // would take lane 0; with HEAD at 3 it takes lane 1, and HEAD's line —
    // 3, 2, 1 — stays on lane 0.
    const commits = [_]git.Commit{
        mkCommit(9, &.{2}),
        mkCommit(3, &.{2}),
        mkCommit(2, &.{1}),
        mkCommit(1, &.{}),
    };
    var layout = try build(std.testing.allocator, &commits, oid(3), &.{});
    defer layout.deinit();
    try std.testing.expectEqual(@as(u16, 1), layout.rows[0].lane);
    for (layout.rows[1..]) |row| try std.testing.expectEqual(@as(u16, 0), row.lane);
    // 9's line comes into 2 on lane 0, turning in on the row above it.
    var joins = false;
    for (layout.links[layout.rows[1].link_start..layout.rows[1].link_end]) |l| {
        if (l.from == 1 and l.to == 0) joins = true;
    }
    try std.testing.expect(joins);
}

test "a branch's tip on HEAD's line gets a whisker from the column to its right" {
    // HEAD at 3; branch feat points at 2, on HEAD's line below it.
    const commits = [_]git.Commit{
        mkCommit(3, &.{2}),
        mkCommit(2, &.{1}),
        mkCommit(1, &.{}),
    };
    const refs = [_]git.Ref{.{ .name = "feat", .kind = .local, .target = oid(2), .head = false }};
    var layout = try build(std.testing.allocator, &commits, oid(3), &refs);
    defer layout.deinit();
    var whisker = false;
    for (layout.links[layout.rows[0].link_start..layout.rows[0].link_end]) |l| {
        if (l.from == 1 and l.to == 0) whisker = true;
    }
    try std.testing.expect(whisker);
    // On HEAD's line, the line keeps HEAD's colour.
    try std.testing.expectEqual(layout.rows[0].color, layout.rows[1].color);
}

test "off HEAD's line, a branch's tip takes its line over in its own colour" {
    // 9 heads for 5, where branch x points; HEAD (3) is on lane 0.
    const commits = [_]git.Commit{
        mkCommit(9, &.{5}),
        mkCommit(3, &.{1}),
        mkCommit(5, &.{1}),
        mkCommit(1, &.{}),
    };
    const refs = [_]git.Ref{.{ .name = "x", .kind = .local, .target = oid(5), .head = false }};
    var layout = try build(std.testing.allocator, &commits, oid(3), &refs);
    defer layout.deinit();
    try std.testing.expectEqual(@as(u16, 1), layout.rows[2].lane);
    try std.testing.expect(layout.rows[2].color != layout.rows[0].color);
}

test "a merge parent not in the list draws no line" {
    // First-parent histories leave a merge's other parents out.
    const commits = [_]git.Commit{
        mkCommit(3, &.{ 2, 99 }),
        mkCommit(2, &.{1}),
        mkCommit(1, &.{}),
    };
    var layout = try build(std.testing.allocator, &commits, null, &.{});
    defer layout.deinit();
    try std.testing.expectEqual(@as(u16, 1), layout.lane_count);
}
