const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const avatars = @import("../github/avatar.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const search_view = @import("search_view.zig");
const diff_view = @import("diff_view.zig");
const rebase_view = @import("rebase_view.zig");
const dialog_views = @import("dialog_views.zig");
const repo_settings = @import("repo_settings.zig");
const repo_io = @import("../core/repo_io.zig");
const github_actions = @import("../github/github_actions.zig");
const github_connect = @import("../github/github_connect.zig");
const app = @import("../main.zig");

// === Commit messages ===

const COMMIT_TYPES = [_][]const u8{ "feat", "fix", "refactor", "perf", "docs", "style", "test", "build", "ci", "chore", "revert" };

/// Summary lines git log keeps whole; past the first, most tools cut them.
const SUMMARY_SOFT = 50;
const SUMMARY_HARD = 72;

/// Where a summary longer than `limit` is cut: at its last space before
/// the limit, or at the limit for one long word. Null when it fits.
fn summaryCut(summary: []const u8, limit: usize) ?usize {
    if (summary.len <= limit) return null;
    const space = std.mem.lastIndexOfScalar(u8, summary[0 .. limit + 1], ' ') orelse return limit;
    return if (space == 0) limit else space;
}

/// The summary's last overflow went to the description: said under it
/// until the summary is emptied — committed, or cleared.
pub var summary_moved = false;

/// What git's conventions say of the summary, said rather than done behind
/// its back: where its overflow went, a full stop to drop, a length that
/// reads long in a log.
fn summaryNotes() void {
    const summary = std.mem.trim(u8, app.commit_summary.items, " ");
    if (summary.len == 0) {
        summary_moved = false;
        return;
    }
    const line_len = if (commitSummaryLine(dvui.currentWindow().arena())) |line| line.len else |_| summary.len;
    if (summary_moved) summaryNote(0, dvui.entypo.info_with_circle, style.accent(), "Past 72 characters: the rest went on in the description.").deinit();
    if (summary[summary.len - 1] == '.') {
        var line = summaryNote(1, dvui.entypo.warning, style.get().orange, "A summary ends without a full stop.");
        defer line.deinit();
        if (dialog_views.linkButtonTagged(@src(), "Remove it", style.get().orange, "commit:drop_stop")) {
            app.commit_summary.shrinkRetainingCapacity(std.mem.trimEnd(u8, app.commit_summary.items, ". ").len);
        }
    } else if (line_len > SUMMARY_SOFT and !summary_moved) {
        summaryNote(2, dvui.entypo.light_bulb, style.textFaint(), "Under 50 characters reads best in a log.").deinit();
    }
}

/// One note under the summary: its icon and words in `hue`; the caller
/// adds what to do about it, then `deinit`s.
fn summaryNote(id: usize, icon: []const u8, hue: dvui.Color, text: []const u8) *dvui.BoxWidget {
    const line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .background = false, .margin = .{ .h = style.space.xs } });
    dvui.icon(@src(), "note_icon", icon, .{ .fill_color = .{ .color = hue } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
    dvui.label(@src(), "{s}", .{text}, .{ .font = style.tiny(), .color_text = .{ .color = hue }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    return line;
}

/// A summary past 72 columns — its prefix counted, the type or the ticket
/// the settings add — moved past its last word that fits to the head of
/// the description. True when something moved.
fn overflowSummary() bool {
    const summary = app.commit_summary.items;
    const line_len = if (commitSummaryLine(dvui.currentWindow().arena())) |line| line.len else |_| summary.len;
    const prefix = line_len -| std.mem.trim(u8, summary, " ").len;
    const cut = summaryCut(summary, @max(20, SUMMARY_HARD -| prefix)) orelse return false;
    const rest = std.mem.trim(u8, summary[cut..], " ");
    var next: std.ArrayList(u8) = .empty;
    next.appendSlice(app.gpa, rest) catch return false;
    if (app.commit_description.items.len > 0) {
        next.append(app.gpa, '\n') catch {};
        next.appendSlice(app.gpa, app.commit_description.items) catch {};
    }
    app.commit_description.deinit(app.gpa);
    app.commit_description = next;
    app.commit_summary.shrinkRetainingCapacity(std.mem.trimEnd(u8, summary[0..cut], " ").len);
    return true;
}

test "a summary past 72 is cut at its last word that fits" {
    const long = "Settings for this repository, and a file opened in your editor of choice today";
    try std.testing.expect(long.len > 72);
    const cut = summaryCut(long, 72).?;
    try std.testing.expectEqualStrings("Settings for this repository, and a file opened in your editor of choice", long[0..cut]);
    try std.testing.expect(summaryCut("short", 72) == null);
    // One word longer than the limit: cut at the limit.
    try std.testing.expectEqual(@as(?usize, 5), summaryCut("abcdefghij", 5));
}
const BODY_WIDTH = 72;

/// The ticket a branch is named after — its first `ABC-123`: two or more
/// capitals or digits starting with a capital, a dash, digits. `PROJ-80` out
/// of `PROJ-80-Back-Login`, `WEB-345` out of `feature/WEB-345-login`.
pub fn branchTicket(branch: []const u8) ?[]const u8 {
    for (branch, 0..) |c, i| {
        if (!std.ascii.isUpper(c)) continue;
        if (i > 0 and std.ascii.isAlphanumeric(branch[i - 1])) continue;
        var j = i;
        while (j < branch.len and (std.ascii.isUpper(branch[j]) or std.ascii.isDigit(branch[j]))) j += 1;
        if (j - i < 2 or j + 1 >= branch.len or branch[j] != '-' or !std.ascii.isDigit(branch[j + 1])) continue;
        var k = j + 1;
        while (k < branch.len and std.ascii.isDigit(branch[k])) k += 1;
        return branch[i..k];
    }
    return null;
}

/// The ticket of the branch checked out, when the settings want it.
fn currentTicket() ?[]const u8 {
    if (!app.commit_prefs.ticket) return null;
    const h = app.history orelse return null;
    return branchTicket(h.head orelse return null);
}

/// The scope of a conventional summary — `api` in `feat(api): …`.
pub fn summaryScope(summary: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, summary, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, summary, open, ')') orelse return null;
    if (open == 0 or close == open + 1 or close + 1 >= summary.len) return null;
    if (summary[close + 1] != ':' and summary[close + 1] != '!') return null;
    for (summary[0..open]) |c| if (!std.ascii.isLower(c)) return null;
    return summary[open + 1 .. close];
}

/// The summary line as it will be committed: `feat(api): PROJ-80 add x`,
/// `PROJ-80: add x`, or what was typed. A ticket the text already carries —
/// typed, or brought back with a recent message — is not added twice.
pub fn composeSummary(a: std.mem.Allocator, typed: []const u8, kind: ?[]const u8, scope: []const u8, ticket: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const text = std.mem.trim(u8, typed, " ");
    const new_ticket = if (ticket) |t| (if (std.mem.indexOf(u8, text, t) == null) t else null) else null;
    if (kind) |k| {
        try out.appendSlice(a, k);
        const sc = std.mem.trim(u8, scope, " ");
        if (sc.len > 0) try out.print(a, "({s})", .{sc});
        try out.appendSlice(a, ": ");
        if (new_ticket) |t| try out.print(a, "{s} ", .{t});
    } else if (new_ticket) |t| try out.print(a, "{s}: ", .{t});
    try out.appendSlice(a, text);
    return out.toOwnedSlice(a);
}

/// `text` with every line longer than `width` broken at its spaces. A word
/// longer than the width stays whole; a line that fits is left alone.
pub fn wrapBody(a: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) try out.append(a, '\n');
        first_line = false;
        var col: usize = 0;
        var words = std.mem.splitScalar(u8, line, ' ');
        var first_word = true;
        while (words.next()) |word| {
            if (!first_word) {
                if (col > 0 and col + 1 + word.len > width) {
                    try out.append(a, '\n');
                    col = 0;
                } else {
                    try out.append(a, ' ');
                    col += 1;
                }
            }
            first_word = false;
            try out.appendSlice(a, word);
            col += word.len;
        }
    }
    return out.toOwnedSlice(a);
}

/// The whole message: the summary, the description, and the trailers last,
/// one per line in a paragraph of their own — where git and GitHub look for
/// them, and where `--signoff` adds its own.
pub fn composeMessage(a: std.mem.Allocator, summary: []const u8, body: []const u8, wrap: bool, refs: ?[]const u8, authors: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, summary);

    const text = std.mem.trim(u8, body, " \n");
    if (text.len > 0) {
        try out.appendSlice(a, "\n\n");
        try out.appendSlice(a, if (wrap) try wrapBody(a, text, BODY_WIDTH) else text);
    }

    var trailers: std.ArrayList(u8) = .empty;
    defer trailers.deinit(a);
    if (refs) |t| {
        if (std.mem.indexOf(u8, summary, t) == null and std.mem.indexOf(u8, text, t) == null) try trailers.print(a, "\nRefs: {s}", .{t});
    }
    for (authors) |who| {
        if (std.mem.indexOf(u8, text, who) == null) try trailers.print(a, "\nCo-authored-by: {s}", .{who});
    }
    if (trailers.items.len > 0) {
        try out.append(a, '\n');
        try out.appendSlice(a, trailers.items);
    }
    return out.toOwnedSlice(a);
}

fn conventionalKind() ?[]const u8 {
    if (!app.commit_prefs.conventional) return null;
    return if (app.commit_type) |t| COMMIT_TYPES[t] else null;
}

fn commitSummaryLine(a: std.mem.Allocator) ![]u8 {
    return composeSummary(a, app.commit_summary.items, conventionalKind(), app.commit_scope.items, if (app.commit_prefs.ticket_footer) null else currentTicket());
}

pub fn commitMessage(a: std.mem.Allocator) ![]u8 {
    const summary = try commitSummaryLine(a);
    return composeMessage(a, summary, app.commit_description.items, app.commit_prefs.wrap_body, if (app.commit_prefs.ticket_footer) currentTicket() else null, app.co_authors.items);
}

pub fn clearCoAuthors() void {
    for (app.co_authors.items) |who| app.gpa.free(who);
    app.co_authors.clearRetainingCapacity();
}

fn addCoAuthor(name: []const u8, email: []const u8) void {
    const who = std.fmt.allocPrint(app.gpa, "{s} <{s}>", .{ name, email }) catch return;
    for (app.co_authors.items) |had| if (std.mem.eql(u8, had, who)) return app.gpa.free(who);
    app.co_authors.append(app.gpa, who) catch app.gpa.free(who);
}

/// What only `git` itself can say of the repository just opened — the
/// address it commits with, wherever that is set, and its commit template —
/// asked once, on another thread: on Windows, two `git` started on the UI
/// thread at every tab switch held the window up.
pub var repo_config_job: ?*run.Capture = null;
/// `commit.template` as `git config --path` gives it; empty for none.
pub var git_template_path: std.ArrayList(u8) = .empty;
/// git's config says whether a fetch prunes, here or everywhere: the
/// setting of Zit's own then gives way to it.
pub var git_fetch_prune_set = false;

pub fn startRepoConfig() void {
    if (repo_config_job) |old| old.deinit(app.app_io);
    repo_config_job = null;
    avatars.setSelfEmail("");
    git_template_path.clearRetainingCapacity();
    git_fetch_prune_set = false;
    repo_config_job = run.Capture.start(app.gpa, app.app_io, app.repo_path.items, &.{ "git", "config", "--path", "--get-regexp", "^(user\\.email|commit\\.template|fetch\\.prune)$" }) catch null;
}

/// Take in the repository's config once its `git` has answered.
pub fn collectRepoConfig() void {
    const job_now = repo_config_job orelse return;
    if (!job_now.finished()) return;
    repo_config_job = null;
    defer job_now.deinit(app.app_io);
    // Closed or swapped for another since: the answer is not this one's.
    if (app.repo == null or !std.mem.eql(u8, job_now.cwd, app.repo_path.items)) return;
    if (!job_now.ok) return;

    var email: []const u8 = "";
    var lines = std.mem.splitScalar(u8, job_now.out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const value = std.mem.trim(u8, line[space + 1 ..], " ");
        // Each level in the order git reads them, the repository's last: the
        // last one said is the one that holds.
        if (std.mem.eql(u8, line[0..space], "user.email")) {
            email = value;
        } else if (std.mem.eql(u8, line[0..space], "commit.template")) {
            git_template_path.clearRetainingCapacity();
            git_template_path.appendSlice(app.gpa, value) catch {};
        } else if (std.mem.eql(u8, line[0..space], "fetch.prune")) {
            git_fetch_prune_set = true;
        }
    }
    // Whose picture is the signed-in GitHub account's: the address this
    // repository commits with — not with the integrations off.
    avatars.setSelfEmail(if (tab_strip.integrations) email else "");
}

