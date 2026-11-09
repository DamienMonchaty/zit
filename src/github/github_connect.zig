const std = @import("std");
const dvui = @import("dvui");
const style = @import("../ui/style.zig");
const git = @import("../git/git.zig");
const run = @import("../core/run.zig");
const avatars = @import("avatar.zig");
const github = @import("github.zig");
const tab_strip = @import("../ui/tab_strip.zig");
const window_chrome = @import("../ui/window_chrome.zig");
const graph_view = @import("../ui/graph_view.zig");
const search_view = @import("../ui/search_view.zig");
const rebase_view = @import("../ui/rebase_view.zig");
const dialog_views = @import("../ui/dialog_views.zig");
const identity_view = @import("../ui/identity_view.zig");
const command_palette = @import("../ui/command_palette.zig");
const repo_io = @import("../core/repo_io.zig");
const github_actions = @import("github_actions.zig");
const app = @import("../main.zig");

// === Connecting GitHub ===
//
// OAuth's device flow, as GitKraken signs in: GitHub hands Zit a code, the
// browser opens on github.com/login/device with the code in the clipboard,
// and once it is approved there the token comes back to Zit's asking.

pub var connect_open = false;
pub var connect_rect: dvui.Rect = .{};
var connect_job: ?*run.Capture = null;
pub var connect_state: enum { asking, waiting, user, done, failed } = .asking;
/// GitHub's code to type, and what Zit asks with; owned.
pub var connect_code: std.ArrayList(u8) = .empty;
pub var connect_device: std.ArrayList(u8) = .empty;
pub var connect_uri: std.ArrayList(u8) = .empty;
var connect_interval_s: u32 = 5;
pub var connect_note: std.ArrayList(u8) = .empty;
/// Asked from the identity dialog: its fields filled once connected.
pub var connect_fills_identity = false;

/// The dialog, and OAuth's device flow under way: a code from GitHub, typed
/// on its page in the browser. Also its Try again.
pub fn openConnect() void {
    connect_open = true;
    connect_rect = .{};
    connect_state = .asking;
    connect_code.clearRetainingCapacity();
    connect_note.clearRetainingCapacity();
    if (connect_job) |j| j.deinit(app.app_io);
    connect_job = github.startDevice() catch {
        connectFailed("Could not run curl. Is it installed?");
        return;
    };
}

pub fn connectFailed(why: []const u8) void {
    connect_state = .failed;
    connect_rect = .{};
    connect_note.clearRetainingCapacity();
    connect_note.appendSlice(app.gpa, why) catch {};
}

pub fn closeConnect() void {
    connect_open = false;
    if (connect_job) |j| j.deinit(app.app_io);
    connect_job = null;
}

/// What came back, and the next ask: on the timer GitHub set, while the
/// dialog is up.
fn pumpConnect(timer_id: dvui.Id) void {
    if (!connect_open) return;
    if (connect_job) |w| {
        if (!w.finished()) return;
        // Ours now: the next ask, if any, takes the slot it leaves.
        connect_job = null;
        defer w.deinit(app.app_io);
        var a: std.heap.ArenaAllocator = .init(app.gpa);
        defer a.deinit();
        if (!w.ok) return connectFailed(if (w.err.items.len > 0) w.err.items else "No answer from GitHub.");
        switch (connect_state) {
            .asking => {
                const d = github.parseDevice(a.allocator(), w.out) catch return connectFailed("GitHub would not give a code. Is Device Flow on for Zit's OAuth App?");
                connect_code.clearRetainingCapacity();
                connect_code.appendSlice(app.gpa, d.user_code) catch {};
                connect_device.clearRetainingCapacity();
                connect_device.appendSlice(app.gpa, d.device_code) catch {};
                connect_uri.clearRetainingCapacity();
                connect_uri.appendSlice(app.gpa, d.verification_uri) catch {};
                connect_interval_s = @max(d.interval, 5);
                connect_state = .waiting;
                // Where the browser page can take it.
                dvui.clipboardTextSet(connect_code.items);
                github_actions.openUrl(connect_uri.items);
                dvui.timer(timer_id, @intCast(connect_interval_s * std.time.us_per_s));
            },
            .waiting => switch (github.parsePoll(a.allocator(), w.out)) {
                .pending => dvui.timer(timer_id, @intCast(connect_interval_s * std.time.us_per_s)),
                .slow_down => {
                    connect_interval_s += 5;
                    dvui.timer(timer_id, @intCast(connect_interval_s * std.time.us_per_s));
                },
                .expired => connectFailed("The code expired before it was approved. Try again."),
                .denied => connectFailed("Zit was not authorised on GitHub."),
                .failed => |why| connectFailed(why),
                .token => |token| {
                    github.save(token, "") catch return connectFailed("Could not keep the token: no config folder.");
                    connect_state = .user;
                    connect_job = github.start(".", "GET", "/user", null) catch return connectFailed("Could not run curl.");
                },
            },
            .user => {
                const got = github.split(w.out);
                // A token GitHub turns down is not kept.
                if (!got.ok()) {
                    github.signOut();
                    return connectFailed(if (got.code == 401) "GitHub did not accept the sign-in." else github.failure(a.allocator(), got) orelse "GitHub did not say who signed in.");
                }
                const user = std.json.parseFromSliceLeaky(struct { login: []const u8 = "" }, a.allocator(), got.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return connectFailed("GitHub did not say who signed in.");
                // The token is on disk already: only the name it goes by.
                github.saveUser(user.login) catch {};
                connect_state = .done;
                window_chrome.me_loaded = false;
                if (!tab_strip.integrations) tab_strip.setIntegrations(true) else repo_io.refreshRequests();
                avatars.setGithubRepo(repo_io.githubRemote());
                if (connect_fills_identity) {
                    connect_fills_identity = false;
                    identity_view.identity_note = if (identity_view.fillFromGithub()) "Filled in from your GitHub account." else "Connected.";
                }
                // Nothing left to say: the account shows in Settings and the
                // pull requests come in behind it.
                closeConnect();
            },
            else => {},
        }
        return;
    }
    if (connect_state == .waiting and dvui.timerDone(timer_id)) {
        connect_job = github.pollDevice(connect_device.items) catch return connectFailed("Could not run curl.");
    }
}

pub fn connectDialog() void {
    if (!connect_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &connect_rect, &connect_open, style.surface(), 420, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    pumpConnect(fw.data().id);
    identity_view.dialogHeader(@src(), dvui.entypo.login, "Connect GitHub", "Pull requests, issues and checks, as your account", &connect_open);

    var body = identity_view.dialogBody(@src(), null);
    const text = switch (connect_state) {
        .asking => "Asking GitHub for a code…",
        .waiting => "Type this code on the GitHub page that just opened — it is in your clipboard — and approve Zit.",
        .user => "Finding out who you are…",
        .done => "Connected.",
        .failed => connect_note.items,
    };
    if (connect_state == .asking or connect_state == .user) {
        // Working: the dots before what it is doing, as a request's loading
        // has them.
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        rebase_view.loadingSpinner(@src());
        dvui.label(@src(), "{s}", .{text}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    } else {
        // Wrapped to the dialog's width, which a label would widen instead.
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(420 - 2 * style.space.xl), .background = false, .padding = dvui.Rect.all(0), .margin = .{ .h = style.space.lg } });
        tl.addText(text, .{ .font = style.small(), .color_text = .{ .color = if (connect_state == .failed) style.danger() else style.textMuted() } });
        tl.deinit();
    }
    if (connect_state == .waiting) {
        dvui.label(@src(), "{s}", .{connect_code.items}, .{ .font = style.bodyBold().withSize(28), .color_text = .{ .color = style.text() }, .gravity_x = 0.5, .padding = dvui.Rect.all(0), .margin = .{ .h = style.space.sm } });
        // What it waits on, on a line of its own under the code: beside the
        // buttons, the dots read as part of the last one.
        {
            var wait = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .background = false, .margin = .{ .h = style.space.lg } });
            defer wait.deinit();
            rebase_view.loadingSpinner(@src());
            dvui.label(@src(), "Waiting for your approval on github.com", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .background = false });
        defer row.deinit();
        if (dialog_views.dialogButton(@src(), "Copy the code", false)) dvui.clipboardTextSet(connect_code.items);
        if (dialog_views.dialogButton(@src(), "Open the page again", false)) github_actions.openUrl(connect_uri.items);
    }
    body.deinit();
    {
        var foot = identity_view.dialogFooter(@src());
        defer foot.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButton(@src(), "Cancel", false)) closeConnect();
        if (connect_state == .failed and dialog_views.dialogButton(@src(), "Try again", true)) openConnect();
    }
    if (dialog_views.escapePressed()) closeConnect();
    if (!connect_open) closeConnect();
}

