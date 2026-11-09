const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const pr = @import("../github/pr.zig");
const github = @import("../github/github.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const search_view = @import("search_view.zig");
const rebase_view = @import("rebase_view.zig");
const commit_view = @import("commit_view.zig");
const identity_view = @import("identity_view.zig");
const repo_settings = @import("repo_settings.zig");
const repo_io = @import("../core/repo_io.zig");
const app = @import("../main.zig");

// === Folder picker ===

/// What the folder being picked is for.
const FolderFor = enum { open_repo, parent };
var folder_for: FolderFor = .open_repo;
/// SDL's answer, written by its callback — on another thread, for all SDL
/// promises — and taken by the next frame: 1 when `folder_buf` holds a path.
var folder_ready: std.atomic.Value(u8) = .init(0);
var folder_buf: [std.fs.max_path_bytes]u8 = undefined;
var folder_len: usize = 0;
var folder_window: ?*dvui.Window = null;

/// The desktop's own folder dialog, through SDL: the portal on Linux — KDE's
/// or GNOME's dialog, whichever the desktop is — and the shell's on Windows.
/// It does not block; the answer arrives with `takeFolder`.
pub fn pickFolder(what: FolderFor, title: [:0]const u8, start: ?[]const u8) void {
    const sdl = dvui.backend.c;
    folder_for = what;
    folder_window = dvui.currentWindow();

    const props = sdl.SDL_CreateProperties();
    defer sdl.SDL_DestroyProperties(props);
    _ = sdl.SDL_SetStringProperty(props, sdl.SDL_PROP_FILE_DIALOG_TITLE_STRING, title.ptr);
    var start_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (start) |dir| {
        if (std.fmt.bufPrintSentinel(&start_buf, "{s}", .{dir}, 0)) |z| {
            _ = sdl.SDL_SetStringProperty(props, sdl.SDL_PROP_FILE_DIALOG_LOCATION_STRING, z.ptr);
        } else |_| {}
    }
    if (sdl.SDL_GetKeyboardFocus()) |win| _ = sdl.SDL_SetPointerProperty(props, sdl.SDL_PROP_FILE_DIALOG_WINDOW_POINTER, win);
    sdl.SDL_ShowFileDialogWithProperties(sdl.SDL_FILEDIALOG_OPENFOLDER, folderPicked, null, props);
}

fn folderPicked(_: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    // Null is an error, an empty list a cancel.
    if (list == null or list[0] == null) return;
    const path = std.mem.sliceTo(list[0], 0);
    if (path.len > folder_buf.len) return;
    @memcpy(folder_buf[0..path.len], path);
    folder_len = path.len;
    folder_ready.store(1, .release);
    dvui.refresh(folder_window, @src(), null);
}

/// Act on a folder the picker handed back since the last frame.
pub fn takeFolder() void {
    if (folder_ready.load(.acquire) != 1) return;
    folder_ready.store(0, .release);
    const path = folder_buf[0..folder_len];
    switch (folder_for) {
        .open_repo => tab_strip.openAndRemember(path),
        .parent => {
            dialog_parent.clearRetainingCapacity();
            dialog_parent.appendSlice(app.gpa, path) catch {};
        },
    }
}

pub var watcher_failure_logged = false;

pub fn closeRepo() void {
    app.stopWatching();
    watcher_failure_logged = false;
    // The picks were in this repository's file: nothing to take back in the
    // next one's.
    app.clearResolveUndo();
    app.conflict_path.clearRetainingCapacity();
    // A status read still out is not waited for — on a large tree, or on
    // Windows, that is the tab switch frozen. `collectWorkLoad` throws its
    // result away for being another repository's, and frees it.
    repo_io.releaseStatusCache();
    if (app.repo) |*r| r.deinit();
    app.repo = null;
    if (app.history) |*h| h.deinit();
    app.history = null;
    if (app.lanes) |*l| l.deinit();
    app.lanes = null;
    if (app.work) |*w| w.deinit();
    app.work = null;
    commit_view.work_version +%= 1;
    repo_io.work_settling = false;

    app.repo_path.clearAndFree(app.gpa);
    app.repo_name = "";
    tab_strip.uses_lfs = false;
    tab_strip.open_error = "No repository open. Use + in the tab bar to open one.";
    app.clearConfirm();
    app.clearPrompt();
    app.clearSelection();
    graph_view.clearFileHistory();
    // What belonged to the repository that was open: its pull request, the
    // commits its `path:`/`code:` search found, the order its list sorted to.
    app.pr_selected = null;
    pr.clearDetail();
    search_view.clearSearchHits();
    // Left ticked, the next repository's commit would rewrite its own HEAD.
    app.amend = false;
    // Its authors are not the next one's.
    graph_view.clearNames(&graph_view.author_only);
    // Its pull requests belong to it.
    app.active_view = .graph;
    // A drop menu's merge or rebase names this repository's branches.
    graph_view.clearDrop();
    graph_view.drag_source.clearRetainingCapacity();
}

// === Clone and create ===
//
// A window of their own, as in every other client: three things to fill in,
// a folder picker beside the one that is a folder, and the path it will all
// add up to shown before anything is written.

pub const RepoDialog = enum { none, clone, create };

pub var repo_dialog: RepoDialog = .none;
var dialog_rect: dvui.Rect = .{};
pub var dialog_url: std.ArrayList(u8) = .empty;
pub var dialog_parent: std.ArrayList(u8) = .empty;
pub var dialog_name: std.ArrayList(u8) = .empty;
pub var dialog_branch: std.ArrayList(u8) = .empty;
/// Once the name is typed into, the URL stops overwriting it.
var dialog_name_edited: bool = false;
pub var dialog_readme: bool = true;

pub fn openRepoDialog(kind: RepoDialog) void {
    repo_dialog = kind;
    dialog_rect = .{};
    dialog_url.clearRetainingCapacity();
    dialog_name.clearRetainingCapacity();
    dialog_name_edited = false;
    dialog_branch.clearRetainingCapacity();
    dialog_branch.appendSlice(app.gpa, if (tab_strip.default_branch.items.len > 0) tab_strip.default_branch.items else "main") catch {};
    dialog_readme = true;

    // Beside the repository that is open, else in the home folder: where the
    // next one usually goes.
    dialog_parent.clearRetainingCapacity();
    if (app.repo_path.items.len > 1) {
        const trimmed = std.mem.trimEnd(u8, app.repo_path.items, "/");
        dialog_parent.appendSlice(app.gpa, std.fs.path.dirname(trimmed) orelse trimmed) catch {};
    } else if (app.homeDir()) |home| {
        dialog_parent.appendSlice(app.gpa, home) catch {};
    }
}

/// "https://host/owner/zync.git" -> "zync". What git itself would name it.
/// A Windows path, `C:\src\zync`, cuts at its backslashes too.
pub fn nameFromUrl(url: []const u8) []const u8 {
    var u = std.mem.trimEnd(u8, std.mem.trim(u8, url, " "), "/\\");
    if (std.mem.endsWith(u8, u, ".git")) u = u[0 .. u.len - 4];
    const cut = std.mem.lastIndexOfAny(u8, u, "/\\:") orelse return u;
    return u[cut + 1 ..];
}

/// Parent and name, joined, `~` expanded.
fn dialogPath(buf: []u8) ?[]const u8 {
    const name = std.mem.trim(u8, dialog_name.items, " ");
    const parent = std.mem.trimEnd(u8, std.mem.trim(u8, dialog_parent.items, " "), "/");
    if (name.len == 0 or parent.len == 0) return null;
    var joined_buf: [std.fs.max_path_bytes]u8 = undefined;
    const joined = std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{ parent, name }) catch return null;
    const out = app.expandHome(buf, joined);
    if (out.ptr == joined.ptr) {
        if (out.len > buf.len) return null;
        @memcpy(buf[0..out.len], out);
        return buf[0..out.len];
    }
    return out;
}

