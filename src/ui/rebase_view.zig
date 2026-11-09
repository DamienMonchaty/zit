const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const pr = @import("../github/pr.zig");
const syntax = @import("syntax.zig");
const github = @import("../github/github.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const diff_view = @import("diff_view.zig");
const commit_view = @import("commit_view.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const repo_settings = @import("repo_settings.zig");
const repo_io = @import("../core/repo_io.zig");
const github_actions = @import("../github/github_actions.zig");
const app = @import("../main.zig");

// === An operation under way ===
//
// What git keeps on disk while a merge, rebase, cherry-pick or revert waits
// on you, read into words: which branch, onto what, how far along, which
// commit it stopped on — and a conflict's two sides by their names rather
// than "ours" and "theirs", which a rebase turns round.

const OpInfo = struct {
    /// The branch a rebase replays, or the one a merge goes into.
    branch: []const u8 = "",
    /// Where a rebase replays onto: a branch's name where one points there.
    onto: []const u8 = "",
    /// 1-based, and how many in all; 0 where git keeps no count.
    step: u32 = 0,
    total: u32 = 0,
    /// The commit being applied, picked, reverted or merged in: short sha
    /// and subject.
    commit: []const u8 = "",
    subject: []const u8 = "",
    /// A conflict's two sides, as the conflict view names them.
    ours: []const u8 = "ours",
    theirs: []const u8 = "theirs",
    /// What "theirs" is mid-rebase: the commit being replayed.
    theirs_role: []const u8 = "",
};

pub var op_info: OpInfo = .{};
/// What `op_info`'s words live in; emptied each time it is read.
var op_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// Read with the history, which every step of an operation reads again.
pub fn readOpInfo() void {
    _ = op_arena.reset(.retain_capacity);
    op_info = .{};
    const r = app.repo orelse return;
    const h = app.history orelse return;
    const a = op_arena.allocator();
    const head = a.dupe(u8, h.head orelse "HEAD") catch "HEAD";
    switch (h.state) {
        .rebase => {
            const dir: []const u8 = if (gitText(a, r, "rebase-merge/head-name") != null) "rebase-merge/" else "rebase-apply/";
            const merge_backend = std.mem.eql(u8, dir, "rebase-merge/");
            if (gitTextIn(a, r, dir, "head-name")) |t| op_info.branch = git.headName(t) orelse "";
            if (gitTextIn(a, r, dir, "onto")) |t| if (git.oidFromHex(t[0..@min(40, t.len)])) |id| {
                op_info.onto = refNameAt(a, id);
            };
            op_info.step = gitNumber(a, r, dir, if (merge_backend) "msgnum" else "next");
            op_info.total = gitNumber(a, r, dir, if (merge_backend) "end" else "last");
            if (gitText(a, r, "REBASE_HEAD") orelse gitTextIn(a, r, dir, "stopped-sha")) |t| setOpCommit(a, r, t);
            op_info.ours = if (op_info.onto.len > 0) op_info.onto else "the base";
            op_info.theirs = if (op_info.branch.len > 0) op_info.branch else if (op_info.commit.len > 0) op_info.commit else "your commit";
            op_info.theirs_role = if (op_info.commit.len > 0)
                std.fmt.allocPrint(a, "your commit {s}, replayed", .{op_info.commit}) catch "your commit, replayed"
            else
                "your commit, replayed";
        },
        .merge => {
            op_info.branch = head;
            if (gitText(a, r, "MERGE_HEAD")) |t| setOpCommit(a, r, t);
            const source = if (gitText(a, r, "MERGE_MSG")) |m| git.mergeSource(m) else null;
            op_info.ours = head;
            op_info.theirs = source orelse if (op_info.commit.len > 0) op_info.commit else "theirs";
        },
        .cherrypick, .revert => {
            op_info.branch = head;
            if (gitText(a, r, if (h.state == .cherrypick) "CHERRY_PICK_HEAD" else "REVERT_HEAD")) |t| setOpCommit(a, r, t);
            op_info.ours = head;
            op_info.theirs = if (op_info.commit.len > 0) op_info.commit else "theirs";
        },
        else => {},
    }
}

/// A small file git keeps under the repository's git directory, trimmed;
/// null when it is not there.
fn gitText(a: std.mem.Allocator, r: git.Repo, rel: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ r.gitdir(), rel }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(app.app_io, p, a, .limited(64 * 1024)) catch return null;
    return std.mem.trim(u8, text, " \t\r\n");
}

fn gitTextIn(a: std.mem.Allocator, r: git.Repo, dir: []const u8, name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const rel = std.fmt.bufPrint(&buf, "{s}{s}", .{ dir, name }) catch return null;
    return gitText(a, r, rel);
}

fn gitNumber(a: std.mem.Allocator, r: git.Repo, dir: []const u8, name: []const u8) u32 {
    const t = gitTextIn(a, r, dir, name) orelse return 0;
    return std.fmt.parseInt(u32, t, 10) catch 0;
}

/// The commit an operation is on, from the sha git wrote: short, with its
/// subject.
fn setOpCommit(a: std.mem.Allocator, r: git.Repo, text: []const u8) void {
    const id = git.oidFromHex(text[0..@min(40, text.len)]) orelse return;
    var short: [8]u8 = undefined;
    op_info.commit = a.dupe(u8, git.oidShort(id, &short)) catch "";
    const message = r.commitMessage(a, id);
    op_info.subject = message[0 .. std.mem.indexOfScalar(u8, message, '\n') orelse message.len];
}

/// A branch's name where one points at `id` — a local one first — else its
/// short sha.
fn refNameAt(a: std.mem.Allocator, id: git.Oid) []const u8 {
    const h = app.history orelse return "";
    var remote: ?[]const u8 = null;
    for (h.refs) |ref| {
        if (!git.oidEql(ref.target, id)) continue;
        if (ref.kind == .local) return a.dupe(u8, ref.name) catch "";
        if (ref.kind == .remote and remote == null) remote = ref.name;
    }
    if (remote) |n| return a.dupe(u8, n) catch "";
    var short: [8]u8 = undefined;
    return a.dupe(u8, git.oidShort(id, &short)) catch "";
}

/// A conflict's sides as the conflict view says them: whose, and what that
/// side is. During a rebase "ours" is the base and "theirs" your own commit,
/// the reverse of what the words suggest.
const SideNames = struct { ours: []const u8, theirs: []const u8, ours_role: []const u8, theirs_role: []const u8 };

pub fn sideNames() SideNames {
    const h = app.history orelse return .{ .ours = "ours", .theirs = "theirs", .ours_role = "already on this branch", .theirs_role = "coming in" };
    return switch (h.state) {
        .rebase => .{ .ours = op_info.ours, .theirs = op_info.theirs, .ours_role = "the base, rebased onto", .theirs_role = op_info.theirs_role },
        .merge => .{ .ours = op_info.ours, .theirs = op_info.theirs, .ours_role = "your branch", .theirs_role = "merging in" },
        .cherrypick => .{ .ours = op_info.ours, .theirs = op_info.theirs, .ours_role = "your branch", .theirs_role = "being picked" },
        .revert => .{ .ours = op_info.ours, .theirs = op_info.theirs, .ours_role = "your branch", .theirs_role = "the revert" },
        else => .{ .ours = "ours", .theirs = "theirs", .ours_role = "already on this branch", .theirs_role = "coming in" },
    };
}

/// True when this click lands on the same widget as the previous one, soon
/// enough to count as a double.
pub fn isDoubleClick(id: dvui.Id) bool {
    const now = dvui.frameTimeNS();
    const same = app.last_click_id != null and app.last_click_id.? == id;
    const quick = now - app.last_click_ns <= app.DOUBLE_CLICK_NS;

    app.last_click_id = id;
    app.last_click_ns = now;

    // Reset, so a third click does not read as another double.
    if (same and quick) {
        app.last_click_id = null;
        return true;
    }
    return false;
}

/// One fold-away group of refs. Returns the ref the user asked to check out.
pub fn sidebarSection(src: std.builtin.SourceLocation, section: diff_view.Section, id: usize) ?git.Ref {
    // Only on a host that has them.
    if ((section == .pulls or section == .issues) and pr.host == .none) return null;
    const collapsed = &diff_view.section_collapsed[@backingInt(section)];

    const count: usize = blk: {
        const h = app.history orelse break :blk 0;
        break :blk switch (section) {
            .stashes => h.stashes.len,
            .remotes => h.remotes.len,
            .worktrees => h.worktrees.len,
            .pulls => pr.list.len,
            .issues => pr.issues.len,
            else => h.refCount(section.refKind().?),
        };
    };

    // The header, as GitComet draws its sections': a chevron, the section's
    // icon and its name in the text's own colour, a line over it parting it
    // from the section above — no count, nothing that comes and goes on hover
    // but the ⋯ at the end, for the right-click menu. Hiding a whole section
    // from the graph is in that menu.
    var head = dvui.box(src, .{ .dir = .horizontal }, .{ .id_extra = id, .tag = dialog_views.frameTag("section", section.label()), .expand = .horizontal, .background = false });
    const header_rect = head.data().borderRectScale().r;
    const head_hover = header_rect.contains(dvui.currentWindow().mouse_pt);
    const eye_kind: ?git.Ref.Kind = section.refKind() orelse (if (section == .remotes) git.Ref.Kind.remote else null);
    const refs_shown: ?bool = if (eye_kind) |k| sectionShown(k) else null;
    // Every ref in it out of the graph: said by fading the name, as a ref out
    // of the graph is faded, and by a crossed eye after it, as GitComet marks
    // a remote it hides.
    const all_hidden = if (refs_shown) |shown| !shown else false;
    // The hover across the whole line, ⋯ included: drawn by hand, as the ref
    // lines' are.
    if (head_hover) header_rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = commit_view.SECTION_HEAD_H },
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    bw.processEvents();

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = false,
            .padding = .{ .x = style.space.md },
        });
        defer row.deinit();

        commit_view.sectionFace(collapsed.*, section.title(), all_hidden);
        if (all_hidden) dvui.icon(@src(), "section_hidden", identity_view.eyeIcon(true), .{ .fill_color = .{ .color = style.textFaint() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.sm },
        });
    }

    var clicked = bw.clicked();
    bw.deinit();

    // The ⋯, in the column the ref lines' ⋯ take, kept and only seen on hover
    // so nothing moves. Clicks right of it fold the section as the rest does.
    var more_at: ?dvui.Point.Physical = null;
    {
        var tail = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .vertical,
            .background = false,
            .padding = .{ .w = SIDE_RIGHT - style.space.xs },
        });
        defer tail.deinit();
        if (dialog_views.iconButtonTagged(@src(), "section_more", "More…", dvui.entypo.dots_three_horizontal, if (head_hover) style.textMuted() else dvui.Color.transparent, dialog_views.frameTag("section-more", section.label()))) {
            more_at = dvui.currentWindow().mouse_pt;
        }
        if (dvui.clicked(tail.data(), .{})) clicked = true;
    }
    if (clicked) collapsed.* = !collapsed.*;
    head.deinit();

    sectionMenu(@src(), section, id, header_rect, more_at, if (refs_shown) |shown| .{ .kind = eye_kind.?, .shown = shown } else null);

    // A filter opens the sections it searches: a match folded away is a
    // match not found.
    const lists_refs = section.refKind() != null or section == .remotes;
    if (collapsed.* and !(lists_refs and sidebarFiltering())) return null;

    const h = app.history orelse return null;
    if (count == 0) if (section.empty()) |note| {
        // One per empty section, each its own: the note's widgets are made
        // at one place in the code for all of them.
        var line = dvui.box(@src(), .{}, .{ .id_extra = id, .expand = .horizontal, .background = false });
        defer line.deinit();
        sidebarNote(@src(), note);
        return null;
    };

    // Open, a section scrolls within a height of its own, as GitKraken's
    // do: a hundred branches do not push the sections under them away. Sized
    // on what it held last frame — a scroll area takes no height from what
    // it holds.
    const si = &section_scroll[@backingInt(section)];
    const height = @min(SECTION_MAX_H, si.virtual_size.h);
    var list = dvui.scrollArea(@src(), .{ .scroll_info = si }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = height },
        .max_size_content = .height(height),
        .background = false,
    });
    const chosen = sectionRows(section, id, h, si);
    list.deinit();
    if (@min(SECTION_MAX_H, si.virtual_size.h) != height) dvui.refresh(null, @src(), null);
    return chosen;
}