/// A group's label: a dot in its colour, as Chrome marks a group with no
/// name — and how many tabs, folded. A click folds or unfolds it; a
/// right-click offers the rest.
pub fn groupChip(g: usize, group: tab_strip.TabGroup, hue: dvui.Color) dvui.Rect.Physical {
    const lit = if (tab_drop_over) |o| o[0] == g and o[1] == std.math.maxInt(usize) else false;
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .id_extra = g,
        .tag = dialog_views.frameTag("group", group.name),
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = if (lit) style.accentDim() else dvui.Color.transparent },
        .color_fill_hover = .{ .color = if (lit) style.accentDim() else style.rowHover() },
        .corners = style.radius.input,
        .margin = .{ .x = style.space.xs, .y = TAB_TOP },
        .padding = dvui.Rect.all(style.space.sm),
    });
    groupDrop(bw.data(), g);
    bw.processEvents();
    bw.drawBackground();
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .gravity_y = 0.5 });
        defer line.deinit();
        var dot = dvui.box(@src(), .{}, .{
            .background = true,
            .color_fill = .{ .color = hue },
            .corners = dvui.CornerRect.all(6),
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
        });
        dot.deinit();
        const label = tab_strip.groupLabel(group);
        if (label.len > 0) {
            var fit_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
            dvui.label(@src(), "{s}", .{graph_view.fitText(&fit_buf, label, style.smallBold(), 140)}, .{ .font = style.smallBold(), .color_text = .{ .color = hue }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
        if (group.collapsed) {
            dvui.label(@src(), "{d}", .{group.tabs.items.len}, .{ .font = style.tinyBold(), .color_text = .{ .color = hue }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
    }
    if (bw.clicked()) github_actions.requestTab(.{ .group_toggle = g });
    const rect = bw.data().borderRectScale().r;
    bw.deinit();
    groupMenu(g, rect);
    return rect;
}

/// A group's right-click: recolour, ungroup, close.
fn groupMenu(g: usize, rect: dvui.Rect.Physical) void {
    const ctx = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = g });
    defer ctx.deinit();
    const cp = ctx.activePoint() orelse return;
    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();

    {
        var swatches = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm } });
        defer swatches.deinit();
        for (0..tab_strip.GROUP_COLORS) |c| {
            const current = tab_strip.groups.items[g].color == c;
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{ .draw_focus = false }, .{
                .id_extra = c,
                .min_size_content = .{ .w = 16, .h = 16 },
                .background = true,
                .color_fill = .{ .color = tab_strip.groupColor(@intCast(c)) },
                .corners = .all(8),
                .border = dvui.Rect.all(if (current) 2 else 0),
                .color_border = .{ .color = style.text() },
                .margin = .{ .w = style.space.sm },
            });
            bw.processEvents();
            bw.drawBackground();
            if (bw.clicked()) {
                fw.close();
                github_actions.requestTab(.{ .group_color = .{ g, c } });
            }
            bw.deinit();
        }
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.pencil, "Rename the group…", false)) {
        fw.close();
        repo_io.group_target = .{ g, 0 };
        openWorkspaceDialog(.group_rename);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.squared_minus, "Ungroup", false)) {
        fw.close();
        github_actions.requestTab(.{ .ungroup = g });
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.cross, "Close the group", false)) {
        fw.close();
        github_actions.requestTab(.{ .close_group = g });
    }
}

/// Switch to workspace `w`, in this window and this view: the group and tab
/// it was on, its first tab, or its start page when it has none.
pub fn selectWorkspace(w: usize) void {
    if (w >= tab_strip.workspaces.items.len) return;
    tab_strip.active_ws = w;
    const at = tab_strip.workspaces.items[w];
    if (at.group < tab_strip.groups.items.len and tab_strip.groups.items[at.group].ws == w and at.tab < tab_strip.groups.items[at.group].tabs.items.len) {
        app.new_tab_open = false;
        return tab_strip.selectTabIn(at.group, at.tab);
    }
    tab_strip.selectAnyTab();
    tab_strip.saveWorkspace();
}

/// A new workspace, with an empty group to open repositories into, switched
/// to. Its index.
pub fn newWorkspace(name: []const u8, color: u8) ?usize {
    const owned = app.gpa.dupe(u8, name) catch return null;
    tab_strip.workspaces.append(app.gpa, .{ .name = owned, .color = color }) catch {
        app.gpa.free(owned);
        return null;
    };
    const w = tab_strip.workspaces.items.len - 1;
    tab_strip.ensureWorkspaceGroups();
    return w;
}

