const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const run = @import("../core/run.zig");
const pr = @import("../github/pr.zig");
const window_chrome = @import("window_chrome.zig");
const search_view = @import("search_view.zig");
const rebase_view = @import("rebase_view.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const repo_settings = @import("repo_settings.zig");
const github_actions = @import("../github/github_actions.zig");
const pr_list = @import("pr_list.zig");
const app = @import("../main.zig");

// === A request's conversation ===
//
// A timeline, as the host's own page has it: the description first, then
// every comment and review in the order they came, each on a line down the
// left with its author's picture; a review with nothing to say a single
// coloured line; a run of reviews from one person folded to its ends. The
// threads on lines of the diff after, then the answer, then the merge.

/// Runs of reviews unfolded, by where they start; for the request below.
pub var pr_runs_open: u128 = 0;
var pr_runs_for: u32 = 0;

/// One step of a conversation: a comment, or a review.
const Event = struct { note: pr.Note, review: bool };

pub fn requestConversation(d: pr.Detail) void {
    if (pr_runs_for != d.number) {
        pr_runs_for = d.number;
        pr_runs_open = 0;
        pr_cards.clearRetainingCapacity();
        pr_cards_all = null;
    }
    // How many conversations on lines of the diff are still open; Expand
    // all, Collapse all for a long conversation, where only the last few
    // are open to begin with.
    const many = d.comments.len + d.reviews.len > CARDS_OPEN_AT_END;
    const open_threads = app.openThreads(d);
    if (many or d.threads.len > 0) {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.sm } });
        defer bar.deinit();
        if (d.threads.len > 0) {
            const hue = if (open_threads > 0) style.get().yellow else style.success();
            dvui.icon(@src(), "threads_icon", if (open_threads > 0) dvui.entypo.chat else dvui.entypo.check, .{ .fill_color = .{ .color = hue } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .w = style.space.sm } });
            if (open_threads > 0) {
                dvui.label(@src(), "{d} open conversation{s}", .{ open_threads, window_chrome.plural(open_threads) }, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            } else {
                dvui.label(@src(), "Every conversation is resolved", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            }
            const settled = d.threads.len - open_threads;
            if (settled > 0) {
                dvui.label(@src(), "· {d} resolved", .{settled}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
                if (dialog_views.linkButtonTagged(@src(), if (pr_list.pr_threads_all) "Fold them" else "Open them", style.textMuted(), "pr:threads_all")) pr_list.pr_threads_all = !pr_list.pr_threads_all;
            }
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (many) {
            if (dialog_views.linkButtonTagged(@src(), "Expand all", style.textMuted(), "pr:expand_all")) {
                pr_cards.clearRetainingCapacity();
                pr_cards_all = true;
            }
            if (dialog_views.linkButtonTagged(@src(), "Collapse all", style.textMuted(), "pr:collapse_all")) {
                pr_cards.clearRetainingCapacity();
                pr_cards_all = false;
            }
        }
    }
    // Which threads a review has shown under it; the rest after the lot.
    const shown_threads = dvui.currentWindow().arena().alloc(bool, d.threads.len) catch return;
    @memset(shown_threads, false);
    var timeline = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
    {
        defer timeline.deinit();
        timelineCard(0, d.author, "opened this", d.created, "", if (d.body.len > 0) d.body else "", true, true);

        // Comments and reviews merged by time, then read in runs: three or
        // more in a row from one person fold to their first and last.
        const a = dvui.currentWindow().arena();
        var events: std.ArrayList(Event) = .empty;
        {
            var ri: usize = 0;
            var ci: usize = 0;
            while (ri < d.reviews.len or ci < d.comments.len) {
                const take_review = ci >= d.comments.len or (ri < d.reviews.len and std.mem.order(u8, d.reviews[ri].when, d.comments[ci].when) != .gt);
                if (take_review) {
                    const r = d.reviews[ri];
                    ri += 1;
                    // A bare "commented" review says nothing — unless it is
                    // what left comments on lines of the diff.
                    if (r.body.len == 0 and std.mem.eql(u8, r.state, "COMMENTED") and !app.reviewHasThreads(d, r.id)) continue;
                    events.append(a, .{ .note = r, .review = true }) catch break;
                } else {
                    events.append(a, .{ .note = d.comments[ci], .review = false }) catch break;
                    ci += 1;
                }
            }
        }
        var i: usize = 0;
        while (i < events.items.len) {
            var end = i + 1;
            // A review with a conversation still open is never folded away.
            while (end < events.items.len and std.mem.eql(u8, events.items[end].note.author, events.items[i].note.author) and !(events.items[end].review and app.reviewHasOpenThreads(d, events.items[end].note.id))) end += 1;
            const bit: u128 = @as(u128, 1) << @intCast(i % 128);
            const folded = end - i >= 3 and pr_runs_open & bit == 0;
            for (i..end) |k| {
                if (folded and k != i and k != end - 1) {
                    // Numbered apart from the events, whose ids are their index + 1.
                    if (k == i + 1 and foldedRun(50_000 + k, events.items[i].note.author, end - i - 2)) pr_runs_open |= bit;
                    continue;
                }
                const e = events.items[k];
                // A long conversation is read from its end: the last few open.
                const open = k + CARDS_OPEN_AT_END >= events.items.len;
                if (e.review) {
                    reviewEvent(k + 1, e.note, open, app.reviewHasThreads(d, e.note.id));
                    // Its conversations on lines of the diff, under it, as
                    // the host shows them.
                    for (d.threads, 0..) |t, ti| {
                        if (e.note.id.len == 0 or !std.mem.eql(u8, t.review, e.note.id)) continue;
                        shown_threads[ti] = true;
                        app.threadRow(ti, t, d, true);
                    }
                } else timelineCard(k + 1, e.note.author, "commented", pr.isoSeconds(e.note.when), "", e.note.body, false, open);
            }
            i = end;
        }
        // Those no review on the page opened: after it, on the rail.
        for (d.threads, 0..) |t, ti| if (!shown_threads[ti]) app.threadRow(ti, t, d, false);
    }

    requestComposer();
    requestMergeCard(d);
}

/// The cards of a conversation opened or folded by a click on their head,
/// by their id; the rest as `pr_cards_all` says, or open where they are
/// among the last few. For the request in `pr_runs_for`.
pub var pr_cards: std.AutoHashMapUnmanaged(usize, bool) = .empty;
pub var pr_cards_all: ?bool = null;
pub const CARDS_OPEN_AT_END = 3;
/// The sidebar beside it, and the width of pane it needs to be there.
pub const PR_SIDE_W: f32 = 220;
pub const PR_SIDE_FROM: f32 = 700;

/// GitHub's sidebar: who is asked to review and where each stands, who it
/// is assigned to, its labels — each head dropping the list to change it.
pub fn requestSidebar(d: pr.Detail) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = PR_SIDE_W },
        .max_size_content = .width(PR_SIDE_W),
        .background = false,
        .margin = .{ .x = style.space.xl },
    });
    defer col.deinit();

    sideHeading(.reviewers, d);
    if (d.reviewers.len == 0) sideNone(0, "No reviews yet");
    for (d.reviewers, 0..) |r, i| sideReviewer(i, r, d.number);
    sideRule(0);

    sideHeading(.assignees, d);
    if (d.assignees.len == 0) sideNone(1, "No one assigned");
    for (d.assignees, 0..) |login, i| {
        // Numbered past the reviewers, on the same column.
        var line = sidePerson(100 + i, login);
        line.deinit();
    }
    sideRule(1);

    sideHeading(.labels, d);
    if (d.labels.len == 0) sideNone(2, "None yet");
    if (d.labels.len > 0) {
        var wrap = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
        defer wrap.deinit();
        for (d.labels, 0..) |l, i| {
            var cell = dvui.box(@src(), .{}, .{ .id_extra = i, .background = false, .margin = .{ .y = 2, .h = 2 } });
            defer cell.deinit();
            app.tinyBadge(@src(), 0, l.name, pr_list.labelColor(l.color));
        }
    }
}

