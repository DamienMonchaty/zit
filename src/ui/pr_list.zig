const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const pr = @import("../github/pr.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const search_view = @import("search_view.zig");
const rebase_view = @import("rebase_view.zig");
const commit_view = @import("commit_view.zig");
const dialog_views = @import("dialog_views.zig");
const repo_io = @import("../core/repo_io.zig");
const app = @import("../main.zig");

// === Pull requests ===
//
// The list on the left, the one picked on the right in full — what it
// changes, whether its checks pass, the conversation so far — and every
// answer to it from here: comment, approve, ask for changes, merge, close.
// Each answer is a call to GitHub's API (`requestApi`), after which the list
// and the request are read again.

var pr_split: f32 = 0.36;
pub var pr_selected: ?u32 = null;
pub var pr_comment: std.ArrayList(u8) = .empty;
/// The merge settings' dropdown: merge commit, squash, rebase. A `usize`
/// because that is what a dvui dropdown writes.
pub var pr_merge_method: usize = 1;
pub var pr_delete_branch: bool = true;

/// Resolved threads shown too, not only the open ones.
pub var pr_threads_all: bool = false;
/// The thread whose reply box is open — its node id — and what is in it.
pub var pr_reply_id: std.ArrayList(u8) = .empty;
pub var pr_reply: std.ArrayList(u8) = .empty;

pub fn selectRequest(number: u32) void {
    // A review written for one request is never sent to another.
    if (pr_selected != number) pr_comment.clearRetainingCapacity();
    pr_selected = number;
    pr_reply_id.clearRetainingCapacity();
    pr_reply.clearRetainingCapacity();
    pr.clearDetail();
    pr.loadDetail(app.repo_path.items, number);
}

pub fn requestNumber(buf: *[12]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{pr_selected orelse 0}) catch "0";
}

pub fn pullsView() void {
    if (pr.host == .none) {
        dialog_views.emptyState(@src(), "Pull requests show up for a repository on GitHub, once Zit is connected to it (Settings › GitHub).");
        return;
    }
    var split = dvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = 700,
        .split_ratio = &pr_split,
        .handle_size = 1,
        .draw_in_deinit = false,
    }, .{ .expand = .both, .background = false });
    defer split.deinit();

    if (split.showFirst()) requestList();
    if (split.showSecond()) requestDetail();
}

/// Which requests the list shows.
const PrFilter = enum { open, review, mine, drafts, merged, closed };
pub var pr_filter: PrFilter = .open;
const PrSort = enum { updated, created, size };
var pr_sort: PrSort = .updated;
pub var pr_search: std.ArrayList(u8) = .empty;

/// Asked to review by the person signed in to the host, and not answered.
fn waitsOnMe(entry: pr.Request) bool {
    if (window_chrome.me_gh.items.len == 0) return false;
    for (entry.reviewers) |r| if (std.ascii.eqlIgnoreCase(r, window_chrome.me_gh.items)) return true;
    return false;
}

pub fn requestsToReview() usize {
    var n: usize = 0;
    for (pr.list) |entry| n += @intFromBool(waitsOnMe(entry));
    return n;
}

/// Whether the list's tab and search let `entry` through.
pub fn requestShown(entry: pr.Request) bool {
    switch (pr_filter) {
        .open, .merged, .closed => {},
        .review => if (!waitsOnMe(entry)) return false,
        .mine => if (window_chrome.me_gh.items.len == 0 or !std.ascii.eqlIgnoreCase(entry.author, window_chrome.me_gh.items)) return false,
        .drafts => if (!entry.draft) return false,
    }
    const needle = std.mem.trim(u8, pr_search.items, " #");
    if (needle.len == 0) return true;
    var num: [12]u8 = undefined;
    const number = std.fmt.bufPrint(&num, "{d}", .{entry.number}) catch "";
    for ([_][]const u8{ entry.title, entry.author, entry.branch, number }) |field| {
        if (std.ascii.findIgnoreCase(field, needle) != null) return true;
    }
    return false;
}