/// Workspace `w` and its tabs gone — the tabs to the recent list — unless
/// it is the last one.
pub fn deleteWorkspace(w: usize) void {
    if (w >= tab_strip.workspaces.items.len or tab_strip.workspaces.items.len <= 1) return;
    var g: usize = tab_strip.groups.items.len;
    while (g > 0) {
        g -= 1;
        if (tab_strip.groups.items[g].ws == w) {
            var removed = tab_strip.groups.orderedRemove(g);
            for (removed.tabs.items) |tab| tab_strip.addRecent(tab.path, true);
            removed.deinit();
        } else if (tab_strip.groups.items[g].ws > w) tab_strip.groups.items[g].ws -= 1;
    }
    app.gpa.free(tab_strip.workspaces.orderedRemove(w).name);
    tab_strip.active_group = 0;
    tab_strip.active_tab = 0;
    dialog_views.closeRepo();
    selectWorkspace(if (w > 0) w - 1 else 0);
}

fn firstGroupOf(w: usize) usize {
    for (tab_strip.groups.items, 0..) |group, g| if (group.ws == w) return g;
    return 0;
}

/// Tab `t` of group `g` into workspace `w`: its first group.
fn moveTabToWorkspace(g: usize, t: usize, w: usize) void {
    for (tab_strip.groups.items, 0..) |group, to| if (group.ws == w) return tab_strip.moveTab(g, t, to);
}

/// The workspace shown, at the strip's start: its colour, its name, and a
/// menu of every workspace, with new, rename, colour and delete.
pub fn workspaceSwitcher() void {
    if (tab_strip.active_ws >= tab_strip.workspaces.items.len) return;
    const current = tab_strip.workspaces.items[tab_strip.active_ws];
    // On its own colour, the name dark on it, as a tab group's label was:
    // which workspace this is reads before its name does.
    const hue = tab_strip.groupColor(current.color);
    const button = window_chrome.DropButton.begin(@src(), .{
        .tag = "workspace:switcher",
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = hue },
        .color_fill_hover = .{ .color = hue.lerp(style.text(), 0.2) },
        .corners = style.radius.input,
        .min_size_content = .{ .w = 110 },
        .margin = .{ .x = style.space.sm, .w = style.space.sm },
        .padding = .{ .x = style.space.md, .y = 3, .w = style.space.sm, .h = 3 },
    });
    {
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .expand = .horizontal });
        defer face.deinit();
        const ink = style.background();
        dvui.label(@src(), "{s}", .{tab_strip.workspaceName(current)}, .{ .font = style.smallBold(), .color_text = .{ .color = ink }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        dvui.icon(@src(), "workspace_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = ink } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs },
        });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse return;

    dialog_views.dropHeading(@src(), 0, "WORKSPACES");
    for (tab_strip.workspaces.items, 0..) |w, i| {
        var mi = dvui.menuItem(@src(), .{}, .{
            .id_extra = i,
            .tag = dialog_views.frameTag("workspace", tab_strip.workspaceName(w)),
            .expand = .horizontal,
            .min_size_content = .{ .w = 260 },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.md, .y = 4, .w = style.space.md, .h = 4 },
        });
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer row.deinit();
            workspaceDot(@src(), i + 1, w.color);
            dvui.label(@src(), "{s}", .{tab_strip.workspaceName(w)}, .{ .font = if (i == tab_strip.active_ws) style.smallBold() else style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0), .margin = .{ .x = style.space.sm } });
            var n: usize = 0;
            for (tab_strip.groups.items) |g| {
                if (g.ws == i) n += g.tabs.items.len;
            }
            dvui.label(@src(), "{d} {s}", .{ n, if (n == 1) "repository" else "repositories" }, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            if (i == tab_strip.active_ws) dvui.icon(@src(), "workspace_on", dvui.entypo.check, .{ .fill_color = .{ .color = style.accent() } }, .{
                .min_size_content = .{ .w = 11, .h = 11 },
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.sm },
            });
        }
        const picked = mi.activeRect() != null;
        mi.deinit();
        if (picked) {
            m.close();
            if (i != tab_strip.active_ws) github_actions.requestTab(.{ .select_ws = i });
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = style.space.xs, .h = style.space.xs } });
    if (graph_view.menuIcon(@src(), dvui.entypo.plus, "New workspace…", false)) {
        m.close();
        openWorkspaceDialog(.new);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.pencil, "Rename this workspace…", false)) {
        m.close();
        openWorkspaceDialog(.rename);
    }
    if (colorSwatches(@src(), current.color, .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm })) |c| {
        m.close();
        tab_strip.workspaces.items[tab_strip.active_ws].color = @intCast(c);
        tab_strip.saveWorkspace();
    }
    if (tab_strip.workspaces.items.len > 1 and graph_view.menuIcon(@src(), dvui.entypo.trash, "Delete this workspace", true)) {
        m.close();
        github_actions.requestTab(.{ .close_ws = tab_strip.active_ws });
    }
}

/// The workspace colours as round buttons, `current` ringed: the one
/// clicked, if any.
fn colorSwatches(src: std.builtin.SourceLocation, current: u8, pad: dvui.Rect) ?usize {
    var swatches = dvui.box(src, .{ .dir = .horizontal }, .{ .background = false, .padding = pad });
    defer swatches.deinit();
    var picked: ?usize = null;
    for (0..tab_strip.GROUP_COLORS) |c| {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = c,
            .min_size_content = .{ .w = 16, .h = 16 },
            .background = true,
            .color_fill = .{ .color = tab_strip.groupColor(@intCast(c)) },
            .corners = .all(8),
            .border = dvui.Rect.all(if (current == c) 2 else 0),
            .color_border = .{ .color = style.text() },
            .margin = .{ .w = style.space.sm },
        });
        bw.processEvents();
        bw.drawBackground();
        if (bw.clicked()) picked = c;
        bw.deinit();
    }
    return picked;
}

/// Naming a workspace, in a dialog: a new one, a new one for the tab
/// `group_target` names, or the one shown renamed — with its colour.
const WorkspaceDialog = enum {
    new,
    with_tab,
    rename,
    /// A new tab group, for the tab `group_target` names.
    group,
    /// The group `group_target` names, its name and colour.
    group_rename,
};
pub var ws_dialog: ?WorkspaceDialog = null;
var ws_rect: dvui.Rect = .{};
pub var ws_name: std.ArrayList(u8) = .empty;
pub var ws_color: u8 = 0;

pub fn openWorkspaceDialog(kind: WorkspaceDialog) void {
    ws_dialog = kind;
    ws_rect = .{};
    ws_name.clearRetainingCapacity();
    ws_color = @intCast(tab_strip.workspaces.items.len % tab_strip.GROUP_COLORS);
    // A group: a colour no other shows yet, where there is one.
    if (kind == .group) {
        ws_color = 0;
        while (ws_color < tab_strip.GROUP_COLORS - 1) : (ws_color += 1) {
            const used = for (tab_strip.groups.items) |other| {
                if (other.name.len > 0 and other.color == ws_color) break true;
            } else false;
            if (!used) break;
        }
    }
    if (kind == .rename and tab_strip.active_ws < tab_strip.workspaces.items.len) {
        ws_name.appendSlice(app.gpa, tab_strip.workspaces.items[tab_strip.active_ws].name) catch {};
        ws_color = tab_strip.workspaces.items[tab_strip.active_ws].color;
    }
    if (kind == .group_rename and repo_io.group_target[0] < tab_strip.groups.items.len) {
        const group = tab_strip.groups.items[repo_io.group_target[0]];
        ws_name.appendSlice(app.gpa, tab_strip.groupLabel(group)) catch {};
        ws_color = group.color;
    }
}

