const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const store = @import("../core/store.zig");
const avatars = @import("../github/avatar.zig");
const window_chrome = @import("window_chrome.zig");
const app = @import("../main.zig");

// === Tabs and groups ===

/// One repository in the strip.
///
/// A tab is a bookmark, not a live session: switching to one opens it, which
/// costs the revwalk that opening a repository has always cost. Keeping every
/// tab's snapshots alive to avoid that would multiply both the memory and the
/// invalidation rules, for something you can only look at one of at a time.
pub const Tab = struct {
    /// Working directory with its trailing slash, exactly as libgit2 resolved
    /// it, owned. Two ways of naming the same repository land on one tab.
    path: []u8,
};

/// A run of tabs in the strip. Named, it is a group — a coloured label
/// before its tabs, foldable to that label. Unnamed, it is tabs in no group.
pub const TabGroup = struct {
    name: []u8,
    tabs: std.ArrayList(Tab),
    color: u8 = 0,
    collapsed: bool = false,
    /// The workspace it is in, by index.
    ws: usize = 0,

    pub fn deinit(self: *TabGroup) void {
        for (self.tabs.items) |tab| app.gpa.free(tab.path);
        self.tabs.deinit(app.gpa);
        app.gpa.free(self.name);
        self.* = undefined;
    }
};

pub var groups: std.ArrayList(TabGroup) = .empty;
pub var active_group: usize = 0;
pub var active_tab: usize = 0;

/// Workspaces, GitComet's: named, coloured sets of groups, the strip showing
/// one at a time — switched in this window, keeping the view. The unnamed
/// one is "Default".
const Workspace = struct {
    name: []u8,
    color: u8 = 0,
    /// The group and tab it was on.
    group: usize = 0,
    tab: usize = 0,
};
pub var workspaces: std.ArrayList(Workspace) = .empty;
pub var active_ws: usize = 0;

pub fn workspaceName(w: Workspace) []const u8 {
    return if (w.name.len > 0) w.name else "Default";
}

/// Every workspace has a group, so a tab opened there has somewhere to go.
pub fn ensureWorkspaceGroups() void {
    for (workspaces.items, 0..) |_, w| {
        const has = for (groups.items) |g| {
            if (g.ws == w) break true;
        } else false;
        if (has) continue;
        const name = app.gpa.dupe(u8, DEFAULT_GROUP_NAME) catch continue;
        groups.append(app.gpa, .{ .name = name, .tabs = .empty, .ws = w }) catch app.gpa.free(name);
    }
}

pub fn freeWorkspaces() void {
    for (workspaces.items) |w| app.gpa.free(w.name);
    workspaces.clearRetainingCapacity();
    active_ws = 0;
}

/// Where the workspace file goes. Empty when the environment names nowhere —
/// and in tests, which is what keeps a test run from writing over the real one.
pub var config_dir: std.ArrayList(u8) = .empty;

/// Tabs in no group.
const DEFAULT_GROUP_NAME = "";
const LEGACY_DEFAULT_GROUP = "Main";

pub fn activeGroup() ?*TabGroup {
    if (active_group >= groups.items.len) return null;
    return &groups.items[active_group];
}