/// Start an empty message from the template: git's `commit.template` when it
/// names one, the settings' otherwise. The first line is the summary. Comment
/// lines go — with `-m`, git would keep them.
fn applyTemplate() void {
    if (app.commit_summary.items.len > 0 or app.commit_description.items.len > 0) return;

    var from_git: ?[]u8 = null;
    defer if (from_git) |t| app.gpa.free(t);
    const path = git_template_path.items;
    if (path.len > 0) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = if (std.fs.path.isAbsolute(path)) path else std.fmt.bufPrint(&buf, "{s}{s}", .{ app.repo_path.items, path }) catch path;
        from_git = std.Io.Dir.cwd().readFileAlloc(app.app_io, abs, app.gpa, .limited(64 * 1024)) catch null;
    }
    const text = from_git orelse app.commit_template.items;

    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(app.gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) continue;
        kept.appendSlice(app.gpa, line) catch return;
        kept.append(app.gpa, '\n') catch return;
    }
    const all = std.mem.trim(u8, kept.items, " \r\n");
    if (all.len == 0) return;
    const end = std.mem.indexOfScalar(u8, all, '\n') orelse all.len;
    app.commit_summary.appendSlice(app.gpa, std.mem.trim(u8, all[0..end], " \r")) catch {};
    if (end < all.len) app.commit_description.appendSlice(app.gpa, std.mem.trim(u8, all[end..], " \r\n")) catch {};
}

// === Right: staging and commit ===

/// Beside the commit list: what the selected commit holds, or what the
/// working tree is about to become, and the box you commit it from.
pub fn detailPanel() void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .padding = dvui.Rect.all(0),
        .border = .{ .x = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer panel.deinit();

    // The compose box goes with the working tree it commits: under a commit
    // or a comparison it only pushed what is being read up out of the way.
    switch (app.selection) {
        .commit => |id| commitDetail(id),
        .compare => compareDetail(),
        else => {
            workingDetail();
            commitBox();
        },
    }
}

/// A commit: what it is, who made it — co-authors too — what it says, what
/// it touched and where it sits; each part after the heading a section that
/// folds.
/// The commit pane's scroll, as dvui kept it for itself: here, for a test to
/// scroll it.
pub var commit_scroll: dvui.ScrollInfo = .{};

fn commitDetail(id: git.Oid) void {
    app.ensureDiff();
    const commit = diff_view.commitAt(id);
    const whole: []const u8 = if (app.repo) |r| r.commitMessage(dvui.currentWindow().arena(), id) else "";
    const nl = std.mem.indexOfScalar(u8, whole, '\n');
    const rest = if (nl) |i| std.mem.trim(u8, whole[i..], " \t\r\n") else "";
    const split = splitTrailers(rest);

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &commit_scroll }, .{
        .expand = .both,
        .background = false,
        .padding = .{ .h = style.space.sm },
    });
    defer scroll.deinit();

    // The commit first, read top to bottom as one block: its sha and refs,
    // its title, and what the message says past it — selectable, to copy.
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = false,
            .padding = dvui.Rect.all(style.space.lg),
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.border() },
        });
        defer card.deinit();

        {
            var chips = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .margin = .{ .h = style.space.md } });
            defer chips.deinit();
            shaChip(id);
            if (app.history) |h| for (h.refs, 0..) |ref, i| {
                if (!git.oidEql(ref.target, id)) continue;
                const synced = search_view.sameOnRemote(h, ref);
                if (synced and ref.kind == .remote) continue;
                search_view.refTag(@src(), ref, i, synced, false, null, null);
            };
        }

        var title = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0) });
        rebase_view.dropStaleTextSelection(title);
        title.addText(diff_view.commitSummary(id), .{ .font = style.title().withSize(15 * style.ui_scale), .color_text = .{ .color = style.text() } });
        title.deinit();

        // The message past its title, read as the host would show it: its
        // lists as lists, its code as code.
        if (split.text.len > 0) {
            var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.md } });
            defer body.deinit();
            app.markdownText(unwrapMessage(dvui.currentWindow().arena(), split.text), style.small());
        }

        // The trailers apart, in the mono face git wrote them in;
        // co-authors are under the authors.
        var lines = trailerLines(split.trailers);
        var trailers: ?*dvui.BoxWidget = null;
        defer if (trailers) |b| b.deinit();
        var i: usize = 0;
        while (lines.next()) |t| : (i += 1) {
            if (std.ascii.eqlIgnoreCase(t.key, "Co-authored-by")) continue;
            if (trailers == null) trailers = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = true,
                .color_fill = .{ .color = style.surfaceInput() },
                .corners = style.radius.input,
                .margin = .{ .y = style.space.md },
                .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
            });
            dvui.label(@src(), "{s}: {s}", .{ t.key, t.value }, .{
                .id_extra = i,
                .font = style.mono(),
                .color_text = .{ .color = style.textMuted() },
                .expand = .horizontal,
                .max_size_content = .width(0),
                .padding = dvui.Rect.all(0),
            });
        }
    }

    // Then who and when — the author, everyone the message names as a
    // co-author — and the parents it came from, a click each away.
    if (commit) |c| if (accordion(@src(), 2, "Authors & parents", null, &detail_open[2], true)) {
        var when: [32]u8 = undefined;
        var exact: [32]u8 = undefined;
        const authored = std.fmt.allocPrint(dvui.currentWindow().arena(), "authored {s} · {s}", .{ search_view.relativeTime(&when, c.time), search_view.absoluteTime(&exact, c.time) }) catch "";
        personRow(@src(), 0, c, c.author, c.email, authored);
        var people = trailerLines(split.trailers);
        var n: usize = 1;
        while (people.next()) |t| {
            if (!coAuthorOther(t, c.email)) continue;
            const lt = std.mem.indexOfScalar(u8, t.value, '<');
            const name = std.mem.trim(u8, if (lt) |l| t.value[0..l] else t.value, " ");
            const email = if (lt) |l| std.mem.trim(u8, t.value[l + 1 ..], " >") else "";
            var who = c;
            who.id = std.mem.zeroes(git.Oid);
            who.author = name;
            who.email = email;
            personRow(@src(), n, who, name, email, "co-author");
            n += 1;
        }
        for (c.parents, 0..) |parent, i| {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .background = false, .padding = .{ .x = style.space.lg, .y = 2, .w = style.space.lg, .h = 2 } });
            defer line.deinit();
            dvui.label(@src(), "{s}", .{if (i == 0) "Parent" else "Merged"}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .min_size_content = .{ .w = 64 }, .padding = dvui.Rect.all(0) });
            var p: [8]u8 = undefined;
            if (dialog_views.linkButton(@src(), git.oidShort(parent, &p), style.accent())) app.selectCommit(parent);
            dvui.label(@src(), "{s}", .{diff_view.commitSummary(parent)}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .expand = .horizontal, .max_size_content = .width(0), .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
    };

    const files = if (app.diff != null) app.diff_all.len else 0;
    if (accordion(@src(), 1, "Files", files, &detail_open[1], false)) {
        if (app.diff != null) commitFiles(id);
    }
}

/// A commit message's lines as the paragraphs and list items they are: git
/// wraps at 72 columns, so a line that carries on the one before joins it —
/// unless it starts something of its own.
fn unwrapMessage(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var prev_blank = true;
    var in_code = false;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = std.mem.trimStart(u8, line, " \t");
        const fence = std.mem.startsWith(u8, t, "```");
        const starts = fence or t.len == 0 or in_code or
            std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ") or
            std.mem.startsWith(u8, t, "#") or std.mem.startsWith(u8, t, ">") or
            (t.len > 1 and std.ascii.isDigit(t[0]) and (t[1] == '.' or t[1] == ')'));
        if (!prev_blank and !starts) {
            out.append(a, ' ') catch {};
            out.appendSlice(a, t) catch {};
        } else {
            if (out.items.len > 0) out.append(a, '\n') catch {};
            out.appendSlice(a, line) catch {};
        }
        if (fence) in_code = !in_code;
        prev_blank = t.len == 0 or in_code or fence;
    }
    return out.items;
}

test "a commit message's wrapped lines join, its lists and paragraphs stay apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = unwrapMessage(arena.allocator(), "Intro that\nwraps.\n\n- one item\n  that wraps\n- two\n\n```\ncode\nkept\n```");
    try std.testing.expectEqualStrings("Intro that wraps.\n\n- one item that wraps\n- two\n\n```\ncode\nkept\n```", got);
}

/// Every file of a commit's tree, for "All files": read once per commit,
/// each with the change the commit made to it, if any.
pub var tree_files: struct {
    arena: ?std.heap.ArenaAllocator = null,
    id: git.Oid = std.mem.zeroes(git.Oid),
    paths: []const []const u8 = &.{},
    status: []git.Status = &.{},
} = .{};

pub fn clearTreeFiles() void {
    if (tree_files.arena) |*a| a.deinit();
    tree_files = .{};
}

pub fn loadTreeFiles(id: git.Oid) void {
    if (tree_files.arena != null and git.oidEql(tree_files.id, id)) return;
    clearTreeFiles();
    const r = app.repo orelse return;
    tree_files.arena = .init(app.gpa);
    const a = tree_files.arena.?.allocator();
    tree_files.id = id;
    const in_tree = r.treePaths(a, id);

    var changed: std.StringHashMapUnmanaged(git.Status) = .empty;
    for (app.diff_all) |f| changed.put(a, f.path, f.status) catch {};
    // A deleted file is not in the tree any more, but it is one of the
    // commit's files: after the rest.
    var paths: std.ArrayList([]const u8) = .empty;
    paths.appendSlice(a, in_tree) catch {};
    for (app.diff_all) |f| if (f.status == .deleted) paths.append(a, f.path) catch {};
    tree_files.paths = paths.items;
    tree_files.status = a.alloc(git.Status, paths.items.len) catch &.{};
    for (tree_files.paths, 0..) |p, i| {
        if (i < tree_files.status.len) tree_files.status[i] = changed.get(p) orelse .unchanged;
    }
}

/// Show every file of the commit's tree, not only the ones it changed.
pub var commit_all_files: bool = false;
/// Folders folded away in the tree view of a commit's files, owned.
var folded_dirs: std.StringHashMapUnmanaged(void) = .empty;

pub fn clearFoldedDirs() void {
    foldClear(&folded_dirs);
    for (&changes_folded) |*m| foldClear(m);
    for (&change_trees) |*t| t.clear();
    commit_tree.clear();
}

/// Which rows of a list, `count` of them `rh` high each, can be seen this
/// frame: where its box `list` sits against the clip — the scroll area it is
/// in, however deep — read in screen pixels. The rest are spacers, as in
/// `sideRows`: a list in the middle of a scrolled pane, whose own scroll
/// area it is not, built a widget for every row of it.
pub fn rowsInSight(list: *dvui.WidgetData, count: usize, rh: f32) struct { first: usize, last: usize } {
    const box = list.contentRectScale();
    const clip = dvui.clipGet();
    const row = rh * box.s;
    if (row <= 0) return .{ .first = 0, .last = count };
    const top = clip.y - box.r.y;
    const first = @min(count, @as(usize, @intFromFloat(@max(0, top) / row)));
    const last = @min(count, @as(usize, @intFromFloat(@max(0, top + clip.h) / row)) + 1);
    return .{ .first = first, .last = @max(first, last) };
}

/// The rows of a list that `rowsInSight` leaves out: one spacer above them,
/// one below.
pub fn rowsSpacer(src: std.builtin.SourceLocation, id: usize, rows: usize, rh: f32) void {
    if (rows == 0) return;
    _ = dvui.spacer(src, .{ .id_extra = id, .min_size_content = .{ .h = @as(f32, @floatFromInt(rows)) * rh } });
}