pub fn dialogReady() bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dialogPath(&buf) == null) return false;
    return repo_dialog != .clone or std.mem.trim(u8, dialog_url.items, " ").len > 0;
}

pub fn browseParent() void {
    pickFolder(.parent, "Where to put it", if (dialog_parent.items.len > 0) dialog_parent.items else null);
}

/// A README and the commit holding it, in the repository just made at `path`.
/// What goes wrong is said; an identity git does not have yet is the usual.
fn firstCommit(path: []const u8) void {
    var readme_buf: [std.fs.max_path_bytes]u8 = undefined;
    const readme = std.fmt.bufPrint(&readme_buf, "{s}/README.md", .{path}) catch return;
    var text_buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "# {s}\n", .{std.mem.trim(u8, dialog_name.items, " ")}) catch "# README\n";
    std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = readme, .data = text }) catch
        return app.setCommandError("Could not write README.md.");
    for ([_][]const []const u8{ &.{ "add", "README.md" }, &.{ "commit", "-q", "-m", "Initial commit" } }) |args| {
        var step = run.git(app.gpa, app.app_io, path, args) catch return app.setCommandError("Could not run git. Is it on your PATH?");
        defer step.deinit(app.gpa);
        if (!step.ok) return app.setCommandError(if (step.message.len > 0) step.message else "The first commit failed.");
    }
}

pub fn submitRepoDialog() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = dialogPath(&buf) orelse return;

    switch (repo_dialog) {
        .none => return,
        .clone => {
            const url = std.mem.trim(u8, dialog_url.items, " ");
            if (url.len == 0) return;
            app.startClone(url, path);
            if (tab_strip.job == null) return;
        },
        .create => {
            // `git init` in a folder that has things in it adopts them, and the
            // README and first commit below would then land on top of them.
            if (std.Io.Dir.cwd().openDir(app.app_io, path, .{ .iterate = true })) |existing| {
                var d = existing;
                defer d.close(app.app_io);
                var it = d.iterate();
                if ((it.next(app.app_io) catch null) != null) return app.setCommandError("That folder already exists and is not empty. Pick another name.");
            } else |err| if (err == error.NotDir) return app.setCommandError("A file already has that name. Pick another one.");
            const branch = std.mem.trim(u8, dialog_branch.items, " ");
            var outcome = run.git(app.gpa, app.app_io, ".", &.{ "init", "-b", if (branch.len > 0) branch else "main", "--", path }) catch {
                return app.setCommandError("Could not run git. Is it on your PATH?");
            };
            defer outcome.deinit(app.gpa);
            if (!outcome.ok) return app.setCommandError(if (outcome.message.len > 0) outcome.message else "git init failed.");
            app.clearCommandError();

            // Opened whatever happens to the README: the repository is there
            // regardless, and left unopened a second try is refused as a
            // folder that is not empty.
            if (dialog_readme) firstCommit(path);
            tab_strip.openAndRemember(path);
        },
    }
    repo_dialog = .none;
}