/// Bring back the groups from the last run.
///
/// Always leaves at least one group, so nothing downstream has to carry a case
/// for there being none.
pub fn loadWorkspace() void {
    var loaded = store.load(app.gpa, app.app_io, config_dir.items);
    defer loaded.deinit();

    remember_tabs = loaded.file.remember_tabs;
    prune_on_fetch = loaded.file.prune;
    integrations = loaded.file.integrations;
    avatars.use_github.store(integrations, .release);
    default_branch.clearRetainingCapacity();
    default_branch.appendSlice(app.gpa, loaded.file.default_branch) catch {};
    editor_cmd.clearRetainingCapacity();
    editor_cmd.appendSlice(app.gpa, loaded.file.editor) catch {};
    terminal_cmd.clearRetainingCapacity();
    terminal_cmd.appendSlice(app.gpa, loaded.file.terminal) catch {};
    show_avatars = loaded.file.avatars;

    // Turned off, the tabs are still written — so turning it back on brings
    // them back — but not opened.
    for (if (remember_tabs) loaded.file.groups else &.{}) |saved| {
        const name = app.gpa.dupe(u8, if (std.mem.eql(u8, saved.name, LEGACY_DEFAULT_GROUP))
            DEFAULT_GROUP_NAME
        else if (std.mem.eql(u8, saved.name, LEGACY_GROUP_MARK))
            GROUP_MARK
        else
            saved.name) catch continue;
        var group: TabGroup = .{ .name = name, .tabs = .empty, .color = saved.color, .collapsed = saved.collapsed, .ws = saved.workspace };

        for (saved.repos) |path| {
            const owned = app.gpa.dupe(u8, path) catch continue;
            group.tabs.append(app.gpa, .{ .path = owned }) catch app.gpa.free(owned);
        }

        groups.append(app.gpa, group) catch {
            group.deinit();
            continue;
        };
    }

    if (groups.items.len == 0) {
        const name = app.gpa.dupe(u8, DEFAULT_GROUP_NAME) catch return;
        groups.append(app.gpa, .{ .name = name, .tabs = .empty }) catch app.gpa.free(name);
    }

    active_group = @min(loaded.file.active_group, groups.items.len -| 1);
    active_tab = loaded.file.active_repo;
    // A file of before the workspaces: all its groups are in one.
    for (loaded.file.workspaces) |saved| {
        const name = app.gpa.dupe(u8, saved.name) catch continue;
        workspaces.append(app.gpa, .{ .name = name, .color = saved.color, .group = saved.group, .tab = saved.tab }) catch app.gpa.free(name);
    }
    if (workspaces.items.len == 0) if (app.gpa.dupe(u8, "")) |name| {
        workspaces.append(app.gpa, .{ .name = name }) catch app.gpa.free(name);
    } else |_| {};
    for (groups.items) |*g| if (g.ws >= workspaces.items.len) {
        g.ws = 0;
    };
    ensureWorkspaceGroups();
    active_ws = if (groups.items.len > 0) groups.items[active_group].ws else 0;
    app.dark_theme = loaded.file.dark;
    app.theme_index = if (app.dark_theme) 0 else 1;
    for (style.themes, 0..) |t, i| if (std.mem.eql(u8, t.name, loaded.file.theme)) {
        app.theme_index = i;
        app.dark_theme = t.dark;
    };
    style.ui_scale = std.math.clamp(loaded.file.ui_text, 0.8, 1.3);
    style.code_scale = std.math.clamp(loaded.file.code_text, 0.8, 1.5);
    for (loaded.file.recent) |path| addRecent(path, false);
    app.commit_prefs = loaded.file.commit;
    auto_fetch_minutes = loaded.file.auto_fetch_minutes;
    app.graph_show_remote = loaded.file.show_remote_branches;
    app.graph_first_parent = loaded.file.first_parent;
    app.graph_width = loaded.file.graph_width;
    app.branch_width = loaded.file.branch_width;
    zoom = zoomStep(loaded.file.zoom);
    // The file's strings die with `loaded`.
    app.commit_template.clearRetainingCapacity();
    app.commit_template.appendSlice(app.gpa, app.commit_prefs.template) catch {};
    app.commit_prefs.template = "";
}

/// The strip and the settings to be written out. Asked for on every change
/// rather than only at exit — the run that loses your tabs is the one that
/// did not exit cleanly — but written once things have been quiet for
/// `SAVE_QUIET_NS`: a column dragged, a run of tabs moved, is one write, not
/// one a frame. A write that fails is tried again later and later, up to a
/// minute apart (`flushWorkspace`). Tests write at once; they read it back.
pub fn saveWorkspace() void {
    // Every change of tab comes through here: the workspace shown follows
    // the tab, and remembers where it is for when it is switched back to.
    if (activeGroup()) |g| active_ws = g.ws;
    if (active_ws < workspaces.items.len) {
        workspaces.items[active_ws].group = active_group;
        workspaces.items[active_ws].tab = active_tab;
    }
    if (config_dir.items.len == 0) return;
    // Outside a frame — at exit — there is no later: now.
    if (@import("builtin").is_test or !in_frame) {
        workspace_dirty = !writeWorkspace();
        return;
    }
    workspace_due_ns = dvui.frameTimeNS() + SAVE_QUIET_NS;
    workspace_dirty = true;
}