/// Whether any ref of `kind` is in the graph; null when there are none
/// but the branch checked out, which no eye hides.
fn sectionShown(kind: git.Ref.Kind) ?bool {
    const h = app.history orelse return null;
    var any = false;
    for (h.refs) |ref| {
        if (ref.kind != kind or ref.head) continue;
        any = true;
        if (!graph_view.isHidden(ref.name)) return true;
    }
    return if (any) false else null;
}

/// Every ref of `kind` out of the graph, or back in; the branch checked out
/// stays in.
///
/// ponytail: one `git config` per ref, as toggling one does. A batch write of
/// `zit.hidden` if a repository with thousands of tags makes it slow.
fn hideAll(kind: git.Ref.Kind, hide: bool) void {
    const h = app.history orelse return;
    // Named first, owned: in tests each toggle reads the history again, and
    // the refs these point into go with the old one.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| app.gpa.free(n);
        names.deinit(app.gpa);
    }
    for (h.refs) |ref| {
        if (ref.kind != kind or ref.head) continue;
        // A local branch's remote copy with it, as its own eye does.
        const upstream = if (kind == .local) ref.tracking.upstream else null;
        for ([_]?[]const u8{ ref.name, upstream }) |maybe| {
            const name = maybe orelse continue;
            if (graph_view.isHidden(name) == hide or graph_view.hasName(names.items, name)) continue;
            const owned = app.gpa.dupe(u8, name) catch continue;
            names.append(app.gpa, owned) catch app.gpa.free(owned);
        }
    }
    for (names.items) |n| graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", n);
}

const SECTION_MAX_H: f32 = 300;

// The sidebar's columns. Every line's text starts where its section's title
// does — past the header's chevron — a remote's branches one step
// further in, and nothing reaches the scroll bar on the right.
/// Where a section title's text starts: the header's left padding, chevron,
/// gap.
pub const SIDE_TEXT_X: f32 = style.space.md + 12 + SECTION_CHEVRON_GAP;
pub const SECTION_CHEVRON_GAP: f32 = style.space.sm + style.space.xs;
/// One level in: a remote's branches under it.
pub const SIDE_NEST: f32 = style.space.lg;
/// Kept clear on the right, for a section's scroll bar.
pub const SIDE_RIGHT: f32 = style.space.xl;
/// The gutter left of a ref's name: the eye, or the current branch's tick.
pub const SIDE_GUTTER: f32 = 22 + 2 * style.space.xxs;
/// Inside a ref line's button, before its name.
pub const SIDE_REF_PAD: f32 = style.space.xs;
const SECTION_ICON_LIFT: f32 = 4;
pub var section_scroll: [@typeInfo(diff_view.Section).@"enum".field_names.len]dvui.ScrollInfo = @splat(.{});

/// An open section's rows. Returns the ref the user asked to check out.
fn sectionRows(section: diff_view.Section, id: usize, h: git.History, si: *const dvui.ScrollInfo) ?git.Ref {
    // The three sections that list something other than a ref never reach the
    // loop below.
    if (section == .stashes) {
        for (h.stashes, 0..) |entry, i| app.stashRow(@src(), entry, id * 1000 + i);
        return null;
    }
    if (section == .remotes) {
        var items: std.ArrayList(SideItem) = .empty;
        for (h.remotes, 0..) |entry, i| {
            items.append(dvui.currentWindow().arena(), .{ .remote = @intCast(i) }) catch return null;
            // Pinned ones first, as in the other sections.
            for (0..2) |pass| for (h.refs, 0..) |ref, r| {
                if (ref.kind != .remote or !std.mem.eql(u8, github_actions.splitRemoteRef(ref.name).remote, entry.name)) continue;
                if (!sidebarMatches(ref.name)) continue;
                if (graph_view.hasName(graph_view.graph_pinned.items, ref.name) != (pass == 0)) continue;
                items.append(dvui.currentWindow().arena(), .{ .ref = @intCast(r) }) catch return null;
            };
        }
        return sideRows(items.items, h, si);
    }
    if (section == .worktrees) {
        for (h.worktrees, 0..) |entry, i| app.worktreeRow(@src(), entry, id * 1000 + i);
        return null;
    }
    if (section == .pulls) {
        switch (pr.status) {
            .loading => if (pr.list.len == 0) sidebarNote(@src(), "Loading…"),
            .failed => requestsError(),
            .ready => if (pr.list.len == 0) sidebarNote(@src(), "None open."),
            .idle => {},
        }
        for (pr.list, 0..) |entry, i| app.requestRow(@src(), entry, id * 1000 + i);
        return null;
    }
    if (section == .issues) {
        switch (pr.issues_status) {
            .loading => if (pr.issues.len == 0) sidebarNote(@src(), "Loading…"),
            .failed => sidebarNote(@src(), if (pr.issues_error.items.len > 0) pr.issues_error.items else "Could not list them."),
            .ready => if (pr.issues.len == 0) sidebarNote(@src(), "None open."),
            .idle => {},
        }
        for (pr.issues, 0..) |entry, i| app.issueRow(@src(), entry, id * 1000 + i);
        return null;
    }

    const kind = section.refKind() orelse return null;

    var items: std.ArrayList(SideItem) = .empty;
    // Pinned ones first, then the rest.
    for (0..2) |pass| {
        for (h.refs, 0..) |ref, r| {
            if (ref.kind != kind) continue;
            if (!sidebarMatches(ref.name)) continue;
            if (graph_view.hasName(graph_view.graph_pinned.items, ref.name) != (pass == 0)) continue;
            items.append(dvui.currentWindow().arena(), .{ .ref = @intCast(r) }) catch return null;
        }
    }
    return sideRows(items.items, h, si);
}