pub fn workspaceDialog() void {
    const kind = ws_dialog orelse return;
    var open = true;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &ws_rect, &open, style.surface(), 400, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    const is_group = kind == .group or kind == .group_rename;
    if (kind == .group)
        identity_view.dialogHeader(@src(), dvui.entypo.plus, "New group", "The tab under a coloured dot, with the ones you add to it", &open)
    else if (kind == .group_rename)
        identity_view.dialogHeader(@src(), dvui.entypo.pencil, "Rename the group", "Its name beside its dot; none leaves the dot alone", &open)
    else
        identity_view.dialogHeader(@src(), dvui.entypo.layers, if (kind == .rename) "Rename the workspace" else "New workspace", "A set of groups and tabs, switched to in this window", &open);

    var body = identity_view.dialogBody(@src(), null);
    var entered = false;
    // A group's name is optional: without one, the group is its dot.
    _ = dialog_views.dialogField(@src(), 0, if (is_group) "Name (optional)" else "Name", &ws_name, "e.g. Client work", true, &entered);
    dialog_views.dialogLabel(@src(), "Colour");
    if (colorSwatches(@src(), ws_color, .{ .y = style.space.xs, .h = style.space.lg })) |c| ws_color = @intCast(c);

    const named = is_group or std.mem.trim(u8, ws_name.items, " \t").len > 0;
    body.deinit();
    {
        var line = identity_view.dialogFooter(@src());
        defer line.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButton(@src(), "Cancel", false)) open = false;
        if ((dialog_views.dialogButton(@src(), if (kind == .rename or kind == .group_rename) "Rename" else "Create", named) or entered) and named) github_actions.requestTab(.workspace_named);
    }
    if (dialog_views.escapePressed() or !open) ws_dialog = null;
}

/// What the dialog was answered with, applied between frames.
pub fn applyWorkspaceDialog() void {
    const kind = ws_dialog orelse return;
    ws_dialog = null;
    const typed = std.mem.trim(u8, ws_name.items, " \t");
    const name = if ((kind == .group or kind == .group_rename) and typed.len == 0) tab_strip.GROUP_MARK else typed;
    if (name.len == 0) return;
    switch (kind) {
        .new => if (newWorkspace(name, ws_color)) |w| selectWorkspace(w),
        .with_tab => if (newWorkspace(name, ws_color)) |w| {
            moveTabToWorkspace(repo_io.group_target[0], repo_io.group_target[1], w);
            selectWorkspace(w);
        },
        .group => {
            const g0 = repo_io.group_target[0];
            const t0 = repo_io.group_target[1];
            if (g0 >= tab_strip.groups.items.len or t0 >= tab_strip.groups.items[g0].tabs.items.len) return;
            // Found again by its tab: the group it left may go, empty.
            const tab = tab_strip.groups.items[g0].tabs.items[t0].path.ptr;
            tab_strip.groupTab(name, g0, t0);
            for (tab_strip.groups.items) |*group| for (group.tabs.items) |other| {
                if (other.path.ptr == tab) group.color = ws_color;
            };
            tab_strip.saveWorkspace();
        },
        .group_rename => {
            const g = repo_io.group_target[0];
            // Only a group: tabs in no group are not renamed into one.
            if (g >= tab_strip.groups.items.len or tab_strip.groups.items[g].name.len == 0) return;
            tab_strip.groups.items[g].color = ws_color;
            tab_strip.renameGroup(g, name);
        },
        .rename => if (tab_strip.active_ws < tab_strip.workspaces.items.len) {
            const owned = app.gpa.dupe(u8, name) catch return;
            app.gpa.free(tab_strip.workspaces.items[tab_strip.active_ws].name);
            tab_strip.workspaces.items[tab_strip.active_ws].name = owned;
            tab_strip.workspaces.items[tab_strip.active_ws].color = ws_color;
            tab_strip.saveWorkspace();
        },
    }
}

/// A workspace's colour, as a dot.
fn workspaceDot(src: std.builtin.SourceLocation, id: usize, color: u8) void {
    var dot = dvui.box(src, .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = 8, .h = 8 },
        .max_size_content = .size(.{ .w = 8, .h = 8 }),
        .background = true,
        .color_fill = .{ .color = tab_strip.groupColor(color) },
        .corners = .all(4),
        .gravity_y = 0.5,
    });
    dot.deinit();
}

/// A tab's right-click: into a group, out of one, to another workspace,
/// closed.
pub fn tabMenu(g: usize, t: usize, id: usize, rect: dvui.Rect.Physical) void {
    const ctx = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();
    const cp = ctx.activePoint() orelse return;
    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();

    if (graph_view.menuIcon(@src(), dvui.entypo.plus, "Add to a new group…", false)) {
        fw.close();
        repo_io.group_target = .{ g, t };
        openWorkspaceDialog(.group);
    }
    for (tab_strip.groups.items, 0..) |other, gi| {
        if (gi == g or other.name.len == 0 or other.ws != tab_strip.groups.items[g].ws) continue;
        const label = tab_strip.groupLabel(other);
        const caption = (if (label.len > 0)
            std.fmt.allocPrint(dvui.currentWindow().arena(), "Move to {s}", .{label})
        else
            std.fmt.allocPrint(dvui.currentWindow().arena(), "Move to the {s} group", .{tab_strip.groupColorName(other.color)})) catch continue;
        if (graph_view.menuIconAt(@src(), gi, dvui.entypo.layers, caption)) {
            fw.close();
            github_actions.requestTab(.{ .tab_to = .{ g, t, gi } });
        }
    }
    if (tab_strip.groups.items[g].name.len > 0 and graph_view.menuIcon(@src(), dvui.entypo.squared_minus, "Remove from the group", false)) {
        fw.close();
        github_actions.requestTab(.{ .tab_out = .{ g, t } });
    }
    for (tab_strip.workspaces.items, 0..) |w, wi| {
        if (wi == tab_strip.groups.items[g].ws) continue;
        const caption = std.fmt.allocPrint(dvui.currentWindow().arena(), "Move to workspace {s}", .{tab_strip.workspaceName(w)}) catch continue;
        if (graph_view.menuIconAt(@src(), wi + 1000, dvui.entypo.layers, caption)) {
            fw.close();
            github_actions.requestTab(.{ .tab_to = .{ g, t, firstGroupOf(wi) } });
        }
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.plus, "Move to a new workspace…", false)) {
        fw.close();
        repo_io.group_target = .{ g, t };
        openWorkspaceDialog(.with_tab);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.cross, "Close", false)) {
        fw.close();
        github_actions.requestTab(.{ .close_in = .{ g, t } });
    }
}

