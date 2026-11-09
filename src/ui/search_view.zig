const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const avatars = @import("../github/avatar.zig");
const pr = @import("../github/pr.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const rebase_view = @import("rebase_view.zig");
const dialog_views = @import("dialog_views.zig");
const repo_io = @import("../core/repo_io.zig");
const app = @import("../main.zig");

// === Search through git ===
//
// `path:` and `code:` are not in the history Zit holds: they are `git log`'s
// pathspec and pickaxe (`-S`), run on another thread whenever that part of the
// search changes. Until the answer is back, they match nothing.

const SearchHits = struct {
    /// The path and code terms the hits were asked for, joined.
    key: std.ArrayList(u8) = .empty,
    ids: std.AutoHashMapUnmanaged(git.Oid, void) = .empty,
    ready: bool = false,
    /// `history_seq` the hits were read against: a commit or a fetch since
    /// then asks again, with the old hits up until the new ones land.
    seq: u64 = 0,
    /// Why there are none: git's error, or a search it cannot run. Shown in
    /// place of "No commit matches".
    err: std.ArrayList(u8) = .empty,
    running: ?*SearchFetch = null,
};
pub var search_hits: SearchHits = .{};

/// A `git log` for the path and code terms, and what it was asked for.
const SearchFetch = struct {
    run: *run.Capture,
    /// Owns `key`.
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    seq: u64,

    fn finished(self: *const SearchFetch) bool {
        return self.run.finished();
    }

    fn free(self: *SearchFetch) void {
        self.run.deinit(app.app_io);
        self.arena.deinit();
        app.gpa.destroy(self);
    }
};

/// Once a frame, before the rows are counted: land an answer, and ask again
/// when the path or code part of the search has changed.
pub fn updateSearchHits() void {
    reapSearchFetches(false);
    var buf: [graph_view.MAX_TERMS]graph_view.Term = undefined;
    const terms = graph_view.parseQuery(app.commit_filter.items, &buf);
    var key_buf: [1024]u8 = undefined;
    var key_len: usize = 0;
    var paths: usize = 0;
    var codes: usize = 0;
    for (terms) |t| {
        if (t.kind != .path and t.kind != .code) continue;
        if (t.kind == .path) paths += 1 else codes += 1;
        const part = std.fmt.bufPrint(key_buf[key_len..], "{s}:{s}\x00", .{ @tagName(t.kind), t.text }) catch break;
        key_len += part.len;
    }
    const key = key_buf[0..key_len];

    if (!std.mem.eql(u8, key, search_hits.key.items)) {
        // What was asked a keystroke ago is let go of, not waited for: a
        // pickaxe can take seconds, and this one would only be thrown away.
        if (search_hits.running) |f| {
            search_hits.running = null;
            if (f.finished()) f.free() else search_retired.append(app.gpa, f) catch f.free();
        }
        search_hits.key.clearRetainingCapacity();
        search_hits.key.appendSlice(app.gpa, key) catch {};
        search_hits.ready = false;
        search_hits.ids.clearRetainingCapacity();
        search_hits.err.clearRetainingCapacity();
        // git ORs pathspecs together and takes a single pickaxe, so a second
        // of either would widen the search or be dropped, where every other
        // term narrows it. Said rather than run.
        if (paths > 1 or codes > 1) {
            search_hits.err.appendSlice(app.gpa, "One path: and one code: at a time.") catch {};
            search_hits.ready = true;
            search_hits.seq = graph_view.history_seq;
        }
    }

    if (search_hits.running) |f| {
        if (!f.finished()) return;
        search_hits.running = null;
        defer f.free();
        // An answer to what the search was a few keystrokes ago, or to
        // another repository, is dropped.
        if (std.mem.eql(u8, f.key, search_hits.key.items) and std.mem.eql(u8, f.run.cwd, app.repo_path.items)) {
            search_hits.ids.clearRetainingCapacity();
            search_hits.err.clearRetainingCapacity();
            if (f.run.ok) {
                var lines = std.mem.splitScalar(u8, f.run.out, '\n');
                while (lines.next()) |line| {
                    if (git.oidFromHex(std.mem.trim(u8, line, " \r"))) |id| search_hits.ids.put(app.gpa, id, {}) catch {};
                }
            } else {
                search_hits.err.appendSlice(app.gpa, if (f.run.err.items.len > 0) f.run.err.items else "git could not run that search.") catch {};
            }
            search_hits.ready = true;
            search_hits.seq = f.seq;
            dvui.refresh(null, @src(), null);
            return;
        }
    }

    if (paths > 1 or codes > 1) return;
    if (key.len > 0 and (!search_hits.ready or search_hits.seq != graph_view.history_seq) and app.repo != null) startSearchFetch(terms);
}

fn startSearchFetch(terms: []const graph_view.Term) void {
    const f = app.gpa.create(SearchFetch) catch return;
    f.arena = .init(app.gpa);
    const a = f.arena.allocator();
    const fail = struct {
        fn undo(fetch: *SearchFetch) void {
            fetch.arena.deinit();
            app.gpa.destroy(fetch);
        }
    }.undo;
    var argv: std.ArrayList([]const u8) = .empty;
    // No more hits than the history holds commits.
    const cap = std.fmt.allocPrint(a, "-n{d}", .{git.MAX_COMMITS}) catch return fail(f);
    argv.appendSlice(a, &.{ "git", "log", "--all", "--format=%H", cap }) catch return fail(f);
    // git takes one pickaxe; `updateSearchHits` lets only one through.
    for (terms) |t| if (t.kind == .code) {
        argv.append(a, std.fmt.allocPrint(a, "-S{s}", .{t.text}) catch return fail(f)) catch return fail(f);
        break;
    };
    argv.append(a, "--") catch return fail(f);
    for (terms) |t| if (t.kind == .path) {
        // A bare name finds the file wherever it is.
        const spec = if (std.mem.indexOfAny(u8, t.text, "/*") == null)
            std.fmt.allocPrint(a, ":(glob)**/{s}*", .{t.text}) catch return fail(f)
        else
            a.dupe(u8, t.text) catch return fail(f);
        argv.append(a, spec) catch return fail(f);
    };
    f.key = a.dupe(u8, search_hits.key.items) catch return fail(f);
    f.seq = graph_view.history_seq;
    f.run = run.Capture.start(app.gpa, app.app_io, app.repo_path.items, argv.items) catch return fail(f);
    search_hits.running = f;
}

/// Searches let go of before they finished — the query cleared, the tab
/// switched — freed once their `git log` is done. Waiting for one on the UI
/// thread is a frozen window for as long as a pickaxe takes. Never read: what
/// they found is for a search nobody is running any more.
pub var search_retired: std.ArrayList(*SearchFetch) = .empty;

/// Free the retired searches that are done; with `all`, wait for the rest.
pub fn reapSearchFetches(all: bool) void {
    var i = search_retired.items.len;
    while (i > 0) {
        i -= 1;
        const f = search_retired.items[i];
        if (!all and !f.finished()) continue;
        _ = search_retired.swapRemove(i);
        f.free();
    }
    if (all) search_retired.clearAndFree(app.gpa);
}

pub fn clearSearchHits() void {
    if (search_hits.running) |f| {
        if (f.finished()) f.free() else search_retired.append(app.gpa, f) catch f.free();
    }
    search_hits.key.deinit(app.gpa);
    search_hits.ids.deinit(app.gpa);
    search_hits.err.deinit(app.gpa);
    search_hits = .{};
}

pub fn changeCount() usize {
    const w = app.work orelse return 0;
    return w.staged.len + w.unstaged.len;
}

/// The uncommitted-changes row, at the top of the graph where it happened.
pub fn wipRow(src: std.builtin.SourceLocation, width: f32) void {
    const w = app.work orelse return;
    // Selected when nothing else is: that is when the panel on the right is
    // showing these changes.
    const selected = app.selection == .none;

    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .tag = "wip_row",
        .rect = .{ .x = 0, .y = 0, .w = width, .h = style.graph_row },
        .background = true,
        .color_fill = .{ .color = if (selected) style.rowSelected() else style.background() },
        .padding = .{ .x = style.space.lg, .w = style.space.lg },
    });
    defer row.deinit();
    // Clicked: the changes, on the right, in place of whichever commit was.
    defer if (dvui.clicked(row.data(), .{})) app.clearSelection();

    // Its node on the line of the commit it goes on top of — HEAD's — in that
    // line's colour, a pencil on a ring: a commit still being written. A
    // dotted line down joins it to HEAD's node (`drawLanes`).
    {
        const head = headLane();
        const hue = if (head) |hl| hl.color else style.accent();
        var column = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = graphLead() },
            .expand = .vertical,
            .background = false,
            .padding = dvui.Rect.all(0),
        });
        defer column.deinit();
        var node = dvui.box(@src(), .{}, .{
            .background = true,
            .color_fill = .{ .color = style.tint(hue) },
            .border = dvui.Rect.all(WIP_RING),
            .color_border = .{ .color = hue },
            .corners = .all(style.avatar / 2),
            .min_size_content = .{ .w = style.avatar - 2 * WIP_RING, .h = style.avatar - 2 * WIP_RING },
            .max_size_content = .size(.{ .w = style.avatar - 2 * WIP_RING, .h = style.avatar - 2 * WIP_RING }),
            .gravity_y = 0.5,
            // Centred on the lane as a commit's node is, and as big, ring
            // included: the row's padding is already the canvas's offset.
            .margin = .{ .x = branchColumn() + laneX(if (head) |hl| hl.lane else 0) - style.avatar / 2 },
            .padding = dvui.Rect.all(0),
        });
        defer node.deinit();
        dvui.icon(@src(), "wip_icon", dvui.entypo.pencil, .{ .fill_color = .{ .color = hue } }, .{
            .min_size_content = .{ .w = 10, .h = 10 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
    }

    dvui.label(@src(), "Uncommitted changes", .{}, .{
        .font = style.bodyBold(),
        .color_text = .{ .color = style.accent() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });

    // How many, on chips: still to stage, and staged.
    if (w.unstaged.len > 0) wipChip(@src(), dvui.entypo.pencil, w.unstaged.len, "unstaged", style.fileStatusColor(.modified));
    if (w.staged.len > 0) wipChip(@src(), dvui.entypo.check, w.staged.len, "staged", style.fileStatusColor(.added));
}

const WIP_RING: f32 = 1.5;

/// The line HEAD's commit is on, which the uncommitted changes go on top of:
/// its lane, its colour, and its place among the commits. Null where the
/// lanes are not drawn in full.
fn headLane() ?struct { lane: u16, color: dvui.Color, index: usize } {
    if (graphCompact()) return null;
    const h = app.history orelse return null;
    const l = app.lanes orelse return null;
    const id = h.head_oid orelse return null;
    // HEAD is near the top: the walk stops early.
    for (h.commits, 0..) |c, i| if (git.oidEql(c.id, id)) {
        if (i >= l.rows.len) return null;
        return .{ .lane = l.rows[i].lane, .color = style.laneColor(l.rows[i].color), .index = i };
    };
    return null;
}

/// A count on the uncommitted row: its icon and number on a tint of `color`.
fn wipChip(src: std.builtin.SourceLocation, icon: []const u8, n: usize, what: []const u8, color: dvui.Color) void {
    var chip = dvui.box(src, .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = .{ .color = style.tint(color) },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.md },
        .padding = .{ .x = style.space.sm, .y = 1, .w = style.space.sm, .h = 1 },
    });
    defer chip.deinit();
    dvui.icon(@src(), "wip_chip", icon, .{ .fill_color = .{ .color = color } }, .{
        .min_size_content = .{ .w = 10, .h = 10 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    dvui.label(@src(), "{d} {s}", .{ n, what }, .{
        .font = style.tinyBold(),
        .color_text = .{ .color = color },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

pub fn commitRow(
    src: std.builtin.SourceLocation,
    row_index: usize,
    commit_index: usize,
    width: f32,
    rh: f32,
    /// Whether the lanes, and the avatars on them, are drawn under this row.
    lanes_drawn: bool,
    /// Left out by the search: drawn faint, in its place.
    dimmed: bool,
) void {
    const faded = dvui.alpha(if (dimmed) 0.35 else 1);
    defer dvui.alphaSet(faded);
    const h = app.history orelse return;
    const commit = h.commits[commit_index];

    const selected = switch (app.selection) {
        .commit => |id| git.oidEql(id, commit.id),
        else => false,
    };
    // The tip of the branch picked in "Branches:", marked as Git Graph marks
    // it: where that branch is now.
    const solo_tip = for (h.refs) |ref| {
        if (git.oidEql(ref.target, commit.id) and graph_view.hasName(graph_view.graph_only.items, ref.name)) break true;
    } else false;

    // Its place in the graph, where the lanes are drawn in full.
    const lane: ?graph.Row = if (lanes_drawn and !graphCompact()) if (app.lanes) |l|
        (if (commit_index < l.rows.len) l.rows[commit_index] else null)
    else
        null else null;
    const hue: ?dvui.Color = if (lane) |l| style.laneColor(l.color) else null;

    // The picked request's commits, tinted: where it sits in the history.
    const in_request = inPickedRequest(commit.id);
    var short: [8]u8 = undefined;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = row_index,
        .tag = dialog_views.frameTag("commit", git.oidShort(commit.id, &short)),
        .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(row_index)) * rh, .w = width, .h = rh },
        // No rule between rows: the hover keeps them apart.
        .background = true,
        .color_fill = .{ .color = if (selected)
            (if (hue) |c| style.laneWash(c, true) else style.rowSelected())
        else if (solo_tip or in_request)
            style.accentDim()
        else
            style.background() },
        .padding = .{ .x = style.space.lg, .w = style.space.lg },
    });
    // A band of the lane's colour from the node to the message: which line of
    // the graph a message belongs to, read without following it by eye. Under
    // everything, so it goes on before the first label.
    // The row under the pointer, lit: which message the date and the author
    // across the row belong to. A fill over the row's own, before anything
    // is drawn on it.
    const rs = row.data().rectScale();
    const hovered = !selected and rs.r.contains(dvui.currentWindow().mouse_pt);
    if (hovered) rs.rectToPhysical(.{ .x = 0, .y = 0, .w = width, .h = rh - 1 })
        .fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });
    // HEAD's commit, a bar of the accent down its left edge, as GitComet
    // marks it: where the next commit goes, found at a glance.
    if (h.head_oid) |head| if (git.oidEql(head, commit.id)) rs.rectToPhysical(.{ .x = 0, .y = 0, .w = 3, .h = rh })
        .fill(.{}, .{ .color = .{ .color = style.accent() }, .fade = 0 });

    // Only under the pointer, as GitComet has it: the lines alone say which
    // branch is which.
    if (lane) |l| if (!selected and hovered) {
        const x0 = style.space.lg + branchColumn() + laneX(l.lane);
        const x1 = style.space.lg + graphRuleX();
        // The branch the commit is on, lit the way GitKraken lights it.
        rs.rectToPhysical(.{ .x = x0, .y = 0, .w = x1 - x0, .h = rh - 1 })
            .fill(.{}, .{ .color = .{ .color = style.laneWash(hue.?, hovered) }, .fade = 0 });
    };

    // Where the lanes are drawn, the branch names have a column of their own
    // before the graph, as GitKraken lays it out: read from the column's
    // left, and joined to the node by a line of its colour. A search shows
    // no lanes, so its names stay in front of the message.
    if (lanes_drawn) {
        var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = branchColumn(), .h = rh },
            .max_size_content = .width(branchColumn()),
            .background = false,
            .padding = .{ .w = style.space.sm },
        });
        var chips = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false });
        const shown = refTags(h, commit, row_index, 1, hue);
        const chips_end = chips.data().borderRectScale().r;
        chips.deinit();
        cell.deinit();
        if (shown) if (lane) |l| {
            // From the last tag's edge, not the margin after it.
            const from = (chips_end.x + chips_end.w - rs.r.x) / rs.s - style.space.sm;
            // To the node's edge: a merge's disc, or a commit's picture or dot.
            const edge = if (commit.parents.len > 1) style.avatar / 2 else nodeRadius();
            const to = style.space.lg + branchColumn() + laneX(l.lane) - edge - 1;
            if (to > from) rs.rectToPhysical(.{ .x = from, .y = rh / 2 - 0.75, .w = to - from, .h = 1.5 })
                .fill(.{}, .{ .color = .{ .color = hue.? }, .fade = 0 });
        };
        // The lanes are painted over this gap by `drawLanes`.
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = graphColumn() + style.graph.gap } });
    }

    // Tags and message share one region that takes what the fixed columns
    // leave and never asks for more — so two long branch names squeeze the
    // message, not the author and date off their columns.
    var lead = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .gravity_y = 0.5,
        .background = false,
        .padding = dvui.Rect.all(0),
    });

    if (!lanes_drawn) _ = refTags(h, commit, row_index, 2, null);
    // Its stashes, before the message: the stash commits are not walked,
    // and the branch column would fold them into its "+N".
    for (h.stashes, 0..) |entry, i| {
        if (git.oidEql(entry.base, commit.id)) stashTag(entry, i, null);
    }
    // GitComet's message border: the line's colour, before the message.
    if (hue) |c| {
        var bar = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 3, .h = rh - 10 },
            .max_size_content = .size(.{ .w = 3, .h = rh - 10 }),
            .background = true,
            .color_fill = .{ .color = c },
            .corners = .all(1.5),
            .gravity_y = 0.5,
            .margin = .{ .w = 6 },
        });
        bar.deinit();
    }

    if (!lanes_drawn) avatar(@src(), 0, commit, null, null);

    // A box takes the message's share of the row first, so the text can be
    // cut to it — with an ellipsis, rather than chopped mid-letter.
    {
        var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .min_size_content = .{ .h = style.graphText().textHeight() },
            // Takes what is left, never asks for more: its text is cut to it,
            // so a long message cannot push the columns after it off the row.
            .max_size_content = .width(0),
            .background = false,
            .padding = dvui.Rect.all(0),
        });
        defer cell.deinit();
        var fit_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
        const font = style.graphText();
        const room = cell.data().contentRect().w;
        // What CI made of it, ahead of the message: a failed build is the
        // first thing anyone scanning the history needs to see.
        var sha_hex: [41]u8 = undefined;
        var ci_w: f32 = 0;
        if (pr.ciOf(git.oidHex(commit.id, &sha_hex)[0..40].*)) |ci| {
            const icon, const color, const hint = switch (ci) {
                .success => .{ dvui.entypo.check, style.success(), "ci_ok" },
                .failure => .{ dvui.entypo.cross, style.danger(), "ci_failed" },
                .pending => .{ dvui.entypo.dot_single, style.get().orange, "ci_running" },
            };
            dvui.icon(@src(), hint, icon, .{ .fill_color = .{ .color = color } }, .{
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .margin = .{ .w = style.space.xs },
            });
            ci_w = 12 + style.space.xs;
        }
        const summary = graph_view.fitText(&fit_buf, commit.summary, font, room - ci_w);
        dvui.label(@src(), "{s}", .{summary}, .{
            .font = font,
            .color_text = .{ .color = style.text() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
        // The body's first line in what the summary leaves, fainter: enough
        // to tell two "fix tests" apart without opening either.
        const gap = style.space.md;
        const left = room - ci_w - font.textSize(summary).w - gap;
        if (commit.body.len > 0 and left > 60) {
            var body_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
            const meta = style.graphMeta();
            dvui.label(@src(), "{s}", .{graph_view.fitText(&body_buf, commit.body, meta, left)}, .{
                .font = meta,
                .color_text = .{ .color = style.textFaint() },
                .gravity_y = 0.5,
                .margin = .{ .x = gap },
                .padding = dvui.Rect.all(0),
            });
        }

        // The whole message under the pointer: the row has room for its first
        // line, and a cut one ends in "…" mid-thought. Read only then, from
        // the repository — the history keeps one line of a body, not all.
        const cell_rect = cell.data().borderRectScale().r;
        if (hovered and cell_rect.contains(dvui.currentWindow().mouse_pt)) if (app.repo) |r| {
            const message = r.commitMessage(dvui.currentWindow().arena(), commit.id);
            if (message.len > 0) dvui.tooltip(@src(), .{ .active_rect = cell_rect, .position = .vertical, .delay = 600_000 }, "{s}", .{message}, .{
                .font = style.small(),
                .max_size_content = .width(520),
                .id_extra = row_index,
            });
        };
    }
    lead.deinit();

    const cols = graph_view.columnsShown();
    // Left, under the header's "AUTHOR": names read from their start.
    if (cols.author) _ = graph_view.listCell(@src(), 0, commit.author, style.graphMeta(), graph_view.col_author, .{ .x = style.space.md, .w = style.space.md }, true);
    var sha: [8]u8 = undefined;
    if (cols.sha) _ = graph_view.centerCell(@src(), 1, git.oidShort(commit.id, &sha), style.graphMono(), graph_view.col_sha, .{});
    // This week's commits by how long ago — "2 hours ago" is what anyone
    // works out from a timestamp anyway — older ones by the date; the exact
    // time either way under the pointer.
    var time_buf: [32]u8 = undefined;
    var exact_buf: [32]u8 = undefined;
    const exact = absoluteTime(&exact_buf, commit.time);
    const this_week = app.frame_now_s > 0 and app.frame_now_s - commit.time < 7 * 86400;
    const when = if (this_week) relativeTime(&time_buf, commit.time) else exact;
    const when_rect = graph_view.centerCell(@src(), 2, when, if (this_week) style.graphMeta() else style.graphMono(), graph_view.col_time, .{});
    if (this_week and hovered and when_rect.contains(dvui.currentWindow().mouse_pt)) {
        dvui.tooltip(@src(), .{ .active_rect = when_rect, .position = .vertical, .delay = 300_000 }, "{s}", .{exact}, .{
            .font = style.small(),
            .id_extra = row_index,
        });
    }

    // Read before `deinit`, which leaves the widget data undefined. The menu is
    // built after it, so it hangs off the scroll area rather than a dead row.
    const hit = dvui.clicked(row.data(), .{});
    const menu_rect = row.data().borderRectScale().r;
    row.deinit();

    commitMenu(@src(), commit, row_index, menu_rect);
    if (hit) app.selectCommit(commit.id);
}

/// What a commit can be the target of. Right-click, because the row has no room
/// for six buttons and a left click already means "show me the diff".
fn commitMenu(
    src: std.builtin.SourceLocation,
    commit: git.Commit,
    id: usize,
    rect: dvui.Rect.Physical,
) void {
    const ctx = dvui.context(src, .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();

    const cp = ctx.activePoint() orelse return;

    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();

    // In full: seven characters stop naming one commit once a repository is
    // big enough, and git refuses an ambiguous one rather than guess.
    var sha_buf: [41]u8 = undefined;
    const sha = git.oidHex(commit.id, &sha_buf);

    // What a click on a commit is most often for, first: going there. The
    // branches on it by name; the commit itself last of the three, named for
    // what it does — it detaches HEAD.
    if (app.history) |h| for (h.refs, 0..) |ref, i| {
        if (ref.kind != .local or ref.head or !git.oidEql(ref.target, commit.id)) continue;
        const caption = std.fmt.allocPrint(dvui.currentWindow().arena(), "Check out {s}", .{ref.name}) catch continue;
        if (graph_view.menuIconAt(@src(), i, dvui.entypo.login, caption)) {
            fw.close();
            app.checkout(ref);
        }
    };
    if (graph_view.menuIcon(@src(), dvui.entypo.login, "Check out this commit (detaches HEAD)", false)) {
        fw.close();
        repo_io.request(&.{ "checkout", sha });
    }

    graph_view.menuSeparator(1);
    if (graph_view.menuIcon(@src(), dvui.entypo.flow_branch, "New branch here", false)) {
        fw.close();
        app.askName(.new_branch, sha);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.tag, "Tag this commit", false)) {
        fw.close();
        app.askName(.new_tag, sha);
    }

    graph_view.menuSeparator(2);
    if (!app.midOperation() and graph_view.menuIcon(@src(), dvui.entypo.flow_cascade, "Cherry-pick onto current branch", false)) {
        fw.close();
        // A merge, like a revert of one: its change is the diff against the
        // first parent, the branch it was merged into.
        if (commit.parents.len > 1) {
            repo_io.request(&.{ "cherry-pick", "-m", "1", sha });
        } else {
            repo_io.request(&.{ "cherry-pick", sha });
        }
    }
    if (!app.midOperation() and graph_view.menuIcon(@src(), dvui.entypo.ccw, "Revert", false)) {
        fw.close();
        // A merge has no single change to undo until one parent is named; the
        // first is the branch it was merged into, which is what "undo this
        // merge" means.
        if (commit.parents.len > 1) {
            repo_io.request(&.{ "revert", "--no-edit", "-m", "1", sha });
        } else {
            repo_io.request(&.{ "revert", "--no-edit", sha });
        }
    }
    if (!app.midOperation() and graph_view.menuIcon(@src(), dvui.entypo.shuffle, "Rebase from here, interactively", false)) {
        fw.close();
        // The clicked commit is replayed too, so the list starts at its parent.
        app.beginRebase(if (commit.parents.len > 0) commit.parents[0] else null);
    }
    // The three resets, one row: they differ only in what happens to the
    // changes, which is the choice the submenu asks for.
    if (dialog_views.menuSubRow(@src(), dvui.entypo.back_in_time, "Reset branch here")) |r| {
        var sub = dvui.floatingMenu(@src(), .{ .from = r }, .{
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.popover,
            .padding = dvui.Rect.all(style.space.xs),
            .min_size_content = .{ .w = 220 },
        });
        defer sub.deinit();
        if (graph_view.menuIcon(@src(), dvui.entypo.back, "Soft — keep changes staged", false)) {
            fw.close();
            repo_io.request(&.{ "reset", "--soft", sha });
        }
        if (graph_view.menuIcon(@src(), dvui.entypo.back, "Mixed — keep changes unstaged", false)) {
            fw.close();
            repo_io.request(&.{ "reset", "--mixed", sha });
        }
        if (graph_view.menuIcon(@src(), dvui.entypo.trash, "Hard — discard changes", true)) {
            fw.close();
            app.ask(.reset_hard, sha);
        }
    }

    graph_view.menuSeparator(3);
    if (graph_view.menuIcon(@src(), dvui.entypo.text_document, "Show diff", false)) {
        fw.close();
        app.selectCommit(commit.id);
    }
    if (app.history) |h| if (h.head_oid) |head_oid| {
        if (!git.oidEql(head_oid, commit.id) and graph_view.menuIcon(@src(), dvui.entypo.flow_parallel, "Compare with the checked-out commit", false)) {
            fw.close();
            var a: [8]u8 = undefined;
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}", .{git.oidShort(commit.id, &a)}) catch "";
            // The current one first, as the branch menu has it: what this
            // commit has that HEAD has not.
            app.startCompare(head_oid, commit.id, h.head orelse "HEAD", name);
        }
    };

    // Its author: theirs alone, or added to the authors shown, or taken off.
    graph_view.menuSeparator(5);
    {
        const arena = dvui.currentWindow().arena();
        const key = graph_view.authorKey(arena, commit.author, commit.email);
        if (graph_view.menuIcon(@src(), dvui.entypo.user, std.fmt.allocPrint(arena, "Only commits by {s}", .{commit.author}) catch "Only this author", false)) {
            fw.close();
            graph_view.onlyAuthor(key);
        }
        const picked = graph_view.keyPicked(key);
        if (graph_view.author_only.items.len > 0 and (!picked or graph_view.author_only.items.len > 1)) {
            if (graph_view.menuIcon(@src(), dvui.entypo.users, std.fmt.allocPrint(arena, "{s} {s} {s} the filter", .{ if (picked) "Take" else "Add", commit.author, if (picked) "off" else "to" }) catch "The filter", false)) {
                fw.close();
                graph_view.toggleAuthor(key);
            }
        }
    }

    graph_view.menuSeparator(4);
    if (graph_view.menuIcon(@src(), dvui.entypo.copy, "Copy the full sha", false)) {
        fw.close();
        var hex: [41]u8 = undefined;
        dvui.clipboardTextSet(git.oidHex(commit.id, &hex));
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.clipboard, "Copy the message", false)) {
        fw.close();
        dvui.clipboardTextSet(commit.summary);
    }
}