fn requestList() void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
    });
    defer panel.deinit();
    window_chrome.loadMe();
    if (pr.pumpPast()) dvui.refresh(null, @src(), null);

    const source = requestSource();
    {
        var head = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.border() },
            .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.sm, .h = style.space.xs },
        });
        defer head.deinit();
        // The way back, said where the eye is, not only on the tab. On a row of
        // its own: a chip centres itself, and in this column it would sit
        // under the filters.
        {
            var top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.sm } });
            defer top.deinit();
            if (dialog_views.chipButton(@src(), dvui.entypo.chevron_left, "History — Esc", false)) app.closePulls();
            dvui.label(@src(), "Pull requests", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
        // The search, the order, and the two buttons.
        {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.xs } });
            defer line.deinit();
            {
                var cell = dvui.box(@src(), .{}, .{ .expand = .horizontal, .background = false });
                defer cell.deinit();
                _ = dialog_views.searchField(@src(), &pr_search, "Search title, #, author, branch…", "pr_search", dvui.Rect.all(0));
            }
            prFilterMenu();
            prSortMenu();
            if (dialog_views.iconButton(@src(), "pr_new", "Create one for this branch", dvui.entypo.plus, style.textMuted())) rebase_view.requestCreateRequest();
            if (dialog_views.iconButton(@src(), "pr_refresh", "Refresh", dvui.entypo.ccw, style.textMuted())) {
                repo_io.refreshRequests();
                if (pr_filter == .merged or pr_filter == .closed) pr.refreshPast(app.repo_path.items, if (pr_filter == .merged) .merged else .closed);
            }
        }
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();

    const status = if (pr_filter == .merged or pr_filter == .closed) pr.past_status else pr.status;
    switch (status) {
        .loading => if (source.len == 0) rebase_view.sidebarNote(@src(), "Loading…"),
        .failed => if (pr_filter == .merged or pr_filter == .closed) rebase_view.sidebarNote(@src(), "Could not list them.") else rebase_view.requestsError(),
        .ready, .idle => {},
    }
    // From the same list as `source`, read once: a filter clicked further
    // up this function switches `requestSource()` to the merged or closed
    // ones, and indexes from one list read out of the other ran past its end.
    const order = shownRequests(dvui.currentWindow().arena(), source);
    // None picked yet: the checked-out branch's own, else the first.
    if (pr_selected == null and order.len > 0) {
        const head = if (app.history) |h| h.head orelse "" else "";
        var pick = source[order[0]].number;
        for (order) |i| if (head.len > 0 and std.mem.eql(u8, source[i].branch, head)) {
            pick = source[i].number;
            break;
        };
        selectRequest(pick);
    }
    if (order.len == 0 and status == .ready) rebase_view.sidebarNote(@src(), switch (pr_filter) {
        .review => "Nothing waits on your review.",
        .mine => "None of yours open.",
        .drafts => "No drafts.",
        else => "None.",
    });
    for (order, 0..) |i, n| requestListRow(@src(), source[i], n);
}

/// The list the filter, the search and the sort leave, as indexes into
/// `source`, in `a`: what is drawn, and what ↑ and ↓ walk.
fn shownRequests(a: std.mem.Allocator, source: []const pr.Request) []u32 {
    var order: std.ArrayList(u32) = .empty;
    for (source, 0..) |entry, i| if (requestShown(entry)) order.append(a, @intCast(i)) catch break;
    const Cmp = struct {
        list: []const pr.Request,
        fn lt(ctx: @This(), x: u32, y: u32) bool {
            const l = ctx.list[x];
            const r = ctx.list[y];
            return switch (pr_sort) {
                .updated => l.updated > r.updated,
                .created => l.created > r.created,
                .size => l.additions + l.deletions > r.additions + r.deletions,
            };
        }
    };
    std.sort.pdq(u32, order.items, Cmp{ .list = source }, Cmp.lt);
    return order.items;
}

/// The open requests, or the merged and closed ones, as the filter says.
fn requestSource() []const pr.Request {
    return switch (pr_filter) {
        .merged, .closed => pr.past,
        else => pr.list,
    };
}

/// The request `delta` along the list from the one picked: ↑ and ↓.
pub fn stepRequest(delta: i2) void {
    const source = requestSource();
    const order = shownRequests(dvui.currentWindow().arena(), source);
    if (order.len == 0) return;
    var at: ?usize = null;
    if (pr_selected) |n| for (order, 0..) |i, k| if (source[i].number == n) {
        at = k;
        break;
    };
    const next = if (at) |k|
        (if (delta > 0) @min(k + 1, order.len - 1) else k -| 1)
    else
        0;
    selectRequest(source[order[next]].number);
}

