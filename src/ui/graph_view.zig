const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const search_view = @import("search_view.zig");
const diff_view = @import("diff_view.zig");
const rebase_view = @import("rebase_view.zig");
const commit_view = @import("commit_view.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const repo_io = @import("../core/repo_io.zig");
const app = @import("../main.zig");

// === Graph filter ===
//
// Branches left out of the graph, and branches pinned to the top of their
// section: per repository, in its own config as `zit.hidden` and
// `zit.pinned`, so they come back with it. "Only this one" is for now only.

pub var graph_hidden: std.ArrayList([]u8) = .empty;
pub var graph_pinned: std.ArrayList([]u8) = .empty;
/// The branches picked to show alone, from the graph header's menu; none
/// for every branch.
pub var graph_only: std.ArrayList([]u8) = .empty;

pub fn graphFilter() git.RefFilter {
    return .{ .hidden = @ptrCast(graph_hidden.items), .hidden_set = &hidden_set, .only = @ptrCast(graph_only.items), .remotes = graph_show_remote, .first_parent = graph_first_parent, .authors = @ptrCast(author_only.items) };
}

/// `graph_hidden` as a set, over the same strings: asked of every ref a
/// sidebar row or a graph tag draws, where a list hiding thousands of
/// branches cost a walk through all of them each time.
pub var hidden_set: std.StringHashMapUnmanaged(void) = .empty;

pub fn isHidden(name: []const u8) bool {
    return hidden_set.contains(name);
}

/// Pick or unpick `name` among the branches shown alone.
pub fn toggleOnly(name: []const u8) void {
    for (graph_only.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
        app.gpa.free(graph_only.orderedRemove(i));
        return graphFilterChanged();
    };
    const owned = app.gpa.dupe(u8, name) catch return;
    graph_only.append(app.gpa, owned) catch return app.gpa.free(owned);
    graphFilterChanged();
}

/// Remote branches drawn in the graph; saved with the workspace.
pub var graph_show_remote: bool = true;
/// GitComet's two history modes: "All branches" (off) or "First-parent" (on),
/// the mainline from HEAD — or from the branches picked — through its merges.
pub var graph_first_parent: bool = false;

/// The graph's filter changed this frame: read the history again once the
/// frame is drawn — reading it now would free what the rest of the frame is
/// drawing from. Tests read it at once, and look straight after.
pub var graph_filter_dirty: bool = false;

pub fn graphFilterChanged() void {
    // A test calling in from outside a frame reads it again at once. Inside
    // one — a click on a sidebar eye — the rows still to be drawn point into
    // this history: the frame's end reads it again, as in the app.
    if (@import("builtin").is_test and !tab_strip.in_frame) return repo_io.reloadHistory();
    graph_filter_dirty = true;
}

pub fn hasName(list: []const []u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub fn clearNames(list: *std.ArrayList([]u8)) void {
    if (list == &graph_hidden) hidden_set.clearRetainingCapacity();
    if (list == &commit_view.picked_changes) commit_view.picked_set.clearRetainingCapacity();
    for (list.items) |n| app.gpa.free(n);
    list.clearRetainingCapacity();
}

pub fn clearGraphPrefs() void {
    clearNames(&graph_hidden);
    clearNames(&graph_pinned);
    clearNames(&graph_only);
}

/// The branches hidden and pinned in this repository, from its own config.
/// Read through libgit2, not `git config`: it happens on every tab switch,
/// on the UI thread, and two `git` started there cost more than the rest of
/// the switch.
pub fn loadGraphPrefs() void {
    clearGraphPrefs();
    const r = app.repo orelse return;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    for ([_]struct { *std.ArrayList([]u8), [:0]const u8 }{ .{ &graph_hidden, "zit.hidden" }, .{ &graph_pinned, "zit.pinned" } }) |p| {
        const values = r.localConfigAll(arena.allocator(), p[1]) catch continue;
        for (values) |raw| {
            const name = std.mem.trim(u8, raw, " \r");
            if (name.len == 0 or hasName(p[0].items, name)) continue;
            const owned = app.gpa.dupe(u8, name) catch continue;
            p[0].append(app.gpa, owned) catch app.gpa.free(owned);
        }
    }
    for (graph_hidden.items) |n| hidden_set.put(app.gpa, n, {}) catch {};
}

/// In the list and the repository's config, or out of both; the graph is
/// read again for it.
pub fn toggleGraphPref(list: *std.ArrayList([]u8), key: []const u8, name: []const u8) void {
    const hidden_list = list == &graph_hidden;
    const present = if (hidden_list) isHidden(name) else hasName(list.items, name);
    var outcome = if (present) blk: {
        if (hidden_list) _ = hidden_set.remove(name);
        for (list.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
            app.gpa.free(list.orderedRemove(i));
            break;
        };
        break :blk run.git(app.gpa, app.app_io, app.repo_path.items, &.{ "config", "--local", "--fixed-value", "--unset-all", key, name });
    } else blk: {
        const owned = app.gpa.dupe(u8, name) catch return;
        list.append(app.gpa, owned) catch return app.gpa.free(owned);
        if (hidden_list) hidden_set.put(app.gpa, owned, {}) catch {};
        break :blk run.git(app.gpa, app.app_io, app.repo_path.items, &.{ "config", "--local", "--add", key, name });
    };
    if (outcome) |*o| o.deinit(app.gpa) else |_| {}
    if (list == &graph_hidden) graphFilterChanged();
}

/// A ref out of the graph, or back in, as its eye says. A local branch and
/// the remote branch it tracks are one line of the graph — one tag where they
/// agree — so they go out and come back together: hiding the local alone left
/// its commits and its tag up, walked through the remote's.
pub fn toggleHidden(ref: git.Ref) void {
    const hide = !isHidden(ref.name);
    // Copied first: in tests each toggle reads the history again, and `ref`
    // points into the old one.
    const upstream: ?[]u8 = if (ref.kind == .local) if (ref.tracking.upstream) |u| app.gpa.dupe(u8, u) catch null else null else null;
    defer if (upstream) |u| app.gpa.free(u);
    toggleGraphPref(&graph_hidden, "zit.hidden", ref.name);
    if (upstream) |u| if (isHidden(u) != hide) toggleGraphPref(&graph_hidden, "zit.hidden", u);
}

pub fn unhideAll() void {
    clearNames(&graph_hidden);
    var outcome = run.git(app.gpa, app.app_io, app.repo_path.items, &.{ "config", "--local", "--unset-all", "zit.hidden" });
    if (outcome) |*o| o.deinit(app.gpa) else |_| {}
    graphFilterChanged();
}

/// `name` alone, or every branch again for null.
pub fn setSolo(name: ?[]const u8) void {
    clearNames(&graph_only);
    if (name) |n| if (app.gpa.dupe(u8, n)) |owned| {
        graph_only.append(app.gpa, owned) catch app.gpa.free(owned);
    } else |_| {};
    graphFilterChanged();
}

/// A history being read on another thread, with its own repository handle:
/// libgit2 objects are not shared across threads, repositories opened twice
/// are fine.
const HistoryLoad = struct {
    path: []u8,
    /// `history_gen` when it started. A synchronous reload since then has
    /// newer data than this will, and wins.
    gen: u64,
    /// The first read of a repository: what waits on its history — pull
    /// requests, GitHub pictures — is set up when it lands. A re-read after
    /// a command has nothing to announce.
    announce: bool = true,
    /// The graph filter as it was, copied: the UI may change its own while
    /// this runs.
    filter_arena: std.heap.ArenaAllocator,
    filter: git.RefFilter = .{},
    done: std.atomic.Value(bool) = .init(false),
    history: ?git.History = null,
    lanes: ?graph.Layout = null,
    future: ?std.Io.Future(void) = null,

    fn work(self: *HistoryLoad) void {
        defer app.wakeUi();
        defer self.done.store(true, .release);
        var r = git.Repo.open(self.path) catch return;
        defer r.deinit();
        var h = r.readHistoryFiltered(app.gpa, self.filter) catch return;
        const l = graph.build(app.gpa, h.commits, h.head_oid) catch {
            h.deinit();
            return;
        };
        self.history = h;
        self.lanes = l;
    }

    pub fn free(self: *HistoryLoad) void {
        if (self.future) |*f| f.await(app.app_io);
        if (self.history) |*h| h.deinit();
        if (self.lanes) |*l| l.deinit();
        self.filter_arena.deinit();
        app.gpa.free(self.path);
        app.gpa.destroy(self);
    }
};

pub var history_load: ?*HistoryLoad = null;
/// Bumped by every synchronous read of the history.
pub var history_gen: u64 = 0;
/// Bumped every time a history lands, however it was read: what a cache built
/// from one says it was built from. The arena's address alone can come back.
pub var history_seq: u64 = 0;
/// Reads a newer one replaced while they were still out. Freeing one awaits
/// its revwalk, which on a large repository is the UI frozen for seconds, so
/// each is left to finish and freed once its `done` says so.
pub var history_retired: std.ArrayList(*HistoryLoad) = .empty;

/// Free the retired reads that have finished; all of them, waiting, at exit.
pub fn reapHistoryLoads(wait: bool) void {
    var i = history_retired.items.len;
    while (i > 0) {
        i -= 1;
        const load = history_retired.items[i];
        if (!wait and !load.done.load(.acquire)) continue;
        _ = history_retired.swapRemove(i);
        load.free();
    }
}

pub fn startHistoryLoad() void {
    if (history_load) |old| {
        history_load = null;
        if (old.done.load(.acquire)) old.free() else history_retired.append(app.gpa, old) catch old.free();
    }
    const load = app.gpa.create(HistoryLoad) catch return repo_io.reloadHistory();
    load.* = .{
        .path = app.gpa.dupe(u8, app.repo_path.items) catch {
            app.gpa.destroy(load);
            return repo_io.reloadHistory();
        },
        .gen = history_gen,
        .filter_arena = .init(app.gpa),
    };
    {
        const a = load.filter_arena.allocator();
        var hidden: []const []const u8 = &.{};
        if (a.alloc([]const u8, graph_hidden.items.len)) |copy| {
            for (copy, graph_hidden.items) |*to, from| to.* = a.dupe(u8, from) catch "";
            hidden = copy;
        } else |_| {}
        var only: []const []const u8 = &.{};
        if (a.alloc([]const u8, graph_only.items.len)) |copy| {
            for (copy, graph_only.items) |*to, from| to.* = a.dupe(u8, from) catch "";
            only = copy;
        } else |_| {}
        var by: []const []const u8 = &.{};
        if (a.alloc([]const u8, author_only.items.len)) |copy| {
            for (copy, author_only.items) |*to, from| to.* = a.dupe(u8, from) catch "";
            by = copy;
        } else |_| {}
        // The whole filter, as the UI has it: First-parent went missing here,
        // and a quiet re-read dropped the graph out of it.
        load.filter = .{
            .hidden = hidden,
            .only = only,
            .remotes = graph_show_remote,
            .first_parent = graph_first_parent,
            .authors = by,
        };
    }
    history_load = load;
    load.future = app.app_io.concurrent(HistoryLoad.work, .{load}) catch blk: {
        load.work();
        break :blk null;
    };
}

/// Swap a finished read in, if it is still the one wanted. Once a frame,
/// before anything draws. True while one is still out.
pub fn collectHistoryLoad() bool {
    reapHistoryLoads(false);
    const load = history_load orelse return false;
    if (!load.done.load(.acquire)) return true;
    history_load = null;
    defer load.free();

    const same_repo = app.repo != null and std.mem.eql(u8, load.path, app.repo_path.items);
    // A synchronous read got there first — the poll, a command. Its history
    // is newer, so this one goes; but what waits on the history still has
    // to happen, or pull requests and GitHub pictures are never set up.
    defer if (history_again and app.repo != null) {
        history_again = false;
        startHistoryLoadQuiet();
    };
    if (same_repo and load.gen != history_gen) {
        if (load.announce) app.historyArrived();
        return false;
    }
    if (!same_repo) return false;
    if (load.history == null) {
        // Read it here instead, which says what went wrong if it fails again.
        repo_io.reloadHistory();
    } else {
        if (app.history) |*h| h.deinit();
        if (app.lanes) |*l| l.deinit();
        app.history = load.history;
        app.lanes = load.lanes;
        load.history = null;
        load.lanes = null;
        history_seq +%= 1;
        diff_view.dropStaleSelection();
        rebase_view.readOpInfo();
        if (file_history.items.len > 0) markFileHistory();
        repo_io.trimHeap();
    }
    if (load.announce) app.historyArrived();
    return false;
}

/// Asked for while one was already out: read again when it lands.
var history_again: bool = false;

fn startHistoryLoadQuiet() void {
    startHistoryLoad();
    if (history_load) |l| l.announce = false;
}

/// The history read again — on another thread outside tests: on Windows a
/// revwalk of a large repository is long enough to see the UI stop. The
/// one on screen stays until the new one lands.
pub fn refreshHistory() void {
    if (@import("builtin").is_test) return repo_io.reloadHistory();
    if (history_load != null) {
        history_again = true;
        return;
    }
    startHistoryLoadQuiet();
}

/// The history read again for a filter just changed — a branch hidden or
/// shown alone, First-parent, the remotes, an author — on another thread, as
/// `refreshHistory` reads it: a click no longer stops the window for a
/// revwalk, a second on a history the size of git's. A read already out
/// was for the filter as it was: retired at once rather than waited for and
/// shown first.
pub fn refilterHistory() void {
    if (@import("builtin").is_test) return repo_io.reloadHistory();
    history_again = false;
    startHistoryLoadQuiet();
}

// === Dragging a branch onto a branch ===

pub const DRAG_NAME = "zit-branch";

/// The branch being dragged, owned: the row it started on is rebuilt every
/// frame, and the history under it on every poll.
pub var drag_source: std.ArrayList(u8) = .empty;
/// Where it was dropped, waiting for its menu to say merge or rebase.
pub var drop: ?struct { source: []u8, target: []u8 } = null;
/// Where it was let go: the menu opens there.
pub var drop_at: dvui.Point.Natural = .{};

/// Take a drop onto this row. True while a branch is dragged over it, for the
/// highlight. Before the row's button sees the events, so the release is
/// this row's rather than a click.
pub fn branchDrop(wd: *dvui.WidgetData, ref: git.Ref) bool {
    if (ref.kind == .tag or !dvui.dragName(DRAG_NAME)) return false;
    if (std.mem.eql(u8, drag_source.items, ref.name)) return false;
    const rect = wd.borderRectScale().r;
    var over = false;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = rect, .drag_name = DRAG_NAME })) continue;
        const me = e.evt.mouse;
        if (me.action == .position) over = true;
        if (me.action == .release and me.button.pointer()) {
            e.handle(@src(), wd);
            dvui.dragEnd(me.button);
            setDrop(drag_source.items, ref.name);
            drop_at = me.p.toNatural();
            // Its menu is drawn at the top of the next frame.
            dvui.refresh(null, @src(), null);
        }
    }
    return over;
}