/// One line of a section that lists refs: a remote's heading, or a ref.
const SideItem = union(enum) { remote: u32, ref: u32 };

/// A section's lines, only those its scroll area shows built, as the graph
/// does: every line is `style.side_row` high, so where each one sits is
/// arithmetic, and spacers stand for the rest. Returns the ref asked to be
/// checked out.
fn sideRows(items: []const SideItem, h: git.History, si: *const dvui.ScrollInfo) ?git.Ref {
    const rh = style.side_row;
    // Before the area has a height — its first frame — as many as it can show.
    const view_h = if (si.viewport.h > 0) si.viewport.h else SECTION_MAX_H;
    const first = @min(items.len, @as(usize, @intFromFloat(@max(0, si.viewport.y) / rh)) -| 1);
    const last = @min(items.len, first + @as(usize, @intFromFloat(@ceil(view_h / rh))) + 2);
    if (first > 0) _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = @as(f32, @floatFromInt(first)) * rh } });

    var chosen: ?git.Ref = null;
    for (items[first..last], first..) |item, i| switch (item) {
        .remote => |r| remoteRow(@src(), h.remotes[r], i),
        // Its own `@src()`: the section's header uses the caller's.
        .ref => |r| if (app.refRow(@src(), h.refs[r], i)) {
            chosen = h.refs[r];
        },
    };

    if (last < items.len) _ = dvui.spacer(@src(), .{ .id_extra = 1, .min_size_content = .{ .h = @as(f32, @floatFromInt(items.len - last)) * rh } });
    return chosen;
}

/// What the sidebar's branches and tags are narrowed to.
pub var sidebar_filter: std.ArrayList(u8) = .empty;

pub fn sidebarFiltering() bool {
    return std.mem.trim(u8, sidebar_filter.items, " ").len > 0;
}

/// Whether `name` passes the sidebar's filter: case aside, it contains it.
pub fn sidebarMatches(name: []const u8) bool {
    const needle = std.mem.trim(u8, sidebar_filter.items, " ");
    return needle.len == 0 or std.ascii.findIgnoreCase(name, needle) != null;
}

/// Whether `branch` ("origin/main") belongs to the remote `name`.
pub fn remoteOf(branch: []const u8, name: []const u8) bool {
    return branch.len > name.len and std.mem.startsWith(u8, branch, name) and branch[name.len] == '/';
}

/// The stash a row's apply or pop button asked for, kept until the frame ends.
pub var stash_pending: [40]u8 = undefined;
pub var stash_verb: []const u8 = "apply";

pub fn requestStash(verb: []const u8, id: git.Oid) void {
    if (repo_io.action != .none) return;
    var hex: [41]u8 = undefined;
    @memcpy(&stash_pending, git.oidHex(id, &hex)[0..40]);
    stash_verb = verb;
    repo_io.action = .stash;
}

/// `git stash <verb>` on the stash whose commit is `hex`. Held by its commit
/// rather than `stash@{n}`, because a stash pushed or dropped since the list
/// was read — in a terminal, say, which no reflog of HEAD records — moves
/// every index; `pop` and `drop` take only `stash@{n}`, so the index is looked
/// up again now — by libgit2, with no `git` to wait for. The command itself
/// runs as a job: applying a stash rewrites the working tree.
pub fn stashDo(verb: []const u8, hex: []const u8) void {
    const r = app.repo orelse return;
    const id = git.oidFromHex(hex) orelse return github_actions.setCommandError("That stash is gone already.");
    const index = r.stashIndex(id) orelse return github_actions.setCommandError("That stash is gone already.");
    // `stash@{n}`: the only name `pop` and `drop` take.
    var ref_buf: [32]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buf, "stash@{{{d}}}", .{index}) catch unreachable;
    const label = if (std.mem.eql(u8, verb, "pop")) "Popping the stash" else if (std.mem.eql(u8, verb, "drop")) "Dropping the stash" else "Applying the stash";
    github_actions.startLocal(label, &.{ "stash", verb, ref }, .local);
}

/// What a section header offers that its rows cannot: the things that create
/// rather than act on something already listed.
fn sectionMenu(
    src: std.builtin.SourceLocation,
    section: diff_view.Section,
    id: usize,
    rect: dvui.Rect.Physical,
    /// Where the header's ⋯ was clicked, to open there as a right-click would.
    open_at: ?dvui.Point.Physical,
    /// The refs it can take out of the graph or bring back, all at once.
    hide: ?struct { kind: git.Ref.Kind, shown: bool },
) void {
    const ctx = dvui.context(src, .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();
    app.openContextAt(ctx, open_at);

    const cp = ctx.activePoint() orelse return;

    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();

    switch (section) {
        .local => {
            if (graph_view.menuIcon(@src(), dvui.entypo.flow_branch, "New branch here", false)) {
                fw.close();
                github_actions.askName(.new_branch, "");
            }
        },
        .tags => {
            if (graph_view.menuIcon(@src(), dvui.entypo.tag, "New tag here", false)) {
                fw.close();
                github_actions.askName(.new_tag, "");
            }
        },
        .remotes => {
            if (graph_view.menuIcon(@src(), dvui.entypo.plus, "Add a remote", false)) {
                fw.close();
                github_actions.askName(.add_remote, "");
            }
            if (graph_view.menuIcon(@src(), dvui.entypo.cw, "Fetch them all", false)) {
                fw.close();
                repo_io.requestNetwork("Fetching", tab_strip.fetchAllArgs(false));
            }
        },
        .pulls => {
            if (graph_view.menuIcon(@src(), dvui.entypo.merge, "Create a pull request for this branch", false)) {
                fw.close();
                requestCreateRequest();
            }
            if (graph_view.menuIcon(@src(), dvui.entypo.globe, "Open the repository on the web", false)) {
                fw.close();
                github_actions.openOnGithub("", .{});
            }
            if (graph_view.menuIcon(@src(), dvui.entypo.ccw, "Refresh the list", false)) {
                fw.close();
                repo_io.refreshRequests();
            }
        },
        .issues => {
            if (graph_view.menuIcon(@src(), dvui.entypo.plus, "File a new issue", false)) {
                fw.close();
                github_actions.openOnGithub("/issues/new", .{});
            }
            if (graph_view.menuIcon(@src(), dvui.entypo.globe, "Open the issues on the web", false)) {
                fw.close();
                github_actions.openOnGithub("/issues", .{});
            }
            if (graph_view.menuIcon(@src(), dvui.entypo.ccw, "Refresh the list", false)) {
                fw.close();
                pr.refreshIssues(app.repo_path.items);
            }
        },
        .worktrees => {
            if (graph_view.menuIcon(@src(), dvui.entypo.folder, "Add a worktree", false)) {
                fw.close();
                github_actions.askName(.add_worktree, "");
            }
        },
        // The toolbar's Stash takes no name; this is the one that does.
        .stashes => {
            if (graph_view.menuIcon(@src(), dvui.entypo.save, "Stash everything, with a message", false)) {
                fw.close();
                github_actions.askName(.stash, "");
            }
        },
    }

    // The whole section out of the graph, or back: the eye the header had.
    if (hide) |hd| {
        graph_view.menuSeparator(90);
        const what = switch (hd.kind) {
            .local => "branches",
            .remote => "remote branches",
            .tag => "tags",
        };
        var buf: [64]u8 = undefined;
        const caption = std.fmt.bufPrint(&buf, "{s} all the {s} {s} the graph", .{ if (hd.shown) "Hide" else "Show", what, if (hd.shown) "from" else "in" }) catch "";
        if (graph_view.menuIcon(@src(), identity_view.eyeIcon(hd.shown), caption, false)) {
            fw.close();
            hideAll(hd.kind, hd.shown);
        }
    }
}

/// One remote: what it is called, where it points, and the two things worth
/// doing to it from a sidebar.
fn remoteRow(src: std.builtin.SourceLocation, entry: git.Remote, id: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .max_size_content = .height(style.side_row),
        .background = false,
        .padding = .{ .x = SIDE_TEXT_X, .w = SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();
    const row_rect = row.data().borderRectScale().r;
    const hover = row_rect.contains(dvui.currentWindow().mouse_pt);
    if (hover) row_rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });

    dvui.label(@src(), "{s}", .{entry.name}, .{
        .font = style.small(),
        .color_text = .{ .color = style.text() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });

    dvui.label(@src(), "{s}", .{entry.url}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });

    // Its four actions on hover only, as a branch's eye and ⋯ are: the
    // line reads as a heading the rest of the time.
    if (hover) {
        if (dialog_views.iconButton(@src(), "remote_fetch", "Fetch from this remote", dvui.entypo.cw, style.textMuted())) {
            repo_io.requestNetwork("Fetching", if (tab_strip.prune_on_fetch) &.{ "fetch", "--prune", entry.name } else &.{ "fetch", entry.name });
        }
        if (dialog_views.iconButton(@src(), "remote_rename", "Rename this remote", dvui.entypo.pencil, style.textFaint())) {
            github_actions.askNameWith(.rename_remote, entry.name, entry.name);
        }
        if (dialog_views.iconButton(@src(), "remote_url", "Change its URL", dvui.entypo.link, style.textFaint())) {
            github_actions.askNameWith(.remote_url, entry.name, entry.url);
        }
        // Removing a remote drops config, never commits, so it does not ask.
        if (dialog_views.iconButton(@src(), "remote_remove", "Remove this remote", dvui.entypo.cross, style.textFaint())) {
            repo_io.request(&.{ "remote", "remove", entry.name });
        }
    }
}