/// Between the start and the end of `appFrame`: where dvui's clock and
/// timers can be asked.
pub var in_frame = false;

const SAVE_QUIET_NS: i128 = 400 * std.time.ns_per_ms;
const SAVE_RETRY_MAX_NS: i128 = 60 * std.time.ns_per_s;
var workspace_dirty = false;
var workspace_due_ns: i128 = 0;
/// After a failed write, how long until the next try; doubled each time.
var workspace_backoff_ns: i128 = 0;

/// Write the workspace if it is due, and ask for a frame when it will be,
/// through `id`'s timer.
pub fn flushWorkspace(id: dvui.Id) void {
    if (!workspace_dirty) return;
    const now = dvui.frameTimeNS();
    if (now < workspace_due_ns) {
        dvui.timer(id, @intCast(@max(1, @divTrunc(workspace_due_ns - now, std.time.ns_per_us))));
        return;
    }
    if (writeWorkspace()) {
        workspace_dirty = false;
        workspace_backoff_ns = 0;
        return;
    }
    workspace_backoff_ns = @min(SAVE_RETRY_MAX_NS, @max(SAVE_QUIET_NS, workspace_backoff_ns * 2));
    workspace_due_ns = now + workspace_backoff_ns;
    dvui.timer(id, @intCast(@divTrunc(workspace_backoff_ns, std.time.ns_per_us)));
}

fn writeWorkspace() bool {
    var list: std.ArrayList(store.Group) = .empty;
    defer {
        for (list.items) |saved| app.gpa.free(saved.repos);
        list.deinit(app.gpa);
    }

    for (groups.items) |group| {
        const repos = app.gpa.alloc([]const u8, group.tabs.items.len) catch return false;
        for (group.tabs.items, 0..) |tab, i| repos[i] = tab.path;

        list.append(app.gpa, .{ .name = group.name, .repos = repos, .color = group.color, .collapsed = group.collapsed, .workspace = group.ws }) catch {
            app.gpa.free(repos);
            return false;
        };
    }

    var ws_list: std.ArrayList(store.Workspace) = .empty;
    defer ws_list.deinit(app.gpa);
    for (workspaces.items) |w| ws_list.append(app.gpa, .{ .name = w.name, .color = w.color, .group = w.group, .tab = w.tab }) catch return false;

    return store.save(app.gpa, app.app_io, config_dir.items, .{
        .groups = list.items,
        .workspaces = ws_list.items,
        .active_workspace = active_ws,
        .active_group = active_group,
        .active_repo = active_tab,
        .dark = app.dark_theme,
        .theme = style.themes[app.theme_index].name,
        .ui_text = style.ui_scale,
        .code_text = style.code_scale,
        .recent = recent.items,
        .auto_fetch_minutes = auto_fetch_minutes,
        .show_remote_branches = app.graph_show_remote,
        .first_parent = app.graph_first_parent,
        .graph_width = app.graph_width,
        .branch_width = app.branch_width,
        .remember_tabs = remember_tabs,
        .default_branch = default_branch.items,
        .editor = editor_cmd.items,
        .terminal = terminal_cmd.items,
        .avatars = show_avatars,
        .prune = prune_on_fetch,
        .integrations = integrations,
        .zoom = zoom,
        .commit = prefs: {
            var prefs = app.commit_prefs;
            prefs.template = app.commit_template.items;
            break :prefs prefs;
        },
    });
}