/// A commit's files: changed ones, or all of them; as paths, or folder by
/// folder with the folders folding away. Only the rows in sight are built.
fn commitFiles(id: git.Oid) void {
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .padding = .{ .x = style.space.lg, .w = style.space.lg, .h = style.space.sm } });
        defer bar.deinit();
        var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .padding = dvui.Rect.all(2),
        });
        viewToggle(@src(), .path, "Path", dvui.entypo.list);
        viewToggle(@src(), .tree, "Tree", dvui.entypo.flow_tree);
        track.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        dvui.label(@src(), "All files", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0), .margin = .{ .w = style.space.xs } });
        if (repo_settings.toggle(@src(), commit_all_files)) commit_all_files = !commit_all_files;
        // The kinds after it, at the end of the line.
        if (app.diff_all.len > 0) fileFilters();
    }

    if (!commit_all_files) {
        if (app.diff_all.len == 0) return rebase_view.sidebarNote(@src(), "This commit changed no files.");
    }

    const total_n = if (commit_all_files) blk: {
        loadTreeFiles(id);
        break :blk tree_files.paths.len;
    } else app.diff_all.len;
    const Files = struct {
        fn path(all: bool, i: usize) []const u8 {
            const at = files_shown[i];
            return if (all) tree_files.paths[at] else app.diff_all[at].path;
        }
        fn status(all: bool, i: usize) git.Status {
            const at = files_shown[i];
            return if (all) (if (at < tree_files.status.len) tree_files.status[at] else .unchanged) else app.diff_all[at].status;
        }
        fn raw(all: bool, i: usize) git.Status {
            return if (all) (if (i < tree_files.status.len) tree_files.status[i] else .unchanged) else app.diff_all[i].status;
        }
    };
    {
        var shown: std.ArrayList(usize) = .empty;
        const a = dvui.currentWindow().arena();
        for (0..total_n) |i| if (file_filter.matches(Files.raw(commit_all_files, i))) shown.append(a, i) catch {};
        files_shown = shown.items;
    }
    const paths_n = files_shown.len;

    const rh = style.row_height;
    var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
    defer list.deinit();

    if (app.changes_view != .tree) {
        const in_sight = rowsInSight(list.data(), paths_n, rh);
        rowsSpacer(@src(), 0, in_sight.first, rh);
        for (in_sight.first..in_sight.last) |i| fileRow(@src(), id, Files.path(commit_all_files, i), Files.status(commit_all_files, i), files_shown[i], null);
        rowsSpacer(@src(), 1, paths_n - in_sight.last, rh);
        return;
    }

    // Rebuilt for another commit, the other list, or the diff read again.
    var key = std.hash.Wyhash.init(@intFromBool(commit_all_files));
    key.update(std.mem.asBytes(&id));
    key.update(std.mem.asBytes(&paths_n));
    const files: usize = if (commit_all_files) @intFromPtr(tree_files.paths.ptr) else @intFromPtr(app.diff_all.ptr);
    key.update(std.mem.asBytes(&files));
    key.update(std.mem.asBytes(&file_filter));
    commit_tree.build(key.final(), paths_n, commit_all_files, Files.path);

    // The lines unfolded: walked whole, a few pointers each, to know how
    // many there are; built only where they can be seen.
    var shown_n: usize = 0;
    var counting: TreeShown = .{ .rows = commit_tree.rows, .folded = &folded_dirs };
    while (counting.next()) |_| shown_n += 1;
    const in_sight = rowsInSight(list.data(), shown_n, rh);
    rowsSpacer(@src(), 0, in_sight.first, rh);

    var it: TreeShown = .{ .rows = commit_tree.rows, .folded = &folded_dirs };
    var row: usize = 0;
    var fold: ?[]const u8 = null;
    while (it.next()) |shown| : (row += 1) {
        if (row >= in_sight.last) break;
        if (row < in_sight.first) continue;
        if (shown.row.file) |f| {
            fileRow(@src(), id, Files.path(commit_all_files, f), Files.status(commit_all_files, f), files_shown[f], @as(f32, @floatFromInt(shown.row.depth)) * TREE_INDENT + TREE_CHEVRON);
        } else if (folderLine(@src(), shown.index, shown.row, shown.folded, null)) {
            fold = shown.row.path;
        }
    }
    rowsSpacer(@src(), 1, shown_n - in_sight.last, rh);
    // After the lines: folding changes which ones it walks.
    if (fold) |path| foldToggle(&folded_dirs, path);
}

/// A co-author trailer naming someone other than the author: crediting
/// yourself as a co-author would list you twice.
fn coAuthorOther(t: Trailer, author_email: []const u8) bool {
    if (!std.ascii.eqlIgnoreCase(t.key, "Co-authored-by")) return false;
    return author_email.len == 0 or std.ascii.findIgnoreCase(t.value, author_email) == null;
}

/// One person on the commit: picture, name, and a line under it — the
/// address and what they did.
fn personRow(src: std.builtin.SourceLocation, id: usize, as: git.Commit, name: []const u8, email: []const u8, what: []const u8) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .background = false, .padding = .{ .x = style.space.lg, .y = style.space.xs, .w = style.space.lg, .h = style.space.xs } });
    defer row.deinit();
    search_view.avatarSized(@src(), id, as, null, null, 30);
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.sm } });
    defer col.deinit();
    dvui.label(@src(), "{s}", .{name}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
    if (email.len > 0) dvui.label(@src(), "{s}", .{email}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{what}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
}

/// A message body's text, and the trailer block that ends it — the
/// `Key: value` lines after its last blank line, as git writes them.
pub fn splitTrailers(body: []const u8) struct { text: []const u8, trailers: []const u8 } {
    const last_gap = std.mem.lastIndexOf(u8, body, "\n\n");
    const block = if (last_gap) |g| body[g + 2 ..] else body;
    var lines = std.mem.splitScalar(u8, block, '\n');
    var any = false;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r").len == 0) continue;
        if (!isTrailer(line)) return .{ .text = body, .trailers = "" };
        any = true;
    }
    if (!any) return .{ .text = body, .trailers = "" };
    return .{ .text = if (last_gap) |g| std.mem.trim(u8, body[0..g], " \t\r\n") else "", .trailers = block };
}

/// `Key: value`, the key one word of letters and dashes.
fn isTrailer(line: []const u8) bool {
    const colon = std.mem.indexOf(u8, line, ": ") orelse return false;
    if (colon == 0) return false;
    for (line[0..colon]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    return true;
}

const Trailer = struct { key: []const u8, value: []const u8 };

/// The trailers of a block from `splitTrailers`, one at a time.
pub fn trailerLines(block: []const u8) struct {
    it: std.mem.SplitIterator(u8, .scalar),
    pub fn next(self: *@This()) ?Trailer {
        while (self.it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
            return .{ .key = line[0..colon], .value = std.mem.trim(u8, line[colon + 2 ..], " ") };
        }
        return null;
    }
} {
    return .{ .it = std.mem.splitScalar(u8, block, '\n') };
}

/// Which of the commit pane's sections are open: description, files,
/// details, people.
var detail_open = [4]bool{ true, true, true, true };

/// The commit's short sha, to copy: on a chip the height of a ref's tag, its
/// icon telling what a click does.
fn shaChip(id: git.Oid) void {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .tag = "detail:sha",
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = style.tint(style.textMuted()) },
        .color_fill_hover = .{ .color = style.accentDim() },
        .corners = style.radius.tag,
        .margin = .{ .w = style.space.sm },
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    bw.processEvents();
    bw.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        defer row.deinit();
        const ink = if (bw.hovered()) style.accent() else style.textMuted();
        var sha: [8]u8 = undefined;
        dvui.label(@src(), "{s}", .{git.oidShort(id, &sha)}, .{ .font = style.mono(), .color_text = .{ .color = ink }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        dvui.icon(@src(), "sha_copy", dvui.entypo.copy, .{ .fill_color = .{ .color = ink } }, .{
            .min_size_content = .{ .w = 10, .h = 10 },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs },
        });
    }
    if (bw.hovered()) dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r, .position = .vertical, .delay = 400_000 }, "Copy the full sha", .{}, .{ .font = style.small() });
    if (bw.clicked()) {
        var hex: [41]u8 = undefined;
        dvui.clipboardTextSet(git.oidHex(id, &hex));
    }
    bw.deinit();
}

/// A section header that folds what follows it. True while open.
fn accordion(src: std.builtin.SourceLocation, id: usize, title: []const u8, count: ?usize, open: *bool, first: bool) bool {
    var bw: dvui.ButtonWidget = undefined;
    // A hairline over each section but the first — the heading's own rule is
    // over that one — and room to breathe on either side of it.
    bw.init(src, .{ .draw_focus = false }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .color_fill_hover = .{ .color = style.rowHover() },
        .border = .{ .y = if (first) 0 else 1 },
        .color_border = .{ .color = style.border() },
        .corners = .all(0),
        // No margin: a gap between two heads would be the one strip that
        // does not light up under the mouse.
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.md, .y = style.space.md, .w = style.space.lg, .h = style.space.md },
    });
    bw.processEvents();
    bw.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer row.deinit();
        dvui.icon(@src(), "fold", if (open.*) dvui.entypo.chevron_small_down else dvui.entypo.chevron_small_right, .{ .fill_color = .{ .color = style.text() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.xs },
        });
        panelTitle(title, null, count);
    }
    if (bw.clicked()) open.* = !open.*;
    bw.deinit();
    return open.*;
}