/// The author as a disc of initials, coloured by name, so one person's
/// commits read as one colour down the list before any name is read.
///
/// `at` is where its top-left goes on the graph's canvas, with the lane's
/// colour as a ring round it; null lays it out inline, for the list a search
/// leaves when the lanes are gone.
fn avatar(src: std.builtin.SourceLocation, id: usize, commit: git.Commit, at: ?dvui.Point, ring: ?dvui.Color) void {
    // Pictures off in the settings — in the graph only: a dot there.
    if (!tab_strip.show_avatars) return avatarDot(src, id, commit, at, ring, style.avatar);
    avatarSized(src, id, commit, at, ring, style.avatar);
}

/// How far from a commit's centre its node reaches: its picture's radius,
/// or its dot's with pictures off — where lines to it stop.
fn nodeRadius() f32 {
    return if (tab_strip.show_avatars) style.avatar / 2 else style.avatar * DOT_SCALE / 2;
}
/// A dot's size against a picture's.
const DOT_SCALE: f32 = 0.5;

/// A graph node with pictures off: a dot in the lane's colour or the
/// author's — no picture asked for, no initials.
fn avatarDot(src: std.builtin.SourceLocation, id: usize, commit: git.Commit, at: ?dvui.Point, ring: ?dvui.Color, d: f32) void {
    const name = commit.author;
    const dot = d * DOT_SCALE;
    var room = dvui.box(src, .{}, .{
        .id_extra = id,
        .rect = if (at) |p| dvui.Rect{ .x = p.x, .y = p.y, .w = d, .h = d } else null,
        .background = false,
        .min_size_content = .{ .w = d, .h = d },
        .max_size_content = .size(.{ .w = d, .h = d }),
        .gravity_y = 0.5,
        .margin = if (at == null) .{ .w = style.space.sm } else dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    defer room.deinit();
    var disc = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = .{ .color = ring orelse style.laneColor(std.hash.Wyhash.hash(0, name) % 6) },
        .corners = .all(dot / 2),
        .min_size_content = .{ .w = dot, .h = dot },
        .max_size_content = .size(.{ .w = dot, .h = dot }),
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    disc.deinit();
}

/// As `avatar`, `d` across: the commit pane's is bigger than a graph node.
pub fn avatarSized(src: std.builtin.SourceLocation, id: usize, commit: git.Commit, at: ?dvui.Point, ring: ?dvui.Color, d: f32) void {
    const name = commit.author;
    const rect: ?dvui.Rect = if (at) |p| .{ .x = p.x, .y = p.y, .w = d, .h = d } else null;
    const border: dvui.Rect = if (ring != null) dvui.Rect.all(1.5) else dvui.Rect.all(0);

    var disc = dvui.box(src, .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = style.laneColor(std.hash.Wyhash.hash(0, name) % 6) },
        .border = border,
        .color_border = .{ .color = ring orelse style.background() },
        .corners = .all(d / 2),
        .min_size_content = .{ .w = d, .h = d },
        .max_size_content = .size(.{ .w = d, .h = d }),
        .gravity_y = 0.5,
        .margin = if (at == null) .{ .w = style.space.sm } else dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    defer disc.deinit();

    // The picture, where there is one: clipped to the same disc by its corners.
    var hex: [41]u8 = undefined;
    // No commit to ask GitHub about — a co-author, or whoever commits here —
    // goes without a sha: asking with the commit's would answer with its
    // author's picture.
    const unborn = std.mem.allEqual(u8, std.mem.asBytes(&commit.id), 0);
    if (avatars.get(commit.email, if (unborn) "" else git.oidHex(commit.id, &hex))) |png| {
        _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = png, .name = "avatar" } }, .shrink = .both }, .{
            .expand = .both,
            // Half of what is left inside the ring: half the whole disc
            // overshoots the picture, and the corners stop being a circle.
            .corners = .all((d - 2 * border.x) / 2),
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .label = .{ .text = name },
        });
        return;
    }

    var buf: [8]u8 = undefined;
    const letters = initials(&buf, name);

    // Made smaller rather than cut: at a fractional display scale two wide
    // capitals, "DG", came out of a disc this size as "…".
    var font: dvui.Font = .find(.{ .family = style.UI_FAMILY, .size = 9.5 * d / style.avatar, .weight = .bold });
    const room = d - 2 * border.x - 2;
    const wide = font.textSize(letters).w;
    if (wide > room) font = font.withSize(font.size * room / wide);
    dvui.label(@src(), "{s}", .{letters}, .{
        .font = font,
        .color_text = .{ .color = style.background() },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// First letter of the first two words, whole UTF-8 sequences and upper-cased
/// where ASCII. "Ada Lovelace" -> "AL", "zig" -> "Z", "Élodie" -> "É".
pub fn initials(buf: *[8]u8, name: []const u8) []const u8 {
    var len: usize = 0;
    var words: usize = 0;
    var it = std.mem.tokenizeAny(u8, name, " \t.-_<>@");
    while (it.next()) |word| {
        if (words == 2) break;
        const n = std.unicode.utf8ByteSequenceLength(word[0]) catch 1;
        if (n > word.len or len + n > buf.len) break;
        for (word[0..n], 0..) |b, i| buf[len + i] = std.ascii.toUpper(b);
        len += n;
        words += 1;
    }
    if (len == 0) {
        buf[0] = '?';
        len = 1;
    }
    return buf[0..len];
}

test "initials take whole letters from the first two words" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("AL", initials(&buf, "Ada Lovelace"));
    try std.testing.expectEqualStrings("Z", initials(&buf, "zig"));
    try std.testing.expectEqualStrings("ÉD", initials(&buf, "Élodie Durand"));
    try std.testing.expectEqualStrings("?", initials(&buf, ""));
}

/// "+N" for the refs a row had no room for — a dropdown that lists every one
/// of them, so the third label is a click away rather than nowhere. Choosing
/// a branch checks it out, as double-clicking it in the sidebar would.
fn moreRefs(src: std.builtin.SourceLocation, commit: git.Commit, hidden: usize, row_index: usize) void {
    const h = app.history orelse return;
    var dd: dvui.DropdownWidget = undefined;
    dd.init(src, .{}, .{
        .id_extra = row_index,
        .gravity_y = 0.5,
        .background = false,
        .margin = .{ .w = style.space.sm },
        .padding = dvui.Rect.all(0),
        .corners = style.radius.tag,
    });

    {
        var face = dvui.box(@src(), .{}, .{
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.tag,
            .padding = .{ .x = style.space.xs, .w = style.space.xs },
        });
        defer face.deinit();
        dvui.label(@src(), "+{d}", .{hidden}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textMuted() },
            .padding = dvui.Rect.all(0),
        });
    }

    var chosen: ?git.Ref = null;
    if (dd.dropped()) {
        for (h.refs) |ref| {
            if (!git.oidEql(ref.target, commit.id)) continue;
            // The two already on the row are listed too: the menu is the
            // whole set, which is what someone opening it wants to read.
            const icon = switch (ref.kind) {
                .local => dvui.entypo.flow_branch,
                .remote => dvui.entypo.cloud,
                .tag => dvui.entypo.tag,
            };
            const hint: []const u8 = switch (ref.kind) {
                .local => if (ref.head) "current" else "check out",
                .remote => "check out",
                .tag => "tag",
            };
            if (dialog_views.dropChoice(&dd, icon, ref.name, hint) and ref.kind != .tag) chosen = ref;
        }
    }
    dd.deinit();

    if (chosen) |ref| app.checkout(ref);
}