const SideKind = enum { reviewers, assignees, labels };

/// The list a sidebar section's picker works on while it is open: who, or
/// which labels, as on the request when it opened, each click since.
pub var side_list: std.ArrayList(u8) = .empty;

/// A sidebar section's head, GitHub's way: its name and a gear, the whole
/// line a button that drops the section's list. Each tick goes to GitHub at
/// once; the request is read again after.
fn sideHeading(kind: SideKind, d: pr.Detail) void {
    const id: usize = 10 + @as(usize, @backingInt(kind));
    const caption: []const u8 = switch (kind) {
        .reviewers => "Reviewers",
        .assignees => "Assignees",
        .labels => "Labels",
    };
    const editable = requestOpen(d);
    var button = window_chrome.DropButton.begin(@src(), .{
        .id_extra = id,
        .tag = dialog_views.frameTag("side", caption),
        .expand = .horizontal,
        .gravity_y = 0,
        .background = false,
        .color_fill_hover = .{ .color = style.rowHover() },
        .corners = style.radius.input,
        .margin = .{ .h = style.space.xs },
        .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
    });
    button.min_w = 260;
    {
        const lit = editable and (button.item.show_active or button.item.mouse_over);
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer line.deinit();
        dvui.label(@src(), "{s}", .{caption}, .{ .font = style.smallBold(), .color_text = .{ .color = if (lit) style.accent() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (editable) dvui.icon(@src(), "side_gear", dvui.entypo.cog, .{ .fill_color = .{ .color = if (lit) style.accent() else style.textFaint() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5 });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse {
        if (app.pick_open == id) app.pick_open = null;
        return;
    };
    if (!editable) return m.close();
    // Opened: the list as the request has it, and who can be asked read.
    if (app.pick_open != id) {
        app.pick_open = id;
        app.pick_filter.clearRetainingCapacity();
        side_list.clearRetainingCapacity();
        switch (kind) {
            .reviewers => for (d.reviewers) |r| app.listToggle(&side_list, r.login),
            .assignees => for (d.assignees) |login| app.listToggle(&side_list, login),
            .labels => for (d.labels) |l| app.listToggle(&side_list, l.name),
        }
        pr.loadMeta(app.repo_path.items);
    }

    const a = dvui.currentWindow().arena();
    var path: [512]u8 = undefined;
    switch (kind) {
        .reviewers => if (app.peopleRows(&side_list, true)) |login| {
            const body = std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{github_actions.jsonList(a, login)}) catch return;
            if (app.listHas(side_list.items, login))
                github_actions.requestApi("Asking for a review", "POST", github_actions.apiPath(&path, "/pulls/{d}/requested_reviewers", .{d.number}), body, .none)
            else
                github_actions.requestApi("Withdrawing a review", "DELETE", github_actions.apiPath(&path, "/pulls/{d}/requested_reviewers", .{d.number}), body, .none);
        },
        .assignees => if (app.peopleRows(&side_list, false)) |_| {
            const body = std.fmt.allocPrint(a, "{{\"assignees\":{s}}}", .{github_actions.jsonList(a, side_list.items)}) catch return;
            github_actions.requestApi("Assigning", "PATCH", github_actions.apiPath(&path, "/issues/{d}", .{d.number}), body, .none);
        },
        .labels => if (app.labelRows(&side_list)) |_| {
            const body = std.fmt.allocPrint(a, "{{\"labels\":{s}}}", .{app.jsonCommaList(a, side_list.items)}) catch return;
            github_actions.requestApi("Labelling", "PUT", github_actions.apiPath(&path, "/issues/{d}/labels", .{d.number}), body, .none);
        },
    }
}

fn sideNone(id: usize, text: []const u8) void {
    dvui.label(@src(), "{s}", .{text}, .{ .id_extra = id, .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2, .h = style.space.xs } });
}

fn sideRule(id: usize) void {
    var line = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .max_size_content = .height(1),
        .background = true,
        .color_fill = .{ .color = style.border() },
        .margin = .{ .y = style.space.md, .h = style.space.md },
    });
    line.deinit();
}

/// A reviewer: who, and where they stand, as an icon of its colour.
fn sideReviewer(id: usize, r: pr.Reviewer, number: u32) void {
    const icon: []const u8, const hue: dvui.Color = if (std.mem.eql(u8, r.state, "APPROVED"))
        .{ dvui.entypo.check, style.success() }
    else if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED"))
        .{ dvui.entypo.cross, style.danger() }
    else if (std.mem.eql(u8, r.state, "COMMENTED"))
        .{ dvui.entypo.chat, style.textMuted() }
    else
        .{ dvui.entypo.dot_single, style.get().orange };
    var line = sidePerson(id, r.login);
    defer line.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    // One who has answered can be asked again, once the changes are made.
    if (!std.mem.eql(u8, r.state, "REQUESTED")) {
        const a = dvui.currentWindow().arena();
        const hint = std.fmt.allocPrint(a, "Ask {s} for a review again", .{r.login}) catch "Ask for a review again";
        if (dialog_views.iconButtonTagged(@src(), "rerequest", hint, dvui.entypo.cycle, style.textFaint(), dialog_views.frameTag("pr:rerequest", r.login))) {
            var path: [512]u8 = undefined;
            github_actions.requestApi("Asking for a review", "POST", github_actions.apiPath(&path, "/pulls/{d}/requested_reviewers", .{number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{github_actions.jsonList(a, r.login)}) catch return, .none);
        }
    }
    dvui.icon(@src(), "review_state", icon, .{ .fill_color = .{ .color = hue } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5 });
}

/// A person on a line of the sidebar: their picture and login. The line
/// is left open for what follows on it.
fn sidePerson(id: usize, login: []const u8) *dvui.BoxWidget {
    const line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .background = false, .margin = .{ .y = 3, .h = 3 } });
    search_view.avatarSized(@src(), 0, pr_list.requestAuthor(login), null, null, 20);
    dvui.label(@src(), "{s}", .{login}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    return line;
}

pub fn cardOpen(id: usize, default: bool) bool {
    return pr_cards.get(id) orelse pr_cards_all orelse default;
}

/// One step of the timeline: the rail on the left with `marker` drawn on
/// it, `content` to its right. Returns the box to fill; `end` closes both.
pub const TimelineRow = struct {
    row: *dvui.BoxWidget,
    body: *dvui.BoxWidget,

    pub fn begin(id: usize) TimelineRow {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .background = false });
        return .{ .row = row, .body = undefined };
    }

    /// The rail's column: what sits on it, then the line on down.
    pub fn rail(self: *TimelineRow, marker: anytype, arg: anytype) void {
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 36 }, .max_size_content = .width(36), .expand = .vertical, .background = false });
            defer col.deinit();
            {
                // At the top of the column, level with the card's head.
                var top = dvui.box(@src(), .{}, .{ .gravity_x = 0.5, .background = false, .margin = .{ .y = 4, .h = 2 } });
                defer top.deinit();
                marker(arg);
            }
            var line = dvui.box(@src(), .{}, .{
                .gravity_x = 0.5,
                .expand = .vertical,
                .background = true,
                .color_fill = .{ .color = style.border() },
                .min_size_content = .{ .w = 2, .h = 8 },
                .max_size_content = .width(2),
            });
            line.deinit();
        }
        // Beside the rail's column, not in it: closed before this opens.
        self.body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .x = style.space.sm, .h = style.space.lg } });
    }

    pub fn end(self: TimelineRow) void {
        self.body.deinit();
        self.row.deinit();
    }
};