/// Why the listing failed, in GitHub's own words when it gave any.
pub fn requestsError() void {
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{ .x = SIDE_TEXT_X, .y = style.space.xs, .w = SIDE_RIGHT, .h = style.space.xs },
    });
    defer line.deinit();
    // Not connected yet: the one thing to do.
    if (!github.signedIn()) {
        dvui.label(@src(), "Not connected to GitHub.", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        if (dialog_views.linkButton(@src(), "Connect", style.accent())) app.openConnect();
        return;
    }
    // GitHub's answer for a private repository Zit has not been let into:
    // its organisation restricts apps until an owner approves this one.
    if (std.mem.indexOf(u8, pr.last_error.items, "Could not resolve to a Repository") != null) {
        dvui.label(@src(), "Private, and its organisation has not approved Zit yet.", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
        if (dialog_views.linkButton(@src(), "Ask for access", style.accent())) github_actions.openUrl("https://github.com/settings/connections/applications/" ++ github.CLIENT_ID);
        return;
    }
    dvui.label(@src(), "{s}", .{if (pr.last_error.items.len > 0) pr.last_error.items else "Could not list them."}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.danger() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = dvui.Rect.all(0),
    });
    // The token turned down: only connecting again mends that.
    if (std.mem.startsWith(u8, pr.last_error.items, "GitHub no longer accepts")) {
        if (dialog_views.linkButton(@src(), "Connect", style.accent())) app.openConnect();
        return;
    }
    if (dialog_views.linkButton(@src(), "Try again", style.accent())) repo_io.refreshRequests();
}

pub fn sidebarNote(src: std.builtin.SourceLocation, text: []const u8) void {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{ .background = false, .padding = .{ .x = SIDE_TEXT_X, .y = style.space.xs, .w = SIDE_RIGHT, .h = style.space.xs } });
    defer line.deinit();
    if (std.mem.startsWith(u8, text, "Loading")) loadingSpinner(@src());
    dvui.label(@src(), "{s}", .{text}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// Three dots, lit one after the other, five steps a second. Not dvui's
/// spinner: it turns every frame, which is the display's rate for as long
/// as anything is loading.
pub fn loadingSpinner(src: std.builtin.SourceLocation) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false, .margin = .{ .w = style.space.sm } });
    defer row.deinit();
    const step: usize = @intCast(@mod(@divTrunc(dvui.frameTimeNS(), 200 * std.time.ns_per_ms), 3));
    for (0..3) |i| {
        var dot = dvui.box(@src(), .{}, .{
            .id_extra = i,
            .background = true,
            .color_fill = .{ .color = style.accent().opacity(if (i == step) 1 else 0.3) },
            .corners = .all(2),
            .min_size_content = .{ .w = 4, .h = 4 },
            .max_size_content = .size(.{ .w = 4, .h = 4 }),
            .gravity_y = 0.5,
            .margin = .{ .w = 2 },
        });
        dot.deinit();
    }
    repo_io.animateEvery(row.data().id, 200);
}

/// The form for a new request, filled from the commits.
pub fn requestCreateRequest() void {
    if (pr.host == .none) return github_actions.setCommandError("No pull requests here: the repository is on no host Zit knows, or the integrations are off in the settings.");
    app.openPrCreate();
}

// === Centre: the interactive rebase composer ===

/// A row asking to swap places with another.
const Move = struct { from: usize, to: usize };

/// The todo list, before it is a todo list.
///
/// It takes the graph's place like the diff pane does, and shows the commits
/// newest first for the same reason the graph does — so the row you clicked is
/// where you left it.
pub fn rebasePanel() void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    defer panel.deinit();

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .min_size_content = .{ .h = style.toolbar_cell },
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.borderSubtle() },
            .padding = .{ .x = style.space.xs, .w = style.space.md },
        });
        defer head.deinit();

        if (dialog_views.iconButton(@src(), "rebase_close", "Back to the graph — Esc", dvui.entypo.chevron_small_left, style.textMuted())) {
            app.clearSelection();
        }

        dvui.label(@src(), "Replay {d} commit{s} onto {s}", .{
            app.rebase_steps.items.len,
            window_chrome.plural(app.rebase_steps.items.len),
            if (app.rebase_root) "the root" else app.rebase_base[0..@min(app.rebase_base_len, 7)],
        }, .{
            .font = style.smallBold(),
            .color_text = .{ .color = style.text() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs },
            .padding = dvui.Rect.all(0),
        });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        dvui.label(@src(), "click an action to change it", .{}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.md },
            .padding = dvui.Rect.all(0),
        });

        if (dialog_views.linkButton(@src(), "Start rebase", style.accent())) repo_io.requestAction(.rebase);
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer scroll.deinit();

    // Collected, not applied in place: swapping inside the loop would re-render
    // a row that has already been drawn this frame, at its new index.
    var move: ?Move = null;
    for (app.rebase_steps.items, 0..) |_, i| {
        if (rebaseRow(@src(), i)) |m| move = m;
    }

    if (move) |m| {
        std.mem.swap(git.RebaseStep, &app.rebase_steps.items[m.from], &app.rebase_steps.items[m.to]);
    }
}

/// The next action in the cycle a click walks through.
///
/// `reword` is not in it: it needs a message editor mid-rebase, and the
/// `core.editor=true` that keeps a squash from hanging would silently keep the
/// old message instead — a button that looks like it worked and did nothing.
fn nextRebaseAction(current: git.RebaseAction) git.RebaseAction {
    return switch (current) {
        .pick => .squash,
        .squash => .fixup,
        .fixup => .drop,
        .drop, .reword => .pick,
    };
}

fn rebaseActionColor(kind: git.RebaseAction) dvui.Color {
    return switch (kind) {
        .pick => style.text(),
        .squash, .fixup => style.accent(),
        .drop => style.danger(),
        .reword => style.textMuted(),
    };
}

