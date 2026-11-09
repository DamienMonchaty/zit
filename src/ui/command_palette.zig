const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const rebase_view = @import("rebase_view.zig");
const commit_view = @import("commit_view.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const repo_io = @import("../core/repo_io.zig");
const github_actions = @import("../github/github_actions.zig");
const github_connect = @import("../github/github_connect.zig");
const pr_editor = @import("pr_editor.zig");
const app = @import("../main.zig");

// === Command palette ===

/// Everything Zit can do, by name, for the keyboard. Each runs through the
/// same request/ask paths the buttons use, so none of them is a second way of
/// doing a thing — only a second way of asking for it.
const Command = struct {
    name: []const u8,
    run: *const fn () void,
    icon: []const u8,
    /// The shortcut that does the same, shown on the right of its row.
    keys: []const u8 = "",
    /// Hidden with no repository open, where it would do nothing.
    needs_repo: bool = true,
    /// Shown only while this says it can run.
    when: ?*const fn () bool = null,
};

const commands = [_]Command{
    .{ .name = "Continue the merge or rebase", .icon = dvui.entypo.controller_play, .keys = "Ctrl+Enter", .when = github_connect.canContinue, .run = github_connect.requestContinue },
    .{ .name = "Skip the commit it stopped on", .icon = dvui.entypo.controller_next, .when = github_connect.canSkip, .run = github_actions.requestSkipStep },
    .{ .name = "Abort the merge or rebase", .icon = dvui.entypo.circle_with_cross, .when = github_connect.midOperation, .run = github_actions.requestAbortOperation },
    .{ .name = "Fetch all remotes", .icon = dvui.entypo.cw, .run = struct {
        fn f() void {
            repo_io.requestNetwork("Fetching", tab_strip.fetchAllArgs(false));
        }
    }.f },
    .{ .name = "Pull", .icon = dvui.entypo.download, .run = struct {
        fn f() void {
            repo_io.requestNetwork("Pulling", &.{"pull"});
        }
    }.f },
    .{ .name = "Pull, rebasing local commits", .icon = dvui.entypo.level_down, .run = struct {
        fn f() void {
            repo_io.requestNetwork("Pulling", &.{ "pull", "--rebase" });
        }
    }.f },
    .{ .name = "Push", .icon = dvui.entypo.upload, .run = struct {
        fn f() void {
            repo_io.requestNetwork("Pushing", &.{ "-c", "push.autoSetupRemote=true", "push" });
        }
    }.f },
    .{ .name = "Force push…", .icon = dvui.entypo.warning, .run = struct {
        fn f() void {
            github_actions.ask(.force_push, "");
        }
    }.f },
    .{ .name = "Undo the last action", .icon = dvui.entypo.ccw, .keys = "Ctrl+Z", .run = github_actions.requestUndo },
    .{ .name = "Redo what was just undone", .icon = dvui.entypo.cw, .keys = "Ctrl+Shift+Z", .run = github_actions.requestRedo },
    .{ .name = "New branch…", .icon = dvui.entypo.flow_branch, .run = struct {
        fn f() void {
            github_actions.askName(.new_branch, "");
        }
    }.f },
    .{ .name = "New tag…", .icon = dvui.entypo.tag, .run = struct {
        fn f() void {
            github_actions.askName(.new_tag, "");
        }
    }.f },
    .{ .name = "Stash everything", .icon = dvui.entypo.archive, .run = struct {
        fn f() void {
            github_actions.requestLocal("Stashing", &.{ "stash", "push", "-u" });
        }
    }.f },
    .{ .name = "Stash everything, with a message…", .icon = dvui.entypo.archive, .run = struct {
        fn f() void {
            github_actions.askName(.stash, "");
        }
    }.f },
    .{ .name = "Pop the last stash", .icon = dvui.entypo.install, .run = struct {
        fn f() void {
            github_actions.requestLocal("Popping the stash", &.{ "stash", "pop" });
        }
    }.f },
    .{ .name = "Stage everything", .icon = dvui.entypo.squared_plus, .run = struct {
        fn f() void {
            commit_view.requestStageAll();
        }
    }.f },
    .{ .name = "Unstage everything", .icon = dvui.entypo.squared_minus, .run = struct {
        fn f() void {
            repo_io.request(&.{ "reset", "-q", "--", "." });
        }
    }.f },
    .{ .name = "Discard every unstaged change…", .icon = dvui.entypo.trash, .run = struct {
        fn f() void {
            github_actions.ask(.discard, "");
        }
    }.f },
    .{ .name = "Add a remote…", .icon = dvui.entypo.cloud, .run = struct {
        fn f() void {
            github_actions.askName(.add_remote, "");
        }
    }.f },
    .{ .name = "Refresh", .icon = dvui.entypo.retweet, .keys = "F5", .run = struct {
        fn f() void {
            repo_io.requestAction(.refresh);
        }
    }.f },
    .{ .name = "Open a repository…", .icon = dvui.entypo.folder, .keys = "Ctrl+O", .needs_repo = false, .run = struct {
        fn f() void {
            repo_io.requestAction(.open_repo);
        }
    }.f },
    .{ .name = "Clone a repository…", .icon = dvui.entypo.download, .needs_repo = false, .run = struct {
        fn f() void {
            dialog_views.openRepoDialog(.clone);
        }
    }.f },
    .{ .name = "New repository…", .icon = dvui.entypo.plus, .needs_repo = false, .run = struct {
        fn f() void {
            dialog_views.openRepoDialog(.create);
        }
    }.f },
    .{ .name = "Open a terminal here", .icon = dvui.entypo.code, .keys = "Ctrl+Shift+T", .run = repo_io.openTerminal },
    .{ .name = "New tab", .icon = dvui.entypo.browser, .keys = "Ctrl+T", .needs_repo = false, .run = struct {
        fn f() void {
            app.new_tab_open = true;
        }
    }.f },
    .{ .name = "Close this tab", .icon = dvui.entypo.cross, .keys = "Ctrl+W", .run = github_actions.closeShownTab },
    .{ .name = "Show or hide the branches panel", .icon = dvui.entypo.align_left, .keys = "Ctrl+B", .run = struct {
        fn f() void {
            app.show_sidebar = !app.show_sidebar;
        }
    }.f },
    .{ .name = "Show or hide the changes panel", .icon = dvui.entypo.align_right, .keys = "Ctrl+J", .run = struct {
        fn f() void {
            app.show_detail = !app.show_detail;
        }
    }.f },
    .{ .name = "Zoom in", .icon = dvui.entypo.plus, .keys = "Ctrl+=", .needs_repo = false, .run = struct {
        fn f() void {
            tab_strip.setZoom(tab_strip.zoom + 0.1);
        }
    }.f },
    .{ .name = "Zoom out", .icon = dvui.entypo.minus, .keys = "Ctrl+-", .needs_repo = false, .run = struct {
        fn f() void {
            tab_strip.setZoom(tab_strip.zoom - 0.1);
        }
    }.f },
    .{ .name = "Reset the zoom to 100 %", .icon = dvui.entypo.resize_100, .keys = "Ctrl+0", .needs_repo = false, .run = struct {
        fn f() void {
            tab_strip.setZoom(1.0);
        }
    }.f },
    .{ .name = "Create a pull request for this branch", .icon = dvui.entypo.merge, .run = rebase_view.requestCreateRequest },
    .{ .name = "Git identity: name, email, GitHub sign-in", .icon = dvui.entypo.user, .needs_repo = false, .run = identity_view.openIdentity },
    .{ .name = "Settings", .icon = dvui.entypo.cog, .needs_repo = false, .run = struct {
        fn f() void {
            identity_view.openSettings(5);
        }
    }.f },
    .{ .name = "Keyboard shortcuts", .icon = dvui.entypo.keyboard, .needs_repo = false, .run = struct {
        fn f() void {
            identity_view.keys_open = true;
            identity_view.keys_rect = .{};
        }
    }.f },
    .{ .name = "Switch theme, light or dark", .icon = dvui.entypo.light_up, .needs_repo = false, .run = struct {
        fn f() void {
            identity_view.setTheme(!app.dark_theme);
        }
    }.f },
};

pub var palette_open: bool = false;
pub var palette_text: std.ArrayList(u8) = .empty;
var palette_pick: usize = 0;
var palette_rect: dvui.Rect = .{};

pub fn openPalette() void {
    palette_open = true;
    palette_rect = .{};
    palette_text.clearRetainingCapacity();
    palette_pick = 0;
}

/// Every letter of `needle`, in order, somewhere in `hay`, ignoring case: "psh"
/// finds "Push". Loose on purpose; the list is short and the order says the rest.
pub fn fuzzy(hay: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    for (hay) |ch| {
        if (i == needle.len) break;
        if (std.ascii.toLower(ch) == std.ascii.toLower(needle[i])) i += 1;
    }
    return i == needle.len;
}

/// One line in the palette: a command, a branch to switch to, or a repository
/// to open — the three things anybody reaches for by name.
const PaletteItem = union(enum) {
    command: usize,
    ref: usize,
    repo: struct { group: usize, tab: usize },
};

const PALETTE_ROWS = 12;

pub fn palette() void {
    if (!palette_open) return;

    // Gathered first, so the keys below know how many there are.
    var items: [PALETTE_ROWS]PaletteItem = undefined;
    var labels: [PALETTE_ROWS][]const u8 = undefined;
    var n: usize = 0;
    const needle = std.mem.trim(u8, palette_text.items, " ");

    for (commands, 0..) |cmd, i| {
        if (n == PALETTE_ROWS) break;
        if (cmd.needs_repo and app.repo == null) continue;
        if (cmd.when) |can| if (!can()) continue;
        if (!fuzzy(cmd.name, needle)) continue;
        items[n] = .{ .command = i };
        labels[n] = cmd.name;
        n += 1;
    }
    if (app.history) |h| {
        for (h.refs, 0..) |ref, i| {
            if (n == PALETTE_ROWS) break;
            if (ref.kind == .tag or ref.head) continue;
            if (!fuzzy(ref.name, needle)) continue;
            items[n] = .{ .ref = i };
            labels[n] = ref.name;
            n += 1;
        }
    }
    for (tab_strip.groups.items, 0..) |group, gi| {
        for (group.tabs.items, 0..) |tab, ti| {
            if (n == PALETTE_ROWS) break;
            if (github_connect.listedEarlier(gi, ti, tab.path)) continue;
            const name = git.repoName(tab.path);
            if (!fuzzy(name, needle)) continue;
            items[n] = .{ .repo = .{ .group = gi, .tab = ti } };
            labels[n] = name;
            n += 1;
        }
    }
    if (palette_pick >= n) palette_pick = n -| 1;

    const win = dvui.windowRect();

    var fw = dialog_views.modalWindow(@src(), &palette_rect, &palette_open, style.surfaceRaised(), 560, dvui.Rect.all(style.space.sm));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, 70);

    var field = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{ .x = style.space.sm },
        .margin = .{ .h = style.space.sm },
    });
    dvui.icon(@src(), "palette_search", dvui.entypo.magnifying_glass, .{ .fill_color = .{ .color = style.textFaint() } }, .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
    });
    const te = dialog_views.textField(@src(), .{
        .text = .{ .array_list = .{ .backing = &palette_text, .allocator = app.gpa, .limit = 128 } },
        .placeholder = "Type a command, a branch or a repository",
    }, .{
        .expand = .horizontal,
        .font = style.body(),
        .margin = .{ .x = style.space.sm },
    });
    const entered = te.enter_pressed;
    const field_id = te.data().id;
    if (te.text_changed) palette_pick = 0;
    te.deinit();
    field.deinit();
    dialog_views.focusOnce(field_id);

    // Up, down and Esc belong to the palette while it is up, not to the
    // graph behind it.
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        const ke = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (ke.action == .up) continue;
        if (pr_editor.pressed(ke, .down, false)) {
            e.handled = true;
            if (palette_pick + 1 < n) palette_pick += 1;
        } else if (pr_editor.pressed(ke, .up, false)) {
            e.handled = true;
            palette_pick -|= 1;
        } else if (pr_editor.pressed(ke, .escape, false)) {
            e.handled = true;
            palette_open = false;
        }
    }

    var chosen: ?usize = if (entered and n > 0) palette_pick else null;
    for (0..n) |i| {
        // A heading wherever the kind of row changes; the gather above keeps
        // each kind together.
        if (i == 0 or std.meta.activeTag(items[i]) != std.meta.activeTag(items[i - 1])) {
            dialog_views.dropHeading(@src(), i, switch (items[i]) {
                .command => "COMMANDS",
                .ref => "BRANCHES",
                .repo => "REPOSITORIES",
            });
        }
        const icon, const hint = switch (items[i]) {
            .command => |c| .{ commands[c].icon, commands[c].keys },
            .ref => |r| .{ if (app.history.?.refs[r].kind == .remote) dvui.entypo.cloud else dvui.entypo.flow_branch, "switch to" },
            .repo => .{ dvui.entypo.folder, "open" },
        };
        if (paletteRow(@src(), i, icon, labels[i], hint, i == palette_pick)) chosen = i;
    }
    if (n == 0) {
        dvui.label(@src(), "Nothing by that name.", .{}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textFaint() },
            .padding = .{ .x = style.space.sm, .y = style.space.xs },
        });
    }

    const pick = chosen orelse return;
    palette_open = false;
    switch (items[pick]) {
        .command => |i| commands[i].run(),
        .ref => |i| github_actions.checkout(app.history.?.refs[i]),
        .repo => |r| github_actions.requestOpenKnown(tab_strip.groups.items[r.group].tabs.items[r.tab].path),
    }
}