fn railAvatar(login: []const u8) void {
    search_view.avatarSized(@src(), 0, pr_list.requestAuthor(login), null, null, RAIL_DOT);
}

/// What sits on the timeline's rail — a picture, an icon on a disc — all
/// one size, so the rail reads as one line of marks.
pub const RAIL_DOT: f32 = 24;

/// An icon on a disc of `hue`'s tint, for an event with no words.
pub const RailIcon = struct { icon: []const u8, hue: dvui.Color };

pub fn railIcon(arg: RailIcon) void {
    var disc = dvui.box(@src(), .{}, .{
        .gravity_x = 0.5,
        .background = true,
        .color_fill = .{ .color = style.tint(arg.hue) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = arg.hue.opacity(0.5) },
        .corners = .all(RAIL_DOT / 2),
        .min_size_content = .{ .w = RAIL_DOT, .h = RAIL_DOT },
        .max_size_content = .size(.{ .w = RAIL_DOT, .h = RAIL_DOT }),
        .padding = dvui.Rect.all(0),
    });
    defer disc.deinit();
    dvui.icon(@src(), "rail_icon", arg.icon, .{ .fill_color = .{ .color = arg.hue } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_x = 0.5, .gravity_y = 0.5 });
}

/// The verdict a review gave, as an icon, a colour and the words for it.
fn verdictOf(state: []const u8) struct { icon: []const u8, hue: dvui.Color, words: []const u8 } {
    if (std.mem.eql(u8, state, "APPROVED")) return .{ .icon = dvui.entypo.check, .hue = style.success(), .words = "approved these changes" };
    if (std.mem.eql(u8, state, "CHANGES_REQUESTED")) return .{ .icon = dvui.entypo.cross, .hue = style.danger(), .words = "requested changes" };
    if (std.mem.eql(u8, state, "DISMISSED")) return .{ .icon = dvui.entypo.block, .hue = style.textFaint(), .words = "had a review dismissed" };
    return .{ .icon = dvui.entypo.eye, .hue = style.textMuted(), .words = "reviewed" };
}