pub fn repoDialog() void {
    if (repo_dialog == .none) return;
    const cloning = repo_dialog == .clone;

    const win = dvui.windowRect();

    var open = true;
    var fw = modalWindow(@src(), &dialog_rect, &open, style.surface(), 520, dvui.Rect.all(0));
    defer fw.deinit();
    centerModal(fw.data(), win, null);

    identity_view.dialogHeader(@src(), if (cloning) dvui.entypo.download else dvui.entypo.plus, if (cloning) "Clone a repository" else "Start a new repository", if (cloning) "Copy one from GitHub, GitLab or any git server onto this computer" else "An empty repository, in a folder of its own", &open);

    var body = identity_view.dialogBody(@src(), null);

    var entered = false;
    if (cloning) {
        const changed = dialogField(@src(), 0, "Repository URL", &dialog_url, "https://github.com/owner/repo.git", true, &entered);
        if (changed and !dialog_name_edited) {
            dialog_name.clearRetainingCapacity();
            dialog_name.appendSlice(app.gpa, nameFromUrl(dialog_url.items)) catch {};
        }
    }

    {
        dialogLabel(@src(), if (cloning) "Where to clone it to" else "Where to create it");
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer row.deinit();
        _ = dialogInput(@src(), 1, &dialog_parent, "/home/you/dev", false, &entered);
        if (dialogButton(@src(), "Browse…", false)) repo_io.requestAction(.browse_parent);
    }

    if (dialogField(@src(), 2, if (cloning) "Folder name" else "Name", &dialog_name, if (cloning) "repo" else "my-project", !cloning, &entered)) {
        dialog_name_edited = true;
    }

    if (!cloning) {
        _ = dialogField(@src(), 3, "Default branch", &dialog_branch, "main", false, &entered);
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer row.deinit();
        if (repo_settings.toggle(@src(), dialog_readme)) dialog_readme = !dialog_readme;
        dvui.label(@src(), "Add a README and make the first commit", .{}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textMuted() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }

    // What all of it adds up to, before anything is written.
    {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = dialogPath(&path_buf);
        var preview = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .corners = style.radius.input,
            .padding = dvui.Rect.all(style.space.md),
            .margin = .{ .h = style.space.lg },
        });
        defer preview.deinit();
        dvui.icon(@src(), "path_icon", dvui.entypo.folder, .{ .fill_color = .{ .color = style.textFaint() } }, .{
            .min_size_content = .{ .w = 13, .h = 13 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
        });
        dvui.label(@src(), "{s}", .{full orelse "Fill in the fields above"}, .{
            .font = style.mono(),
            .color_text = .{ .color = if (full != null) style.text() else style.textFaint() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
    }

    body.deinit();
    {
        var foot = identity_view.dialogFooter(@src());
        defer foot.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialogButton(@src(), "Cancel", false)) open = false;
        const ready = dialogReady();
        if ((dialogButton(@src(), if (cloning) "Clone" else "Create repository", true) or entered) and ready) {
            repo_io.requestAction(.repo_dialog);
        }
    }

    if (escapePressed()) open = false;
    if (!open) repo_dialog = .none;
}

pub fn dialogLabel(src: std.builtin.SourceLocation, caption: []const u8) void {
    dvui.label(src, "{s}", .{caption}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = style.textMuted() },
        .margin = .{ .h = style.space.xs },
        .padding = dvui.Rect.all(0),
    });
}

/// A labelled field. True when its text changed this frame.
pub fn dialogField(src: std.builtin.SourceLocation, id: usize, caption: []const u8, text: *std.ArrayList(u8), placeholder: []const u8, focus: bool, entered: *bool) bool {
    var col = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
        .margin = .{ .h = style.space.lg },
    });
    defer col.deinit();
    dialogLabel(@src(), caption);
    return dialogInput(@src(), id, text, placeholder, focus, entered);
}

fn dialogInput(src: std.builtin.SourceLocation, id: usize, text: *std.ArrayList(u8), placeholder: []const u8, focus: bool, entered: *bool) bool {
    const te = textField(src, .{
        .text = .{ .array_list = .{ .backing = text, .allocator = app.gpa, .limit = 1024 } },
        .placeholder = placeholder,
    }, .{
        .id_extra = id,
        .expand = .horizontal,
        .font = style.body(),
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .padding = .{ .x = style.space.md + 2, .y = style.space.md, .w = style.space.md + 2, .h = style.space.md },
    });
    const changed = te.text_changed;
    if (te.enter_pressed) entered.* = true;
    const field_id = te.data().id;
    // Pre-filled (a folder, a name from GitHub): the cursor after it.
    if (dvui.firstFrame(field_id)) te.textLayout.selection.moveCursor(text.items.len, false);
    te.deinit();
    if (focus) focusOnce(field_id);
    return changed;
}

/// A dialog's button: filled in the accent for the one it is for, outlined
/// for the rest.
pub fn dialogButton(src: std.builtin.SourceLocation, caption: []const u8, primary: bool) bool {
    return dialogButtonTagged(src, caption, primary, frameTag("dialog", caption));
}

pub fn dialogButtonTagged(src: std.builtin.SourceLocation, caption: []const u8, primary: bool, tag: ?[]const u8) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = tag,
        .background = true,
        // The one that answers filled in the accent; the others framed on
        // the dialog's own ground.
        .color_fill = .{ .color = if (primary) style.accent() else dvui.Color.transparent },
        .color_fill_hover = .{ .color = if (primary) style.accent().lerp(style.text(), 0.15) else style.rowHover() },
        .border = dvui.Rect.all(if (primary) 0 else 1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm },
        .padding = .{ .x = style.space.lg, .y = style.space.md, .w = style.space.lg, .h = style.space.md },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    dvui.label(@src(), "{s}", .{caption}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = if (primary) style.background() else style.text() },
        .padding = dvui.Rect.all(0),
    });
    return bw.clicked();
}

/// Keep a modal centred on the window, from the size it actually is.
///
/// The size is left entirely to `autoSize`: centring on a fixed width spills
/// a wider window off the right.
/// `top` pins it that far down instead of centring it vertically.
///
/// After the window's `init`, which is when it takes its size, and before
/// anything is laid out inside it — so even the first frame it has a size is
/// drawn where it belongs.
///
/// Once dragged — it is no longer where it was last put — it stays where the
/// user left it, until it is opened again (its rect back to zero).
pub fn centerModal(wd: *dvui.WidgetData, win: dvui.Rect.Natural, top: ?f32) void {
    const fresh = wd.rect.x == 0 and wd.rect.y == 0;
    if (fresh) dvui.dataRemove(null, wd.id, "_zit_moved");
    if (dvui.dataGet(null, wd.id, "_zit_moved", bool) != null) return;
    if (dvui.dataGet(null, wd.id, "_zit_placed", dvui.Point)) |p| if (!fresh and (p.x != wd.rect.x or p.y != wd.rect.y)) {
        dvui.dataSet(null, wd.id, "_zit_moved", true);
        return;
    };
    wd.rect.x = @max(0, (win.w - wd.rect.w) / 2);
    wd.rect.y = top orelse @max(40, (win.h - wd.rect.h) / 2);
    dvui.dataSet(null, wd.id, "_zit_placed", dvui.Point{ .x = wd.rect.x, .y = wd.rect.y });
}