const TabHit = enum { none, select, close };

/// Each tab as wide as its name, up to this much, cut with "…" past it.
pub const TAB_W: f32 = 200;

/// What kind of tab: its icon.
const TabLook = struct {
    icon: []const u8 = dvui.entypo.flow_branch,
    /// Group and index of a repository's tab: what makes it draggable.
    slot: ?[2]usize = null,
    /// Its group's colour: the active one is outlined in it.
    hue: ?dvui.Color = null,
};

pub const TAB_DRAG_NAME = "zit-tab";
/// The tab being dragged, by group and index.
pub var tab_drag: [2]usize = .{ 0, 0 };
/// The tab a drag was over last frame, lit this one.
pub var tab_drop_over: ?[2]usize = null;
pub var tab_drop_seen: ?[2]usize = null;

/// The tab on the move, under the cursor as a branch is: its badge and
/// name, a little below and right of the pointer, deaf to the mouse.
pub fn tabGhost() void {
    const g = tab_drag[0];
    if (g >= tab_strip.groups.items.len or tab_drag[1] >= tab_strip.groups.items[g].tabs.items.len) return;
    const name = git.repoName(tab_strip.groups.items[g].tabs.items[tab_drag[1]].path);
    const scale = dvui.windowNaturalScale();
    const at = dvui.currentWindow().mouse_pt;
    const named = tab_strip.groups.items[g].name.len > 0;
    // Sized by hand: a floating widget takes its rect as given.
    const text = style.tab().textSize(name);
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = .{ .x = at.x / scale + 14, .y = at.y / scale + 10, .w = BADGE_W + style.space.sm + text.w + 2 * style.space.md + 4, .h = @max(text.h, 18) + 12 },
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(2),
        .color_border = .{ .color = if (named) tab_strip.groupColor(tab_strip.groups.items[g].color) else style.accent() },
        .corners = style.radius.tag,
        .box_shadow = .{ .color = .black, .offset = .{ .x = 0, .y = 2 }, .fade = 8, .alpha = 0.25 },
        .padding = .{ .x = style.space.md, .y = 4, .w = style.space.md, .h = 4 },
    });
    defer fw.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
    defer row.deinit();
    tabBadge(name, true);
    dvui.label(@src(), "{s}", .{name}, .{ .font = style.tab(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
}

/// A tab dragged onto a group's label goes to the end of that group —
/// the way into a folded one.
fn groupDrop(wd: *dvui.WidgetData, g: usize) void {
    if (!dvui.dragName(TAB_DRAG_NAME)) return;
    const rect = wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = rect, .drag_name = TAB_DRAG_NAME })) continue;
        const me = e.evt.mouse;
        if (me.action == .position) tab_drop_seen = .{ g, std.math.maxInt(usize) };
        if (me.action == .release and me.button.pointer()) {
            e.handle(@src(), wd);
            dvui.dragEnd(me.button);
            github_actions.requestTab(.{ .tab_to = .{ tab_drag[0], tab_drag[1], g } });
        }
    }
}

/// A tab dragged onto this one moves to its place.
fn tabDrop(wd: *dvui.WidgetData, slot: [2]usize) void {
    if (!dvui.dragName(TAB_DRAG_NAME)) return;
    if (tab_drag[0] == slot[0] and tab_drag[1] == slot[1]) return;
    const rect = wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        if (!dvui.eventMatch(e, .{ .id = wd.id, .r = rect, .drag_name = TAB_DRAG_NAME })) continue;
        const me = e.evt.mouse;
        if (me.action == .position) tab_drop_seen = slot;
        if (me.action == .release and me.button.pointer()) {
            e.handle(@src(), wd);
            dvui.dragEnd(me.button);
            github_actions.requestTab(.{ .tab_at = .{ tab_drag[0], tab_drag[1], slot[0], slot[1] } });
        }
    }
}

/// A press on a tab may be the start of a drag; once it moves far enough
/// the button lets the mouse go, so the tabs it crosses see it.
fn tabDragStart(wd: *dvui.WidgetData, slot: [2]usize) void {
    if (!dvui.captured(wd.id)) return;
    const rect = wd.borderRectScale().r;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action == .press and me.button.pointer() and rect.contains(me.p)) {
            dvui.dragPreStart(me.button, me.p, .{ .name = TAB_DRAG_NAME });
            tab_drag = slot;
        } else if (me.action == .motion) {
            if (dvui.dragging(me, TAB_DRAG_NAME) != null) {
                dvui.captureMouse(null, e.num);
                return;
            }
        }
    }
}

