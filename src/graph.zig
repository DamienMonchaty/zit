//! Turning a flat commit list into the lanes and curves the graph draws.
//!
//! This is the one genuinely custom algorithm in Zit: everything else is
//! libgit2 or dvui. It is the standard gitk/tig approach — walk the commits in
//! topological order carrying a set of open lanes, and at each commit decide
//! which lane it sits in and where its parents go.
//!
//! Two rules on top, the way VS Code's Git Graph draws: lanes stay packed —
//! when one ends, the ones to its right slide left into its place, so there
//! is never an empty column between two branches — and a branch that forks
//! off takes the lane just to the right of the one it forks from. A branch
//! keeps its colour as it slides: the colour belongs to the branch, not to
//! the column.

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

    // The lanes at the current row, packed: what each waits for, and its
    // branch's colour. During a row a lane can end (null); the row's last
    // step packs them again.
    var active: std.ArrayList(?git.Oid) = .empty;
    defer active.deinit(gpa);
    var colors: std.ArrayList(u16) = .empty;
    defer colors.deinit(gpa);
    var next_color: u16 = 0;

    // Links of this row, with `to` still a pre-packing index.
    var pending: std.ArrayList(Link) = .empty;
    defer pending.deinit(gpa);
    var remap: std.ArrayList(u16) = .empty;
    defer remap.deinit(gpa);
    // Where each lane was at the row's start; null for one born on it.
    var origin: std.ArrayList(?u16) = .empty;
    defer origin.deinit(gpa);

    for (commits, 0..) |commit, i| {
        pending.clearRetainingCapacity();
        origin.clearRetainingCapacity();
        for (0..active.items.len) |k| try origin.append(gpa, @intCast(k));

        // Its lane: the one waiting for it, or — a branch tip nothing above
        // leads to — a new one at the right.
        const my: u16 = findLane(active.items, commit.id, null) orelse blk: {
            if (active.items.len >= MAX_LANES) {
                active.items[MAX_LANES - 1] = commit.id;
                break :blk MAX_LANES - 1;
            }
            try active.append(gpa, commit.id);
            try colors.append(gpa, next_color);
            try origin.append(gpa, null);
            next_color +%= 1;
            break :blk @intCast(active.items.len - 1);
        };
        const my_color = colors.items[my];

        if (commit.parents.len == 0) {
            // A root commit: the lane ends here.
            active.items[my] = null;
        } else {
            const first = commit.parents[0];
            if (findLane(active.items, first, my)) |existing| {
                // The first parent is already carried by another lane, so
                // this branch rejoins it: end this lane and curve across.
                active.items[my] = null;
                try pending.append(gpa, .{ .from = my, .to = existing, .color_lane = colors.items[existing] });
            } else {
                active.items[my] = first;
                try pending.append(gpa, .{ .from = my, .to = my, .color_lane = my_color });
            }

            // Merge parents: the lane already waiting for one, or a new lane
            // just to the right of this one — a branch forks off rightwards.
            var insert_at: usize = my + 1;
            for (1..commit.parents.len) |p| {
                const parent = commit.parents[p];
                if (findLane(active.items, parent, null)) |lane| {
                    try pending.append(gpa, .{ .from = my, .to = lane, .color_lane = colors.items[lane] });
                    continue;
                }
                if (active.items.len >= MAX_LANES) {
                    // Folded into the last lane — given this parent to wait
                    // for if it has just ended, or the line leads nowhere.
                    if (active.items[MAX_LANES - 1] == null) active.items[MAX_LANES - 1] = parent;
                    try pending.append(gpa, .{ .from = my, .to = MAX_LANES - 1, .color_lane = colors.items[MAX_LANES - 1] });
                    continue;
                }
                try active.insert(gpa, insert_at, parent);
                try colors.insert(gpa, insert_at, next_color);
                try origin.insert(gpa, insert_at, null);
                next_color +%= 1;
                // Everything already recorded to its right moved over one.
                for (pending.items) |*l| {
                    if (l.to >= insert_at) l.to += 1;
                }
                try pending.append(gpa, .{ .from = my, .to = @intCast(insert_at), .color_lane = colors.items[insert_at] });
                insert_at += 1;
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

        // Every other lane that came in from above, and is still open, keeps
        // flowing down — from where it was on this row to where it is now,
        // which the inserts above may have moved right.
        for (active.items, origin.items, colors.items, 0..) |slot, from, color, k| {
            const was = from orelse continue;
            if (slot == null or was == my) continue;
            try pending.append(gpa, .{ .from = was, .to = @intCast(k), .color_lane = color });
        }

        // Pack: lanes that ended this row go, the rest slide left.
        remap.clearRetainingCapacity();
        var packed_len: u16 = 0;
        for (active.items) |slot| {
            try remap.append(gpa, packed_len);
            if (slot != null) packed_len += 1;
        }
        var w: usize = 0;
        for (active.items, colors.items) |slot, color| {
            if (slot == null) continue;
            active.items[w] = slot;
            colors.items[w] = color;
            w += 1;
        }
        active.shrinkRetainingCapacity(w);
        colors.shrinkRetainingCapacity(w);

        const link_start: u32 = @intCast(links.items.len);
        for (pending.items) |l| {
            try links.append(arena, .{ .from = l.from, .to = remap.items[l.to], .color_lane = l.color_lane });
        }

        rows[i] = .{
            .lane = my,
            .color = my_color,
            .link_start = link_start,
            .link_end = @intCast(links.items.len),
        };

        // Widest on this row: before packing, with every lane born on it.
        out.lane_count = @max(out.lane_count, @as(u16, @intCast(remap.items.len)));
    }

    out.rows = rows;
    out.links = try links.toOwnedSlice(arena);
    return out;
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

test "a branch forks off to the right, and lanes close up when one ends" {
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
    // 4 (lane 2) rejoins 5's lane at 3; once 3 is reached, the graph is down
    // to the two lanes still open, packed with no gap: 3 sits on lane 1.
    try std.testing.expectEqual(@as(u16, 1), layout.rows[4].lane);
    // And 1 gathers lane 0's and lane 1's lines on lane 0.
    try std.testing.expectEqual(@as(u16, 0), layout.rows[5].lane);
}

test "a branch keeps its colour as it slides left" {
    // Lane 0 ends at a root while lane 1 carries on: lane 1's branch moves
    // to lane 0, in the same colour.
    const commits = [_]git.Commit{
        mkCommit(4, &.{2}),
        mkCommit(3, &.{1}),
        mkCommit(2, &.{}),
        mkCommit(1, &.{}),
    };
    var layout = try build(std.testing.allocator, &commits);
    defer layout.deinit();
    try std.testing.expectEqual(@as(u16, 1), layout.rows[1].lane);
    // After 2 ends lane 0, 1 sits on lane 0 — packed — in 3's colour.
    try std.testing.expectEqual(@as(u16, 0), layout.rows[3].lane);
    try std.testing.expectEqual(layout.rows[1].color, layout.rows[3].color);
    // The slide is drawn: from lane 1 on 2's row, to lane 0 below it.
    var slid = false;
    for (layout.links[layout.rows[2].link_start..layout.rows[2].link_end]) |l| {
        if (l.from == 1 and l.to == 0) slid = true;
    }
    try std.testing.expect(slid);
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