/// Whether `ref` is a local branch and a remote branch of the same name, both
/// at the same commit — what "pushed, nothing new on either side" looks like.
pub fn sameOnRemote(h: git.History, ref: git.Ref) bool {
    if (ref.kind == .tag) return false;
    for (h.refs) |other| {
        if (other.kind == .tag or other.kind == ref.kind or !git.oidEql(other.target, ref.target)) continue;
        const local, const remote = if (ref.kind == .local) .{ ref, other } else .{ other, ref };
        if (std.mem.eql(u8, app.splitRemoteRef(remote.name).branch, local.name)) return true;
    }
    return false;
}

/// Whether `ref` has a tag of its own in the graph. Not when its eye put it
/// out of the graph — its commits may still be there, through another
/// branch, but its name is not. And not a remote branch whose local branch,
/// at the same commit, carries it with a cloud — unless that one is out and
/// the remote is not.
fn tagShown(h: git.History, ref: git.Ref) bool {
    if (graph_view.isHidden(ref.name) and !ref.head) return false;
    if (ref.kind != .remote) return true;
    for (h.refs) |other| {
        if (other.kind != .local or !git.oidEql(other.target, ref.target)) continue;
        if (std.mem.eql(u8, app.splitRemoteRef(ref.name).branch, other.name)) return graph_view.isHidden(other.name) and !other.head;
    }
    return true;
}