/// Turn a press on this row into a possible drag. After the button: it
/// starts an unnamed one of its own on the press, which this replaces with a
/// named one, and once that has moved far enough the button gives the mouse
/// up so the rows it crosses can see it.
pub fn branchDragStart(wd: *dvui.WidgetData, ref: git.Ref) void {
    if (ref.kind == .tag or !dvui.captured(wd.id)) return;
    const rect = wd.borderRectScale().r;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action == .press and me.button.pointer() and rect.contains(me.p)) {
            dvui.dragPreStart(me.button, me.p, .{ .name = DRAG_NAME });
            drag_source.clearRetainingCapacity();
            drag_source.appendSlice(app.gpa, ref.name) catch {};
        } else if (me.action == .motion) {
            if (dvui.dragging(me, DRAG_NAME) != null) {
                dvui.captureMouse(null, e.num);
                return;
            }
        }
    }
}

/// The branch on the move, under the cursor while it is dragged: a tag like
/// the graph's, a little below and right of the pointer. Deaf to the mouse,
/// so the release lands on the row beneath it.
pub fn dragGhost() void {
    if (dvui.dragName(app.TAB_DRAG_NAME)) return app.tabGhost();
    if (!dvui.dragName(DRAG_NAME) or drag_source.items.len == 0) return;
    const scale = dvui.windowNaturalScale();
    const at = dvui.currentWindow().mouse_pt;
    // Sized by hand: a floating widget takes its rect as given.
    const text = style.smallBold().textSize(drag_source.items);
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = .{ .x = at.x / scale + 14, .y = at.y / scale + 10, .w = text.w + 11 + style.space.xs + style.space.sm + style.space.md, .h = text.h + 6 },
        .background = true,
        .color_fill = .{ .color = style.accent() },
        .corners = style.radius.tag,
        .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = 2 }, .fade = 8, .alpha = 0.25 },
        .padding = .{ .x = style.space.sm, .y = 3, .w = style.space.md, .h = 3 },
    });
    defer fw.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
    defer row.deinit();
    dvui.icon(@src(), "ghost_icon", dvui.entypo.flow_branch, .{ .fill_color = .{ .color = style.textOnAccent() }, .stroke_color = null }, .{
        .min_size_content = .{ .w = 11, .h = 11 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    dvui.label(@src(), "{s}", .{drag_source.items}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = style.textOnAccent() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

pub fn setDrop(source: []const u8, target: []const u8) void {
    clearDrop();
    const s = app.gpa.dupe(u8, source) catch return;
    const t = app.gpa.dupe(u8, target) catch {
        app.gpa.free(s);
        return;
    };
    drop = .{ .source = s, .target = t };
}

pub fn clearDrop() void {
    if (drop) |d| {
        app.gpa.free(d.source);
        app.gpa.free(d.target);
    }
    drop = null;
}

const DropAction = enum { merge, rebase };
pub var drop_action: DropAction = .merge;

/// What a drop means, asked rather than guessed: a menu where the branch was
/// let go, as GitKraken's, with the two things it can mean — merge it in, or
/// rebase onto it. A click anywhere else, or Esc, lets it be.
pub fn dropMenu() void {
    const d = drop orelse return;
    if (dialog_views.escapePressed()) return clearDrop();

    // The menu says when it closes — another window taking the keys —
    // through the root of its chain, which no context widget is here to be.
    var closed = false;
    const prev_root = dvui.MenuWidget.Root.set(.{ .ptr = &closed, .close = dropMenuClosed });
    defer _ = dvui.MenuWidget.Root.set(prev_root);
    var chosen = false;
    var menu_rect: dvui.Rect.Physical = .{};
    {
        var fw = contextMenu(drop_at);
        defer fw.deinit();
        menu_rect = fw.data().rectScale().r;

        var buf: [300]u8 = undefined;
        const merge = std.fmt.bufPrint(&buf, "Merge {s} into {s}", .{ d.source, d.target }) catch "Merge";
        if (menuIcon(@src(), dvui.entypo.merge, merge, false)) {
            chosen = true;
            fw.close();
            drop_action = .merge;
            repo_io.requestAction(.drop);
        }
        var buf2: [300]u8 = undefined;
        // A remote branch is not rebased itself: the local one tracking it is.
        const rebase = (if (app.isLocalBranch(d.source))
            std.fmt.bufPrint(&buf2, "Rebase {s} onto {s}", .{ d.source, d.target })
        else
            std.fmt.bufPrint(&buf2, "Rebase the branch tracking {s} onto {s}", .{ d.source, d.target })) catch "Rebase";
        if (menuIcon(@src(), dvui.entypo.level_up, rebase, false)) {
            chosen = true;
            fw.close();
            drop_action = .rebase;
            repo_io.requestAction(.drop);
        }
    }
    // Chosen, the drop is the action's to clear once it has run.
    // A press anywhere else lets it be, as a right-click menu's does: dvui
    // leaves that to the context widget, and the window under this menu
    // keeps it open otherwise. Not taken: the press goes on to what it hit.
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .mouse => |me| if (me.action == .press and !menu_rect.contains(me.p)) {
                closed = true;
            },
            else => {},
        }
    }
    if (closed and !chosen) clearDrop();
}

fn dropMenuClosed(ptr: *anyopaque, reason: dvui.MenuWidget.CloseReason) void {
    _ = reason;
    const closed: *bool = @ptrCast(@alignCast(ptr));
    closed.* = true;
}

/// The branch a remote ref would be checked out as, or a local name as is.
fn localName(name: []const u8) []const u8 {
    if (app.isLocalBranch(name)) return name;
    return app.splitRemoteRef(name).branch;
}

/// The local branch whose upstream is `remote_ref` ("origin/feat"), owned.
fn trackingBranch(remote_ref: []const u8) ?[]u8 {
    const answer = run.capture(app.gpa, app.app_io, app.repo_path.items, &.{ "git", "for-each-ref", "--format=%(upstream:short) %(refname:short)", "refs/heads" }) catch return null;
    defer app.gpa.free(answer.out);
    var lines = std.mem.splitScalar(u8, answer.out, '\n');
    while (lines.next()) |line| {
        const pair = app.splitPair(std.mem.trim(u8, line, " \r")) orelse continue;
        if (std.mem.eql(u8, pair[0], remote_ref)) return app.gpa.dupe(u8, pair[1]) catch null;
    }
    return null;
}

/// `name` as git should read it: bare, which is what a merge message then
/// shows, unless a ref of another kind is called the same — a tag `v1` beside
/// a branch `v1` — where git would warn and take the tag.
pub fn refArg(buf: *[512]u8, name: []const u8, kind: git.Ref.Kind) []const u8 {
    const h = app.history orelse return name;
    for (h.refs) |other| {
        if (other.kind == kind or !std.mem.eql(u8, other.name, name)) continue;
        const prefix = switch (kind) {
            .local => "refs/heads/",
            .remote => "refs/remotes/",
            .tag => "refs/tags/",
        };
        return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, name }) catch name;
    }
    return name;
}