fn rebaseRow(src: std.builtin.SourceLocation, index: usize) ?Move {
    const step = app.rebase_steps.items[index];

    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = index,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.toolbar_cell },
        .background = index % 2 == 1,
        .color_fill = .{ .color = style.rowHover() },
        .padding = .{ .x = style.space.md, .w = style.space.md },
    });
    defer row.deinit();

    var sha_buf: [8]u8 = undefined;
    dvui.label(@src(), "{s}", .{git.oidShort(step.id, &sha_buf)}, .{
        .font = style.mono(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });

    dvui.label(@src(), "{s}", .{step.summary}, .{
        .font = style.small(),
        // A dropped commit is struck out of the plan, so it reads as gone.
        .color_text = .{ .color = if (step.action == .drop) style.textFaint() else style.text() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });

    dvui.label(@src(), "{s}", .{step.action.hint()}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .padding = dvui.Rect.all(0),
    });

    if (dialog_views.linkButton(@src(), step.action.verb(), rebaseActionColor(step.action))) {
        app.rebase_steps.items[index].action = nextRebaseAction(step.action);
    }

    // Up and down are in graph order, which is the reverse of replay order —
    // moving a row up here moves it later in the rebase, and that is what the
    // person looking at the graph means.
    var move: ?Move = null;
    if (index > 0) {
        if (dialog_views.iconButton(@src(), "rebase_up", "Move up", dvui.entypo.chevron_small_up, style.textMuted())) {
            move = .{ .from = index, .to = index - 1 };
        }
    }
    if (index + 1 < app.rebase_steps.items.len) {
        if (dialog_views.iconButton(@src(), "rebase_down", "Move down", dvui.entypo.chevron_small_down, style.textMuted())) {
            move = .{ .from = index, .to = index + 1 };
        }
    }
    return move;
}

pub fn isConflictView() bool {
    return switch (app.selection) {
        .change => |side| app.selectedStatus(side) == .conflicted,
        else => false,
    };
}

/// The three-pane merge: each conflict's two sides next to each other on top,
/// and underneath, the file they are being resolved into.
pub fn conflictBody() void {
    // A binary file, or one deleted on a side, has nothing to read in an
    // output pane: its question takes the whole of it.
    if (app.wholeFileConflict()) return conflictRegions();
    var split = dvui.paned(@src(), .{
        .direction = .vertical,
        .collapsed_size = 360,
        .split_ratio = &app.output_split,
        .handle_size = 1,
        .draw_in_deinit = false,
    }, .{ .expand = .both, .background = false });
    defer split.deinit();

    if (split.showFirst()) conflictRegions();
    if (split.showSecond()) conflictOutput();
}

/// Most lines of the output pane drawn.
///
/// ponytail: a cap, not virtualised rows like the diff. Past it, "Open this
/// file" is the better place to read the result anyway.
const MAX_OUTPUT_LINES: usize = 3000;

/// The file as resolving will leave it: everything outside the regions as it
/// is, and each region not yet answered marked as the hole it still is.
fn conflictOutput() void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
        .border = .{ .y = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer pane.deinit();

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .min_size_content = .{ .h = style.toolbar_cell },
            .padding = .{ .x = style.space.md, .w = style.space.md },
        });
        defer head.deinit();
        dvui.label(@src(), "OUTPUT", .{}, .{
            .font = style.section(),
            .color_text = .{ .color = style.textMuted() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
        dvui.label(@src(), "{d} conflict{s} left", .{ app.conflicts.len, window_chrome.plural(app.conflicts.len) }, .{
            .font = style.tiny(),
            .color_text = .{ .color = if (app.conflicts.len == 0) style.success() else style.textFaint() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.md },
            .padding = dvui.Rect.all(0),
        });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.linkButton(@src(), "Open this file", style.textMuted())) commit_view.openPath(app.selected_path.items);
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();

    var line_no: usize = 0;
    var at: usize = 0;
    var region: usize = 0;
    while (at < app.conflict_text.len and line_no < MAX_OUTPUT_LINES) {
        if (region < app.conflicts.len and at == app.conflicts[region].start) {
            outputLine(@src(), line_no, null, region);
            at = app.conflicts[region].end;
            region += 1;
            line_no += 1;
            continue;
        }
        const stop = if (region < app.conflicts.len) app.conflicts[region].start else app.conflict_text.len;
        const end = std.mem.indexOfScalarPos(u8, app.conflict_text, at, '\n') orelse app.conflict_text.len;
        const line_end = @min(end, stop);
        outputLine(@src(), line_no, app.conflict_text[at..line_end], 0);
        line_no += 1;
        at = if (line_end == end) end + 1 else line_end;
    }
    if (at < app.conflict_text.len) {
        dvui.label(@src(), "… the rest is not shown — Open this file to read it all", .{}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .padding = .{ .x = style.space.md, .y = style.space.sm },
        });
    }
}

/// One line of the output, or — with no text — the marker for an unanswered
/// region.
fn outputLine(src: std.builtin.SourceLocation, n: usize, text: ?[]const u8, region: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = n,
        .expand = .horizontal,
        .background = text == null,
        .color_fill = .{ .color = style.get().yellow.lerp(style.background(), 0.85) },
        .padding = .{ .x = style.space.md, .w = style.space.md },
    });
    defer row.deinit();

    var buf: [16]u8 = undefined;
    dvui.label(@src(), "{s}", .{std.fmt.bufPrint(&buf, "{d}", .{n + 1}) catch ""}, .{
        .font = style.mono(),
        .color_text = .{ .color = style.textFaint() },
        .min_size_content = .{ .w = 40 },
        .padding = dvui.Rect.all(0),
    });
    if (text) |t| {
        var tab_buf: [MAX_SHOWN_LINE]u8 = undefined;
        dvui.label(@src(), "{s}", .{detab(&tab_buf, t)}, .{
            .font = style.mono(),
            .color_text = .{ .color = style.text() },
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
    } else {
        dvui.label(@src(), "conflict {d}: pick a side above — click to go to it", .{region + 1}, .{
            .font = style.mono(),
            .color_text = .{ .color = style.get().yellow },
            .padding = dvui.Rect.all(0),
        });
        if (row.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) dvui.cursorSet(.hand);
        if (dvui.clicked(row.data(), .{})) {
            app.conflict_focus = region;
            app.conflict_reveal = true;
        }
    }
}

fn conflictRegions() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer scroll.deinit();

    // What has no regions to pick from: a file deleted on one side, a binary
    // one. Each a plain question.
    if (app.conflict_kind == .deleted_by_us or app.conflict_kind == .deleted_by_them) return deletedConflict();
    if (app.conflict_binary) return binaryConflict();

    if (app.conflicts.len == 0) {
        // No markers left, but git still has the file down as conflicted: what
        // is missing is the click that says so.
        var done = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .margin = .{ .y = style.space.xl } });
        defer done.deinit();
        dvui.label(@src(), "Nothing left to resolve in this file.", .{}, .{
            .font = style.body(),
            .color_text = .{ .color = style.text() },
            .gravity_x = 0.5,
            .padding = dvui.Rect.all(0),
            .margin = .{ .h = style.space.md },
        });
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer row.deinit();
        if (app.opButton(@src(), "Stage it and open the next — Enter", "conflict:stage_next")) repo_io.requestAction(.stage_next);
        return;
    }

    const safe = app.safeConflicts();
    if (safe > 0) safeBar(safe);

    for (app.conflicts, 0..) |region, i| conflictBlock(@src(), region, i);
}

/// "2 of 3 conflicts can be resolved safely": one click for every region
/// where one side alone changed things, line by line at the finest.
fn safeBar(safe: usize) void {
    var bar = dialog_views.alertBox(@src(), 0, style.success(), dvui.entypo.check, .{ .x = style.space.md, .y = style.space.md, .w = style.space.md, .h = style.space.sm });
    defer bar.deinit();
    var text_buf: [160]u8 = undefined;
    dialog_views.alertText(@src(), std.fmt.bufPrint(&text_buf, "{d} of {d} conflict{s} can be resolved safely: each keeps the side that changed it.", .{ safe, app.conflicts.len, window_chrome.plural(app.conflicts.len) }) catch "", style.success());
    var buf: [48]u8 = undefined;
    const caption = if (safe == 1) "Resolve it" else std.fmt.bufPrint(&buf, "Resolve these {d}", .{safe}) catch "Resolve them";
    if (dialog_views.alertButton(@src(), caption, style.success(), "conflict:resolve_safe")) repo_io.requestAction(.resolve_safe);
}

