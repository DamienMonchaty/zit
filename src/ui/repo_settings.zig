const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const run = @import("../core/run.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const commit_view = @import("commit_view.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const home_page = @import("home_page.zig");
const github_actions = @import("../github/github_actions.zig");
const github_connect = @import("../github/github_connect.zig");
const pr_create = @import("pr_create.zig");
const app = @import("../main.zig");

// === This repository's settings ===
//
// What git keeps in the repository's own .git/config: read when the page is
// opened, written as it is changed, so git — and any other tool — goes by
// them too. Unset, the global ones hold.

pub var repo_prefs_loaded = false;
pub var repo_prefs_job: ?*run.Capture = null;
/// Which repository's settings the page shows, picked from every one Zit
/// knows; owned.
pub var repo_settings_path: std.ArrayList(u8) = .empty;
pub var repo_name_local: std.ArrayList(u8) = .empty;
pub var repo_email_local: std.ArrayList(u8) = .empty;
/// How `git pull` joins what it fetched: as set everywhere, or here.
pub var repo_pull: enum { global, merge, rebase, ff_only } = .global;
/// `fetch.prune` and `commit.gpgsign` here: unset, on, off.
pub var repo_prune: Tri = .global;
pub var repo_sign: Tri = .global;
const Tri = enum { global, on, off };

pub fn loadRepoPrefs() void {
    if (repo_prefs_loaded or repo_settings_path.items.len == 0) return;
    const job_now = repo_prefs_job orelse blk: {
        const started = run.Capture.start(app.gpa, app.app_io, repo_settings_path.items, &.{ "git", "config", "--local", "--get-regexp", "^(user\\.name|user\\.email|pull\\.rebase|pull\\.ff|fetch\\.prune|commit\\.gpgsign)$" }) catch {
            repo_prefs_loaded = true;
            return;
        };
        repo_prefs_job = started;
        break :blk started;
    };
    if (!job_now.finished()) return;
    repo_prefs_job = null;
    defer job_now.deinit(app.app_io);
    // Asked about another repository than the one picked since: again.
    if (!std.mem.eql(u8, job_now.cwd, repo_settings_path.items)) return;

    repo_prefs_loaded = true;
    repo_name_local.clearRetainingCapacity();
    repo_email_local.clearRetainingCapacity();
    repo_pull = .global;
    repo_prune = .global;
    repo_sign = .global;
    // Nothing set gives git's exit 1: every setting as everywhere.
    var lines = std.mem.splitScalar(u8, job_now.out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = std.mem.trim(u8, line[space + 1 ..], " ");
        const yes = std.ascii.eqlIgnoreCase(value, "true");
        if (std.mem.eql(u8, key, "user.name")) {
            repo_name_local.appendSlice(app.gpa, value) catch {};
        } else if (std.mem.eql(u8, key, "user.email")) {
            repo_email_local.appendSlice(app.gpa, value) catch {};
        } else if (std.mem.eql(u8, key, "pull.rebase")) {
            if (repo_pull != .ff_only) repo_pull = if (yes) .rebase else .merge;
        } else if (std.mem.eql(u8, key, "pull.ff")) {
            if (std.mem.eql(u8, value, "only")) repo_pull = .ff_only;
        } else if (std.mem.eql(u8, key, "fetch.prune")) {
            repo_prune = if (yes) .on else .off;
        } else if (std.mem.eql(u8, key, "commit.gpgsign")) {
            repo_sign = if (yes) .on else .off;
        }
    }
}

/// `git config --local key value` in the repository picked — the empty
/// value unsets it.
pub fn setLocalConfig(key: []const u8, value: []const u8) void {
    const where = repo_settings_path.items;
    if (where.len == 0) return;
    var outcome = (if (value.len == 0)
        run.git(app.gpa, app.app_io, where, &.{ "config", "--local", "--unset-all", key })
    else
        run.git(app.gpa, app.app_io, where, &.{ "config", "--local", key, value })) catch return github_actions.setCommandError("Could not run git. Is it on your PATH?");
    defer outcome.deinit(app.gpa);
    // Unsetting what was never set is git's exit 5: nothing to say.
    if (!outcome.ok and value.len > 0) github_actions.setCommandError(if (outcome.message.len > 0) outcome.message else "git config failed.");
    repo_prefs_loaded = false;
}

/// Which of `steps` `value` is closest to: a saved factor read back as the
/// chip it was picked from.
pub fn nearestStep(steps: []const f32, value: f32) usize {
    var best: usize = 0;
    for (steps, 0..) |v, i| if (@abs(v - value) < @abs(steps[best] - value)) {
        best = i;
    };
    return best;
}

/// One choice out of a few, as a row of chips: the one picked ticked.
pub fn choiceChips(id: usize, options: []const []const u8, current: usize) ?usize {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .background = false });
    defer row.deinit();
    var picked: ?usize = null;
    for (options, 0..) |caption, i| {
        var chip = dvui.box(@src(), .{}, .{ .id_extra = i, .background = false });
        defer chip.deinit();
        if (dialog_views.chipButton(@src(), if (current == i) dvui.entypo.check else dvui.entypo.dot_single, caption, current == i)) picked = i;
    }
    return picked;
}