pub fn runDrop() void {
    const d = drop orelse return;
    if (app.midOperation()) {
        clearDrop();
        return app.setCommandError("Finish or abort what is under way first.");
    }
    var ref_buf: [512]u8 = undefined;
    defer clearDrop();
    switch (drop_action) {
        // Into the target: it has to be checked out to take a merge.
        .merge => {
            app.gitDo(&.{ "switch", localName(d.target) });
            if (tab_strip.command_error != null) return;
            app.gitDo(&.{ "merge", "--no-edit", refArg(&ref_buf, d.source, if (app.isLocalBranch(d.source)) .local else .remote) });
        },
        // `rebase <upstream> <branch>` checks the branch out itself. A
        // remote branch cannot be rebased here, only the local one tracking
        // it — not whichever happens to share its name.
        .rebase => if (app.isLocalBranch(d.source))
            app.gitDo(&.{ "rebase", refArg(&ref_buf, d.target, if (app.isLocalBranch(d.target)) .local else .remote), d.source })
        else if (trackingBranch(d.source)) |branch| {
            defer app.gpa.free(branch);
            app.gitDo(&.{ "rebase", refArg(&ref_buf, d.target, if (app.isLocalBranch(d.target)) .local else .remote), branch });
        } else app.setCommandError("No local branch tracks that one. Check it out first, then rebase."),
    }
}

/// What a branch can be the target of. Right-click, because the sidebar has no
/// room for four buttons a row and double-click already means checkout.
pub fn refMenu(
    src: std.builtin.SourceLocation,
    ref: git.Ref,
    id: usize,
    rect: dvui.Rect.Physical,
    open_at: ?dvui.Point.Physical,
) void {
    const ctx = dvui.context(src, .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();
    app.openContextAt(ctx, open_at);

    const cp = ctx.activePoint() orelse return;

    var fw = contextMenu(cp);
    defer fw.deinit();
    var ref_buf: [512]u8 = undefined;

    // Merging or rebasing a branch onto itself is a no-op git refuses, and
    // checking out the branch you are on does nothing: leaving those out beats
    // offering them and showing the error afterwards. Which branches the graph
    // shows is the "Branches:" menu over it, not this one.
    menuTitle(ref.name, switch (ref.kind) {
        .local => if (ref.head) "current branch" else "branch",
        .remote => "remote branch",
        .tag => "tag",
    });

    if (ref.head) {
        if (menuIcon(@src(), dvui.entypo.download, "Pull, rebasing local commits", false)) {
            fw.close();
            repo_io.requestNetwork("Pulling", &.{ "pull", "--rebase" });
        }
        if (menuIcon(@src(), dvui.entypo.download, "Pull, fast-forward only", false)) {
            fw.close();
            repo_io.requestNetwork("Pulling", &.{ "pull", "--ff-only" });
        }
        if (menuIcon(@src(), dvui.entypo.upload, "Force push…", true)) {
            fw.close();
            app.ask(.force_push, "");
        }
    } else {
        if (ref.kind != .tag and menuIcon(@src(), dvui.entypo.flow_branch, "Check out", false)) {
            fw.close();
            app.checkout(ref);
        }
        if (app.history) |h| if (h.head_oid) |head_oid| {
            if (menuIcon(@src(), dvui.entypo.swap, "Compare with the current branch", false)) {
                fw.close();
                app.startCompare(head_oid, ref.target, h.head orelse "HEAD", ref.name);
            }
        };

        menuSeparator(1);
        if (!app.midOperation() and menuIcon(@src(), dvui.entypo.merge, "Merge into current branch", false)) {
            fw.close();
            repo_io.request(&.{ "merge", "--no-edit", refArg(&ref_buf, ref.name, ref.kind) });
        }
        if (!app.midOperation() and menuIcon(@src(), dvui.entypo.merge, "Merge, always with a merge commit", false)) {
            fw.close();
            repo_io.request(&.{ "merge", "--no-edit", "--no-ff", refArg(&ref_buf, ref.name, ref.kind) });
        }
        // Leaves the result staged and HEAD where it was: the commit that
        // follows is yours to write, which is the point of squashing.
        if (!app.midOperation() and menuIcon(@src(), dvui.entypo.archive, "Squash into current branch, uncommitted", false)) {
            fw.close();
            repo_io.request(&.{ "merge", "--squash", refArg(&ref_buf, ref.name, ref.kind) });
        }
        if (!app.midOperation() and menuIcon(@src(), dvui.entypo.level_up, "Rebase current branch onto this", false)) {
            fw.close();
            repo_io.request(&.{ "rebase", refArg(&ref_buf, ref.name, ref.kind) });
        }
    }

    menuSeparator(2);
    if (ref.kind == .local and !ref.head) {
        if (menuIcon(@src(), dvui.entypo.upload, "Push, and track it", false)) {
            fw.close();
            if (app.defaultRemote()) |remote| {
                repo_io.requestNetwork("Pushing", &.{ "push", "-u", remote, refArg(&ref_buf, ref.name, ref.kind) });
            } else app.setCommandError("There is no remote to push to. Add one in the sidebar.");
        }
    }
    if (ref.kind == .tag) {
        if (menuIcon(@src(), dvui.entypo.upload, "Push this tag", false)) {
            fw.close();
            if (app.defaultRemote()) |remote| {
                // The full name, as for a delete: a branch called the same
                // would make the bare one ambiguous.
                const full = std.fmt.bufPrint(&ref_buf, "refs/tags/{s}", .{ref.name}) catch ref.name;
                repo_io.requestNetwork("Pushing", &.{ "push", remote, full });
            } else app.setCommandError("There is no remote to push to. Add one in the sidebar.");
        }
    }
    if (ref.kind != .tag) {
        const pinned = hasName(graph_pinned.items, ref.name);
        if (menuIcon(@src(), dvui.entypo.pin, if (pinned) "Unpin" else "Pin to the top", false)) {
            fw.close();
            toggleGraphPref(&graph_pinned, "zit.pinned", ref.name);
        }
        const hidden = isHidden(ref.name);
        if (menuIcon(@src(), identity_view.eyeIcon(!hidden), if (hidden) "Show in the graph" else "Hide from the graph", false)) {
            fw.close();
            toggleHidden(ref);
        }
    }
    if (ref.kind == .local) {
        if (menuIcon(@src(), dvui.entypo.pencil, "Rename…", false)) {
            fw.close();
            app.askNameWith(.rename_branch, ref.name, ref.name);
        }
    }
    if (menuIcon(@src(), dvui.entypo.copy, "Copy the name", false)) {
        fw.close();
        dvui.clipboardTextSet(ref.name);
    }

    if (ref.head) return;
    menuSeparator(3);
    // `-d` first: refusing to delete unmerged work is the point of the flag.
    // `-D` is offered, but behind the bar, never on one click.
    if (ref.kind == .local) {
        if (menuIcon(@src(), dvui.entypo.trash, "Delete branch", true)) {
            fw.close();
            repo_io.request(&.{ "branch", "-d", ref.name });
        }
        if (menuIcon(@src(), dvui.entypo.trash, "Delete, even unmerged…", true)) {
            fw.close();
            app.ask(.delete_branch_force, ref.name);
        }
    }
    if (ref.kind == .remote) {
        if (menuIcon(@src(), dvui.entypo.trash, "Delete on the remote…", true)) {
            fw.close();
            app.ask(.delete_remote_branch, ref.name);
        }
    }
    if (ref.kind == .tag) {
        if (menuIcon(@src(), dvui.entypo.trash, "Delete tag", true)) {
            fw.close();
            repo_io.request(&.{ "tag", "-d", ref.name });
        }
        if (menuIcon(@src(), dvui.entypo.trash, "Delete on the remote…", true)) {
            fw.close();
            app.ask(.delete_remote_tag, ref.name);
        }
    }
}

/// A right-click menu: a raised card with a border, a little room inside.
/// A menu's least width and its rows' padding above and below the caption:
/// GitComet's comfortable menus — 260 wide, rows about 30 high.
pub const MENU_MIN_W: f32 = 260;
pub const MENU_ROW_PAD_Y: f32 = 7;

pub fn contextMenu(cp: dvui.Point.Natural) *dvui.FloatingMenuWidget {
    return dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
        .background = true,
        .color_fill = .{ .color = style.surfaceRaised() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.popover,
        .padding = dvui.Rect.all(style.space.xs),
        .min_size_content = .{ .w = MENU_MIN_W },
    });
}