/// A file one side deleted and the other changed: keep it, or let it go.
fn deletedConflict() void {
    const names = sideNames();
    const by_us = app.conflict_kind == .deleted_by_us;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .margin = .{ .y = style.space.xl } });
    defer box.deinit();
    dvui.label(@src(), "{s} deleted this file; {s} changed it.", .{ if (by_us) names.ours else names.theirs, if (by_us) names.theirs else names.ours }, .{
        .font = style.body(),
        .color_text = .{ .color = style.text() },
        .gravity_x = 0.5,
        .padding = dvui.Rect.all(0),
        .margin = .{ .h = style.space.md },
    });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer row.deinit();
    // The side that still has it, and the side that deleted it.
    if (dialog_views.dialogButton(@src(), "Keep the file", true)) takeFile(if (by_us) .theirs else .ours);
    if (dialog_views.dialogButton(@src(), "Delete it", false)) takeFile(if (by_us) .ours else .theirs);
}

/// A binary file: no lines to pick between, one version or the other.
fn binaryConflict() void {
    const names = sideNames();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .margin = .{ .y = style.space.xl } });
    defer box.deinit();
    dvui.label(@src(), "A binary file: keep one side's version of it.", .{}, .{
        .font = style.body(),
        .color_text = .{ .color = style.text() },
        .gravity_x = 0.5,
        .padding = dvui.Rect.all(0),
        .margin = .{ .h = style.space.md },
    });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer row.deinit();
    var ours_buf: [96]u8 = undefined;
    var theirs_buf: [96]u8 = undefined;
    if (dialog_views.dialogButton(@src(), keepCaption(&ours_buf, names.ours), false)) takeFile(.ours);
    if (dialog_views.dialogButton(@src(), keepCaption(&theirs_buf, names.theirs), false)) takeFile(.theirs);
}

fn conflictBlock(src: std.builtin.SourceLocation, region: git.Conflict, index: usize) void {
    const focused = index == app.conflict_focus;
    var block = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = index,
        .expand = .horizontal,
        .background = false,
        .padding = dvui.Rect.all(0),
        .margin = .{ .x = style.space.md, .y = style.space.xs, .w = style.space.md, .h = style.space.sm },
    });
    defer block.deinit();

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (focused) style.accentDim() else style.surface() },
            .corners = .{ .tl = style.radius.input.tl, .tr = style.radius.input.tr },
            .min_size_content = .{ .h = style.toolbar_cell },
            .padding = .{ .x = style.space.md, .w = style.space.sm },
        });
        defer head.deinit();

        dvui.label(@src(), "Conflict {d} of {d}", .{ index + 1, app.conflicts.len }, .{
            .font = style.smallBold(),
            .color_text = .{ .color = if (focused) style.accent() else style.text() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
        // Why it would resolve on its own, where it would.
        if (index < app.conflict_autos.len) if (app.conflict_autos[index]) |reason| {
            var why_buf: [160]u8 = undefined;
            dvui.label(@src(), "{s}", .{autoText(&why_buf, reason)}, .{
                .font = style.tiny(),
                .color_text = .{ .color = style.success() },
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.md },
                .padding = dvui.Rect.all(0),
            });
        };

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        // Each with the key that does the same, on the one the keys act on.
        const names = sideNames();
        var ours_buf: [96]u8 = undefined;
        var theirs_buf: [96]u8 = undefined;
        if (keyedLink(@src(), if (focused) "1" else "", keepCaption(&ours_buf, names.ours), style.success())) github_actions.requestResolve(index, .ours);
        if (keyedLink(@src(), if (focused) "2" else "", keepCaption(&theirs_buf, names.theirs), style.get().blue)) github_actions.requestResolve(index, .theirs);
        if (keyedLink(@src(), if (focused) "3" else "", "Keep both", style.textMuted())) github_actions.requestResolve(index, .both);
    }

    if (region.has_base) {
        conflictSide(@src(), 0, "base — before either side changed it", region.base, style.rowHover());
    }

    {
        // Side by side, the way they are compared: one column each.
        var sides = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
            .expand = .horizontal,
            .background = false,
        });
        defer sides.deinit();
        const names = sideNames();
        var ours_buf: [160]u8 = undefined;
        var theirs_buf: [160]u8 = undefined;
        conflictSide(@src(), 1, std.fmt.bufPrint(&ours_buf, "{s} — {s}", .{ names.ours, names.ours_role }) catch "ours", region.ours, style.diffAddedFill());
        conflictSide(@src(), 2, std.fmt.bufPrint(&theirs_buf, "{s} — {s}", .{ names.theirs, names.theirs_role }) catch "theirs", region.theirs, style.get().blue.lerp(style.background(), 0.86));
    }

    // A click anywhere in it — past the buttons, which take theirs first —
    // makes it the one the keys act on.
    if (dvui.clicked(block.data(), .{})) app.conflict_focus = index;
    const rs = block.data().borderRectScale();
    if (focused) {
        rs.r.stroke(dvui.CornerRect.Physical.all(6 * rs.s), .{ .thickness = 1.5 * rs.s, .color = .{ .color = style.accent() }, .closed = true });
        if (app.conflict_reveal) {
            app.conflict_reveal = false;
            dvui.scrollTo(.{ .screen_rect = rs.r });
        }
    }
}

/// Why a region resolves on its own, in its sides' names.
fn autoText(buf: []u8, reason: git.AutoReason) []const u8 {
    const names = sideNames();
    return switch (reason) {
        .same => "safe: the same change on both sides",
        .only_ours => std.fmt.bufPrint(buf, "safe: only {s} changed it", .{names.ours}) catch "safe",
        .only_theirs => std.fmt.bufPrint(buf, "safe: only {s} changed it", .{names.theirs}) catch "safe",
        .lines_apart => "safe: each side changed different lines",
    };
}

/// A pick's link with the key that does the same before it — none where
/// `key` is empty.
fn keyedLink(src: std.builtin.SourceLocation, key: []const u8, caption: []const u8, color: dvui.Color) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .gravity_y = 0.5,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.sm, .y = 2, .w = style.space.sm, .h = 2 },
        .corners = style.radius.input,
    });
    defer bw.deinit();
    bw.processEvents();
    {
        var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = bw.hovered(),
            .color_fill = .{ .color = style.rowHover() },
            .corners = style.radius.input,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        });
        defer cell.deinit();
        if (key.len > 0) dvui.label(@src(), "{s}", .{key}, .{
            .font = style.tinyBold(),
            .color_text = .{ .color = style.textMuted() },
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = dvui.CornerRect.all(3),
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.xs },
            .padding = .{ .x = 4, .w = 4 },
        });
        dvui.label(@src(), "{s}", .{caption}, .{
            .font = style.small(),
            .color_text = .{ .color = if (bw.hovered()) style.text() else color },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }
    return bw.clicked();
}

pub fn takeFile(side: git.ConflictSide) void {
    if (repo_io.action != .none) return;
    repo_io.action_side = side;
    repo_io.action = .take_file;
}

/// "All of main": the whole file as one side has it.
pub fn allCaption(buf: []u8, name: []const u8) []const u8 {
    var fit: [MAX_SHOWN_LINE]u8 = undefined;
    return std.fmt.bufPrint(buf, "All of {s}", .{graph_view.fitText(&fit, name, style.small(), 120)}) catch "All";
}

/// "Keep main": a side's button, its name cut to fit.
fn keepCaption(buf: []u8, name: []const u8) []const u8 {
    var fit: [MAX_SHOWN_LINE]u8 = undefined;
    return std.fmt.bufPrint(buf, "Keep {s}", .{graph_view.fitText(&fit, name, style.small(), 140)}) catch "Keep";
}