/// A branch or tag name on its commit. The branch checked out is filled in
/// its colour and bold, the one picked in "Branches:" outlined and bold —
/// the two Git Graph sets apart from the rest. `synced`, a cloud after the
/// name: the remote branch of that name is at the same commit.
/// The names on `commit`, `most` of them, then "+N" for the rest; whether
/// any was drawn. A branch and its remote copy at the same commit say one
/// thing: one tag, marked as on the remote too.
fn refTags(h: git.History, commit: git.Commit, row_index: usize, most: usize, lane: ?dvui.Color) bool {
    // Counted first: in the branch column the names share its width with the
    // "+N" after them, so how much each gets depends on how many there are.
    var count: usize = 0;
    for (h.refs) |ref| {
        if (!git.oidEql(ref.target, commit.id) or !tagShown(h, ref)) continue;
        count += 1;
    }

    const hidden = count -| most;
    const room: ?f32 = if (lane == null) null else (branchColumn() - style.space.sm - (if (hidden > 0) moreRefsWidth(hidden) else 0)) /
        @as(f32, @floatFromInt(@max(1, @min(count, most))));

    var drawn: usize = 0;
    for (h.refs, 0..) |ref, i| {
        if (drawn >= most) break;
        if (!git.oidEql(ref.target, commit.id) or !tagShown(h, ref)) continue;
        refTag(@src(), ref, i, ref.kind == .local and sameOnRemote(h, ref), true, lane, room);
        drawn += 1;
    }

    if (hidden > 0) moreRefs(@src(), commit, hidden, row_index);
    return drawn > 0;
}