/// A tab's name and its × are siblings, not nested, so the tab's own button
/// never swallows the press meant for the ×.
pub fn tabButton(src: std.builtin.SourceLocation, id: usize, name: []const u8, hint: []const u8, active: bool, width: f32, rect_out: *dvui.Rect.Physical, look: TabLook) TabHit {
    var hit: TabHit = .none;
    const lit = if (look.slot) |s| (if (tab_drop_over) |o| o[0] == s[0] and o[1] == s[1] else false) else false;

    // Browser tabs, as GitComet's: the active one raised on the toolbar's
    // ground, its top corners round, outlined on top and on its sides and
    // open below — one piece with the bar under it. The others lie flat on
    // the strip, a short rule between two, lit under the pointer.
    const prev_active = tab_prev_active;
    tab_prev_active = active;
    var face = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .vertical,
        .background = true,
        .color_fill = .{ .color = if (lit) style.accentDim() else if (active) style.surface() else style.background() },
        .border = if (!active) dvui.Rect.all(0) else if (look.hue != null) .{ .x = 2, .y = 2, .w = 2 } else .{ .x = 1, .y = 1, .w = 1 },
        .color_border = .{ .color = look.hue orelse style.border() },
        .corners = if (active) .{ .tl = style.radius.row.tl, .tr = style.radius.row.tr } else dvui.CornerRect.all(0),
        .margin = .{ .x = TAB_GAP / 2, .y = TAB_TOP, .w = TAB_GAP / 2 },
        .padding = .{ .w = style.space.xs },
    });
    defer face.deinit();
    const face_rs = face.data().borderRectScale();
    const s = face_rs.s;
    rect_out.* = face_rs.r;
    // The strip's hairline is rubbed out under it, between its side edges.
    const side: f32 = if (look.hue != null) 2 * s else s;
    if (active) command_palette.active_tab_foot = .{ .x = face_rs.r.x + side, .y = face_rs.r.y + face_rs.r.h, .w = face_rs.r.w - 2 * side, .h = s };
    if (!active and !lit) {
        // Under the pointer, a plate a little in from the tab's edges.
        if (face_rs.r.contains(dvui.currentWindow().mouse_pt)) {
            (dvui.Rect.Physical{ .x = face_rs.r.x, .y = face_rs.r.y + 2 * s, .w = face_rs.r.w, .h = face_rs.r.h - 6 * s })
                .fill(dvui.CornerRect.Physical.all(5 * s), .{ .color = .{ .color = style.rowHover() }, .fade = 0 });
        }
        // The rule from the tab before, unless either of them is the raised one.
        if (!prev_active) {
            (dvui.Rect.Physical{ .x = face_rs.r.x - (TAB_GAP / 2) * s - s / 2, .y = face_rs.r.y + (face_rs.r.h - 16 * s) / 2 - 2 * s, .w = s, .h = 16 * s })
                .fill(.{}, .{ .color = .{ .color = style.border() }, .fade = 0 });
        }
    }

    var bw: dvui.ButtonWidget = undefined;
    var id_buf: [16]u8 = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .tag = dialog_views.frameTag("tab", std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch ""),
        .expand = .vertical,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.md, .w = style.space.xs },
    });
    // Around the button's own handling, as a branch row does: the release
    // that ends a drag is this tab's, the press may start one.
    if (look.slot) |slot| tabDrop(bw.data(), slot);
    bw.processEvents();
    if (look.slot) |slot| tabDragStart(bw.data(), slot);

    const font = style.tab();
    // A button lays its children over each other: the icon and the name go
    // in a row of their own.
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false });
    // A repository's initials on a badge, as GitComet marks its tabs —
    // the accent's on the active one; the new-tab page's plus.
    // A command running in it — commands run in the repository on show —
    // spins where its initials were.
    if (look.slot != null and active and tab_strip.job != null and !tab_strip.job_quiet) dvui.spinner(@src(), .{
        .min_size_content = .{ .w = 18, .h = 18 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .color_text = .{ .color = style.accent() },
    }) else if (look.slot != null) tabBadge(name, active) else dvui.icon(@src(), "tab_icon", look.icon, .{ .fill_color = .{ .color = if (active) style.accent() else style.textMuted() } }, .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    var fit_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
    dvui.label(@src(), "{s}", .{graph_view.fitText(&fit_buf, name, font, width)}, .{
        .font = font,
        .color_text = .{ .color = if (active or bw.hovered()) style.text() else style.textMuted() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    line.deinit();

    if (bw.hovered()) {
        dvui.tooltip(@src(), .{
            .active_rect = bw.data().borderRectScale().r,
            .position = .vertical,
            .delay = 500_000,
        }, "{s}", .{hint}, .{ .font = style.small() });
    }
    if (bw.clicked()) hit = .select;
    bw.deinit();

    // The × on the active tab and the one under the pointer; on the others its
    // room is kept, so a tab does not change width as the pointer crosses it.
    const show_close = active or face_rs.r.contains(dvui.currentWindow().mouse_pt);
    if (dialog_views.iconButton(@src(), "tab_close", "Close this tab — Ctrl+W", dvui.entypo.cross, if (show_close) style.textFaint() else dvui.Color.transparent)) hit = .close;
    return hit;
}

/// Where the tab before this one was the raised one, for the rule between.
pub var tab_prev_active = true;
/// The strip shows above a tab, and between two.
const TAB_TOP: f32 = 4;
const TAB_GAP: f32 = 4;

/// A repository's initials on a rounded square, before its name in a tab.
pub fn tabBadge(name: []const u8, active: bool) void {
    var badge = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = .{ .color = if (active) style.accentDim() else style.border() },
        .corners = dvui.CornerRect.all(4),
        // One width whether one letter or two: the letters centred in it,
        // and badges down a list lined up.
        .min_size_content = .{ .w = BADGE_W, .h = 18 },
        .max_size_content = .size(.{ .w = BADGE_W, .h = 18 }),
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    defer badge.deinit();
    var buf: [8]u8 = undefined;
    dvui.label(@src(), "{s}", .{search_view.initials(&buf, name)}, .{
        .font = style.tinyBold(),
        .color_text = .{ .color = if (active) style.accent() else style.textMuted() },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        // A little room each side: at some zooms the rounded glyphs come out
        // a pixel wider, and a badge with no room left shows an ellipsis.
        .padding = .{ .x = 2, .w = 2 },
    });
}

const BADGE_W: f32 = 30;

/// What says a pill opens a menu: a chevron after its text, and the hand
/// cursor over it.
pub fn dropAffordance(dd: *dvui.DropdownWidget, color: dvui.Color) void {
    dvui.icon(@src(), "drop_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = color } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.xs },
    });
    if (dd.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) dvui.cursorSet(.hand);
}

/// Whether this path already appeared before (`group_index`, `tab_index`) in
/// the tabs' own order, group by group.
pub fn listedEarlier(group_index: usize, tab_index: usize, path: []const u8) bool {
    for (tab_strip.groups.items, 0..) |group, gi| {
        for (group.tabs.items, 0..) |tab, ti| {
            if (gi > group_index or (gi == group_index and ti >= tab_index)) return false;
            if (std.mem.eql(u8, tab.path, path)) return true;
        }
    }
    return false;
}

/// A merge, rebase or cherry-pick git stopped in the middle of, in the
/// toolbar's right end as GitComet's action bar has it: what — REBASING,
/// MERGING… — how far and how many conflicts, its whole story on hover;
/// Abort, and the next thing to do, filled.
///
/// Without it the only sign is that ordinary commands start refusing to run,
/// which is the single most confusing state a git GUI can leave you in.
pub fn operationControls() void {
    const h = app.history orelse return;
    if (h.state == .none) return;

    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false });
    defer line.deinit();

    {
        var what = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5, .background = false, .margin = .{ .w = style.space.md } });
        const word: []const u8 = switch (h.state) {
            .merge => "MERGING",
            .rebase => "REBASING",
            .cherrypick => "CHERRY-PICKING",
            .revert => "REVERTING",
            .bisect => "BISECTING",
            else => "IN PROGRESS",
        };
        dvui.label(@src(), "{s}", .{word}, .{ .font = style.smallBold(), .color_text = .{ .color = style.get().yellow }, .padding = dvui.Rect.all(0) });
        var detail_buf: [64]u8 = undefined;
        dvui.label(@src(), "{s}", .{opShort(&detail_buf)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0) });
        const r = what.data().borderRectScale().r;
        what.deinit();
        // The whole of it — which branch, onto what, the commit stopped on —
        // under the pointer.
        if (r.contains(dvui.currentWindow().mouse_pt)) {
            var title_buf: [256]u8 = undefined;
            dvui.tooltip(@src(), .{ .active_rect = r, .position = .vertical, .delay = 300_000 }, "{s}\n{s}", .{ opTitle(&title_buf), opDetail() }, .{ .font = style.small() });
        }
    }

    // Bisect and `git am` have no uniform continue/abort pair; the words
    // alone are still worth showing for those.
    const cmd = h.state.command() orelse return;

    const next = opNext();
    if (dialog_views.linkButtonTagged(@src(), "Abort", style.danger(), "op:abort")) github_actions.requestAbortOperation();
    if (canSkip() and next != .skip) {
        if (dialog_views.linkButtonTagged(@src(), "Skip", style.textMuted(), "op:skip")) github_actions.requestSkipStep();
    }
    switch (next) {
        .resolve => {
            const viewing = viewingConflict();
            if (!viewing or dialog_views.conflictCount() > 1) {
                var buf: [32]u8 = undefined;
                const caption = if (viewing) "Next file" else std.fmt.bufPrint(&buf, "Resolve ({d})", .{dialog_views.conflictCount()}) catch "Resolve";
                if (opButton(@src(), caption, "op:resolve")) openNextConflict();
            }
        },
        // Nothing left of the commit once its conflicts were answered: git
        // refuses to continue with it, and skipping it loses nothing.
        .skip => if (opButton(@src(), "Skip empty", "op:skip")) github_actions.requestLocal("Skipping", &.{ cmd, "--skip" }),
        .proceed => if (opButton(@src(), "Continue", "op:continue")) requestContinue(),
    }
}