/// The whole window's zoom, over the system's own scale, as a browser's:
/// Ctrl+= and Ctrl+- a tenth at a time, Ctrl+0 back to 100 %. Remembered.
pub var zoom: f32 = 1.0;
pub const ZOOM_MIN: f32 = 0.7;
pub const ZOOM_MAX: f32 = 2.0;

/// `to` on the tenths and within the bounds: dvui's own steps add 0.1 to a
/// float, which drifts, and a file edited by hand can say anything.
pub fn zoomStep(to: f32) f32 {
    if (!std.math.isFinite(to)) return 1.0;
    return std.math.clamp(@round(to * 10) / 10, ZOOM_MIN, ZOOM_MAX);
}

/// Within a frame: the next one is laid out at the new size.
pub fn setZoom(to: f32) void {
    const z = zoomStep(to);
    dvui.currentWindow().content_scale = z;
    dvui.refresh(null, @src(), null);
    if (z == zoom) return;
    zoom = z;
    saveWorkspace();
}

/// The 6 key where it types a minus — AZERTY: SDL names the number row by
/// its digits on a French keyboard, so its "-" comes as 6. Asked of the
/// layout itself, so elsewhere Ctrl+6 stays nothing.
fn minusOnSix(ke: dvui.Event.Key) bool {
    if (ke.code != .six) return false;
    if (@import("builtin").is_test) return false;
    const c = dvui.backend.c;
    return c.SDL_GetKeyFromScancode(c.SDL_SCANCODE_6, c.SDL_KMOD_NONE, false) == c.SDLK_MINUS;
}

/// A "+" with a key of its own — QWERTZ: SDL calls it SDLK_PLUS, which dvui
/// has no name for, so it arrives unnamed. Whether the layout's "+" key is
/// the one down, asked of SDL.
fn plusKey(ke: dvui.Event.Key) bool {
    if (ke.code != .unknown) return false;
    if (@import("builtin").is_test) return false;
    const c = dvui.backend.c;
    const sc = c.SDL_GetScancodeFromKey(c.SDLK_PLUS, null);
    if (sc == c.SDL_SCANCODE_UNKNOWN) return false;
    const keys = c.SDL_GetKeyboardState(null);
    return keys[@intCast(sc)];
}

/// What a key asks of the zoom: the step, or back to 100 %. The keypad's as
/// well as the main row's; Cmd on a Mac, through dvui's own binds.
pub fn zoomKey(ke: dvui.Event.Key) ?f32 {
    const mod = ke.mod.control() and !ke.mod.alt();
    if ((mod and (ke.code == .equal or ke.code == .kp_add or plusKey(ke))) or ke.matchBind("zoom_in")) return zoom + 0.1;
    if ((mod and (ke.code == .minus or ke.code == .kp_subtract or minusOnSix(ke))) or ke.matchBind("zoom_out")) return zoom - 0.1;
    if (mod and !ke.mod.shift() and (ke.code == .zero or ke.code == .kp_0)) return 1.0;
    return null;
}

/// The General settings: what is saved with the workspace beside the tabs.
pub var remember_tabs: bool = true;
pub var prune_on_fetch: bool = true;
/// GitHub: off, no pull requests or issues in the sidebar or the strip, no
/// checks, no account — and no request goes to GitHub at all.
pub var integrations: bool = true;

/// The integrations turned on or off: what hangs off them is asked for
/// again, or let go.
pub fn setIntegrations(on: bool) void {
    integrations = on;
    avatars.use_github.store(on, .release);
    window_chrome.me_loaded = false;
    if (!on and app.active_view == .pulls) app.closePulls();
    avatars.setGithubRepo(if (on) app.githubRemote() else null);
    app.refreshRequests();
    saveWorkspace();
}
pub var default_branch: std.ArrayList(u8) = .empty;
/// The command a file opens with; empty for the system's own choice.
pub var editor_cmd: std.ArrayList(u8) = .empty;
/// The terminal Terminal opens, one of `known_terminals`; empty for the
/// first found.
pub var terminal_cmd: std.ArrayList(u8) = .empty;
/// Authors' pictures on the graph's commits; off, a dot for each.
pub var show_avatars: bool = true;