// === Alerts ===
//
// One shape for every alert, whatever it says: a ground tinted with its
// colour, framed in it, its icon and its words in it, and the thing to do
// about it on the right — a button framed in the same colour.

/// The alert's frame, its icon already in: what it says and the button
/// after go in it, then `deinit`.
pub fn alertBox(src: std.builtin.SourceLocation, id: usize, hue: dvui.Color, icon: []const u8, margin: dvui.Rect) *dvui.BoxWidget {
    const box = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.tint(hue) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = alertEdge(hue) },
        .corners = style.radius.input,
        .margin = margin,
        .padding = .{ .x = style.space.lg, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
        .min_size_content = .{ .h = 36 },
    });
    dvui.icon(@src(), "alert_icon", icon, .{ .fill_color = .{ .color = hue } }, .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.md },
    });
    return box;
}

/// The alert's frame and its button's: its colour, halfway to the ground.
pub fn alertEdge(hue: dvui.Color) dvui.Color {
    return hue.lerp(style.surface(), 0.45);
}

/// What the alert says, in its colour, wrapped to what is left of the line.
pub fn alertText(src: std.builtin.SourceLocation, text: []const u8, hue: dvui.Color) void {
    var tl = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .max_size_content = .width(0), .background = false, .padding = dvui.Rect.all(0) });
    tl.addText(text, .{ .font = style.smallBold(), .color_text = .{ .color = hue } });
    tl.deinit();
}

/// The thing to do about an alert: framed in its colour, its caption in it.
pub fn alertButton(src: std.builtin.SourceLocation, caption: []const u8, hue: dvui.Color, tag: ?[]const u8) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = tag,
        .background = true,
        .color_fill = .{ .color = dvui.Color.transparent },
        .color_fill_hover = .{ .color = style.tint(hue).lerp(hue, 0.12) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = alertEdge(hue) },
        .corners = style.radius.input,
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm },
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    dvui.label(@src(), "{s}", .{caption}, .{ .font = style.smallBold(), .color_text = .{ .color = hue }, .padding = dvui.Rect.all(0) });
    return bw.clicked();
}

/// What a force push replaces, in commits: after a rebase the upstream's go
/// and the branch's own take their place.
pub fn forcePushText(buf: []u8) []const u8 {
    const plain = "Overwrite the remote branch with yours? Refused if it moved since your last fetch.";
    const h = app.history orelse return plain;
    const t = h.tracking;
    const upstream = t.upstream orelse return plain;
    if (t.behind == 0) return plain;
    return std.fmt.bufPrint(buf, "Replace {s} with your branch? Its {d} commit{s} there give way to your {d}. Refused if it moved since your last fetch.", .{ upstream, t.behind, window_chrome.plural(t.behind), t.ahead }) catch plain;
}

/// "Abort the rebase? …": what an abort puts back, and what it loses.
pub fn abortText(buf: []u8) []const u8 {
    const h = app.history orelse return "Abort?";
    const what: []const u8 = switch (h.state) {
        .merge => "the merge",
        .rebase => "the rebase",
        .cherrypick => "the cherry-pick",
        .revert => "the revert",
        else => "it",
    };
    return std.fmt.bufPrint(buf, "Abort {s}? The branch goes back to where it was before, and the conflicts resolved so far are lost.", .{what}) catch "Abort?";
}

/// The one-field dialog for the handful of commands that need a name first:
/// a branch, a tag, a remote, a stash, a worktree. Enter does it; Esc,
/// Cancel or the × let it be.
pub fn promptDialog() void {
    const p = app.prompt orelse {
        prompt_rect = .{};
        return;
    };
    // Before it is drawn: taken after, the frame would still show it, and no
    // key or click brings the next one.
    if (escapePressed()) return app.clearPrompt();
    var open = true;
    const win = dvui.windowRect();
    var fw = modalWindow(@src(), &prompt_rect, &open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    centerModal(fw.data(), win, null);
    var hint_buf: [160]u8 = undefined;
    identity_view.dialogHeader(@src(), app.Prompt.icon(p.kind), app.Prompt.caption(p.kind), app.Prompt.hint(p.kind, p.arg, &hint_buf), &open);

    var body = identity_view.dialogBody(@src(), PROMPT_W);
    var entered = false;
    _ = dialogField(@src(), 0, app.Prompt.label(p.kind), &app.prompt_text, app.Prompt.placeholder(p.kind), true, &entered);
    body.deinit();
    {
        var line = identity_view.dialogFooter(@src());
        defer line.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialogButton(@src(), "Cancel", false)) open = false;
        if (dialogButtonTagged(@src(), app.Prompt.verb(p.kind), true, "prompt:go")) entered = true;
    }
    if (entered) repo_io.requestAction(.prompt) else if (!open) app.clearPrompt();
    // Gone, or answered: the frame that no longer shows it.
    if (entered or !open) dvui.refresh(null, @src(), null);
}

var prompt_rect: dvui.Rect = .{};
const PROMPT_W: f32 = 420;

pub fn conflictCount() usize {
    const w = app.work orelse return 0;
    var n: usize = 0;
    for (w.unstaged) |change| {
        if (change.status == .conflicted) n += 1;
    }
    return n;
}