/// "3/7 · 2 conflicts": how far, how many left, short enough for the toolbar.
fn opShort(buf: []u8) []const u8 {
    const n = dialog_views.conflictCount();
    const o = rebase_view.op_info;
    if (o.total > 0) return (if (n > 0)
        std.fmt.bufPrint(buf, "{d}/{d} · {d} conflict{s}", .{ @min(o.step, o.total), o.total, n, window_chrome.plural(n) })
    else
        std.fmt.bufPrint(buf, "{d}/{d} · resolved", .{ @min(o.step, o.total), o.total })) catch "";
    return (if (n > 0) std.fmt.bufPrint(buf, "{d} conflict{s}", .{ n, window_chrome.plural(n) }) else std.fmt.bufPrint(buf, "resolved", .{})) catch "";
}

/// The strip's one filled button: the next thing to do.
pub fn opButton(src: std.builtin.SourceLocation, caption: []const u8, tag: []const u8) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = tag,
        .background = true,
        .color_fill = .{ .color = style.accent() },
        .color_fill_hover = .{ .color = style.accentHover() },
        .corners = style.radius.input,
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm },
        .padding = .{ .x = style.space.md, .y = 3, .w = style.space.md, .h = 3 },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    dvui.label(@src(), "{s}", .{caption}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = style.textOnAccent() },
        .padding = dvui.Rect.all(0),
    });
    return bw.clicked();
}

/// "Rebasing feat onto main", "Merging feature/x into main": the strip's
/// title, in the names the branches go by.
pub fn opTitle(buf: []u8) []const u8 {
    const h = app.history orelse return "";
    const o = rebase_view.op_info;
    return switch (h.state) {
        .rebase => if (o.branch.len > 0 and o.onto.len > 0)
            std.fmt.bufPrint(buf, "Rebasing {s} onto {s}", .{ o.branch, o.onto }) catch "Rebasing"
        else if (o.onto.len > 0)
            std.fmt.bufPrint(buf, "Rebasing onto {s}", .{o.onto}) catch "Rebasing"
        else
            "Rebasing",
        .merge => std.fmt.bufPrint(buf, "Merging {s} into {s}", .{ o.theirs, o.ours }) catch "Merging",
        .cherrypick => if (o.commit.len > 0) std.fmt.bufPrint(buf, "Cherry-picking {s} onto {s}", .{ o.commit, o.ours }) catch "Cherry-picking" else "Cherry-picking",
        .revert => if (o.commit.len > 0) std.fmt.bufPrint(buf, "Reverting {s} on {s}", .{ o.commit, o.ours }) catch "Reverting" else "Reverting",
        else => h.state.label(),
    };
}

/// After the title: how far along, which commit it stopped on, how many
/// files wait — each where git says so. In the frame's arena.
fn opDetail() []const u8 {
    const h = app.history orelse return "";
    const a = dvui.currentWindow().arena();
    var out: std.ArrayList(u8) = .empty;
    const o = rebase_view.op_info;
    if (o.total > 0) out.print(a, "step {d} of {d}", .{ @min(o.step, o.total), o.total }) catch {};
    if (h.state == .rebase and o.commit.len > 0) {
        if (out.items.len > 0) out.appendSlice(a, "  ·  ") catch {};
        out.print(a, "{s} {s}", .{ o.commit, o.subject }) catch {};
    } else if ((h.state == .cherrypick or h.state == .revert) and o.subject.len > 0) {
        if (out.items.len > 0) out.appendSlice(a, "  ·  ") catch {};
        out.appendSlice(a, o.subject) catch {};
    }
    if (out.items.len > 0) out.appendSlice(a, "  ·  ") catch {};
    const n = dialog_views.conflictCount();
    if (n > 0) {
        out.print(a, "{d} conflicted file{s}", .{ n, window_chrome.plural(n) }) catch {};
    } else {
        out.appendSlice(a, "no conflict left") catch {};
    }
    return out.items;
}

/// What the strip's filled button does next.
const OpNext = enum { resolve, skip, proceed };

pub fn opNext() OpNext {
    if (dialog_views.conflictCount() > 0) return .resolve;
    const h = app.history orelse return .proceed;
    const w = app.work orelse return .proceed;
    // A merge with nothing to add still makes its merge commit.
    if (h.state != .merge and w.staged.len == 0) return .skip;
    return .proceed;
}

/// Skip goes with the operations that replay one commit after another.
pub fn canSkip() bool {
    const h = app.history orelse return false;
    return h.state == .rebase or h.state == .cherrypick or h.state == .revert;
}

/// A merge, rebase, cherry-pick or revert is under way: starting another is
/// refused by git, and offered by nothing.
pub fn midOperation() bool {
    const h = app.history orelse return false;
    return h.state.command() != null;
}

/// Continue, once every conflict is answered and there is something to go
/// on with: the filled button, Ctrl+Enter and the palette.
pub fn canContinue() bool {
    return midOperation() and opNext() == .proceed;
}

/// `core.editor=true`: `--continue` does not stop on an editor with nowhere
/// to open — `true` exits 0, and git keeps the message it already has. A
/// job, as a commit is: it may run hooks and sign.
pub fn requestContinue() void {
    const cmd = github_actions.operationCommand() orelse return;
    github_actions.requestLocal("Continuing", &.{ "-c", "core.editor=true", cmd, "--continue" });
}

/// Whether the file open is one of the conflicted ones.
pub fn viewingConflict() bool {
    return switch (app.selection) {
        .change => |side| side == .unstaged and app.selectedStatus(.unstaged) == .conflicted,
        else => false,
    };
}