/// Which requests the list shows, as a select beside the search: open,
/// waiting on your review, yours, drafts, merged, closed — each with how
/// many it holds, where that is known without asking.
fn prFilterMenu() void {
    var drafts: usize = 0;
    var mine: usize = 0;
    for (pr.list) |e| {
        drafts += @intFromBool(e.draft);
        mine += @intFromBool(window_chrome.me_gh.items.len > 0 and std.ascii.eqlIgnoreCase(e.author, window_chrome.me_gh.items));
    }
    const items = [_]struct { PrFilter, []const u8, ?usize }{
        .{ .open, "Open", pr.list.len },
        .{ .review, "To review", requestsToReview() },
        .{ .mine, "Mine", mine },
        .{ .drafts, "Drafts", drafts },
        .{ .merged, "Merged", null },
        .{ .closed, "Closed", null },
    };
    const current = for (items) |it| {
        if (it[0] == pr_filter) break it;
    } else items[0];

    const button = window_chrome.DropButton.begin(@src(), .{
        .tag = "pr:filter",
        .gravity_y = 0.5,
        .background = false,
        .color_fill_hover = .{ .color = style.rowHover() },
        .corners = style.radius.input,
        .margin = .{ .x = style.space.xs },
        .padding = dvui.Rect.all(0),
    });
    {
        const lit = button.item.show_active or button.item.mouse_over;
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .color_fill = .{ .color = if (lit) style.rowHover() else style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.md, .y = 5, .w = style.space.sm, .h = 5 },
        });
        defer face.deinit();
        dvui.label(@src(), "{s}", .{current[1]}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        if (current[2]) |n| commit_view.countPill(n);
        dvui.icon(@src(), "filter_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textMuted() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs } });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse return;
    for (items, 0..) |it, i| {
        var count_buf: [16]u8 = undefined;
        const count = if (it[2]) |n| std.fmt.bufPrint(&count_buf, "{d}", .{n}) catch "" else "";
        if (app.pickRow(i, it[1], count, pr_filter == it[0], null)) {
            pr_filter = it[0];
            if (it[0] == .merged or it[0] == .closed) pr.refreshPast(app.repo_path.items, if (it[0] == .merged) .merged else .closed);
            m.close();
            // The keys back to the list: the closed menu would keep ↑ and ↓.
            dvui.focusWidget(null, dvui.currentWindow().data().id, null);
        }
    }
}

/// The list's order, as a menu.
fn prSortMenu() void {
    const button = window_chrome.DropButton.begin(@src(), .{
        .tag = "pr_sort",
        .gravity_y = 0.5,
        .background = false,
        .corners = style.radius.input,
        .padding = .{ .x = 4, .y = 2, .w = 2, .h = 2 },
        .margin = .{ .x = style.space.xs },
    });
    {
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        defer face.deinit();
        dvui.icon(@src(), "sort_icon", dvui.entypo.list, .{ .fill_color = .{ .color = style.textMuted() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5 });
        dvui.icon(@src(), "sort_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textFaint() } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5 });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse return;
    dialog_views.dropHeading(@src(), 0, "SORT BY");
    for ([_]struct { PrSort, []const u8 }{ .{ .updated, "Recently updated" }, .{ .created, "Newest" }, .{ .size, "Largest change" } }, 0..) |it, i| {
        if (graph_view.menuIconAt(@src(), i, if (pr_sort == it[0]) dvui.entypo.check else dvui.entypo.dot_single, it[1])) {
            pr_sort = it[0];
            m.close();
        }
    }
}

/// A review verdict as a coloured word, or nothing where there is none.
fn reviewBadge(src: std.builtin.SourceLocation, id: usize, review: []const u8, draft: bool) void {
    const word: []const u8, const hue: dvui.Color = if (draft)
        .{ "Draft", style.textFaint() }
    else if (std.mem.eql(u8, review, "APPROVED"))
        .{ "Approved", style.success() }
    else if (std.mem.eql(u8, review, "CHANGES_REQUESTED"))
        .{ "Changes requested", style.danger() }
    else if (std.mem.eql(u8, review, "REVIEW_REQUIRED"))
        .{ "Review required", style.get().orange }
    else
        return;
    dvui.label(src, "{s}", .{word}, .{
        .id_extra = id,
        .font = style.tiny(),
        .color_text = .{ .color = hue },
        .background = true,
        .color_fill = .{ .color = style.tint(hue) },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .padding = .{ .x = style.space.xs, .w = style.space.xs },
        .margin = .{ .w = style.space.sm },
    });
}

fn requestListRow(src: std.builtin.SourceLocation, entry: pr.Request, id: usize) void {
    var tag_buf: [12]u8 = undefined;
    const selected = pr_selected != null and pr_selected.? == entry.number;
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .id_extra = id,
        .tag = dialog_views.frameTag("pr", std.fmt.bufPrint(&tag_buf, "{d}", .{entry.number}) catch ""),
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = if (selected) style.rowSelected() else style.background() },
        .color_fill_hover = .{ .color = if (selected) style.rowSelected() else style.rowHover() },
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.borderSubtle() },
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        .margin = dvui.Rect.all(0),
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer row.deinit();
    search_view.avatarSized(@src(), 0, requestAuthor(entry.author), null, null, 26);

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .x = style.space.xs } });
    defer col.deinit();
    {
        // The number, the title, and what CI made of its head.
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer line.deinit();
        dvui.label(@src(), "#{d}", .{entry.number}, .{
            .font = style.smallBold(),
            .color_text = .{ .color = if (entry.draft) style.textFaint() else style.accent() },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
            .padding = dvui.Rect.all(0),
        });
        var cell = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = style.small().textHeight() }, .background = false });
        var fit_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
        dvui.label(@src(), "{s}", .{graph_view.fitText(&fit_buf, entry.title, style.smallBold(), cell.data().contentRect().w)}, .{
            .font = style.smallBold(),
            .color_text = .{ .color = if (entry.draft) style.textMuted() else style.text() },
            .padding = dvui.Rect.all(0),
        });
        cell.deinit();
        if (entry.sha.len == 40) if (pr.ciOf(entry.sha[0..40].*)) |ci| {
            const icon, const color = switch (ci) {
                .success => .{ dvui.entypo.check, style.success() },
                .failure => .{ dvui.entypo.cross, style.danger() },
                .pending => .{ dvui.entypo.dot_single, style.get().orange },
            };
            dvui.icon(@src(), "pr_ci", icon, .{ .fill_color = .{ .color = color } }, .{
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.xs },
            });
        };
    }
    {
        // Where review stands, where it goes, its labels; its size and age
        // at the end.
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = 3 } });
        defer line.deinit();
        reviewBadge(@src(), 0, entry.review, entry.draft);
        if (entry.conflict) app.tinyBadge(@src(), 1, "conflict", style.danger());
        for (entry.labels[0..@min(entry.labels.len, 2)], 0..) |label, i| app.tinyBadge(@src(), 10 + i, label.name, labelColor(label.color));
        if (entry.labels.len > 2) dvui.label(@src(), "+{d}", .{entry.labels.len - 2}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "{s} → {s}", .{ entry.branch, entry.base }, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .margin = .{ .x = style.space.xs },
            .padding = dvui.Rect.all(0),
        });
        if (entry.additions + entry.deletions > 0) sizeMarks(entry.additions, entry.deletions);
        if (entry.updated > 0) {
            var when: [32]u8 = undefined;
            dvui.label(@src(), "{s}", .{search_view.relativeTime(&when, entry.updated)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
    }

    if (bw.clicked()) selectRequest(entry.number);
}

/// A request's author as a commit, for the avatar: on GitHub the login's own
/// noreply address, which is the account's picture without a commit to ask about.
pub fn requestAuthor(login: []const u8) git.Commit {
    const email = if (pr.host == .github)
        std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}@users.noreply.github.com", .{login}) catch ""
    else
        "";
    return .{ .id = std.mem.zeroes(git.Oid), .summary = "", .author = login, .email = email, .time = 0 };
}