/// A comment, or the description: the author's picture on the rail, a card
/// with who, what and when on its head and the words under it.
fn timelineCard(id: usize, author: []const u8, what: []const u8, when: i64, verdict: []const u8, body: []const u8, first: bool, default_open: bool) void {
    var row = TimelineRow.begin(id);
    row.rail(railAvatar, author);
    defer row.end();
    const accent: ?dvui.Color = if (verdict.len > 0) verdictOf(verdict).hue else null;
    const open = cardOpen(id, default_open);
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = if (accent) |h| h.opacity(0.6) else if (first) style.accent().opacity(0.35) else style.borderSubtle() },
        .corners = style.radius.row,
    });
    defer card.deinit();
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (first) style.accentDim() else style.surfaceRaised() },
            .border = .{ .h = if (open) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .corners = if (open) .{ .tl = style.radius.row.tl, .tr = style.radius.row.tr } else style.radius.row,
            .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        defer head.deinit();
        // An accordion's head: the chevron says which way it is.
        dvui.icon(@src(), "card_fold", if (open) dvui.entypo.chevron_small_down else dvui.entypo.chevron_small_right, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.xs },
        });
        dvui.label(@src(), "{s}", .{author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        const words = if (verdict.len > 0) verdictOf(verdict).words else what;
        dvui.label(@src(), "{s}", .{words}, .{ .font = style.small(), .color_text = .{ .color = accent orelse style.textMuted() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        // Folded, the first line of what it says, so a long thread can be
        // skimmed without opening each one.
        if (!open and body.len > 0) {
            dvui.label(@src(), "{s}", .{previewLine(body)}, .{
                .font = style.small(),
                .color_text = .{ .color = style.textFaint() },
                .gravity_y = 0.5,
                .expand = .horizontal,
                .max_size_content = .width(0),
                .margin = .{ .x = style.space.xs, .w = style.space.sm },
                .padding = dvui.Rect.all(0),
            });
        } else _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (when > 0) {
            var buf: [32]u8 = undefined;
            dvui.label(@src(), "{s}", .{search_view.relativeTime(&buf, when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
        if (head.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) dvui.cursorSet(.hand);
        if (dvui.clicked(head.data(), .{})) pr_cards.put(app.gpa, id, !open) catch {};
    }
    if (!open) return;
    var text = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.md } });
    defer text.deinit();
    if (body.len == 0) {
        dvui.label(@src(), "No description.", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
    } else markdownBody(body);
}

/// The first line of a comment worth reading, its Markdown marks left out:
/// what a folded card shows.
pub fn previewLine(body: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r#>*-_`");
        if (line.len > 0) return line;
    }
    return "";
}

/// A review: a card when it says something, one coloured line when it is
/// only a verdict.
fn reviewEvent(id: usize, r: pr.Note, open: bool, has_threads: bool) void {
    const when = pr.isoSeconds(r.when);
    const v = verdictOf(r.state);
    if (r.body.len > 0) return timelineCard(id, r.author, "", when, r.state, r.body, false, open);
    // A bare "commented" review has no words and no verdict: nothing to show
    // but the comments it left on lines, if any — "ann reviewed", over them.
    if (std.mem.eql(u8, r.state, "COMMENTED") and !has_threads) return;
    var row = TimelineRow.begin(id);
    row.rail(railIcon, RailIcon{ .icon = v.icon, .hue = v.hue });
    defer row.end();
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = 4 } });
    defer line.deinit();
    search_view.avatarSized(@src(), 0, pr_list.requestAuthor(r.author), null, null, 18);
    dvui.label(@src(), "{s}", .{r.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{v.words}, .{ .font = style.small(), .color_text = .{ .color = v.hue }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
    if (when > 0) {
        var buf: [32]u8 = undefined;
        dvui.label(@src(), "· {s}", .{search_view.relativeTime(&buf, when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs }, .padding = dvui.Rect.all(0) });
    }
}

/// The middle of a long run of one person's comments and reviews, folded: a
/// click shows them.
fn foldedRun(id: usize, author: []const u8, hidden: usize) bool {
    var row = TimelineRow.begin(id);
    row.rail(railIcon, RailIcon{ .icon = dvui.entypo.dots_three_horizontal, .hue = style.textFaint() });
    defer row.end();
    var buf: [96]u8 = undefined;
    return dialog_views.chipButton(@src(), dvui.entypo.chevron_small_down, std.fmt.bufPrint(&buf, "Show {d} more from {s}", .{ hidden, author }) catch "Show more", false);
}

/// A heading in a comment: this much over its text, not the same size.
const MD_HEADING_STEP: f32 = 2.5;

/// A comment's text, read the way the host would show it — enough of
/// Markdown to read: headings, lists, quotes, code blocks; `**` and `` ` ``
/// marks dropped rather than shown.
pub fn markdownBody(body: []const u8) void {
    markdownText(body, style.body());
}

/// As `markdownBody`, its text at `base`: a commit's message reads at the
/// panel's size, a comment at the page's.
pub fn markdownText(body: []const u8, base: dvui.Font) void {
    const a = dvui.currentWindow().arena();
    var code: ?*dvui.BoxWidget = null;
    defer if (code) |c| c.deinit();
    var it = std.mem.splitScalar(u8, body, '\n');
    var n: usize = 0;
    while (it.next()) |raw| : (n += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (code) |c| {
                c.deinit();
                code = null;
            } else code = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = n,
                .expand = .horizontal,
                .background = true,
                .color_fill = .{ .color = style.surfaceInput() },
                .border = dvui.Rect.all(1),
                .color_border = .{ .color = style.borderSubtle() },
                .corners = style.radius.input,
                .padding = dvui.Rect.all(style.space.sm),
                .margin = .{ .y = style.space.xs, .h = style.space.xs },
            });
            continue;
        }
        if (code != null) {
            dvui.label(@src(), "{s}", .{line}, .{ .id_extra = n, .font = style.mono(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
            continue;
        }
        if (trimmed.len == 0) {
            _ = dvui.spacer(@src(), .{ .id_extra = n, .min_size_content = .{ .h = style.space.sm } });
            continue;
        }
        const clean = plainInline(a, trimmed);
        if (trimmed[0] == '#') {
            const words = std.mem.trimStart(u8, clean, "# ");
            var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = n, .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0), .margin = .{ .y = style.space.xs } });
            tl.addText(words, .{ .font = style.bodyBold().withSize(base.size + MD_HEADING_STEP), .color_text = .{ .color = style.text() } });
            tl.deinit();
        } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "+ ")) {
            var item = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = n, .expand = .horizontal, .background = false, .margin = .{ .x = style.space.sm, .y = style.space.xs, .h = style.space.xs } });
            defer item.deinit();
            const checked = std.mem.startsWith(u8, trimmed[2..], "[x]") or std.mem.startsWith(u8, trimmed[2..], "[X]");
            const box_item = checked or std.mem.startsWith(u8, trimmed[2..], "[ ]");
            if (box_item) {
                // Drawn: Inter has no ☑ or ☐, and they came out blank.
                var tick = dvui.box(@src(), .{}, .{
                    .background = true,
                    .color_fill = .{ .color = if (checked) style.success() else style.surface() },
                    .border = dvui.Rect.all(1),
                    .color_border = .{ .color = if (checked) style.success() else style.textFaint() },
                    .corners = style.radius.tag,
                    .min_size_content = .{ .w = 12, .h = 12 },
                    .max_size_content = .size(.{ .w = 12, .h = 12 }),
                    .gravity_y = 0.5,
                    .margin = .{ .w = style.space.sm },
                });
                if (checked) dvui.icon(@src(), "md_tick", dvui.entypo.check, .{ .fill_color = .{ .color = style.textOnAccent() } }, .{ .min_size_content = .{ .w = 9, .h = 9 }, .gravity_x = 0.5, .gravity_y = 0.5 });
                tick.deinit();
            } else dvui.label(@src(), "•", .{}, .{ .font = base, .color_text = .{ .color = style.textMuted() }, .margin = .{ .w = style.space.sm }, .padding = dvui.Rect.all(0) });
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0) });
            const words = std.mem.trimStart(u8, trimmed[2..], " ");
            addInline(tl, if (box_item) std.mem.trimStart(u8, words, "[xX ] ") else words, base, style.text());
            tl.deinit();
        } else if (trimmed[0] == '>') {
            // Filled as the card under it: dvui fills a box with a border on
            // one side only, and in the theme's colour unless told.
            var quote = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = n, .expand = .horizontal, .background = true, .color_fill = .{ .color = style.surface() }, .border = .{ .x = 3 }, .color_border = .{ .color = style.border() }, .padding = .{ .x = style.space.sm }, .margin = .{ .y = 2, .h = 2 } });
            defer quote.deinit();
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0) });
            addInline(tl, std.mem.trimStart(u8, trimmed, "> "), base, style.textMuted());
            tl.deinit();
        } else {
            var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = n, .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0) });
            addInline(tl, trimmed, base, style.text());
            tl.deinit();
        }
    }
}