/// A folding section's header, the same on either side of the window: the
/// chevron in the text's colour, its name semi-bold.
/// `faded`: everything in it out of the graph.
pub fn sectionFace(folded: bool, title: []const u8, faded: bool) void {
    // In the toolbar's grey, as its buttons' captions are: a head says where
    // things are, and white made it louder than what it heads.
    // The gap after the chevron puts the title over the rows' names, which
    // start past the eye's gutter.
    dvui.icon(@src(), "section_chevron", if (folded) dvui.entypo.chevron_small_right else dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = if (faded) style.textFaint() else style.textMuted() } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = rebase_view.SECTION_CHEVRON_GAP },
    });
    dvui.label(@src(), "{s}", .{title}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = if (faded) style.textFaint() else style.textMuted() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// The same line, under a panel's title.
fn sectionHairlineUnder(wd: *dvui.WidgetData) void {
    const rs = wd.borderRectScale();
    const h = @max(1, rs.s);
    (dvui.Rect.Physical{ .x = rs.r.x, .y = rs.r.y + rs.r.h - h, .w = rs.r.w, .h = h })
        .fill(.{}, .{ .color = .{ .color = style.border() }, .fade = 0 });
}

pub const SECTION_HEAD_H: f32 = 36;
/// A panel's own title, over its sections: GitComet's pane header.
const PANEL_HEAD_H: f32 = 42;

/// A section's title on the right, as the sidebar's are on the left: its
/// icon, its name in the text's own colour and case, semi-bold; and where it
/// helps, how many, on a pill.
fn panelTitle(title: []const u8, icon: ?[]const u8, count: ?usize) void {
    // The sidebar's section icon: its size, its colour, its gap.
    if (icon) |i| dvui.icon(@src(), "panel_icon", i, .{ .fill_color = .{ .color = style.textMuted() } }, .{
        .min_size_content = .{ .w = 13, .h = 13 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    dvui.label(@src(), "{s}", .{title}, .{ .font = style.smallBold(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    countPill(count orelse return);
}

/// How many, on a pill a step lighter than the panel, so it reads at a
/// glance; a zero on the same pill, quieter.
pub fn countPill(n: usize) void {
    var pill = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = .{ .color = style.border() },
        .corners = .all(COUNT_PILL_H / 2),
        .min_size_content = .{ .w = COUNT_PILL_H - 10, .h = COUNT_PILL_H },
        .max_size_content = .height(COUNT_PILL_H),
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm },
        .padding = .{ .x = 5, .w = 5 },
    });
    defer pill.deinit();
    dvui.label(@src(), "{d}", .{n}, .{
        .font = style.tinyBold(),
        .color_text = .{ .color = if (n > 0) style.textMuted() else style.textFaint() },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

const COUNT_PILL_H: f32 = 16;

/// "Label  value", one line of the details section.
fn detailLine(src: std.builtin.SourceLocation, id: usize, caption: []const u8, value: []const u8) void {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .background = false, .padding = .{ .x = style.space.lg, .y = 2, .w = style.space.lg, .h = 2 } });
    defer line.deinit();
    dvui.label(@src(), "{s}", .{caption}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .min_size_content = .{ .w = 64 }, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{value}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
}

/// Which of a commit's files the list shows: all of them, or those of one
/// kind.
const FileFilter = enum {
    all,
    modified,
    added,
    deleted,
    renamed,

    fn matches(self: FileFilter, status: git.Status) bool {
        return switch (self) {
            .all => true,
            .added => status == .added,
            .deleted => status == .deleted,
            .renamed => status == .renamed,
            .modified => status != .added and status != .deleted and status != .renamed and status != .unchanged,
        };
    }

    fn icon(self: FileFilter) []const u8 {
        return switch (self) {
            .all => dvui.entypo.documents,
            .modified => dvui.entypo.edit,
            .added => dvui.entypo.plus,
            .deleted => dvui.entypo.minus,
            .renamed => dvui.entypo.arrow_long_right,
        };
    }

    fn hue(self: FileFilter) dvui.Color {
        return switch (self) {
            .all => style.textMuted(),
            .modified => style.fileStatusColor(.modified),
            .added => style.fileStatusColor(.added),
            .deleted => style.fileStatusColor(.deleted),
            .renamed => style.fileStatusColor(.renamed),
        };
    }
};
var file_filter: FileFilter = .all;

/// Over a commit's files, a tab per kind: its mark in its colour and how
/// many — the one picked lit, the empty ones faded. A click shows only those.
fn fileFilters() void {
    var n = std.enums.EnumArray(FileFilter, usize).initFill(0);
    for (app.diff_all) |file| {
        n.getPtr(.all).* += 1;
        for ([_]FileFilter{ .modified, .added, .deleted, .renamed }) |f| {
            if (f.matches(file.status)) n.getPtr(f).* += 1;
        }
    }
    // A kind this commit has none of shows nothing: back to all of them.
    if (n.get(file_filter) == 0) file_filter = .all;

    // After All files, framed as Path / Tree are: All, then only the kinds
    // this commit has, each as wide as it needs.
    var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm },
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .padding = dvui.Rect.all(2),
    });
    defer track.deinit();
    for (std.enums.values(FileFilter), 0..) |f, i| {
        const count = n.get(f);
        if (count == 0 and f != .all) continue;
        const on = file_filter == f;
        const usable = count > 0;
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .tag = dialog_views.frameTag("files", @tagName(f)),
            .background = true,
            .color_fill = .{ .color = if (on) style.accentDim() else dvui.Color.transparent },
            .color_fill_hover = .{ .color = if (on) style.accentDim() else if (usable) style.rowHover() else dvui.Color.transparent },
            .corners = style.radius.input,
            .margin = dvui.Rect.all(0),
            .padding = .{ .x = style.space.sm, .y = 3, .w = style.space.sm, .h = 3 },
        });
        bw.processEvents();
        bw.drawBackground();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .background = false });
            defer row.deinit();
            const faded = !usable;
            dvui.icon(@src(), "filter_icon", f.icon(), .{ .fill_color = .{ .color = if (faded) style.textFaint() else f.hue() } }, .{
                .min_size_content = .{ .w = 11, .h = 11 },
                .gravity_y = 0.5,
                .margin = .{ .w = style.space.xs },
            });
            dvui.label(@src(), "{d}", .{count}, .{ .font = if (on) style.tinyBold() else style.tiny(), .color_text = .{ .color = if (faded) style.textFaint() else if (on) style.accent() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
        if (bw.hovered()) dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r, .position = .vertical, .delay = 400_000 }, "{d} {s}", .{ count, if (f == .all) "files" else @tagName(f) }, .{ .font = style.small() });
        if (usable and bw.clicked()) file_filter = f;
        bw.deinit();
    }
}

/// The files the list shows, under the filter, by their place in the whole
/// list: what the tree and the rows read their paths through.
var files_shown: []const usize = &.{};

/// A comparison: the two ends, and every file that differs between them.
fn compareDetail() void {
    app.ensureDiff();
    {
        var head = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = false,
            .padding = .{ .x = style.space.lg, .y = style.space.md, .w = style.space.lg, .h = style.space.md },
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.border() },
        });
        defer head.deinit();
        panelTitle("Comparing", null, null);
        dvui.label(@src(), "{s}", .{app.compare_label}, .{
            .font = style.title(),
            .color_text = .{ .color = style.text() },
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
            .margin = .{ .y = style.space.xs },
        });
        const files = if (app.diff != null) app.diff_all.len else 0;
        dvui.label(@src(), "{d} file{s} differ", .{ files, window_chrome.plural(files) }, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0), .margin = .{ .y = style.space.xs } });
    }
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    if (app.diff == null) return;
    // Only the rows in sight, as a commit's: two commits far apart can
    // differ by tens of thousands of files.
    const rh = style.row_height;
    var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
    defer list.deinit();
    const in_sight = rowsInSight(list.data(), app.diff_all.len, rh);
    rowsSpacer(@src(), 0, in_sight.first, rh);
    for (app.diff_all[in_sight.first..in_sight.last], in_sight.first..) |file, i| fileRow(@src(), app.compare_to, file.path, file.status, i, null);
    rowsSpacer(@src(), 1, app.diff_all.len - in_sight.last, rh);
}

/// The working tree: what is staged, what is not, and the way to move a file
/// between the two.
fn workingDetail() void {
    const w = app.work;
    const unstaged: []const git.Change = if (w) |x| x.unstaged else &.{};
    const staged: []const git.Change = if (w) |x| x.staged else &.{};

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
            // The panel's title, taller than the sections under it and in a
            // title's face, as GitComet heads its panes; set in as far as
            // they are — its icon over their chevrons — with a hairline
            // under it, parting it from the lists.
            .min_size_content = .{ .h = PANEL_HEAD_H },
            .padding = .{ .x = style.space.md, .w = style.space.md },
        });
        defer head.deinit();
        defer sectionHairlineUnder(head.data());

        dvui.icon(@src(), "panel_icon", dvui.entypo.documents, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 15, .h = 15 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.md },
        });
        dvui.label(@src(), "Changed files", .{}, .{ .font = style.title(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // One segmented control, the way a two-way choice reads: a framed
        // track with the chosen half filled.
        var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .background = true,
            .color_fill = .{ .color = style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .padding = dvui.Rect.all(2),
        });
        viewToggle(@src(), .path, "Path", dvui.entypo.list);
        viewToggle(@src(), .tree, "Tree", dvui.entypo.flow_tree);
        track.deinit();
    }

    var lists = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer lists.deinit();

    // A list that fits in half the room takes what it needs and leaves the
    // rest to the other; two that do not share it. Neither asks for more than
    // a few rows, so the commit box under them stays in sight however many
    // files there are.
    const half = lists.data().contentRect().h / 2;
    // A list folded away is its title alone, and leaves the rest to the other.
    const fits_unstaged = changes_folded_lists[0] or changes_head_h + changeListHeight(0, unstaged) <= half;
    const fits_staged = changes_folded_lists[1] or changes_head_h + changeListHeight(1, staged) <= half;

    // While a command changes them, or they are read again after one: the
    // lists under a veil, with the dots a request's loading has — after a
    // moment, so a small repository, done at once, never flashes one. Clicks
    // on them wait too: what they would act on is going.
    const waiting = changesWaiting();
    const now = dvui.frameTimeNS();
    if (waiting == null) changes_waiting_since = 0 else if (changes_waiting_since == 0) changes_waiting_since = now;
    const veiled = waiting != null and now - changes_waiting_since >= CHANGES_VEIL_AFTER_NS;
    if (waiting != null and !veiled) dvui.timer(lists.data().id, @intCast(@max(1, @divTrunc(CHANGES_VEIL_AFTER_NS - (now - changes_waiting_since), std.time.ns_per_us))));
    if (veiled) swallowMouse(lists.data());

    changesSection(@src(), "Unstaged", unstaged, false, 0, !(fits_unstaged and !fits_staged));
    changesSection(@src(), "Staged", staged, true, 1, !fits_staged);
    if (veiled) changesVeil(lists.data().contentRect().justSize(), waiting.?);
}

/// What the changes are waiting on, while they wait: a job that changes the
/// working tree — staging, a stash, a commit — or the read after a command.
fn changesWaiting() ?[]const u8 {
    if (tab_strip.job != null and github_actions.job_after != .remote) return tab_strip.job_label;
    if (repo_io.work_settling) return repo_io.settling_label;
    return null;
}

var changes_waiting_since: i128 = 0;
const CHANGES_VEIL_AFTER_NS: i128 = 150 * std.time.ns_per_ms;

/// Every mouse event over `wd` taken before the widgets in it see them.
fn swallowMouse(wd: *dvui.WidgetData) void {
    const r = wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = r })) continue;
        e.handle(@src(), wd);
    }
}

/// The veil over the lists: the panel's own ground, see-through, and in the
/// middle the three dots and what is being done.
fn changesVeil(rect: dvui.Rect, what: []const u8) void {
    var veil = dvui.box(@src(), .{ .dir = .vertical }, .{
        .tag = "changes_veil",
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = style.surface().opacity(0.85) },
    });
    defer veil.deinit();
    // On a card of its own: over the rows' names, bare words read as one more.
    var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = style.surfaceRaised() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
    });
    defer middle.deinit();
    rebase_view.loadingSpinner(@src());
    dvui.label(@src(), "{s}…", .{what}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// Each side's list scrolls on its own. Its rows are placed by hand, only
/// the ones in sight, so its height is given rather than measured: 11,000
/// changed files are 11,000 rows, and building them all made every frame
/// slow and the list as tall as all of them, pushing the commit box off.
pub var changes_scroll: [2]dvui.ScrollInfo = @splat(.{ .vertical = .given });

/// A list's head — "UNSTAGED 3   Stage all" — as last laid out.
var changes_head_h: f32 = 28;

/// Each side's list folded away under its title, as a sidebar section folds.
pub var changes_folded_lists: [2]bool = .{ false, false };

/// The fewest rows a long list keeps while it shares the panel.
const CHANGES_MIN_ROWS = 3;

/// The rows a list shows: one per file, and in the tree view one per folder
/// too, less what folded folders hide.
pub fn changeRows(side: usize, changes: []const git.Change) usize {
    if (app.changes_view != .tree) return changes.len;
    var it: TreeShown = .{ .rows = changeTree(side, changes).rows, .folded = &changes_folded[side] };
    var rows: usize = 0;
    while (it.next()) |_| rows += 1;
    return rows;
}

fn changeListHeight(side: usize, changes: []const git.Change) f32 {
    return @as(f32, @floatFromInt(changeRows(side, changes))) * style.row_height;
}

// === Tree view ===
//
// Files as a file explorer shows them: folders nested in folders, each set
// in under the one it is in, its folders before its files, every folder
// folding away. Built once per list — 11,000 files sorted and nested is a
// few milliseconds, not something to do every frame — and read a screenful
// at a time.

/// One line of a tree view: a folder, or a file in one.
const TreeRow = struct {
    /// How deep it is: 0 at the repository's root.
    depth: u16,
    /// What the line reads: the folder's or the file's own name.
    name: []const u8,
    /// A folder: its path, which is what it is folded by. A file: its path.
    path: []const u8,
    /// A file: its index in the list the tree was built from.
    file: ?u32,
    /// A folder: the lines inside it, which follow it.
    inside: u32 = 0,
    /// A folder: the files inside it, at any depth.
    files: u32 = 0,
};

/// A tree's lines, and the files in the order it shows them.
const Tree = struct {
    arena: ?std.heap.ArenaAllocator = null,
    /// What it was built from; a different one builds it again.
    key: u64 = 0,
    rows: []const TreeRow = &.{},
    /// File indices, top to bottom: a Shift+click's range runs in this order.
    order: []const u32 = &.{},

    pub fn clear(self: *Tree) void {
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }

    /// The tree of `paths` — copied, so it outlives the list they are from.
    fn build(self: *Tree, key: u64, n: usize, ctx: anytype, comptime pathAt: fn (@TypeOf(ctx), usize) []const u8) void {
        if (self.arena != null and self.key == key) return;
        self.clear();
        self.arena = .init(app.gpa);
        self.key = key;
        const a = self.arena.?.allocator();
        const paths = a.alloc([]const u8, n) catch return;
        for (paths, 0..) |*p, i| p.* = a.dupe(u8, pathAt(ctx, i)) catch return;
        self.rows = treeRows(a, paths) catch &.{};
        var order: std.ArrayList(u32) = .empty;
        for (self.rows) |row| if (row.file) |f| order.append(a, f) catch {};
        self.order = order.items;
    }
};

/// Explorer order: in a folder, its folders first, then its files, each by
/// name whatever the case.
fn treeLessThan(paths: []const []const u8, a: u32, b: u32) bool {
    var pa = paths[a];
    var pb = paths[b];
    while (true) {
        const ea = std.mem.indexOfScalar(u8, pa, '/');
        const eb = std.mem.indexOfScalar(u8, pb, '/');
        const ca = pa[0 .. ea orelse pa.len];
        const cb = pb[0 .. eb orelse pb.len];
        if (ea != null and eb != null and std.mem.eql(u8, ca, cb)) {
            pa = pa[ea.? + 1 ..];
            pb = pb[eb.? + 1 ..];
            continue;
        }
        if ((ea != null) != (eb != null)) return ea != null;
        return switch (std.ascii.orderIgnoreCase(ca, cb)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, ca, cb),
        };
    }
}