/// A label's colour, from the host's hex; the accent where there is none.
pub fn labelColor(hex: []const u8) dvui.Color {
    if (hex.len != 6) return style.accent();
    const v = std.fmt.parseInt(u24, hex, 16) catch return style.accent();
    const c: dvui.Color = .{ .r = @intCast(v >> 16), .g = @intCast((v >> 8) & 0xff), .b = @intCast(v & 0xff) };
    // Labels are picked for GitHub's own pages: a pale one vanishes as text
    // on paper, a dark one on the dark ground. Pulled toward contrast.
    const lum = (0.299 * @as(f32, @floatFromInt(c.r)) + 0.587 * @as(f32, @floatFromInt(c.g)) + 0.114 * @as(f32, @floatFromInt(c.b))) / 255;
    if (!style.get().dark and lum > 0.55) return c.lerp(.black, 0.5);
    if (style.get().dark and lum < 0.35) return c.lerp(.white, 0.45);
    return c;
}

/// "+12 −3" in green and red, and a five-block bar of their proportion, as
/// GitHub draws a change's size.
pub fn sizeMarks(added: u32, removed: u32) void {
    var buf: [16]u8 = undefined;
    dvui.label(@src(), "+{d}", .{added}, .{ .font = style.tinyBold(), .color_text = .{ .color = style.success() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{std.fmt.bufPrint(&buf, "−{d}", .{removed}) catch ""}, .{ .font = style.tinyBold(), .color_text = .{ .color = style.danger() }, .gravity_y = 0.5, .margin = .{ .x = 3 }, .padding = dvui.Rect.all(0) });
    const total: f32 = @floatFromInt(added + removed);
    const green: usize = @intFromFloat(@round(5 * @as(f32, @floatFromInt(added)) / total));
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.xs } });
    defer bar.deinit();
    for (0..5) |i| {
        var block = dvui.box(@src(), .{}, .{
            .id_extra = i,
            .background = true,
            .color_fill = .{ .color = if (i < green) style.success() else style.danger() },
            .corners = .all(1),
            .min_size_content = .{ .w = 6, .h = 6 },
            .max_size_content = .size(.{ .w = 6, .h = 6 }),
            .margin = .{ .w = 1 },
            .padding = dvui.Rect.all(0),
        });
        block.deinit();
    }
}