/// What the menu is about, over its rows: the name, and what kind of thing.
pub fn menuTitle(name: []const u8, kind: []const u8) void {
    var head = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{ .x = style.space.md, .y = style.space.xs, .w = style.space.md, .h = style.space.sm },
    });
    defer head.deinit();
    dvui.label(@src(), "{s}", .{name}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .max_size_content = .width(320), .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{kind}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
}

/// A menu row with its icon; `danger` reads it in red — the ones that lose
/// something.
pub fn menuIcon(src: std.builtin.SourceLocation, icon: []const u8, caption: []const u8, danger: bool) bool {
    return menuIconId(src, 0, icon, caption, danger);
}

/// As `menuIcon`, for a row built in a loop.
pub fn menuIconAt(src: std.builtin.SourceLocation, id: usize, icon: []const u8, caption: []const u8) bool {
    return menuIconId(src, id, icon, caption, false);
}

fn menuIconId(src: std.builtin.SourceLocation, id: usize, icon: []const u8, caption: []const u8, danger: bool) bool {
    var mi = dvui.menuItem(src, .{}, .{
        .id_extra = id,
        .tag = dialog_views.menuTag(caption),
        .expand = .horizontal,
        .corners = style.radius.input,
        // Lit with a tint of the accent, not filled with it: the row
        // under the pointer, or the keys, is found without shouting.
        .color_fill_hover = .{ .color = style.accentDim() },
        .padding = .{ .x = style.space.md, .y = MENU_ROW_PAD_Y, .w = style.space.lg, .h = MENU_ROW_PAD_Y },
    });
    defer mi.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer row.deinit();
    const color = if (danger) style.danger() else style.textMuted();
    dvui.icon(@src(), "menu_icon", icon, .{ .fill_color = .{ .color = color } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.md },
    });
    dvui.label(@src(), "{s}", .{caption}, .{
        .font = style.small(),
        .color_text = .{ .color = if (danger) style.danger() else style.text() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    return mi.activeRect() != null;
}

/// A hairline between groups of rows.
pub fn menuSeparator(id: usize) void {
    var line = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .max_size_content = .height(1),
        .background = true,
        .color_fill = .{ .color = style.border() },
        .margin = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.sm, .h = style.space.xs },
    });
    line.deinit();
}

// === Centre: the graph ===

pub fn graphPanel() void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
        .padding = dvui.Rect.all(0),
    });
    defer panel.deinit();

    const commits: []const git.Commit = if (app.history) |h| h.commits else &.{};
    // ↑ and ↓ before the list's scroll area sees them: once a row was
    // clicked the scroll area had the keyboard, and scrolled by a line
    // instead of moving to the next commit.
    if (!app.typing()) for (dvui.events()) |*e| {
        if (e.handled or e.evt != .key) continue;
        const ke = e.evt.key;
        if (ke.action == .up) continue;
        if (app.pressed(ke, .up, false) or app.pressed(ke, .down, false)) {
            e.handled = true;
            app.stepCommit(if (app.pressed(ke, .up, false)) -1 else 1);
        }
    };

    const filtering = listFiltered();
    search_view.updateSearchHits();

    // Listed before anything is drawn: the scrollbar needs the total, and the
    // bar above says how many of them there are.
    // In the frame's arena: this is every frame a filter is on, and the heap
    // is not for what a frame throws away.
    const frame = dvui.currentWindow().arena();
    var shown: std.ArrayList(u32) = .empty;
    defer shown.deinit(frame);
    if (filtering) shownRows(frame, commits, &shown);
    const matches = shown.items.len;

    // A search or an author picked leaves the graph as it is, the commits
    // that do not match faded; only a file's history narrows the list.
    const narrowed = listNarrowed();
    var hit: []bool = &.{};
    if (filtering and !narrowed) {
        hit = dvui.currentWindow().arena().alloc(bool, commits.len) catch &.{};
        @memset(hit, false);
        if (hit.len == commits.len) for (shown.items) |i| {
            hit[i] = true;
        };
    }

    list_total = commits.len;
    list_matches = matches;
    list_filtering = filtering;
    graphNotes();
    columnHeader(@src(), !narrowed);
    // Over the rows, so after them: deferred, it runs once they are drawn.
    defer if (search_open or app.commit_filter.items.len > 0) floatingSearch();

    if (commits.len == 0) {
        dialog_views.emptyState(@src(), tab_strip.open_error orelse if (author_only.items.len > 0) "No commit by the authors picked." else "No commits yet.");
        return;
    }

    // A new search brings its first match into view.
    const query = std.hash.Wyhash.hash(author_only.items.len, app.commit_filter.items);
    if (query != last_query) {
        last_query = query;
        if (filtering and matches > 0) if (listRow(shown.items[0], shown.items)) |row| app.revealCommit(row);
    }

    // A `path:` or `code:` search git refused says why, in place of the list.
    if (filtering and matches == 0 and (narrowed or search_view.search_hits.err.items.len > 0)) {
        // `path:` and `code:` still running have found nothing yet, not nothing.
        dialog_views.emptyState(@src(), if (search_view.search_hits.err.items.len > 0)
            search_view.search_hits.err.items
        else if (search_view.search_hits.running != null and !search_view.search_hits.ready)
            "Loading the commits that match…"
        else
            "No commit matches that.");
        return;
    }

    // A row for the uncommitted changes, above the first commit. Not in a
    // file's history: it is not one of its commits.
    const wip = !narrowed and search_view.changeCount() > 0;
    const extra: usize = if (wip) 1 else 0;
    const total = if (narrowed) matches else commits.len + extra;

    const rh = style.graph_row;
    app.graph_scroll.virtual_size.h = @as(f32, @floatFromInt(total)) * rh;

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &app.graph_scroll }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer scroll.deinit();

    const width = @max(app.graph_scroll.viewport.w, 320);

    // Only the rows on screen are built. 5000 commits is 5000 sets of widgets a
    // frame otherwise, and the whole point of a fixed row height is that the
    // visible range is arithmetic.
    const top = @max(0, app.graph_scroll.viewport.y);
    const first_visible: usize = @intFromFloat(@floor(top / rh));
    const rows_visible: usize = @intFromFloat(@ceil(app.graph_scroll.viewport.h / rh) + 2);
    // Held to the end of the list: when the history just got shorter — a
    // branch shown alone — the scroll position still points past it until
    // the scroll area catches up next frame.
    const first = @min(first_visible -| 1, total);
    const last = @min(total, first + rows_visible + 2);

    if (narrowed) {
        // A file's history is a plain list: the lanes describe the whole
        // history, and drawing a subset of them would draw a history that
        // never happened.
        for (shown.items[first..last], first..) |commit_index, row| {
            search_view.commitRow(@src(), row, commit_index, width, rh, false, false);
        }
        return;
    }

    if (wip and first == 0) search_view.wipRow(@src(), width);

    for (first..last) |i| {
        if (i < extra) continue;
        const index = i - extra;
        search_view.commitRow(@src(), i, index, width, rh, true, filtering and index < hit.len and !hit[index]);
    }

    // The lanes are drawn in one pass over a canvas spanning the whole virtual
    // height: a curve joins two rows, so drawing it inside either one would
    // clip it at the row boundary.
    search_view.drawLanes(@src(), first, last, extra, rh);
}

