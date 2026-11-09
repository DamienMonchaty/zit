const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const github = @import("../github/github.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const repo_io = @import("../core/repo_io.zig");
const github_actions = @import("../github/github_actions.zig");
const github_connect = @import("../github/github_connect.zig");
const pr_editor = @import("pr_editor.zig");
const app = @import("../main.zig");

// === What Zit does ===

pub var features_open = false;
pub var features_rect: dvui.Rect = .{};

const Feature = struct { icon: []const u8, title: []const u8, items: []const []const u8 };
/// Every feature, grouped as a day of work goes: the history, the changes,
/// the branches, the remotes, the forge, the workspace.
const features = [_]Feature{
    .{ .icon = dvui.entypo.flow_tree, .title = "History", .items = &.{
        "The graph, each commit its author's picture — or a dot",
        "A BRANCH / TAG column, and which branches it draws",
        "Search: author:, msg:, path:, code:, after:",
        "Hide branches from the graph: eye, or all",
        "A file's history, through its renames",
        "Blame, line by line",
        "Compare any two commits",
        "Pictures in the diff, before and after",
    } },
    .{ .icon = dvui.entypo.pencil, .title = "Changes & commits", .items = &.{
        "Stage files, hunks or single lines",
        "Even in a file git does not track yet",
        "Discard a hunk, a file, or everything",
        "A summary that stops at 72, the rest in the description",
        "Type, ticket, recent messages, co-authors, sign-off",
        "GPG or SSH signing, amend",
        "Undo and redo — Ctrl+Z, Ctrl+Shift+Z",
        "A commit's files filtered by kind",
    } },
    .{ .icon = dvui.entypo.flow_branch, .title = "Branches", .items = &.{
        "Create, rename, delete, switch",
        "Merge: fast-forward, no-ff or squash",
        "Rebase, and interactive rebase",
        "Drag one onto another: merge or rebase",
        "Cherry-pick, revert, reset",
        "Tags, made, pushed and deleted",
    } },
    .{ .icon = dvui.entypo.cloud, .title = "Remotes", .items = &.{
        "Fetch by hand or every few minutes",
        "Pull: merge, rebase or fast-forward only",
        "Push, setting the upstream itself",
        "Force push, always with a lease",
        "Stashes, several at once",
        "Worktrees, Git LFS",
    } },
    .{ .icon = dvui.entypo.merge, .title = "Pull requests", .items = &.{
        "Checks, reviews, threads in a timeline",
        "Create, check out, review, comment",
        "Suggestions applied here",
        "Merge, auto-merge, close",
        "Re-run the failed checks; issues",
        "Sign in with a code on github.com",
        "Off: nothing is asked of GitHub",
    } },
    .{ .icon = dvui.entypo.archive, .title = "Conflicts", .items = &.{
        "Both sides, side by side, with their base",
        "Each region: ours, theirs, or both — 1, 2, 3",
        "The safe ones resolved in one click",
        "Continue, skip or abort from the toolbar",
    } },
    .{ .icon = dvui.entypo.browser, .title = "Workspace", .items = &.{
        "Tabs, groups as colour dots, workspaces",
        "Open, clone or start a repository",
        "Command palette — Ctrl+P",
        "Open a file in your editor; a terminal in its folder",
        "Each repository its own settings",
    } },
    .{ .icon = dvui.entypo.palette, .title = "Look", .items = &.{
        "Zit Dark and Light, Catppuccin's four",
        "The app's text and the editor's, sized apart",
        "Zoom from 70 to 200 %, any keyboard",
    } },
    .{ .icon = dvui.entypo.gauge, .title = "Light", .items = &.{
        "Draws only when something changes",
        "Sees the repository change on disk",
        "Long lists drawn a screenful at a time",
        "About 7 MB, nothing else to install",
    } },
};

pub fn featuresDialog() void {
    if (!features_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &features_rect, &features_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    identity_view.dialogHeader(@src(), dvui.entypo.info_with_circle, "About Zit", "Version " ++ app.APP_VERSION ++ " · " ++ PLATFORM, &features_open);

    const w: f32 = @min(780, win.w - 80);
    // The app itself: its mark, what it is, where to read more.
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = w },
            .max_size_content = .width(w),
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.border() },
            .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.xl, .h = style.space.lg },
        });
        defer head.deinit();
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = @embedFile("../brand/zit-icon-256.png"), .name = "zit" } },
            .shrink = .both,
        }, .{ .min_size_content = .{ .w = 56, .h = 56 }, .max_size_content = .size(.{ .w = 56, .h = 56 }), .gravity_y = 0.5, .margin = .{ .w = style.space.lg } });
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false });
        defer col.deinit();
        dvui.label(@src(), "Zit " ++ app.APP_VERSION, .{}, .{ .font = style.title().withSize(18 * style.ui_scale), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "A fast, native Git client for Linux and Windows, written in Zig.", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2, .h = style.space.md } });
        var links = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        defer links.deinit();
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.book, "Documentation", true, "about:docs")) github_actions.openUrl(SITE_URL);
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.star, "What's new", false, "about:changelog")) github_actions.openUrl(SITE_URL ++ "project/changelog/");
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.code, "Source", false, "about:repo")) github_actions.openUrl(REPO_URL);
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.bug, "Report a problem", false, "about:issue")) github_actions.openUrl(REPO_URL ++ "/issues/new");
    }

    // What it does: the kinds down the left, the one picked on the right.
    var split = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = w, .h = 300 },
        .max_size_content = .size(.{ .w = w, .h = 300 }),
        .background = false,
    });
    defer split.deinit();
    {
        var nav = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 200 },
            .expand = .vertical,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .border = .{ .w = 1 },
            .color_border = .{ .color = style.border() },
            .padding = dvui.Rect.all(style.space.sm),
        });
        defer nav.deinit();
        for (features, 0..) |feature, i| {
            const on = features_page == i;
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{ .draw_focus = false }, .{
                .id_extra = i,
                .tag = dialog_views.frameTag("about", feature.title),
                .expand = .horizontal,
                .background = true,
                .color_fill = .{ .color = if (on) style.accentDim() else style.surface() },
                .color_fill_hover = .{ .color = if (on) style.accentDim() else style.rowHover() },
                .corners = style.radius.input,
                .margin = .{ .h = 2 },
                .padding = .{ .x = style.space.sm, .y = 5, .w = style.space.sm, .h = 5 },
            });
            bw.processEvents();
            bw.drawBackground();
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
                defer row.deinit();
                dvui.icon(@src(), "about_icon", feature.icon, .{ .fill_color = .{ .color = if (on) style.accent() else style.textMuted() } }, .{ .min_size_content = .{ .w = 13, .h = 13 }, .gravity_y = 0.5, .margin = .{ .w = style.space.md } });
                dvui.label(@src(), "{s}", .{feature.title}, .{ .font = if (on) style.smallBold() else style.small(), .color_text = .{ .color = if (on) style.text() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            }
            if (bw.clicked()) features_page = i;
            bw.deinit();
        }
    }
    {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .color = style.surface() }, .padding = dvui.Rect.all(style.space.xl) });
        defer body.deinit();
        const feature = features[@min(features_page, features.len - 1)];
        {
            var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .margin = .{ .h = style.space.md } });
            defer head.deinit();
            identity_view.iconTile(@src(), feature.icon, 32, 16);
            dvui.label(@src(), "{s}", .{feature.title}, .{ .font = style.bodyBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .margin = .{ .x = style.space.md }, .padding = dvui.Rect.all(0) });
        }
        for (feature.items, 0..) |item, i| {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .background = false, .padding = .{ .y = 3, .h = 3 } });
            defer line.deinit();
            dvui.icon(@src(), "feature_tick", dvui.entypo.check, .{ .fill_color = .{ .color = style.accent() } }, .{
                .min_size_content = .{ .w = 10, .h = 10 },
                .gravity_y = 0.5,
                .margin = .{ .x = 2, .w = style.space.md },
            });
            dvui.label(@src(), "{s}", .{item}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
    }

    if (dialog_views.escapePressed()) features_open = false;
}