/// The page: who commits here, how pull joins, whether fetch prunes and
/// commits are signed — each "as everywhere" until set.
/// Every repository Zit knows: the one open, its tabs, then the ones it
/// remembers — each once.
pub fn knownRepos() []const []const u8 {
    const a = dvui.currentWindow().arena();
    var known: std.ArrayList([]const u8) = .empty;
    if (app.repo != null and !home_page.isOpenTab(app.repo_path.items)) known.append(a, app.repo_path.items) catch {};
    for (tab_strip.groups.items, 0..) |group, gi| for (group.tabs.items, 0..) |tab, ti| {
        if (!github_connect.listedEarlier(gi, ti, tab.path)) known.append(a, tab.path) catch {};
    };
    for (tab_strip.recent.items) |path| if (!home_page.isOpenTab(path)) known.append(a, path) catch {};
    return known.items;
}

pub fn repoSettings() void {
    var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = identity_view.settings_body_pad });
    defer section.deinit();

    const known = knownRepos();
    if (known.len == 0) {
        dvui.label(@src(), "No repository yet. Open one and its settings are here.", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
        return;
    }
    if (repo_settings_path.items.len == 0) repo_settings_path.appendSlice(app.gpa, known[0]) catch {};

    loadRepoPrefs();
    if (!repo_prefs_loaded) {
        dvui.label(@src(), "Reading its config…", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
        return;
    }

    identity_view.settingsField(@src(), "Name and email here", "Commits in this repository only — work or personal. Empty: the global ones");
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false });
        defer row.deinit();
        for ([_]*std.ArrayList(u8){ &repo_name_local, &repo_email_local }, [_][]const u8{ window_chrome.me_name.items, window_chrome.me_email.items }, 0..) |list, global, i| {
            var cell = dvui.box(@src(), .{}, .{ .id_extra = i, .expand = .horizontal, .background = false, .margin = .{ .w = if (i == 0) style.space.sm else 0 } });
            defer cell.deinit();
            const te = dialog_views.textField(@src(), .{
                .text = .{ .array_list = .{ .backing = list, .allocator = app.gpa, .limit = 256 } },
                .placeholder = if (global.len > 0) global else if (i == 0) "Name" else "Email",
            }, identity_view.settingsInput().override(.{ .tag = if (i == 0) "repo:name" else "repo:email" }));
            te.deinit();
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.sm } });
        defer row.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButtonTagged(@src(), "Save", true, "repo:save_identity")) {
            setLocalConfig("user.name", std.mem.trim(u8, repo_name_local.items, " "));
            setLocalConfig("user.email", std.mem.trim(u8, repo_email_local.items, " "));
        }
    }

    identity_view.settingsField(@src(), "Pull", "How Pull joins what it fetched — pull.rebase and pull.ff");
    if (choiceChips(0, &.{ "As everywhere", "Merge", "Rebase", "Fast-forward only" }, @backingInt(repo_pull))) |i| {
        switch (i) {
            0 => {
                setLocalConfig("pull.rebase", "");
                setLocalConfig("pull.ff", "");
            },
            1 => {
                setLocalConfig("pull.ff", "");
                setLocalConfig("pull.rebase", "false");
            },
            2 => {
                setLocalConfig("pull.ff", "");
                setLocalConfig("pull.rebase", "true");
            },
            else => {
                setLocalConfig("pull.rebase", "");
                setLocalConfig("pull.ff", "only");
            },
        }
    }

    identity_view.settingsField(@src(), "Prune when fetching", "Drop the remote branches deleted on the remote — fetch.prune");
    if (choiceChips(1, &.{ "As everywhere", "On", "Off" }, @backingInt(repo_prune))) |i| {
        setLocalConfig("fetch.prune", switch (i) {
            0 => "",
            1 => "true",
            else => "false",
        });
        // What Fetch passes follows: the open repository's config read again.
        if (app.repo != null and std.mem.eql(u8, repo_settings_path.items, app.repo_path.items)) commit_view.startRepoConfig();
    }

    identity_view.settingsField(@src(), "Sign commits", "Every commit made here signed with your key — commit.gpgsign");
    if (choiceChips(2, &.{ "As everywhere", "On", "Off" }, @backingInt(repo_sign))) |i| {
        setLocalConfig("commit.gpgsign", switch (i) {
            0 => "",
            1 => "true",
            else => "false",
        });
    }
}