/// The names over the list's columns, the sortable ones clickable.
fn columnHeader(src: std.builtin.SourceLocation, with_lanes: bool) void {
    var head = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer head.deinit();

    // The rows sit in a scroll area that keeps its scrollbar's width on the
    // right whenever the list overflows; the header has to keep the same, or
    // every column header sits that far right of its column.
    const bar_w: f32 = if (app.graph_scroll.virtual_size.h > app.graph_scroll.viewport.h + 0.5) dvui.ScrollBarWidget.defaults.min_sizeGet().w else 0;

    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
            .min_size_content = .{ .h = 28 },
            .padding = .{ .x = style.space.lg, .w = style.space.lg + bar_w },
        });
        defer bar.deinit();
        const rs = bar.data().contentRectScale();
        // The widths dragged before any cell is drawn: drawn first, the
        // header would show last frame's widths under this frame's rows.
        const cols = columnsShown();
        const edges = columnEdges(rs);
        if (cols.author) columnHandle(@src(), 0, edges.author, rs, &col_author);
        if (cols.sha) columnHandle(@src(), 1, edges.sha - style.space.xs * rs.s, rs, &col_sha);
        columnHandle(@src(), 2, edges.date - style.space.xs * rs.s, rs, &col_time);
        if (with_lanes) {
            // Dragged from the auto width, it starts from what is shown.
            if (search_view.graph_width == 0) search_view.graph_width_drag = search_view.graphColumn() else search_view.graph_width_drag = search_view.graph_width;
            const before = search_view.graph_width_drag;
            columnHandleDir(@src(), 3, rs.r.x + search_view.graphRuleX() * rs.s, rs, &search_view.graph_width_drag, 1, search_view.GRAPH_MIN_W, search_view.GRAPH_MAX_W);
            if (search_view.graph_width_drag != before) {
                search_view.graph_width = search_view.graph_width_drag;
                tab_strip.saveWorkspace();
            }
            // The branch column's right edge: wider shows more of each name.
            search_view.branch_width_drag = search_view.branchColumn();
            columnHandleDir(@src(), 4, rs.r.x + search_view.branchColumn() * rs.s, rs, &search_view.branch_width_drag, 1, search_view.BRANCH_MIN_W, search_view.BRANCH_MAX_W);
            if (search_view.branch_width_drag != search_view.branchColumn()) {
                search_view.branch_width = search_view.branch_width_drag;
                tab_strip.saveWorkspace();
            }
        }

        const lane_w: f32 = if (with_lanes) search_view.graphLead() else 0;
        if (with_lanes) {
            // GitKraken's heads: the branch column's, then the graph's.
            {
                const bw = search_view.branchColumn();
                // Which branches the graph draws, in the column of the
                // branches, at the end of its name.
                var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{ .tag = "header:branches", .min_size_content = .{ .w = bw }, .max_size_content = .width(bw), .gravity_y = 0.5, .background = false });
                defer cell.deinit();
                var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
                dvui.label(@src(), "{s}", .{fitText(&buf, "BRANCH / TAG", style.section(), bw - HEADER_INSET - style.space.sm - search_view.BRANCH_MENU_W)}, .{
                    .font = style.section(),
                    .color_text = .{ .color = style.textFaint() },
                    .gravity_y = 0.5,
                    .padding = .{ .x = HEADER_INSET },
                });
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                dialog_views.graphBranchMenu(@src());
            }
            // The graph's own head: its width, nothing in it.
            var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{ .min_size_content = .{ .w = lane_w - search_view.branchColumn() }, .max_size_content = .width(lane_w - search_view.branchColumn()), .gravity_y = 0.5, .background = false });
            cell.deinit();
        }
        headerCell(@src(), "MESSAGE", 0, true, false);
        if (cols.author) authorHeader();
        if (cols.sha) headerCell(@src(), "COMMIT", col_sha, false, false);
        headerCell(@src(), "DATE", col_time, false, false);
        columnRules(bar.data().contentRectScale(), with_lanes);
    }
}

/// The authors the list is narrowed to, by `authorKey`; none is everyone.
pub var author_only: std.ArrayList([]u8) = .empty;
/// What the authors' menu is narrowed to.
pub var author_filter: std.ArrayList(u8) = .empty;

/// Who wrote a commit, as the filter goes by them: name and address
/// together, "name\nemail", as `git shortlog -sne` counts people. Not the
/// address alone: a team or a bot shares one under several names. Not the
/// name alone: two people share names. One person under two spellings is
/// one key where the repository's .mailmap says so, which the history is
/// read through. In `a`.
pub fn authorKey(a: std.mem.Allocator, name: []const u8, email: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}\n{s}", .{ name, email }) catch name;
}

/// The name and the address a key holds.
fn keyName(key: []const u8) []const u8 {
    return key[0 .. std.mem.indexOfScalar(u8, key, '\n') orelse key.len];
}

fn keyEmail(key: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, key, '\n') orelse return "";
    return key[at + 1 ..];
}

/// Two keys for one author: the same name, the address in any case.
pub fn sameAuthor(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, keyName(x), keyName(y)) and std.ascii.eqlIgnoreCase(keyEmail(x), keyEmail(y));
}

fn authorPicked(commit: git.Commit) bool {
    for (author_only.items) |k| {
        if (std.mem.eql(u8, keyName(k), commit.author) and std.ascii.eqlIgnoreCase(keyEmail(k), commit.email)) return true;
    }
    return false;
}

pub fn keyPicked(key: []const u8) bool {
    for (author_only.items) |k| if (sameAuthor(k, key)) return true;
    return false;
}

/// One author of the history: who, and how many commits.
pub const AuthorEntry = struct { key: []const u8, name: []const u8, email: []const u8, count: usize };

/// The history's authors, newest first, read once per history: rebuilt only
/// when `history_seq` moves. Their words are the history's.
pub var known_authors: std.ArrayList(AuthorEntry) = .empty;
pub var authors_seq: ?u64 = null;
/// What the index's keys are made in; emptied with it.
pub var authors_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn authorIndex() []const AuthorEntry {
    const h = app.history orelse return &.{};
    if (authors_seq == history_seq) return known_authors.items;
    // Narrowed to authors, the history holds theirs alone: the list read
    // before, everyone's, stays — its words are its own.
    if (author_only.items.len > 0 and authors_seq != null) return known_authors.items;
    known_authors.clearRetainingCapacity();
    _ = authors_arena.reset(.retain_capacity);
    authors_seq = history_seq;
    const a = authors_arena.allocator();
    var at: std.StringHashMapUnmanaged(usize) = .empty;
    defer at.deinit(app.gpa);
    for (h.commits) |commit| {
        // The address in one case: two cases of it are one person.
        const email = std.ascii.allocLowerString(a, commit.email) catch continue;
        const key = authorKey(a, commit.author, email);
        if (at.get(key)) |k| {
            known_authors.items[k].count += 1;
            continue;
        }
        at.put(app.gpa, key, known_authors.items.len) catch continue;
        known_authors.append(app.gpa, .{
            .key = key,
            .name = a.dupe(u8, commit.author) catch continue,
            .email = a.dupe(u8, commit.email) catch continue,
            .count = 1,
        }) catch continue;
    }
    return known_authors.items;
}

/// The author `key` names, if the history has them.
pub fn authorByKey(key: []const u8) ?AuthorEntry {
    for (authorIndex()) |entry| if (sameAuthor(entry.key, key)) return entry;
    return null;
}

/// Whether `entry` is you, by the address git commits as here.
fn isMe(entry: AuthorEntry) bool {
    return window_chrome.me_email.items.len > 0 and std.ascii.eqlIgnoreCase(entry.email, window_chrome.me_email.items);
}

/// What the filter is, in words: the one author's name, or how many.
fn authorFilterCaption(buf: []u8) []const u8 {
    if (author_only.items.len == 1) {
        const key = author_only.items[0];
        return if (authorByKey(key)) |e| e.name else keyName(key);
    }
    return std.fmt.bufPrint(buf, "{d} authors", .{author_only.items.len}) catch "authors";
}