/// The arguments of a fetch of every remote, pruning or not as set; `quiet`
/// for the timer's own. Where git's own config says whether to prune — for
/// this repository or everywhere — git decides.
pub fn fetchAllArgs(quiet: bool) []const []const u8 {
    if (app.git_fetch_prune_set) return if (quiet) &.{ "fetch", "--all", "--quiet" } else &.{ "fetch", "--all" };
    return if (prune_on_fetch)
        (if (quiet) &.{ "fetch", "--all", "--prune", "--quiet" } else &.{ "fetch", "--all", "--prune" })
    else
        (if (quiet) &.{ "fetch", "--all", "--quiet" } else &.{ "fetch", "--all" });
}

/// Repositories whose tab was closed, newest first, owned. What the start
/// page lists besides the open tabs.
pub var recent: std.ArrayList([]const u8) = .empty;
/// Past this the oldest drop off: a list nobody scrolls is not a memory.
const MAX_RECENT = 30;

/// Put `path` at the front of the recent list, once. `front` false appends,
/// for loading the saved list in its own order.
pub fn addRecent(path: []const u8, front: bool) void {
    removeRecent(path);
    const owned = app.gpa.dupe(u8, path) catch return;
    if (front) {
        recent.insert(app.gpa, 0, owned) catch return app.gpa.free(owned);
    } else {
        recent.append(app.gpa, owned) catch return app.gpa.free(owned);
    }
    while (recent.items.len > MAX_RECENT) app.gpa.free(recent.pop().?);
}

fn removeRecent(path: []const u8) void {
    for (recent.items, 0..) |p, i| {
        if (std.mem.eql(u8, p, path)) {
            app.gpa.free(recent.orderedRemove(i));
            return;
        }
    }
}

pub fn clearRecent() void {
    for (recent.items) |p| app.gpa.free(p);
    recent.clearRetainingCapacity();
}

/// Forget a repository entirely: off the recent list and out of every tab.
/// Nothing on disk is touched.
pub fn forgetRepo(path: []const u8) void {
    removeRecent(path);
    // The other groups first, and only then the active one: closing its last
    // tab drops the group from under this loop and opens the first tab left
    // anywhere — which must not be this repository again.
    for (groups.items, 0..) |*group, gi| {
        if (gi == active_group) continue;
        var i: usize = group.tabs.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, group.tabs.items[i].path, path)) app.gpa.free(group.tabs.orderedRemove(i).path);
        }
    }
    // A group it was the only tab of goes too, as when its last tab closes.
    dropEmptyGroups();
    // Looked up afresh each time: a close can move the active group.
    while (activeGroup()) |group| {
        const i = for (group.tabs.items, 0..) |tab, i| {
            if (std.mem.eql(u8, tab.path, path)) break i;
        } else break;
        closeTab(i);
    }
    removeRecent(path);
    saveWorkspace();
}

/// Open a repository and make it the active tab.
pub fn openAndRemember(path: []const u8) void {
    // Nothing on the strip has moved yet, so a folder that is no repository
    // leaves the open one alone rather than closing it to show the error.
    if (app.repo != null) {
        var probe = git.Repo.open(path) catch return app.setCommandError("Not a git repository.");
        defer probe.deinit();
        if (probe.workdir() == null) return app.setCommandError("Bare repositories have no working tree to show.");
    }
    app.openRepo(path);
    rememberActive();
    // A tab again, so no longer only a memory.
    if (app.repo != null) {
        removeRecent(app.repo_path.items);
        saveWorkspace();
    }
}

/// Make whatever is open the active tab, adding it to the group if it is not
/// in any group already.
pub fn rememberActive() void {
    if (app.repo == null) return;

    const group = activeGroup() orelse return;

    // Matched on the working directory libgit2 resolved, not on what was typed,
    // so opening the same repository from a subdirectory reuses its tab — in
    // whichever group it is.
    for (groups.items, 0..) |other, g| {
        for (other.tabs.items, 0..) |tab, i| {
            if (std.mem.eql(u8, tab.path, app.repo_path.items)) {
                active_group = g;
                active_tab = i;
                saveWorkspace();
                return;
            }
        }
    }

    const owned = app.gpa.dupe(u8, app.repo_path.items) catch return;
    group.tabs.append(app.gpa, .{ .path = owned }) catch {
        app.gpa.free(owned);
        return;
    };
    active_tab = group.tabs.items.len - 1;
    saveWorkspace();
}