/// The branches the graph draws, from the icon at the head of its column:
/// every one, or those ticked, as many as wanted — and whether the remote
/// ones count. A filter at the top, for a repository with a hundred.
pub fn graphBranchMenu(src: std.builtin.SourceLocation) void {
    const picked = graph_view.graph_only.items.len;

    const button = window_chrome.DropButton.begin(src, .{
        .tag = "branch_selector",
        .gravity_y = 0.5,
        // Lit while it narrows the graph: branches picked, or First-parent.
        .background = picked > 0 or graph_view.graph_first_parent,
        .color_fill = .{ .color = style.accentDim() },
        .margin = .{ .w = style.space.xs },
        .padding = .{ .x = 3, .y = 2, .w = 3, .h = 2 },
        .corners = style.radius.input,
    });
    {
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        defer face.deinit();
        dvui.icon(@src(), "branches", if (graph_view.graph_first_parent) dvui.entypo.flow_line else dvui.entypo.flow_branch, .{ .fill_color = .{ .color = if (picked > 0 or graph_view.graph_first_parent) style.accent() else style.textMuted() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
        });
        if (picked > 0) dvui.label(@src(), "{d}", .{picked}, .{ .font = style.tinyBold(), .color_text = .{ .color = style.accent() }, .gravity_y = 0.5, .margin = .{ .x = 2 }, .padding = dvui.Rect.all(0) });
        dvui.icon(@src(), "drop_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textFaint() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs },
        });
    }

    var flip_remote = false;
    var all = false;
    var mode: ?bool = null;
    // Copied before the history it names can be read again.
    var toggled: ?[]const u8 = null;
    const menu = button.open();
    if (menu) |m| {
        focusOnce(searchField(@src(), &branch_filter, "Filter branches…", "branch_filter", .{ .x = style.space.xs, .y = style.space.xs, .w = style.space.xs, .h = style.space.sm }));

        dropHeading(@src(), 1, "HISTORY");
        if (graph_view.menuIcon(@src(), if (!graph_view.graph_first_parent) dvui.entypo.check else dvui.entypo.flow_tree, "All branches", false)) {
            mode = false;
            m.close();
        }
        if (graph_view.menuIcon(@src(), if (graph_view.graph_first_parent) dvui.entypo.check else dvui.entypo.flow_line, "First-parent", false)) {
            mode = true;
            m.close();
        }
        dropHeading(@src(), 2, "BRANCHES");
        var remote = graph_view.graph_show_remote;
        if (dvui.checkbox(@src(), &remote, "Remote branches", .{ .font = style.small(), .margin = .{ .x = style.space.sm, .y = 2, .h = 2 } })) flip_remote = true;
        if (graph_view.menuIcon(@src(), if (picked == 0) dvui.entypo.check else dvui.entypo.flow_tree, "Every branch shown", false)) {
            all = true;
            m.close();
        }

        const needle = std.mem.trim(u8, branch_filter.items, " ");
        // A fixed size, the list scrolling inside it: a hundred branches
        // made a menu the height of the screen.
        var list = dvui.scrollArea(@src(), .{}, .{
            .min_size_content = .{ .w = 300, .h = 320 },
            .max_size_content = .size(.{ .w = 300, .h = 320 }),
            .background = false,
        });
        defer list.deinit();
        if (app.history) |h| {
            var shown: usize = 0;
            for ([_]git.Ref.Kind{ .local, .remote }, 0..) |kind, k| {
                var header = false;
                for (h.refs, 0..) |ref, i| {
                    if (ref.kind != kind) continue;
                    if (kind == .remote and !graph_view.graph_show_remote) continue;
                    if (needle.len > 0 and std.ascii.findIgnoreCase(ref.name, needle) == null) continue;
                    // Past this many the filter is the way through, and a
                    // menu taller than the screen is no use to anybody.
                    if (shown >= MAX_BRANCH_CHOICES) break;
                    if (!header) {
                        dropHeading(@src(), k + 10, if (kind == .local) "LOCAL" else "REMOTE");
                        header = true;
                    }
                    var on = graph_view.hasName(graph_view.graph_only.items, ref.name);
                    // Ticked one by one with the menu left open: picking
                    // several is the point.
                    if (dvui.checkbox(@src(), &on, ref.name, .{ .id_extra = i, .font = style.small(), .margin = .{ .x = style.space.sm, .y = 1, .h = 1 } })) toggled = ref.name;
                    shown += 1;
                }
            }
            if (shown == 0 and needle.len > 0) dropHeading(@src(), 20, "NO BRANCH BY THAT NAME");
        }
    } else branch_filter.clearRetainingCapacity();
    button.end(menu);

    if (toggled) |name| graph_view.toggleOnly(name);
    if (all) graph_view.setSolo(null);
    if (mode) |first_parent| if (first_parent != graph_view.graph_first_parent) {
        graph_view.graph_first_parent = first_parent;
        tab_strip.saveWorkspace();
        graph_view.graphFilterChanged();
    };
    if (flip_remote) {
        graph_view.graph_show_remote = !graph_view.graph_show_remote;
        tab_strip.saveWorkspace();
        graph_view.graphFilterChanged();
    }
}

/// What the branch menu is narrowed to, and how many it shows at most.
pub var branch_filter: std.ArrayList(u8) = .empty;
pub const MAX_BRANCH_CHOICES = 60;

/// A section title inside a dropdown — not a choice, just a label.
pub fn dropHeading(src: std.builtin.SourceLocation, id: usize, caption: []const u8) void {
    dvui.label(src, "{s}", .{caption}, .{
        .id_extra = id,
        .font = style.section(),
        .color_text = .{ .color = style.textFaint() },
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.xxs },
    });
}