/// The AUTHOR column's head, as a menu. Each author of the history once —
/// you first, those picked kept at the top even when the history shown has
/// none of theirs — with their picture, address and how many commits. A
/// click on one shows theirs alone; the box beside it adds or takes them
/// off; Enter in the field takes the first one shown.
fn authorHeader() void {
    var cell = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = col_author },
        .max_size_content = .width(col_author),
        .background = false,
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.md, .w = style.space.md },
        .padding = dvui.Rect.all(0),
    });
    defer cell.deinit();
    const picked = author_only.items.len;
    var button = window_chrome.DropButton.begin(@src(), .{
        .tag = "header:author",
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = picked > 0,
        .color_fill = .{ .color = style.accentDim() },
        .corners = style.radius.input,
        .padding = .{ .x = HEADER_INSET, .y = 1, .w = 2, .h = 1 },
    });
    button.min_w = 340;
    {
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        defer face.deinit();
        const ink = if (picked > 0) style.accent() else style.textFaint();
        if (picked == 0) {
            dvui.label(@src(), "AUTHOR", .{}, .{ .font = style.section(), .color_text = .{ .color = ink }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        } else {
            // Who it is narrowed to, by name, rather than how many.
            var cap_buf: [32]u8 = undefined;
            var fit_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
            dvui.label(@src(), "{s}", .{fitText(&fit_buf, authorFilterCaption(&cap_buf), style.smallBold(), col_author - 24)}, .{ .font = style.smallBold(), .color_text = .{ .color = ink }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
        dvui.icon(@src(), "author_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = ink } }, .{
            .min_size_content = .{ .w = 11, .h = 11 },
            .gravity_y = 0.5,
            .margin = .{ .x = 2 },
        });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse {
        author_filter.clearRetainingCapacity();
        return;
    };

    const field = dialog_views.searchField(@src(), &author_filter, "Find an author…", "author_filter", .{ .x = style.space.xs, .y = style.space.xs, .w = style.space.xs, .h = style.space.sm });
    dialog_views.focusOnce(field);
    if (app.pickRow(9000, "All authors", "", picked == 0, null)) {
        clearAuthors();
        m.close();
    }
    var list = dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .max_size_content = .height(@min(360, dvui.windowRect().h * 0.55)),
        .background = false,
    });
    defer list.deinit();

    const needle = std.mem.trim(u8, author_filter.items, " ");
    const index = authorIndex();
    var change: ?struct { key: []const u8, only: bool } = null;

    // Who the menu lists, in its order — the list, not its rows: a
    // history's authors can be thousands, and a row asks for its picture.
    const Listed = struct { entry: AuthorEntry, picked: bool, has_commit: bool };
    var listed: std.ArrayList(Listed) = .empty;
    const arena = dvui.currentWindow().arena();
    // Those picked first, kept even where the history shown has none of
    // theirs: the only place they can be taken off from.
    for (author_only.items) |key| {
        const entry = authorByKey(key) orelse AuthorEntry{ .key = key, .name = keyName(key), .email = keyEmail(key), .count = 0 };
        if (!authorShownBy(entry, needle)) continue;
        listed.append(arena, .{ .entry = entry, .picked = true, .has_commit = index.len > 0 and entry.count > 0 }) catch break;
    }
    // You, then everyone else, newest first.
    for ([_]bool{ true, false }) |mine| {
        for (index) |entry| {
            if (isMe(entry) != mine or keyPicked(entry.key)) continue;
            if (!authorShownBy(entry, needle)) continue;
            listed.append(arena, .{ .entry = entry, .picked = false, .has_commit = true }) catch break;
        }
    }
    if (listed.items.len == 0) dialog_views.dropHeading(@src(), 0, "NO AUTHOR BY THAT NAME");

    // Only the rows in sight are built.
    {
        var rows = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
        defer rows.deinit();
        const in_sight = commit_view.rowsInSight(rows.data(), listed.items.len, AUTHOR_ROW_H);
        commit_view.rowsSpacer(@src(), 0, in_sight.first, AUTHOR_ROW_H);
        for (listed.items[in_sight.first..in_sight.last], in_sight.first..) |l, i| {
            if (authorRow(i, l.entry, l.picked, l.has_commit)) |only| change = .{ .key = l.entry.key, .only = only };
        }
        commit_view.rowsSpacer(@src(), 1, listed.items.len - in_sight.last, AUTHOR_ROW_H);
    }

    if (dialog_views.search_entered == field) {
        dialog_views.search_entered = null;
        if (listed.items.len > 0) change = .{ .key = listed.items[0].entry.key, .only = true };
    }
    if (change) |c| {
        if (c.only) {
            onlyAuthor(c.key);
            m.close();
        } else toggleAuthor(c.key);
    }
}

/// Whether what is typed over the authors' menu lets `entry` through: its
/// name or its address.
fn authorShownBy(entry: AuthorEntry, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.findIgnoreCase(entry.name, needle) != null or std.ascii.findIgnoreCase(entry.email, needle) != null;
}

/// One author in the menu: the box that adds or takes them off, then the
/// row itself — their picture, name, address, how many commits — whose click
/// shows theirs alone. Null when neither was clicked; true for "theirs
/// alone", false for the box.
/// An author's row in the authors' menu, held to one height: the menu builds
/// only the rows in sight and stands spacers for the rest. 28.15 is what its
/// picture and padding came to.
const AUTHOR_ROW_H: f32 = 29;

fn authorRow(id: usize, entry: AuthorEntry, picked: bool, has_commit: bool) ?bool {
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = AUTHOR_ROW_H },
        .max_size_content = .height(AUTHOR_ROW_H),
        .background = false,
    });
    defer line.deinit();
    var on = picked;
    const toggled = dvui.checkbox(@src(), &on, null, .{ .gravity_y = 0.5, .margin = .{ .x = style.space.sm, .w = 2 } });

    var mi = dvui.menuItem(@src(), .{}, .{
        .tag = dialog_views.frameTag("author", entry.name),
        .expand = .horizontal,
        .corners = style.radius.input,
        .color_fill_hover = .{ .color = style.accentDim() },
        .padding = .{ .x = style.space.sm, .y = 5, .w = style.space.md, .h = 5 },
    });
    var chosen = false;
    {
        defer mi.deinit();
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer face.deinit();
        if (has_commit) search_view.avatarSized(@src(), 0, .{ .id = std.mem.zeroes(git.Oid), .summary = "", .author = entry.name, .email = entry.email, .time = 0 }, null, null, 18);
        dvui.label(@src(), "{s}", .{entry.name}, .{
            .font = if (picked) style.smallBold() else style.small(),
            .color_text = .{ .color = style.text() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
        if (isMe(entry)) dvui.label(@src(), "you", .{}, .{ .font = style.tinyBold(), .color_text = .{ .color = style.accent() }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "{s}", .{entry.email}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .margin = .{ .x = style.space.sm },
            .padding = dvui.Rect.all(0),
        });
        dvui.label(@src(), "{d}", .{entry.count}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        // Read before the item closes: after, its data is gone.
        chosen = mi.activeRect() != null;
    }
    if (chosen) return true;
    if (toggled) return false;
    return null;
}

/// The list narrowed to `key`'s commits alone.
pub fn onlyAuthor(key: []const u8) void {
    _ = authorIndex();
    clearNames(&author_only);
    addAuthor(key);
    authorsChanged();
}

pub fn toggleAuthor(key: []const u8) void {
    _ = authorIndex();
    for (author_only.items, 0..) |k, i| if (sameAuthor(k, key)) {
        app.gpa.free(author_only.orderedRemove(i));
        return authorsChanged();
    };
    addAuthor(key);
    authorsChanged();
}

fn addAuthor(key: []const u8) void {
    const owned = app.gpa.dupe(u8, key) catch return;
    author_only.append(app.gpa, owned) catch app.gpa.free(owned);
}

/// Everyone again.
pub fn clearAuthors() void {
    if (author_only.items.len == 0) return;
    clearNames(&author_only);
    authorsChanged();
}

/// The history read again, narrowed to the authors picked — the others'
/// commits left out, the lanes joining what is left — off the window's
/// thread: one person's commits can be far back.
fn authorsChanged() void {
    app.graph_scroll.viewport.y = 0;
    // Not in the middle of a frame: the rows being drawn index the history
    // as it is. Once the frame is done.
    if (tab_strip.in_frame) authors_dirty = true else refilterHistory();
}

pub var authors_dirty = false;

/// A fixed-width cell of the commit list, its text centred and cut with "…"
/// where it is too long.
pub fn centerCell(src: std.builtin.SourceLocation, id: usize, text: []const u8, font: dvui.Font, width: f32, margin: dvui.Rect) dvui.Rect.Physical {
    return listCell(src, id, text, font, width, margin, false);
}

/// Where a left-aligned column's caption starts inside its header cell.
const HEADER_INSET: f32 = 4;

pub fn listCell(src: std.builtin.SourceLocation, id: usize, text: []const u8, font: dvui.Font, width: f32, margin: dvui.Rect, left: bool) dvui.Rect.Physical {
    var cell = dvui.box(src, .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = width, .h = font.textHeight() },
        .max_size_content = .width(width),
        .gravity_y = 0.5,
        .margin = margin,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer cell.deinit();
    var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
    const inset: f32 = if (left) HEADER_INSET else 0;
    dvui.label(@src(), "{s}", .{fitText(&buf, text, font, width - inset)}, .{
        .font = font,
        .color_text = .{ .color = style.textFaint() },
        .gravity_x = if (left) 0 else 0.5,
        .gravity_y = 0.5,
        .padding = .{ .x = inset },
    });
    return cell.data().borderRectScale().r;
}

/// The resizable columns' widths, from the header's handles. The message
/// column takes whatever is left.
pub var col_author: f32 = style.author_column;
pub var col_sha: f32 = style.sha_column;
pub var col_time: f32 = style.time_column;
const COL_MIN: f32 = 40;
const COL_MAX: f32 = 400;

/// `text` cut to fit `width` at `font`, ending in "…" where it was cut.
/// Whole UTF-8 sequences only; the cut point is found by halving.
pub fn fitText(buf: *[rebase_view.MAX_SHOWN_LINE]u8, text: []const u8, font: dvui.Font, width: f32) []const u8 {
    if (width <= 0 or font.textSize(text).w <= width) return text;
    const ellipsis = "…";
    var lo: usize = 0;
    var hi: usize = @min(text.len, buf.len - ellipsis.len);
    while (lo < hi) {
        var mid = (lo + hi + 1) / 2;
        while (mid > 0 and mid < text.len and text[mid] & 0xC0 == 0x80) mid -= 1;
        if (mid <= lo) break;
        @memcpy(buf[0..mid], text[0..mid]);
        @memcpy(buf[mid..][0..ellipsis.len], ellipsis);
        if (font.textSize(buf[0 .. mid + ellipsis.len]).w <= width) lo = mid else hi = mid - 1;
    }
    var end = lo;
    while (end > 0 and end < text.len and text[end] & 0xC0 == 0x80) end -= 1;
    // Not ending on a space before the dots.
    while (end > 0 and text[end - 1] == ' ') end -= 1;
    @memcpy(buf[0..end], text[0..end]);
    @memcpy(buf[end..][0..ellipsis.len], ellipsis);
    return buf[0 .. end + ellipsis.len];
}

/// The width a column's handle is dragged to, before its limits: one drag
/// at a time.
var column_drag_raw: f32 = 0;

/// A grab handle on a column's left edge: dragged, it resizes the column to
/// its right, which is anchored at the window's edge — so the message column
/// is what gives or takes the room.
fn columnHandle(src: std.builtin.SourceLocation, id: usize, x: f32, rs: dvui.RectScale, width: *f32) void {
    columnHandleDir(src, id, x, rs, width, -1, COL_MIN, COL_MAX);
}

/// As `columnHandle`, for a column on either side of its handle: `dir` -1
/// grows the column as the handle moves left, +1 as it moves right.
fn columnHandleDir(src: std.builtin.SourceLocation, id: usize, x: f32, rs: dvui.RectScale, width: *f32, dir: f32, min: f32, max: f32) void {
    const s = rs.s;
    // Never wider than the message can give: past `MESSAGE_MIN` the list
    // would hide a column — the author dragged over the message vanished.
    const cap = @max(min, @min(max, width.* + messageSpare()));
    const hit: dvui.Rect.Physical = .{ .x = x - 4 * s, .y = rs.r.y, .w = 8 * s, .h = rs.r.h };
    var handle = dvui.box(src, .{}, .{ .id_extra = id, .rect = .{}, .background = false });
    defer handle.deinit();
    const hid = handle.data().id;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        if (!dvui.eventMatch(e, .{ .id = hid, .r = hit })) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .position => dvui.cursorSet(.arrow_w_e),
            .press => if (me.button.pointer()) {
                e.handle(@src(), handle.data());
                column_drag_raw = width.*;
                dvui.captureMouse(handle.data(), e.num);
                dvui.dragPreStart(me.button, me.p, .{ .cursor = .arrow_w_e });
            },
            .release => if (dvui.captured(hid)) {
                e.handle(@src(), handle.data());
                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
            },
            .motion => if (dvui.captured(hid)) {
                e.handle(@src(), handle.data());
                if (dvui.dragging(me, null)) |dp| {
                    // Unclamped as dragged, so past a limit and back the
                    // edge stays under the pointer.
                    column_drag_raw += dir * dp.x / s;
                    width.* = std.math.clamp(column_drag_raw, min, cap);
                    dvui.refresh(null, @src(), hid);
                }
            },
            else => {},
        }
    }
}

/// The thin rules between the columns, drawn by hand at the columns' left
/// edges — measured from the right, where the fixed-width columns sit.
fn columnRules(rs: dvui.RectScale, with_lanes: bool) void {
    const r = rs.r;
    const s = rs.s;
    const cols = columnsShown();
    const edges = columnEdges(rs);
    // The full border colour: the subtle one vanishes on the rows' ground.
    const color = style.border();
    const xs = [_]?f32{
        // The branch column's and the graph's edges too, where the lanes are
        // drawn: columns like the others, each rule where its handle is.
        if (with_lanes) r.x + search_view.branchColumn() * s else null,
        if (with_lanes) r.x + search_view.graphRuleX() * s else null,
        if (cols.author) edges.author else null,
        if (cols.sha) edges.sha - style.space.xs * s else null,
        edges.date - style.space.xs * s,
    };
    for (xs) |maybe| {
        const x = maybe orelse continue;
        const line: dvui.Rect.Physical = .{ .x = x, .y = r.y + 3 * s, .w = @max(1, s), .h = r.h - 6 * s };
        line.fill(.{}, .{ .color = .{ .color = color }, .fade = 0 });
    }
}

/// Where the fixed columns start, physical x, measured from the right edge
/// of `rs` where they sit. A hidden column takes no room.
fn columnEdges(rs: dvui.RectScale) struct { author: f32, sha: f32, date: f32 } {
    const cols = columnsShown();
    const date = rs.r.x + rs.r.w - col_time * rs.s;
    const sha = date - (if (cols.sha) col_sha else 0) * rs.s;
    const author = sha - (if (cols.author) col_author + 2 * style.space.md else 0) * rs.s;
    return .{ .author = author, .sha = sha, .date = date };
}

/// Least the message column keeps before the optional columns give way.
pub const MESSAGE_MIN: f32 = 220;

/// How much wider the other columns may get before the message is down to
/// `MESSAGE_MIN`, with the columns shown now.
pub fn messageSpare() f32 {
    const w = app.graph_scroll.viewport.w;
    if (w <= 0) return std.math.inf(f32);
    const cols = columnsShown();
    const room = w - 2 * style.space.lg - search_view.graphLead() - col_time -
        (if (cols.sha) col_sha else 0) - (if (cols.author) col_author + 2 * style.space.md else 0);
    return @max(0, room - MESSAGE_MIN);
}

/// The optional columns, given up when the message would otherwise get less
/// than `MESSAGE_MIN` — the sha first, then the author. The date stays: it is
/// what the list is in the order of.
pub fn columnsShown() struct { author: bool, sha: bool } {
    const w = app.graph_scroll.viewport.w;
    if (w <= 0) return .{ .author = true, .sha = true };
    var room = w - 2 * style.space.lg - search_view.graphLead() - col_time - col_sha - col_author - 2 * style.space.md;
    const sha = room >= MESSAGE_MIN;
    if (!sha) room += col_sha;
    return .{ .author = room >= MESSAGE_MIN, .sha = sha };
}

/// A column's name over it. `inset` for the author's, whose cells sit
/// between margins of their own.
fn headerCell(src: std.builtin.SourceLocation, caption: []const u8, width: f32, expand: bool, inset: bool) void {
    var cell = dvui.box(src, .{}, .{
        .expand = if (expand) .horizontal else .none,
        .min_size_content = .{ .w = width },
        .max_size_content = if (expand) null else .width(width),
        .background = false,
        .gravity_y = 0.5,
        .margin = if (inset) .{ .x = style.space.md, .w = style.space.md } else dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    defer cell.deinit();
    dvui.label(@src(), "{s}", .{caption}, .{
        .font = style.section(),
        .color_text = .{ .color = style.textFaint() },
        // The fixed columns' names over the middle of them, as their cells
        // are; the message column reads from the left.
        .gravity_x = if (expand) 0.0 else 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// The history's search: a card floating over the middle of the list's top,
/// opened by the toolbar's Search or Ctrl+F — out of the way the rest of the
/// time, which gives the list its row back.
pub var search_open: bool = false;

fn floatingSearch() void {
    // A floating widget, a subwindow of its own over the list: drawn as a
    // plain box on top of the rows, its × lost every click to the row under
    // it, which saw the events first. Placed in window coordinates, centred
    // over the list's top.
    const area = dvui.windowRectScale().rectFromPhysical(dvui.parentGet().data().contentRectScale().r);
    const w = @min(520, area.w - 32);
    var float: dvui.FloatingWidget = undefined;
    float.init(@src(), .{}, .{ .rect = .{ .x = area.x + (area.w - w) / 2, .y = area.y + 30, .w = w, .h = 42 } });
    defer float.deinit();
    // The card is the field: one frame, the count and the × inside it.
    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.accent().opacity(0.5) },
        .corners = style.radius.input,
        .padding = .{ .x = style.space.xs, .w = style.space.xs },
    });
    defer card.deinit();
    dialog_views.focusOnce(dialog_views.searchFieldIn(@src(), &app.commit_filter, "Search commits — author:, msg:, path:, code:, after:", "commit_filter", dvui.Rect.all(0), false));
    if (search_view.search_hits.running != null) rebase_view.loadingSpinner(@src());
    if (list_filtering) {
        dvui.label(@src(), "{d} of {d}", .{ list_matches, list_total }, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textMuted() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.sm },
            .padding = dvui.Rect.all(0),
        });
    }
    if (dialog_views.iconButtonTagged(@src(), "search_close", "Close the search — Esc", dvui.entypo.cross, style.textMuted(), "search:close")) closeSearch();
}

pub fn closeSearch() void {
    search_open = false;
    app.commit_filter.clearRetainingCapacity();
    clearFileHistory();
}

/// What the list shows, as its last frame counted it, for the toolbar.
var list_total: usize = 0;
pub var list_matches: usize = 0;
var list_filtering: bool = false;

/// Over the list, only while there is something to say: branches hidden
/// from the graph, or the file whose history it is narrowed to.
fn graphNotes() void {
    const hidden = graph_only.items.len == 0 and graph_hidden.items.len > 0;
    const by_author = author_only.items.len > 0;
    if (!hidden and file_history.items.len == 0 and !by_author) return;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .padding = .{ .x = style.space.md, .y = style.space.xs, .w = style.space.md, .h = style.space.xs },
    });
    defer bar.deinit();
    // Hidden ones: say so, and bring them back in one click.
    if (hidden) {
        const caption = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d} hidden — show all", .{graph_hidden.items.len}) catch "Show all";
        if (dialog_views.chipButton(@src(), identity_view.eyeIcon(true), caption, false)) unhideAll();
    }
    // Narrowed to authors: who, how many of the commits shown are theirs,
    // and back to everyone in one click — or, with none of theirs here,
    // saying so rather than leaving a faded graph to puzzle over.
    if (by_author) {
        var cap_buf: [32]u8 = undefined;
        const who = authorFilterCaption(&cap_buf);
        const n = if (app.history) |h| h.commits.len else 0;
        const caption = if (n == 0)
            std.fmt.allocPrint(dvui.currentWindow().arena(), "No commit by {s} — show all authors", .{who}) catch "Show all authors"
        else
            std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · {d} commit{s} — show all authors", .{ who, n, window_chrome.plural(n) }) catch "Show all authors";
        if (dialog_views.chipButton(@src(), dvui.entypo.users, caption, true)) clearAuthors();
    }
    if (file_history.items.len > 0) {
        dvui.label(@src(), "history of {s}", .{file_history.items}, .{
            .font = style.small(),
            .color_text = .{ .color = style.accent() },
            .gravity_y = 0.5,
            .max_size_content = .width(260),
            .margin = .{ .x = style.space.md },
            .padding = dvui.Rect.all(0),
        });
    }
}