/// Reopen whatever was in front last time.
pub fn restoreActiveTab() void {
    const group = activeGroup() orelse return;
    if (group.tabs.items.len == 0) return;

    if (active_tab >= group.tabs.items.len) active_tab = 0;

    // A tab whose directory has gone stays in the list: an unmounted drive is
    // likelier than a deleted repository, and dropping it would lose the
    // bookmark for good. `openRepo` says so in the graph pane.
    app.openRepo(group.tabs.items[active_tab].path);
}

pub fn selectTab(index: usize) void {
    selectTabIn(active_group, index);
}

pub fn selectTabIn(g: usize, index: usize) void {
    if (g >= groups.items.len or index >= groups.items[g].tabs.items.len) return;
    active_group = g;
    active_tab = index;
    app.openRepo(groups.items[g].tabs.items[index].path);
    saveWorkspace();
}

/// A tab of any group closed; for the active group, `closeTab`'s way.
pub fn closeTabIn(g: usize, index: usize) void {
    if (g == active_group) return closeTab(index);
    if (g >= groups.items.len or index >= groups.items[g].tabs.items.len) return;
    const removed = groups.items[g].tabs.orderedRemove(index);
    addRecent(removed.path, true);
    app.gpa.free(removed.path);
    dropEmptyGroups();
    saveWorkspace();
}

/// A group with no tabs left goes, as in a browser — unless it is all
/// there is, since everything downstream assumes a group exists.
fn dropEmptyGroups() void {
    var g: usize = groups.items.len;
    while (g > 0 and groups.items.len > 1) {
        g -= 1;
        if (groups.items[g].tabs.items.len > 0) continue;
        // A workspace keeps at least one group.
        const others = for (groups.items, 0..) |other, o| {
            if (o != g and other.ws == groups.items[g].ws) break true;
        } else false;
        if (!others) continue;
        var removed = groups.orderedRemove(g);
        removed.deinit();
        if (active_group > g) active_group -= 1 else if (active_group == g) {
            active_group = @min(g, groups.items.len - 1);
            active_tab = 0;
        }
    }
}

/// After the active group lost its last tab: the first tab anywhere, or
/// nothing open.
pub fn selectAnyTab() void {
    for (groups.items, 0..) |group, g| {
        if (group.ws == active_ws and group.tabs.items.len > 0) return selectTabIn(g, 0);
    }
    // The workspace stays, empty, on its start page.
    for (groups.items, 0..) |group, g| if (group.ws == active_ws) {
        active_group = g;
        active_tab = 0;
        break;
    };
    app.closeRepo();
    app.new_tab_open = true;
}

pub fn closeTab(index: usize) void {
    const group = activeGroup() orelse return;
    if (index >= group.tabs.items.len) return;

    const was_active = index == active_tab;
    const removed = group.tabs.orderedRemove(index);
    // Closed, not forgotten: it moves to the start page's recent list.
    addRecent(removed.path, true);
    app.gpa.free(removed.path);

    // Closing a tab to the left of the one you are looking at must not change
    // which one that is.
    if (!was_active and index < active_tab) active_tab -= 1;
    if (active_tab >= group.tabs.items.len) active_tab = group.tabs.items.len -| 1;

    if (group.tabs.items.len == 0) {
        app.closeRepo();
        dropEmptyGroups();
        selectAnyTab();
    } else if (was_active) {
        app.openRepo(group.tabs.items[active_tab].path);
    }

    saveWorkspace();
}