/// The lines of the tree of `paths`: a folder's line, then what is in it.
pub fn treeRows(a: std.mem.Allocator, paths: []const []const u8) ![]TreeRow {
    const order = try a.alloc(u32, paths.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    // Unstable: the paths are distinct and `treeLessThan` breaks every tie,
    // so the order is total and a stable sort would only add code.
    std.mem.sortUnstable(u32, order, paths, treeLessThan);

    var rows: std.ArrayList(TreeRow) = .empty;
    // The folders the last path was in, outermost first: their lines.
    var open: std.ArrayList(u32) = .empty;
    for (order) |i| {
        const path = paths[i];
        // The open folders this path is in too.
        var keep: usize = 0;
        var at: usize = 0;
        while (keep < open.items.len) : (keep += 1) {
            const dir = rows.items[open.items[keep]].path;
            if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') break;
            at = dir.len + 1;
        }
        while (open.items.len > keep) {
            const f = open.pop().?;
            rows.items[f].inside = @intCast(rows.items.len - f - 1);
        }
        // The folders it is in that are new.
        while (std.mem.indexOfScalarPos(u8, path, at, '/')) |slash| {
            try open.append(a, @intCast(rows.items.len));
            try rows.append(a, .{ .depth = @intCast(open.items.len - 1), .name = path[at..slash], .path = path[0..slash], .file = null });
            at = slash + 1;
        }
        for (open.items) |f| rows.items[f].files += 1;
        try rows.append(a, .{ .depth = @intCast(open.items.len), .name = path[at..], .path = path, .file = i });
    }
    while (open.pop()) |f| rows.items[f].inside = @intCast(rows.items.len - f - 1);
    return compactTree(a, rows.items);
}

/// Compact folders, as GitComet and VS Code have them: a folder that holds
/// nothing but one folder is one line with it — "src/components" — named
/// and folded by the deepest of them.
fn compactTree(a: std.mem.Allocator, rows: []const TreeRow) ![]TreeRow {
    var out: std.ArrayList(TreeRow) = .empty;
    // Where the folders merged into the line after them end: the lines
    // before that sit one level higher for each.
    var merged: std.ArrayList(usize) = .empty;
    // Where in its path the name of a line merged so far starts.
    var from: ?usize = null;
    for (rows, 0..) |row, i| {
        while (merged.items.len > 0 and merged.items[merged.items.len - 1] <= i) _ = merged.pop();
        var r = row;
        r.depth -= @intCast(merged.items.len);
        // Its only line inside is a folder, with everything else in that.
        if (r.file == null and i + 1 < rows.len and rows[i + 1].file == null and r.inside == rows[i + 1].inside + 1) {
            if (from == null) from = r.path.len - r.name.len;
            try merged.append(a, i + 1 + r.inside);
            continue;
        }
        if (from) |f| r.name = r.path[f..];
        from = null;
        try out.append(a, r);
    }
    // What each folder holds, counted again over the lines that are left.
    var open: std.ArrayList(usize) = .empty;
    for (out.items, 0..) |row, j| {
        while (open.items.len > 0 and out.items[open.items[open.items.len - 1]].depth >= row.depth) {
            const f = open.pop().?;
            out.items[f].inside = @intCast(j - f - 1);
        }
        if (row.file == null) try open.append(a, j);
    }
    while (open.pop()) |f| out.items[f].inside = @intCast(out.items.len - f - 1);
    return out.items;
}

/// The lines of a tree that show: a folded folder's own, not what is in it.
pub const TreeShown = struct {
    rows: []const TreeRow,
    folded: *const std.StringHashMapUnmanaged(void),
    at: usize = 0,
    /// Files gone by, folded ones too: the next file's place in `Tree.order`.
    files: u32 = 0,

    const Shown = struct { row: TreeRow, index: usize, folded: bool, pos: u32 };

    pub fn next(self: *TreeShown) ?Shown {
        if (self.at >= self.rows.len) return null;
        const index = self.at;
        const row = self.rows[index];
        self.at += 1;
        const pos = self.files;
        if (row.file != null) {
            self.files += 1;
            return .{ .row = row, .index = index, .folded = false, .pos = pos };
        }
        const folded = self.folded.contains(row.path);
        if (folded) {
            self.at += row.inside;
            self.files += row.files;
        }
        return .{ .row = row, .index = index, .folded = folded, .pos = pos };
    }
};

/// How far in a tree's lines are set, per level.
const TREE_INDENT: f32 = 14;
/// A file's line goes in by a folder's chevron more, so its name lines up
/// with its folder's siblings' names.
const TREE_CHEVRON: f32 = 11 + 4;

/// Each side's tree, and the folders folded in it, by path, owned.
var change_trees: [2]Tree = .{ .{}, .{} };
var changes_folded: [2]std.StringHashMapUnmanaged(void) = .{ .empty, .empty };
/// Bumped each time the working tree's snapshot is replaced.
pub var work_version: u64 = 0;

fn changeTree(side: usize, changes: []const git.Change) *const Tree {
    const t = &change_trees[side];
    t.build(work_version *% 2 +% side, changes.len, changes, struct {
        fn at(c: []const git.Change, i: usize) []const u8 {
            return c[i].path;
        }
    }.at);
    return t;
}

/// The commit's files' tree.
pub var commit_tree: Tree = .{};

fn foldToggle(map: *std.StringHashMapUnmanaged(void), path: []const u8) void {
    if (map.fetchRemove(path)) |kv| {
        app.gpa.free(kv.key);
        return;
    }
    const owned = app.gpa.dupe(u8, path) catch return;
    map.put(app.gpa, owned, {}) catch app.gpa.free(owned);
}

fn foldClear(map: *std.StringHashMapUnmanaged(void)) void {
    var it = map.keyIterator();
    while (it.next()) |k| app.gpa.free(k.*);
    map.deinit(app.gpa);
    map.* = .empty;
}

/// A folder's line in a tree view: set in by its depth, a chevron, the
/// folder, its name and how many files are in it. A click folds or opens it.
/// With `side`, a button stages or unstages the whole folder, as a file's
/// line does the file.
fn folderLine(src: std.builtin.SourceLocation, id: usize, row: TreeRow, folded: bool, side: ?git.DiffSide) bool {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        // "unstaged:src/", as a file's line is tagged by its side: the same
        // folder can be on both, and dvui flags a tag used twice.
        .tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}:{s}/", .{ if (side) |s| @tagName(s) else "folder", row.path }) catch null,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.row_height },
        // On the files' ground, so the tree reads as one list.
        .background = true,
        .color_fill = .{ .color = style.surfaceRaised() },
        .padding = .{ .w = style.space.sm },
    });
    defer line.deinit();
    const rect = line.data().borderRectScale().r;
    if (rect.contains(dvui.currentWindow().mouse_pt)) rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .expand = .both,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.lg + @as(f32, @floatFromInt(row.depth)) * TREE_INDENT },
    });
    bw.processEvents();
    {
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = false });
        defer face.deinit();
        dvui.icon(@src(), "fold", if (folded) dvui.entypo.chevron_small_right else dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textFaint() } }, .{
            .min_size_content = .{ .w = 11, .h = 11 },
            .gravity_y = 0.5,
            .margin = .{ .w = 4 },
        });
        dvui.icon(@src(), "folder", dvui.entypo.folder, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 13, .h = 13 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
        });
        dvui.label(@src(), "{s}", .{row.name}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textMuted() },
            .gravity_y = 0.5,
            .max_size_content = .width(0),
            .expand = .horizontal,
            .padding = dvui.Rect.all(0),
        });
        dvui.label(@src(), "{d}", .{row.files}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.sm },
            .padding = dvui.Rect.all(0),
        });
    }
    const hit = bw.clicked();
    bw.deinit();

    if (side) |s| {
        if (s == .staged) {
            if (dialog_views.iconButton(@src(), "unstage_folder", "Unstage this folder", dvui.entypo.minus, style.textMuted())) repo_io.request(&.{ "reset", "-q", "--", row.path });
        } else {
            if (dialog_views.iconButton(@src(), "stage_folder", "Stage this folder", dvui.entypo.plus, style.textMuted())) github_actions.requestLocal("Staging", &.{ "add", "-A", "--", row.path });
        }
    }
    return hit;
}

/// One file of a commit — a flag, a path, and a click that opens its diff.
fn fileRow(src: std.builtin.SourceLocation, commit_id: git.Oid, path: []const u8, status: git.Status, id: usize, indent: ?f32) void {
    const open = std.mem.eql(u8, app.selected_path.items, path);
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        // By its path, for a test to find which rows were built.
        .tag = dialog_views.frameTag("file", path),
        .expand = .horizontal,
        .min_size_content = .{ .h = style.row_height },
        // Selected as a row of the commit list is: its colour, and a bar.
        // The others on the panel's ground — dvui fills a box with a border
        // on one side in its colour whatever `background` says.
        .background = open,
        .color_fill = .{ .color = if (open) style.rowSelected() else style.surfaceRaised() },
        .border = .{ .x = 2 },
        .color_border = .{ .color = if (open) style.accent() else dvui.Color.transparent },
        // Under its folder's line in the tree view, set in from it.
        .padding = .{ .x = style.space.lg + (indent orelse 0), .w = style.space.md },
    });

    statusFlag(@src(), status);

    // The file's name first, where the eye lands, and its folder after it,
    // faint: a long path cut at the end cut the part that mattered. In the
    // tree view the folder is the line above.
    const name = std.fs.path.basename(path);
    const folder = if (indent != null) "" else std.fs.path.dirname(path) orelse "";
    dvui.label(@src(), "{s}", .{name}, .{
        .font = style.small(),
        .color_text = .{ .color = if (status == .unchanged) style.textMuted() else style.text() },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    dvui.label(@src(), "{s}", .{folder}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });

    const hit = dvui.clicked(row.data(), .{});
    row.deinit();

    // That file's diff, in the centre; the commit stays on the right, so the
    // next file is one click away.
    if (hit) {
        if (app.selection == .compare) {
            app.selected_path.clearRetainingCapacity();
            app.selected_path.appendSlice(app.gpa, path) catch {};
            app.diff_stale = true;
            app.diff_scroll.viewport.y = 0;
        } else app.selectCommitFile(commit_id, path);
    }
}