/// The path the graph is narrowed to, empty for the whole history, and which
/// commits touched it: one flag per commit in `history`, re-marked whenever
/// that is re-read, because the indices move with it.
pub var file_history: std.ArrayList(u8) = .empty;
var file_history_hits: []bool = &.{};

pub fn showFileHistory(path: []const u8) void {
    clearFileHistory();
    file_history.appendSlice(app.gpa, path) catch return;
    markFileHistory();
    app.graph_scroll.viewport.y = 0;
}

pub fn markFileHistory() void {
    app.gpa.free(file_history_hits);
    file_history_hits = &.{};
    const r = app.repo orelse return;
    const h = app.history orelse return;
    file_history_hits = r.touching(app.gpa, h.commits, file_history.items) catch {
        app.setCommandError("Could not read that file's history.");
        return clearFileHistory();
    };
}

pub fn clearFileHistory() void {
    app.gpa.free(file_history_hits);
    file_history_hits = &.{};
    file_history.clearRetainingCapacity();
}

/// Whether the list shows only some commits: searched, a file's history, or
/// narrowed to some authors.
pub fn listFiltered() bool {
    return app.commit_filter.items.len > 0 or file_history.items.len > 0 or author_only.items.len > 0;
}

/// Whether the list holds only the commits shown, a file's history; a
/// search or an author keeps every commit and fades the others.
fn listNarrowed() bool {
    return file_history.items.len > 0;
}