/// The conflicted file after the one open, round the end — the first when
/// none is open.
pub fn openNextConflict() void {
    const w = app.work orelse return;
    const open: []const u8 = if (viewingConflict()) app.selected_path.items else "";
    var first: ?[]const u8 = null;
    var past = open.len == 0;
    for (w.unstaged) |change| {
        if (change.status != .conflicted) continue;
        if (first == null) first = change.path;
        if (past and !std.mem.eql(u8, change.path, open)) {
            app.active_view = .graph;
            return app.selectChange(change.path, .unstaged);
        }
        if (std.mem.eql(u8, change.path, open)) past = true;
    }
    if (first) |p| {
        app.active_view = .graph;
        app.selectChange(p, .unstaged);
    }
}

/// A toast: a card low on the right over the window, above the status bar,
/// where a question waits for its answer — not a bar that pushes everything
/// down.
fn toastWindow(src: std.builtin.SourceLocation, rect: *dvui.Rect, hue: dvui.Color) *dvui.FloatingWindowWidget {
    // Placed before dvui lays it out, from the size it had the frame before.
    // Placed after, what is in it stays where dvui first put it — centred,
    // as a dialog — until a frame comes that a quiet window never draws.
    // Given a place of its own, dvui does not centre it at all.
    const win = dvui.windowRect();
    const w = rect.w;
    const h = rect.h;
    rect.x = @max(1, win.w - (if (w > 0) w else TOAST_W) - style.space.xl);
    rect.y = @max(1, win.h - h - style.statusbar_height - style.space.lg);
    const fw = dvui.floatingWindow(src, .{
        .modal = false,
        .rect = rect,
        .resize = .none,
        .window_avoid = .none,
    }, .{
        // An alert's shape, floating: its colour's ground and frame.
        .background = true,
        .color_fill = .{ .color = style.tint(hue) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = dialog_views.alertEdge(hue) },
        .corners = style.radius.popover,
        .min_size_content = .{ .w = TOAST_W },
        .max_size_content = .width(TOAST_W),
        .padding = .{ .x = style.space.md, .y = style.space.md, .w = style.space.md, .h = style.space.sm },
    });
    fw.autoSize();
    // Its size only now known — the first time, or once its text changed:
    // one more frame, placed from it.
    const wd = fw.data();
    if (wd.rect.w != w or wd.rect.h != h) dvui.refresh(null, @src(), wd.id);
    return fw;
}

const TOAST_W: f32 = 380;

/// Text wrapped to the toast's width, which a label would widen instead.
fn toastText(src: std.builtin.SourceLocation, text: []const u8, font: dvui.Font) void {
    var tl = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(TOAST_W - 2 * style.space.md), .background = false, .padding = dvui.Rect.all(0), .margin = .{ .h = style.space.sm } });
    tl.addText(text, .{ .font = font, .color_text = .{ .color = style.text() } });
    tl.deinit();
}

var confirm_rect: dvui.Rect = .{};

/// The yes or no for anything git cannot undo, as a toast: the question,
/// and its answers — the one that does it named for what it does.
pub fn confirmToast() void {
    const c = app.confirm orelse {
        confirm_rect = .{};
        return;
    };
    // Esc is Cancel: the toast is what waits on an answer.
    if (dialog_views.escapePressed()) return github_actions.clearConfirm();

    var fw = toastWindow(@src(), &confirm_rect, style.danger());
    defer fw.deinit();

    var buf: [512]u8 = undefined;
    const short = c.arg[0..@min(7, c.arg.len)];
    const text = switch (c.kind) {
        .discard => if (c.arg.len == 0)
            "Discard every unstaged change?"
        else
            std.fmt.bufPrint(&buf, "Discard your changes to {s}?", .{c.arg}),
        .reset_hard => std.fmt.bufPrint(&buf, "Reset to {s} and throw away every local change?", .{short}),
        .stash_drop => std.fmt.bufPrint(&buf, "Delete stash {s}? Nothing gets it back.", .{short}),
        .discard_hunk => "Discard this hunk from the working copy?",
        .force_push => dialog_views.forcePushText(&buf),
        .delete_branch_force => std.fmt.bufPrint(&buf, "Delete {s}, with commits no other branch has?", .{c.arg}),
        .merge_request => std.fmt.bufPrint(&buf, "Merge #{s}? It goes into its base branch on the server, for everyone.", .{c.arg}),
        .close_request => std.fmt.bufPrint(&buf, "Close #{s} without merging it?", .{c.arg}),
        .sign_out => std.fmt.bufPrint(&buf, "Sign out of GitHub as {s}? Pull requests and issues stop until you sign in again.", .{c.arg}),
        .stage_markers => if (c.arg.len == 0)
            "Stage everything? Some conflicted files still have conflict markers, and git would take them as resolved."
        else
            std.fmt.bufPrint(&buf, "Stage {s} with its conflict markers still in it? git would take them as the resolution.", .{c.arg}),
        .abort_operation => dialog_views.abortText(&buf),
        .skip_step => "Skip the commit the rebase stopped on? It is left out of the rebased branch.",
        .restart_file => std.fmt.bufPrint(&buf, "Start {s} over? Every pick made in it goes, and its conflicts come back as git left them.", .{c.arg}),
        .remove_worktree => std.fmt.bufPrint(&buf, "Remove the worktree at {s}, and its folder?", .{c.arg}),
        .delete_remote_branch, .delete_remote_tag => std.fmt.bufPrint(&buf, "Delete {s} on the remote, for everyone?", .{c.arg}),
        .restore_file => std.fmt.bufPrint(&buf, "Replace your copy of {s} with this commit's?", .{
            if (std.mem.indexOfScalar(u8, c.arg, ' ')) |sep| c.arg[sep + 1 ..] else c.arg,
        }),
    } catch "Are you sure? This cannot be undone.";
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer head.deinit();
        dvui.icon(@src(), "confirm_icon", dvui.entypo.warning, .{ .fill_color = .{ .color = style.danger() } }, .{ .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0, .margin = .{ .y = 2, .w = style.space.sm } });
        toastText(@src(), text, style.small());
    }
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer line.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (dialog_views.linkButtonTagged(@src(), "Cancel", style.textMuted(), "confirm:cancel")) github_actions.clearConfirm();
    if (dialog_views.alertButton(@src(), confirmVerb(c.kind), style.danger(), "confirm:yes")) repo_io.requestAction(.confirmed);
}

/// The button that does what the toast asks, named for it.
fn confirmVerb(kind: app.Confirm.Kind) []const u8 {
    return switch (kind) {
        .discard, .discard_hunk => "Discard",
        .reset_hard => "Reset",
        .stash_drop, .delete_branch_force, .delete_remote_branch, .delete_remote_tag => "Delete",
        .force_push => "Force push",
        .restore_file => "Replace",
        .remove_worktree => "Remove",
        .merge_request => "Merge",
        .close_request => "Close",
        .sign_out => "Sign out",
        .stage_markers => "Stage anyway",
        .abort_operation => "Abort",
        .skip_step => "Skip",
        .restart_file => "Start over",
    };
}