/// The kind of feature the About dialog shows.
pub var features_page: usize = 0;

/// Where Zit is: its documentation, and its sources.
pub const SITE_URL = "https://damienmonchaty.github.io/zit/";
const REPO_URL = "https://github.com/DamienMonchaty/zit";
const PLATFORM = switch (@import("builtin").os.tag) {
    .windows => "Windows",
    .macos => "macOS",
    else => "Linux",
} ++ " " ++ @tagName(@import("builtin").cpu.arch);

/// A panel's fold button in the status bar: lit while the panel is shown.
pub fn panelToggle(src: std.builtin.SourceLocation, shown: *bool, icon: []const u8, hint: []const u8, tag: []const u8) void {
    if (dialog_views.iconButtonTagged(src, tag, hint, icon, if (shown.*) style.accent() else style.textFaint(), tag)) shown.* = !shown.*;
}

/// One count in the status bar, after its icon. English plurals, which is
/// all this needs: "1 stash", "2 stashes".
pub fn statusStat(src: std.builtin.SourceLocation, icon: []const u8, n: usize, one: []const u8, many: []const u8) void {
    var cell = dvui.box(src, .{ .dir = .horizontal }, .{
        .background = false,
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.lg },
        .padding = dvui.Rect.all(0),
    });
    defer cell.deinit();
    dvui.icon(@src(), "stat_icon", icon, .{ .fill_color = .{ .color = style.textFaint() } }, .{
        .min_size_content = .{ .w = 11, .h = 11 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    dvui.label(@src(), "{d}", .{n}, .{
        .font = style.tinyBold(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    dvui.label(@src(), "{s}", .{if (n == 1) one else many}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .margin = .{ .x = 3 },
        .padding = dvui.Rect.all(0),
    });
}

/// The status bar's word on the last command: its icon and line on a pill
/// tinted by `color`.
pub fn statusPill(src: std.builtin.SourceLocation, color: dvui.Color, icon: []const u8, text: []const u8, tail: []const u8) void {
    var pill = dvui.box(src, .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = .{ .color = color.opacity(0.14) },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .max_size_content = .width(460),
        .margin = .{ .x = style.space.sm },
        .padding = .{ .x = style.space.sm, .y = 1, .w = style.space.sm, .h = 1 },
    });
    defer pill.deinit();
    dvui.icon(@src(), "pill_icon", icon, .{ .fill_color = .{ .color = color } }, .{
        .min_size_content = .{ .w = 10, .h = 10 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    dvui.label(@src(), "{s}{s}", .{ text, tail }, .{
        .font = style.tiny(),
        .color_text = .{ .color = color },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// The new-tab page, and what shows with nothing open: who you are, the
/// three ways to get a repository into a tab, and every one a tab has held —
/// found by typing, opened with Enter.
pub fn startScreen() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
    });
    defer scroll.deinit();

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = 0.5,
        .min_size_content = .{ .w = START_W },
        .max_size_content = .width(START_W),
        .background = false,
        .padding = .{ .y = 48, .h = style.space.xxl },
    });
    defer page.deinit();

    {
        // The mark, small, and a word to whoever git says is here.
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.xl } });
        defer head.deinit();
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{
                .bytes = if (app.dark_theme) @embedFile("../brand/zit-logo-light.png") else @embedFile("../brand/zit-logo-dark.png"),
                .name = "zit logo",
            } },
            .shrink = .ratio,
        }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 86, .h = 48 },
            .max_size_content = .size(.{ .w = 86, .h = 48 }),
            .margin = .{ .w = style.space.lg },
        });
        var words = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5, .background = false });
        defer words.deinit();
        window_chrome.loadMe();
        const first = std.mem.sliceTo(std.mem.trim(u8, window_chrome.me_name.items, " "), ' ');
        if (first.len > 0)
            dvui.label(@src(), "Hello, {s}", .{first}, .{ .font = style.title(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) })
        else
            dvui.label(@src(), "Welcome to Zit", .{}, .{ .font = style.title(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "Pick up where you left off, or bring a repository in.", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0), .margin = .{ .y = style.space.xxs } });
    }

    if (tab_strip.open_error) |message| {
        if (app.repo == null) dvui.label(@src(), "{s}", .{message}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textFaint() },
            .padding = dvui.Rect.all(0),
            .margin = .{ .h = style.space.md },
        });
    }

    {
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .margin = .{ .h = style.space.xl } });
        defer actions.deinit();
        if (startAction(@src(), dvui.entypo.folder, "Open a folder", "Ctrl+O", "start:Open a repository", true)) repo_io.requestAction(.open_repo);
        if (startAction(@src(), dvui.entypo.download, "Clone", null, "start:Clone", false)) dialog_views.openRepoDialog(.clone);
        if (startAction(@src(), dvui.entypo.plus, "New repository", null, "start:Start a new one", false)) dialog_views.openRepoDialog(.create);
    }

    // What the list shows, as typed: by name or anywhere in the path.
    const field = dialog_views.searchField(@src(), &start_filter, "Find a repository", "start_filter", .{ .h = style.space.lg });
    dialog_views.focusOnce(field);
    const needle = std.mem.trim(u8, start_filter.items, " ");

    // Every row shown, in order, so the keys can walk them.
    var shown: std.ArrayList([]const u8) = .empty;
    defer shown.deinit(dvui.currentWindow().arena());
    const arena = dvui.currentWindow().arena();
    var open_n: usize = 0;
    for (tab_strip.groups.items, 0..) |group, gi| for (group.tabs.items, 0..) |tab, ti| {
        if (github_connect.listedEarlier(gi, ti, tab.path) or !startMatches(needle, tab.path)) continue;
        shown.append(arena, tab.path) catch {};
        open_n += 1;
    };
    for (tab_strip.recent.items) |path| {
        if (isOpenTab(path) or !startMatches(needle, path)) continue;
        shown.append(arena, path) catch {};
    }

    // Up and down walk the rows while the field has the keys; Enter opens
    // the one picked.
    if (start_pick >= shown.items.len) start_pick = shown.items.len -| 1;
    if (dvui.focusedWidgetId() == field) for (dvui.events()) |*e| {
        if (e.handled) continue;
        const ke = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (ke.action == .up) continue;
        if (pr_editor.pressed(ke, .down, false)) {
            e.handled = true;
            if (start_pick + 1 < shown.items.len) start_pick += 1;
        } else if (pr_editor.pressed(ke, .up, false)) {
            e.handled = true;
            start_pick -|= 1;
        }
    };
    if (dialog_views.search_entered == field) {
        dialog_views.search_entered = null;
        if (start_pick < shown.items.len) github_actions.requestOpenKnown(shown.items[start_pick]);
    }

    for (shown.items, 0..) |path, i| {
        if (i == 0 and open_n > 0) startHeading(@src(), 0, "Open in tabs", open_n);
        if (i == open_n) startHeading(@src(), 1, "Recent", shown.items.len - open_n);
        recentRow(@src(), i, path, i < open_n, i == start_pick);
    }

    if (shown.items.len == 0) {
        dvui.label(@src(), "{s}", .{if (needle.len > 0) "No repository by that name." else "Nothing yet. What you open is remembered here."}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textFaint() },
            .margin = .{ .x = style.space.md, .y = style.space.md },
            .padding = dvui.Rect.all(0),
        });
    }
}