fn requestDetail() void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .x = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer panel.deinit();

    const number = pr_selected orelse return dialog_views.emptyState(@src(), "Pick one on the left.");
    const d = pr.detail orelse {
        // Being read: its head at once, from the list it was picked in, and
        // the rest to come under it.
        if (pr.detail_status != .failed) if (app.listedRequest(number)) |r| app.loadingHeader(r);
        return dialog_views.emptyState(@src(), if (pr.detail_status == .failed) "Could not read it." else "Loading…");
    };
    // Read again where it is — the page stays up until the answer replaces
    // it, which frees what `d` points into: asked once the pane is drawn.
    var reload = false;
    defer if (reload) pr.loadDetail(app.repo_path.items, d.number);
    if (app.pr_reread_at != 0) {
        if (app.frame_now_s >= app.pr_reread_at) {
            app.pr_reread_at = 0;
            pr.loadDetail(app.repo_path.items, d.number);
        } else dvui.timer(panel.data().id, app.PR_REREAD_S * std.time.us_per_s);
    }

    // The whole pane, and where there is the room GitHub's sidebar on its
    // right: who reviews, who it is assigned to, its labels.
    const pane_w = panel.data().contentRect().w;
    const total = @max(320, pane_w - 2 * style.space.xl);
    const side = total >= app.PR_SIDE_FROM;
    const main_w = if (side) total - app.PR_SIDE_W - style.space.xl else total;
    // The head and its tabs a banner from one edge of the pane to the other,
    // what they hold set in as far as the page under them is.
    const inset = @max(style.space.sm, (pane_w - total) / 2);
    app.requestHeader(d, &reload, !side, inset);
    app.requestTabs(d, inset);

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = total },
            .max_size_content = .width(total),
            .background = false,
            .padding = .{ .y = style.space.xl, .h = style.space.xl },
        });
        defer row.deinit();
        {
            var body = dvui.box(@src(), .{ .dir = .vertical }, .{
                .min_size_content = .{ .w = main_w },
                .max_size_content = .width(main_w),
                .background = false,
            });
            defer body.deinit();

            switch (app.pr_tab) {
                .conversation => app.requestConversation(d),
                .commits => app.requestCommits(d),
                .files => app.requestFiles(d),
                .checks => app.requestChecks(d),
            }
        }
        if (side) app.requestSidebar(d);
    }
    scroll.deinit();
}