/// One dropdown entry: an icon, its text in the small size, and a faint hint
/// on the right — a shortcut, or what choosing it does.
pub fn dropChoice(dd: *dvui.DropdownWidget, icon: []const u8, text: []const u8, hint: []const u8) bool {
    var mi = dd.addChoice();
    defer mi.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer row.deinit();
    dvui.icon(@src(), "choice_icon", icon, .{ .fill_color = .{ .color = style.textMuted() } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    dvui.label(@src(), "{s}", .{text}, .{
        .font = style.small(),
        .color_text = .{ .color = style.text() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(420),
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

    if (mi.activeRect()) |_| {
        dd.close();
        return true;
    }
    return false;
}

/// What a toolbar button is, beyond its caption and icon.
const Tool = struct {
    /// How many commits Pull or Push would move, beside the caption when
    /// not zero; the button is then lit in the accent, as what to do next.
    badge: usize = 0,
    /// Findable by this, whatever its caption says. Null: "toolbar:" and
    /// the caption.
    tag: ?[]const u8 = null,
    /// Lit in the accent: a view it shows.
    on: bool = false,
    /// Faded and deaf unless so; its hint then says why.
    usable: bool = true,
    /// On hover, what it would do — and its keys. Null: its caption.
    hint: ?[]const u8 = null,
    /// The icon alone, whatever the bar's width: its hint names it.
    icon_only: bool = false,
    /// Its command is running: a spinner for the icon, and deaf meanwhile.
    busy: bool = false,
};

/// The icon alone; the caption is its hint, on hover.
pub fn toolButton(src: std.builtin.SourceLocation, caption: []const u8, icon: []const u8, t: Tool) bool {
    const enabled = app.repo != null and t.usable and !t.busy;
    const bare = true;

    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = t.tag orelse frameTag("toolbar", caption),
        .min_size_content = .{ .w = if (bare) window_chrome.TOOL_H else 0, .h = window_chrome.TOOL_H },
        .gravity_y = 0.5,
        .background = false,
        .margin = .{ .x = 2, .w = 2 },
        .padding = dvui.Rect.all(0),
        .corners = style.radius.input,
    });
    defer bw.deinit();
    bw.processEvents();

    const hovered = enabled and bw.hovered();
    const loud = enabled and t.badge > 0;
    const color = if (!enabled and !t.busy) style.textFaint() else if (t.on or loud or t.busy) style.accent() else if (hovered) style.text() else style.textMuted();
    // Every button says on hover what it would do, or why it cannot.
    if (bw.hovered()) dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r, .position = .vertical, .delay = 400_000 }, "{s}", .{t.hint orelse caption}, .{ .font = style.small() });

    {
        var cell = dvui.box(@src(), .{ .dir = if (bare) .vertical else .horizontal }, .{
            .expand = .both,
            .background = hovered or t.on,
            .color_fill = .{ .color = if (t.on) style.accentDim() else style.rowHover() },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.md, .y = 5, .w = style.space.md, .h = 5 },
        });
        defer cell.deinit();

        // Running, a spinner: in place of the icon, or before the caption.
        if (t.busy) dvui.spinner(@src(), .{
            .min_size_content = .{ .w = if (bare) 17 else 13, .h = if (bare) 17 else 13 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .margin = .{ .w = if (bare) 0 else style.space.xs },
            .color_text = .{ .color = color },
        }) else if (bare) dvui.icon(@src(), caption, icon, .{ .fill_color = .{ .color = color } }, .{
            .min_size_content = .{ .w = 17, .h = 17 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });

        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .background = false,
            .padding = dvui.Rect.all(0),
        });
        defer line.deinit();

        if (!bare) dvui.label(@src(), "{s}", .{caption}, .{
            .font = if (loud) style.smallBold() else style.small(),
            .color_text = .{ .color = color },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
        });

        if (loud) {
            dvui.label(@src(), "{d}", .{t.badge}, .{
                .font = style.tinyBold(),
                .color_text = .{ .color = style.background() },
                .background = true,
                .color_fill = .{ .color = style.accent() },
                .corners = style.radius.tag,
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.xs },
                .padding = .{ .x = style.space.xs, .w = style.space.xs },
            });
        }
    }

    return enabled and bw.clicked();
}

/// Square icon-only button, for chrome where a caption would be noise.
///
/// `hint` is what the icon means, in words: an icon on its own is a guess
/// until you have clicked it once, and some of these are not undoable.
pub fn iconButton(src: std.builtin.SourceLocation, name: []const u8, hint: []const u8, icon: []const u8, color: dvui.Color) bool {
    return iconButtonTagged(src, name, hint, icon, color, null);
}

/// As `iconButton`, findable by `tag` — for one that appears once.
pub fn iconButtonTagged(src: std.builtin.SourceLocation, name: []const u8, hint: []const u8, icon: []const u8, color: dvui.Color, tag: ?[]const u8) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = tag,
        .min_size_content = .{ .w = 24, .h = 24 },
        .gravity_y = 0.5,
        .background = false,
        .margin = .{ .x = style.space.xxs, .w = style.space.xxs },
        .padding = dvui.Rect.all(0),
        .corners = style.radius.input,
    });
    defer bw.deinit();
    bw.processEvents();

    {
        var cell = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = bw.hovered(),
            .color_fill = .{ .color = style.rowHover() },
            .corners = style.radius.input,
        });
        defer cell.deinit();

        dvui.icon(@src(), name, icon, .{
            .fill_color = .{ .color = if (bw.hovered()) style.text() else color },
        }, .{
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
    }

    // Only the hovered button builds one, which is also what keeps two buttons
    // from claiming the same floating-widget id.
    if (bw.hovered()) {
        dvui.tooltip(@src(), .{
            .active_rect = bw.data().borderRectScale().r,
            .position = .vertical,
            .delay = 500_000,
        }, "{s}", .{hint}, .{ .font = style.small() });
    }

    return bw.clicked();
}