/// The editors a file can open with, by the command that starts each, and
/// the name it goes by.
const known_editors = [_]struct { []const u8, []const u8 }{
    .{ "code", "VS Code" },
    .{ "codium", "VSCodium" },
    .{ "cursor", "Cursor" },
    .{ "zed", "Zed" },
    .{ "subl", "Sublime Text" },
    .{ "idea", "IntelliJ IDEA" },
    .{ "webstorm", "WebStorm" },
    .{ "notepad++", "Notepad++" },
    .{ "kate", "Kate" },
    .{ "gnome-text-editor", "Text Editor" },
    .{ "gedit", "gedit" },
    .{ "mousepad", "Mousepad" },
};
/// The terminals Terminal can open, by command and name.
const known_terminals = if (@import("builtin").os.tag == .windows) [_]struct { []const u8, []const u8 }{
    .{ "wt", "Windows Terminal" },
    .{ "pwsh", "PowerShell 7" },
    .{ "powershell", "Windows PowerShell" },
    .{ "cmd", "Command Prompt" },
} else [_]struct { []const u8, []const u8 }{
    .{ "konsole", "Konsole" },
    .{ "gnome-terminal", "GNOME Terminal" },
    .{ "kitty", "kitty" },
    .{ "alacritty", "Alacritty" },
    .{ "wezterm", "WezTerm" },
    .{ "ghostty", "Ghostty" },
    .{ "foot", "foot" },
    .{ "xfce4-terminal", "Xfce Terminal" },
    .{ "tilix", "Tilix" },
    .{ "xterm", "xterm" },
};
/// Which of them this machine has, found once the settings open.
var editors_found: [known_editors.len]bool = @splat(false);
var terminals_found: [known_terminals.len]bool = @splat(false);
pub var editors_loaded = false;
pub var editors_job: ?*run.Capture = null;

/// Each known editor whose command is on the PATH, one name a line: one
/// shell for all of them, off the window's thread.
fn loadEditors() void {
    if (editors_loaded) return;
    const job_now = editors_job orelse blk: {
        const a = dvui.currentWindow().arena();
        var names: std.ArrayList(u8) = .empty;
        for (known_editors) |e| {
            names.appendSlice(a, e[0]) catch {};
            names.append(a, ' ') catch {};
        }
        for (known_terminals) |e| {
            names.appendSlice(a, e[0]) catch {};
            names.append(a, ' ') catch {};
        }
        const script = if (@import("builtin").os.tag == .windows)
            std.fmt.allocPrint(a, "for %e in ({s}) do @where %e >nul 2>nul && @echo %e", .{names.items}) catch return
        else
            std.fmt.allocPrint(a, "for e in {s}; do command -v \"$e\" >/dev/null 2>&1 && echo \"$e\"; done; true", .{names.items}) catch return;
        const argv: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "cmd.exe", "/c", script } else &.{ "sh", "-c", script };
        const started = run.Capture.start(app.gpa, app.app_io, ".", argv) catch {
            editors_loaded = true;
            return;
        };
        editors_job = started;
        break :blk started;
    };
    if (!job_now.finished()) return;
    editors_job = null;
    defer job_now.deinit(app.app_io);
    editors_loaded = true;
    editors_found = @splat(false);
    terminals_found = @splat(false);
    var lines = std.mem.splitScalar(u8, job_now.out, '\n');
    while (lines.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r");
        for (known_editors, 0..) |e, i| if (std.mem.eql(u8, e[0], name)) {
            editors_found[i] = true;
        };
        for (known_terminals, 0..) |e, i| if (std.mem.eql(u8, e[0], name)) {
            terminals_found[i] = true;
        };
    }
}