/// A line's words into `tl`: `` `code` `` in the mono face and the accent,
/// the rest without its `**` marks.
fn addInline(tl: *dvui.TextLayoutWidget, text: []const u8, base: dvui.Font, ink: dvui.Color) void {
    const a = dvui.currentWindow().arena();
    var parts = std.mem.splitScalar(u8, text, '`');
    var code = false;
    while (parts.next()) |part| : (code = !code) {
        if (part.len == 0) continue;
        if (code)
            tl.addText(part, .{ .font = style.mono().withSize(base.size - 0.5), .color_text = .{ .color = style.accent() } })
        else
            tl.addText(plainInline(a, part), .{ .font = base, .color_text = .{ .color = ink } });
    }
}

/// `**bold**`, `__bold__` and `` `code` `` without their marks.
pub fn plainInline(a: std.mem.Allocator, text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "*_`") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and ((text[i] == '*' and text[i + 1] == '*') or (text[i] == '_' and text[i + 1] == '_'))) {
            i += 2;
            continue;
        }
        if (text[i] == '`') {
            i += 1;
            continue;
        }
        out.append(a, text[i]) catch return text;
        i += 1;
    }
    return out.items;
}

/// The answer, at the end of the conversation: who is writing, the box, and
/// the three ways to send it.
fn requestComposer() void {
    var row = TimelineRow.begin(90000);
    row.rail(railAvatar, if (window_chrome.me_gh.items.len > 0) window_chrome.me_gh.items else "you");
    defer row.end();
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
        .padding = dvui.Rect.all(style.space.md),
    });
    defer card.deinit();
    dvui.label(@src(), "Your review", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .margin = .{ .h = style.space.sm }, .padding = dvui.Rect.all(0) });
    {
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_list.pr_comment, .allocator = app.gpa, .limit = 16384 } },
            .placeholder = "Leave a comment — Markdown reads as on the host",
            .multiline = true,
            .break_lines = true,
        }, identity_view.settingsInput().override(.{ .tag = "pr:comment", .min_size_content = .{ .h = 84 }, .margin = .{ .h = style.space.sm } }));
        te.deinit();
    }
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer line.deinit();
    const text = std.mem.trim(u8, pr_list.pr_comment.items, " \n\t");
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (dialog_views.dialogButton(@src(), "Comment", false) and text.len > 0) app.prAnswer(.comment);
    // GitHub refuses a review of your own request: only a comment there.
    const own = if (pr.detail) |d| window_chrome.me_gh.items.len > 0 and std.ascii.eqlIgnoreCase(d.author, window_chrome.me_gh.items) else false;
    if (own) return;
    if (dialog_views.dialogButton(@src(), "Request changes", false) and text.len > 0) app.prAnswer(.request_changes);
    if (dialog_views.dialogButton(@src(), "Approve", true)) app.prAnswer(.approve);
}