pub fn selectGroup(index: usize) void {
    if (index >= groups.items.len) return;
    if (groups.items[index].tabs.items.len == 0) {
        active_group = index;
        active_tab = 0;
        app.closeRepo();
        return saveWorkspace();
    }
    selectTabIn(index, 0);
}

/// The palette's colours, a group each; the index is what is saved.
pub const GROUP_COLORS = 7;

pub fn groupColor(i: u8) dvui.Color {
    const p = style.get();
    return switch (i % GROUP_COLORS) {
        0 => p.blue,
        1 => p.purple,
        2 => p.green,
        3 => p.orange,
        4 => p.red,
        5 => p.yellow,
        else => style.textMuted(),
    };
}

/// What each of the palette's colours is called, as a group is referred to
/// in a menu: groups have no name shown, only their colour.
pub fn groupColorName(i: u8) []const u8 {
    return switch (i % GROUP_COLORS) {
        0 => "blue",
        1 => "purple",
        2 => "green",
        3 => "orange",
        4 => "red",
        5 => "yellow",
        else => "grey",
    };
}

/// What a group left unnamed is called inside: never shown, it only marks
/// the tabs as grouped — tabs in no group have no name. Not a name anyone
/// types.
pub const GROUP_MARK = "\x1f";
/// What unnamed groups were called in the files of before group names.
const LEGACY_GROUP_MARK = "group";

/// A group's name as shown; empty for one left unnamed, which is its dot.
pub fn groupLabel(group: TabGroup) []const u8 {
    return if (std.mem.eql(u8, group.name, GROUP_MARK)) "" else group.name;
}

/// A new group named `name`, holding tab `t` of group `g`, right after it.
pub fn groupTab(name: []const u8, g: usize, t: usize) void {
    if (g >= groups.items.len or t >= groups.items[g].tabs.items.len) return;
    const owned = app.gpa.dupe(u8, name) catch return;
    // A colour the strip does not show yet, where there is one.
    var color: u8 = 0;
    while (color < GROUP_COLORS - 1) : (color += 1) {
        const used = for (groups.items) |other| {
            if (other.name.len > 0 and other.color == color) break true;
        } else false;
        if (!used) break;
    }
    groups.insert(app.gpa, g + 1, .{ .name = owned, .tabs = .empty, .color = color, .ws = groups.items[g].ws }) catch return app.gpa.free(owned);
    if (active_group > g) active_group += 1;
    moveTab(g, t, g + 1);
}

/// Tab `t` of group `from`, to the end of group `to`. The open repository
/// stays open; only where its tab sits changes.
pub fn moveTab(from: usize, t: usize, to: usize) void {
    if (from == to) return;
    moveTabTo(from, t, to, std.math.maxInt(usize));
}

/// Tab `t` of group `from` into slot `at` of group `to` — where a tab is
/// dropped, it takes the place of the one it was dropped on, as in a browser.
/// The tab you are looking at stays the one you are looking at.
pub fn moveTabTo(from: usize, t: usize, to: usize, at: usize) void {
    if (from >= groups.items.len or to >= groups.items.len) return;
    if (t >= groups.items[from].tabs.items.len) return;
    if (from == to and t == at) return;
    // Found again by its path afterwards, whichever indices shifted.
    const shown: ?[*]u8 = if (activeGroup()) |g| (if (active_tab < g.tabs.items.len) g.tabs.items[active_tab].path.ptr else null) else null;

    const tab = groups.items[from].tabs.orderedRemove(t);
    const list = &groups.items[to].tabs;
    list.insert(app.gpa, @min(at, list.items.len), tab) catch {
        app.gpa.free(tab.path);
        return;
    };
    if (shown) |p| for (groups.items, 0..) |group, g| for (group.tabs.items, 0..) |other, i| {
        if (other.path.ptr != p) continue;
        active_group = g;
        active_tab = i;
    };
    groups.items[to].collapsed = false;
    dropEmptyGroups();
    saveWorkspace();
}