const START_W: f32 = 720;
/// What the start page's list is narrowed to, and the row the keys are on.
var start_filter: std.ArrayList(u8) = .empty;
var start_pick: usize = 0;

fn startMatches(needle: []const u8, path: []const u8) bool {
    return needle.len == 0 or std.ascii.findIgnoreCase(path, needle) != null;
}

/// Over a run of rows: what they are, and how many.
fn startHeading(src: std.builtin.SourceLocation, id: usize, title: []const u8, count: usize) void {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{ .id_extra = id, .background = false, .margin = .{ .x = style.space.md, .y = style.space.lg, .h = style.space.xs } });
    defer line.deinit();
    dvui.label(@src(), "{s}", .{title}, .{ .font = style.smallBold(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{d}", .{count}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
}

/// One of the three ways in, as a button in a row: the first filled in the
/// accent, the others framed; `keys` after its caption.
fn startAction(src: std.builtin.SourceLocation, icon: []const u8, caption: []const u8, keys: ?[]const u8, tag: []const u8, primary: bool) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = tag,
        .background = true,
        .color_fill = .{ .color = if (primary) style.accent() else style.surface() },
        .color_fill_hover = .{ .color = if (primary) style.accent().lerp(style.text(), 0.15) else style.surfaceRaised() },
        .border = dvui.Rect.all(if (primary) 0 else 1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .margin = .{ .w = style.space.sm },
        .padding = .{ .x = style.space.lg, .y = style.space.sm, .w = style.space.lg, .h = style.space.sm },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    const ink = if (primary) style.background() else style.text();
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
    defer line.deinit();
    dvui.icon(@src(), "start_icon", icon, .{ .fill_color = .{ .color = if (primary) ink else style.accent() } }, .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    dvui.label(@src(), "{s}", .{caption}, .{ .font = style.bodyBold(), .color_text = .{ .color = ink }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    if (keys) |k| dvui.label(@src(), "{s}", .{k}, .{ .font = style.tiny(), .color_text = .{ .color = ink.opacity(0.7) }, .gravity_y = 0.5, .margin = .{ .x = style.space.md }, .padding = dvui.Rect.all(0) });
    return bw.clicked();
}

pub fn isOpenTab(path: []const u8) bool {
    for (tab_strip.groups.items) |group| {
        for (group.tabs.items) |tab| {
            if (std.mem.eql(u8, tab.path, path)) return true;
        }
    }
    return false;
}

/// One repository on the start page: its initials, as its tab shows them,
/// its name and the folder it is in. A click opens it, Enter too when the
/// keys are on it; the × — on hover — forgets it, after asking.
fn recentRow(src: std.builtin.SourceLocation, id: usize, path: []const u8, open: bool, picked: bool) void {
    var row_box = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
    });
    defer row_box.deinit();
    const hover = row_box.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt);

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = 44 },
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    bw.processEvents();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = picked or bw.hovered(),
            .color_fill = .{ .color = if (picked) style.accentDim() else style.rowHover() },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.md, .w = style.space.md },
        });
        defer row.deinit();

        const trimmed = std.mem.trimEnd(u8, path, "/\\");
        {
            // One column for the initials, however wide two letters are, so
            // the names line up.
            var mark = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 34 }, .max_size_content = .width(34), .gravity_y = 0.5, .background = false });
            defer mark.deinit();
            github_connect.tabBadge(git.repoName(path), open or picked);
        }

        var text = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .background = false,
            .padding = dvui.Rect.all(0),
        });
        dvui.label(@src(), "{s}", .{git.repoName(path)}, .{
            .font = style.bodyBold(),
            .color_text = .{ .color = style.text() },
            .padding = dvui.Rect.all(0),
        });
        dvui.label(@src(), "{s}", .{std.fs.path.dirname(trimmed) orelse trimmed}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.textFaint() },
            .max_size_content = .width(0),
            .expand = .horizontal,
            .padding = dvui.Rect.all(0),
        });
        text.deinit();

        if (picked) dvui.label(@src(), "Enter", .{}, .{
            .font = style.tiny(),
            .color_text = .{ .color = style.accent() },
            .background = true,
            .color_fill = .{ .color = style.background() },
            .corners = style.radius.tag,
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.sm },
            .padding = .{ .x = style.space.xs, .w = style.space.xs },
        });
    }
    if (bw.clicked()) github_actions.requestOpenKnown(path);
    bw.deinit();

    if (dialog_views.iconButton(@src(), "forget_repo", "Remove from Zit…", dvui.entypo.cross, if (hover or picked) style.textFaint() else dvui.Color.transparent)) {
        dialog_views.askForget(path);
    }
}