/// Merging, on a card of its own at the very end.
fn requestMergeCard(d: pr.Detail) void {
    if (!requestOpen(d)) return;
    var row = TimelineRow.begin(90001);
    row.rail(railIcon, RailIcon{ .icon = dvui.entypo.merge, .hue = style.accent() });
    defer row.end();
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
        .padding = dvui.Rect.all(style.space.md),
    });
    defer card.deinit();
    dvui.label(@src(), "Merge", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .margin = .{ .h = style.space.sm }, .padding = dvui.Rect.all(0) });
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer line.deinit();
    var methods = [_][]const u8{ "Merge commit", "Squash and merge", "Rebase and merge" };
    _ = dvui.dropdown(@src(), &methods, .{ .choice = &pr_list.pr_merge_method }, .{}, .{
        .min_size_content = .{ .w = 150 },
        .gravity_y = 0.5,
        .font = style.small(),
        .corners = style.radius.input,
    });
    if (repo_settings.toggle(@src(), pr_list.pr_delete_branch)) pr_list.pr_delete_branch = !pr_list.pr_delete_branch;
    dvui.label(@src(), "Delete the branch after", .{}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .padding = dvui.Rect.all(0),
    });
    var num: [12]u8 = undefined;
    if (dialog_views.dialogButton(@src(), "Close…", false)) github_actions.ask(.close_request, pr_list.requestNumber(&num));
    // Merged by the host itself once its checks and reviews allow.
    if (d.auto_merge) {
        if (dialog_views.dialogButton(@src(), "Cancel auto-merge", false)) requestOnRequest("Cancelling auto-merge", "disablePullRequestAutoMerge", d.id);
    } else if (dialog_views.dialogButton(@src(), "Auto-merge", false)) autoMerge(d);
    if (dialog_views.dialogButton(@src(), "Merge…", true)) github_actions.ask(.merge_request, pr_list.requestNumber(&num));
}