/// The mockup's file flag: one letter on a tinted square, in the colour the
/// rest of the app uses for that status.
pub fn statusFlag(src: std.builtin.SourceLocation, status: git.Status) void {
    const hue = style.fileStatusColor(status);

    // A fixed box with the letter centred in it: a label's own min size pads
    // to the right and below, which leaves the letter off centre.
    var badge = dvui.box(src, .{}, .{
        .background = true,
        .color_fill = .{ .color = style.tint(hue) },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .size(.{ .w = 16, .h = 16 }),
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    defer badge.deinit();

    dvui.label(@src(), "{s}", .{status.letter()}, .{
        .font = style.tiny(),
        .color_text = .{ .color = hue },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
}

fn viewToggle(src: std.builtin.SourceLocation, view: app.ChangesView, caption: []const u8, icon: []const u8) void {
    const selected = app.changes_view == view;

    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .id_extra = @backingInt(view),
        .min_size_content = .{ .h = 24 },
        .gravity_y = 0.5,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    defer bw.deinit();
    bw.processEvents();

    const color = if (selected) style.accent() else if (bw.hovered()) style.text() else style.textFaint();

    {
        var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = selected or bw.hovered(),
            .color_fill = .{ .color = if (selected) style.accentDim() else style.rowHover() },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.sm, .w = style.space.sm },
        });
        defer cell.deinit();

        dvui.icon(@src(), caption, icon, .{ .fill_color = .{ .color = color } }, .{
            .min_size_content = .{ .w = 10, .h = 10 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.xs },
        });
        dvui.label(@src(), "{s}", .{caption}, .{
            .font = if (selected) style.tinyBold() else style.tiny(),
            .color_text = .{ .color = color },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }

    if (bw.clicked()) app.changes_view = view;
}

fn changesSection(
    src: std.builtin.SourceLocation,
    caption: []const u8,
    changes: []const git.Change,
    staged: bool,
    id: usize,
    /// Takes a share of the room left, rather than just what its rows need.
    grow: bool,
) void {
    const folded = &changes_folded_lists[id];
    var section = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        // An empty list is a header and one line: expanded, it would squeeze
        // the list that has files into half the panel. A folded one is its
        // header alone.
        .expand = if (changes.len == 0 or !grow or folded.*) .horizontal else .both,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer section.deinit();

    {
        // As a sidebar section's header, line for line: the hover drawn by
        // hand, a button as high, set in as far, and the same face — no rule
        // between Unstaged and Staged. Then the count, and the links.
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer head.deinit();
        const head_rect = head.data().borderRectScale().r;
        if (head_rect.contains(dvui.currentWindow().mouse_pt)) head_rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });

        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .tag = if (staged) "fold:staged" else "fold:unstaged",
            .expand = .horizontal,
            .min_size_content = .{ .h = SECTION_HEAD_H },
            .background = false,
            .margin = dvui.Rect.all(0),
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = false, .padding = .{ .x = style.space.md } });
            defer row.deinit();
            sectionFace(folded.*, caption, false);
            countPill(changes.len);
        }
        if (bw.clicked()) folded.* = !folded.*;
        bw.deinit();

        var links = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .vertical, .background = false, .padding = .{ .w = style.space.md } });
        defer links.deinit();
        const side: git.DiffSide = if (staged) .staged else .unstaged;
        const n = pickedIn(side, changes);
        if (n > 0) {
            // Files picked with Ctrl or Shift: what to do with those alone.
            var buf: [32]u8 = undefined;
            if (dialog_views.linkButtonTagged(@src(), std.fmt.bufPrint(&buf, "Stash {d}", .{n}) catch "Stash", style.textMuted(), "link:stash_picked")) requestPicked(.stash, side, changes);
            var buf2: [32]u8 = undefined;
            if (dialog_views.linkButtonTagged(@src(), std.fmt.bufPrint(&buf2, "{s} {d}", .{ if (staged) "Unstage" else "Stage", n }) catch "Stage", style.accent(), "link:stage_picked")) requestPicked(if (staged) .unstage else .stage, side, changes);
            if (dialog_views.iconButtonTagged(@src(), "picked_clear", "Clear the selection — Esc", dvui.entypo.cross, style.textFaint(), "link:picked_clear")) clearPickedChanges();
        } else if (changes.len > 0) {
            if (staged) {
                if (dialog_views.linkButtonTagged(@src(), "Unstage all", style.accent(), "link:unstage_all")) repo_io.request(&.{ "reset", "-q", "--", "." });
            } else {
                // A job: adding 11,000 new files is 13 s of git on Windows,
                // which the window would otherwise wait out frozen.
                if (dialog_views.linkButtonTagged(@src(), "Stage all", style.accent(), "link:stage_all")) requestStageAll();
            }
        }
        changes_head_h = head.data().rect.h;
    }
    if (folded.*) return;

    if (changes.len == 0) {
        dvui.label(@src(), "{s}", .{if (staged) "Nothing staged." else "No local changes."}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textFaint() },
            .margin = .{ .x = style.space.lg, .y = style.space.xs, .h = style.space.md },
            .padding = dvui.Rect.all(0),
        });
        return;
    }

    const rh = style.row_height;
    const info = &changes_scroll[id];
    info.virtual_size.h = changeListHeight(id, changes);
    // Held to the list: one that just got shorter — files staged while
    // scrolled far down — would otherwise be drawn scrolled past its end.
    info.viewport.y = @min(info.viewport.y, info.scrollMax(.vertical));
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = info }, .{
        .expand = .both,
        .background = false,
        // All of a list that fits; a few rows of one that shares the room,
        // which is what keeps the commit box in the panel.
        .min_size_content = .{ .h = if (grow) @min(info.virtual_size.h, CHANGES_MIN_ROWS * rh) else info.virtual_size.h },
    });
    defer scroll.deinit();

    // Only the rows in sight are built, as in the history.
    const width = @max(info.viewport.w, 120);
    const first: usize = @intFromFloat(@floor(@max(0, info.viewport.y) / rh));
    const last = first + @as(usize, @intFromFloat(@ceil(info.viewport.h / rh))) + 1;

    if (app.changes_view != .tree) {
        // Held to the list: one that just got shorter — files staged while
        // scrolled far down — is still scrolled past its end this frame.
        const end = @min(last, changes.len);
        for (@min(first, end)..end) |i| {
            var slot = dvui.box(@src(), .{}, .{ .id_extra = i, .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(i)) * rh, .w = width, .h = rh }, .background = false });
            changeRow(@src(), changes[i], staged, id * 10000 + i, changes, i, null, 0);
            slot.deinit();
        }
        return;
    }

    const tree = changeTree(id, changes);
    var it: TreeShown = .{ .rows = tree.rows, .folded = &changes_folded[id] };
    var row: usize = 0;
    var fold: ?[]const u8 = null;
    while (it.next()) |shown| : (row += 1) {
        if (row >= last) break;
        if (row < first) continue;
        var slot = dvui.box(@src(), .{}, .{ .id_extra = shown.index, .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(row)) * rh, .w = width, .h = rh }, .background = false });
        defer slot.deinit();
        if (shown.row.file) |f| {
            const indent = @as(f32, @floatFromInt(shown.row.depth)) * TREE_INDENT + TREE_CHEVRON;
            changeRow(@src(), changes[f], staged, id * 10000 + f, changes, shown.pos, tree.order, indent);
        } else if (folderLine(@src(), shown.index, shown.row, shown.folded, if (staged) .staged else .unstaged)) {
            fold = shown.row.path;
        }
    }
    // After the loop: folding changes which lines it walks.
    if (fold) |path| foldToggle(&changes_folded[id], path);
}

/// `index`: the file's place in the list as shown — `order` maps it to
/// `changes` in the tree view, where a Shift+click's range runs top to
/// bottom as the tree reads. `indent`: how far a tree's line is set in.
fn changeRow(src: std.builtin.SourceLocation, change: git.Change, staged: bool, id: usize, changes: []const git.Change, index: usize, order: ?[]const u32, indent: f32) void {
    const side: git.DiffSide = if (staged) .staged else .unstaged;
    const selected = switch (app.selection) {
        .change => |s| s == side and std.mem.eql(u8, app.selected_path.items, change.path),
        else => false,
    };
    const picked = isChangePicked(side, change.path);

    // The row is a box holding two siblings: the button that is the file
    // (click for the diff, double-click to stage), and the icon buttons.
    // Nested inside that button, the icons never saw a click — the outer
    // button takes the press first — so they sit beside it instead.
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        // "staged:path" / "unstaged:path", so a test can find the row; the
        // same path can be on both sides at once.
        .tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}:{s}", .{ @tagName(side), change.path }) catch null,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.row_height },
        .background = selected or picked,
        .color_fill = .{ .color = if (picked) style.accentDim() else if (selected) style.rowSelected() else style.surfaceRaised() },
        // The mockup marks the open file with a bar down its left edge
        // rather than a fill, so a selected row still reads as a row.
        .border = .{ .x = 2 },
        .color_border = .{ .color = if (selected) style.get().purple else dvui.Color.transparent },
        .padding = .{ .w = style.space.sm },
    });
    defer row.deinit();

    // Hover across the whole row, icons included: drawn by hand, since the
    // box decided its own background before it knew where the mouse was.
    const row_rect = row.data().borderRectScale().r;
    if (!selected and row_rect.contains(dvui.currentWindow().mouse_pt)) {
        row_rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });
    }

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .expand = .both,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.lg + indent },
    });
    bw.processEvents();
    {
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = false });
        defer face.deinit();

        statusFlag(@src(), change.status);

        const shown = if (app.changes_view == .tree) std.fs.path.basename(change.path) else change.path;
        dvui.label(@src(), "{s}", .{shown}, .{
            // The interface's face, as a commit's files and the sidebar's names
            // are — and as GitComet writes paths in its lists: mono read large
            // and cramped there.
            .font = style.small(),
            .color_text = .{ .color = if (selected) style.text() else style.textMuted() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .margin = .{ .x = style.space.sm },
            .padding = dvui.Rect.all(0),
        });
    }
    // Read before `deinit`, which leaves the widget data undefined.
    const hit = bw.clicked();
    const row_id = bw.data().id;
    bw.deinit();

    if (staged) {
        if (dialog_views.iconButton(@src(), "unstage", "Unstage this file", dvui.entypo.minus, style.textMuted())) {
            requestStage(change.path, change.old_path, false);
        }
    } else {
        if (dialog_views.iconButton(@src(), "discard", "Discard changes to this file", dvui.entypo.trash, style.textFaint())) {
            github_actions.ask(.discard, change.path);
        }
        if (dialog_views.iconButton(@src(), "stage", "Stage this file", dvui.entypo.plus, style.textMuted())) {
            requestStage(change.path, change.old_path, true);
        }
    }

    changeMenu(@src(), change, staged, id, row_rect);

    if (hit) {
        const mods = dvui.currentWindow().modifiers;
        if (mods.control() or mods.command()) {
            // Ctrl+click: one more, or one fewer — starting from the file
            // already open, which a list's selection always includes.
            if (pickedIn(side, changes) == 0) switch (app.selection) {
                .change => |s| if (s == side and !std.mem.eql(u8, app.selected_path.items, change.path)) toggleChangePick(side, app.selected_path.items),
                else => {},
            };
            toggleChangePick(side, change.path);
            pick_anchor = index;
        } else if (mods.shift()) {
            // Shift+click: everything from the last file clicked to this one.
            const from = pick_anchor orelse index;
            clearPickedChanges();
            for (@min(from, index)..@max(from, index) + 1) |at| {
                const i = if (order) |o| (if (at < o.len) o[at] else continue) else at;
                if (i < changes.len) toggleChangePick(side, changes[i].path);
            }
            pick_anchor = from;
        } else {
            clearPickedChanges();
            pick_anchor = index;
            // Double-click stages or unstages, which is what the gesture means in
            // every other git client; a single click still just shows the diff.
            if (rebase_view.isDoubleClick(row_id)) {
                requestStage(change.path, change.old_path, !staged);
            }
            app.selectChange(change.path, side);
        }
    }
}

// === Several changes at once ===

/// Changes picked with Ctrl or Shift, by path, owned: one side's at a time.
pub var picked_changes: std.ArrayList([]u8) = .empty;
/// The same paths, borrowed from `picked_changes`: what "is it picked?" asks,
/// for every row drawn and, through `pickedIn`, for every change of the
/// list each frame — 62 ms a frame through the list with 5,000 picked.
pub var picked_set: std.StringHashMapUnmanaged(void) = .empty;
var picked_side: git.DiffSide = .unstaged;
/// The file a Shift+click range runs from: the last one clicked.
var pick_anchor: ?usize = null;