fn paletteRow(src: std.builtin.SourceLocation, id: usize, icon: []const u8, name: []const u8, hint: []const u8, picked: bool) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.row_height },
        .background = true,
        .color_fill = .{ .color = if (picked) style.accentDim() else style.surfaceRaised() },
        .color_fill_hover = .{ .color = if (picked) style.accentDim() else style.rowHover() },
        .corners = style.radius.input,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.md, .w = style.space.md },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = false });
    defer row.deinit();

    const lit = picked or bw.hovered();
    dvui.icon(@src(), "palette_icon", icon, .{ .fill_color = .{ .color = if (lit) style.accent() else style.textMuted() } }, .{
        .min_size_content = .{ .w = 13, .h = 13 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.md },
    });
    dvui.label(@src(), "{s}", .{name}, .{
        .font = style.small(),
        .color_text = .{ .color = if (lit) style.text() else style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .padding = dvui.Rect.all(0),
    });
    if (hint.len > 0) {
        dvui.label(@src(), "{s}", .{hint}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.lg },
            .padding = dvui.Rect.all(0),
        });
    }
    return bw.clicked();
}

/// Every open repository, one tab each, the way every multi-repo client
/// shows them: what is open has to be visible, not filed in a menu, or nobody
/// finds out it came back after a restart. Groups are runs of them behind a
/// coloured label, underlined in its colour, folded to the label on a click.
pub fn tabStrip() void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.background() },
        .min_size_content = .{ .h = style.tab_height },
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
        // Nothing on the left: the first tab starts at the window's edge.
        .padding = .{ .w = style.space.sm },
        .margin = dvui.Rect.all(0),
    });
    defer strip.deinit();

    active_tab_foot = null;
    github_connect.workspaceSwitcher();
    window_chrome.tabList();
    window_chrome.userMenu();
    window_chrome.windowControls();

    // The strip's hairline runs under every tab; the active one is joined to
    // the bar below, so it is rubbed out there. After the tabs, which the
    // scroll area clips to the strip's inside, and so cannot reach it.
    if (active_tab_foot) |foot| foot.fill(.{}, .{ .color = .{ .color = style.surface() }, .fade = 0 });
}

/// The strip's bottom hairline under the active tab, as last drawn.
pub var active_tab_foot: ?dvui.Rect.Physical = null;