/// Which part of a request the pane shows under its head.
pub const PrTab = enum { conversation, commits, files, checks };
pub var pr_tab: PrTab = .conversation;

/// The request's head, above its tabs: where it stands as a pill, its title,
/// who wants what merged where, who reviews it, its labels, and a line on
/// what still stands between it and a merge.
pub fn requestHeader(d: pr.Detail, reload: *bool, people_inline: bool, inset: f32) void {
    // On the page's own ground: the title is what stands out, not its box.
    var head = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{ .x = inset, .y = style.space.xl, .w = inset, .h = style.space.sm },
    });
    defer head.deinit();

    // The state, the number, the title.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer line.deinit();
        const word: []const u8, const hue: dvui.Color = if (std.mem.eql(u8, d.state, "MERGED") or std.mem.eql(u8, d.state, "merged"))
            .{ "Merged", style.get().purple }
        else if (std.mem.eql(u8, d.state, "CLOSED") or std.mem.eql(u8, d.state, "closed"))
            .{ "Closed", style.danger() }
        else if (d.draft)
            .{ "Draft", style.textMuted() }
        else
            .{ "Open", style.success() };
        app.statePill(word, hue);
        dvui.label(@src(), "#{d}", .{d.number}, .{ .font = style.title().withSize(PR_TITLE_SIZE * style.ui_scale), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.md, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .padding = dvui.Rect.all(0) });
        tl.addText(d.title, .{ .font = style.title().withSize(PR_TITLE_SIZE * style.ui_scale), .color_text = .{ .color = style.text() } });
        tl.deinit();

        // What to do with it, short of answering it: icons at the end of
        // its title's line, each saying itself on hover.
        if (dialog_views.iconButtonTagged(@src(), "pr_checkout", "Check it out: switch to its branch, up to date", dvui.entypo.download, style.textMuted(), "pr:checkout")) github_actions.checkoutRequest(d.number, d.head, d.fork);
        if (dialog_views.iconButtonTagged(@src(), "pr_web", "Open it on GitHub", dvui.entypo.popup, style.textMuted(), "pr:web")) github_actions.openUrl(d.url);
        if (dialog_views.iconButtonTagged(@src(), "pr_edit", "Edit its title, description, reviewers and labels", dvui.entypo.pencil, style.textMuted(), "pr:edit")) app.openPrEdit(d);
        if (requestOpen(d) and !d.draft) {
            if (dialog_views.iconButtonTagged(@src(), "pr_draft", "Convert it back to a draft", dvui.entypo.back, style.textMuted(), "pr:draft")) requestOnRequest("Making a draft", "convertPullRequestToDraft", d.id);
        }
        // While it is read again, or an action on it is out, the dots and
        // what is being done instead of the refresh icon.
        if (pr.detailLoading() or github_actions.api_job != null) {
            rebase_view.loadingSpinner(@src());
            dvui.label(@src(), "{s}", .{if (github_actions.api_job != null and github_actions.api_label.len > 0) github_actions.api_label else "Reading"}, .{ .tag = "pr:busy", .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0), .margin = .{ .w = style.space.xs } });
        } else if (dialog_views.iconButtonTagged(@src(), "pr_refresh", "Read it again", dvui.entypo.cw, style.textMuted(), "pr:refresh")) reload.* = true;
    }
    // Who, from where into where, when; its size on the right.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.md } });
        defer line.deinit();
        search_view.avatarSized(@src(), 0, pr_list.requestAuthor(d.author), null, null, 20);
        dvui.label(@src(), "{s}", .{d.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "wants to merge", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
        app.branchChip(0, d.head);
        dvui.icon(@src(), "into", dvui.entypo.arrow_long_right, .{ .fill_color = .{ .color = style.textFaint() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs, .w = style.space.xs } });
        app.branchChip(1, d.base);
        if (d.created > 0) {
            var when: [32]u8 = undefined;
            dvui.label(@src(), "· opened {s}", .{search_view.relativeTime(&when, d.created)}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        pr_list.sizeMarks(d.additions, d.deletions);
        dvui.label(@src(), "{d} file{s}", .{ d.files, window_chrome.plural(d.files) }, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0), .margin = .{ .x = style.space.sm } });
    }
    // Reviewers, assignees, labels — here only where the sidebar has no room.
    if (people_inline and d.reviewers.len + d.assignees.len + d.labels.len > 0) {
        var line = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .margin = .{ .h = style.space.sm } });
        defer line.deinit();
        for (d.reviewers, 0..) |r, i| app.reviewerChip(i, r);
        for (d.assignees, 0..) |a, i| app.personChip(100 + i, a, "assigned");
        for (d.labels, 0..) |l, i| {
            var cell = dvui.box(@src(), .{}, .{ .id_extra = 200 + i, .background = false, .margin = .{ .y = 2, .h = 2 } });
            defer cell.deinit();
            app.tinyBadge(@src(), 0, l.name, pr_list.labelColor(l.color));
        }
    }
    app.mergeReadiness(d);
}