pub fn clearPickedChanges() void {
    graph_view.clearNames(&picked_changes);
    pick_anchor = null;
}

pub fn isChangePicked(side: git.DiffSide, path: []const u8) bool {
    return picked_side == side and picked_set.contains(path);
}

pub fn toggleChangePick(side: git.DiffSide, path: []const u8) void {
    if (picked_side != side) graph_view.clearNames(&picked_changes);
    picked_side = side;
    if (picked_set.contains(path)) {
        _ = picked_set.remove(path);
        for (picked_changes.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) {
            app.gpa.free(picked_changes.orderedRemove(i));
            return;
        };
        return;
    }
    const owned = app.gpa.dupe(u8, path) catch return;
    picked_changes.append(app.gpa, owned) catch return app.gpa.free(owned);
    picked_set.put(app.gpa, owned, {}) catch {
        _ = picked_changes.pop();
        app.gpa.free(owned);
    };
}

/// How many of `changes` are picked: a pick whose file has since gone —
/// staged, discarded — does not count.
pub fn pickedIn(side: git.DiffSide, changes: []const git.Change) usize {
    var n: usize = 0;
    for (changes) |c| n += @intFromBool(isChangePicked(side, c.path));
    return n;
}

const PickedVerb = enum { stage, unstage, stash };

/// The picked files staged, unstaged or stashed together. Handed to git on
/// standard input, NUL-separated: there may be more of them than a command
/// line Zit keeps room for, and a path may hold anything but a NUL.
pub fn requestPicked(verb: PickedVerb, side: git.DiffSide, changes: []const git.Change) void {
    if (repo_io.action != .none) return;
    var input: std.ArrayList(u8) = .empty;
    for (changes) |c| {
        if (!isChangePicked(side, c.path)) continue;
        input.appendSlice(app.gpa, c.path) catch return input.deinit(app.gpa);
        input.append(app.gpa, 0) catch return input.deinit(app.gpa);
        // A rename's old path goes with it: unstaging or stashing half of
        // one leaves a deletion behind.
        if (c.old_path.len > 0 and !std.mem.eql(u8, c.old_path, c.path)) {
            input.appendSlice(app.gpa, c.old_path) catch return input.deinit(app.gpa);
            input.append(app.gpa, 0) catch return input.deinit(app.gpa);
        }
    }
    if (input.items.len == 0) return input.deinit(app.gpa);
    switch (verb) {
        .stage => repo_io.request(&.{ "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul" }),
        .unstage => repo_io.request(&.{ "reset", "-q", "--pathspec-from-file=-", "--pathspec-file-nul" }),
        .stash => github_actions.requestLocal("Stashing", &.{ "stash", "push", "--include-untracked", "--pathspec-from-file=-", "--pathspec-file-nul" }),
    }
    // Refused — a job running, say — the paths would wait for whatever
    // command comes next.
    if (repo_io.action == .none) return input.deinit(app.gpa);
    repo_io.action_input = input.toOwnedSlice(app.gpa) catch return input.deinit(app.gpa);
    clearPickedChanges();
}

/// Stage every change — asked first when a conflicted file still has its
/// markers in it. A job: adding 11,000 new files is 13 s of git on Windows,
/// which the window would otherwise wait out frozen.
pub fn requestStageAll() void {
    const w = app.work orelse return;
    for (w.unstaged) |change| {
        if (change.status == .conflicted and markersLeft(change.path)) return github_actions.ask(.stage_markers, "");
    }
    github_actions.requestLocal("Staging", &.{ "add", "-A" });
}

/// Whether `path` is conflicted and its file still holds a conflict region,
/// read off the disk now: what staging it would put in the index as the
/// resolution. False for a file git does not count as conflicted.
pub fn markersLeft(path: []const u8) bool {
    const w = app.work orelse return false;
    const conflicted = for (w.unstaged) |change| {
        if (change.status == .conflicted and std.mem.eql(u8, change.path, path)) break true;
    } else false;
    if (!conflicted) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&buf, "{s}{s}", .{ app.repo_path.items, path }) catch return false;
    const text = std.Io.Dir.cwd().readFileAlloc(app.app_io, abs, app.gpa, .limited(app.MAX_CONFLICT_BYTES)) catch return false;
    defer app.gpa.free(text);
    const regions = git.parseConflicts(app.gpa, text) catch return false;
    defer app.gpa.free(regions);
    return regions.len > 0;
}

/// Stage or unstage a whole file, both its names when it was renamed —
/// `old` is `path` otherwise.
///
/// `reset`, not `restore --staged`: the latter resolves HEAD, so it fails on a
/// repository that has no commits yet — which is exactly when you are staging
/// for the first time.
pub fn requestStage(path: []const u8, old: []const u8, stage: bool) void {
    if (stage) {
        if (markersLeft(path)) return github_actions.ask(.stage_markers, path);
        repo_io.request(&.{ "--literal-pathspecs", "add", "--", path, old });
    } else {
        repo_io.request(&.{ "--literal-pathspecs", "reset", "-q", "--", path, old });
    }
}

/// What a changed file can be the target of. Right-click, because the row has
/// space for two buttons and this is the rest of the list.
fn changeMenu(
    src: std.builtin.SourceLocation,
    change: git.Change,
    staged: bool,
    id: usize,
    rect: dvui.Rect.Physical,
) void {
    const ctx = dvui.context(src, .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();

    const cp = ctx.activePoint() orelse return;

    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();

    if (staged) {
        if (graph_view.menuIcon(@src(), dvui.entypo.squared_minus, "Unstage", false)) {
            fw.close();
            requestStage(change.path, change.old_path, false);
        }
    } else {
        if (graph_view.menuIcon(@src(), dvui.entypo.squared_plus, "Stage", false)) {
            fw.close();
            requestStage(change.path, change.old_path, true);
        }
    }

    if (graph_view.menuIcon(@src(), dvui.entypo.document, "Open this file", false)) {
        fw.close();
        openPath(change.path);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.eye, "Blame", false)) {
        fw.close();
        app.selectBlame(change.path);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.clock, "History of this file", false)) {
        fw.close();
        graph_view.showFileHistory(change.path);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.copy, "Copy the path", false)) {
        fw.close();
        dvui.clipboardTextSet(change.path);
    }

    // Last, and only where there is something to lose: staged changes are
    // dropped by unstaging them first, which is the line above.
    if (!staged) {
        if (graph_view.menuIcon(@src(), dvui.entypo.trash, "Discard changes…", true)) {
            fw.close();
            github_actions.ask(.discard, change.path);
        }
        // Only for a file git does not know yet: ignoring a tracked one does
        // nothing until it is removed from the index, which is a surprise.
        if (change.status == .added) {
            if (graph_view.menuIcon(@src(), dvui.entypo.eye_with_line, "Ignore this file", false)) {
                fw.close();
                ignorePath(change.path);
            }
        }
    }
}

/// Append `path` to the top-level `.gitignore`, creating it if need be.
pub fn ignorePath(path: []const u8) void {
    if (app.repo == null) return;

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}.gitignore", .{app.repo_path.items}) catch return;

    const old = std.Io.Dir.cwd().readFileAlloc(app.app_io, abs, app.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => app.gpa.dupe(u8, "") catch return,
        else => return github_actions.setCommandError("Could not read .gitignore."),
    };
    defer app.gpa.free(old);

    // Anchored with a leading slash, so it ignores this file and not every
    // file of that name further down the tree; its glob characters, and the
    // trailing spaces git would trim, escaped, so it names only this one.
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(app.gpa);
    next.appendSlice(app.gpa, old) catch return;
    if (old.len > 0 and old[old.len - 1] != '\n') next.append(app.gpa, '\n') catch return;
    next.append(app.gpa, '/') catch return;
    const kept = std.mem.trimEnd(u8, path, " ").len;
    for (path, 0..) |ch, i| {
        if (std.mem.indexOfScalar(u8, "*?[\\", ch) != null or i >= kept) next.append(app.gpa, '\\') catch return;
        next.append(app.gpa, ch) catch return;
    }
    next.append(app.gpa, '\n') catch return;

    std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = abs, .data = next.items }) catch {
        return github_actions.setCommandError("Could not write .gitignore.");
    };
    github_actions.clearCommandError();
    repo_io.workChanged("Ignoring");
}

/// Hand a file in the working tree to the desktop, without waiting for it.
pub fn openPath(path: []const u8) void {
    if (app.repo == null) return;

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}{s}", .{ app.repo_path.items, path }) catch return;

    run.open(app.app_io, app.repo_path.items, abs) catch github_actions.setCommandError("Could not open that file.");
}

/// The compose box at the bottom of the detail panel: a summary, a body, and
/// the one button that writes history.
fn commitBox() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surfaceRaised() },
        .padding = .{
            .x = style.space.xl,
            .y = style.space.lg,
            .w = style.space.xl,
            .h = style.space.lg,
        },
        .border = .{ .y = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer box.deinit();

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
            .padding = .{ .h = style.space.sm },
        });
        defer head.deinit();

        panelTitle("Commit", null, null);
        // The length of the line git will get, prefix and all: 50 is the
        // convention, 72 where most tools start cutting.
        if (app.commit_summary.items.len > 0) {
            const n = if (commitSummaryLine(dvui.currentWindow().arena())) |line| line.len else |_| app.commit_summary.items.len;
            dvui.label(@src(), "{d}", .{n}, .{
                .font = style.tiny(),
                .color_text = .{ .color = if (n > SUMMARY_HARD) style.get().red else if (n > SUMMARY_SOFT) style.get().yellow else style.textFaint() },
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.sm },
                .padding = dvui.Rect.all(0),
            });
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        // Everything that shapes the commit, beside its title: the ticket it
        // will carry, a recent message, co-authors, signing, sign-off — the
        // last two the settings' standing choices, flipped here as well.
        if (currentTicket()) |ticket| signalChip(@src(), 1, dvui.entypo.tag, ticket, style.get().blue);
        recentMessages(@src());
        coAuthorMenu(@src());
        if (dialog_views.iconButtonTagged(@src(), "commit_sign", if (app.commit_prefs.sign) "Signed (-S) — click to stop signing" else "Not signed — click to sign with -S", dvui.entypo.lock, if (app.commit_prefs.sign) style.success() else style.textFaint(), "commit:sign")) {
            app.commit_prefs.sign = !app.commit_prefs.sign;
            tab_strip.saveWorkspace();
        }
        if (dialog_views.iconButtonTagged(@src(), "commit_signoff", if (app.commit_prefs.signoff) "Signed-off-by — click to drop it" else "No Signed-off-by — click to add one", dvui.entypo.check, if (app.commit_prefs.signoff) style.accent() else style.textFaint(), "commit:signoff")) {
            app.commit_prefs.signoff = !app.commit_prefs.signoff;
            tab_strip.saveWorkspace();
        }
        // No `color_text`: dvui draws the tick in it, and a muted one
        // vanishes into the accent fill. Not while a merge or a rebase is
        // under way: amending a rebase's stop folds it into the commit
        // before, and a merge's into the branch's last.
        if (github_actions.operationCommand() != null) {
            app.amend = false;
        } else if (dvui.checkbox(@src(), &app.amend, "Amend", .{
            .tag = "commit:amend",
            .font = style.small(),
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        }) and app.amend) github_actions.fillFromHead();
    }

    // Once git has said whether the repository names a template of its own.
    if (app.template_due and app.repo != null and repo_config_job == null) {
        app.template_due = false;
        applyTemplate();
    }

    if (app.commit_prefs.conventional) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer row.deinit();
        commitTypeMenu(@src());
        _ = commitField(@src(), &app.commit_scope, "scope", false, 0, "commit_scope");
        scopeMenu(@src());
    }
    _ = commitField(@src(), &app.commit_summary, "Commit summary", false, 0, "commit_summary");
    const description_field = commitField(@src(), &app.commit_description, "Description (optional)", true, 52, "commit_description");
    // Past 72 the summary goes on in the description, the typing with it.
    if (overflowSummary()) {
        summary_moved = true;
        dvui.focusWidget(description_field, null, null);
        dvui.refresh(null, @src(), null);
    }
    summaryNotes();

    // What the settings add, shown before it is committed rather than found
    // in the log afterwards.
    if (app.commit_summary.items.len > 0) {
        if (commitSummaryLine(dvui.currentWindow().arena())) |line| {
            if (!std.mem.eql(u8, line, std.mem.trim(u8, app.commit_summary.items, " "))) {
                dvui.label(@src(), "→ {s}", .{line}, .{
                    .font = style.tiny(),
                    .color_text = .{ .color = style.textFaint() },
                    .expand = .horizontal,
                    .max_size_content = .width(0),
                    .margin = .{ .h = style.space.sm },
                    .padding = dvui.Rect.all(0),
                });
            }
        } else |_| {}
    }

    coAuthorChips();

    const can_commit = app.canCommit();

    const caption: []const u8 = if (app.commit_summary.items.len == 0)
        "Write a summary to commit"
    else if (!can_commit)
        "Stage something to commit"
    else if (app.amend)
        "Amend the last commit"
    else
        "Commit";

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .tag = "commit_button",
        .expand = .horizontal,
        .min_size_content = .{ .h = 36 },
        .background = false,
        .margin = .{ .y = style.space.xs },
        .padding = dvui.Rect.all(0),
        .corners = style.radius.input,
    });
    defer bw.deinit();
    bw.processEvents();

    {
        var cell = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .color = if (!can_commit)
                style.rowHover()
            else if (bw.hovered())
                style.accentHover()
            else
                style.accent() },
            .corners = style.radius.input,
        });
        defer cell.deinit();

        // Icon and caption centred together.
        var inner = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5, .background = false });
        defer inner.deinit();
        const ink = if (can_commit) style.textOnAccent() else style.textFaint();
        dvui.icon(@src(), "commit_icon", if (app.amend) dvui.entypo.pencil else dvui.entypo.check, .{ .fill_color = .{ .color = ink }, .stroke_color = null }, .{
            .min_size_content = .{ .w = 13, .h = 13 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
        });
        dvui.label(@src(), "{s}", .{caption}, .{
            .font = style.bodyBold(),
            .color_text = .{ .color = ink },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }

    if (can_commit and bw.clicked()) repo_io.requestAction(.commit);
}

fn commitField(
    src: std.builtin.SourceLocation,
    backing: *std.ArrayList(u8),
    placeholder: []const u8,
    multiline: bool,
    height: f32,
    tag: []const u8,
) dvui.Id {
    var field = dvui.box(src, .{}, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .min_size_content = .{ .h = height },
        .margin = .{ .h = style.space.sm },
    });
    defer field.deinit();

    const te = dialog_views.textField(@src(), .{
        .text = .{ .array_list = .{ .backing = backing, .allocator = app.gpa, .limit = 8192 } },
        .placeholder = placeholder,
        .multiline = multiline,
        .break_lines = multiline,
    }, .{
        .tag = tag,
        .expand = .both,
        .background = false,
        .border = dvui.Rect.all(0),
        .corners = style.radius.input,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
        .min_size_content = .{ .w = 0 },
        .max_size_content = .width(0),
        .font = style.small(),
    });
    const id = te.data().id;
    te.deinit();
    return id;
}