/// The editor setting, as a select: the system's choice, or each editor
/// found here. True when it changed.
pub fn editorChoice() bool {
    loadEditors();
    const current = std.mem.trim(u8, tab_strip.editor_cmd.items, " ");
    var face: []const u8 = if (current.len == 0) "System default" else current;
    for (known_editors) |e| if (std.mem.eql(u8, e[0], current)) {
        face = e[1];
    };
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.sm } });
    defer cell.deinit();
    const p = pr_create.picker(EDITOR_PICKER, face, "", "settings:editor");
    defer p.end();
    const m = p.menu orelse return false;
    if (!editors_loaded) dvui.label(@src(), "Looking for the editors on this computer…", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm } });
    var picked: ?[]const u8 = null;
    if (pr_create.pickRow(0, "System default", "what the system opens the file with", current.len == 0, null)) picked = "";
    for (known_editors, 0..) |e, i| {
        if (!editors_found[i]) continue;
        if (pr_create.pickRow(i + 1, e[1], e[0], std.mem.eql(u8, current, e[0]), null)) picked = e[0];
    }
    const cmd = picked orelse return false;
    m.close();
    tab_strip.editor_cmd.clearRetainingCapacity();
    tab_strip.editor_cmd.appendSlice(app.gpa, cmd) catch {};
    return true;
}

/// The terminal setting, as a select: the first found, or one of those
/// installed here. True when it changed.
pub fn terminalChoice() bool {
    loadEditors();
    const current = std.mem.trim(u8, tab_strip.terminal_cmd.items, " ");
    var face: []const u8 = "Automatic";
    for (known_terminals) |e| if (std.mem.eql(u8, e[0], current)) {
        face = e[1];
    };
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.sm } });
    defer cell.deinit();
    const p = pr_create.picker(TERMINAL_PICKER, face, "", "settings:terminal");
    defer p.end();
    const m = p.menu orelse return false;
    if (!editors_loaded) dvui.label(@src(), "Looking for the terminals on this computer…", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm } });
    var picked: ?[]const u8 = null;
    if (pr_create.pickRow(0, "Automatic", if (@import("builtin").os.tag == .windows) "Windows Terminal where there is one" else "$TERMINAL, then the first found", current.len == 0, null)) picked = "";
    for (known_terminals, 0..) |e, i| {
        if (!terminals_found[i]) continue;
        if (pr_create.pickRow(i + 1, e[1], e[0], std.mem.eql(u8, current, e[0]), null)) picked = e[0];
    }
    const cmd = picked orelse return false;
    m.close();
    tab_strip.terminal_cmd.clearRetainingCapacity();
    tab_strip.terminal_cmd.appendSlice(app.gpa, cmd) catch {};
    return true;
}

/// Picker ids of the settings' selects, apart from those of the dialogs.
const EDITOR_PICKER = 50;
const TERMINAL_PICKER = 51;

/// `path` — the repository's file — in the editor the settings name, or the
/// system's choice for it.
pub fn openInEditor(path: []const u8) void {
    if (app.repo == null) return;
    const a = dvui.currentWindow().arena();
    const full = std.fs.path.join(a, &.{ app.repo_path.items, path }) catch return;
    const cmd = std.mem.trim(u8, tab_strip.editor_cmd.items, " ");
    if (cmd.len == 0) return run.open(app.app_io, app.repo_path.items, full) catch github_actions.setCommandError("Could not open the file.");
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (words.next()) |w| argv.append(a, w) catch return;
    argv.append(a, full) catch return;
    // Not waited on: an editor can stay open for hours.
    run.startDetached(app.app_io, app.repo_path.items, argv.items) catch github_actions.setCommandError("Could not start the editor. Is it on your PATH?");
}

/// `git config --global key value` — the empty value unsets it — then read
/// back, so what is shown is what git has.
pub fn setGlobalConfig(key: []const u8, value: []const u8) void {
    var outcome = (if (value.len == 0)
        run.git(app.gpa, app.app_io, ".", &.{ "config", "--global", "--unset", key })
    else
        run.git(app.gpa, app.app_io, ".", &.{ "config", "--global", key, value })) catch return github_actions.setCommandError("Could not run git. Is it on your PATH?");
    defer outcome.deinit(app.gpa);
    if (!outcome.ok and value.len > 0) github_actions.setCommandError(if (outcome.message.len > 0) outcome.message else "git config failed.");
    identity_view.signing_loaded = false;
}

/// One setting: what it is and what it does, its switch on the right.
/// True when it was flipped.
pub fn settingsSwitch(id: usize, value: *bool, title: []const u8, hint: []const u8) bool {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
        .padding = .{ .y = style.space.sm, .h = style.space.sm },
    });
    defer row.deinit();
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .gravity_y = 0.5 });
        defer col.deinit();
        dvui.label(@src(), "{s}", .{title}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "{s}", .{hint}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2 } });
    }
    if (!toggle(@src(), value.*)) return false;
    value.* = !value.*;
    return true;
}