/// A menu row that opens a submenu beside it: the rect to hang it from,
/// while it is open.
pub fn menuSubRow(src: std.builtin.SourceLocation, icon: []const u8, caption: []const u8) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, .{ .submenu = true }, .{
        .tag = menuTag(caption),
        .expand = .horizontal,
        .corners = style.radius.input,
        .color_fill_hover = .{ .color = style.accentDim() },
        .padding = .{ .x = style.space.md, .y = graph_view.MENU_ROW_PAD_Y, .w = style.space.md, .h = graph_view.MENU_ROW_PAD_Y },
    });
    defer mi.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer row.deinit();
    dvui.icon(@src(), "menu_icon", icon, .{ .fill_color = .{ .color = style.textMuted() } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.md },
    });
    dvui.label(@src(), "{s}", .{caption}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    dvui.icon(@src(), "submenu", dvui.entypo.chevron_small_right, .{ .fill_color = .{ .color = style.textFaint() } }, .{
        .min_size_content = .{ .w = 11, .h = 11 },
        .gravity_y = 0.5,
    });
    return mi.activeRect();
}

/// A text entry with its caret visible and no ring. dvui draws both, while
/// the entry is made, in the theme's focus colour — transparent, so that
/// clicked buttons and checkboxes wear no ring. The caret borrows the accent
/// for the length of the call; the ring reads a copy of the theme where
/// focus stays clear.
pub fn textField(src: std.builtin.SourceLocation, init_opts: dvui.TextEntryWidget.InitOptions, opts: dvui.Options) *dvui.TextEntryWidget {
    const w = dvui.currentWindow();
    const S = struct {
        var ringless: dvui.Theme = undefined;
    };
    S.ringless = w.theme;
    S.ringless.focus = .transparent;
    var with = opts;
    with.theme = &S.ringless;
    // dvui sizes a single line from its own default font, whatever `.font`
    // says: a smaller one sits at the top of a field too tall for it. The
    // width is kept as dvui makes it; the height is the font's own line.
    if (!init_opts.multiline and opts.min_size_content == null) {
        const dvui_min = dvui.TextEntryWidget.defaults.min_sizeM(dvui.TextEntryWidget.defaultMWidth, 1).min_size_contentGet();
        with.min_size_content = .{ .w = dvui_min.w, .h = opts.fontGet().sizeM(1, 1).h };
    }
    w.theme.focus = style.accent();
    defer w.theme.focus = .transparent;
    return dvui.textEntry(src, init_opts, with);
}

/// Give a field the keyboard once, the frame after it first appears.
///
/// Not on its first frame: a floating window spends that one hidden while it
/// measures itself, and a focus asked for then is dropped. Remembered per
/// widget, so a click elsewhere is not undone the frame after.
pub fn focusOnce(id: dvui.Id) void {
    if (dvui.firstFrame(id)) return;
    if (dvui.dataGet(null, id, "_zit_focused", bool) != null) return;
    dvui.dataSet(null, id, "_zit_focused", true);
    dvui.focusWidget(id, null, null);
}

/// "menu:caption", once per frame: a menu still closing the frame another
/// opens would otherwise give two rows the same tag, which dvui reports —
/// in red, and in its log.
pub fn menuTag(caption: []const u8) ?[]const u8 {
    const S = struct {
        var frame: i128 = -1;
        var seen: std.ArrayList(u64) = .empty;
    };
    const now = dvui.frameTimeNS();
    if (now != S.frame) {
        S.frame = now;
        S.seen.clearRetainingCapacity();
    }
    const h = std.hash.Wyhash.hash(0, caption);
    if (std.mem.indexOfScalar(u64, S.seen.items, h) != null) return null;
    // Kept for the run, not from `gpa`: a few hashes a frame, reused.
    S.seen.append(std.heap.page_allocator, h) catch return null;
    return frameTag("menu", caption);
}

/// "prefix:name", allocated for this frame only: a tag a test can look a
/// widget up by, built from text the widget already shows.
pub fn frameTag(prefix: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}:{s}", .{ prefix, name }) catch null;
}

/// The one search box: a framed field with a magnifier at the end of it.
///
/// `tag` is what a shortcut focuses it by. The commits, the "Branches:" menu
/// and the sidebar each have one. Returns the text entry's id, for a caller
/// that focuses it.
pub fn searchField(
    src: std.builtin.SourceLocation,
    backing: *std.ArrayList(u8),
    placeholder: []const u8,
    tag: []const u8,
    margin: dvui.Rect,
) dvui.Id {
    return searchFieldIn(src, backing, placeholder, tag, margin, true);
}