/// A small pill that opens a menu: icon, text, chevron.
fn pillFace(dd: *dvui.DropdownWidget, icon: []const u8, text: []const u8) void {
    var face = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .padding = .{ .x = style.space.sm, .w = style.space.xs },
    });
    defer face.deinit();
    dvui.icon(@src(), "pill_icon", icon, .{ .fill_color = .{ .color = style.textMuted() } }, .{
        .min_size_content = .{ .w = 11, .h = 11 },
        .gravity_y = 0.5,
        .margin = .{ .w = if (text.len > 0) style.space.xs else 0 },
    });
    if (text.len > 0) {
        dvui.label(@src(), "{s}", .{text}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textMuted() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }
    github_connect.dropAffordance(dd, style.textFaint());
}

fn pillInit(dd: *dvui.DropdownWidget, src: std.builtin.SourceLocation, tag: []const u8, margin: dvui.Rect) void {
    dd.init(src, .{}, .{
        .tag = tag,
        .min_size_content = .{ .h = 26 },
        .gravity_y = 0.5,
        .background = false,
        .margin = margin,
        .padding = dvui.Rect.all(0),
        .corners = style.radius.input,
    });
}

/// The conventional-commit type, `none` included.
fn commitTypeMenu(src: std.builtin.SourceLocation) void {
    var dd: dvui.DropdownWidget = undefined;
    pillInit(&dd, src, "commit_type", .{ .w = style.space.sm, .h = style.space.sm });
    pillFace(&dd, dvui.entypo.tag, if (app.commit_type) |t| COMMIT_TYPES[t] else "type");
    if (dd.dropped()) {
        if (dialog_views.dropChoice(&dd, dvui.entypo.cross, "none", "")) app.commit_type = null;
        for (COMMIT_TYPES, 0..) |name, i| {
            if (dialog_views.dropChoice(&dd, if (app.commit_type == i) dvui.entypo.check else dvui.entypo.dot_single, name, "")) app.commit_type = i;
        }
    }
    dd.deinit();
}

/// The scopes the history already uses, newest first.
fn scopeMenu(src: std.builtin.SourceLocation) void {
    const h = app.history orelse return;
    var dd: dvui.DropdownWidget = undefined;
    pillInit(&dd, src, "commit_scopes", .{ .x = style.space.sm, .h = style.space.sm });
    pillFace(&dd, dvui.entypo.list, "");
    if (dd.dropped()) {
        var seen: [24][]const u8 = undefined;
        var n: usize = 0;
        for (h.commits[0..@min(h.commits.len, 1000)]) |c| {
            const scope = summaryScope(c.summary) orelse continue;
            const had = for (seen[0..n]) |x| {
                if (std.mem.eql(u8, x, scope)) break true;
            } else false;
            if (had) continue;
            seen[n] = scope;
            n += 1;
            if (dialog_views.dropChoice(&dd, dvui.entypo.dot_single, scope, "")) {
                app.commit_scope.clearRetainingCapacity();
                app.commit_scope.appendSlice(app.gpa, scope) catch {};
            }
            if (n == seen.len) break;
        }
        if (n == 0) dialog_views.dropHeading(@src(), 0, "No scopes in the history yet");
    }
    dd.deinit();
}

/// The last messages committed here, to start from one again.
fn recentMessages(src: std.builtin.SourceLocation) void {
    const h = app.history orelse return;
    if (h.commits.len == 0) return;
    const p = pillMenu(src, "recent_messages", dvui.entypo.clock, .{ .w = style.space.md }, "Recent messages");
    defer p.end();
    const m = p.menu orelse return;
    dialog_views.dropHeading(@src(), 0, "RECENT MESSAGES");
    var list = app.pickList();
    defer list.deinit();
    var seen: [12][]const u8 = undefined;
    var n: usize = 0;
    for (h.commits[0..@min(h.commits.len, 200)]) |c| {
        if (c.summary.len == 0) continue;
        const had = for (seen[0..n]) |x| {
            if (std.mem.eql(u8, x, c.summary)) break true;
        } else false;
        if (had) continue;
        seen[n] = c.summary;
        n += 1;
        // Cut at a width, not the whole message: the menu would span the window.
        var fit: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
        if (app.pickRow(n, graph_view.fitText(&fit, c.summary, style.small(), 420), "", false, null)) {
            app.commit_summary.clearRetainingCapacity();
            app.commit_summary.appendSlice(app.gpa, c.summary) catch {};
            m.close();
        }
        if (n == seen.len) break;
    }
}

/// Everyone who has authored a commit here, to credit as a co-author.
fn coAuthorMenu(src: std.builtin.SourceLocation) void {
    const h = app.history orelse return;
    const p = pillMenu(src, "co_authors", dvui.entypo.add_user, .{ .w = style.space.xs }, "Add a co-author");
    defer p.end();
    const m = p.menu orelse return;
    dialog_views.dropHeading(@src(), 0, "ADD A CO-AUTHOR");
    var list = app.pickList();
    defer list.deinit();
    var seen: [30][]const u8 = undefined;
    var n: usize = 0;
    for (h.commits) |c| {
        if (c.email.len == 0) continue;
        const had = for (seen[0..n]) |x| {
            if (std.mem.eql(u8, x, c.email)) break true;
        } else false;
        if (had) continue;
        seen[n] = c.email;
        n += 1;
        if (app.pickRow(n, c.author, c.email, false, null)) {
            addCoAuthor(c.author, c.email);
            m.close();
        }
        if (n == seen.len) break;
    }
}

/// A pill whose menu drops as a select's does: under it, or over it where
/// the window has no room below — never on top of it. Its list scrolls past
/// a height.
fn pillMenu(src: std.builtin.SourceLocation, tag: []const u8, icon: []const u8, margin: dvui.Rect, hint: []const u8) app.Picker {
    var button = window_chrome.DropButton.begin(src, .{
        .tag = tag,
        .min_size_content = .{ .h = 26 },
        .gravity_y = 0.5,
        .background = false,
        .margin = margin,
        .padding = dvui.Rect.all(0),
        .corners = style.radius.input,
    });
    button.min_w = 280;
    {
        const lit = button.item.show_active or button.item.mouse_over;
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .color = if (lit) style.rowHover() else style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.sm, .w = style.space.xs },
        });
        defer face.deinit();
        dvui.icon(@src(), "pill_icon", icon, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 11, .h = 11 },
            .gravity_y = 0.5,
        });
        dvui.icon(@src(), "pill_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textFaint() } }, .{
            .min_size_content = .{ .w = 10, .h = 10 },
            .gravity_y = 0.5,
            .margin = .{ .x = 2 },
        });
    }
    // Said on hover while its menu is shut: its place read before `open`,
    // which is the end of the button.
    const r = button.item.data().borderRectScale().r;
    const menu = button.open();
    if (menu == null and r.contains(dvui.currentWindow().mouse_pt)) dvui.tooltip(@src(), .{ .active_rect = r, .position = .vertical, .delay = 400_000 }, "{s}", .{hint}, .{ .font = style.small() });
    return .{ .button = button, .menu = menu, .id = 0 };
}

/// One fact about the commit about to be made, as a chip: an icon and a word
/// in its colour, on a tint of it.
fn signalChip(src: std.builtin.SourceLocation, id: usize, icon: []const u8, text: []const u8, color: dvui.Color) void {
    var chip = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.tint(color) },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .min_size_content = .{ .h = 22 },
        .margin = .{ .x = style.space.xs },
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer chip.deinit();
    dvui.icon(@src(), "signal_icon", icon, .{ .fill_color = .{ .color = color } }, .{
        .min_size_content = .{ .w = 10, .h = 10 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    dvui.label(@src(), "{s}", .{text}, .{
        .font = style.tiny(),
        .color_text = .{ .color = color },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// The co-authors picked so far, each with its ×.
fn coAuthorChips() void {
    if (app.co_authors.items.len == 0) return;
    var flow = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .margin = .{ .h = style.space.sm } });
    defer flow.deinit();
    var removed: ?usize = null;
    for (app.co_authors.items, 0..) |who, i| {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .background = true,
            .color_fill = .{ .color = style.accentDim() },
            .corners = style.radius.tag,
            .padding = .{ .x = style.space.sm },
            .min_size_content = .{ .h = 22 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.xs, .h = style.space.xs },
        });
        defer chip.deinit();
        dvui.icon(@src(), "co_author_icon", dvui.entypo.user, .{ .fill_color = .{ .color = style.accent() } }, .{
            .min_size_content = .{ .w = 10, .h = 10 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.xs },
        });
        const name = who[0 .. std.mem.indexOf(u8, who, " <") orelse who.len];
        dvui.label(@src(), "{s}", .{name}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.accent() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
        if (dialog_views.iconButton(@src(), "co_author_remove", who, dvui.entypo.cross, style.accent())) removed = i;
    }
    if (removed) |i| app.gpa.free(app.co_authors.orderedRemove(i));
}