/// A request's title: the largest words on its page.
const PR_TITLE_SIZE: f32 = 18;

/// The request `number` as the list it was picked in has it.
pub fn listedRequest(number: u32) ?pr.Request {
    for (pr.list) |r| if (r.number == number) return r;
    for (pr.past) |r| if (r.number == number) return r;
    return null;
}

/// A request's head while the rest of it is read: what the list knew — its
/// state, number and title, who wants it merged from where into where.
pub fn loadingHeader(r: pr.Request) void {
    var head = dvui.box(@src(), .{ .dir = .vertical }, .{
        .tag = "pr:loading",
        .expand = .horizontal,
        .background = false,
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.xl, .h = style.space.md },
    });
    defer head.deinit();
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer line.deinit();
        if (r.draft) app.statePill("Draft", style.textMuted()) else app.statePill("Open", style.success());
        dvui.label(@src(), "#{d}", .{r.number}, .{ .font = style.title().withSize(PR_TITLE_SIZE), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.md, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .padding = dvui.Rect.all(0) });
        tl.addText(r.title, .{ .font = style.title().withSize(PR_TITLE_SIZE), .color_text = .{ .color = style.text() } });
        tl.deinit();
    }
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.md } });
    defer line.deinit();
    search_view.avatarSized(@src(), 0, pr_list.requestAuthor(r.author), null, null, 20);
    dvui.label(@src(), "{s}", .{r.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "wants to merge", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
    app.branchChip(0, r.branch);
    dvui.icon(@src(), "into", dvui.entypo.arrow_long_right, .{ .fill_color = .{ .color = style.textFaint() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs, .w = style.space.xs } });
    app.branchChip(1, r.base);
}

/// Ask GitHub to merge it once it can, by the method picked. Deleting its
/// branch after is the repository's own setting on GitHub, not the call's.
fn autoMerge(d: pr.Detail) void {
    if (!app.safeNodeId(d.id)) return;
    const method = ([_][]const u8{ "MERGE", "SQUASH", "REBASE" })[@min(pr_list.pr_merge_method, 2)];
    const v = std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"id\":\"{s}\",\"method\":\"{s}\"}}", .{ d.id, method }) catch return;
    github_actions.requestGraphql("Setting auto-merge", "mutation($id:ID!,$method:PullRequestMergeMethod!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:$method}){clientMutationId}}", v, .none);
}

/// One of GitHub's mutations that take a request's node id and nothing else.
pub fn requestOnRequest(label: []const u8, comptime mutation: []const u8, id: []const u8) void {
    if (!app.safeNodeId(id)) return;
    const v = std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"id\":\"{s}\"}}", .{id}) catch return;
    github_actions.requestGraphql(label, "mutation($id:ID!){" ++ mutation ++ "(input:{pullRequestId:$id}){clientMutationId}}", v, .none);
}

pub fn requestOpen(d: pr.Detail) bool {
    return std.ascii.eqlIgnoreCase(d.state, "OPEN") or std.ascii.eqlIgnoreCase(d.state, "opened") or d.state.len == 0;
}