/// A stash's tag in the graph, on the commit it was made on: its message,
/// outlined in purple. Its right-click is the sidebar row's menu.
fn stashTag(entry: git.Stash, i: usize, room: ?f32) void {
    const color = style.get().purple;
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = i,
        .tag = dialog_views.frameTag("stash_tag", entry.message),
        .background = true,
        .color_fill = .{ .color = style.tint(color) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = color },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer pill.deinit();
    dvui.icon(@src(), "stash_kind", dvui.entypo.archive, .{ .fill_color = .{ .color = color }, .stroke_color = null }, .{
        .min_size_content = .{ .w = 10, .h = 10 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    const name_room = if (room) |r| r - (3 * style.space.sm + 10 + style.space.xs + 2) else 140;
    var name_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
    // Past git's "On main: " or "WIP on main: ": the branch is the row's.
    const said = if (std.mem.indexOf(u8, entry.message, ": ")) |at| entry.message[at + 2 ..] else entry.message;
    dvui.label(@src(), "{s}", .{graph_view.fitText(&name_buf, said, style.small(), @max(name_room, 12))}, .{
        .font = style.small(),
        .color_text = .{ .color = color },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    const rect = pill.data().borderRectScale().r;
    if (rect.contains(dvui.currentWindow().mouse_pt)) {
        dvui.tooltip(@src(), .{ .active_rect = rect, .position = .vertical, .delay = 500_000 }, "Stash: {s}", .{entry.message}, .{ .font = style.small() });
    }
    app.stashMenu(entry, 1_000_000 + i, rect, null);
}

/// The "+N" after a commit's names, margin included.
fn moreRefsWidth(hidden: usize) f32 {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "+{d}", .{hidden}) catch "+";
    return style.space.sm + 2 + 2 * style.space.xs + style.tiny().textSize(text).w;
}

/// What a ref's tag shows besides its name, in width: the cloud, the
/// distance from its upstream, the request's number.
fn refExtrasWidth(ref: git.Ref, synced: bool) f32 {
    var buf: [24]u8 = undefined;
    var w: f32 = 0;
    if (synced) w += 11 + style.space.xs;
    for ([_]usize{ ref.tracking.ahead, ref.tracking.behind }) |n| {
        if (n > 0) w += style.space.xs + 9 + style.tiny().textSize(std.fmt.bufPrint(&buf, "{d}", .{n}) catch "").w;
    }
    if (requestFor(ref)) |req| w += style.space.xs + style.tinyBold().textSize(std.fmt.bufPrint(&buf, "#{d}", .{req.number}) catch "").w;
    return w;
}

/// `lane`: the colour of the graph line the ref's commit sits on. A branch
/// takes it, as GitKraken colours one, so a name is matched to its line at a
/// glance; a tag keeps its own. `room`: the width the whole tag may take, in
/// the branch column; null elsewhere, where a name is cut at 140.
pub fn refTag(src: std.builtin.SourceLocation, ref: git.Ref, id: usize, synced: bool, draggable: bool, lane: ?dvui.Color, room: ?f32) void {
    const color = switch (ref.kind) {
        .local => lane orelse style.accent(),
        .remote => lane orelse style.get().blue,
        .tag => style.get().yellow,
    };
    const picked = graph_view.hasName(graph_view.graph_only.items, ref.name);
    // On a lane's colour, filled: the ground's colour reads on it in either
    // theme, where white would wash out on the dark theme's light hues.
    const ink = if (!ref.head) color else if (lane != null and ref.kind != .tag) style.background() else style.textOnAccent();

    var pill = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        // The graph's, by name, so a test can find one to drag.
        .tag = if (draggable) dialog_views.frameTag("ref", ref.name) else null,
        .background = true,
        .color_fill = .{ .color = if (ref.head) color else style.tint(color) },
        .border = dvui.Rect.all(if (picked and !ref.head) 1 else 0),
        .color_border = .{ .color = color },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer pill.deinit();
    // Where the ref is, before its name, as GitKraken marks it: a laptop for
    // a local branch, a cloud for a remote one, a label for a tag.
    // No stroke colour: with dvui's white defaults for both, an icon is
    // tinted the theme's text colour, and white on the head's pill turns dark.
    const kind_icon = switch (ref.kind) {
        .local => dvui.entypo.laptop,
        .remote => dvui.entypo.cloud,
        .tag => dvui.entypo.tag,
    };
    dvui.icon(@src(), "ref_kind", kind_icon, .{ .fill_color = .{ .color = ink }, .stroke_color = null }, .{
        .min_size_content = .{ .w = 10, .h = 10 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    // In the branch column, as much of the name as the column leaves once
    // the tag's own parts are counted: its padding, icon, border and margin.
    const font = if (ref.head or picked) style.smallBold() else style.small();
    const name_room = if (room) |r| r - (3 * style.space.sm + 10 + style.space.xs + 2) - refExtrasWidth(ref, synced) else 140;
    var name_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
    dvui.label(@src(), "{s}", .{graph_view.fitText(&name_buf, ref.name, font, @max(name_room, 12))}, .{
        .font = font,
        .color_text = .{ .color = ink },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    if (synced) dvui.icon(@src(), "synced", dvui.entypo.cloud, .{ .fill_color = .{ .color = ink }, .stroke_color = null }, .{
        .min_size_content = .{ .w = 11, .h = 11 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.xs },
    });
    trackingMarks(ref.tracking, ink);
    requestBadge(ref, ink);
    const pill_rect = pill.data().borderRectScale().r;
    if (pill_rect.contains(dvui.currentWindow().mouse_pt)) refTooltip(ref, synced, pill_rect);
    if (draggable) {
        _ = graph_view.branchDrop(pill.data(), ref);
        tagDrag(pill.data(), ref);
    }
}

/// What a ref's tag stands for, in words: local, on a remote, or both.
fn refTooltip(ref: git.Ref, synced: bool, rect: dvui.Rect.Physical) void {
    const arena = dvui.currentWindow().arena();
    const text = switch (ref.kind) {
        .tag => std.fmt.allocPrint(arena, "Tag {s}", .{ref.name}),
        .remote => std.fmt.allocPrint(arena, "Remote branch {s}, on {s}", .{ ref.name, app.splitRemoteRef(ref.name).remote }),
        .local => if (synced)
            std.fmt.allocPrint(arena, "Local branch {s}, and {s} at the same commit", .{ ref.name, syncedRemote(ref) orelse "its remote" })
        else
            std.fmt.allocPrint(arena, "Local branch {s}, with no remote branch at this commit", .{ref.name}),
    } catch return;
    dvui.tooltip(@src(), .{ .active_rect = rect, .position = .vertical, .delay = 400_000 }, "{s}", .{text}, .{ .font = style.small() });
}

/// The remote branch of the same name as local `ref`, at its commit.
fn syncedRemote(ref: git.Ref) ?[]const u8 {
    const h = app.history orelse return null;
    for (h.refs) |other| {
        if (other.kind != .remote or !git.oidEql(other.target, ref.target)) continue;
        if (std.mem.eql(u8, app.splitRemoteRef(other.name).branch, ref.name)) return other.name;
    }
    return null;
}

/// A branch's tag in the graph, dragged as its row in the sidebar is: onto
/// another branch's tag or row, for the same merge-or-rebase bar. A press
/// that never moves is still a click on its commit. After the tag's own
/// children, so its request badge keeps its clicks.
fn tagDrag(wd: *dvui.WidgetData, ref: git.Ref) void {
    if (ref.kind == .tag) return;
    const rect = wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = rect })) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press => if (me.button.pointer()) {
                e.handle(@src(), wd);
                dvui.captureMouse(wd, e.num);
                dvui.dragPreStart(me.button, me.p, .{ .name = graph_view.DRAG_NAME });
                graph_view.drag_source.clearRetainingCapacity();
                graph_view.drag_source.appendSlice(app.gpa, ref.name) catch {};
            },
            // Moved far enough: the mouse goes, so the tags and rows it
            // crosses can take the drop.
            .motion => if (dvui.captured(wd.id) and dvui.dragging(me, graph_view.DRAG_NAME) != null) {
                dvui.captureMouse(null, e.num);
            },
            .release => if (me.button.pointer() and dvui.captured(wd.id)) {
                e.handle(@src(), wd);
                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
                app.selectCommit(ref.target);
            },
            else => {},
        }
    }
}

/// The open pull or merge request whose branch `ref` is, if there is one.
fn requestFor(ref: git.Ref) ?pr.Request {
    if (ref.kind == .tag) return null;
    const branch = if (ref.kind == .remote) app.splitRemoteRef(ref.name).branch else ref.name;
    for (pr.list) |req| {
        if (std.mem.eql(u8, req.branch, branch)) return req;
    }
    return null;
}

/// "#63" on a branch with a request open, in the colour of where its review
/// stands: green approved, red changes asked for, faint while a draft.
pub fn requestBadge(ref: git.Ref, ink: dvui.Color) void {
    const req = requestFor(ref) orelse return;
    const color = if (req.draft)
        style.textFaint()
    else if (std.mem.eql(u8, req.review, "APPROVED"))
        style.success()
    else if (std.mem.eql(u8, req.review, "CHANGES_REQUESTED"))
        style.danger()
    else
        ink;
    // A click opens it, in the requests' view. No tag: the same request's
    // badge is on its branch in the graph and in the sidebar, and on the
    // local branch and its remote copy, and dvui flags a tag used twice.
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .gravity_y = 0.5,
        .background = false,
        .margin = .{ .x = style.space.xs },
        .padding = dvui.Rect.all(0),
    });
    bw.processEvents();
    dvui.label(@src(), "#{d}", .{req.number}, .{
        .font = style.tinyBold(),
        .color_text = .{ .color = color },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    if (bw.hovered()) {
        dvui.cursorSet(.hand);
        dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r, .position = .vertical, .delay = 400_000 }, "Open #{d}: {s}", .{ req.number, req.title }, .{ .font = style.small(), .max_size_content = .width(360) });
    }
    const clicked = bw.clicked();
    bw.deinit();
    if (clicked) {
        app.active_view = .pulls;
        app.pr_filter = .open;
        app.selectRequest(req.number);
    }
}

/// Whether `id` is one of the commits of the request picked, as last read.
fn inPickedRequest(id: git.Oid) bool {
    const d = pr.detail orelse return false;
    if (app.pr_selected == null or d.commits.len == 0) return false;
    var hex: [41]u8 = undefined;
    const sha = git.oidHex(id, &hex);
    for (d.commits) |c| if (std.mem.eql(u8, c.oid, sha)) return true;
    return false;
}

/// "↑2 ↓1" for a branch's distance from its upstream, nothing when level.
/// Icons rather than arrow characters: the fonts are cut down to what the
/// UI already used.
pub fn trackingMarks(t: git.Tracking, ink: dvui.Color) void {
    for ([_]struct { usize, []const u8, []const u8 }{ .{ t.ahead, dvui.entypo.arrow_up, "ahead" }, .{ t.behind, dvui.entypo.arrow_down, "behind" } }, 0..) |mark, i| {
        if (mark[0] > 0) {
            dvui.icon(@src(), mark[2], mark[1], .{ .fill_color = .{ .color = ink }, .stroke_color = null }, .{
                .id_extra = i,
                .min_size_content = .{ .w = 9, .h = 9 },
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.xs },
            });
            dvui.label(@src(), "{d}", .{mark[0]}, .{
                .id_extra = i,
                .font = style.tiny(),
                .color_text = .{ .color = ink },
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(0),
            });
        }
    }
}

/// How wide the graph column is: as wide as the history's lanes need, up to
/// a share of the list — so a repository with a dozen branches open at once
/// gets a dozen lanes side by side instead of a pile on the column's edge.
pub fn graphColumn() f32 {
    if (graph_width > 0) return graph_width;
    return graphColumnAuto();
}

/// The graph column as dragged in its header; 0 for as wide as its lanes
/// need. Narrower than `GRAPH_COMPACT_BELOW`, it is the compact graph.
pub var graph_width: f32 = 0;
pub const GRAPH_MIN_W: f32 = 40;
pub const GRAPH_MAX_W: f32 = 600;
const GRAPH_COMPACT_BELOW: f32 = 70;
const GRAPH_COMPACT_W: f32 = 48;

pub var graph_width_drag: f32 = 0;

/// GitKraken's narrow graph: no lines, each commit its author's picture
/// ringed in its branch's colour, and a bar of that colour beside it.
fn graphCompact() bool {
    return graph_width > 0 and graph_width < GRAPH_COMPACT_BELOW;
}

fn graphColumnAuto() f32 {
    const need = 2 * style.graph.inset + @as(f32, @floatFromInt(@max(laneCount(), 1) - 1)) * style.graph.lane_w;
    return std.math.clamp(need, 2 * style.graph.inset + style.avatar / 2, graphColumnMax());
}

/// The most the graph may take: a third of the list — past that the
/// message column is what pays — and never less than 120.
fn graphColumnMax() f32 {
    return @max(120, app.graph_scroll.viewport.w * 0.35);
}

/// The distance between two lanes: the full step while they fit, closer
/// together once they would not — every lane keeps its own line.
fn laneStep() f32 {
    const n = laneCount();
    if (n <= 1) return style.graph.lane_w;
    const room = (if (graph_width > 0) graphColumn() else graphColumnMax()) - 2 * style.graph.inset;
    return @max(9, @min(style.graph.lane_w, room / @as(f32, @floatFromInt(n - 1))));
}

fn laneCount() usize {
    const l = app.lanes orelse return 1;
    return l.lane_count;
}

pub fn drawLanes(
    src: std.builtin.SourceLocation,
    first: usize,
    last: usize,
    extra: usize,
    rh: f32,
) void {
    const l = app.lanes orelse return;

    var canvas = dvui.box(src, .{}, .{
        .rect = .{
            .x = style.space.lg + branchColumn(),
            .y = 0,
            .w = graphColumn(),
            .h = app.graph_scroll.virtual_size.h,
        },
        .background = false,
    });
    defer canvas.deinit();

    const rs = canvas.data().rectScale();

    // The uncommitted changes' node to HEAD's: dots down HEAD's lane, in its
    // colour, as GitKraken joins its work in progress to the commit under it.
    if (extra > 0) if (headLane()) |hl| {
        const x = laneX(hl.lane);
        const top = @max(0.5 * rh + style.avatar / 2 + 2, @as(f32, @floatFromInt(first)) * rh);
        const bottom = @min((@as(f32, @floatFromInt(hl.index + extra)) + 0.5) * rh - nodeRadius() - 2, @as(f32, @floatFromInt(last)) * rh);
        var y = top;
        while (y + 2 <= bottom) : (y += 5) {
            rs.rectToPhysical(.{ .x = x - 1, .y = y, .w = 2, .h = 2 }).fill(.{}, .{ .color = .{ .color = hl.color }, .fade = 0 });
        }
    };

    if (graphCompact()) {
        const h = app.history orelse return;
        for (first..last) |row_index| {
            if (row_index < extra) continue;
            const i = row_index - extra;
            if (i >= l.rows.len or i >= h.commits.len) continue;
            const color = style.laneColor(l.rows[i].color);
            const y = (@as(f32, @floatFromInt(row_index)) + 0.5) * rh;
            const r = style.avatar / 2;
            // The branch's colour down the row's height, right of the picture.
            const bar = rs.rectToPhysical(.{ .x = style.graph.inset + r + 5, .y = y - rh / 2 + 1, .w = 3, .h = rh - 2 });
            bar.fill(.{}, .{ .color = .{ .color = color }, .fade = 0 });
            avatar(@src(), row_index, h.commits[i], .{ .x = style.graph.inset - r, .y = y - r }, color);
        }
        return;
    }

    // The branch of the commit picked: its line full strength, every other
    // one receding, as GitKraken and GitComet show which line you are on.
    const focus: ?u16 = switch (app.selection) {
        .commit => |id| if (app.history) |h| if (h.indexOf(id)) |at| (if (at < l.rows.len) l.rows[at].color else null) else null else null,
        else => null,
    };
    const ink = struct {
        fn of(lane_color: u16, focused: ?u16) dvui.Color {
            const c = style.laneColor(lane_color);
            const f = focused orelse return c;
            return if (f == lane_color) c else c.lerp(style.background(), 0.6);
        }
    }.of;

    for (first..last) |row_index| {
        if (row_index < extra) continue;
        const i = row_index - extra;
        if (i >= l.rows.len) continue;

        const row = l.rows[i];
        const y = (@as(f32, @floatFromInt(row_index)) + 0.5) * rh;
        const y_next = y + rh;

        // As GitComet strokes them: a whole, even number of the screen's
        // pixels wide, each lane and each row's middle on a pixel's edge, so
        // a lane is two crisp pixels rather than a blur across three.
        const thickness = @max(2, @round(style.graph.line_w * rs.s / 2) * 2);
        const Y = @round(rs.r.y + y * rs.s);
        const Yn = @round(rs.r.y + y_next * rs.s);
        const next_lane: ?u16 = if (i + 1 < l.rows.len) l.rows[i + 1].lane else null;

        for (l.links[row.link_start..row.link_end]) |link| {
            const color = ink(link.color_lane, focus);
            const X0 = @round(rs.r.x + laneX(link.from) * rs.s);
            const X1 = @round(rs.r.x + laneX(link.to) * rs.s);

            var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
            defer path.deinit();

            path.addPoint(.{ .x = X0, .y = Y });
            const sx: f32 = if (X1 > X0) 1 else -1;
            // GitComet's elbows: one quarter circle of `corner` radius, as a
            // cubic, between a run down a lane and a run across at a
            // commit's own height — a line meets a node at its middle or
            // straight down into it, never beside it.
            const r = @min(style.graph.corner * rs.s, @abs(X1 - X0), (Yn - Y) / 2);
            const k: f32 = 0.5522847;
            const steps = 8;
            switch (linkShape(link, row.lane, next_lane)) {
                .straight => {},
                .across_then_down => {
                    const turn = X1 - sx * r;
                    path.addPoint(.{ .x = turn, .y = Y });
                    for (1..steps + 1) |n| {
                        const t = @as(f32, @floatFromInt(n)) / steps;
                        const q = bezier(.{ .x = turn, .y = Y }, .{ .x = turn + sx * r * k, .y = Y }, .{ .x = X1, .y = Y + r * (1 - k) }, .{ .x = X1, .y = Y + r }, t);
                        path.addPoint(.{ .x = q.x, .y = q.y });
                    }
                },
                .down_then_across => {
                    path.addPoint(.{ .x = X0, .y = Yn - r });
                    for (1..steps + 1) |n| {
                        const t = @as(f32, @floatFromInt(n)) / steps;
                        const q = bezier(.{ .x = X0, .y = Yn - r }, .{ .x = X0, .y = Yn - r * (1 - k) }, .{ .x = X0 + sx * r * k, .y = Yn }, .{ .x = X0 + sx * r, .y = Yn }, t);
                        path.addPoint(.{ .x = q.x, .y = q.y });
                    }
                },
                .slide => {
                    // A lane sliding over as one to its left ends: a soft S
                    // across the whole row — half an ease, half a slope, so
                    // one slide reads as a curve and slides on row after row
                    // as an even slope, not as stairs or as waves.
                    for (1..steps) |n| {
                        const t = @as(f32, @floatFromInt(n)) / steps;
                        const e = 0.5 * t + 0.5 * t * t * (3 - 2 * t);
                        path.addPoint(.{ .x = X0 + (X1 - X0) * e, .y = Y + (Yn - Y) * t });
                    }
                },
            }
            path.addPoint(.{ .x = X1, .y = Yn });

            path.build().stroke(.{
                .thickness = thickness,
                .color = .{ .color = color },
            });
        }

        // The commit's own node, drawn last so lines pass under it: its
        // author, ringed in the lane's colour, the way GitKraken marks one. A
        // merge is a small ring instead: on a history of merges, a picture on
        // every one buries the commits that hold the work.
        if (app.history) |h| {
            if (i < h.commits.len) {
                const commit = h.commits[i];
                if (commit.parents.len > 1) {
                    // As GitComet draws one: the node's size, ringed in the
                    // lane's colour over a faint wash of it, the merge glyph
                    // in the middle.
                    const d = style.avatar;
                    const hue = ink(row.color, focus);
                    var disc = dvui.box(@src(), .{}, .{
                        .id_extra = row_index,
                        .rect = .{ .x = laneX(row.lane) - d / 2, .y = y - d / 2, .w = d, .h = d },
                        .background = true,
                        .color_fill = .{ .color = hue.lerp(style.background(), 0.88) },
                        .border = dvui.Rect.all(1.5),
                        .color_border = .{ .color = hue },
                        .corners = .all(d / 2),
                    });
                    dvui.icon(@src(), "merge_glyph", dvui.entypo.merge, .{ .fill_color = .{ .color = hue } }, .{
                        .min_size_content = .{ .w = 10, .h = 10 },
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                    });
                    disc.deinit();
                } else {
                    const r = style.avatar / 2;
                    avatar(@src(), row_index, commit, .{ .x = laneX(row.lane) - r, .y = y - r }, ink(row.color, focus));
                }
            }
        }
    }
}

/// The rule between the graph and the message, from the list's content edge:
/// in the gap after the deepest node, a little short of the text.
pub fn graphRuleX() f32 {
    return graphLead() - style.space.sm;
}

/// GitKraken's BRANCH / TAG column, left of the graph: a commit's branch
/// names, joined by a line to its node, rather than in front of its message.
pub fn branchColumn() f32 {
    return if (branch_width > 0) branch_width else BRANCH_DEFAULT_W;
}

/// The branch column as dragged in its header; 0 for its default.
pub var branch_width: f32 = 0;
pub var branch_width_drag: f32 = 0;
pub const BRANCH_DEFAULT_W: f32 = 160;
/// The branch menu's room at the end of the column's name.
pub const BRANCH_MENU_W: f32 = 34;
pub const BRANCH_MIN_W: f32 = 60;
pub const BRANCH_MAX_W: f32 = 400;

/// What comes before the message where the lanes are drawn: the branch
/// column, the graph, and the gap after it.
pub fn graphLead() f32 {
    return branchColumn() + graphColumn() + style.graph.gap;
}

/// Where lane `lane` runs, from the graph column's left edge.
fn laneX(lane: u16) f32 {
    const x = style.graph.inset + @as(f32, @floatFromInt(lane)) * laneStep();
    return @min(x, graphColumn() - style.graph.inset);
}

/// How a line from one row's lane to the next row's is drawn: GitComet's two
/// elbows, which meet a commit only at its own height or straight down into
/// it, and the slide of a lane moving over.
const LinkShape = enum {
    straight,
    /// Out of this row's commit — a merge to its other parent, or onto a
    /// line already there: across at its height, the corner, then down.
    across_then_down,
    /// Into the next row's commit beside it — a branch rejoining, a merge
    /// whose parent is the next commit: down its own column, the corner,
    /// then across into it at its height.
    down_then_across,
    slide,
};

fn linkShape(link: graph.Link, lane: u16, next_lane: ?u16) LinkShape {
    if (link.from == link.to) return .straight;
    const into_node = next_lane != null and link.to == next_lane.?;
    // Leftwards into the next commit, across at this one's height would run
    // above the next row's node and reach it beside its middle.
    if (link.from == lane and !(into_node and link.to < link.from)) return .across_then_down;
    if (link.joins or into_node) return .down_then_across;
    return .slide;
}

test "a line meets a commit at its height or straight down into it" {
    // A merge to its other parent on its right: across first, then down.
    try std.testing.expectEqual(LinkShape.across_then_down, linkShape(.{ .from = 0, .to = 1, .color_lane = 1 }, 0, 0));
    // A merge whose parent is the next commit, on its left: down its own
    // column, then into that commit at its middle — not across above it.
    try std.testing.expectEqual(LinkShape.down_then_across, linkShape(.{ .from = 1, .to = 0, .color_lane = 0 }, 1, 0));
    // A merge onto a line already there on its left, the next commit
    // elsewhere: across at the merge's height, then down that line.
    try std.testing.expectEqual(LinkShape.across_then_down, linkShape(.{ .from = 1, .to = 0, .color_lane = 0 }, 1, 1));
    // A branch rejoining the line it left, by the commit it left from.
    try std.testing.expectEqual(LinkShape.down_then_across, linkShape(.{ .from = 2, .to = 0, .color_lane = 0, .joins = true }, 1, 0));
    try std.testing.expectEqual(LinkShape.straight, linkShape(.{ .from = 1, .to = 1, .color_lane = 1 }, 0, 0));
    try std.testing.expectEqual(LinkShape.slide, linkShape(.{ .from = 2, .to = 1, .color_lane = 1 }, 0, 0));
}

fn bezier(p0: dvui.Point, p1: dvui.Point, p2: dvui.Point, p3: dvui.Point, t: f32) dvui.Point {
    const u = 1 - t;
    return .{
        .x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
        .y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y,
    };
}

/// The C library's broken-down time: only the fields every platform has, in
/// the order they all put them.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
};