/// One side of a region: a caption, then its lines in a tint that says which
/// side they are.
fn conflictSide(
    src: std.builtin.SourceLocation,
    id: usize,
    caption: []const u8,
    text: []const u8,
    fill: dvui.Color,
) void {
    var side = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = fill },
        .margin = .{ .w = if (id == 1) 1 else 0 },
        .padding = .{ .x = style.space.md, .y = style.space.xs, .w = style.space.md, .h = style.space.xs },
    });
    defer side.deinit();

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer head.deinit();
        dvui.label(@src(), "{s}", .{caption}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textMuted() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
    }

    // A side with nothing in it is a real answer — one branch deleted what the
    // other edited — and an empty box does not say so.
    if (text.len == 0) {
        dvui.label(@src(), "(nothing)", .{}, .{
            .font = style.mono(),
            .color_text = .{ .color = style.textFaint() },
            .padding = dvui.Rect.all(0),
        });
        return;
    }

    var body = text;
    if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];

    var shown: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| : (shown += 1) {
        if (shown >= app.MAX_CONFLICT_LINES) break;
        var tab_buf: [MAX_SHOWN_LINE]u8 = undefined;
        dvui.label(@src(), "{s}", .{detab(&tab_buf, line)}, .{
            .id_extra = shown,
            .font = style.mono(),
            .color_text = .{ .color = style.text() },
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
    }

    const total = std.mem.count(u8, body, "\n") + 1;
    if (total > shown) {
        dvui.label(@src(), "… {d} more lines, not shown — the buttons still take the whole region", .{total - shown}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .padding = dvui.Rect.all(0),
        });
    }
}

pub fn diffFileRow(
    src: std.builtin.SourceLocation,
    file: git.FileDiff,
    id: usize,
    row: usize,
    width: f32,
    rh: f32,
) void {
    var box = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(row)) * rh, .w = width, .h = diff_view.FILE_ROWS * rh },
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .y = if (row > 0) 1 else 0, .h = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.lg, .w = style.space.lg },
    });
    defer box.deinit();

    commit_view.statusFlag(@src(), file.status);
    // Its folder faint, its name in full: the name is what is looked for.
    const slash = std.mem.lastIndexOfScalar(u8, file.path, '/');
    const folder = if (slash) |i| file.path[0 .. i + 1] else "";
    const name = if (slash) |i| file.path[i + 1 ..] else file.path;
    {
        var names = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.md } });
        defer names.deinit();
        if (folder.len > 0) dvui.label(@src(), "{s}", .{folder}, .{
            .font = style.body(),
            .color_text = .{ .color = style.textMuted() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
        dvui.label(@src(), "{s}", .{name}, .{
            .font = style.bodyBold(),
            .color_text = .{ .color = style.text() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
    }

    if (file.binary) {
        dvui.label(@src(), "binary", .{}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }

    switch (app.selection) {
        .commit => |commit_id| {
            if (file.status != .deleted and dialog_views.chipButton(@src(), dvui.entypo.edit, "Open in editor", false)) repo_settings.openInEditor(file.path);
            if (dialog_views.chipButton(@src(), dvui.entypo.clock, "History", false)) graph_view.showFileHistory(file.path);
            // Nothing to restore of a file this commit deleted.
            if (file.status != .deleted) {
                if (dialog_views.chipButton(@src(), dvui.entypo.ccw, "Restore this version", true)) {
                    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
                    var sha_buf: [41]u8 = undefined;
                    const arg = std.fmt.bufPrint(&buf, "{s} {s}", .{ git.oidHex(commit_id, &sha_buf), file.path }) catch return;
                    github_actions.ask(.restore_file, arg);
                }
            }
        },
        else => {},
    }
}

pub fn diffLineRow(
    src: std.builtin.SourceLocation,
    file: git.FileDiff,
    line: git.DiffLine,
    /// Its row in the whole diff, which is also what tells it apart from
    /// every other line: unique however many files and lines there are.
    row: usize,
    width: f32,
    rh: f32,
    side: ?git.DiffSide,
    /// Its index in the file, where a click may pick it.
    line_index: ?usize,
) void {
    const pickable = side != null and line_index != null and (line.kind == .addition or line.kind == .deletion);
    const picked = pickable and isPicked(line_index.?);
    const fill: ?dvui.Color = if (picked) style.accentDim() else switch (line.kind) {
        .addition => style.diffAddedFill(),
        .deletion => style.diffRemovedFill(),
        .hunk_header => style.rowHover(),
        .context, .no_newline => null,
    };

    var box = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = row,
        .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(row)) * rh, .w = width, .h = rh },
        .background = fill != null,
        .color_fill = .{ .color = fill orelse style.background() },
        .padding = .{ .x = style.space.md, .w = style.space.md },
    });
    defer box.deinit();

    if (line.kind == .hunk_header) {
        var header_buf: [MAX_SHOWN_LINE]u8 = undefined;
        dvui.label(@src(), "{s}", .{detab(&header_buf, line.text)}, .{
            .font = style.graphMono(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });

        if (side) |s| {
            // Once lines are picked in this hunk, the buttons act on those.
            const n = pickedInHunk(file, line.hunk);
            var buf: [32]u8 = undefined;
            if (n > 0) {
                if (s == .unstaged) {
                    const discard = std.fmt.bufPrint(&buf, "Discard {d} line{s}", .{ n, window_chrome.plural(n) }) catch "Discard lines";
                    if (dialog_views.linkButton(@src(), discard, style.danger())) requestLines(file, line.hunk, s, true);
                }
                const verb = if (s == .unstaged) "Stage" else "Unstage";
                const caption = std.fmt.bufPrint(&buf, "{s} {d} line{s}", .{ verb, n, window_chrome.plural(n) }) catch verb;
                if (dialog_views.linkButton(@src(), caption, style.accent())) requestLines(file, line.hunk, s, false);
                return;
            }
            // Said where it is done: a click on a line picks it.
            dvui.label(@src(), "or click lines to pick them", .{}, .{
                .font = style.tiny(),
                .color_text = .{ .color = style.textFaint() },
                .gravity_y = 0.5,
                .margin = .{ .w = style.space.md },
                .padding = dvui.Rect.all(0),
            });
            if (s == .unstaged) {
                if (dialog_views.linkButton(@src(), "Discard hunk", style.danger())) askDiscardHunk(file, line.hunk);
            }
            const caption = if (s == .unstaged) "Stage hunk" else "Unstage hunk";
            if (dialog_views.linkButton(@src(), caption, style.accent())) requestHunk(file, line.hunk, s);
        }
        return;
    }

    if (pickable and dvui.clicked(box.data(), .{})) togglePicked(line_index.?, file.lines.len);

    lineNumber(@src(), line.old_no);
    lineNumber(@src(), line.new_no);
    codeLine(file, line_index orelse indexOfLine(file, line));
}

/// Where `line` sits in its file's lines: rows of a file after the first
/// carry no index, but the pairing below needs one.
fn indexOfLine(file: git.FileDiff, line: git.DiffLine) usize {
    for (file.lines, 0..) |l, i| {
        if (l.text.ptr == line.text.ptr and l.kind == line.kind) return i;
    }
    return 0;
}

/// A line of code as the diff draws it: its sign, its text coloured by
/// syntax, and — on a changed line set against the one it replaced — the
/// part that actually changed, on a stronger ground.
pub fn codeLine(file: git.FileDiff, index: usize) void {
    const line = file.lines[index];
    var buf: [MAX_SHOWN_LINE]u8 = undefined;
    const text = detab(&buf, line.text);

    var span: ?[2]usize = null;
    if (pairedLine(file.lines, index)) |other| {
        var other_buf: [MAX_SHOWN_LINE]u8 = undefined;
        const other_text = detab(&other_buf, file.lines[other].text);
        if (line.kind == .deletion) {
            if (syntax.changedSpan(text, other_text)) |sp| span = sp.old;
        } else if (syntax.changedSpan(other_text, text)) |sp| span = sp.new;
    }

    // Wider than the row when the line is long: the row clips it.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .background = false,
        .margin = .{ .x = style.space.sm },
    });
    defer row.deinit();

    const sign_color = switch (line.kind) {
        .addition => style.success(),
        .deletion => style.danger(),
        else => style.textFaint(),
    };
    dvui.label(@src(), "{s}", .{git.linePrefix(line.kind)}, .{ .font = style.code(), .color_text = .{ .color = sign_color }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });

    var tokens_buf: [128]syntax.Token = undefined;
    var tokens = syntax.tokenize(syntax.langOf(file.path), text, &tokens_buf);
    var whole = [_]syntax.Token{.{ .start = 0, .end = text.len, .kind = .plain }};
    if (tokens.len == 0) tokens = whole[0..if (text.len > 0) 1 else 0];
    const strong = if (line.kind == .addition) style.success().opacity(0.28) else style.danger().opacity(0.28);

    // One text layout for the line, not a label per token: that is what lets
    // a drag select it and Ctrl+C copy it. A changed line in a working-tree
    // diff is picked by its click before this sees the press.
    var tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
        .gravity_y = 0.5,
        .background = false,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    defer tl.deinit();
    dropStaleTextSelection(tl);
    for (tokens) |tok| {
        // A token split where the changed part starts and ends.
        var cuts = [_]usize{ tok.start, tok.end, tok.end, tok.end };
        var n: usize = 1;
        if (span) |sp| {
            for (sp) |at| if (at > tok.start and at < tok.end) {
                cuts[n] = at;
                n += 1;
            };
        }
        cuts[n] = tok.end;
        for (0..n) |k| {
            const a = cuts[k];
            const b = cuts[k + 1];
            if (b <= a) continue;
            const marked = if (span) |sp| a >= sp[0] and b <= sp[1] else false;
            tl.addText(text[a..b], .{
                .font = style.code(),
                .color_text = .{ .color = syntaxColor(tok.kind) },
                .color_fill = if (marked) .{ .color = strong } else null,
            });
        }
    }
}