/// As `searchField`, `framed` or not: unframed, it sits in a frame of the
/// caller's, with what else that holds beside it.
pub fn searchFieldIn(
    src: std.builtin.SourceLocation,
    backing: *std.ArrayList(u8),
    placeholder: []const u8,
    tag: []const u8,
    margin: dvui.Rect,
    framed: bool,
) dvui.Id {
    var field = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        // Centred on the line of an unframed one's frame; in a menu's column
        // a gravity would move it down the column.
        .gravity_y = if (framed) null else 0.5,
        .background = framed,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(if (framed) 1 else 0),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .margin = margin,
    });
    defer field.deinit();

    const te = textField(@src(), .{
        .text = .{ .array_list = .{ .backing = backing, .allocator = app.gpa, .limit = 256 } },
        .placeholder = placeholder,
    }, .{
        .tag = tag,
        .expand = .horizontal,
        .gravity_y = 0.5,
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
    if (te.enter_pressed) search_entered = id;
    te.deinit();

    dvui.icon(@src(), "search_icon", dvui.entypo.magnifying_glass, .{
        .fill_color = .{ .color = style.textFaint() },
    }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    return id;
}

/// A small framed button with an icon: for the actions a header offers,
/// where a bare link reads as text. `accent` marks the one that changes
/// something.
/// The search field Enter was last pressed in, for its caller to act on
/// and forget.
pub var search_entered: ?dvui.Id = null;

pub fn chipButton(src: std.builtin.SourceLocation, icon: []const u8, caption: []const u8, accent: bool) bool {
    return chipButtonTagged(src, icon, caption, accent, null);
}

/// As `chipButton`, findable by `tag`.
pub fn chipButtonTagged(src: std.builtin.SourceLocation, icon: []const u8, caption: []const u8, accent: bool, tag: ?[]const u8) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = tag,
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = if (accent) style.accentDim() else style.surfaceRaised() },
        .color_fill_hover = .{ .color = if (accent) style.accentDim() else style.rowHover() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = if (accent) style.accent().opacity(0.4) else style.border() },
        .corners = style.radius.input,
        .margin = .{ .x = style.space.sm },
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.lg, .h = style.space.sm },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();

    const color = if (accent) style.accent() else if (bw.hovered()) style.text() else style.textMuted();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
    defer row.deinit();
    dvui.icon(@src(), "chip_icon", icon, .{ .fill_color = .{ .color = color } }, .{
        .min_size_content = .{ .w = 11, .h = 11 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.xs },
    });
    dvui.label(@src(), "{s}", .{caption}, .{
        .font = style.small(),
        .color_text = .{ .color = color },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    return bw.clicked();
}

/// Small text button, for the "Stage all" / "Unstage all" kind of action.
pub fn linkButton(src: std.builtin.SourceLocation, caption: []const u8, color: dvui.Color) bool {
    return linkButtonTagged(src, caption, color, null);
}

/// As `linkButton`, findable by `tag` — for the ones that appear once, which
/// is not all of them: a hunk's buttons repeat down a diff.
pub fn linkButtonTagged(src: std.builtin.SourceLocation, caption: []const u8, color: dvui.Color, tag: ?[]const u8) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = tag,
        .gravity_y = 0.5,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.sm, .y = 2, .w = style.space.sm, .h = 2 },
        .corners = style.radius.input,
    });
    defer bw.deinit();
    bw.processEvents();

    {
        var cell = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = bw.hovered(),
            .color_fill = .{ .color = style.rowHover() },
            .corners = style.radius.input,
        });
        defer cell.deinit();

        dvui.label(@src(), "{s}", .{caption}, .{
            .font = style.small(),
            .color_text = .{ .color = if (bw.hovered()) style.text() else color },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }

    return bw.clicked();
}

// === Forgetting a repository ===

/// The path waiting for a yes, owned.
pub var forget_path: ?[]u8 = null;
var forget_rect: dvui.Rect = .{};

pub fn askForget(path: []const u8) void {
    if (forget_path) |p| app.gpa.free(p);
    forget_path = app.gpa.dupe(u8, path) catch null;
    forget_rect = .{};
}

pub fn clearForget() void {
    if (forget_path) |p| app.gpa.free(p);
    forget_path = null;
}

/// The frame every dialog shares: modal, sized to what it holds, a card on
/// the window. Its own close — a click outside — clears `open`.
pub fn modalWindow(
    src: std.builtin.SourceLocation,
    rect: *dvui.Rect,
    open: *bool,
    fill: dvui.Color,
    min_w: f32,
    padding: dvui.Rect,
) *dvui.FloatingWindowWidget {
    const fw = dvui.floatingWindow(src, .{
        .modal = true,
        .rect = rect,
        .open_flag = open,
        .resize = .none,
        .window_avoid = .none,
    }, .{
        .background = true,
        .color_fill = .{ .color = fill },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.popover,
        .min_size_content = .{ .w = min_w },
        .padding = padding,
    });
    fw.autoSize();
    return fw;
}

/// Whether Esc went down this frame with nothing else taking it — and takes
/// it, so the shortcuts after the frame do not close a second thing.
pub fn escapePressed() bool {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |ke| if (ke.action == .down and app.pressed(ke, .escape, false)) {
                e.handled = true;
                return true;
            },
            else => {},
        }
    }
    return false;
}

/// "Remove it?", as a modal, because it is about a whole repository — and
/// saying plainly that the folder stays is the point of asking.
pub fn forgetDialog() void {
    const path = forget_path orelse return;

    var open = true;
    const win = dvui.windowRect();
    var fw = modalWindow(@src(), &forget_rect, &open, style.surface(), 420, dvui.Rect.all(0));
    defer fw.deinit();
    centerModal(fw.data(), win, null);

    var title_buf: [160]u8 = undefined;
    identity_view.dialogHeader(@src(), dvui.entypo.trash, std.fmt.bufPrint(&title_buf, "Remove {s} from Zit?", .{git.repoName(path)}) catch "Remove it from Zit?", path, &open);

    var body = identity_view.dialogBody(@src(), null);
    // Two lines: a label does not wrap.
    for ([_][]const u8{ "It leaves the recent list and any tab it is open in.", "The folder and everything in it stay where they are." }, 0..) |line, i| {
        dvui.label(@src(), "{s}", .{line}, .{
            .id_extra = i,
            .font = style.small(),
            .color_text = .{ .color = style.textMuted() },
            .padding = dvui.Rect.all(0),
        });
    }
    body.deinit();

    var foot = identity_view.dialogFooter(@src());
    defer foot.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (dialogButton(@src(), "Cancel", false)) open = false;
    if (dialogButton(@src(), "Remove", true)) repo_io.requestAction(.forget);

    if (escapePressed()) open = false;
    if (!open) clearForget();
}

pub fn runForget() void {
    const path = forget_path orelse return;
    defer clearForget();
    tab_strip.forgetRepo(path);
}

/// Centred message for a pane with nothing in it yet.
pub fn emptyState(src: std.builtin.SourceLocation, message: []const u8) void {
    var area = dvui.box(src, .{}, .{ .expand = .both, .background = false });
    defer area.deinit();

    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5, .background = false });
    defer line.deinit();
    if (std.mem.startsWith(u8, message, "Loading")) rebase_view.loadingSpinner(@src());
    dvui.label(@src(), "{s}", .{message}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
    });
}

/// git's errors are often a paragraph; the toolbar has room for the headline.
pub fn firstLine(message: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
    return message[0..end];
}