/// `localtime`, which the Windows C runtime only exports as `_localtime64`.
/// Called from the UI thread alone, so its shared result is safe here.
const localtime = @extern(*const fn (*const i64) callconv(.c) ?*const Tm, .{
    .name = if (@import("builtin").os.tag == .windows) "_localtime64" else "localtime",
});

/// "2026-10-21 18:05", in this machine's time zone.
pub fn absoluteTime(buf: []u8, when: i64) []const u8 {
    const tm = localtime(&when) orelse return "";
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)), @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)),
    }) catch "";
}

/// "5 days ago". Coarse on purpose: the exact minute of a commit from last
/// spring is noise.
pub fn relativeTime(buf: []u8, when: i64) []const u8 {
    const d = app.frame_now_s - when;
    if (d < 0) return "in the future";
    if (d < 60) return "just now";

    const units = [_]struct { secs: i64, name: []const u8 }{
        .{ .secs = 60, .name = "minute" },
        .{ .secs = 3600, .name = "hour" },
        .{ .secs = 86400, .name = "day" },
        .{ .secs = 604800, .name = "week" },
        .{ .secs = 2592000, .name = "month" },
        .{ .secs = 31536000, .name = "year" },
    };

    var chosen = units[0];
    for (units) |u| {
        if (d >= u.secs) chosen = u;
    }

    const n = @divFloor(d, chosen.secs);
    return std.fmt.bufPrint(buf, "{d} {s}{s} ago", .{
        n,
        chosen.name,
        window_chrome.plural(n),
    }) catch "a while ago";
}