/// A text layout keeps its selection, and draws it, focused or not: without
/// this, every line ever selected stays lit, and a line reused for another
/// commit lights the old range. The press that starts a new selection is
/// handled after this, in the layout's deinit.
pub fn dropStaleTextSelection(tl: *dvui.TextLayoutWidget) void {
    if (dvui.focusedWidgetId() != tl.data().id) tl.selection.* = .{};
}

fn syntaxColor(kind: syntax.Kind) dvui.Color {
    const p = style.get();
    return switch (kind) {
        .plain => style.text(),
        .keyword => p.purple,
        .string => p.green,
        .number => p.orange,
        .comment => style.textFaint(),
        .type_name => p.blue,
    };
}

/// The line a changed line is set against: in a run of removals followed by
/// a run of additions, the n-th of one with the n-th of the other — the same
/// pairing the split view lays out.
fn pairedLine(lines: []const git.DiffLine, i: usize) ?usize {
    switch (lines[i].kind) {
        .deletion => {
            var s = i;
            while (s > 0 and lines[s - 1].kind == .deletion) s -= 1;
            var e = i;
            while (e < lines.len and lines[e].kind == .deletion) e += 1;
            const at = e + (i - s);
            if (at >= lines.len) return null;
            for (lines[e .. at + 1]) |l| if (l.kind != .addition) return null;
            return at;
        },
        .addition => {
            var s = i;
            while (s > 0 and lines[s - 1].kind == .addition) s -= 1;
            var d = s;
            while (d > 0 and lines[d - 1].kind == .deletion) d -= 1;
            const at = d + (i - s);
            return if (at < s) at else null;
        },
        else => return null,
    }
}

/// Longest line of a file drawn, in bytes after tabs are expanded. Past it the
/// row is cut: it is wider than any pane already.
pub const MAX_SHOWN_LINE = 4096;
const TAB_WIDTH = 4;

/// `text` with its tabs as spaces, to the next multiple of `TAB_WIDTH`.
///
/// Neither font has a glyph for a tab — it is a control character, not
/// something to draw — so left in, every indent shows as an empty box. Only
/// what is drawn: the patches Zit builds keep the real tabs.
pub fn detab(buf: *[MAX_SHOWN_LINE]u8, raw: []const u8) []const u8 {
    // A CRLF file's lines keep their `\r` for the patches built from them;
    // on screen it is nothing.
    const text = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
    var n: usize = 0;
    var col: usize = 0;
    for (text) |ch| {
        if (ch == '\t') {
            const spaces = TAB_WIDTH - col % TAB_WIDTH;
            if (n + spaces > buf.len) break;
            @memset(buf[n..][0..spaces], ' ');
            n += spaces;
            col += spaces;
        } else {
            if (n == buf.len) break;
            buf[n] = ch;
            n += 1;
            // Columns count characters, not the bytes of a UTF-8 sequence.
            if (ch & 0xC0 != 0x80) col += 1;
        }
    }
    return buf[0..n];
}

test "tabs become spaces to the next tab stop, and nothing else changes" {
    var buf: [MAX_SHOWN_LINE]u8 = undefined;
    try std.testing.expectEqualStrings("    x", detab(&buf, "\tx"));
    try std.testing.expectEqualStrings("ab  c", detab(&buf, "ab\tc"));
    try std.testing.expectEqualStrings("é   c", detab(&buf, "é\tc"));
    const plain = "no tabs";
    try std.testing.expectEqual(plain.ptr, detab(&buf, plain).ptr);
}

/// One side's line number, blank where the line does not exist on that side.
pub fn lineNumber(src: std.builtin.SourceLocation, n: u32) void {
    var buf: [12]u8 = undefined;
    const text = if (n == 0) "" else std.fmt.bufPrint(&buf, "{d}", .{n}) catch "";

    // A column of its own, the number to its right: in the row itself the
    // gravity would send it to the row's far end, over the code.
    var column = dvui.box(src, .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 38 },
        .max_size_content = .width(38),
        .background = false,
        .margin = .{ .w = style.space.sm },
    });
    defer column.deinit();
    dvui.label(@src(), "{s}", .{text}, .{
        .font = style.code(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .gravity_x = 1.0,
        .padding = dvui.Rect.all(0),
    });
}

/// Stage or unstage one hunk, by handing `git apply` a patch rebuilt from it.
pub fn requestHunk(file: git.FileDiff, hunk: u32, side: git.DiffSide) void {
    // Checked up front: `request` drops the command if one is already pending,
    // and the patch would then be allocated with nothing left to free it.
    if (repo_io.action != .none) return;

    const patch = git.patchForHunk(app.gpa, file, hunk) catch {
        github_actions.setCommandError("Out of memory building the patch.");
        return;
    };

    // `--cached` applies to the index: forward to stage a hunk that is not
    // staged, reversed to take a staged one back out.
    switch (side) {
        .unstaged => repo_io.request(&.{ "apply", "--cached", "-" }),
        .staged => repo_io.request(&.{ "apply", "--cached", "--reverse", "-" }),
    }
    repo_io.action_input = patch;
}

pub fn isPicked(index: usize) bool {
    return index < app.picked_lines.items.len and app.picked_lines.items[index];
}

pub fn togglePicked(index: usize, count: usize) void {
    if (app.picked_lines.items.len != count) {
        app.picked_lines.resize(app.gpa, count) catch return;
        @memset(app.picked_lines.items, false);
    }
    app.picked_lines.items[index] = !app.picked_lines.items[index];
}

pub fn pickedInHunk(file: git.FileDiff, hunk: u32) usize {
    var n: usize = 0;
    for (file.lines, 0..) |l, i| {
        if (l.hunk == hunk and isPicked(i)) n += 1;
    }
    return n;
}

/// Stage, unstage or discard only the picked lines of one hunk. Discarding
/// asks first, the same as a whole hunk does.
pub fn requestLines(file: git.FileDiff, hunk: u32, side: git.DiffSide, discard: bool) void {
    if (repo_io.action != .none) return;

    const reverse = discard or side == .staged;
    const patch = (git.patchForLines(app.gpa, file, hunk, app.picked_lines.items, reverse) catch {
        return github_actions.setCommandError("Out of memory building the patch.");
    }) orelse return github_actions.setCommandError(if (side == .staged) "Lines of a new or deleted file come out with the whole file." else "Lines of a deleted file go in with the whole file.");

    if (discard) {
        defer app.gpa.free(patch);
        return github_actions.ask(.discard_hunk, patch);
    }
    switch (side) {
        .unstaged => repo_io.request(&.{ "apply", "--cached", "-" }),
        .staged => repo_io.request(&.{ "apply", "--cached", "--reverse", "-" }),
    }
    repo_io.action_input = patch;
}

/// Throwing a hunk away is staging's mirror image — the same rebuilt patch,
/// reversed out of the working tree instead of applied to the index — so it
/// asks first, with the patch itself as what it asks about.
pub fn askDiscardHunk(file: git.FileDiff, hunk: u32) void {
    const patch = git.patchForHunk(app.gpa, file, hunk) catch {
        github_actions.setCommandError("Out of memory building the patch.");
        return;
    };
    defer app.gpa.free(patch);
    github_actions.ask(.discard_hunk, patch);
}