/// The search last seen, to bring a new one's first match into view.
var last_query: u64 = 0;

/// Where history commit `index` sits in the list on screen, given the
/// commits `shownRows` lists: among them in a narrowed list, else at its own
/// place under the uncommitted-changes row.
pub fn listRow(index: u32, shown: []const u32) ?usize {
    if (listNarrowed()) return std.mem.indexOfScalar(u32, shown, index);
    return index + @intFromBool(search_view.changeCount() > 0);
}

pub fn commitShown(commit: git.Commit, index: usize, terms: []const Term) bool {
    if (author_only.items.len > 0 and !authorPicked(commit)) return false;
    if (file_history.items.len > 0) {
        if (index >= file_history_hits.len or !file_history_hits[index]) return false;
    }
    return commitMatches(commit, terms);
}

/// The commits a filtered list shows, as history indices in its order. The
/// search is parsed once here, not once per commit.
pub fn shownRows(a: std.mem.Allocator, commits: []const git.Commit, out: *std.ArrayList(u32)) void {
    var buf: [MAX_TERMS]Term = undefined;
    const terms = parseQuery(app.commit_filter.items, &buf);
    for (commits, 0..) |commit, i| {
        if (!commitShown(commit, i, terms)) continue;
        out.append(a, @intCast(i)) catch return;
    }
}

/// One part of a search: a bare word, or `key:value` for one field.
/// Every part must match. `path:` and `code:` ask git, see `SearchHits`.
pub const Term = struct {
    kind: enum { any, author, message, sha, after, before, path, code },
    text: []const u8,
    /// `after:`/`before:` as seconds since the epoch.
    time: i64 = 0,
};

pub const MAX_TERMS = 16;

/// The search box's text cut into terms. Spaces separate them, except in
/// double quotes: `author:"Ann Lee"`.
pub fn parseQuery(text: []const u8, out: *[MAX_TERMS]Term) []Term {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        while (i < text.len and text[i] == ' ') i += 1;
        if (i == text.len) break;
        const start = i;
        var quoted = false;
        while (i < text.len and (quoted or text[i] != ' ')) : (i += 1) {
            if (text[i] == '"') quoted = !quoted;
        }
        const raw = text[start..i];
        var term: Term = .{ .kind = .any, .text = std.mem.trim(u8, raw, "\"") };
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
            const keys = [_]struct { []const u8, @FieldType(Term, "kind") }{ .{ "author", .author }, .{ "msg", .message }, .{ "message", .message }, .{ "sha", .sha }, .{ "after", .after }, .{ "before", .before }, .{ "path", .path }, .{ "code", .code } };
            for (keys) |k| {
                if (std.ascii.eqlIgnoreCase(raw[0..colon], k[0])) {
                    term = .{ .kind = k[1], .text = std.mem.trim(u8, raw[colon + 1 ..], "\"") };
                }
            }
        }
        // A date that does not read as one — half typed, or 2026-02-31 — is
        // left out of the search, the same for `after:` and `before:`, rather
        // than turned into 1970 and hiding everything.
        if (term.kind == .after or term.kind == .before) {
            term.time = parseDay(term.text) orelse continue;
        }
        if (term.text.len > 0) {
            out[n] = term;
            n += 1;
        }
    }
    return out[0..n];
}

/// "2026-10-22" as seconds since the epoch, at midnight UTC.
/// ponytail: UTC, not local midnight — Zit has no time zone code; a day's
/// edge is off by the local offset. Use the local zone if one ever lands.
pub fn parseDay(text: []const u8) ?i64 {
    var it = std.mem.splitScalar(u8, text, '-');
    const year = std.fmt.parseInt(std.time.epoch.Year, it.next() orelse return null, 10) catch return null;
    const month = std.fmt.parseInt(u8, it.next() orelse "1", 10) catch return null;
    const day = std.fmt.parseInt(u8, it.next() orelse "1", 10) catch return null;
    if (it.next() != null or year < 1 or month < 1 or month > 12 or day < 1) return null;
    if (day > std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)))) return null;
    const y: i64 = year;
    const m: i64 = month;
    const d: i64 = day;
    // Days from the civil date, Howard Hinnant's way.
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400;
}

/// Whether a commit is one of the search results: every term matches.
/// A bare word looks in the message, the author and the sha, the three
/// things anybody has in hand when they come looking for a commit.
pub fn commitMatches(commit: git.Commit, terms: []const Term) bool {
    var sha: [41]u8 = undefined;
    const hex = git.oidHex(commit.id, &sha);
    for (terms) |t| {
        const ok = switch (t.kind) {
            .any => std.ascii.findIgnoreCase(commit.summary, t.text) != null or
                std.ascii.findIgnoreCase(commit.author, t.text) != null or
                std.ascii.startsWithIgnoreCase(hex, t.text),
            .author => std.ascii.findIgnoreCase(commit.author, t.text) != null or
                std.ascii.findIgnoreCase(commit.email, t.text) != null,
            .message => std.ascii.findIgnoreCase(commit.summary, t.text) != null,
            .sha => std.ascii.startsWithIgnoreCase(hex, t.text),
            .after => commit.time >= t.time,
            .before => commit.time < t.time,
            .path, .code => search_view.search_hits.ready and search_view.search_hits.ids.contains(commit.id),
        };
        if (!ok) return false;
    }
    return true;
}