/// Tab `t` of group `g` to the end of its workspace's strip, in no group:
/// into the ungrouped run there, or a new one.
pub fn tabToEnd(g: usize, t: usize) void {
    if (g >= groups.items.len) return;
    const ws = groups.items[g].ws;
    var last = g;
    for (groups.items, 0..) |other, i| {
        if (other.ws == ws) last = i;
    }
    if (groups.items[last].name.len > 0) {
        const owned = app.gpa.dupe(u8, DEFAULT_GROUP_NAME) catch return;
        groups.insert(app.gpa, last + 1, .{ .name = owned, .tabs = .empty, .ws = ws }) catch return app.gpa.free(owned);
        if (active_group > last) active_group += 1;
        last += 1;
    }
    moveTabTo(g, t, last, std.math.maxInt(usize));
}

/// Tab `t` of group `g` out of it, into the tabs in no group just after.
pub fn ungroupTab(g: usize, t: usize) void {
    if (g >= groups.items.len or groups.items[g].name.len == 0) return;
    const next = g + 1;
    if (next >= groups.items.len or groups.items[next].name.len > 0) {
        const owned = app.gpa.dupe(u8, DEFAULT_GROUP_NAME) catch return;
        groups.insert(app.gpa, next, .{ .name = owned, .tabs = .empty, .ws = groups.items[g].ws }) catch return app.gpa.free(owned);
        if (active_group > g) active_group += 1;
    }
    moveTab(g, t, next);
}

/// The label goes, the tabs stay where they are.
pub fn ungroup(g: usize) void {
    if (g >= groups.items.len) return;
    const name = app.gpa.dupe(u8, DEFAULT_GROUP_NAME) catch return;
    app.gpa.free(groups.items[g].name);
    groups.items[g].name = name;
    groups.items[g].collapsed = false;
    saveWorkspace();
}

pub fn renameGroup(g: usize, name: []const u8) void {
    if (g >= groups.items.len) return;
    const owned = app.gpa.dupe(u8, name) catch return;
    app.gpa.free(groups.items[g].name);
    groups.items[g].name = owned;
    saveWorkspace();
}

/// Every tab of the group closed, and the group with them.
pub fn closeGroup(index: usize) void {
    if (index >= groups.items.len) return;
    const was_active = index == active_group;
    var removed = groups.orderedRemove(index);
    for (removed.tabs.items) |tab| addRecent(tab.path, true);
    removed.deinit();
    // Its workspace keeps a group, empty if need be.
    ensureWorkspaceGroups();
    if (groups.items.len == 0) {
        if (app.gpa.dupe(u8, DEFAULT_GROUP_NAME)) |name| {
            groups.append(app.gpa, .{ .name = name, .tabs = .empty }) catch app.gpa.free(name);
        } else |_| {}
    }
    if (active_group > index) active_group -= 1;
    if (was_active) {
        active_group = 0;
        active_tab = 0;
        selectAnyTab();
    }
    saveWorkspace();
}

/// The networked command running on another thread, if any.
///
/// One at a time: two of these at once on the same repository is not something
/// to encourage, and the second would race the first for the index lock.
pub var job: ?*run.Job = null;
/// What it is, for the toolbar. Always a literal, so there is nothing to free.
pub var job_label: []const u8 = "";
/// The job running is the background fetch: a failure there — no network —
/// is not worth a red bar.
pub var job_quiet: bool = false;

/// Fetch every remote this often, from the settings; 0 never.
pub var auto_fetch_minutes: u32 = 10;
/// When the repository last fetched on its own, in seconds. Set back on
/// opening, so the first one comes shortly after.
pub var last_auto_fetch_s: i64 = 0;
pub const AUTO_FETCH_FIRST_S = 20;

/// True when the repository tracks anything through LFS, which is what puts the
/// LFS button in the toolbar. There is nothing to offer a repository that does
/// not use it.
pub var uses_lfs: bool = false;

/// Why there is no repository open, shown where the graph would be.
pub var open_error: ?[]const u8 = null;
/// stderr from the last failing git command, owned. Shown until the next one
/// succeeds — a failed checkout that vanishes on the next frame is worse than
/// no message at all.
pub var command_error: ?[]u8 = null;