fn settingsHeading(src: std.builtin.SourceLocation, caption: []const u8) void {
    dvui.label(src, "{s}", .{caption}, .{
        .font = style.section(),
        .color_text = .{ .color = style.textFaint() },
        .margin = .{ .h = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
}

/// A theme to pick, drawn in its own colours: a strip of background, a
/// surface and an accent, so it is chosen by looking rather than by name.
pub fn themeCard(src: std.builtin.SourceLocation, id: usize) bool {
    const t = style.themes[id];
    const caption = t.name;
    const selected = id == app.theme_index;
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = dialog_views.frameTag("theme", caption),
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
        .margin = .{ .x = style.space.xs, .w = style.space.xs },
        .padding = dvui.Rect.all(0),
    });
    defer bw.deinit();
    bw.processEvents();

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.surfaceRaised() },
        .border = dvui.Rect.all(if (selected) 2 else 1),
        .color_border = .{ .color = if (selected) style.accent() else if (bw.hovered()) style.textFaint() else style.border() },
        .corners = style.radius.row,
        .padding = dvui.Rect.all(style.space.sm),
    });
    defer card.deinit();

    const bg = style.hex(t.preview[0]);
    const panel = style.hex(t.preview[1]);
    const line = style.hex(t.preview[2]);
    const accent = style.hex(t.preview[3]);
    {
        var preview = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .h = 64 },
            .background = true,
            .color_fill = .{ .color = bg },
            .corners = style.radius.input,
            .padding = dvui.Rect.all(style.space.sm),
            .margin = .{ .h = style.space.sm },
        });
        defer preview.deinit();

        var side = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 40 },
            .expand = .vertical,
            .background = true,
            .color_fill = .{ .color = panel },
            .corners = style.radius.tag,
            .margin = .{ .w = style.space.sm },
        });
        side.deinit();

        var main_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
        defer main_col.deinit();
        for (0..3) |i| {
            var bar = dvui.box(@src(), .{}, .{
                .id_extra = i,
                .expand = .horizontal,
                .min_size_content = .{ .h = 8 },
                .background = true,
                .color_fill = .{ .color = if (i == 0) accent else line },
                .corners = style.radius.tag,
                .margin = .{ .h = 6, .w = if (i == 2) 30 else 0 },
            });
            bar.deinit();
        }
    }

    {
        var caption_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer caption_row.deinit();
        dvui.label(@src(), "{s}", .{caption}, .{
            .font = style.smallBold(),
            .color_text = .{ .color = style.text() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
        if (selected) {
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            dvui.icon(@src(), "theme_check", dvui.entypo.check, .{ .fill_color = .{ .color = style.accent() } }, .{
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
            });
        }
    }

    return bw.clicked();
}

/// An on/off switch: a pill with a knob, the knob on the right when on.
pub fn toggle(src: std.builtin.SourceLocation, on: bool) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .min_size_content = .{ .w = 36, .h = 20 },
        .max_size_content = .size(.{ .w = 36, .h = 20 }),
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = if (on) style.accent() else style.border() },
        .corners = .all(10),
        .margin = .{ .x = style.space.md, .w = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();

    var knob = dvui.box(@src(), .{}, .{
        .rect = .{ .x = if (on) 18 else 2, .y = 2, .w = 16, .h = 16 },
        .background = true,
        .color_fill = .{ .color = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .corners = .all(8),
    });
    knob.deinit();

    return bw.clicked();
}

pub fn shortcutRow(src: std.builtin.SourceLocation, keys: []const u8, what: []const u8) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{ .x = style.space.xs, .y = style.space.xs, .w = style.space.xs, .h = style.space.xs },
    });
    defer row.deinit();
    dvui.label(@src(), "{s}", .{what}, .{
        .font = style.small(),
        .color_text = .{ .color = style.text() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .padding = dvui.Rect.all(0),
    });
    // Each key of the chord on a cap of its own.
    var caps = std.mem.splitScalar(u8, keys, '+');
    var i: usize = 0;
    while (caps.next()) |cap| : (i += 1) {
        dvui.label(@src(), "{s}", .{cap}, .{
            .id_extra = i,
            .font = style.mono(),
            .color_text = .{ .color = style.textMuted() },
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = .{ .x = 1, .y = 1, .w = 1, .h = 2 },
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs },
            .padding = .{ .x = style.space.sm, .y = 1, .w = style.space.sm, .h = 1 },
        });
    }
}
