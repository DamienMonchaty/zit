//! Zit — a desktop git client.
//!
//! Reads go through libgit2 (`git.zig`), writes through the `git` binary
//! (`run.zig`), the graph's lanes are computed in `graph.zig`, and every visual
//! value lives in `style.zig`. What is left here is the UI.

const std = @import("std");
const dvui = @import("dvui");
const style = @import("ui/style.zig");
const git = @import("git/git.zig");
const graph = @import("git/graph.zig");
const run = @import("core/run.zig");
const store = @import("core/store.zig");
const avatars = @import("github/avatar.zig");
const pr = @import("github/pr.zig");
const syntax = @import("ui/syntax.zig");
const watch = @import("git/watch.zig");
const github = @import("github/github.zig");
const refs_panel = @import("ui/refs_panel.zig");
const tab_strip = @import("ui/tab_strip.zig");
const window_chrome = @import("ui/window_chrome.zig");
const graph_view = @import("ui/graph_view.zig");
const search_view = @import("ui/search_view.zig");
const diff_view = @import("ui/diff_view.zig");
const rebase_view = @import("ui/rebase_view.zig");
const commit_view = @import("ui/commit_view.zig");
const dialog_views = @import("ui/dialog_views.zig");

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = &startOptions },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};

/// Runs before SDL starts, which is the only time its app id can be set.
///
/// dvui's backend names every app "com.example.dvui.app". On Wayland that id
/// is what the desktop matches to a `.desktop` file for the taskbar icon,
/// so left alone Zit shows up as a generic window; `zit` matches
/// `zit.desktop`, and is the X11 class too.
fn startOptions() dvui.App.StartOptions {
    _ = dvui.backend.c.SDL_SetAppMetadata("Zit", APP_VERSION, "zit");
    // A click on the window while another one has focus acts as well as
    // focusing, instead of being spent on focus alone — what every desktop
    // app does, and what SDL turns off by default.
    _ = dvui.backend.c.SDL_SetHint(dvui.backend.c.SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
    // Warnings and errors only: dvui turns SDL's informational chatter on —
    // "Integrated memory detected, allocating TransferBuffers…" — which says
    // nothing a user can act on.
    dvui.backend.c.SDL_SetLogPriorities(dvui.backend.c.SDL_LOG_PRIORITY_WARN);
    // SDL's GPU renderer first on Linux, then its Vulkan one, then OpenGL:
    // OpenGL, the default, maps Mesa's gallium and LLVM into the process, about
    // twice the RSS of the other two. Tried in order, so a machine without
    // Vulkan still gets OpenGL.
    //
    // Direct3D 12 first on Windows, then 11, SDL's default, where there is no
    // 12. Measured on a 2,300-file repository (Intel Iris Xe): 11 is 30 MB
    // more private memory, 40 MB more commit and twice the wake-ups; Vulkan
    // and OpenGL are heavier still in working set, five times the wake-ups.
    if (@import("builtin").os.tag == .windows) {
        _ = dvui.backend.c.SDL_SetHint(dvui.backend.c.SDL_HINT_RENDER_DRIVER, "direct3d12,direct3d11,software");
    }
    if (@import("builtin").os.tag == .linux) {
        _ = dvui.backend.c.SDL_SetHint(dvui.backend.c.SDL_HINT_RENDER_DRIVER, "gpu,vulkan,opengl,software");

        // No libdecor on Wayland: SDL loads it for client-side window frames,
        // and its GTK plugin brings GTK, Pango, Cairo, GLib and — through
        // libxml2 — ICU and libstdc++ into the process, 24 MB of RSS for a
        // title bar. KDE, Sway, Hyprland and the rest draw the frame
        // themselves; GNOME alone does not, so there it stays.
        const desktop = if (std.c.getenv("XDG_CURRENT_DESKTOP")) |d| std.mem.span(d) else "";
        if (std.mem.indexOf(u8, desktop, "GNOME") == null) {
            _ = dvui.backend.c.SDL_SetHint(dvui.backend.c.SDL_HINT_VIDEO_WAYLAND_ALLOW_LIBDECOR, "0");
        }

        // One malloc arena, not one per thread: the history is read on a
        // thread of its own, and its arena kept the read's freed scratch
        // pinned between the live snapshot's pages — 6 MB that never went
        // back. The threads here take turns; a shared lock costs nothing.
        if (mallopt) |set| _ = set(M_ARENA_MAX, 1);
        // A fixed mmap threshold: glibc's moves up to whatever large block
        // was last freed — up to 32 MB — and the next ones come out of the
        // heap instead, where a free gives nothing back until a trim. Fixed,
        // a snapshot's arena pages or a big diff are their own mapping, and
        // their free is the system's at once.
        if (mallopt) |set| _ = set(M_MMAP_THRESHOLD, 128 * 1024);
    }
    return .{
        .size = .{ .w = 1320.0, .h = 840.0 },
        .min_size = .{ .w = 720.0, .h = 480.0 },
        .org = "zit",
        .app = "Zit",
        .title = "Zit",
        .icon = @embedFile("brand/zit-icon-256.png"),
        // Zit keeps its own window size and zoom, in its config.
        .persist_window_geometry = false,
        .window_init_options = .{},
        // Shown by `showWindowOnce` once the first frame is drawn: shown at
        // creation, Windows paints it white, with the renderer's black
        // rectangle in it, until Direct3D is up.
        .hidden = true,
        // No vsync: Zit draws when something changed, not every refresh of
        // the display, so waiting for the next one only adds up to 16 ms
        // between a key and what it does — and there is no animation to tear.
        .vsync = false,
    };
}

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
    // The same for Zit's own logs and dvui's: a terminal it was started from
    // hears about problems, not about every frame going well.
    .log_level = .warn,
    // The stack a segfault's trace is printed on: 256 KB of thread-local
    // storage by default, which glibc reserves and zeroes for every thread in
    // the process — SDL's and the GPU driver's too — about 2 MB in all. Kept
    // in Debug, where a trace can be printed; a release build is stripped
    // and could not print one anyway.
    .signal_stack_size = if (@import("builtin").mode == .debug) 1 << 18 else null,
};

/// From `build.zig.zon`, through `build.zig`; printed so that it is
/// zero-terminated, as SDL takes it and as a literal would be.
const APP_VERSION = std.fmt.comptimePrint("{s}", .{@import("build_options").version});

/// How often the working tree is re-read, so a file you changed in your editor
/// shows up without you asking.
///
/// ponytail: polling, not inotify. One `git_status_list` per interval is cheap
/// next to a frame; swap in a filesystem watcher if it ever shows up in a
/// profile on a big repository.
const POLL_INTERVAL_US: i32 = 700_000;
/// While another window has the keyboard: a `git status` is the one thing the
/// app spends CPU on when nobody is looking at it, and nobody is.
const POLL_INTERVAL_BACKGROUND_US: i32 = 3_000_000;
/// With the tree watched (`watch.zig`), the poll is only the net under the
/// watcher: a filesystem the kernel does not watch, a change it missed. The
/// status read it costs is ~4 ms, and draws nothing when nothing changed.
const WATCHED_POLL_US: i64 = 30 * std.time.us_per_s;

/// What tells Zit the open repository changed, where the system can.
var watcher: ?*watch.Watcher = null;
/// The window, for other threads to wake.
var app_window: ?*dvui.Window = null;
/// Set by the first wake since the frame began: the ones after it would only
/// queue more events for the same frame.
var wake_pending: std.atomic.Value(bool) = .init(false);

/// Ask for a frame from any thread — the watcher, a command or read that
/// finished (`run.wake`). One event however many ask before it is drawn.
pub fn wakeUi() void {
    if (wake_pending.swap(true, .acq_rel)) return;
    if (app_window) |w| dvui.refresh(w, @src(), null);
}

fn watching() bool {
    const w = watcher orelse return false;
    return !w.failed.load(.acquire);
}

fn startWatching(r: git.Repo) void {
    if (@import("builtin").is_test or !watch.supported) return;
    const workdir = r.workdir() orelse return;
    watcher = watch.Watcher.start(gpa, app_io, workdir, r.gitdir(), r.commondir(), wakeUi) catch |err| blk: {
        std.log.warn("not watching {s} ({s}): polling instead", .{ workdir, @errorName(err) });
        break :blk null;
    };
}

pub fn stopWatching() void {
    if (watcher) |w| w.stop();
    watcher = null;
}

/// How long until the next poll: the old interval where nothing watches the
/// tree; with a watcher, the slow net — but never past a fetch that is due.
fn pollInterval(focused: bool) i32 {
    if (!watching()) return if (focused) POLL_INTERVAL_US else POLL_INTERVAL_BACKGROUND_US;
    var us: i64 = WATCHED_POLL_US;
    if (tab_strip.auto_fetch_minutes > 0 and repo != null) {
        const due_s = tab_strip.last_auto_fetch_s + @as(i64, tab_strip.auto_fetch_minutes) * 60 - frame_now_s;
        us = @min(us, @max(1, due_s) * std.time.us_per_s);
    }
    return @intCast(us);
}
var was_focused: bool = true;

/// Whether the OS window has the keyboard. dvui does not pass focus changes
/// on, so this asks SDL.
fn windowFocused() bool {
    const sdl = dvui.backend.c;
    const flags = sdl.SDL_GetWindowFlags(dvui.currentWindow().backend.impl.window);
    return flags & sdl.SDL_WINDOW_INPUT_FOCUS != 0;
}

/// The allocator and Io zig's runtime hands the process. Set in `appInit`,
/// which runs before any frame.
pub var gpa: std.mem.Allocator = undefined;
pub var app_io: std.Io = undefined;

// === Repository state ===

pub var repo: ?git.Repo = null;
/// Absolute path of the working directory, owned.
pub var repo_path: std.ArrayList(u8) = .empty;
/// Repo directory name, a slice into `repo_path`.
pub var repo_name: []const u8 = "";

/// Refs and commits. Rebuilt when HEAD moves or after Zit writes.
pub var history: ?git.History = null;
/// Lanes and curves derived from `history.commits`.
pub var lanes: ?graph.Layout = null;
/// Staged and unstaged changes. Re-read on the poll timer.
pub var work: ?git.Work = null;

// === UI state ===

/// Where the three draggable seams sit. The sidebar takes what its branch
/// names need and no more: about 280px on a 1920px screen.
pub var sidebar_split: f32 = 0.15;
/// The commit list against the detail panel beside it: the list gets two
/// thirds, the columns need the room more than the panel does.
pub var detail_split: f32 = 0.68;
/// The two side panels, each hidden by a key (Ctrl+B, Ctrl+J) or from the
/// palette. Hiding leaves the ratio alone, so the
/// panel comes back the width it was.
var show_sidebar: bool = true;
pub var show_detail: bool = true;
/// What a hidden panel's seam points at instead: no room on that side. The
/// paned widget writes through it while dragging, so these are not consts.
var no_split: f32 = 0;
var all_split: f32 = 1;
/// The new-tab page — GitKraken's "open, clone or start a repository" —
/// over whatever is open, until a repository is picked or it is closed.
pub var new_tab_open: bool = false;
/// The pull requests: a tab of their own, always at the strip's right end
/// on a host that has them, showing when `active_view` is `.pulls`.
fn openPulls() void {
    new_tab_open = false;
    active_view = .pulls;
}

pub fn closePulls() void {
    active_view = .graph;
}
/// The two sides of the conflicts over the output they make.
pub var output_split: f32 = 0.6;

/// What the graph is searched for: a word in a message, an author, or the
/// start of a sha. Empty means the whole history, which is the usual case.
pub var commit_filter: std.ArrayList(u8) = .empty;
pub var commit_summary: std.ArrayList(u8) = .empty;
pub var commit_description: std.ArrayList(u8) = .empty;
pub var amend: bool = false;
/// The commit settings. `template` is unused here: the text lives in
/// `commit_template`, which the settings window edits in place.
pub var commit_prefs: store.CommitPrefs = .{};
pub var commit_template: std.ArrayList(u8) = .empty;
/// The conventional-commit type picked for this message, an index into
/// `COMMIT_TYPES`; null for none.
pub var commit_type: ?usize = null;
pub var commit_scope: std.ArrayList(u8) = .empty;
/// `Name <email>`, owned: whom this commit credits besides its author.
pub var co_authors: std.ArrayList([]u8) = .empty;
/// The next empty message should start from the template: set on opening a
/// repository and after each commit.
pub var template_due: bool = true;

pub var graph_scroll: dvui.ScrollInfo = .{ .vertical = .given };

/// Wall-clock seconds, read once at the top of each frame: `relativeTime` runs
/// per visible row and has no business making a syscall each time.
pub var frame_now_s: i64 = 0;

/// Last row clicked, and when, so a list can tell a double-click from two
/// single ones. dvui has no click count of its own.
pub var last_click_id: ?dvui.Id = null;
pub var last_click_ns: i128 = 0;
pub const DOUBLE_CLICK_NS: i128 = 400 * std.time.ns_per_ms;

pub const ChangesView = enum { path, tree };
pub var changes_view: ChangesView = .path;

/// Which compiled-in theme is on.
pub var dark_theme: bool = true;
/// The theme on, by its place in `style.themes`.
pub var theme_index: usize = 0;

/// A destructive action waiting for a yes.
///
/// Everything git cannot get back routes through here rather than firing on a
/// single click. It renders under the toolbar rather than beside the thing it
/// applies to, because three different panels raise it and one place to look is
/// worth more than proximity.
const Confirm = struct {
    kind: Kind,
    /// Path, stash commit or sha the action applies to. Empty where the kind needs
    /// no argument, which is what "discard everything" is.
    arg: []u8,

    const Kind = enum {
        discard,
        reset_hard,
        stash_drop,
        /// `arg` is the patch itself, which is what gets reversed out of the
        /// working tree.
        discard_hunk,
        force_push,
        /// `-D`: the branch has work nothing else points at.
        delete_branch_force,
        /// "origin/feat", as the sidebar names it.
        delete_remote_branch,
        delete_remote_tag,
        /// "<sha> <path>": the file as that commit had it, over the working copy.
        restore_file,
        /// The worktree's folder. git refuses one with uncommitted work.
        remove_worktree,
        /// A pull request's number, for these two.
        merge_request,
        close_request,
        /// `arg` is the GitHub login.
        sign_out,
        /// A conflicted file — or, empty, everything — staged with conflict
        /// markers still in it: git takes them as the resolution.
        stage_markers,
        /// The merge, rebase, cherry-pick or revert under way, called off.
        abort_operation,
        /// The commit a rebase stopped on, left out of it.
        skip_step,
        /// The open conflicted file put back as git left it, picks and all.
        restart_file,
    };
};

var confirm: ?Confirm = null;

/// A name Zit needs before it can run something, in the same slot and for the
/// same reason: a modal over the graph hides the thing you are naming.
pub const Prompt = struct {
    kind: Kind,
    /// The commit a branch or tag is created at. Empty means HEAD.
    arg: []u8,

    const Kind = enum {
        new_branch,
        new_tag,
        add_remote,
        new_group,
        rename_group,
        /// `arg` is the branch's current name.
        rename_branch,
        stash,
        /// `arg` is the remote's current name, for both of these.
        rename_remote,
        remote_url,
        /// "path branch": an existing branch is checked out there, a new name
        /// is created from HEAD.
        add_worktree,
    };

    pub fn caption(kind: Kind) []const u8 {
        return switch (kind) {
            .new_branch => "New branch",
            .new_tag => "New tag",
            .add_remote => "Add remote",
            .new_group => "New tab group",
            .rename_group => "Rename this group",
            .rename_branch => "Rename branch",
            .stash => "Stash, as",
            .rename_remote => "Rename remote",
            .remote_url => "New URL",
            .add_worktree => "Add worktree",
        };
    }

    pub fn placeholder(kind: Kind) []const u8 {
        return switch (kind) {
            .new_branch, .rename_branch => "branch name",
            .new_tag => "tag name",
            .add_remote => "name url",
            .new_group, .rename_group => "group name",
            .stash => "what this stash is",
            .rename_remote => "remote name",
            .remote_url => "url",
            .add_worktree => "/where/to/put/it branch",
        };
    }

    /// Over the field, what goes in it.
    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .new_branch, .rename_branch, .new_tag, .rename_remote, .new_group, .rename_group => "Name",
            .add_remote => "Name and URL",
            .stash => "Message",
            .remote_url => "URL",
            .add_worktree => "Folder and branch",
        };
    }

    pub fn icon(kind: Kind) []const u8 {
        return switch (kind) {
            .new_branch => dvui.entypo.flow_branch,
            .new_tag => dvui.entypo.tag,
            .add_remote => dvui.entypo.cloud,
            .new_group => dvui.entypo.plus,
            .rename_branch, .rename_remote, .rename_group => dvui.entypo.pencil,
            .stash => dvui.entypo.archive,
            .remote_url => dvui.entypo.link,
            .add_worktree => dvui.entypo.folder,
        };
    }

    /// Under the dialog's title: what it is about.
    pub fn hint(kind: Kind, arg: []const u8, buf: []u8) []const u8 {
        return switch (kind) {
            .new_branch, .new_tag => if (arg.len > 0)
                std.fmt.bufPrint(buf, "At {s}", .{arg[0..@min(7, arg.len)]}) catch ""
            else
                "At what is checked out",
            .add_remote => "A name, a space, then its URL",
            .rename_branch, .rename_remote, .remote_url => arg,
            .stash => "Every change, set aside under this name",
            .add_worktree => "A folder, a space, then the branch to check out there",
            .new_group, .rename_group => "",
        };
    }

    /// The button that answers the dialog.
    pub fn verb(kind: Kind) []const u8 {
        return switch (kind) {
            .rename_branch, .rename_remote, .rename_group => "Rename",
            .stash => "Stash",
            .remote_url => "Save",
            .add_remote, .add_worktree => "Add",
            else => "Create",
        };
    }
};

pub var prompt: ?Prompt = null;
pub var prompt_text: std.ArrayList(u8) = .empty;

/// What the centre pane shows instead of the graph.
///
/// The path of a selected change lives in `selected_path` rather than here: a
/// `git.Change` points into the `Work` arena, and the next poll throws that
/// away while the selection is still on screen.
const Selection = union(enum) {
    none,
    commit: git.Oid,
    change: git.DiffSide,
    /// Composing an interactive rebase, in `rebase_steps`.
    rebase,
    /// Blaming the file in `selected_path`.
    blame,
    /// Two points in history set against each other, `compare_from` to
    /// `compare_to`; one file of it when `selected_path` is set.
    compare,
};

var compare_from: git.Oid = undefined;
pub var compare_to: git.Oid = undefined;
/// "develop → PROJ-80": what is being compared, for the headers.
var compare_label_buf: [256]u8 = undefined;
pub var compare_label: []const u8 = "";

/// What `to` has that `from` has not: the diff from where they last met,
/// as GitHub shows a pull request.
pub fn startCompare(from: git.Oid, to: git.Oid, from_name: []const u8, to_name: []const u8) void {
    const r = repo orelse return;
    compare_from = r.mergeBase(from, to) orelse from;
    compare_to = to;
    compare_label = std.fmt.bufPrint(&compare_label_buf, "{s} → {s}", .{ from_name, to_name }) catch "";
    selection = .compare;
    selected_path.clearRetainingCapacity();
    diff_stale = true;
    diff_scroll.viewport.y = 0;
}

pub var selection: Selection = .none;
pub var selected_path: std.ArrayList(u8) = .empty;

/// The diff for `selection`, read lazily. `diff_stale` is set by whatever
/// invalidates it rather than re-reading on the spot: a burst of staging then
/// costs one read instead of one per command.
pub var diff: ?git.Diff = null;
pub var diff_stale: bool = false;
/// Every file of `diff`'s commit or comparison, in its arena, for the list on
/// the right: `diff` itself is narrowed to the one file the pane shows.
pub var diff_all: []git.FileDiff = &.{};
/// A file a commit did not change, read whole when it is picked from all the
/// commit's files; `diff` points into it then.
var file_at: ?git.Diff = null;
/// Rows in `diff`: one per file header plus one per line. Fixed height, so the
/// visible range is arithmetic — the same trick the graph uses.
pub var diff_rows: usize = 0;
pub var diff_scroll: dvui.ScrollInfo = .{ .vertical = .given };
/// Lines of the selected change picked for staging one by one, a flag per line
/// of its file. Empty until one is clicked.
pub var picked_lines: std.ArrayList(bool) = .empty;

/// A conflicted file is shown as its regions rather than as a diff: a diff
/// against a file full of markers tells you nothing you can act on.
///
/// `conflict_text` is the file as it is on disk, markers and all, and
/// `conflicts` points into it — so the two are always freed together.
pub var conflict_text: []u8 = &.{};
pub var conflicts: []git.Conflict = &.{};
/// The same file merged again in diff3 style, which the regions' bases point
/// into when git wrote plain markers; freed with them.
var conflict_base_text: []u8 = &.{};
/// Each region's `git.autoResolve` answer, if it has one: why it is safe to
/// resolve without asking.
pub var conflict_autos: []?git.AutoReason = &.{};
/// How the open path came to be conflicted, and whether it is binary.
pub var conflict_kind: git.ConflictKind = .none;
pub var conflict_binary = false;
/// The region the keys act on, in the file named here: another file starts
/// at its first region, with nothing to undo.
pub var conflict_focus: usize = 0;
pub var conflict_path: std.ArrayList(u8) = .empty;
/// Bring the focused region into view on the next frame.
pub var conflict_reveal = false;
/// Each pick made in the open conflicted file, newest last, as what it
/// changed was before it: U and Ctrl+Z take the last one back. The span, not
/// the file: 500 picks in a 1.3 MB lockfile kept whole copies of it, 628 MB;
/// as spans, 50 KB.
pub var resolve_undo: std.ArrayList(git.Splice) = .empty;
/// Picks that can be taken back; past it the oldest goes. A bound, not a
/// size anyone reaches by hand.
const MAX_RESOLVE_UNDO = 1000;

pub fn clearResolveUndo() void {
    for (resolve_undo.items) |step| step.deinit(gpa);
    resolve_undo.clearRetainingCapacity();
}

/// Biggest conflicted file Zit will read. Past this it is not a merge you
/// resolve by clicking.
pub const MAX_CONFLICT_BYTES: usize = 8 * 1024 * 1024;

/// Who last touched each line of the blamed file.
pub var blame_view: ?git.Blame = null;
pub var blame_scroll: dvui.ScrollInfo = .{ .vertical = .given };

/// The rebase being composed, newest first — the order the graph shows, which
/// is the reverse of the order git replays them in.
pub var rebase_steps: std.ArrayList(git.RebaseStep) = .empty;
/// Summaries copied out of the history snapshot, because that snapshot is
/// rebuilt under the composer while it is open.
var rebase_arena: ?std.heap.ArenaAllocator = null;
/// Full sha of the commit the list replays onto — the one below the oldest
/// step, left exactly where it is; seven characters can name two commits. Empty when `rebase_root` says there is none.
pub var rebase_base: [41]u8 = undefined;
pub var rebase_base_len: usize = 0;
pub var rebase_root: bool = false;

/// Most commits Zit will put into one interactive rebase.
///
/// ponytail: a cap, not paging. A rebase longer than this is not one anybody
/// composes by clicking, and the list is built by walking first parents.
const MAX_REBASE_STEPS: usize = 200;

/// Lines shown per side of one region.
///
/// ponytail: a display cap, not a limit on what gets resolved — the buttons
/// always rewrite the whole region. Virtualise the rows like the diff pane if
/// anyone ever hits it on a conflict they actually want to read here.
pub const MAX_CONFLICT_LINES: usize = 200;

/// One file of a commit, its diff in the centre while the commit stays
/// selected on the right.
pub fn selectCommitFile(id: git.Oid, path: []const u8) void {
    selection = .{ .commit = id };
    selected_path.clearRetainingCapacity();
    selected_path.appendSlice(gpa, path) catch return;
    diff_stale = true;
    diff_scroll.viewport.y = 0;
}

/// Whether a diff takes the centre of the graph view: a working-tree file,
/// or one file of a commit.
fn diffOpen() bool {
    return switch (selection) {
        .change, .compare => true,
        .commit => selected_path.items.len > 0,
        else => false,
    };
}

/// Back to the graph from a diff: a commit's file goes back to the commit,
/// anything else to nothing selected.
pub fn closeDiff() void {
    switch (selection) {
        .commit => |id| selectCommit(id),
        else => clearSelection(),
    }
}

pub fn selectCommit(id: git.Oid) void {
    selection = .{ .commit = id };
    selected_path.clearRetainingCapacity();
    diff_stale = true;
    diff_scroll.viewport.y = 0;
}

pub fn selectBlame(path: []const u8) void {
    // `path` is routinely `selected_path.items` itself — the Blame button sits
    // in the header of the very file it blames — and clearing first would then
    // copy a buffer over itself.
    if (path.ptr != selected_path.items.ptr) {
        selected_path.clearRetainingCapacity();
        selected_path.appendSlice(gpa, path) catch return clearSelection();
    }
    selection = .blame;
    diff_stale = true;
    blame_scroll.viewport.y = 0;
}

/// Show a file. The view follows, because opening a file is the whole reason
/// the diff view exists — unless the merge view is up, where the file being
/// picked is a conflict and belongs in the pane already on screen.
pub fn selectChange(path: []const u8, side: git.DiffSide) void {
    selected_path.clearRetainingCapacity();
    selected_path.appendSlice(gpa, path) catch return clearSelection();
    selection = .{ .change = side };
    diff_stale = true;
    diff_scroll.viewport.y = 0;
}

pub fn clearSelection() void {
    selection = .none;
    picked_lines.clearRetainingCapacity();
    selected_path.clearRetainingCapacity();
    if (diff) |*d| d.deinit();
    diff = null;
    if (file_at) |*d| d.deinit();
    file_at = null;
    commit_view.clearTreeFiles();
    commit_view.commit_tree.clear();
    diff_all = &.{};
    diff_rows = 0;
    diff_stale = false;
    clearConflicts();
    clearRebase();
    if (blame_view) |*b| b.deinit();
    blame_view = null;
}

fn clearRebase() void {
    rebase_steps.clearRetainingCapacity();
    if (rebase_arena) |*a| a.deinit();
    rebase_arena = null;
    rebase_base_len = 0;
    rebase_root = false;
}

fn clearConflicts() void {
    if (conflicts.len > 0) gpa.free(conflicts);
    conflicts = &.{};
    if (conflict_text.len > 0) gpa.free(conflict_text);
    conflict_text = &.{};
    if (conflict_base_text.len > 0) gpa.free(conflict_base_text);
    conflict_base_text = &.{};
    if (conflict_autos.len > 0) gpa.free(conflict_autos);
    conflict_autos = &.{};
    conflict_kind = .none;
    conflict_binary = false;
}

/// Status of the selected path on its side, from the work snapshot. Null once
/// the file is clean, which is how a resolved conflict stops being one.
pub fn selectedStatus(side: git.DiffSide) ?git.Status {
    const w = work orelse return null;
    const list = if (side == .staged) w.staged else w.unstaged;
    for (list) |change| {
        if (std.mem.eql(u8, change.path, selected_path.items)) return change.status;
    }
    return null;
}

/// Absolute path of the selected file, into `buf`.
fn selectedAbsPath(buf: []u8) ?[]const u8 {
    if (repo == null) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ repo_path.items, selected_path.items }) catch null;
}

/// Blame the selected file, against the copy on disk.
///
/// Uncommitted edits shift the line numbers, so blaming the working copy is
/// the only version whose line 40 is the line 40 on screen.
fn loadBlame() void {
    const r = repo orelse return clearSelection();

    if (blame_view) |*b| b.deinit();
    blame_view = null;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = selectedAbsPath(&path_buf) orelse return clearSelection();

    const text = std.Io.Dir.cwd().readFileAlloc(app_io, abs, gpa, .limited(MAX_CONFLICT_BYTES)) catch {
        setCommandError("Could not read that file.");
        return clearSelection();
    };
    defer gpa.free(text);

    blame_view = r.readBlame(gpa, selected_path.items, text) catch {
        setCommandError("git has no history for that file yet.");
        return clearSelection();
    };
}

/// Read the conflicted file and find its regions.
///
/// Straight off disk, markers and all: that is where git leaves a conflict and
/// where an editor would resolve one, so it is the one copy everything agrees
/// on.
fn loadConflicts() void {
    clearConflicts();

    // Another file: its own first region, and its own undo.
    if (!std.mem.eql(u8, conflict_path.items, selected_path.items)) {
        conflict_path.clearRetainingCapacity();
        conflict_path.appendSlice(gpa, selected_path.items) catch {};
        conflict_focus = 0;
        clearResolveUndo();
    }

    const r = repo orelse return;
    conflict_kind = r.conflictKind(selected_path.items);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = selectedAbsPath(&path_buf) orelse return;

    conflict_text = std.Io.Dir.cwd().readFileAlloc(app_io, abs, gpa, .limited(MAX_CONFLICT_BYTES)) catch {
        conflict_text = &.{};
        // Deleted on one side: there may be nothing on disk, and that is
        // the conflict, answered below.
        if (conflict_kind != .deleted_by_us and conflict_kind != .deleted_by_them) setCommandError("Could not read that conflicted file.");
        return;
    };
    // Read as text, a binary file is noise: its two versions are picked
    // whole instead.
    conflict_binary = std.mem.indexOfScalar(u8, conflict_text[0..@min(conflict_text.len, 8000)], 0) != null;
    if (conflict_binary) return;

    conflicts = git.parseConflicts(gpa, conflict_text) catch {
        clearConflicts();
        return;
    };

    // A base for each region where git wrote plain markers, its default:
    // merged again from the index, diff3 style, and matched side by side.
    const missing = for (conflicts) |region| {
        if (!region.has_base) break true;
    } else false;
    if (missing and conflict_kind == .both_modified) {
        if (r.mergedWithBase(gpa, selected_path.items)) |merged| {
            conflict_base_text = merged;
            if (git.parseConflicts(gpa, merged)) |with_base| {
                defer gpa.free(with_base);
                git.attachBases(conflicts, with_base);
            } else |_| {}
        }
    }

    conflict_autos = gpa.alloc(?git.AutoReason, conflicts.len) catch &.{};
    for (conflict_autos, conflicts) |*auto, region| {
        auto.* = null;
        const got = (git.autoResolve(gpa, region) catch null) orelse continue;
        gpa.free(got.text);
        auto.* = got.reason;
    }
    conflict_focus = @min(conflict_focus, conflicts.len -| 1);
}

/// A conflict answered by picking a whole file — a binary one, or one a side
/// deleted — rather than region by region.
pub fn wholeFileConflict() bool {
    return conflict_binary or conflict_kind == .deleted_by_us or conflict_kind == .deleted_by_them;
}

/// How many regions resolve on their own, safely.
pub fn safeConflicts() usize {
    var n: usize = 0;
    for (conflict_autos) |auto| n += @intFromBool(auto != null);
    return n;
}

/// Re-read the diff if what it was taken from is gone. Called at the top of the
/// diff pane, so a selection nobody is looking at costs nothing.
pub fn ensureDiff() void {
    if (!diff_stale) return;
    diff_stale = false;
    // Indices into a diff that is about to be replaced. A working-tree file
    // keeps them until the re-read below says it actually changed: the poll
    // re-reads it every time, and picks must not vanish under the cursor.
    if (selection != .change) picked_lines.clearRetainingCapacity();

    const r = repo orelse return clearSelection();

    // A conflicted file is read as text, not as a diff. Checked against the
    // work snapshot rather than by sniffing for markers, so a file that merely
    // contains a line of angle brackets still shows its diff.
    switch (selection) {
        .change => |side| if (selectedStatus(side) == .conflicted) {
            picked_lines.clearRetainingCapacity();
            if (diff) |*d| d.deinit();
            diff = null;
            diff_all = &.{};
            diff_rows = 0;
            loadConflicts();
            return;
        },
        else => {},
    }
    clearConflicts();

    if (selection == .blame) {
        loadBlame();
        return;
    }

    var next: git.Diff = switch (selection) {
        .none, .rebase, .blame => return,
        // The files listed, and the lines of the one open alone: a commit of
        // thousands of files froze the window for seconds reading them all.
        .commit => |id| r.readCommitDiffLines(gpa, id, openLines()) catch return clearSelection(),
        .compare => r.readRangeDiffLines(gpa, compare_from, compare_to, openLines()) catch return clearSelection(),
        .change => |side| r.readWorkDiffFrom(gpa, side, selected_path.items, oldPathOf(side, selected_path.items)) catch return clearSelection(),
    };

    // One file was the whole selection, and it has no changes on this side any
    // more: it was staged, or discarded. Nothing left to look at.
    const single_file = switch (selection) {
        .change => true,
        else => false,
    };
    if (single_file and next.files.len == 0) {
        next.deinit();
        return clearSelection();
    }

    // A file picked out of a commit: that file's diff alone.
    const all = next.files;
    switch (selection) {
        .commit, .compare => if (selected_path.items.len > 0) {
            for (next.files, 0..) |f, i| {
                if (std.mem.eql(u8, f.path, selected_path.items)) {
                    next.files = next.files[i .. i + 1];
                    break;
                }
            } else if (selection == .commit) {
                // A file the commit did not change, picked from all its
                // files: the file as it stood, all context. Its own arena;
                // the commit's file list stays for the panel beside it.
                if (r.readFileAt(gpa, selection.commit, selected_path.items)) |whole| {
                    if (file_at) |*d| d.deinit();
                    file_at = whole;
                    next.files = whole.files;
                } else |_| {}
            }
        },
        else => {},
    }

    if (diff == null or !sameDiff(diff.?, next)) picked_lines.clearRetainingCapacity();

    var rows: usize = 0;
    for (next.files) |f| rows += diff_view.FILE_ROWS + f.lines.len;

    if (diff) |*d| d.deinit();
    diff = next;
    diff_all = all;
    diff_rows = rows;
    diff_view.buildSplitRows();
}

/// The lines a commit's or a range's diff is read with: the file open, or
/// none — its list is all the panel beside it shows.
fn openLines() git.Lines {
    return if (selected_path.items.len > 0) .{ .one = selected_path.items } else .none;
}

/// Line for line the same diff: what lets picks outlive a re-read.
fn sameDiff(a: git.Diff, b: git.Diff) bool {
    if (a.files.len != b.files.len) return false;
    for (a.files, b.files) |x, y| {
        if (!std.mem.eql(u8, x.path, y.path) or x.lines.len != y.lines.len) return false;
        for (x.lines, y.lines) |l, m| {
            if (l.kind != m.kind or l.old_no != m.old_no or l.new_no != m.new_no or !std.mem.eql(u8, l.text, m.text)) return false;
        }
    }
    return true;
}

// === Lifecycle ===

fn appInit(win: *dvui.Window) !void {
    app_window = win;
    run.wake = wakeUi;
    stillUi();

    // Set by `dvui.App.main` before it calls us, so this is never null here.
    const init = dvui.App.main_init.?;
    gpa = init.gpa;
    app_io = init.io;

    // Windows commits a thread's whole stack when it starts, and std's pool
    // — the history, status and GitHub reads run on it — gives each of its
    // threads 16 MB. 4 is far more than a libgit2 revwalk or status needs
    // and still leaves room for a Debug build's frames. Set before the pool
    // has a thread: it starts them as the first reads go out. The Io here is
    // always the `std.Io.Threaded` that std's `main` makes.
    if (@import("builtin").os.tag == .windows) {
        const pool: *std.Io.Threaded = @ptrCast(@alignCast(app_io.userdata));
        pool.stack_size = 4 * 1024 * 1024;
    }

    // Before anything reads it, and before the workspace is loaded out of it.
    var config_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (store.appDir(init.environ_map.*, &config_buf, .config, "")) |dir| {
        migrateFromZync(dir, "zit");
        tab_strip.config_dir.appendSlice(gpa, dir) catch {};
    }

    // Every program Zit starts reads its environment from here: the user's
    // own, minus anything that forces colour (coloured output would not
    // parse), and minus the editor overrides, which beat the `-c core.editor=`
    // and `-c sequence.editor=` a rebase is driven with.
    if (init.environ_map.clone(gpa)) |env| {
        child_env = env;
        for ([_][]const u8{ "CLICOLOR_FORCE", "FORCE_COLOR", "GH_FORCE_TTY", "GIT_PAGER", "PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR" }) |key| _ = child_env.?.swapRemove(key);
        child_env.?.put("NO_COLOR", "1") catch {};
        child_env.?.put("CLICOLOR", "0") catch {};
        child_env.?.put("GH_PROMPT_DISABLED", "1") catch {};
        child_env.?.put("GH_NO_UPDATE_NOTIFIER", "1") catch {};
        child_env.?.put("GIT_TERMINAL_PROMPT", "0") catch {};
        run.env_override = &child_env.?;
    } else |_| {}

    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (store.appDir(init.environ_map.*, &cache_buf, .cache, "avatars")) |dir| {
        migrateFromZync(dir, "zit/avatars");
        avatars.init(gpa, app_io, dir);
    }
    initStatusCache(init.environ_map.*);
    pr.init(gpa, app_io);
    github.init(gpa, app_io, tab_strip.config_dir.items);

    try git.init();

    // Before the theme, which is one of the things it remembers.
    tab_strip.loadWorkspace();
    applyTheme();
    win.content_scale = tab_strip.zoom;
    try openRepoFromArgs();

    // A machine git has never been told who is using it: every commit would
    // fail, so say so before the first one does. Read once, for the avatar's
    // menu as well.
    window_chrome.loadMe();
    if (window_chrome.me_name.items.len == 0 or window_chrome.me_email.items.len == 0) openIdentity();
}

/// The app was called Zync, and its tabs, settings and pictures live under
/// that name: move them to the new one the first time, so a rename is not a
/// reset. `dir` ends in `tail`; the old one ends in it with zit spelled zync.
/// Nothing happens where the new folder already exists — rename refuses — or
/// there is no old one.
fn migrateFromZync(dir: []const u8, tail: []const u8) void {
    if (!std.mem.endsWith(u8, dir, tail)) return;
    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old = std.fmt.bufPrint(&old_buf, "{s}zync{s}", .{ dir[0 .. dir.len - tail.len], tail["zit".len..] }) catch return;
    if (std.fs.path.dirname(dir)) |parent| std.Io.Dir.cwd().createDirPath(app_io, parent) catch {};
    std.Io.Dir.cwd().rename(old, std.Io.Dir.cwd(), dir, app_io) catch {};
}

/// Put the chosen theme on. Split out of `appInit` because the settings menu
/// calls it too, and a failure means the same thing in both places.
fn applyTheme() void {
    dark_theme = style.themes[theme_index].dark;
    style.applyTheme(gpa, theme_index) catch |err| {
        // Only reachable if the compiled-in JSON is malformed, which is a build
        // problem, not a user one — but an unstyled window beats no window.
        std.log.warn("theme not applied ({s}), falling back to the dvui default", .{@errorName(err)});
    };
}

/// The environment children run in; see `appInit`.
var child_env: ?std.process.Environ.Map = null;

fn appDeinit(win: *dvui.Window) void {
    _ = win;

    // Before anything else is freed: the worker is writing into memory this
    // process is about to give back. A command that never returns would hang
    // the exit, which still beats the alternative.
    if (tab_strip.job) |running| {
        var outcome = running.finish(gpa, app_io);
        if (outcome) |*o| o.deinit(gpa);
        tab_strip.job = null;
    }

    // While the strip is still standing: the last chance to record it, and
    // the write of a change from the last 400 ms, which was still waiting.
    tab_strip.saveWorkspace();

    if (graph_view.history_load) |load| load.free();
    graph_view.history_load = null;
    graph_view.reapHistoryLoads(true);
    graph_view.history_retired.deinit(gpa);
    if (work_load) |load| load.free();
    work_load = null;
    dialog_views.closeRepo();
    status_cache_file.deinit(gpa);
    git.shutdown();
    avatars.deinit();
    pr.deinit();
    // Before its paths go: a call still out finishes first.
    if (api_job) |w| w.deinit(app_io);
    api_job = null;
    clearApiQueue();
    api_queue.deinit(gpa);
    api_reviewers.deinit(gpa);
    api_assignees.deinit(gpa);
    api_labels.deinit(gpa);
    repo_slug.deinit(gpa);
    clearJobSteps();
    job_steps.deinit(gpa);
    closeConnect();
    for ([_]*std.ArrayList(u8){ &connect_code, &connect_device, &connect_uri, &connect_note }) |l| l.deinit(gpa);
    github.deinit();
    // After the workers above, the last that start programs with it.
    run.env_override = null;
    if (child_env) |*env| env.deinit();
    child_env = null;

    repo_path.deinit(gpa);
    commit_view.clearPickedChanges();
    commit_view.picked_changes.deinit(gpa);
    commit_view.picked_set.deinit(gpa);
    commit_view.clearFoldedDirs();
    commit_filter.deinit(gpa);
    commit_summary.deinit(gpa);
    commit_description.deinit(gpa);
    commit_scope.deinit(gpa);
    commit_template.deinit(gpa);
    commit_view.clearCoAuthors();
    co_authors.deinit(gpa);
    graph_view.clearGraphPrefs();
    graph_view.hidden_set.deinit(gpa);
    graph_view.graph_hidden.deinit(gpa);
    graph_view.graph_only.deinit(gpa);
    graph_view.graph_pinned.deinit(gpa);
    search_view.clearSearchHits();
    search_view.reapSearchFetches(true);
    clearCommandError();
    clearConfirm();
    clearPrompt();
    prompt_text.deinit(gpa);
    clearSelection();
    rebase_steps.deinit(gpa);
    selected_path.deinit(gpa);
    clone_dest.deinit(gpa);
    graph_view.clearFileHistory();
    graph_view.file_history.deinit(gpa);
    palette_text.deinit(gpa);
    dialog_views.branch_filter.deinit(gpa);
    window_chrome.switch_filter.deinit(gpa);
    graph_view.author_filter.deinit(gpa);
    graph_view.clearNames(&graph_view.author_only);
    graph_view.author_only.deinit(gpa);
    rebase_view.sidebar_filter.deinit(gpa);
    tab_strip.default_branch.deinit(gpa);
    tab_strip.editor_cmd.deinit(gpa);
    tab_strip.terminal_cmd.deinit(gpa);
    diff_view.clearImagePair();
    signing_key.deinit(gpa);
    if (signing_job) |j| j.deinit(app_io);
    if (repo_prefs_job) |j| j.deinit(app_io);
    repo_name_local.deinit(gpa);
    repo_email_local.deinit(gpa);
    repo_settings_path.deinit(gpa);
    if (editors_job) |j| j.deinit(app_io);
    if (commit_view.repo_config_job) |j| j.deinit(app_io);
    commit_view.git_template_path.deinit(gpa);
    commit_sent.deinit(gpa);
    tab_strip.clearRecent();
    tab_strip.recent.deinit(gpa);
    dialog_views.clearForget();
    identity_name.deinit(gpa);
    identity_email.deinit(gpa);
    window_chrome.forgetMe();
    graph_view.clearDrop();
    graph_view.drag_source.deinit(gpa);
    picked_lines.deinit(gpa);
    pr_comment.deinit(gpa);
    clearPrEdit();
    clearPrCreate();
    pr_search.deinit(gpa);
    pr_search = .empty;
    pr_filter = .open;
    pr_reply.deinit(gpa);
    pr_reply_id.deinit(gpa);
    diff_view.split_rows.deinit(gpa);
    for ([_]*std.ArrayList(u8){ &dialog_views.dialog_url, &dialog_views.dialog_parent, &dialog_views.dialog_name, &dialog_views.dialog_branch }) |list| list.deinit(gpa);
    freeViews();
    if (action_input) |patch| gpa.free(patch);
    action_input = null;

    for (tab_strip.groups.items) |*group| group.deinit();
    tab_strip.groups.deinit(gpa);
    tab_strip.freeWorkspaces();
    tab_strip.workspaces.deinit(gpa);
    ws_name.deinit(gpa);
    tab_strip.config_dir.deinit(gpa);
}

/// Open the repo named on the command line, or the one containing the current
/// directory — `zit` in a checkout should just work, like `git` does.
fn openRepoFromArgs() !void {
    // The process arena, not `gpa`: argv is read once and lives as long as the
    // process, so there is nothing to free.
    const init = dvui.App.main_init.?;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len > 1) {
        tab_strip.openAndRemember(args[1]);
        return;
    }

    // The repository you are standing in wins, the way `git` itself behaves.
    // Only when there is none does the last session come back.
    openRepo(".");
    if (repo != null) {
        tab_strip.rememberActive();
        return;
    }

    tab_strip.restoreActiveTab();
}

/// Make `path` the open repository, replacing whatever was open.
///
/// Failures are reported in the graph pane rather than in a dialog — pointing
/// at the wrong folder is a normal thing to do, not an error to acknowledge.
pub fn openRepo(path: []const u8) void {
    // A failure closes what was open: the strip already shows the tab asked
    // for, and the old repository under it would take every command meant
    // for the new one — while `open_error` only shows with nothing open.
    var opened = git.Repo.open(path) catch {
        dialog_views.closeRepo();
        tab_strip.open_error = "Not a git repository. Use + in the tab bar to open one.";
        return;
    };

    const workdir = opened.workdir() orelse {
        opened.deinit();
        dialog_views.closeRepo();
        tab_strip.open_error = "Bare repositories have no working tree to show.";
        return;
    };

    // Copied before the old repo is closed: `path` may well be a slice of
    // `repo_path`, which the swap below frees.
    var next: std.ArrayList(u8) = .empty;
    next.appendSlice(gpa, workdir) catch {
        opened.deinit();
        dialog_views.closeRepo();
        tab_strip.open_error = "Out of memory opening that repository.";
        return;
    };

    dialog_views.closeRepo();

    repo = opened;
    repo_path = next;
    repo_name = git.repoName(repo_path.items);
    startWatching(opened);
    template_due = true;
    // The real clock: before the first frame, `frame_now_s` is still 0, and
    // the first fetch would come at once instead of shortly after.
    const now_s: i64 = @intCast(@divFloor(std.Io.Timestamp.now(app_io, .real).nanoseconds, std.time.ns_per_s));
    tab_strip.last_auto_fetch_s = now_s - @as(i64, tab_strip.auto_fetch_minutes) * 60 + tab_strip.AUTO_FETCH_FIRST_S;
    tab_strip.open_error = null;
    new_tab_open = false;

    detectLfs();
    graph_view.loadGraphPrefs();
    commit_view.startRepoConfig();
    // Off the UI thread too, beside the history's: under the loading screen,
    // which is up longer than 11,000 files take to stat.
    workChanged("Reading the changes");
    // The first read of a repository is the slow one — packfiles not yet in
    // the page cache — so it happens off the UI thread, with the loading
    // screen in the meantime. Tests read it in place: they assert on it straight after.
    if (@import("builtin").is_test) {
        reloadHistory();
        historyArrived();
    } else {
        graph_view.startHistoryLoad();
    }
}

/// What needs the history once it is there: the remotes it lists say where
/// pictures and pull requests come from.
pub fn historyArrived() void {
    avatars.setGithubRepo(if (tab_strip.integrations) githubRemote() else null);
    refreshRequests();
}

// === Working tree, read in the background ===
//
// The status is re-read on the poll timer. On Linux that is a few
// milliseconds; on Windows, where every stat is slow, it is long enough in a
// big repository to freeze the window every poll. So the timer's reads go to
// another thread, and so do the reads after a command (`workChanged`): with
// 11,000 changed files one is 300 ms on Windows, which the window waited out
// frozen after every stage. A read after a command bumps `work_gen`, which
// retires any read already out — it may have started before the command.

const WorkLoad = struct {
    path: []u8,
    gen: u64,
    done: std.atomic.Value(bool) = .init(false),
    work: ?git.Work = null,
    future: ?std.Io.Future(void) = null,

    fn run(self: *WorkLoad) void {
        defer wakeUi();
        defer self.done.store(true, .release);
        if (status_cache_file.items.len > 0 and status_cache_lock.tryLock()) {
            defer status_cache_lock.unlock(app_io);
            defer if (status_cache_drop.swap(false, .acq_rel)) dropStatusCache();
            if (statusCacheFor(self.path)) |cache| {
                if (cache.readWork(gpa, app_io)) |w| {
                    self.work = w;
                    return;
                } else |_| dropStatusCache();
            }
        }
        var r = git.Repo.open(self.path) catch return;
        defer r.deinit();
        self.work = r.readWork(gpa) catch null;
    }

    fn free(self: *WorkLoad) void {
        if (self.future) |*f| f.await(app_io);
        if (self.work) |*w| w.deinit();
        gpa.free(self.path);
        gpa.destroy(self);
    }
};

/// The status reads' copy of the index (`git.StatusCache`), kept from one
/// read to the next, so that a file touched without being changed is hashed
/// once rather than at every read. One read holds it at a time — a read
/// after a command, with the timer's still out, reads without it — and it is
/// for the repository last read.
var status_cache: ?git.StatusCache = null;
var status_cache_lock: std.Io.Mutex = .init;
/// Set by `closeRepo` while a read holds the cache: dropped as that read
/// ends, with its file.
var status_cache_drop: std.atomic.Value(bool) = .init(false);
/// Where the index's copy is kept: Zit's cache, under a name of this
/// process's own. Empty — no cache — when there is no cache folder.
var status_cache_file: std.ArrayList(u8) = .empty;

/// The cache for `path`, opened — and the last repository's dropped — if
/// it is not that one's. Called with `status_cache_lock` held.
fn statusCacheFor(path: []const u8) ?*git.StatusCache {
    if (status_cache) |cache| if (!std.mem.eql(u8, cache.path, path)) dropStatusCache();
    if (status_cache == null) status_cache = git.StatusCache.open(gpa, path, status_cache_file.items) catch return null;
    return &status_cache.?;
}

/// Called with `status_cache_lock` held, or with no read left to hold it.
fn dropStatusCache() void {
    if (status_cache) |*cache| cache.deinit(gpa, app_io);
    status_cache = null;
}

/// The closed repository's cache let go of: now, or as the read holding it
/// ends — which is not waited for, as `closeRepo` waits for no read.
pub fn releaseStatusCache() void {
    if (status_cache_lock.tryLock()) {
        defer status_cache_lock.unlock(app_io);
        dropStatusCache();
    } else status_cache_drop.store(true, .release);
}

fn initStatusCache(env: std.process.Environ.Map) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = store.appDir(env, &buf, .cache, "") orelse return;
    std.Io.Dir.cwd().createDirPath(app_io, dir) catch return;
    var id: [8]u8 = undefined;
    app_io.random(&id);
    const sep = if (@import("builtin").os.tag == .windows) "\\" else "/";
    status_cache_file.print(gpa, "{s}" ++ sep ++ "index-{x}", .{ dir, id[0..] }) catch status_cache_file.clearRetainingCapacity();
}

var work_load: ?*WorkLoad = null;
var work_gen: u64 = 0;
/// Asked for while one was out: what changed during that read is read when
/// it lands, not lost.
var work_again = false;

/// After a command: the status read again, off the UI thread. A read
/// already out may have begun before the command: retired, and read again
/// once it lands, so what lands is never older than the command.
pub fn workChanged(what: []const u8) void {
    if (@import("builtin").is_test) return reloadWork();
    work_gen +%= 1;
    work_settling = true;
    settling_label = what;
    refreshWork();
}

/// A read asked for by a command is out: the lists on screen are about to
/// change, which the changes panel says over them — with what the command
/// did, "Staging". The poll's reads, which usually find nothing new, do not
/// set it.
pub var work_settling = false;
pub var settling_label: []const u8 = "Reading the changes";

/// What the command a result is folded in for did, as the changes' veil says
/// it until they are read again: set by whoever calls `applyOutcome`.
var command_label: []const u8 = "Reading the changes";

/// "Staging" for `git add`: what a command does, in the words the veil over
/// the changes uses while they are read again after it.
fn commandLabel(args: []const []const u8) []const u8 {
    // Past git's own options: `--literal-pathspecs`, `-c key=value`.
    var at: usize = 0;
    while (at < args.len and args[at].len > 0 and args[at][0] == '-') : (at += 1) {
        if (std.mem.eql(u8, args[at], "-c")) at += 1;
    }
    if (at >= args.len) return "Updating";
    const verb = args[at];
    const rest = args[at..];
    const eq = std.mem.eql;
    if (eq(u8, verb, "add")) return "Staging";
    if (eq(u8, verb, "reset")) return if (hasArg(rest, "--hard") or hasArg(rest, "--soft") or hasArg(rest, "--mixed")) "Resetting" else "Unstaging";
    if (eq(u8, verb, "apply")) return if (!hasArg(rest, "--cached")) "Discarding" else if (hasArg(rest, "-R") or hasArg(rest, "--reverse")) "Unstaging" else "Staging";
    if (eq(u8, verb, "restore") or eq(u8, verb, "clean")) return "Discarding";
    if (eq(u8, verb, "checkout")) return if (hasArg(rest, "--")) "Discarding" else "Switching";
    if (eq(u8, verb, "switch")) return "Switching";
    if (eq(u8, verb, "rm")) return "Removing";
    if (eq(u8, verb, "mv")) return "Renaming";
    if (eq(u8, verb, "commit")) return "Committing";
    if (eq(u8, verb, "stash")) return "Stashing";
    if (eq(u8, verb, "merge")) return "Merging";
    if (eq(u8, verb, "rebase")) return "Rebasing";
    if (eq(u8, verb, "cherry-pick")) return "Cherry-picking";
    if (eq(u8, verb, "revert")) return "Reverting";
    return "Updating";
}

fn hasArg(args: []const []const u8, arg: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, arg)) return true;
    return false;
}

fn refreshWork() void {
    if (@import("builtin").is_test) return reloadWork();
    if (repo == null) return;
    if (work_load != null) {
        work_again = true;
        return;
    }
    const load = gpa.create(WorkLoad) catch return;
    load.* = .{ .path = gpa.dupe(u8, repo_path.items) catch {
        gpa.destroy(load);
        return;
    }, .gen = work_gen };
    work_load = load;
    load.future = app_io.concurrent(WorkLoad.run, .{load}) catch blk: {
        load.run();
        break :blk null;
    };
}

/// Once a frame, before anything draws: swap a finished read in, if it is
/// still the newest. True when one landed.
fn collectWorkLoad() bool {
    const load = work_load orelse return false;
    if (!load.done.load(.acquire)) return false;
    work_load = null;
    defer load.free();
    defer if (work_again) {
        work_again = false;
        refreshWork();
    };
    if (repo == null or !std.mem.eql(u8, load.path, repo_path.items) or load.gen != work_gen) return false;
    // The newest read is in, whatever it found.
    work_settling = false;
    var next = load.work orelse return false;
    load.work = null;
    // Nothing changed — the usual answer, on a timer or a watcher's word —
    // and nothing is drawn again. Except the open file's diff: its lines can
    // change with its status staying "modified".
    if (work) |w| if (sameWork(w, next)) {
        next.deinit();
        if (selection != .change) return false;
        diff_stale = true;
        return true;
    };
    swapWork(next);
    // The old snapshot just went: its pages back now, not at some later trim.
    trimHeap();
    return true;
}

fn sameWork(a: git.Work, b: git.Work) bool {
    for ([_][2][]const git.Change{ .{ a.staged, b.staged }, .{ a.unstaged, b.unstaged } }) |pair| {
        if (pair[0].len != pair[1].len) return false;
        for (pair[0], pair[1]) |x, y| {
            if (x.status != y.status or !std.mem.eql(u8, x.path, y.path) or !std.mem.eql(u8, x.old_path, y.old_path)) return false;
        }
    }
    return true;
}

/// What a tab shows while its history is read — on opening it, and on coming
/// back to it: Zit's mark, breathing, over the repository's name, the way
/// GitKraken shows its own while it reads a repository.
fn loadingScreen() void {
    var area = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
    });
    defer area.deinit();
    var stack = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .gravity_y = 0.45, .background = false });
    defer stack.deinit();

    // One breath every 1.2 s: a few pixels bigger and back, inside a box
    // that does not move, so the name under it stays put.
    const period_ms = 1200;
    const t: f32 = @floatFromInt(@mod(@divTrunc(dvui.frameTimeNS(), std.time.ns_per_ms), period_ms));
    const breath = 0.5 - 0.5 * @cos(t / period_ms * 2 * std.math.pi);
    const size: f32 = 64;
    const d = size - 10 * (1 - breath);
    {
        var frame = dvui.box(@src(), .{}, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = size, .h = size },
            .max_size_content = .size(.{ .w = size, .h = size }),
            .background = false,
        });
        defer frame.deinit();
        _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = @embedFile("brand/zit-icon-256.png"), .name = "zit" } }, .shrink = .both }, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = d, .h = d },
            .max_size_content = .size(.{ .w = d, .h = d }),
        });
    }
    dvui.label(@src(), "Loading {s}…", .{repo_name}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_x = 0.5,
        .margin = .{ .y = style.space.md },
    });
    // The next breath, a few times a second; the history's landing wakes the
    // window by itself.
    animateEvery(area.data().id, 80);
}

/// No motion dvui would add by itself: a hover's wash fading in over 0.12 s,
/// a pane sliding shut. Each is frames at the display's rate for nothing a
/// git client says; a wash that snaps on says the same.
fn stillUi() void {
    dvui.reduce_motion = true;
    dvui.hover_fade_secs = 0;
}

/// The next step of an animation, `ms` from now: a timer, not a refresh — a
/// refresh draws again at once, as fast as the display goes, for something
/// that moves a few times a second.
pub fn animateEvery(id: dvui.Id, ms: u32) void {
    if (dvui.timerDoneOrNone(id)) dvui.timer(id, @intCast(ms * 1000));
}

fn historyLoading() bool {
    return graph_view.history_load != null and history == null;
}

/// How many of the newest commits CI is asked about.
const CI_COMMITS = 40;
/// And how many pull requests' heads, on top.
const CI_REQUESTS = 30;

/// Ask the host what CI made of the newest commits; `pr` paces it.
fn askCi() void {
    if (@import("builtin").is_test) return;
    const h = history orelse return;
    var shas: [CI_COMMITS + CI_REQUESTS]pr.Sha = undefined;
    // Typed: against a comptime constant `@min` narrows to the smallest type
    // that holds it — a u6 for 40 — and the requests' heads counted on top
    // overflowed it, the moment a repository had enough open requests.
    var n: usize = @min(h.commits.len, CI_COMMITS);
    for (h.commits[0..n], 0..) |commit, i| {
        var hex: [41]u8 = undefined;
        @memcpy(&shas[i], git.oidHex(commit.id, &hex)[0..40]);
    }
    // And the pull requests' heads, for their rows' checks.
    for (pr.list) |req| {
        if (n == shas.len) break;
        if (req.sha.len != 40) continue;
        @memcpy(&shas[n], req.sha[0..40]);
        n += 1;
    }
    pr.ciRefresh(repo_path.items, shas[0..n], frame_now_s);
}

/// Re-list the open pull requests, if the repository is on GitHub.
pub fn refreshRequests() void {
    repo_slug.clearRetainingCapacity();
    if (history == null or !tab_strip.integrations) return pr.refresh(repo_path.items, .none, "");
    // The first remote on GitHub, `origin` before the others.
    const found = firstRemote([]const u8, struct {
        fn pick(r: git.Remote) ?[]const u8 {
            return avatars.githubSlug(r.url);
        }
    }.pick);
    if (found) |s| repo_slug.appendSlice(gpa, s) catch {};
    pr.refresh(repo_path.items, if (found != null) .github else .none, repo_slug.items);
    pr.refreshIssues(repo_path.items);
}

/// What `pick` makes of the first remote it makes anything of — `origin`
/// before the others, then in the order they are listed.
fn firstRemote(comptime T: type, comptime pick: fn (git.Remote) ?T) ?T {
    const h = history orelse return null;
    for (h.remotes) |r| {
        if (std.mem.eql(u8, r.name, "origin")) if (pick(r)) |v| return v;
    }
    for (h.remotes) |r| if (pick(r)) |v| return v;
    return null;
}

/// "owner/repo" of the remote a GitHub repository is known by — origin if it
/// is on GitHub, else the first one that is.
pub fn githubRemote() ?[]const u8 {
    return firstRemote([]const u8, struct {
        fn pick(r: git.Remote) ?[]const u8 {
            return avatars.githubSlug(r.url);
        }
    }.pick);
}

/// Whether anything here is tracked through LFS.
///
/// Checked once, on open: `.gitattributes` naming the lfs filter is how a
/// repository declares it, and that does not change while you work in one.
fn detectLfs() void {
    tab_strip.uses_lfs = false;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buf, "{s}.gitattributes", .{repo_path.items}) catch return;

    // Having no `.gitattributes` at all is the common case, not an error.
    const text = std.Io.Dir.cwd().readFileAlloc(app_io, abs, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(text);

    tab_strip.uses_lfs = std.mem.indexOf(u8, text, "filter=lfs") != null;
}

/// Ask for a folder and open whatever repository contains it.
fn promptOpenRepo() void {
    dialog_views.pickFolder(.open_repo, "Open a repository", if (repo_path.items.len > 0) repo_path.items else null);
}

// === Reading ===

/// Refs, commits and lanes. Built into locals and swapped in at the end, so a
/// failed read leaves the previous graph on screen rather than an empty pane.
pub fn reloadHistory() void {
    const r = repo orelse return;
    graph_view.history_gen +%= 1;

    var next_history = r.readHistoryFiltered(gpa, graph_view.graphFilter()) catch {
        setCommandError(git.lastError());
        return;
    };
    var next_lanes = graph.build(gpa, next_history.commits, next_history.head_oid) catch {
        next_history.deinit();
        setCommandError("Out of memory laying out the graph.");
        return;
    };

    if (history) |*h| h.deinit();
    if (lanes) |*l| l.deinit();
    history = next_history;
    lanes = next_lanes;
    _ = &next_history;
    _ = &next_lanes;
    graph_view.history_seq +%= 1;
    diff_view.dropStaleSelection();
    rebase_view.readOpInfo();

    if (graph_view.file_history.items.len > 0) graph_view.markFileHistory();
    // The old snapshot just went: give its pages back now rather than at the
    // next timed trim, or every refresh shows as a spike of a few seconds.
    trimHeap();
}

fn reloadWork() void {
    const r = repo orelse return;
    work_gen +%= 1;
    const next = r.readWork(gpa) catch return;
    swapWork(next);
}

fn swapWork(next: git.Work) void {
    if (work) |*w| w.deinit();
    work = next;
    commit_view.work_version +%= 1;

    if (open_first_conflict) {
        open_first_conflict = false;
        for (next.unstaged) |change| {
            if (change.status != .conflicted) continue;
            active_view = .graph;
            selectChange(change.path, .unstaged);
            break;
        }
    }

    // A commit's diff cannot change, so only the working-tree side is worth
    // re-reading — and this runs on the poll timer.
    switch (selection) {
        .change => diff_stale = true,
        else => {},
    }
}

/// glibc's `mallopt`, for the arena count; null elsewhere, as `malloc_trim`.
const mallopt: ?*const fn (c_int, c_int) callconv(.c) c_int = if (@import("builtin").os.tag == .linux and @import("builtin").abi.isGnu())
    @extern(*const fn (c_int, c_int) callconv(.c) c_int, .{ .name = "mallopt" })
else
    null;
const M_ARENA_MAX: c_int = -8;
const M_MMAP_THRESHOLD: c_int = -3;

/// glibc's `malloc_trim`: hands the heap's free pages back to the system.
/// glibc keeps what is freed for reuse, and a client that rebuilds its
/// snapshots every poll frees a lot — so without this the RSS shows the
/// high-water mark of every refresh since start, not what is in use.
const malloc_trim: ?*const fn (usize) callconv(.c) c_int = if (@import("builtin").os.tag == .linux and @import("builtin").abi.isGnu())
    @extern(*const fn (usize) callconv(.c) c_int, .{ .name = "malloc_trim" })
else
    null;

pub fn trimHeap() void {
    if (malloc_trim) |trim| _ = trim(0);
}

/// Runs every `POLL_INTERVAL_US`. Re-reads the working tree always — that is
/// what notices a file you just saved — and the history only when HEAD has
/// actually moved, which is what notices a commit or checkout you made in a
/// terminal.
fn poll() void {
    const r = repo orelse return;
    // The first read is still out on its thread; reading it again here would
    // only do the same work twice, on the UI thread.
    if (graph_view.history_load != null) return refreshWork();

    refreshWork();
    autoFetch();

    const now = r.headOid();
    const known = if (history) |h| h.head_oid else null;
    const moved = if (now) |a|
        if (known) |b| !git.oidEql(a, b) else true
    else
        known != null;

    // A checkout of another branch at the same commit moves no oid, but it is
    // still a move: the branch shown, and the reflog entry Undo takes back.
    const name_now = r.headBranch(gpa) catch null;
    defer if (name_now) |n| gpa.free(n);
    const name_known = if (history) |h| h.head else null;
    const switched = if (name_now) |a|
        if (name_known) |b| !std.mem.eql(u8, a, b) else true
    else
        name_known != null;

    // A reset to the commit HEAD is already on moves neither: only the
    // reflog says so, and it is what Undo would act on.
    const move_now = r.readLastMove(gpa);
    defer if (move_now) |m| gpa.free(m.message);
    const move_known = if (history) |h| h.last_move else null;
    const logged = if (move_now) |a|
        if (move_known) |b| !git.oidEql(a.old, b.old) or !std.mem.eql(u8, a.message, b.message) else true
    else
        move_known != null;

    // A merge stopped on a conflict in a terminal moves none of the three:
    // only the repository's state says it is under way.
    const state_changed = if (history) |h| r.state() != h.state else false;

    if (moved or switched or logged or state_changed) graph_view.refreshHistory();
}

/// The quiet fetch, when it is due and nothing else is running.
fn autoFetch() void {
    // Tests drive their own fetches; one arriving on its own would race them.
    if (@import("builtin").is_test) return;
    if (tab_strip.auto_fetch_minutes == 0 or tab_strip.job != null or action != .none) return;
    if (frame_now_s - tab_strip.last_auto_fetch_s < @as(i64, tab_strip.auto_fetch_minutes) * 60) return;
    tab_strip.last_auto_fetch_s = frame_now_s;
    const h = history orelse return;
    if (h.remotes.len == 0) return;
    requestNetwork("Fetching", tab_strip.fetchAllArgs(true));
    tab_strip.job_quiet = action == .network;
}

/// The desktop's own terminal, in the repository's folder: `$TERMINAL` if
/// set, else the first of the usual ones found, told the folder outright
/// where it takes it — a profile's start folder would win over the one it
/// was started in. Through `sh` and in the background, so it leaves no child
/// of Zit's behind.
pub fn openTerminal() void {
    if (repo == null) return;
    // Windows Terminal where there is one, the console otherwise; `start`
    // gives either its own window and returns.
    // The one picked in the settings first — only ever one of
    // `known_terminals`, so a name safe in a command line.
    const chosen = std.mem.trim(u8, tab_strip.terminal_cmd.items, " ");
    const windows_line: []const u8 = if (std.mem.eql(u8, chosen, "wt"))
        "start wt -d ."
    else if (std.mem.eql(u8, chosen, "pwsh"))
        "start pwsh"
    else if (std.mem.eql(u8, chosen, "powershell"))
        "start powershell"
    else if (std.mem.eql(u8, chosen, "cmd"))
        "start cmd"
    else
        "where wt >nul 2>nul && start wt -d . || start cmd";
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd.exe", "/s", "/c", windows_line }
    else
        &.{
            "sh", "-c",
            \\for t in "$1" "$TERMINAL" x-terminal-emulator konsole gnome-terminal kitty alacritty wezterm foot ghostty xfce4-terminal tilix xterm; do
            \\  [ -n "$t" ] && command -v "$t" >/dev/null 2>&1 || continue
            \\  case "${t##*/}" in
            \\    konsole) set -- --workdir "$PWD" ;;
            \\    gnome-terminal|xfce4-terminal|alacritty) set -- --working-directory "$PWD" ;;
            \\    kitty) set -- --directory "$PWD" ;;
            \\    wezterm) set -- start --cwd "$PWD" ;;
            \\    foot) set -- -D "$PWD" ;;
            \\    tilix) set -- -w "$PWD" ;;
            \\    *) set -- ;;
            \\  esac
            \\  "$t" "$@" >/dev/null 2>&1 &
            \\  exit 0
            \\done
            \\exit 1
            ,
            "sh", chosen,
        };
    const ok = run.launch(app_io, repo_path.items, argv) catch return setCommandError("Could not start a terminal.");
    if (!ok) setCommandError("No terminal found. Set $TERMINAL to the one you use.");
}

// === Writing ===

/// What this frame asked the repository to do.
///
/// Nothing mutates the repository while the frame is being built. Every panel
/// iterates slices that live inside a snapshot arena (`History`, `Work`), and
/// any git command throws those arenas away and builds new ones — so a button
/// that ran `git add` in place left the loop around it walking freed memory.
/// One action is collected here and run in `runAction`, after the last widget.
const Action = enum {
    none,
    /// `action_argv[0..action_argc]`, copied in by `request`.
    run,
    commit,
    confirmed,
    prompt,
    resolve,
    /// Every region that resolves on its own, in the open file.
    resolve_safe,
    /// The open file as it was before its last pick.
    undo_resolve,
    /// The open file whole, as `action_side` has it, staged.
    take_file,
    /// The open file staged, nothing left in it, and on to the next.
    stage_next,
    rebase,
    network,
    tabs,
    refresh,
    open_repo,
    close_repo,
    /// The clone or create dialog's button, and its Browse button.
    repo_dialog,
    browse_parent,
    /// The drop menu's answer, for `drop`.
    drop,
    /// The forget dialog's yes.
    forget,
    /// Apply or pop of the stash in `stash_pending`, by `stash_verb`.
    stash,
};

pub var action: Action = .none;
var action_argv: [8][]const u8 = undefined;
var action_argc: usize = 0;
/// Holds the pending command's arguments: the callers build them in buffers
/// on their own stack, or in a snapshot a command throws away, and the
/// command runs after both are gone.
var action_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// Copy `args` in as the pending command's. False, with the error said, when
/// there was no memory for it.
fn setArgv(args: []const []const u8) bool {
    std.debug.assert(args.len <= action_argv.len);
    _ = action_arena.reset(.retain_capacity);
    for (args, 0..) |a, i| {
        action_argv[i] = action_arena.allocator().dupe(u8, a) catch {
            setCommandError("Out of memory.");
            return false;
        };
    }
    action_argc = args.len;
    return true;
}
/// Fed to the pending command's standard input, owned. Set by `requestHunk`
/// and freed by `runAction` — one action per frame means one buffer.
pub var action_input: ?[]u8 = null;
/// What the tab strip asked for.
///
/// Deferred like every other mutation: these rebuild the very lists the strip
/// is iterating at the moment it asks.
const TabAction = union(enum) {
    none,
    select: usize,
    close: usize,
    select_group: usize,
    close_group: usize,
    /// Group, tab.
    select_in: [2]usize,
    close_in: [2]usize,
    group_toggle: usize,
    /// Group, colour.
    group_color: [2]usize,
    ungroup: usize,
    /// Group, tab, the group it goes to.
    tab_to: [3]usize,
    tab_out: [2]usize,
    /// Group, tab, then the group and slot it was dragged to.
    tab_at: [4]usize,
    /// A tab let go past the last one: out of its group, at the end.
    tab_end: [2]usize,
    /// A repository picked out of the menu of known ones, owned — the list it
    /// came from is about to be rebuilt underneath it.
    open: []u8,
    select_ws: usize,
    close_ws: usize,
    /// The workspace dialog answered: what it holds is applied.
    workspace_named,
};

var tab_action: TabAction = .none;
/// The group — and tab — a group prompt is about: the tab a new group
/// starts with, the group being renamed.
var group_target: [2]usize = .{ 0, 0 };

/// Which conflict region the pending `.resolve` applies to, and how.
var action_conflict: usize = 0;
pub var action_side: git.ConflictSide = .ours;

/// Ask for `git <args...>` once the frame is built.
pub fn request(args: []const []const u8) void {
    // First one wins. Two mutations in one frame is not something a person
    // does, and the second would run against a tree the first just changed.
    if (action != .none) return;
    if (!setArgv(args)) return;
    action = .run;
}

pub fn requestAction(kind: Action) void {
    if (action == .none) action = kind;
}

/// Returns true when it did something, so the caller knows to draw again.
fn runAction() bool {
    const pending = action;
    action = .none;

    switch (pending) {
        .none => return false,
        .run => {
            gitDoInput(action_argv[0..action_argc], action_input);
            if (action_input) |patch| gpa.free(patch);
            action_input = null;
        },
        .commit => doCommit(),
        .confirmed => runConfirmed(),
        .prompt => runPrompt(),
        .resolve => runResolve(),
        .resolve_safe => runResolveSafe(),
        .undo_resolve => runUndoResolve(),
        .take_file => runTakeFile(),
        .stage_next => runStageNext(),
        .rebase => runRebase(),
        .network => startJob(),
        .tabs => runTabAction(),
        .refresh => {
            graph_view.refreshHistory();
            workChanged("Refreshing");
        },
        .open_repo => promptOpenRepo(),
        .repo_dialog => dialog_views.submitRepoDialog(),
        .browse_parent => dialog_views.browseParent(),
        .drop => graph_view.runDrop(),
        .forget => dialog_views.runForget(),
        .close_repo => dialog_views.closeRepo(),
        .stash => rebase_view.stashDo(rebase_view.stash_verb, &rebase_view.stash_pending),
    }

    return true;
}

/// Ask for `git <args...>` on another thread once the frame is built.
///
/// For the commands that talk to a remote, and for the local ones that can
/// take a while: switching branch, stashing, committing — which runs the
/// hooks and the signing. Waited for on the UI thread, any of them froze the
/// window on Windows. The quick ones go through `request`, which finishes
/// before it returns: one code path that completes synchronously is worth
/// more than making all of them look alike.
pub fn requestNetwork(label: []const u8, args: []const []const u8) void {
    if (action != .none) return;
    // The toolbar says one is running, but a held key or a double click can
    // still arrive before the frame showing that — and a click while a quiet
    // fetch runs would otherwise vanish without a word.
    if (tab_strip.job != null) return setCommandError(BUSY);
    if (!setArgv(args)) return;
    tab_strip.job_label = label;
    action = .network;
}

const BUSY = "Another command is still running. Try again when it finishes.";

// === GitHub, acted on ===
//
// What changes something on GitHub — a merge, a review, a comment — is a call
// to its API (`github.zig`), out on a thread of its own like a git job, and a
// run of them for what takes several: merged then its branch deleted, edited
// then reviewers asked then labels set. A call that fails stops the run, and
// GitHub's own words are what the bar shows.

const ApiCall = struct {
    label: []const u8,
    method: []const u8,
    /// Under the API, owned.
    path: []u8,
    /// Owned; null for none.
    body: ?[]u8,
    then: ApiThen = .none,
};

/// What a call's success sets off besides the next in the run.
const ApiThen = enum {
    none,
    /// A request merged or closed: off the open list, and shown as such,
    /// before GitHub's own lists have caught up. Its number in
    /// `api_gone_number`.
    gone,
    /// The branch after a merge: GitHub may have deleted it itself, where
    /// the repository says to — gone either way, and no failure.
    branch_after_merge,
    /// Empty the review box: what it held went out.
    clear_comment,
    clear_reply,
    /// A request was created: ask its reviewers, from `api_reviewers`.
    ask_reviewers,
};

var api_job: ?*run.Capture = null;
var api_label: []const u8 = "";
var api_then: ApiThen = .none;
/// The calls waiting behind the one out.
var api_queue: std.ArrayList(ApiCall) = .empty;
/// For `.ask_reviewers`: the JSON lists, owned — whom to ask, whom to
/// assign, which labels.
var api_reviewers: std.ArrayList(u8) = .empty;
var api_assignees: std.ArrayList(u8) = .empty;
var api_labels: std.ArrayList(u8) = .empty;
/// Fetch once the run succeeds: it moved branches on the remote.
var api_fetch_after = false;
/// For `.gone`: the request merged or closed, and what it now is.
var api_gone_number: u32 = 0;
var api_gone_state: []const u8 = "";

/// `owner/name` on GitHub of the open repository; empty when it is not there.
var repo_slug: std.ArrayList(u8) = .empty;

/// `/repos/<owner>/<name>` followed by `fmt`, into `buf`; null when the
/// repository is not on GitHub.
fn apiPath(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    if (repo_slug.items.len == 0) return null;
    const head = std.fmt.bufPrint(buf, "/repos/{s}", .{repo_slug.items}) catch return null;
    const tail = std.fmt.bufPrint(buf[head.len..], fmt, args) catch return null;
    return buf[0 .. head.len + tail.len];
}

/// Queue a call; it starts at once when none is out.
fn requestApi(label: []const u8, method: []const u8, path: ?[]const u8, body: ?[]const u8, then: ApiThen) void {
    const p = path orelse return setCommandError("This repository is not on GitHub.");
    if (!github.signedIn()) return setCommandError("Connect GitHub first: Settings › GitHub.");
    const call: ApiCall = .{
        .label = label,
        .method = method,
        .path = gpa.dupe(u8, p) catch return,
        .body = if (body) |b| gpa.dupe(u8, b) catch null else null,
        .then = then,
    };
    api_queue.append(gpa, call) catch return freeCall(call);
    if (api_job == null) startNextApi();
}

/// A GraphQL mutation, `variables` a JSON object.
fn requestGraphql(label: []const u8, query: []const u8, variables: []const u8, then: ApiThen) void {
    const body = github.graphqlBody(gpa, query, variables) catch return;
    defer gpa.free(body);
    requestApi(label, "POST", "/graphql", body, then);
}

fn freeCall(call: ApiCall) void {
    gpa.free(call.path);
    if (call.body) |b| gpa.free(b);
}

fn startNextApi() void {
    if (api_queue.items.len == 0) return;
    const call = api_queue.orderedRemove(0);
    defer freeCall(call);
    api_job = github.start(if (repo_path.items.len > 0) repo_path.items else ".", call.method, call.path, call.body) catch {
        clearApiQueue();
        return setCommandError("Could not run curl. Is it installed?");
    };
    api_label = call.label;
    api_then = call.then;
    clearCommandError();
}

fn clearApiQueue() void {
    for (api_queue.items) |c| freeCall(c);
    api_queue.clearRetainingCapacity();
    api_fetch_after = false;
}

/// Land a finished call: GitHub's words if it failed — and the rest of the
/// run dropped — else what it sets off, the next call, and once the run is
/// done the requests read again.
fn collectApi() void {
    const w = api_job orelse return;
    if (!w.finished()) return;
    defer {
        w.deinit(app_io);
        api_job = null;
        api_label = "";
    }
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const failed: ?[]const u8 = if (!w.ok)
        (if (w.err.items.len > 0) a.allocator().dupe(u8, w.err.items) catch "curl failed." else "curl failed.")
    else
        github.failure(a.allocator(), github.split(w.out));
    // A branch already deleted is what was asked for; and a failure there
    // does not keep the list from being read again.
    if (failed != null and api_then == .branch_after_merge) {
        if (api_queue.items.len > 0) return startNextApi();
        refreshRequests();
        if (pr_selected) |n| pr.loadDetail(repo_path.items, n);
        return;
    }
    if (failed) |why| {
        clearApiQueue();
        setCommandError(why);
        // The dialog stays, with what went wrong, to try again.
        pr_creating = false;
        pr_created = 0;
        return;
    }
    switch (api_then) {
        .none => {},
        .clear_comment => pr_comment.clearRetainingCapacity(),
        .clear_reply => {
            pr_reply.clearRetainingCapacity();
            pr_reply_id.clearRetainingCapacity();
        },
        .ask_reviewers => askReviewers(github.split(w.out).body),
        .gone => {
            pr.markGone(api_gone_number);
            if (pr.detail) |*d| if (d.number == api_gone_number) {
                d.state = api_gone_state;
            };
        },
        .branch_after_merge => {},
    }
    if (api_queue.items.len > 0) return startNextApi();
    // A request just made, its reviewers and labels set: open it, in the
    // list read again with it.
    if (pr_created != 0) {
        const n = pr_created;
        pr_created = 0;
        pr_creating = false;
        pr_new_open = false;
        new_tab_open = false;
        pr_filter = .open;
        active_view = .pulls;
        refreshRequests();
        return selectRequest(n);
    }
    refreshRequests();
    if (pr_selected) |n| pr.loadDetail(repo_path.items, n);
    if (api_fetch_after) {
        api_fetch_after = false;
        requestNetwork("Fetching", tab_strip.fetchAllArgs(true));
        tab_strip.job_quiet = action == .network;
    }
}

/// After a request was created: its reviewers, assignees and labels, by the
/// number GitHub gave it.
fn askReviewers(body: []const u8) void {
    defer {
        api_reviewers.clearRetainingCapacity();
        api_assignees.clearRetainingCapacity();
        api_labels.clearRetainingCapacity();
    }
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const made = std.json.parseFromSliceLeaky(struct { number: u32 = 0 }, a.allocator(), body, .{ .ignore_unknown_fields = true }) catch return;
    if (made.number == 0) return;
    // Opened once the calls below are done, with what they set on it.
    pr_created = made.number;
    if (api_reviewers.items.len + api_assignees.items.len + api_labels.items.len == 0) return;
    var path: [512]u8 = undefined;
    if (api_reviewers.items.len > 0) {
        const reviewers = std.fmt.allocPrint(a.allocator(), "{{\"reviewers\":{s}}}", .{api_reviewers.items}) catch return;
        requestApi("Asking for reviews", "POST", apiPath(&path, "/pulls/{d}/requested_reviewers", .{made.number}), reviewers, .none);
    }
    if (api_assignees.items.len > 0) {
        const assignees = std.fmt.allocPrint(a.allocator(), "{{\"assignees\":{s}}}", .{api_assignees.items}) catch return;
        requestApi("Assigning", "POST", apiPath(&path, "/issues/{d}/assignees", .{made.number}), assignees, .none);
    }
    if (api_labels.items.len > 0) {
        const labels = std.fmt.allocPrint(a.allocator(), "{{\"labels\":{s}}}", .{api_labels.items}) catch return;
        requestApi("Labelling", "POST", apiPath(&path, "/issues/{d}/labels", .{made.number}), labels, .none);
    }
}

/// `{"k":"v",…}` from pairs of strings; into `a`.
fn jsonFields(a: std.mem.Allocator, pairs: []const [2][]const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '{') catch return "{}";
    for (pairs, 0..) |kv, i| {
        if (i > 0) out.append(a, ',') catch return "{}";
        github.jsonString(a, &out, kv[0]) catch return "{}";
        out.append(a, ':') catch return "{}";
        github.jsonString(a, &out, kv[1]) catch return "{}";
    }
    out.append(a, '}') catch return "{}";
    return out.items;
}

/// "a, b ,c" as a JSON list of strings; into `a`.
fn jsonList(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return "[]";
    var it = std.mem.tokenizeAny(u8, text, ", \t\n");
    var first = true;
    while (it.next()) |word| {
        if (!first) out.append(a, ',') catch return "[]";
        first = false;
        github.jsonString(a, &out, word) catch return "[]";
    }
    out.append(a, ']') catch return "[]";
    return out.items;
}

/// A request checked out, as `gh pr checkout` does it.
///
/// From this repository: its branch fetched, then a local one tracking it —
/// made, or switched to and fast-forwarded, so an old checkout is brought up
/// to date rather than left behind. From a fork: fetched by the request's
/// own ref into `pr/N`, never into a branch of yours of the same name — a
/// fork's `main` is not your `main`.
fn checkoutRequest(number: u32, branch: []const u8, fork: bool) void {
    if (branch.len == 0) return setCommandError("GitHub did not say which branch that request is.");
    const remote = defaultRemote() orelse return setCommandError("There is no remote to fetch it from.");
    if (midOperation()) return setCommandError("Finish or abort what is under way first.");
    if (fork) {
        var spec_buf: [32]u8 = undefined;
        requestNetwork("Fetching", &.{ "fetch", remote, std.fmt.bufPrint(&spec_buf, "pull/{d}/head", .{number}) catch return });
        queueRequestBranch(number, branch, remote, true);
    } else {
        requestNetwork("Fetching", &.{ "fetch", remote, branch });
        queueRequestBranch(number, branch, remote, false);
    }
}

/// After the fetch: onto the request's branch, made or fast-forwarded.
fn queueRequestBranch(number: u32, branch: []const u8, remote: []const u8, fork: bool) void {
    var local_buf: [32]u8 = undefined;
    const local = if (fork) std.fmt.bufPrint(&local_buf, "pr/{d}", .{number}) catch return else branch;
    var tip_buf: [512]u8 = undefined;
    const tip = if (fork) "FETCH_HEAD" else std.fmt.bufPrint(&tip_buf, "{s}/{s}", .{ remote, branch }) catch return;
    if (isLocalBranch(local)) {
        queueStep("Checking out", &.{ "switch", local });
        queueStep("Bringing it up to date", &.{ "merge", "--ff-only", tip });
    } else if (fork) {
        queueStep("Checking out", &.{ "switch", "-c", local, tip });
    } else {
        queueStep("Checking out", &.{ "switch", "-c", local, "--track", tip });
    }
}

/// A request with conflicts, or behind its base, brought up to date here:
/// its branch checked out as above, its base fetched, then rebased onto it
/// or merged into it. A conflict stops it in the conflict view, with the
/// bar to go on from; after a rebase, Push is a force push.
fn resolveRequestLocally(d: pr.Detail, rebase: bool) void {
    if (d.fork) return setCommandError("Its branch is in a fork: check it out and bring the base in by hand.");
    const remote = defaultRemote() orelse return setCommandError("There is no remote to fetch it from.");
    if (midOperation()) return setCommandError("Finish or abort what is under way first.");
    if (work) |w| if (w.staged.len > 0 or hasTrackedChanges(w)) {
        return setCommandError("Commit or stash your changes first: the branch is about to change under them.");
    };
    requestNetwork("Fetching", &.{ "fetch", remote, d.base, d.head });
    queueRequestBranch(d.number, d.head, remote, false);
    var base_buf: [512]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "{s}/{s}", .{ remote, d.base }) catch return;
    if (rebase) {
        queueStep("Rebasing", &.{ "rebase", base });
    } else {
        queueStep("Merging", &.{ "merge", "--no-edit", base });
    }
}

/// Changes to tracked files — what a switch or a rebase refuses to run over.
/// Untracked ones are not: git leaves those where they are.
fn hasTrackedChanges(w: git.Work) bool {
    // Unstaged and added is untracked: a new file git does not know yet.
    for (w.unstaged) |change| if (change.status != .added) return true;
    return false;
}

/// What to run once the job out has succeeded, in order: a request fetched,
/// then switched to, then brought up to date. Dropped at the first step
/// that fails — or stops, as a rebase does at a conflict.
const JobStep = struct { label: []const u8, argv: [][]u8 };
var job_steps: std.ArrayList(JobStep) = .empty;

fn queueStep(label: []const u8, args: []const []const u8) void {
    // Only behind a job that was queued.
    if (action != .network) return clearJobSteps();
    const argv = gpa.alloc([]u8, args.len) catch return clearJobSteps();
    for (args, 0..) |arg, i| {
        argv[i] = gpa.dupe(u8, arg) catch {
            for (argv[0..i]) |done| gpa.free(done);
            gpa.free(argv);
            return clearJobSteps();
        };
    }
    job_steps.append(gpa, .{ .label = label, .argv = argv }) catch {
        freeStep(.{ .label = label, .argv = argv });
        clearJobSteps();
    };
}

fn freeStep(step: JobStep) void {
    for (step.argv) |arg| gpa.free(arg);
    gpa.free(step.argv);
}

fn clearJobSteps() void {
    for (job_steps.items) |step| freeStep(step);
    job_steps.clearRetainingCapacity();
}

/// Open `url` in the browser.
pub fn openUrl(url: []const u8) void {
    run.open(app_io, ".", url) catch setCommandError("Could not open the browser.");
}

/// The repository's page on GitHub, `tail` after it, in the browser.
pub fn openOnGithub(comptime tail: []const u8, args: anytype) void {
    if (repo_slug.items.len == 0) return setCommandError("This repository is not on GitHub.");
    var buf: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "https://github.com/{s}", .{repo_slug.items}) catch return;
    const rest = std.fmt.bufPrint(buf[head.len..], tail, args) catch return;
    openUrl(buf[0 .. head.len + rest.len]);
}

fn startJob() void {
    // Copied by the job, and owned here either way.
    defer if (action_input) |bytes| {
        gpa.free(bytes);
        action_input = null;
    };
    const after = action_after;
    action_after = .remote;
    if (repo == null or tab_strip.job != null) return;
    tab_strip.job = run.Job.start(gpa, app_io, repo_path.items, action_argv[0..action_argc], .{ .input = action_input }) catch {
        setCommandError("Could not start git.");
        tab_strip.job_label = "";
        // Left set, the next job's failure would be swallowed as a quiet one.
        tab_strip.job_quiet = false;
        return;
    };
    job_after = after;
    clearCommandError();
}

/// What a job does once its outcome is folded in.
const JobAfter = enum {
    /// It went to a remote or came from one: the pull requests are read again.
    remote,
    /// The repository's own — a stash: GitHub has nothing new to say.
    local,
    /// A commit: `commitLanded`.
    commit,
};
/// For the job out, and for the one asked for and not yet started.
pub var job_after: JobAfter = .remote;
var action_after: JobAfter = .remote;

/// As `requestNetwork`, for a command of the repository's own.
pub fn requestLocal(label: []const u8, args: []const []const u8) void {
    requestNetwork(label, args);
    if (action == .network) action_after = .local;
}

/// Start a networked command now, from inside `runAction` — for the ones that
/// first went through a confirmation or a prompt, which already were the
/// deferred action.
fn startNetwork(label: []const u8, args: []const []const u8) void {
    // A confirmed force push dropped here has to say so.
    if (tab_strip.job != null) return setCommandError(BUSY);
    if (!setArgv(args)) return;
    tab_strip.job_label = label;
    startJob();
}

/// As `startNetwork`, for a command of the repository's own, with what to
/// do once it lands.
pub fn startLocal(label: []const u8, args: []const []const u8, after: JobAfter) void {
    if (tab_strip.job != null) return setCommandError(BUSY);
    action_after = after;
    startNetwork(label, args);
}

/// Where a running clone is going, owned. Set while that job is out; it is the
/// one job with no repository behind it, and it opens one when it lands.
var clone_dest: std.ArrayList(u8) = .empty;

pub fn startClone(url: []const u8, dest: []const u8) void {
    if (tab_strip.job != null) return;

    clone_dest.clearRetainingCapacity();
    clone_dest.appendSlice(gpa, dest) catch return;

    // From the process's own directory: there may be no repository to run in,
    // and a relative destination then means what it does in a terminal.
    tab_strip.job = run.Job.start(gpa, app_io, ".", &.{ "clone", "--", url, dest }, .{}) catch {
        clone_dest.clearRetainingCapacity();
        setCommandError("Could not start git.");
        return;
    };
    tab_strip.job_label = "Cloning";
    clearCommandError();
}

/// Pick up a finished network command.
///
/// On the UI thread, and only between frames: it rebuilds the snapshots every
/// panel is iterating, which is the same rule `runAction` follows.
fn collectJob() void {
    const running = tab_strip.job orelse return;
    if (!running.finished()) return;

    if (clone_dest.items.len > 0) {
        tab_strip.job = null;
        tab_strip.job_label = "";
        defer clone_dest.clearRetainingCapacity();

        var result = running.finish(gpa, app_io) orelse return setCommandError("Could not run git. Is it on your PATH?");
        defer result.deinit(gpa);
        if (!result.ok) return setCommandError(if (result.message.len > 0) result.message else "git clone failed.");

        clearCommandError();
        tab_strip.openAndRemember(clone_dest.items);
        return;
    }

    // Read before `finish`, which frees the copy: the repository can be closed
    // or swapped while a fetch is in flight, and that fetch has nothing to say
    // about whatever is on screen now.
    const still_current = repo != null and std.mem.eql(u8, running.cwd, repo_path.items);

    tab_strip.job = null;
    // Its words go on over the changes while they are read again after it.
    // A literal, as every job's label is: it outlives the job.
    command_label = if (tab_strip.job_label.len > 0) tab_strip.job_label else "Reading the changes";
    tab_strip.job_label = "";
    const quiet = tab_strip.job_quiet;
    tab_strip.job_quiet = false;
    const after = job_after;
    job_after = .remote;

    var outcome = running.finish(gpa, app_io);
    if (!still_current) {
        if (outcome) |*o| o.deinit(gpa);
        return;
    }
    if (quiet) {
        if (outcome) |*o| {
            if (!o.ok) {
                o.deinit(gpa);
                return;
            }
        } else return;
    }

    const succeeded = if (outcome) |o| o.ok else false;
    applyOutcome(outcome);
    switch (after) {
        .local => return,
        .commit => return commitLanded(),
        .remote => {},
    }
    // The rest of what was asked — a request fetched, then switched to,
    // then brought up to date — a step at a time, each once the one before
    // went well.
    if (job_steps.items.len > 0) {
        if (succeeded) {
            const step = job_steps.orderedRemove(0);
            defer freeStep(step);
            startNetwork(step.label, @ptrCast(step.argv));
        } else clearJobSteps();
    }
    // Whatever went to the remote may have opened, merged or closed one.
    refreshRequests();
    if (pr_selected) |n| pr.loadDetail(repo_path.items, n);
}

/// Fold the result of a command back into the UI. Shared by the synchronous
/// path and by a job coming back off another thread.
fn applyOutcome(outcome: ?run.Outcome) void {
    var result = outcome orelse {
        setCommandError("Could not run git. Is it on your PATH?");
        return;
    };
    defer result.deinit(gpa);

    if (result.ok) {
        clearCommandError();
    } else if (stoppedAtConflict(result.message)) {
        // The operation doing what it should: the toolbar says what is under
        // way, and the first conflicted file opens once the changes are read.
        clearCommandError();
        open_first_conflict = true;
    } else {
        setCommandError(if (result.message.len > 0) result.message else "git failed.");
    }

    // Both, unconditionally, and on failure too: `poll` only refreshes the
    // history when HEAD moved, and plenty of commands change refs without
    // moving it — a fetch being the obvious one, and a merge that stopped on a
    // conflict being the one that hides its controls if this is skipped.
    graph_view.refreshHistory();
    workChanged(command_label);
    command_label = "Reading the changes";
}

/// Whether a failed command stopped a merge, rebase, cherry-pick or revert
/// at a conflict — git's way of handing it over — rather than failing.
fn stoppedAtConflict(message: []const u8) bool {
    const r = repo orelse return false;
    if (r.state() == .none) return false;
    for ([_][]const u8{ "CONFLICT", "could not apply", "fix conflicts" }) |sign| {
        if (std.mem.indexOf(u8, message, sign) != null) return true;
    }
    return false;
}

/// Set when an operation stopped at a conflict: the first conflicted file
/// is opened as soon as the changes are read again.
var open_first_conflict = false;

/// Run a git command in the repository and fold the result back into the UI.
pub fn gitDo(args: []const []const u8) void {
    gitDoInput(args, null);
}

/// As `gitDo`, with `input` on the command's standard input — which is how a
/// single hunk is staged: `git apply --cached -` reading a patch Zit rebuilt.
fn gitDoInput(args: []const []const u8, input: ?[]const u8) void {
    if (repo == null) return;

    const outcome = run.gitInput(gpa, app_io, repo_path.items, args, input) catch null;
    command_label = commandLabel(args);
    applyOutcome(outcome);
}

/// Compose a rebase of every commit from HEAD down to `onto`, which stays where
/// it is — exactly the set `git rebase -i <onto>` replays. Null means down to
/// the root, which git spells `--root`.
pub fn beginRebase(onto: ?git.Oid) void {
    const h = history orelse return;
    clearSelection();

    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    var id = h.head_oid orelse {
        arena.deinit();
        setCommandError("Nothing is checked out to rebase.");
        return;
    };

    var reached = false;
    var guard: usize = 0;
    while (guard <= MAX_REBASE_STEPS) : (guard += 1) {
        if (onto) |stop| {
            if (git.oidEql(id, stop)) {
                reached = true;
                break;
            }
        }

        const at = h.indexOf(id) orelse break;
        const commit = h.commits[at];

        // `rebase -i` without --rebase-merges drops merges and replays the
        // side's commits in their place; a `pick` of one stops it with "is a
        // merge but no -m option". Neither is what this list would show.
        if (commit.parents.len > 1) {
            arena.deinit();
            clearRebase();
            setCommandError("There is a merge in that range; an interactive rebase here would flatten it.");
            return;
        }

        rebase_steps.append(gpa, .{
            .id = commit.id,
            .summary = a.dupe(u8, commit.summary) catch break,
            .action = .pick,
        }) catch break;

        // The root commit has no parent to replay onto, which is the one case
        // git needs telling about — but only when the root is what was asked
        // for. Reaching it while still looking for `onto` means the walk ran
        // off the end without ever meeting it, so it is not on this line.
        if (commit.parents.len == 0) {
            if (onto == null) {
                reached = true;
                rebase_root = true;
            }
            break;
        }
        id = commit.parents[0];
    }

    // First parents from HEAD is the line git replays. A commit off that line
    // is on another branch, and "rebase onto it" means something else — which
    // the branch menu already offers.
    if (!reached or rebase_steps.items.len == 0) {
        arena.deinit();
        clearRebase();
        setCommandError("That commit is not on the current branch's first-parent line.");
        return;
    }

    rebase_arena = arena;
    if (!rebase_root) rebase_base_len = git.oidHex(onto.?, &rebase_base).len;
    selection = .rebase;
}

/// Hand the composed list to `git rebase -i` and let it run.
fn runRebase() void {
    const r = repo orelse return;
    if (rebase_steps.items.len == 0) return;

    // Oldest first: git replays a todo list top to bottom, the reverse of the
    // order the graph shows them in.
    var ordered: std.ArrayList(git.RebaseStep) = .empty;
    defer ordered.deinit(gpa);
    var i = rebase_steps.items.len;
    while (i > 0) {
        i -= 1;
        ordered.append(gpa, rebase_steps.items[i]) catch return;
    }

    const todo = git.rebaseTodo(gpa, ordered.items) catch return;
    defer gpa.free(todo);

    var todo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const todo_path = std.fmt.bufPrint(&todo_path_buf, "{s}zit-rebase-todo", .{r.gitdir()}) catch {
        setCommandError("That repository's path is too long to write a todo list into.");
        return;
    };

    std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = todo_path, .data = todo }) catch {
        setCommandError("Could not write the rebase todo list.");
        return;
    };

    // How a GUI drives `rebase -i` without an editor: git runs `sequence.editor`
    // with the todo file as its argument, so `cp <ours>` overwrites it with the
    // list composed above. git always launches an editor through a shell, hence
    // the quoting.
    var quoted_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const quoted = run.shellQuote(&quoted_buf, todo_path) orelse {
        setCommandError("That repository's path is too long to quote.");
        return;
    };

    var cfg_buf: [std.fs.max_path_bytes + 96]u8 = undefined;
    const cfg = std.fmt.bufPrint(&cfg_buf, "sequence.editor=cp {s}", .{quoted}) catch return;

    // `core.editor=true` covers the message editor a squash opens: `true` exits
    // 0, and git keeps the combined message it had already prepared.
    if (rebase_root) {
        gitDo(&.{ "-c", "core.editor=true", "-c", cfg, "rebase", "-i", "--root" });
    } else {
        gitDo(&.{ "-c", "core.editor=true", "-c", cfg, "rebase", "-i", rebase_base[0..rebase_base_len] });
    }

    // git has its own copy of the list by now, if it started at all.
    std.Io.Dir.cwd().deleteFile(app_io, todo_path) catch {};

    // Refused before it began — a dirty tree, say: the plan stays on screen,
    // to run again once that is sorted. Otherwise it finished or stopped on
    // a conflict, the toolbar takes it from there, and the list is done.
    if (tab_strip.command_error != null and r.state() == .none) return;
    clearSelection();
}

/// Ctrl+W, from the keyboard or the palette: the new-tab page when it is up —
/// it is what is on screen — and only otherwise the repository under it.
fn closeShownTab() void {
    if (new_tab_open) {
        new_tab_open = false;
    } else if (active_view != .graph) {
        active_view = .graph;
    } else requestTab(.{ .close = tab_strip.active_tab });
}

pub fn requestTab(what: TabAction) void {
    if (action != .none) return;
    tab_action = what;
    action = .tabs;
}

fn requestOpenKnown(path: []const u8) void {
    if (action != .none) return;
    const owned = gpa.dupe(u8, path) catch return;
    tab_action = .{ .open = owned };
    action = .tabs;
}

fn runTabAction() void {
    const what = tab_action;
    tab_action = .none;

    switch (what) {
        .none => {},
        .select => |i| tab_strip.selectTab(i),
        .close => |i| tab_strip.closeTab(i),
        .select_group => |i| tab_strip.selectGroup(i),
        .close_group => |i| tab_strip.closeGroup(i),
        .select_in => |gt| tab_strip.selectTabIn(gt[0], gt[1]),
        .close_in => |gt| tab_strip.closeTabIn(gt[0], gt[1]),
        .group_toggle => |g| if (g < tab_strip.groups.items.len) {
            tab_strip.groups.items[g].collapsed = !tab_strip.groups.items[g].collapsed;
            tab_strip.saveWorkspace();
        },
        .group_color => |gc| if (gc[0] < tab_strip.groups.items.len) {
            tab_strip.groups.items[gc[0]].color = @intCast(gc[1]);
            tab_strip.saveWorkspace();
        },
        .ungroup => |g| tab_strip.ungroup(g),
        .tab_to => |m| tab_strip.moveTab(m[0], m[1], m[2]),
        .tab_at => |m| tab_strip.moveTabTo(m[0], m[1], m[2], m[3]),
        .tab_end => |m| tab_strip.tabToEnd(m[0], m[1]),
        .select_ws => |w| selectWorkspace(w),
        .close_ws => |w| deleteWorkspace(w),
        .workspace_named => applyWorkspaceDialog(),
        .tab_out => |gt| tab_strip.ungroupTab(gt[0], gt[1]),
        .open => |path| {
            defer gpa.free(path);
            tab_strip.openAndRemember(path);
        },
    }
}

pub fn requestResolve(index: usize, side: git.ConflictSide) void {
    if (action != .none) return;
    action_conflict = index;
    action_side = side;
    action = .resolve;
}

/// Rewrite the conflicted file with one region replaced by the chosen side.
///
/// Nothing is staged here. The file still has to look right, and marking it
/// resolved is a separate, deliberate click — same as resolving in an editor.
fn runResolve() void {
    if (action_conflict >= conflicts.len) return;
    const next = git.resolveConflict(gpa, conflict_text, conflicts[action_conflict], action_side) catch {
        setCommandError("Out of memory resolving that conflict.");
        return;
    };
    defer gpa.free(next);
    _ = writeConflictFile(next, true);
}

/// Every region that resolves on its own, at once: each keeps the side that
/// changed it, line by line at the finest. The file written in one pass —
/// one region at a time was a copy of all of it for each, 345 ms for 250
/// regions of a 1.3 MB lockfile.
fn runResolveSafe() void {
    const with = gpa.alloc(?[]const u8, conflicts.len) catch return;
    defer gpa.free(with);
    @memset(with, null);
    defer for (with) |w| if (w) |t| gpa.free(t);
    for (conflicts, with) |region, *w| {
        if (git.autoResolve(gpa, region) catch null) |auto| w.* = auto.text;
    }
    const text = git.replaceRegions(gpa, conflict_text, conflicts, with) catch return;
    defer gpa.free(text);
    _ = writeConflictFile(text, true);
}

/// U and Ctrl+Z in a conflicted file: the file as it was before the last pick.
fn runUndoResolve() void {
    const step = resolve_undo.pop() orelse return;
    defer step.deinit(gpa);
    const previous = (git.spliceUndo(gpa, conflict_text, step) catch return) orelse {
        // Edited since, another way than a pick: the picks before it no
        // longer fit it.
        clearResolveUndo();
        setCommandError("The file changed since that pick: there is nothing to take back.");
        return;
    };
    defer gpa.free(previous);
    _ = writeConflictFile(previous, false);
}

/// Write `next` over the open conflicted file, keeping what it was for U to
/// put back. Refused when the file changed on disk since it was shown:
/// "Open this file" invites an edit in another editor, and writing the
/// older copy over it would lose that edit without a word.
fn writeConflictFile(next: []const u8, keep_undo: bool) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = selectedAbsPath(&path_buf) orelse return false;

    const on_disk = std.Io.Dir.cwd().readFileAlloc(app_io, abs, gpa, .limited(MAX_CONFLICT_BYTES)) catch null;
    defer if (on_disk) |d| gpa.free(d);
    if (on_disk == null or !std.mem.eql(u8, on_disk.?, conflict_text)) {
        diff_stale = true;
        setCommandError("The file changed on disk since it was shown: here it is as it is now. Pick again.");
        return false;
    }

    if (keep_undo) {
        const step = git.spliceBetween(gpa, conflict_text, next) catch return false;
        if (resolve_undo.items.len == MAX_RESOLVE_UNDO) resolve_undo.orderedRemove(0).deinit(gpa);
        resolve_undo.append(gpa, step) catch {
            step.deinit(gpa);
            return false;
        };
    }
    std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = abs, .data = next }) catch {
        setCommandError("Could not write that file back.");
        return false;
    };

    clearCommandError();
    // The offsets of every region after the one just resolved have moved, so
    // the list is rebuilt rather than patched.
    diff_stale = true;
    workChanged("Resolving");
    return true;
}

/// The whole file as one side has it, staged: `checkout --ours` or
/// `--theirs`, then `add` — or, where that side deleted it, `rm`. The
/// next conflicted file opens after it.
fn runTakeFile() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (selected_path.items.len > path_buf.len) return;
    @memcpy(path_buf[0..selected_path.items.len], selected_path.items);
    const file = path_buf[0..selected_path.items.len];
    const side = action_side;

    const deleted = (conflict_kind == .deleted_by_us and side == .ours) or (conflict_kind == .deleted_by_them and side == .theirs);
    if (deleted) {
        gitDo(&.{ "--literal-pathspecs", "rm", "-q", "--", file });
    } else {
        // Deleted on the other side: what is on disk is already this one's.
        if (conflict_kind != .deleted_by_us and conflict_kind != .deleted_by_them) {
            gitDo(&.{ "--literal-pathspecs", "checkout", if (side == .theirs) "--theirs" else "--ours", "--", file });
            if (tab_strip.command_error != null) return;
        }
        gitDo(&.{ "--literal-pathspecs", "add", "--", file });
    }
    if (tab_strip.command_error != null) return;
    clearResolveUndo();
    open_first_conflict = true;
    workChanged("Resolving");
}

/// A file with nothing left to resolve, staged, and the next one opened.
fn runStageNext() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (selected_path.items.len > path_buf.len) return;
    @memcpy(path_buf[0..selected_path.items.len], selected_path.items);
    const file = path_buf[0..selected_path.items.len];
    if (commit_view.markersLeft(file)) return ask(.stage_markers, file);
    gitDo(&.{ "--literal-pathspecs", "add", "--", file });
    if (tab_strip.command_error != null) return;
    clearResolveUndo();
    open_first_conflict = true;
    workChanged("Resolving");
}

/// Take back whatever last moved HEAD, as the reflog tells it.
pub fn requestUndo() void {
    const h = history orelse return;
    // Mid-rebase the reflog's last move is a step of it, and resetting there
    // leaves the rebase replaying onto the wrong commit: Abort is the undo.
    if (h.state != .none) return setCommandError("Finish or abort what is under way first: an undo in the middle of it would break it.");
    const move = h.last_move orelse return setCommandError("Nothing to undo yet.");
    var sha: [41]u8 = undefined;
    var argv: [4][]const u8 = undefined;
    const args = git.undoArgs(move.message, git.oidHex(move.old, &sha), isLocalBranch, &argv) orelse
        return setCommandError("Zit cannot undo that.");
    // Where HEAD stood before this undo: while the reflog's last move is
    // still the one leaving it, that move is the undo, and taking it back
    // is the redo.
    redo_from = h.head_oid;
    const what = std.mem.trim(u8, move.message, " \r\n");
    redo_what_len = @min(what.len, redo_what.len);
    @memcpy(redo_what[0..redo_what_len], what[0..redo_what_len]);
    request(args);
}

/// HEAD before the last undo Zit made, while that undo can be redone.
var redo_from: ?git.Oid = null;
/// What that undo took back, in the reflog's words: Redo's hover.
var redo_what: [160]u8 = undefined;
var redo_what_len: usize = 0;

/// Whether Redo has something to take back: an undo made here, and nothing
/// moved HEAD since.
pub fn canRedo() bool {
    const h = history orelse return false;
    const from = redo_from orelse return false;
    const move = h.last_move orelse return false;
    return git.oidEql(move.old, from);
}

/// Undo's hover: what it would take back, as the reflog says it.
pub fn undoHint() []const u8 {
    const h = history orelse return "Undo";
    const move = h.last_move orelse return "Nothing to undo yet";
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "Undo \u{201C}{s}\u{201D} — Ctrl+Z", .{std.mem.trim(u8, move.message, " \r\n")}) catch "Undo";
}

/// Redo's hover: what the last undo took back, or why there is nothing.
pub fn redoHint() []const u8 {
    if (!canRedo()) return "Nothing to redo: undo something first";
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "Redo \u{201C}{s}\u{201D} — Ctrl+Shift+Z", .{redo_what[0..redo_what_len]}) catch "Redo";
}

/// Ctrl+Shift+Z: take back the last undo — an undo undone, which is what
/// `requestUndo` already does to it — and only that: after anything else
/// has moved HEAD there is nothing to redo.
pub fn requestRedo() void {
    const h = history orelse return;
    const from = redo_from orelse return setCommandError("Nothing to redo.");
    const move = h.last_move orelse return setCommandError("Nothing to redo.");
    if (!git.oidEql(move.old, from)) {
        redo_from = null;
        return setCommandError("Nothing to redo.");
    }
    requestUndo();
    // A redo is not itself undone by the next Ctrl+Shift+Z.
    redo_from = null;
}

pub fn isLocalBranch(name: []const u8) bool {
    const h = history orelse return false;
    for (h.refs) |ref| {
        if (ref.kind == .local and std.mem.eql(u8, ref.name, name)) return true;
    }
    return false;
}

pub fn checkout(ref: git.Ref) void {
    // `switch`, not `checkout`: `checkout` also takes paths, so a branch whose
    // name matches a file is ambiguous, and `checkout -- <name>` means the
    // opposite of what it looks like — restore that *path* from the index.
    //
    // For a remote-tracking name only the remote is stripped ("origin/feat/x"
    // -> "feat/x"), and `switch` then does the right thing in both cases: it
    // moves to the local branch if there is one, and creates a tracking branch
    // if there is not.
    const name = if (ref.kind == .remote) splitRemoteRef(ref.name).branch else ref.name;

    // A job, with its pill in the status bar: rewriting the working tree takes
    // long enough on Windows to freeze the window if it is waited for here.
    requestNetwork("Switching branch", &.{ "switch", name });
}

pub fn setCommandError(message: []const u8) void {
    clearCommandError();
    tab_strip.command_error = gpa.dupe(u8, message) catch null;
}

pub fn clearCommandError() void {
    if (tab_strip.command_error) |m| gpa.free(m);
    tab_strip.command_error = null;
}

pub fn ask(kind: Confirm.Kind, arg: []const u8) void {
    clearConfirm();
    confirm = .{ .kind = kind, .arg = gpa.dupe(u8, arg) catch return };
}

pub fn clearConfirm() void {
    if (confirm) |c| gpa.free(c.arg);
    confirm = null;
}

/// Run whatever was confirmed. Every branch here destroys work on purpose.
fn runConfirmed() void {
    const c = confirm orelse return;
    switch (c.kind) {
        .discard => doDiscard(c.arg),
        .reset_hard => gitDo(&.{ "reset", "--hard", c.arg }),
        .stash_drop => rebase_view.stashDo("drop", c.arg),
        .discard_hunk => gitDoInput(&.{ "apply", "--reverse", "-" }, c.arg),
        // `--force-with-lease`, never `--force`: it refuses when the remote has
        // moved since the last fetch, which is the push that loses someone
        // else's work. The quiet fetch keeps moving that "last fetch" up to
        // the remote, so on its own the lease always holds; `--force-if-includes`
        // also wants what is being overwritten to be in this branch's own
        // history. An upstream is set up the way the toolbar's push does it.
        .force_push => startNetwork("Force pushing", &.{ "-c", "push.autoSetupRemote=true", "push", "--force-with-lease", "--force-if-includes" }),
        .delete_branch_force => gitDo(&.{ "branch", "-D", c.arg }),
        .delete_remote_branch => {
            const split = splitRemoteRef(c.arg);
            // The full name: a tag called the same would make the bare one
            // ambiguous.
            var buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "refs/heads/{s}", .{split.branch}) catch split.branch;
            startNetwork("Deleting", &.{ "push", split.remote, "--delete", full });
        },
        .delete_remote_tag => if (defaultRemote()) |remote| {
            var buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "refs/tags/{s}", .{c.arg}) catch c.arg;
            startNetwork("Deleting", &.{ "push", remote, "--delete", full });
        } else setCommandError("There is no remote to delete it from."),
        .restore_file => {
            const sep = std.mem.indexOfScalar(u8, c.arg, ' ') orelse return clearConfirm();
            gitDo(&.{ "--literal-pathspecs", "checkout", c.arg[0..sep], "--", c.arg[sep + 1 ..] });
        },
        .remove_worktree => gitDo(&.{ "worktree", "remove", c.arg }),
        .merge_request => {
            var path: [512]u8 = undefined;
            const number = std.fmt.parseInt(u32, c.arg, 10) catch return clearConfirm();
            // In the dropdown's order: a merge commit, squash, rebase.
            const method = ([_][]const u8{ "merge", "squash", "rebase" })[@min(pr_merge_method, 2)];
            // With the commit it was shown at: GitHub refuses if the branch
            // moved since, rather than merge what nobody looked at.
            const sha = if (pr.detail) |d| (if (d.number == number) d.head_sha else "") else "";
            const body = (if (sha.len > 0)
                std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"merge_method\":\"{s}\",\"sha\":\"{s}\"}}", .{ method, sha })
            else
                std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"merge_method\":\"{s}\"}}", .{method})) catch return clearConfirm();
            api_gone_number = number;
            api_gone_state = "MERGED";
            requestApi("Merging", "PUT", apiPath(&path, "/pulls/{d}/merge", .{number}), body, .gone);
            // Its branch after it, as the toggle asked: GitHub's ref, by name —
            // unless it lives in a fork, which is not this repository's to delete.
            if (pr_delete_branch) if (pr.detail) |d| if (d.number == number and d.head.len > 0 and !d.fork) {
                var ref_path: [512]u8 = undefined;
                requestApi("Deleting the branch", "DELETE", apiPath(&ref_path, "/git/refs/heads/{s}", .{d.head}), null, .branch_after_merge);
            };
            api_fetch_after = true;
        },
        .close_request => {
            var path: [512]u8 = undefined;
            const number = std.fmt.parseInt(u32, c.arg, 10) catch return clearConfirm();
            api_gone_number = number;
            api_gone_state = "CLOSED";
            requestApi("Closing", "PATCH", apiPath(&path, "/pulls/{d}", .{number}), "{\"state\":\"closed\"}", .gone);
        },
        .sign_out => window_chrome.signOutGithub(c.arg),
        .stage_markers => if (c.arg.len == 0)
            requestLocal("Staging", &.{ "add", "-A" })
        else
            request(&.{ "--literal-pathspecs", "add", "--", c.arg }),
        .abort_operation => if (operationCommand()) |cmd| request(&.{ cmd, "--abort" }),
        .skip_step => if (operationCommand()) |cmd| requestLocal("Skipping", &.{ cmd, "--skip" }),
        // `checkout -m` writes the conflict again from the index's three
        // stages: every pick made in the file goes.
        .restart_file => {
            gitDo(&.{ "--literal-pathspecs", "checkout", "-m", "--", c.arg });
            if (tab_strip.command_error == null) clearResolveUndo();
            diff_stale = true;
        },
    }
    clearConfirm();
}

/// The subcommand of the operation under way — `rebase`, `merge`… — whose
/// `--continue`, `--skip` and `--abort` apply; null with none.
pub fn operationCommand() ?[]const u8 {
    const h = history orelse return null;
    return h.state.command();
}

/// Abort and Skip, each asked first: an abort throws away every conflict
/// resolved so far, and a skipped commit is gone from the branch.
fn requestAbortOperation() void {
    if (operationCommand() == null) return;
    ask(.abort_operation, "");
}

fn requestSkipStep() void {
    if (operationCommand() == null) return;
    ask(.skip_step, "");
}

pub fn askName(kind: Prompt.Kind, arg: []const u8) void {
    clearPrompt();
    prompt = .{ .kind = kind, .arg = gpa.dupe(u8, arg) catch return };
}

/// As `askName`, with the field already holding `text` — the current name, for
/// a rename, so a typo is fixed rather than retyped.
pub fn askNameWith(kind: Prompt.Kind, arg: []const u8, text: []const u8) void {
    askName(kind, arg);
    prompt_text.appendSlice(gpa, text) catch {};
}

/// A leading `~/` as a shell would read it. No shell runs these commands, so
/// without this `~/dev/x` makes a directory literally named `~`.
pub fn expandHome(buf: []u8, path: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, path, "~/") and !std.mem.eql(u8, path, "~")) return path;
    const home = homeDir() orelse return path;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, path[1..] }) catch path;
}

/// The user's home folder: HOME, or on Windows, where there is none,
/// USERPROFILE.
pub fn homeDir() ?[]const u8 {
    if (std.c.getenv("HOME")) |h| return std.mem.span(h);
    if (std.c.getenv("USERPROFILE")) |h| return std.mem.span(h);
    return null;
}

/// "first rest", the shape of every two-word prompt. Null unless both are there.
pub fn splitPair(text: []const u8) ?[2][]const u8 {
    const sep = std.mem.indexOfAny(u8, text, " \t") orelse return null;
    const rest = std.mem.trimStart(u8, text[sep..], " \t");
    if (rest.len == 0) return null;
    return .{ text[0..sep], rest };
}

/// Where a branch or tag goes when nothing says otherwise: `origin` if there is
/// one, else the first remote. Null when there are none.
pub fn defaultRemote() ?[]const u8 {
    return firstRemote([]const u8, struct {
        fn pick(r: git.Remote) ?[]const u8 {
            return r.name;
        }
    }.pick);
}

/// "origin/feat/x" -> "origin", "feat/x". Both sides can hold slashes
/// ("team/origin"), so the remote is the longest known one the name starts
/// with; the first slash only when no known remote fits.
pub fn splitRemoteRef(name: []const u8) struct { remote: []const u8, branch: []const u8 } {
    var remote: []const u8 = "";
    if (history) |h| for (h.remotes) |r| {
        if (r.name.len > remote.len and rebase_view.remoteOf(name, r.name)) remote = r.name;
    };
    if (remote.len == 0) {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return .{ .remote = name, .branch = name };
        remote = name[0..slash];
    }
    return .{ .remote = remote, .branch = name[remote.len + 1 ..] };
}

pub fn clearPrompt() void {
    if (prompt) |p| gpa.free(p.arg);
    prompt = null;
    prompt_text.clearRetainingCapacity();
}

/// Run the command the name was for. A failure keeps the bar open with the text
/// still in it, because the usual failure is a name that is already taken.
fn runPrompt() void {
    const p = prompt orelse return;

    const name = std.mem.trim(u8, prompt_text.items, " \t");
    if (name.len == 0) return;

    // A word starting with a dash reaches git as an option, not a name: `-f`
    // as a branch name forces, `--upload-pack=…` as a URL runs a program. No
    // ref, remote, URL or folder asked for here starts with one; git refuses
    // such ref names anyway.
    switch (p.kind) {
        .new_branch, .new_tag, .add_remote, .rename_branch, .rename_remote, .remote_url, .add_worktree => {
            const words = splitPair(name) orelse [2][]const u8{ name, "" };
            if (words[0][0] == '-' or std.mem.startsWith(u8, words[1], "-"))
                return setCommandError("A name cannot start with a dash: git would read it as an option.");
        },
        else => {},
    }

    switch (p.kind) {
        .new_branch => if (p.arg.len > 0)
            gitDo(&.{ "branch", name, p.arg })
        else
            gitDo(&.{ "branch", name }),
        // Signed when set, which makes it annotated: `-s` needs a message,
        // and the tag's name is the obvious one.
        .new_tag => if (commit_prefs.sign_tags)
            (if (p.arg.len > 0) gitDo(&.{ "tag", "-s", "-m", name, name, p.arg }) else gitDo(&.{ "tag", "-s", "-m", name, name }))
        else if (p.arg.len > 0)
            gitDo(&.{ "tag", name, p.arg })
        else
            gitDo(&.{ "tag", name }),
        // "origin git@host:repo.git", in one field: two boxes for two words is
        // a dialog, and this is a bar.
        .add_remote => {
            const sep = std.mem.indexOfAny(u8, name, " \t") orelse {
                setCommandError("A remote needs a name and a URL, separated by a space.");
                return;
            };
            const url = std.mem.trimStart(u8, name[sep..], " \t");
            if (url.len == 0) {
                setCommandError("A remote needs a name and a URL, separated by a space.");
                return;
            }
            gitDo(&.{ "remote", "add", name[0..sep], url });
        },
        .rename_branch => gitDo(&.{ "branch", "-m", p.arg, name }),
        .stash => startLocal("Stashing", &.{ "stash", "push", "-u", "-m", name }, .local),
        .rename_remote => gitDo(&.{ "remote", "rename", p.arg, name }),
        .remote_url => gitDo(&.{ "remote", "set-url", p.arg, name }),
        .add_worktree => {
            const pair = splitPair(name) orelse {
                setCommandError("A worktree needs a folder and a branch, separated by a space.");
                return;
            };
            var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dest = expandHome(&dest_buf, pair[0]);
            if (isLocalBranch(pair[1])) {
                gitDo(&.{ "worktree", "add", dest, pair[1] });
            } else {
                gitDo(&.{ "worktree", "add", "-b", pair[1], dest });
            }
        },
        // Nothing to run and nothing to fail: these only rearrange the strip.
        .new_group => {
            tab_strip.groupTab(name, group_target[0], group_target[1]);
            return clearPrompt();
        },
        .rename_group => {
            tab_strip.renameGroup(group_target[0], name);
            return clearPrompt();
        },
    }

    if (tab_strip.command_error == null) clearPrompt();
}

/// Throw away working-tree changes. Untracked files need `clean`; tracked ones
/// need `restore` — running only one of them silently leaves half the mess.
/// A rename on disk is both: the old name comes back, the new one goes.
///
/// `--literal-pathspecs` on every command given a file's name, here and
/// wherever else one is: a pathspec is a glob, and `pages/[id].tsx` would
/// otherwise take `pages/i.tsx` with it.
///
/// `restore` refuses a pathspec that names nothing git tracks — an untracked
/// file, or a tree holding only those — so it runs only where a tracked change
/// is; and when it fails that is where this stops, rather than `clean`
/// wiping its error and the untracked files going all the same.
fn doDiscard(path: []const u8) void {
    if (hasTrackedChange(path)) {
        if (path.len == 0) {
            gitDo(&.{ "restore", "--worktree", "--", "." });
        } else {
            gitDo(&.{ "--literal-pathspecs", "restore", "--worktree", "--", oldPathOf(.unstaged, path) });
        }
        if (tab_strip.command_error != null) return;
    }
    if (path.len == 0) {
        gitDo(&.{ "clean", "-fd", "--", "." });
    } else {
        gitDo(&.{ "--literal-pathspecs", "clean", "-fd", "--", path });
    }
}

/// Whether the working tree holds a change to a tracked file at `path`, or
/// anywhere when it is empty. Untracked files are the `.added` ones.
fn hasTrackedChange(path: []const u8) bool {
    const w = work orelse return true;
    for (w.unstaged) |change| {
        if (change.status != .added and (path.len == 0 or std.mem.eql(u8, change.path, path))) return true;
    }
    return false;
}

/// Where the change at `path` was renamed from; `path` itself for anything
/// that was not renamed, or is no longer listed.
pub fn oldPathOf(side: git.DiffSide, path: []const u8) []const u8 {
    const w = work orelse return path;
    for (if (side == .staged) w.staged else w.unstaged) |change| {
        if (std.mem.eql(u8, change.path, path)) return change.old_path;
    }
    return path;
}

/// Amend ticked over an empty message: the last commit's, to edit rather than
/// type again — amending is most often fixing a word of it.
pub fn fillFromHead() void {
    if (commit_summary.items.len > 0 or commit_description.items.len > 0) return;
    const r = repo orelse return;
    const head = (history orelse return).head_oid orelse return;
    const whole = r.commitMessage(dvui.currentWindow().arena(), head);
    const nl = std.mem.indexOfScalar(u8, whole, '\n') orelse whole.len;
    commit_summary.appendSlice(gpa, std.mem.trimEnd(u8, whole[0..nl], " \r")) catch return;
    commit_description.appendSlice(gpa, std.mem.trim(u8, whole[nl..], " \t\r\n")) catch {};
}

fn doCommit() void {
    if (commit_summary.items.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = commit_view.commitMessage(arena.allocator()) catch return;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);

    args.append(gpa, "commit") catch return;
    if (amend) args.append(gpa, "--amend") catch return;
    if (commit_prefs.signoff) args.append(gpa, "--signoff") catch return;
    if (commit_prefs.sign) args.append(gpa, "-S") catch return;
    // One `-m` holding the whole message: two would put a blank line between
    // the description and the trailers git reads the co-authors from.
    args.append(gpa, "-m") catch return;
    args.append(gpa, text) catch return;

    // On another thread, with the status bar's pill: a commit runs the hooks
    // and the signing, which can wait on a passphrase, and on Windows even a
    // plain one held the window up.
    commit_sent.clearRetainingCapacity();
    commit_sent.appendSlice(gpa, text) catch {};
    startLocal("Committing", args.items, .commit);
}

/// The message of the commit out on its job. The box stays editable while it
/// runs; when it lands, the box is emptied only if it still says this.
var commit_sent: std.ArrayList(u8) = .empty;

/// A commit's outcome, folded in: the box emptied for the next one, or the
/// identity asked for when git said it has none.
fn commitLanded() void {
    // git's own words for an identity it does not have.
    if (tab_strip.command_error) |message| {
        if (std.mem.indexOf(u8, message, "tell me who you are") != null or std.mem.indexOf(u8, message, "user.email") != null) openIdentity();
        return;
    }
    // Typed into while the commit ran: that is the next message, not this one.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const now = commit_view.commitMessage(arena.allocator()) catch "";
    const unchanged = std.mem.eql(u8, now, commit_sent.items);
    commit_sent.clearRetainingCapacity();
    if (!unchanged) return;
    commit_summary.clearRetainingCapacity();
    commit_description.clearRetainingCapacity();
    amend = false;
    commit_type = null;
    commit_scope.clearRetainingCapacity();
    commit_view.clearCoAuthors();
    template_due = true;
}

// === Frame ===

fn appFrame() !dvui.App.Result {
    tab_strip.in_frame = true;
    defer tab_strip.in_frame = false;
    frame_now_s = @intCast(@divFloor(std.Io.Timestamp.now(app_io, .real).nanoseconds, std.time.ns_per_s));
    // Before anything is collected: a worker finishing after this point
    // wakes the window again rather than finding the flag still set.
    wake_pending.store(false, .release);

    // Before any widget: this rebuilds the snapshots the panels below iterate.
    collectJob();
    collectApi();
    commit_view.collectRepoConfig();
    dialog_views.takeFolder();
    if (collectWorkLoad()) dvui.refresh(null, @src(), null);
    if (graph_view.collectHistoryLoad()) dvui.refresh(null, @src(), null);
    updateWindowTitle();
    // A zoom key that reached dvui rather than `shortcuts` — under a modal,
    // say: bounded and remembered all the same.
    if (dvui.currentWindow().content_scale != tab_strip.zoom) tab_strip.setZoom(dvui.currentWindow().content_scale);
    // The zoom's keys before any widget: a focused text field would claim
    // them, and they mean nothing there. Held down, they repeat, as a
    // browser's do.
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        const ke = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (ke.action == .up) continue;
        if (tab_strip.zoomKey(ke)) |to| {
            e.handled = true;
            tab_strip.setZoom(to);
        }
    }
    no_split = 0;
    all_split = 1;

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    defer root.deinit();

    // What landed since the last frame. Nothing is drawn while it is still
    // out: each worker wakes the window when it finishes (`run.wake`).
    if (avatars.pump()) dvui.refresh(null, @src(), null);
    if (pr.pump()) dvui.refresh(null, @src(), null);
    if (pr.pumpIssues()) dvui.refresh(null, @src(), null);
    if (pr.pumpMeta()) dvui.refresh(null, @src(), null);
    if (pr.pumpDetail()) dvui.refresh(null, @src(), null);
    if (pr.ciPump()) dvui.refresh(null, @src(), null);
    askCi();

    // One timer, hung off the root widget's id, is the whole refresh story.
    const poll_id = root.data().id;
    tab_strip.flushWorkspace(poll_id.update("workspace"));
    // Back in front: whatever the editor just saved shows now, not at the
    // next tick.
    const focused = windowFocused();
    const refocused = focused and !was_focused;
    was_focused = focused;
    // The watcher's word, or the timer's net under it.
    const told = if (watcher) |w| w.take() else false;
    if (watcher) |w| if (w.failed.load(.acquire) and !dialog_views.watcher_failure_logged) {
        dialog_views.watcher_failure_logged = true;
        std.log.warn("stopped watching the repository ({d} folders): polling instead", .{w.count.load(.acquire)});
    };
    if (dvui.timerDoneOrNone(poll_id) or refocused or told) {
        poll();
        dvui.timer(poll_id, pollInterval(focused));
    }

    if (window_chrome.close_requested) return .close;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .window => |we| if (we.action == .close) return .close,
            .app => |ae| if (ae.action == .quit) return .close,
            else => {},
        }
    }

    // The new-tab page takes the window, as GitKraken's does: a repository's
    // toolbar and sidebar have nothing to say about a tab with none in it.
    const start_page = new_tab_open or repo == null;
    tabStrip();
    if (!start_page) window_chrome.titlebar();
    // A name asked for in a dialog; a yes or no in a toast low on the
    // right; a dropped branch's merge or rebase in a menu where it fell.
    dialog_views.promptDialog();
    confirmToast();
    graph_view.dropMenu();

    palette();
    dialog_views.repoDialog();
    identityDialog();
    connectDialog();
    workspaceDialog();
    settingsDialog();
    keysDialog();
    prEditDialog();
    prCreateDialog();
    featuresDialog();
    graph_view.dragGhost();
    dialog_views.forgetDialog();

    if (start_page) {
        startScreen();
    } else {
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = false,
            .padding = dvui.Rect.all(0),
        });
        defer body.deinit();

        var split = dvui.paned(@src(), .{
            .direction = .horizontal,
            // Below this the sidebar is not worth its width and the content
            // takes the window.
            .collapsed_size = 760,
            // Hidden is a ratio of nothing: the seam goes to the left edge
            // and comes back to where it was.
            // The pull-request view has its own list on the left; the
            // branches beside it would be a third column saying nothing.
            .split_ratio = if (leftShown()) &sidebar_split else &no_split,
            // A fixed 1px seam: dvui's dynamic handle widens the gap as the
            // mouse nears, which shoves both panes aside. The cursor is the
            // only sign needed.
            .handle_size = 1,
            .draw_in_deinit = false,
        }, .{ .expand = .both, .background = false });
        defer split.deinit();
        body_width = split.data().contentRect().w;

        if (leftShown() and split.showFirst()) refs_panel.sidebarPane();
        if (split.showSecond()) contentPane();
    }

    statusBar();

    // After every widget, and before the action below runs: a key a text field
    // consumed is already marked handled by the time this sees it.
    shortcuts();

    // After every widget: see `Action`. The frame just drawn was built from the
    // old snapshot, so ask for another one rather than leaving it on screen
    // until the poll timer comes round.
    if (runAction()) dvui.refresh(null, @src(), null);

    if (graph_view.graph_filter_dirty or graph_view.authors_dirty) {
        graph_view.graph_filter_dirty = false;
        graph_view.authors_dirty = false;
        graph_view.refilterHistory();
        dvui.refresh(null, @src(), null);
    }

    showWindowOnce();
    return .ok;
}

var window_shown = false;

/// The window, at the end of its first frame — presented straight after —
/// maximised again if it was when Zit last closed. dvui leaves that to the
/// caller for a window created hidden.
fn showWindowOnce() void {
    if (window_shown or @import("builtin").is_test) return;
    window_shown = true;
    const back = dvui.currentWindow().backend.impl;
    // Zit's own frame: see `hitTest`.
    _ = dvui.backend.c.SDL_SetWindowBordered(back.window, false);
    _ = dvui.backend.c.SDL_SetWindowHitTest(back.window, window_chrome.hitTest, null);
    if (back.window_geometry.state != .normal) _ = dvui.backend.c.SDL_MaximizeWindow(back.window);
    _ = dvui.backend.c.SDL_ShowWindow(back.window);
}

/// What the content area is showing: the history — with the working tree's
/// changes beside it, and a file's diff in its place when one is picked — or,
/// in a tab of their own, the pull requests. One view for both history and
/// changes, as GitKraken has it: nothing to click across to before staging.
const View = enum { graph, pulls };

pub var active_view: View = .graph;

/// The content area, right of the sidebar.
///
/// The two full-window tasks come first: the rebase composer is a list being
/// edited and blame is a file being read, and neither is a view you switch
/// away from by accident.
fn contentPane() void {
    switch (selection) {
        .rebase => return rebase_view.rebasePanel(),
        .blame => return diff_view.blamePanel(),
        else => {},
    }

    switch (active_view) {
        .graph => if (historyLoading()) loadingScreen() else graphView(),
        .pulls => pullsView(),
    }
}

// === Pull requests ===
//
// The list on the left, the one picked on the right in full — what it
// changes, whether its checks pass, the conversation so far — and every
// answer to it from here: comment, approve, ask for changes, merge, close.
// Each answer is a call to GitHub's API (`requestApi`), after which the list
// and the request are read again.

var pr_split: f32 = 0.36;
pub var pr_selected: ?u32 = null;
var pr_comment: std.ArrayList(u8) = .empty;
/// The merge settings' dropdown: merge commit, squash, rebase. A `usize`
/// because that is what a dvui dropdown writes.
var pr_merge_method: usize = 1;
var pr_delete_branch: bool = true;

/// Resolved threads shown too, not only the open ones.
var pr_threads_all: bool = false;
/// The thread whose reply box is open — its node id — and what is in it.
var pr_reply_id: std.ArrayList(u8) = .empty;
var pr_reply: std.ArrayList(u8) = .empty;

pub fn selectRequest(number: u32) void {
    // A review written for one request is never sent to another.
    if (pr_selected != number) pr_comment.clearRetainingCapacity();
    pr_selected = number;
    pr_reply_id.clearRetainingCapacity();
    pr_reply.clearRetainingCapacity();
    pr.clearDetail();
    pr.loadDetail(repo_path.items, number);
}

fn requestNumber(buf: *[12]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{pr_selected orelse 0}) catch "0";
}

fn pullsView() void {
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
var pr_search: std.ArrayList(u8) = .empty;

/// Asked to review by the person signed in to the host, and not answered.
fn waitsOnMe(entry: pr.Request) bool {
    if (window_chrome.me_gh.items.len == 0) return false;
    for (entry.reviewers) |r| if (std.ascii.eqlIgnoreCase(r, window_chrome.me_gh.items)) return true;
    return false;
}

fn requestsToReview() usize {
    var n: usize = 0;
    for (pr.list) |entry| n += @intFromBool(waitsOnMe(entry));
    return n;
}

/// Whether the list's tab and search let `entry` through.
fn requestShown(entry: pr.Request) bool {
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
            if (dialog_views.chipButton(@src(), dvui.entypo.chevron_left, "History — Esc", false)) closePulls();
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
                refreshRequests();
                if (pr_filter == .merged or pr_filter == .closed) pr.refreshPast(repo_path.items, if (pr_filter == .merged) .merged else .closed);
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
        const head = if (history) |h| h.head orelse "" else "";
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
fn stepRequest(delta: i2) void {
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
        if (pickRow(i, it[1], count, pr_filter == it[0], null)) {
            pr_filter = it[0];
            if (it[0] == .merged or it[0] == .closed) pr.refreshPast(repo_path.items, if (it[0] == .merged) .merged else .closed);
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
        if (entry.conflict) tinyBadge(@src(), 1, "conflict", style.danger());
        for (entry.labels[0..@min(entry.labels.len, 2)], 0..) |label, i| tinyBadge(@src(), 10 + i, label.name, labelColor(label.color));
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
fn requestAuthor(login: []const u8) git.Commit {
    const email = if (pr.host == .github)
        std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}@users.noreply.github.com", .{login}) catch ""
    else
        "";
    return .{ .id = std.mem.zeroes(git.Oid), .summary = "", .author = login, .email = email, .time = 0 };
}

/// A label's colour, from the host's hex; the accent where there is none.
fn labelColor(hex: []const u8) dvui.Color {
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
fn sizeMarks(added: u32, removed: u32) void {
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
        if (pr.detail_status != .failed) if (listedRequest(number)) |r| loadingHeader(r);
        return dialog_views.emptyState(@src(), if (pr.detail_status == .failed) "Could not read it." else "Loading…");
    };
    // Read again where it is — the page stays up until the answer replaces
    // it, which frees what `d` points into: asked once the pane is drawn.
    var reload = false;
    defer if (reload) pr.loadDetail(repo_path.items, d.number);
    if (pr_reread_at != 0) {
        if (frame_now_s >= pr_reread_at) {
            pr_reread_at = 0;
            pr.loadDetail(repo_path.items, d.number);
        } else dvui.timer(panel.data().id, PR_REREAD_S * std.time.us_per_s);
    }

    // The whole pane, and where there is the room GitHub's sidebar on its
    // right: who reviews, who it is assigned to, its labels.
    const pane_w = panel.data().contentRect().w;
    const total = @max(320, pane_w - 2 * style.space.xl);
    const side = total >= PR_SIDE_FROM;
    const main_w = if (side) total - PR_SIDE_W - style.space.xl else total;
    // The head and its tabs a banner from one edge of the pane to the other,
    // what they hold set in as far as the page under them is.
    const inset = @max(style.space.sm, (pane_w - total) / 2);
    requestHeader(d, &reload, !side, inset);
    requestTabs(d, inset);

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

            switch (pr_tab) {
                .conversation => requestConversation(d),
                .commits => requestCommits(d),
                .files => requestFiles(d),
                .checks => requestChecks(d),
            }
        }
        if (side) requestSidebar(d);
    }
    scroll.deinit();
}

// === A request's conversation ===
//
// A timeline, as the host's own page has it: the description first, then
// every comment and review in the order they came, each on a line down the
// left with its author's picture; a review with nothing to say a single
// coloured line; a run of reviews from one person folded to its ends. The
// threads on lines of the diff after, then the answer, then the merge.

/// Runs of reviews unfolded, by where they start; for the request below.
var pr_runs_open: u128 = 0;
var pr_runs_for: u32 = 0;

/// One step of a conversation: a comment, or a review.
const Event = struct { note: pr.Note, review: bool };

fn requestConversation(d: pr.Detail) void {
    if (pr_runs_for != d.number) {
        pr_runs_for = d.number;
        pr_runs_open = 0;
        pr_cards.clearRetainingCapacity();
        pr_cards_all = null;
    }
    // How many conversations on lines of the diff are still open; Expand
    // all, Collapse all for a long conversation, where only the last few
    // are open to begin with.
    const many = d.comments.len + d.reviews.len > CARDS_OPEN_AT_END;
    const open_threads = openThreads(d);
    if (many or d.threads.len > 0) {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.sm } });
        defer bar.deinit();
        if (d.threads.len > 0) {
            const hue = if (open_threads > 0) style.get().yellow else style.success();
            dvui.icon(@src(), "threads_icon", if (open_threads > 0) dvui.entypo.chat else dvui.entypo.check, .{ .fill_color = .{ .color = hue } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .w = style.space.sm } });
            if (open_threads > 0) {
                dvui.label(@src(), "{d} open conversation{s}", .{ open_threads, window_chrome.plural(open_threads) }, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            } else {
                dvui.label(@src(), "Every conversation is resolved", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            }
            const settled = d.threads.len - open_threads;
            if (settled > 0) {
                dvui.label(@src(), "· {d} resolved", .{settled}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
                if (dialog_views.linkButtonTagged(@src(), if (pr_threads_all) "Fold them" else "Open them", style.textMuted(), "pr:threads_all")) pr_threads_all = !pr_threads_all;
            }
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (many) {
            if (dialog_views.linkButtonTagged(@src(), "Expand all", style.textMuted(), "pr:expand_all")) {
                pr_cards.clearRetainingCapacity();
                pr_cards_all = true;
            }
            if (dialog_views.linkButtonTagged(@src(), "Collapse all", style.textMuted(), "pr:collapse_all")) {
                pr_cards.clearRetainingCapacity();
                pr_cards_all = false;
            }
        }
    }
    // Which threads a review has shown under it; the rest after the lot.
    const shown_threads = dvui.currentWindow().arena().alloc(bool, d.threads.len) catch return;
    @memset(shown_threads, false);
    var timeline = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false });
    {
        defer timeline.deinit();
        timelineCard(0, d.author, "opened this", d.created, "", if (d.body.len > 0) d.body else "", true, true);

        // Comments and reviews merged by time, then read in runs: three or
        // more in a row from one person fold to their first and last.
        const a = dvui.currentWindow().arena();
        var events: std.ArrayList(Event) = .empty;
        {
            var ri: usize = 0;
            var ci: usize = 0;
            while (ri < d.reviews.len or ci < d.comments.len) {
                const take_review = ci >= d.comments.len or (ri < d.reviews.len and std.mem.order(u8, d.reviews[ri].when, d.comments[ci].when) != .gt);
                if (take_review) {
                    const r = d.reviews[ri];
                    ri += 1;
                    // A bare "commented" review says nothing — unless it is
                    // what left comments on lines of the diff.
                    if (r.body.len == 0 and std.mem.eql(u8, r.state, "COMMENTED") and !reviewHasThreads(d, r.id)) continue;
                    events.append(a, .{ .note = r, .review = true }) catch break;
                } else {
                    events.append(a, .{ .note = d.comments[ci], .review = false }) catch break;
                    ci += 1;
                }
            }
        }
        var i: usize = 0;
        while (i < events.items.len) {
            var end = i + 1;
            // A review with a conversation still open is never folded away.
            while (end < events.items.len and std.mem.eql(u8, events.items[end].note.author, events.items[i].note.author) and !(events.items[end].review and reviewHasOpenThreads(d, events.items[end].note.id))) end += 1;
            const bit: u128 = @as(u128, 1) << @intCast(i % 128);
            const folded = end - i >= 3 and pr_runs_open & bit == 0;
            for (i..end) |k| {
                if (folded and k != i and k != end - 1) {
                    // Numbered apart from the events, whose ids are their index + 1.
                    if (k == i + 1 and foldedRun(50_000 + k, events.items[i].note.author, end - i - 2)) pr_runs_open |= bit;
                    continue;
                }
                const e = events.items[k];
                // A long conversation is read from its end: the last few open.
                const open = k + CARDS_OPEN_AT_END >= events.items.len;
                if (e.review) {
                    reviewEvent(k + 1, e.note, open, reviewHasThreads(d, e.note.id));
                    // Its conversations on lines of the diff, under it, as
                    // the host shows them.
                    for (d.threads, 0..) |t, ti| {
                        if (e.note.id.len == 0 or !std.mem.eql(u8, t.review, e.note.id)) continue;
                        shown_threads[ti] = true;
                        threadRow(ti, t, d, true);
                    }
                } else timelineCard(k + 1, e.note.author, "commented", pr.isoSeconds(e.note.when), "", e.note.body, false, open);
            }
            i = end;
        }
        // Those no review on the page opened: after it, on the rail.
        for (d.threads, 0..) |t, ti| if (!shown_threads[ti]) threadRow(ti, t, d, false);
    }

    requestComposer();
    requestMergeCard(d);
}

/// The cards of a conversation opened or folded by a click on their head,
/// by their id; the rest as `pr_cards_all` says, or open where they are
/// among the last few. For the request in `pr_runs_for`.
var pr_cards: std.AutoHashMapUnmanaged(usize, bool) = .empty;
var pr_cards_all: ?bool = null;
const CARDS_OPEN_AT_END = 3;
/// The sidebar beside it, and the width of pane it needs to be there.
const PR_SIDE_W: f32 = 220;
const PR_SIDE_FROM: f32 = 700;

/// GitHub's sidebar: who is asked to review and where each stands, who it
/// is assigned to, its labels — each head dropping the list to change it.
fn requestSidebar(d: pr.Detail) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = PR_SIDE_W },
        .max_size_content = .width(PR_SIDE_W),
        .background = false,
        .margin = .{ .x = style.space.xl },
    });
    defer col.deinit();

    sideHeading(.reviewers, d);
    if (d.reviewers.len == 0) sideNone(0, "No reviews yet");
    for (d.reviewers, 0..) |r, i| sideReviewer(i, r, d.number);
    sideRule(0);

    sideHeading(.assignees, d);
    if (d.assignees.len == 0) sideNone(1, "No one assigned");
    for (d.assignees, 0..) |login, i| {
        // Numbered past the reviewers, on the same column.
        var line = sidePerson(100 + i, login);
        line.deinit();
    }
    sideRule(1);

    sideHeading(.labels, d);
    if (d.labels.len == 0) sideNone(2, "None yet");
    if (d.labels.len > 0) {
        var wrap = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
        defer wrap.deinit();
        for (d.labels, 0..) |l, i| {
            var cell = dvui.box(@src(), .{}, .{ .id_extra = i, .background = false, .margin = .{ .y = 2, .h = 2 } });
            defer cell.deinit();
            tinyBadge(@src(), 0, l.name, labelColor(l.color));
        }
    }
}

const SideKind = enum { reviewers, assignees, labels };

/// The list a sidebar section's picker works on while it is open: who, or
/// which labels, as on the request when it opened, each click since.
var side_list: std.ArrayList(u8) = .empty;

/// A sidebar section's head, GitHub's way: its name and a gear, the whole
/// line a button that drops the section's list. Each tick goes to GitHub at
/// once; the request is read again after.
fn sideHeading(kind: SideKind, d: pr.Detail) void {
    const id: usize = 10 + @as(usize, @backingInt(kind));
    const caption: []const u8 = switch (kind) {
        .reviewers => "Reviewers",
        .assignees => "Assignees",
        .labels => "Labels",
    };
    const editable = requestOpen(d);
    var button = window_chrome.DropButton.begin(@src(), .{
        .id_extra = id,
        .tag = dialog_views.frameTag("side", caption),
        .expand = .horizontal,
        .gravity_y = 0,
        .background = false,
        .color_fill_hover = .{ .color = style.rowHover() },
        .corners = style.radius.input,
        .margin = .{ .h = style.space.xs },
        .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
    });
    button.min_w = 260;
    {
        const lit = editable and (button.item.show_active or button.item.mouse_over);
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer line.deinit();
        dvui.label(@src(), "{s}", .{caption}, .{ .font = style.smallBold(), .color_text = .{ .color = if (lit) style.accent() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (editable) dvui.icon(@src(), "side_gear", dvui.entypo.cog, .{ .fill_color = .{ .color = if (lit) style.accent() else style.textFaint() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5 });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse {
        if (pick_open == id) pick_open = null;
        return;
    };
    if (!editable) return m.close();
    // Opened: the list as the request has it, and who can be asked read.
    if (pick_open != id) {
        pick_open = id;
        pick_filter.clearRetainingCapacity();
        side_list.clearRetainingCapacity();
        switch (kind) {
            .reviewers => for (d.reviewers) |r| listToggle(&side_list, r.login),
            .assignees => for (d.assignees) |login| listToggle(&side_list, login),
            .labels => for (d.labels) |l| listToggle(&side_list, l.name),
        }
        pr.loadMeta(repo_path.items);
    }

    const a = dvui.currentWindow().arena();
    var path: [512]u8 = undefined;
    switch (kind) {
        .reviewers => if (peopleRows(&side_list, true)) |login| {
            const body = std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{jsonList(a, login)}) catch return;
            if (listHas(side_list.items, login))
                requestApi("Asking for a review", "POST", apiPath(&path, "/pulls/{d}/requested_reviewers", .{d.number}), body, .none)
            else
                requestApi("Withdrawing a review", "DELETE", apiPath(&path, "/pulls/{d}/requested_reviewers", .{d.number}), body, .none);
        },
        .assignees => if (peopleRows(&side_list, false)) |_| {
            const body = std.fmt.allocPrint(a, "{{\"assignees\":{s}}}", .{jsonList(a, side_list.items)}) catch return;
            requestApi("Assigning", "PATCH", apiPath(&path, "/issues/{d}", .{d.number}), body, .none);
        },
        .labels => if (labelRows(&side_list)) |_| {
            const body = std.fmt.allocPrint(a, "{{\"labels\":{s}}}", .{jsonCommaList(a, side_list.items)}) catch return;
            requestApi("Labelling", "PUT", apiPath(&path, "/issues/{d}/labels", .{d.number}), body, .none);
        },
    }
}

fn sideNone(id: usize, text: []const u8) void {
    dvui.label(@src(), "{s}", .{text}, .{ .id_extra = id, .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2, .h = style.space.xs } });
}

fn sideRule(id: usize) void {
    var line = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = 1 },
        .max_size_content = .height(1),
        .background = true,
        .color_fill = .{ .color = style.border() },
        .margin = .{ .y = style.space.md, .h = style.space.md },
    });
    line.deinit();
}

/// A reviewer: who, and where they stand, as an icon of its colour.
fn sideReviewer(id: usize, r: pr.Reviewer, number: u32) void {
    const icon: []const u8, const hue: dvui.Color = if (std.mem.eql(u8, r.state, "APPROVED"))
        .{ dvui.entypo.check, style.success() }
    else if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED"))
        .{ dvui.entypo.cross, style.danger() }
    else if (std.mem.eql(u8, r.state, "COMMENTED"))
        .{ dvui.entypo.chat, style.textMuted() }
    else
        .{ dvui.entypo.dot_single, style.get().orange };
    var line = sidePerson(id, r.login);
    defer line.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    // One who has answered can be asked again, once the changes are made.
    if (!std.mem.eql(u8, r.state, "REQUESTED")) {
        const a = dvui.currentWindow().arena();
        const hint = std.fmt.allocPrint(a, "Ask {s} for a review again", .{r.login}) catch "Ask for a review again";
        if (dialog_views.iconButtonTagged(@src(), "rerequest", hint, dvui.entypo.cycle, style.textFaint(), dialog_views.frameTag("pr:rerequest", r.login))) {
            var path: [512]u8 = undefined;
            requestApi("Asking for a review", "POST", apiPath(&path, "/pulls/{d}/requested_reviewers", .{number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{jsonList(a, r.login)}) catch return, .none);
        }
    }
    dvui.icon(@src(), "review_state", icon, .{ .fill_color = .{ .color = hue } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5 });
}

/// A person on a line of the sidebar: their picture and login. The line
/// is left open for what follows on it.
fn sidePerson(id: usize, login: []const u8) *dvui.BoxWidget {
    const line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .background = false, .margin = .{ .y = 3, .h = 3 } });
    search_view.avatarSized(@src(), 0, requestAuthor(login), null, null, 20);
    dvui.label(@src(), "{s}", .{login}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    return line;
}

fn cardOpen(id: usize, default: bool) bool {
    return pr_cards.get(id) orelse pr_cards_all orelse default;
}

/// One step of the timeline: the rail on the left with `marker` drawn on
/// it, `content` to its right. Returns the box to fill; `end` closes both.
const TimelineRow = struct {
    row: *dvui.BoxWidget,
    body: *dvui.BoxWidget,

    fn begin(id: usize) TimelineRow {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .background = false });
        return .{ .row = row, .body = undefined };
    }

    /// The rail's column: what sits on it, then the line on down.
    fn rail(self: *TimelineRow, marker: anytype, arg: anytype) void {
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 36 }, .max_size_content = .width(36), .expand = .vertical, .background = false });
            defer col.deinit();
            {
                // At the top of the column, level with the card's head.
                var top = dvui.box(@src(), .{}, .{ .gravity_x = 0.5, .background = false, .margin = .{ .y = 4, .h = 2 } });
                defer top.deinit();
                marker(arg);
            }
            var line = dvui.box(@src(), .{}, .{
                .gravity_x = 0.5,
                .expand = .vertical,
                .background = true,
                .color_fill = .{ .color = style.border() },
                .min_size_content = .{ .w = 2, .h = 8 },
                .max_size_content = .width(2),
            });
            line.deinit();
        }
        // Beside the rail's column, not in it: closed before this opens.
        self.body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .x = style.space.sm, .h = style.space.lg } });
    }

    fn end(self: TimelineRow) void {
        self.body.deinit();
        self.row.deinit();
    }
};

fn railAvatar(login: []const u8) void {
    search_view.avatarSized(@src(), 0, requestAuthor(login), null, null, RAIL_DOT);
}

/// What sits on the timeline's rail — a picture, an icon on a disc — all
/// one size, so the rail reads as one line of marks.
const RAIL_DOT: f32 = 24;

/// An icon on a disc of `hue`'s tint, for an event with no words.
const RailIcon = struct { icon: []const u8, hue: dvui.Color };

fn railIcon(arg: RailIcon) void {
    var disc = dvui.box(@src(), .{}, .{
        .gravity_x = 0.5,
        .background = true,
        .color_fill = .{ .color = style.tint(arg.hue) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = arg.hue.opacity(0.5) },
        .corners = .all(RAIL_DOT / 2),
        .min_size_content = .{ .w = RAIL_DOT, .h = RAIL_DOT },
        .max_size_content = .size(.{ .w = RAIL_DOT, .h = RAIL_DOT }),
        .padding = dvui.Rect.all(0),
    });
    defer disc.deinit();
    dvui.icon(@src(), "rail_icon", arg.icon, .{ .fill_color = .{ .color = arg.hue } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_x = 0.5, .gravity_y = 0.5 });
}

/// The verdict a review gave, as an icon, a colour and the words for it.
fn verdictOf(state: []const u8) struct { icon: []const u8, hue: dvui.Color, words: []const u8 } {
    if (std.mem.eql(u8, state, "APPROVED")) return .{ .icon = dvui.entypo.check, .hue = style.success(), .words = "approved these changes" };
    if (std.mem.eql(u8, state, "CHANGES_REQUESTED")) return .{ .icon = dvui.entypo.cross, .hue = style.danger(), .words = "requested changes" };
    if (std.mem.eql(u8, state, "DISMISSED")) return .{ .icon = dvui.entypo.block, .hue = style.textFaint(), .words = "had a review dismissed" };
    return .{ .icon = dvui.entypo.eye, .hue = style.textMuted(), .words = "reviewed" };
}

/// A comment, or the description: the author's picture on the rail, a card
/// with who, what and when on its head and the words under it.
fn timelineCard(id: usize, author: []const u8, what: []const u8, when: i64, verdict: []const u8, body: []const u8, first: bool, default_open: bool) void {
    var row = TimelineRow.begin(id);
    row.rail(railAvatar, author);
    defer row.end();
    const accent: ?dvui.Color = if (verdict.len > 0) verdictOf(verdict).hue else null;
    const open = cardOpen(id, default_open);
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = if (accent) |h| h.opacity(0.6) else if (first) style.accent().opacity(0.35) else style.borderSubtle() },
        .corners = style.radius.row,
    });
    defer card.deinit();
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (first) style.accentDim() else style.surfaceRaised() },
            .border = .{ .h = if (open) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .corners = if (open) .{ .tl = style.radius.row.tl, .tr = style.radius.row.tr } else style.radius.row,
            .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        defer head.deinit();
        // An accordion's head: the chevron says which way it is.
        dvui.icon(@src(), "card_fold", if (open) dvui.entypo.chevron_small_down else dvui.entypo.chevron_small_right, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.xs },
        });
        dvui.label(@src(), "{s}", .{author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        const words = if (verdict.len > 0) verdictOf(verdict).words else what;
        dvui.label(@src(), "{s}", .{words}, .{ .font = style.small(), .color_text = .{ .color = accent orelse style.textMuted() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        // Folded, the first line of what it says, so a long thread can be
        // skimmed without opening each one.
        if (!open and body.len > 0) {
            dvui.label(@src(), "{s}", .{previewLine(body)}, .{
                .font = style.small(),
                .color_text = .{ .color = style.textFaint() },
                .gravity_y = 0.5,
                .expand = .horizontal,
                .max_size_content = .width(0),
                .margin = .{ .x = style.space.xs, .w = style.space.sm },
                .padding = dvui.Rect.all(0),
            });
        } else _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (when > 0) {
            var buf: [32]u8 = undefined;
            dvui.label(@src(), "{s}", .{search_view.relativeTime(&buf, when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
        if (head.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) dvui.cursorSet(.hand);
        if (dvui.clicked(head.data(), .{})) pr_cards.put(gpa, id, !open) catch {};
    }
    if (!open) return;
    var text = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.md } });
    defer text.deinit();
    if (body.len == 0) {
        dvui.label(@src(), "No description.", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
    } else markdownBody(body);
}

/// The first line of a comment worth reading, its Markdown marks left out:
/// what a folded card shows.
fn previewLine(body: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r#>*-_`");
        if (line.len > 0) return line;
    }
    return "";
}

/// A review: a card when it says something, one coloured line when it is
/// only a verdict.
fn reviewEvent(id: usize, r: pr.Note, open: bool, has_threads: bool) void {
    const when = pr.isoSeconds(r.when);
    const v = verdictOf(r.state);
    if (r.body.len > 0) return timelineCard(id, r.author, "", when, r.state, r.body, false, open);
    // A bare "commented" review has no words and no verdict: nothing to show
    // but the comments it left on lines, if any — "ann reviewed", over them.
    if (std.mem.eql(u8, r.state, "COMMENTED") and !has_threads) return;
    var row = TimelineRow.begin(id);
    row.rail(railIcon, RailIcon{ .icon = v.icon, .hue = v.hue });
    defer row.end();
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = 4 } });
    defer line.deinit();
    search_view.avatarSized(@src(), 0, requestAuthor(r.author), null, null, 18);
    dvui.label(@src(), "{s}", .{r.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{v.words}, .{ .font = style.small(), .color_text = .{ .color = v.hue }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
    if (when > 0) {
        var buf: [32]u8 = undefined;
        dvui.label(@src(), "· {s}", .{search_view.relativeTime(&buf, when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs }, .padding = dvui.Rect.all(0) });
    }
}

/// The middle of a long run of one person's comments and reviews, folded: a
/// click shows them.
fn foldedRun(id: usize, author: []const u8, hidden: usize) bool {
    var row = TimelineRow.begin(id);
    row.rail(railIcon, RailIcon{ .icon = dvui.entypo.dots_three_horizontal, .hue = style.textFaint() });
    defer row.end();
    var buf: [96]u8 = undefined;
    return dialog_views.chipButton(@src(), dvui.entypo.chevron_small_down, std.fmt.bufPrint(&buf, "Show {d} more from {s}", .{ hidden, author }) catch "Show more", false);
}

/// A heading in a comment: this much over its text, not the same size.
const MD_HEADING_STEP: f32 = 2.5;

/// A comment's text, read the way the host would show it — enough of
/// Markdown to read: headings, lists, quotes, code blocks; `**` and `` ` ``
/// marks dropped rather than shown.
fn markdownBody(body: []const u8) void {
    markdownText(body, style.body());
}

/// As `markdownBody`, its text at `base`: a commit's message reads at the
/// panel's size, a comment at the page's.
pub fn markdownText(body: []const u8, base: dvui.Font) void {
    const a = dvui.currentWindow().arena();
    var code: ?*dvui.BoxWidget = null;
    defer if (code) |c| c.deinit();
    var it = std.mem.splitScalar(u8, body, '\n');
    var n: usize = 0;
    while (it.next()) |raw| : (n += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (code) |c| {
                c.deinit();
                code = null;
            } else code = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = n,
                .expand = .horizontal,
                .background = true,
                .color_fill = .{ .color = style.surfaceInput() },
                .border = dvui.Rect.all(1),
                .color_border = .{ .color = style.borderSubtle() },
                .corners = style.radius.input,
                .padding = dvui.Rect.all(style.space.sm),
                .margin = .{ .y = style.space.xs, .h = style.space.xs },
            });
            continue;
        }
        if (code != null) {
            dvui.label(@src(), "{s}", .{line}, .{ .id_extra = n, .font = style.mono(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
            continue;
        }
        if (trimmed.len == 0) {
            _ = dvui.spacer(@src(), .{ .id_extra = n, .min_size_content = .{ .h = style.space.sm } });
            continue;
        }
        const clean = plainInline(a, trimmed);
        if (trimmed[0] == '#') {
            const words = std.mem.trimStart(u8, clean, "# ");
            var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = n, .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0), .margin = .{ .y = style.space.xs } });
            tl.addText(words, .{ .font = style.bodyBold().withSize(base.size + MD_HEADING_STEP), .color_text = .{ .color = style.text() } });
            tl.deinit();
        } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "+ ")) {
            var item = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = n, .expand = .horizontal, .background = false, .margin = .{ .x = style.space.sm, .y = style.space.xs, .h = style.space.xs } });
            defer item.deinit();
            const checked = std.mem.startsWith(u8, trimmed[2..], "[x]") or std.mem.startsWith(u8, trimmed[2..], "[X]");
            const box_item = checked or std.mem.startsWith(u8, trimmed[2..], "[ ]");
            if (box_item) {
                // Drawn: Inter has no ☑ or ☐, and they came out blank.
                var tick = dvui.box(@src(), .{}, .{
                    .background = true,
                    .color_fill = .{ .color = if (checked) style.success() else style.surface() },
                    .border = dvui.Rect.all(1),
                    .color_border = .{ .color = if (checked) style.success() else style.textFaint() },
                    .corners = style.radius.tag,
                    .min_size_content = .{ .w = 12, .h = 12 },
                    .max_size_content = .size(.{ .w = 12, .h = 12 }),
                    .gravity_y = 0.5,
                    .margin = .{ .w = style.space.sm },
                });
                if (checked) dvui.icon(@src(), "md_tick", dvui.entypo.check, .{ .fill_color = .{ .color = style.textOnAccent() } }, .{ .min_size_content = .{ .w = 9, .h = 9 }, .gravity_x = 0.5, .gravity_y = 0.5 });
                tick.deinit();
            } else dvui.label(@src(), "•", .{}, .{ .font = base, .color_text = .{ .color = style.textMuted() }, .margin = .{ .w = style.space.sm }, .padding = dvui.Rect.all(0) });
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0) });
            const words = std.mem.trimStart(u8, trimmed[2..], " ");
            addInline(tl, if (box_item) std.mem.trimStart(u8, words, "[xX ] ") else words, base, style.text());
            tl.deinit();
        } else if (trimmed[0] == '>') {
            // Filled as the card under it: dvui fills a box with a border on
            // one side only, and in the theme's colour unless told.
            var quote = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = n, .expand = .horizontal, .background = true, .color_fill = .{ .color = style.surface() }, .border = .{ .x = 3 }, .color_border = .{ .color = style.border() }, .padding = .{ .x = style.space.sm }, .margin = .{ .y = 2, .h = 2 } });
            defer quote.deinit();
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0) });
            addInline(tl, std.mem.trimStart(u8, trimmed, "> "), base, style.textMuted());
            tl.deinit();
        } else {
            var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = n, .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0) });
            addInline(tl, trimmed, base, style.text());
            tl.deinit();
        }
    }
}

/// A line's words into `tl`: `` `code` `` in the mono face and the accent,
/// the rest without its `**` marks.
fn addInline(tl: *dvui.TextLayoutWidget, text: []const u8, base: dvui.Font, ink: dvui.Color) void {
    const a = dvui.currentWindow().arena();
    var parts = std.mem.splitScalar(u8, text, '`');
    var code = false;
    while (parts.next()) |part| : (code = !code) {
        if (part.len == 0) continue;
        if (code)
            tl.addText(part, .{ .font = style.mono().withSize(base.size - 0.5), .color_text = .{ .color = style.accent() } })
        else
            tl.addText(plainInline(a, part), .{ .font = base, .color_text = .{ .color = ink } });
    }
}

/// `**bold**`, `__bold__` and `` `code` `` without their marks.
fn plainInline(a: std.mem.Allocator, text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "*_`") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and ((text[i] == '*' and text[i + 1] == '*') or (text[i] == '_' and text[i + 1] == '_'))) {
            i += 2;
            continue;
        }
        if (text[i] == '`') {
            i += 1;
            continue;
        }
        out.append(a, text[i]) catch return text;
        i += 1;
    }
    return out.items;
}

/// The answer, at the end of the conversation: who is writing, the box, and
/// the three ways to send it.
fn requestComposer() void {
    var row = TimelineRow.begin(90000);
    row.rail(railAvatar, if (window_chrome.me_gh.items.len > 0) window_chrome.me_gh.items else "you");
    defer row.end();
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
        .padding = dvui.Rect.all(style.space.md),
    });
    defer card.deinit();
    dvui.label(@src(), "Your review", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .margin = .{ .h = style.space.sm }, .padding = dvui.Rect.all(0) });
    {
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_comment, .allocator = gpa, .limit = 16384 } },
            .placeholder = "Leave a comment — Markdown reads as on the host",
            .multiline = true,
            .break_lines = true,
        }, settingsInput().override(.{ .tag = "pr:comment", .min_size_content = .{ .h = 84 }, .margin = .{ .h = style.space.sm } }));
        te.deinit();
    }
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer line.deinit();
    const text = std.mem.trim(u8, pr_comment.items, " \n\t");
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (dialog_views.dialogButton(@src(), "Comment", false) and text.len > 0) prAnswer(.comment);
    // GitHub refuses a review of your own request: only a comment there.
    const own = if (pr.detail) |d| window_chrome.me_gh.items.len > 0 and std.ascii.eqlIgnoreCase(d.author, window_chrome.me_gh.items) else false;
    if (own) return;
    if (dialog_views.dialogButton(@src(), "Request changes", false) and text.len > 0) prAnswer(.request_changes);
    if (dialog_views.dialogButton(@src(), "Approve", true)) prAnswer(.approve);
}

/// Merging, on a card of its own at the very end.
fn requestMergeCard(d: pr.Detail) void {
    if (!requestOpen(d)) return;
    var row = TimelineRow.begin(90001);
    row.rail(railIcon, RailIcon{ .icon = dvui.entypo.merge, .hue = style.accent() });
    defer row.end();
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
        .padding = dvui.Rect.all(style.space.md),
    });
    defer card.deinit();
    dvui.label(@src(), "Merge", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .margin = .{ .h = style.space.sm }, .padding = dvui.Rect.all(0) });
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer line.deinit();
    var methods = [_][]const u8{ "Merge commit", "Squash and merge", "Rebase and merge" };
    _ = dvui.dropdown(@src(), &methods, .{ .choice = &pr_merge_method }, .{}, .{
        .min_size_content = .{ .w = 150 },
        .gravity_y = 0.5,
        .font = style.small(),
        .corners = style.radius.input,
    });
    if (toggle(@src(), pr_delete_branch)) pr_delete_branch = !pr_delete_branch;
    dvui.label(@src(), "Delete the branch after", .{}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .padding = dvui.Rect.all(0),
    });
    var num: [12]u8 = undefined;
    if (dialog_views.dialogButton(@src(), "Close…", false)) ask(.close_request, requestNumber(&num));
    // Merged by the host itself once its checks and reviews allow.
    if (d.auto_merge) {
        if (dialog_views.dialogButton(@src(), "Cancel auto-merge", false)) requestOnRequest("Cancelling auto-merge", "disablePullRequestAutoMerge", d.id);
    } else if (dialog_views.dialogButton(@src(), "Auto-merge", false)) autoMerge(d);
    if (dialog_views.dialogButton(@src(), "Merge…", true)) ask(.merge_request, requestNumber(&num));
}

/// Which part of a request the pane shows under its head.
const PrTab = enum { conversation, commits, files, checks };
var pr_tab: PrTab = .conversation;

/// The request's head, above its tabs: where it stands as a pill, its title,
/// who wants what merged where, who reviews it, its labels, and a line on
/// what still stands between it and a merge.
fn requestHeader(d: pr.Detail, reload: *bool, people_inline: bool, inset: f32) void {
    // On the page's own ground: the title is what stands out, not its box.
    var head = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{ .x = inset, .y = style.space.xl, .w = inset, .h = style.space.sm },
    });
    defer head.deinit();

    // The state, the number, the title.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer line.deinit();
        const word: []const u8, const hue: dvui.Color = if (std.mem.eql(u8, d.state, "MERGED") or std.mem.eql(u8, d.state, "merged"))
            .{ "Merged", style.get().purple }
        else if (std.mem.eql(u8, d.state, "CLOSED") or std.mem.eql(u8, d.state, "closed"))
            .{ "Closed", style.danger() }
        else if (d.draft)
            .{ "Draft", style.textMuted() }
        else
            .{ "Open", style.success() };
        statePill(word, hue);
        dvui.label(@src(), "#{d}", .{d.number}, .{ .font = style.title().withSize(PR_TITLE_SIZE * style.ui_scale), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.md, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .padding = dvui.Rect.all(0) });
        tl.addText(d.title, .{ .font = style.title().withSize(PR_TITLE_SIZE * style.ui_scale), .color_text = .{ .color = style.text() } });
        tl.deinit();

        // What to do with it, short of answering it: icons at the end of
        // its title's line, each saying itself on hover.
        if (dialog_views.iconButtonTagged(@src(), "pr_checkout", "Check it out: switch to its branch, up to date", dvui.entypo.download, style.textMuted(), "pr:checkout")) checkoutRequest(d.number, d.head, d.fork);
        if (dialog_views.iconButtonTagged(@src(), "pr_web", "Open it on GitHub", dvui.entypo.popup, style.textMuted(), "pr:web")) openUrl(d.url);
        if (dialog_views.iconButtonTagged(@src(), "pr_edit", "Edit its title, description, reviewers and labels", dvui.entypo.pencil, style.textMuted(), "pr:edit")) openPrEdit(d);
        if (requestOpen(d) and !d.draft) {
            if (dialog_views.iconButtonTagged(@src(), "pr_draft", "Convert it back to a draft", dvui.entypo.back, style.textMuted(), "pr:draft")) requestOnRequest("Making a draft", "convertPullRequestToDraft", d.id);
        }
        // While it is read again, or an action on it is out, the dots and
        // what is being done instead of the refresh icon.
        if (pr.detailLoading() or api_job != null) {
            rebase_view.loadingSpinner(@src());
            dvui.label(@src(), "{s}", .{if (api_job != null and api_label.len > 0) api_label else "Reading"}, .{ .tag = "pr:busy", .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0), .margin = .{ .w = style.space.xs } });
        } else if (dialog_views.iconButtonTagged(@src(), "pr_refresh", "Read it again", dvui.entypo.cw, style.textMuted(), "pr:refresh")) reload.* = true;
    }
    // Who, from where into where, when; its size on the right.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.md } });
        defer line.deinit();
        search_view.avatarSized(@src(), 0, requestAuthor(d.author), null, null, 20);
        dvui.label(@src(), "{s}", .{d.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "wants to merge", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
        branchChip(0, d.head);
        dvui.icon(@src(), "into", dvui.entypo.arrow_long_right, .{ .fill_color = .{ .color = style.textFaint() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs, .w = style.space.xs } });
        branchChip(1, d.base);
        if (d.created > 0) {
            var when: [32]u8 = undefined;
            dvui.label(@src(), "· opened {s}", .{search_view.relativeTime(&when, d.created)}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        sizeMarks(d.additions, d.deletions);
        dvui.label(@src(), "{d} file{s}", .{ d.files, window_chrome.plural(d.files) }, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0), .margin = .{ .x = style.space.sm } });
    }
    // Reviewers, assignees, labels — here only where the sidebar has no room.
    if (people_inline and d.reviewers.len + d.assignees.len + d.labels.len > 0) {
        var line = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .margin = .{ .h = style.space.sm } });
        defer line.deinit();
        for (d.reviewers, 0..) |r, i| reviewerChip(i, r);
        for (d.assignees, 0..) |a, i| personChip(100 + i, a, "assigned");
        for (d.labels, 0..) |l, i| {
            var cell = dvui.box(@src(), .{}, .{ .id_extra = 200 + i, .background = false, .margin = .{ .y = 2, .h = 2 } });
            defer cell.deinit();
            tinyBadge(@src(), 0, l.name, labelColor(l.color));
        }
    }
    mergeReadiness(d);
}

/// A request's title: the largest words on its page.
const PR_TITLE_SIZE: f32 = 18;

/// The request `number` as the list it was picked in has it.
fn listedRequest(number: u32) ?pr.Request {
    for (pr.list) |r| if (r.number == number) return r;
    for (pr.past) |r| if (r.number == number) return r;
    return null;
}

/// A request's head while the rest of it is read: what the list knew — its
/// state, number and title, who wants it merged from where into where.
fn loadingHeader(r: pr.Request) void {
    var head = dvui.box(@src(), .{ .dir = .vertical }, .{
        .tag = "pr:loading",
        .expand = .horizontal,
        .background = false,
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.xl, .h = style.space.md },
    });
    defer head.deinit();
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer line.deinit();
        if (r.draft) statePill("Draft", style.textMuted()) else statePill("Open", style.success());
        dvui.label(@src(), "#{d}", .{r.number}, .{ .font = style.title().withSize(PR_TITLE_SIZE), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.md, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .padding = dvui.Rect.all(0) });
        tl.addText(r.title, .{ .font = style.title().withSize(PR_TITLE_SIZE), .color_text = .{ .color = style.text() } });
        tl.deinit();
    }
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.md } });
    defer line.deinit();
    search_view.avatarSized(@src(), 0, requestAuthor(r.author), null, null, 20);
    dvui.label(@src(), "{s}", .{r.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "wants to merge", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm, .w = style.space.sm }, .padding = dvui.Rect.all(0) });
    branchChip(0, r.branch);
    dvui.icon(@src(), "into", dvui.entypo.arrow_long_right, .{ .fill_color = .{ .color = style.textFaint() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs, .w = style.space.xs } });
    branchChip(1, r.base);
}

/// Ask GitHub to merge it once it can, by the method picked. Deleting its
/// branch after is the repository's own setting on GitHub, not the call's.
fn autoMerge(d: pr.Detail) void {
    if (!safeNodeId(d.id)) return;
    const method = ([_][]const u8{ "MERGE", "SQUASH", "REBASE" })[@min(pr_merge_method, 2)];
    const v = std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"id\":\"{s}\",\"method\":\"{s}\"}}", .{ d.id, method }) catch return;
    requestGraphql("Setting auto-merge", "mutation($id:ID!,$method:PullRequestMergeMethod!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:$method}){clientMutationId}}", v, .none);
}

/// One of GitHub's mutations that take a request's node id and nothing else.
fn requestOnRequest(label: []const u8, comptime mutation: []const u8, id: []const u8) void {
    if (!safeNodeId(id)) return;
    const v = std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"id\":\"{s}\"}}", .{id}) catch return;
    requestGraphql(label, "mutation($id:ID!){" ++ mutation ++ "(input:{pullRequestId:$id}){clientMutationId}}", v, .none);
}

fn requestOpen(d: pr.Detail) bool {
    return std.ascii.eqlIgnoreCase(d.state, "OPEN") or std.ascii.eqlIgnoreCase(d.state, "opened") or d.state.len == 0;
}

// === Editing a request ===

var pr_edit_open = false;
var pr_edit_rect: dvui.Rect = .{};
var pr_edit_title: std.ArrayList(u8) = .empty;
var pr_edit_body: std.ArrayList(u8) = .empty;
var pr_edit_reviewers: std.ArrayList(u8) = .empty;
var pr_edit_labels: std.ArrayList(u8) = .empty;
var pr_edit_assignees: std.ArrayList(u8) = .empty;
var pr_edit_base: std.ArrayList(u8) = .empty;
var pr_edit_draft = false;

/// The edit dialog, filled in with the request as it is: what it says,
/// where it goes, who reviews, who it is assigned to, its labels, its type.
fn openPrEdit(d: pr.Detail) void {
    pr_edit_open = true;
    pr_edit_rect = .{};
    for (prEditLists()) |t| t.clearRetainingCapacity();
    pr_edit_title.appendSlice(gpa, d.title) catch {};
    pr_edit_body.appendSlice(gpa, d.body) catch {};
    pr_edit_base.appendSlice(gpa, d.base) catch {};
    for (d.reviewers) |r| listToggle(&pr_edit_reviewers, r.login);
    for (d.assignees) |login| listToggle(&pr_edit_assignees, login);
    for (d.labels) |l| listToggle(&pr_edit_labels, l.name);
    pr_edit_draft = d.draft;
    pr.loadMeta(repo_path.items);
}

fn prEditLists() [6]*std.ArrayList(u8) {
    return .{ &pr_edit_title, &pr_edit_body, &pr_edit_reviewers, &pr_edit_labels, &pr_edit_assignees, &pr_edit_base };
}

fn clearPrEdit() void {
    pr_edit_open = false;
    for (prEditLists()) |t| {
        t.deinit(gpa);
        t.* = .empty;
    }
}

/// The request's words, and who and what to add to it.
fn prEditDialog() void {
    if (!pr_edit_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &pr_edit_rect, &pr_edit_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    var num: [12]u8 = undefined;
    var title_buf: [48]u8 = undefined;
    dialogHeader(@src(), dvui.entypo.pencil, std.fmt.bufPrint(&title_buf, "Edit #{s}", .{requestNumber(&num)}) catch "Edit", "Saved on the host when you press Save", &pr_edit_open);

    var body = dialogBody(@src(), @min(PR_CREATE_W, win.w - 80));

    // As the create dialog has it: where it goes — where it comes from is
    // fixed once it is made — its words, who and what, its type.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        branchPicker(0, "Into", &pr_edit_base, .remote);
        fixedField(1, "From", if (pr.detail) |d| d.head else "");
    }
    var entered = false;
    _ = dialog_views.dialogField(@src(), 0, "Title", &pr_edit_title, "What it does", false, &entered);
    dialog_views.dialogLabel(@src(), "Description");
    {
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_edit_body, .allocator = gpa, .limit = 65536 } },
            .multiline = true,
            .break_lines = true,
            .placeholder = "Why, and how to try it",
        }, settingsInput().override(.{ .tag = "pr_edit:body", .min_size_content = .{ .h = 160 }, .max_size_content = .size(.{ .w = 0, .h = 260 }), .margin = .{ .h = style.space.lg } }));
        te.deinit();
    }
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        peoplePicker(2, "Reviewers", &pr_edit_reviewers, "Ask for reviews", true, "pr_edit:reviewers");
        peoplePicker(3, "Assignees", &pr_edit_assignees, "Assign someone", false, "pr_edit:assignees");
        labelPicker(4, &pr_edit_labels, "pr_edit:labels");
    }
    body.deinit();
    {
        var line = dialogFooter(@src());
        defer line.deinit();
        typePicker(5, &pr_edit_draft, "pr_edit:type");
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButton(@src(), "Cancel", false)) pr_edit_open = false;
        if (dialog_views.dialogButton(@src(), "Save", true)) savePrEdit();
    }
    if (dialog_views.escapePressed() and pick_open == null) pr_edit_open = false;
}

fn savePrEdit() void {
    const title = std.mem.trim(u8, pr_edit_title.items, " \n\t");
    if (title.len == 0) return setCommandError("A request needs a title.");
    const d = pr.detail orelse return;
    const a = dvui.currentWindow().arena();
    const number = d.number;
    var path: [512]u8 = undefined;

    // Its words, and where it goes.
    const base = std.mem.trim(u8, pr_edit_base.items, " ");
    requestApi("Saving", "PATCH", apiPath(&path, "/pulls/{d}", .{number}), jsonFields(a, &.{ .{ "title", title }, .{ "body", pr_edit_body.items }, .{ "base", if (base.len > 0) base else d.base } }), .none);

    // Reviewers newly asked, and those asked no longer — only one who has
    // not answered can be: a review given stays given.
    var added: std.ArrayList(u8) = .empty;
    var removed: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, pr_edit_reviewers.items, ',');
    while (it.next()) |raw| {
        const login = std.mem.trim(u8, raw, " ");
        if (login.len == 0) continue;
        const known = for (d.reviewers) |r| {
            if (std.ascii.eqlIgnoreCase(r.login, login)) break true;
        } else false;
        if (!known) listAppend(a, &added, login);
    }
    for (d.reviewers) |r| {
        if (std.mem.eql(u8, r.state, "REQUESTED") and !listHas(pr_edit_reviewers.items, r.login)) listAppend(a, &removed, r.login);
    }
    if (added.items.len > 0) requestApi("Asking for reviews", "POST", apiPath(&path, "/pulls/{d}/requested_reviewers", .{number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{jsonList(a, added.items)}) catch return, .none);
    if (removed.items.len > 0) requestApi("Withdrawing reviews", "DELETE", apiPath(&path, "/pulls/{d}/requested_reviewers", .{number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{jsonList(a, removed.items)}) catch return, .none);

    // Assignees and labels as picked, the whole of each, where they changed.
    if (!sameNames(pr_edit_assignees.items, d.assignees)) {
        requestApi("Assigning", "PATCH", apiPath(&path, "/issues/{d}", .{number}), std.fmt.allocPrint(a, "{{\"assignees\":{s}}}", .{jsonList(a, pr_edit_assignees.items)}) catch return, .none);
    }
    var label_names: std.ArrayList([]const u8) = .empty;
    for (d.labels) |l| label_names.append(a, l.name) catch {};
    if (!sameNames(pr_edit_labels.items, label_names.items)) {
        requestApi("Labelling", "PUT", apiPath(&path, "/issues/{d}/labels", .{number}), std.fmt.allocPrint(a, "{{\"labels\":{s}}}", .{jsonCommaList(a, pr_edit_labels.items)}) catch return, .none);
    }

    // Ready for review, or back to a draft.
    if (pr_edit_draft != d.draft) {
        if (pr_edit_draft) requestOnRequest("Making a draft", "convertPullRequestToDraft", d.id) else requestOnRequest("Marking ready", "markPullRequestReadyForReview", d.id);
    }
    pr_edit_open = false;
}

/// `item` after the comma-separated `list`, in `a`.
fn listAppend(a: std.mem.Allocator, list: *std.ArrayList(u8), item: []const u8) void {
    if (list.items.len > 0) list.appendSlice(a, ", ") catch return;
    list.appendSlice(a, item) catch {};
}

/// Whether the comma-separated `list` names exactly `names`, in any order.
fn sameNames(list: []const u8, names: []const []const u8) bool {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const x = std.mem.trim(u8, raw, " ");
        if (x.len == 0) continue;
        n += 1;
        const known = for (names) |name| {
            if (std.mem.eql(u8, name, x)) break true;
        } else false;
        if (!known) return false;
    }
    return n == names.len;
}

/// A request's state, on a pill of its colour.
fn statePill(word: []const u8, hue: dvui.Color) void {
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = .{ .color = hue },
        .corners = .all(100),
        .gravity_y = 0.5,
        .padding = .{ .x = style.space.md, .y = 2, .w = style.space.md, .h = 2 },
    });
    defer pill.deinit();
    dvui.icon(@src(), "state_icon", dvui.entypo.merge, .{ .fill_color = .{ .color = style.textOnAccent() }, .stroke_color = null }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
    dvui.label(@src(), "{s}", .{word}, .{ .font = style.smallBold(), .color_text = .{ .color = style.textOnAccent() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
}

/// A branch's name on a chip, in the mono face it is typed in.
fn branchChip(id: usize, name: []const u8) void {
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.accentDim() },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer chip.deinit();
    var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
    dvui.label(@src(), "{s}", .{graph_view.fitText(&buf, name, style.mono(), 260)}, .{ .font = style.mono(), .color_text = .{ .color = style.accent() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
}

/// Someone on the request, their picture and name, and a word on their part.
fn personChip(id: usize, login: []const u8, what: []const u8) void {
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = .all(100),
        .margin = .{ .w = style.space.sm, .y = 2, .h = 2 },
        .padding = .{ .x = 2, .y = 2, .w = style.space.md, .h = 2 },
    });
    defer chip.deinit();
    search_view.avatarSized(@src(), 0, requestAuthor(login), null, null, 18);
    dvui.label(@src(), "{s}", .{login}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{what}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs }, .padding = dvui.Rect.all(0) });
}

/// A reviewer, with where they stand as an icon of its colour.
fn reviewerChip(id: usize, r: pr.Reviewer) void {
    const icon: []const u8, const hue: dvui.Color, const word: []const u8 = if (std.mem.eql(u8, r.state, "APPROVED"))
        .{ dvui.entypo.check, style.success(), "approved" }
    else if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED"))
        .{ dvui.entypo.cross, style.danger(), "asks for changes" }
    else if (std.mem.eql(u8, r.state, "COMMENTED"))
        .{ dvui.entypo.chat, style.textMuted(), "commented" }
    else
        .{ dvui.entypo.clock, style.get().orange, "asked to review" };
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = hue.opacity(0.5) },
        .corners = .all(100),
        .margin = .{ .w = style.space.sm, .y = 2, .h = 2 },
        .padding = .{ .x = 2, .y = 2, .w = style.space.md, .h = 2 },
    });
    defer chip.deinit();
    search_view.avatarSized(@src(), 0, requestAuthor(r.login), null, null, 18);
    dvui.label(@src(), "{s}", .{r.login}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.icon(@src(), "review_state", icon, .{ .fill_color = .{ .color = hue } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm } });
    dvui.label(@src(), "{s}", .{word}, .{ .font = style.tiny(), .color_text = .{ .color = hue }, .gravity_y = 0.5, .margin = .{ .x = 2 }, .padding = dvui.Rect.all(0) });
}

/// What a request's checks came to: failed, running, passed.
const CheckTally = struct { failed: usize = 0, running: usize = 0, passed: usize = 0 };

fn checkOk(result: []const u8) bool {
    return std.mem.eql(u8, result, "SUCCESS") or std.mem.eql(u8, result, "NEUTRAL") or std.mem.eql(u8, result, "SKIPPED");
}

fn checkBad(result: []const u8) bool {
    return std.mem.eql(u8, result, "FAILURE") or std.mem.eql(u8, result, "ERROR") or std.mem.eql(u8, result, "CANCELLED") or std.mem.eql(u8, result, "TIMED_OUT") or std.mem.eql(u8, result, "ACTION_REQUIRED");
}

fn tallyChecks(checks: []const pr.Check) CheckTally {
    var t: CheckTally = .{};
    for (checks) |c| {
        if (checkOk(c.result)) t.passed += 1 else if (checkBad(c.result)) t.failed += 1 else t.running += 1;
    }
    return t;
}

/// The one line on whether it can be merged, and if not what is in the way —
/// worst first: conflicts, failing checks, changes asked for, the base moved
/// on, a review still wanted, checks still running, a draft.
fn mergeReadiness(d: pr.Detail) void {
    const t = tallyChecks(d.checks);
    var buf: [160]u8 = undefined;
    const icon: []const u8, const hue: dvui.Color, const text: []const u8 = blk: {
        // Done with: what became of it, not whether it could merge.
        if (std.ascii.eqlIgnoreCase(d.state, "MERGED")) break :blk .{ dvui.entypo.merge, style.get().purple, std.fmt.bufPrint(&buf, "Merged into {s}", .{d.base}) catch "Merged" };
        if (std.ascii.eqlIgnoreCase(d.state, "CLOSED")) break :blk .{ dvui.entypo.block, style.danger(), "Closed without merging" };
        if (std.mem.eql(u8, d.mergeable, "CONFLICTING")) break :blk .{ dvui.entypo.warning, style.danger(), std.fmt.bufPrint(&buf, "Conflicts with {s}: resolve them before it can merge", .{d.base}) catch "" };
        if (t.failed > 0) break :blk .{ dvui.entypo.cross, style.danger(), std.fmt.bufPrint(&buf, "{d} check{s} failing", .{ t.failed, window_chrome.plural(t.failed) }) catch "" };
        if (std.mem.eql(u8, d.review, "CHANGES_REQUESTED")) break :blk .{ dvui.entypo.cross, style.danger(), changesText(d) };
        if (std.mem.eql(u8, d.merge_state, "BEHIND")) break :blk .{ dvui.entypo.arrow_down, style.get().orange, std.fmt.bufPrint(&buf, "Behind {s}: update the branch first", .{d.base}) catch "" };
        if (std.mem.eql(u8, d.review, "REVIEW_REQUIRED")) break :blk .{ dvui.entypo.eye, style.get().orange, "A review is still needed" };
        if (t.running > 0) break :blk .{ dvui.entypo.clock, style.get().orange, std.fmt.bufPrint(&buf, "{d} check{s} still running", .{ t.running, window_chrome.plural(t.running) }) catch "" };
        if (d.draft) break :blk .{ dvui.entypo.pencil, style.textMuted(), "A draft: mark it ready for review to merge it" };
        if (std.mem.eql(u8, d.merge_state, "BLOCKED")) break :blk .{ dvui.entypo.lock, style.get().orange, "Blocked by the branch's protection rules" };
        // GitHub works mergeability out after a push, a while later: until
        // then it says UNKNOWN, which is not a yes.
        if (mergeUnknown(d)) break :blk .{ dvui.entypo.clock, style.textMuted(), "GitHub is still working out whether it can merge…" };
        break :blk .{ dvui.entypo.check, style.success(), if (t.passed > 0) std.fmt.bufPrint(&buf, "Ready to merge: {d} check{s} passed", .{ t.passed, window_chrome.plural(t.passed) }) catch "" else "Ready to merge" };
    };
    var bar = dialog_views.alertBox(@src(), 0, hue, icon, .{ .y = style.space.md, .h = style.space.xs });
    defer bar.deinit();
    dialog_views.alertText(@src(), text, hue);
    if (d.auto_merge) tinyBadge(@src(), 0, "auto-merge on", style.accent());
    readinessAction(d, t, hue);

    // Asked again every few seconds while GitHub has no answer yet — about
    // one still open: a merged one's stays unknown for good.
    if (requestOpen(d) and mergeUnknown(d)) {
        if (frame_now_s - pr_recheck_s >= PR_RECHECK_S) {
            pr_recheck_s = frame_now_s;
            pr.loadDetail(repo_path.items, d.number);
        }
        dvui.timer(bar.data().id, PR_RECHECK_S * std.time.us_per_s);
    }
}

/// "ann asked for changes · 2 open conversations": who, and what is left.
fn changesText(d: pr.Detail) []const u8 {
    const a = dvui.currentWindow().arena();
    var who: []const u8 = "";
    var n: usize = 0;
    for (d.reviewers) |r| if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED")) {
        if (n == 0) who = r.login;
        n += 1;
    };
    const head = (switch (n) {
        0 => "Changes were asked for",
        1 => std.fmt.allocPrint(a, "{s} asked for changes", .{who}),
        else => std.fmt.allocPrint(a, "{s} and {d} more asked for changes", .{ who, n - 1 }),
    }) catch "Changes were asked for";
    const open = openThreads(d);
    if (open == 0) return head;
    return std.fmt.allocPrint(a, "{s} · {d} open conversation{s}", .{ head, open, window_chrome.plural(open) }) catch head;
}

/// Ask again those who asked for changes, once they are made.
fn rerequestReview(d: pr.Detail) void {
    const a = dvui.currentWindow().arena();
    var who: std.ArrayList(u8) = .empty;
    for (d.reviewers) |r| if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED")) listAppend(a, &who, r.login);
    if (who.items.len == 0) return;
    var path: [512]u8 = undefined;
    requestApi("Asking for a review", "POST", apiPath(&path, "/pulls/{d}/requested_reviewers", .{d.number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{jsonList(a, who.items)}) catch return, .none);
}

/// The one thing to do next about a request, at the end of its readiness
/// line: resolve its conflicts here, bring it up to date on GitHub, look at
/// the failing checks, put a draft up for review, or merge it.
fn readinessAction(d: pr.Detail, t: anytype, hue: dvui.Color) void {
    if (!requestOpen(d)) return;
    if (std.mem.eql(u8, d.mergeable, "CONFLICTING")) {
        // Rebased onto its base, here: the conflicts come up one by one.
        if (!d.fork and dialog_views.alertButton(@src(), "Rebase onto it here", hue, "pr:resolve")) resolveRequestLocally(d, true);
        if (!d.fork and dialog_views.linkButtonTagged(@src(), "or merge it in", hue, "pr:resolve_merge")) resolveRequestLocally(d, false);
        return;
    }
    // In the order the line above says what is in the way.
    if (t.failed > 0) {
        if (dialog_views.alertButton(@src(), "See the checks", hue, "pr:see_checks")) pr_tab = .checks;
        return;
    }
    // Changes asked for: to the conversations left, then onto its branch to
    // make them, then the reviewers asked again.
    if (std.mem.eql(u8, d.review, "CHANGES_REQUESTED")) {
        if (openThreads(d) > 0 and dialog_views.linkButtonTagged(@src(), "Show them", hue, "pr:to_threads")) {
            pr_tab = .conversation;
            pr_scroll_thread = true;
        }
        if (!onRequestBranch(d)) {
            if (dialog_views.alertButton(@src(), "Check out to fix", hue, "pr:fix")) checkoutRequest(d.number, d.head, d.fork);
        } else if (dialog_views.alertButton(@src(), "Re-request review", hue, "pr:rerequest")) rerequestReview(d);
        return;
    }
    if (std.mem.eql(u8, d.merge_state, "BEHIND")) {
        if (dialog_views.alertButton(@src(), "Update branch", hue, "pr:update")) updateRequestBranch(d);
        return;
    }
    if (d.draft) {
        if (dialog_views.alertButton(@src(), "Ready for review", hue, "pr:ready")) requestOnRequest("Marking ready", "markPullRequestReadyForReview", d.id);
        return;
    }
    if (mergeUnknown(d) or t.running > 0) return;
    var num: [12]u8 = undefined;
    if (dialog_views.alertButton(@src(), "Merge…", hue, "pr:merge")) ask(.merge_request, std.fmt.bufPrint(&num, "{d}", .{d.number}) catch return);
}

/// The base merged into the request's branch, on GitHub — refused there if
/// the branch moved since it was shown — then the request read again once
/// GitHub has had the time.
fn updateRequestBranch(d: pr.Detail) void {
    var path: [512]u8 = undefined;
    const body = if (d.head_sha.len > 0)
        std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"expected_head_sha\":\"{s}\"}}", .{d.head_sha}) catch "{}"
    else
        "{}";
    requestApi("Updating the branch", "PUT", apiPath(&path, "/pulls/{d}/update-branch", .{d.number}), body, .none);
    api_fetch_after = true;
    pr_reread_at = frame_now_s + PR_REREAD_S;
}

/// When to read the open request again: GitHub answers "update branch"
/// before it has done it. 0 for never.
var pr_reread_at: i64 = 0;
const PR_REREAD_S = 4;

/// Whether GitHub has yet to say if the request can merge.
fn mergeUnknown(d: pr.Detail) bool {
    return std.mem.eql(u8, d.mergeable, "UNKNOWN") or std.mem.eql(u8, d.merge_state, "UNKNOWN");
}

/// When the open request's mergeability was last asked for again.
var pr_recheck_s: i64 = 0;
const PR_RECHECK_S = 3;

/// The tabs under the head: the conversation, the commits, the files, the
/// checks, each with how many.
fn requestTabs(d: pr.Detail, inset: f32) void {
    // Sideways when the pane is narrower than the four of them.
    var scroll = dvui.scrollArea(@src(), .{ .vertical = .none, .horizontal = .auto, .horizontal_bar = .auto_overlay }, .{
        .expand = .horizontal,
        .background = false,
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer scroll.deinit();
    // The first tab's icon under the head's first word.
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = false,
        .padding = .{ .x = @max(0, inset - style.space.md) },
    });
    defer bar.deinit();
    const tabs = [_]struct { PrTab, []const u8, []const u8, usize }{
        .{ .conversation, dvui.entypo.chat, "Conversation", d.comments.len + d.reviews.len },
        .{ .commits, dvui.entypo.flow_line, "Commits", d.commits.len },
        .{ .files, dvui.entypo.text_document, "Files changed", @max(d.files, d.file_list.len) },
        .{ .checks, dvui.entypo.check, "Checks", d.checks.len },
    };
    for (tabs, 0..) |tab, i| {
        const on = pr_tab == tab[0];
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .tag = dialog_views.frameTag("prtab", tab[2]),
            // Words on the page's ground; the one shown underlined in the
            // accent, on the bar's rule.
            .background = false,
            .margin = .{ .w = style.space.md },
            .padding = .{ .x = style.space.md, .y = style.space.md, .w = style.space.md, .h = style.space.md },
        });
        bw.processEvents();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
            defer row.deinit();
            const ink = if (on) style.accent() else if (bw.hovered()) style.text() else style.textMuted();
            dvui.label(@src(), "{s}", .{tab[2]}, .{ .font = style.body(), .color_text = .{ .color = ink }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            if (tab[3] > 0) dvui.label(@src(), "{d}", .{tab[3]}, .{
                .font = style.tinyBold(),
                .color_text = .{ .color = style.textMuted() },
                .background = true,
                .color_fill = .{ .color = style.surfaceRaised() },
                .corners = style.radius.tag,
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.sm },
                .padding = .{ .x = 5, .w = 5 },
            });
        }
        if (on) {
            const rs = bw.data().borderRectScale();
            (dvui.Rect.Physical{ .x = rs.r.x, .y = rs.r.y + rs.r.h - 2 * rs.s, .w = rs.r.w, .h = 2 * rs.s })
                .fill(.{}, .{ .color = .{ .color = style.accent() }, .fade = 0 });
        }
        if (bw.clicked()) pr_tab = tab[0];
        bw.deinit();
    }
}

/// The commits of the request, newest last as the host lists them; a click
/// shows one in the graph, where it is there.
fn requestCommits(d: pr.Detail) void {
    if (d.commits.len == 0) return emptyNote("No commits.");
    var card = listCard(@src());
    defer card.deinit();
    for (d.commits, 0..) |c, i| {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .color_fill_hover = .{ .color = style.rowHover() },
            .border = .{ .h = if (i + 1 < d.commits.len) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        bw.processEvents();
        bw.drawBackground();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer row.deinit();
            search_view.avatarSized(@src(), 0, requestAuthor(c.author), null, null, 20);
            var fit: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
            dvui.label(@src(), "{s}", .{graph_view.fitText(&fit, c.headline, style.small(), 420)}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
            dvui.label(@src(), "{s}", .{c.oid[0..@min(c.oid.len, 7)]}, .{ .font = style.mono(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.md }, .padding = dvui.Rect.all(0) });
            if (c.when > 0) {
                var when: [32]u8 = undefined;
                dvui.label(@src(), "{s}", .{search_view.relativeTime(&when, c.when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            }
        }
        if (bw.hovered()) dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r, .position = .vertical, .delay = 400_000 }, "Show it in the graph", .{}, .{ .font = style.small() });
        const clicked = bw.clicked();
        bw.deinit();
        if (clicked) showInGraph(c.oid);
    }
}

/// The graph, with the commit `hex` picked, if the history has it.
fn showInGraph(hex: []const u8) void {
    const h = history orelse return;
    for (h.commits) |commit| {
        var buf: [41]u8 = undefined;
        if (!std.mem.startsWith(u8, git.oidHex(commit.id, &buf), hex)) continue;
        revealInGraph(commit.id);
        return;
    }
    setCommandError("That commit is not in the history here yet: fetch, then try again.");
}

/// The graph, with commit `id` picked and scrolled into view — what a click
/// on a branch, tag, stash or worktree in the sidebar does.
fn revealInGraph(id: git.Oid) void {
    const h = history orelse return;
    const index = h.indexOf(id) orelse
        return setCommandError("That commit is not in the graph: its branch is hidden, or not walked.");
    new_tab_open = false;
    active_view = .graph;
    selectCommit(id);

    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(gpa);
    graph_view.shownRows(gpa, h.commits, &rows);
    const row = graph_view.listRow(@intCast(index), rows.items) orelse
        return setCommandError("That commit is not in this file's history: close it to see the commit.");
    revealCommit(row);
}

/// The files the request changes, each with its size and the review threads
/// left on it; a button opens the whole change in the diff pane.
fn requestFiles(d: pr.Detail) void {
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.md } });
        defer line.deinit();
        dvui.label(@src(), "{d} file{s} changed", .{ d.file_list.len, window_chrome.plural(d.file_list.len) }, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        if (dialog_views.dialogButton(@src(), "Open the changes", true)) openRequestChanges(d);
    }
    if (d.file_list.len == 0) return emptyNote("The host did not list the files.");
    var card = listCard(@src());
    defer card.deinit();
    for (d.file_list, 0..) |f, i| {
        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .expand = .horizontal,
            // The card's own: dvui fills a box ruled on one side anyway.
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .border = .{ .h = if (i + 1 < d.file_list.len) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        defer row.deinit();
        {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer line.deinit();
            const base = std.fs.path.basename(f.path);
            dvui.label(@src(), "{s}", .{base}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            dvui.label(@src(), "{s}", .{std.fs.path.dirname(f.path) orelse ""}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .expand = .horizontal, .max_size_content = .width(0), .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
            sizeMarks(f.additions, f.deletions);
        }
        // The threads on this file, under it, where they belong.
        var n: usize = 0;
        for (d.threads, 0..) |t, ti| if (std.mem.eql(u8, t.path, f.path)) {
            threadCard(i * 100 + n, ti, t, d, true);
            n += 1;
        };
    }
}

/// The whole change of a request in the diff pane: from where its branch
/// left the base to its head, as the compare view shows any two commits.
fn openRequestChanges(d: pr.Detail) void {
    const r = repo orelse return;
    const h = history orelse return;
    const remote = defaultRemote() orelse "origin";
    const head = remoteTip(h, remote, d.head) orelse {
        setCommandError("Its branch is not here: fetch, then try again.");
        return;
    };
    const base = remoteTip(h, remote, d.base) orelse {
        setCommandError("Its base is not here: fetch, then try again.");
        return;
    };
    const from = r.mergeBase(base, head) orelse base;
    active_view = .graph;
    startCompare(from, head, d.base, d.head);
}

/// Where `remote`'s `branch` points, as the history last read it.
fn remoteTip(h: git.History, remote: []const u8, branch: []const u8) ?git.Oid {
    for (h.refs) |ref| {
        if (ref.kind != .remote) continue;
        const parts = splitRemoteRef(ref.name);
        if (std.mem.eql(u8, parts.remote, remote) and std.mem.eql(u8, parts.branch, branch)) return ref.target;
    }
    return null;
}

/// The checks, by workflow: each with its result, how long it took, and its
/// log; the failed ones run again with one button.
fn requestChecks(d: pr.Detail) void {
    const t = tallyChecks(d.checks);
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.md } });
        defer line.deinit();
        dvui.label(@src(), "{d} passed · {d} failed · {d} running", .{ t.passed, t.failed, t.running }, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        if (t.failed > 0 and pr.host == .github and dialog_views.dialogButton(@src(), "Re-run the failed", true)) rerunFailed(d);
    }
    if (d.checks.len == 0) return emptyNote("No checks ran on it.");
    var card = listCard(@src());
    defer card.deinit();
    var last_group: []const u8 = "\x00";
    for (d.checks, 0..) |c, i| {
        if (!std.mem.eql(u8, c.group, last_group)) {
            last_group = c.group;
            dialog_views.dropHeading(@src(), i, if (c.group.len > 0) c.group else "STATUSES");
        }
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = false,
            .padding = .{ .x = style.space.md, .y = 4, .w = style.space.md, .h = 4 },
        });
        defer row.deinit();
        const ok = checkOk(c.result);
        const bad = checkBad(c.result);
        dvui.icon(@src(), "check_icon", if (ok) dvui.entypo.check else if (bad) dvui.entypo.cross else dvui.entypo.clock, .{
            .fill_color = .{ .color = if (ok) style.success() else if (bad) style.danger() else style.get().orange },
        }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .w = style.space.md } });
        dvui.label(@src(), "{s}", .{c.name}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        if (c.seconds > 0) {
            var buf: [24]u8 = undefined;
            const took = if (c.seconds >= 60) std.fmt.bufPrint(&buf, "{d}m {d}s", .{ @divFloor(c.seconds, 60), @mod(c.seconds, 60) }) catch "" else std.fmt.bufPrint(&buf, "{d}s", .{c.seconds}) catch "";
            dvui.label(@src(), "{s}", .{took}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .w = style.space.md }, .padding = dvui.Rect.all(0) });
        }
        if (c.url.len > 0 and dialog_views.linkButtonTagged(@src(), "Log", style.accent(), null)) run.open(app_io, ".", c.url) catch {};
    }
}

/// Each workflow run with a failed check started again, its failed jobs
/// alone, by the run id in its link.
fn rerunFailed(d: pr.Detail) void {
    var ids: [8][]const u8 = undefined;
    var n: usize = 0;
    for (d.checks) |c| {
        if (!checkBad(c.result)) continue;
        const id = runIdOf(c.url) orelse continue;
        for (ids[0..n]) |seen| {
            if (std.mem.eql(u8, seen, id)) break;
        } else if (n < ids.len) {
            ids[n] = id;
            n += 1;
        }
    }
    if (n == 0) return setCommandError("No workflow run to start again: the failing checks are not GitHub Actions.");
    var path: [512]u8 = undefined;
    for (ids[0..n]) |id| requestApi("Re-running", "POST", apiPath(&path, "/actions/runs/{s}/rerun-failed-jobs", .{id}), null, .none);
}

/// ".../actions/runs/123/job/456" -> "123".
fn runIdOf(url: []const u8) ?[]const u8 {
    const key = "/actions/runs/";
    const at = std.mem.indexOf(u8, url, key) orelse return null;
    const rest = url[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (end == 0) return null;
    for (rest[0..end]) |ch| if (!std.ascii.isDigit(ch)) return null;
    return rest[0..end];
}

/// The card a tab's list sits on.
fn listCard(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
    });
}

/// A line of faint text where a tab has nothing to show.
fn emptyNote(text: []const u8) void {
    dvui.label(@src(), "{s}", .{text}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
}

/// How many conversations on lines of the diff are still open.
fn openThreads(d: pr.Detail) usize {
    var n: usize = 0;
    for (d.threads) |t| n += @intFromBool(!t.resolved);
    return n;
}

fn reviewHasThreads(d: pr.Detail, review: []const u8) bool {
    if (review.len == 0) return false;
    for (d.threads) |t| if (std.mem.eql(u8, t.review, review)) return true;
    return false;
}

fn reviewHasOpenThreads(d: pr.Detail, review: []const u8) bool {
    if (review.len == 0) return false;
    for (d.threads) |t| if (!t.resolved and std.mem.eql(u8, t.review, review)) return true;
    return false;
}

/// A conversation on a line, on the timeline: under the review that
/// opened it, set in a little under its card; or on its own mark.
fn threadRow(ti: usize, t: pr.Thread, d: pr.Detail, under_review: bool) void {
    var row = TimelineRow.begin(60_000 + ti);
    if (under_review)
        row.rail(railNone, {})
    else
        row.rail(railIcon, RailIcon{ .icon = if (t.resolved) dvui.entypo.check else dvui.entypo.chat, .hue = if (t.resolved) style.success() else style.get().yellow });
    defer row.end();
    var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .x = if (under_review) style.space.xl else 0 } });
    defer inner.deinit();
    threadCard(ti, ti, t, d, false);
}

/// The rail going on past a step that has no mark of its own.
fn railNone(_: void) void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = RAIL_DOT, .h = 0 } });
}

/// Scroll to the first open conversation on the next frame it is drawn.
var pr_scroll_thread = false;

/// A conversation on a line of the diff, folded to its head once resolved:
/// where, the diff it was left on, what was said — a suggestion as the
/// change it suggests, to apply here — and the answer: reply, resolve.
/// `ti` is its place in the request's threads, what its fold is kept by;
/// `under_file` when it is shown under its file's name, which it then
/// leaves out: "Line 3", not "login.ts:3" twice over.
fn threadCard(id: usize, ti: usize, t: pr.Thread, d: pr.Detail, under_file: bool) void {
    const fold_key = 70_000 + ti;
    const open = cardOpen(fold_key, !t.resolved or pr_threads_all);
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = if (t.resolved) style.borderSubtle() else style.get().yellow.opacity(0.45) },
        .corners = style.radius.row,
        .margin = .{ .h = style.space.md },
    });
    defer card.deinit();
    // Asked from the readiness line: the first one still open, in sight.
    if (pr_scroll_thread and !t.resolved) {
        pr_scroll_thread = false;
        dvui.scrollTo(.{ .screen_rect = card.data().borderRectScale().r });
    }

    // Where, on a head that folds it.
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = .{ .h = if (open) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .corners = if (open) .{ .tl = style.radius.row.tl, .tr = style.radius.row.tr } else style.radius.row,
            .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        defer head.deinit();
        dvui.icon(@src(), "thread_fold", if (open) dvui.entypo.chevron_small_down else dvui.entypo.chevron_small_right, .{ .fill_color = .{ .color = style.textMuted() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
        if (!under_file) dvui.icon(@src(), "thread_file", dvui.entypo.text_document, .{ .fill_color = .{ .color = style.textFaint() } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
        var where_buf: [512]u8 = undefined;
        const ranged = t.start_line > 0 and t.start_line < t.line;
        const where = if (under_file) (if (t.line == 0)
            "The file"
        else if (ranged)
            std.fmt.bufPrint(&where_buf, "Lines {d}–{d}", .{ t.start_line, t.line }) catch ""
        else
            std.fmt.bufPrint(&where_buf, "Line {d}", .{t.line}) catch "") else if (t.line == 0)
            t.path
        else if (ranged)
            std.fmt.bufPrint(&where_buf, "{s}:{d}–{d}", .{ t.path, t.start_line, t.line }) catch t.path
        else
            std.fmt.bufPrint(&where_buf, "{s}:{d}", .{ t.path, t.line }) catch t.path;
        dvui.label(@src(), "{s}", .{where}, .{ .font = if (under_file) style.small() else style.graphMono(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        if (t.outdated) tinyBadge(@src(), 0, "Outdated", style.get().yellow);
        if (t.resolved) tinyBadge(@src(), 1, "Resolved", style.success());
        // Folded, who started it and its first words.
        if (!open and t.comments.len > 0) {
            dvui.label(@src(), "{s}: {s}", .{ t.comments[0].author, previewLine(t.comments[0].body) }, .{
                .font = style.small(),
                .color_text = .{ .color = style.textFaint() },
                .gravity_y = 0.5,
                .expand = .horizontal,
                .max_size_content = .width(0),
                .margin = .{ .x = style.space.sm },
                .padding = dvui.Rect.all(0),
            });
        } else _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (t.comments.len > 1) dvui.label(@src(), "{d} comments", .{t.comments.len}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        if (head.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) dvui.cursorSet(.hand);
        if (dvui.clicked(head.data(), .{})) pr_cards.put(gpa, fold_key, !open) catch {};
    }
    if (!open) return;

    var inside = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(style.space.md) });
    defer inside.deinit();

    // The diff it was left on: the hunk's last lines, which end at the line —
    // unless a comment suggests a change, whose box shows those lines and
    // what they would become: the same code twice otherwise.
    const suggests = for (t.comments) |c| {
        if (suggestionOf(c.body) != null) break true;
    } else false;
    if (t.hunk.len > 0 and !suggests) {
        var code = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceInput() },
            .corners = style.radius.tag,
            .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.sm, .h = style.space.xs },
            .margin = .{ .h = style.space.sm },
        });
        defer code.deinit();
        const TAIL = 4;
        const count = std.mem.count(u8, t.hunk, "\n") + 1;
        var it = std.mem.splitScalar(u8, t.hunk, '\n');
        var n: usize = 0;
        while (it.next()) |raw| : (n += 1) {
            if (n + TAIL < count) continue;
            const text = std.mem.trimEnd(u8, raw, "\r");
            const hue = if (std.mem.startsWith(u8, text, "+")) style.success() else if (std.mem.startsWith(u8, text, "-")) style.danger() else style.textFaint();
            dvui.label(@src(), "{s}", .{text}, .{ .id_extra = n, .font = style.graphMono(), .color_text = .{ .color = hue }, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
        }
    }

    for (t.comments, 0..) |c, ci| threadComment(ci, c, t, d);

    const replying = pr_reply_id.items.len > 0 and std.mem.eql(u8, pr_reply_id.items, t.id);
    if (replying) {
        var field = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .min_size_content = .{ .h = 56 },
            .margin = .{ .y = style.space.sm, .h = style.space.sm },
        });
        defer field.deinit();
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_reply, .allocator = gpa, .limit = 16384 } },
            .placeholder = "Reply — Ctrl+Enter sends it",
            .multiline = true,
            .break_lines = true,
        }, .{
            .tag = "pr:reply",
            .expand = .both,
            .background = false,
            .border = dvui.Rect.all(0),
            .corners = style.radius.input,
            .font = style.small(),
            .padding = dvui.Rect.all(style.space.sm),
        });
        const field_id = te.data().id;
        te.deinit();
        dialog_views.focusOnce(field_id);
    }

    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.xs } });
        defer line.deinit();
        if (replying) {
            if (dialog_views.dialogButtonTagged(@src(), "Reply", true, "pr:reply_send")) replyToThread();
            if (!t.resolved and t.can_resolve) {
                if (dialog_views.dialogButtonTagged(@src(), "Reply and resolve", false, "pr:reply_resolve")) {
                    replyToThread();
                    setThreadResolved(t.id, true);
                }
            }
            if (dialog_views.dialogButton(@src(), "Cancel", false)) {
                pr_reply_id.clearRetainingCapacity();
                pr_reply.clearRetainingCapacity();
            }
        } else if (t.can_reply) {
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.reply, "Reply", false, dialog_views.frameTag("pr:reply_to", t.id))) {
                pr_reply_id.clearRetainingCapacity();
                pr_reply_id.appendSlice(gpa, t.id) catch {};
                pr_reply.clearRetainingCapacity();
            }
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (!t.resolved and t.can_resolve) {
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.check, "Resolve conversation", true, dialog_views.frameTag("pr:resolve", t.id))) setThreadResolved(t.id, true);
        } else if (t.resolved and t.can_unresolve) {
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.ccw, "Unresolve", false, dialog_views.frameTag("pr:unresolve", t.id))) setThreadResolved(t.id, false);
        }
    }
}

/// One reply in a thread: who and when on a line, the words under it,
/// indented under the picture.
fn threadComment(id: usize, c: pr.Note, t: pr.Thread, d: pr.Detail) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        // The card's own: dvui fills a box ruled on one side anyway, in the
        // theme's colour unless told — the dark band behind a reply.
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .y = if (id > 0) 1 else 0 },
        .color_border = .{ .color = style.borderSubtle() },
        .padding = .{ .y = style.space.sm, .h = style.space.xs },
    });
    defer box.deinit();
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.xs } });
        defer line.deinit();
        search_view.avatarSized(@src(), 0, requestAuthor(c.author), null, null, 20);
        dvui.label(@src(), "{s}", .{c.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        const when = pr.isoSeconds(c.when);
        if (when > 0) {
            var buf: [32]u8 = undefined;
            dvui.label(@src(), "· {s}", .{search_view.relativeTime(&buf, when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
    }
    var text = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .x = 20 + style.space.sm } });
    defer text.deinit();
    // A suggestion is shown as the change it is — the lines it replaces and
    // what with — and can be applied to the file here.
    if (suggestionOf(c.body)) |sg| {
        if (std.mem.trim(u8, sg.before, " \t\r\n").len > 0) markdownBody(sg.before);
        suggestionBox(id, t, d, sg.code);
        if (std.mem.trim(u8, sg.after, " \t\r\n").len > 0) markdownBody(sg.after);
    } else markdownBody(c.body);
}

/// A comment's first ```suggestion block: the words before it, the lines
/// it suggests, the words after.
const Suggestion = struct { before: []const u8, code: []const u8, after: []const u8 };

fn suggestionOf(body: []const u8) ?Suggestion {
    const fence = std.mem.indexOf(u8, body, "```suggestion") orelse return null;
    const code_start = (std.mem.indexOfScalarPos(u8, body, fence, '\n') orelse return null) + 1;
    var pos = code_start;
    while (pos <= body.len) {
        const eol = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        if (std.mem.startsWith(u8, std.mem.trim(u8, body[pos..eol], " \t\r"), "```")) {
            // The newline before the closing fence is not part of the code.
            const code_end = if (pos > code_start) pos - 1 else code_start;
            return .{ .before = body[0..fence], .code = body[code_start..code_end], .after = if (eol < body.len) body[eol + 1 ..] else "" };
        }
        if (eol == body.len) return null;
        pos = eol + 1;
    }
    return null;
}

/// The last `n` lines of the new side of a diff hunk — what a comment on
/// them saw — their `+` or space taken off. In `a`.
fn hunkTail(a: std.mem.Allocator, hunk: []const u8, n: usize) []const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, hunk, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '+' or line[0] == ' ') lines.append(a, line[1..]) catch return &.{};
    }
    return lines.items[lines.items.len -| n..];
}

/// The lines a thread is on: from its first through its last.
fn threadSpan(t: pr.Thread) usize {
    if (t.start_line > 0 and t.start_line < t.line) return t.line - t.start_line + 1;
    return 1;
}

/// A suggestion as a change: the lines it replaces, in red, what with, in
/// green; and the button that writes it into the file here — once the
/// request's branch is the one checked out.
fn suggestionBox(id: usize, t: pr.Thread, d: pr.Detail, code: []const u8) void {
    const a = dvui.currentWindow().arena();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.borderSubtle() },
        .corners = style.radius.input,
        .margin = .{ .y = style.space.xs, .h = style.space.xs },
    });
    defer box.deinit();
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.borderSubtle() },
            .corners = .{ .tl = style.radius.input.tl, .tr = style.radius.input.tr },
            .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.xs, .h = style.space.xs },
        });
        defer head.deinit();
        dvui.label(@src(), "Suggested change", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (suggestionApplied(d.number, t.id)) {
            // Done here: said so, with the way to the change it made.
            dvui.icon(@src(), "applied", dvui.entypo.check, .{ .fill_color = .{ .color = style.success() } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
            dvui.label(@src(), "Applied here", .{}, .{ .font = style.small(), .color_text = .{ .color = style.success() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.text_document, "See the change", false, dialog_views.frameTag("pr:applied", t.id))) {
                active_view = .graph;
                selectChange(t.path, .unstaged);
            }
        } else if (t.outdated) {
            dvui.label(@src(), "its lines have moved since", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        } else if (requestOpen(d)) {
            if (!onRequestBranch(d)) {
                if (dialog_views.chipButtonTagged(@src(), dvui.entypo.download, "Check out to apply", false, dialog_views.frameTag("pr:apply_checkout", t.id))) checkoutRequest(d.number, d.head, d.fork);
            } else if (dialog_views.chipButtonTagged(@src(), dvui.entypo.check, "Apply suggestion", true, dialog_views.frameTag("pr:apply", t.id))) applySuggestion(d.number, t, code);
        }
    }
    var lines = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = .{ .y = style.space.xs, .h = style.space.xs } });
    defer lines.deinit();
    // The lines before it in grey, for where it is; those it replaces in
    // red; what with in green.
    const span = threadSpan(t);
    const seen = hunkTail(a, t.hunk, span + SUGGESTION_CONTEXT);
    const before = seen.len -| span;
    for (seen, 0..) |old, n| diffLine(n, if (n < before) ' ' else '-', old);
    var it = std.mem.splitScalar(u8, code, '\n');
    var n: usize = 0;
    while (it.next()) |raw| : (n += 1) diffLine(1000 + n, '+', std.mem.trimEnd(u8, raw, "\r"));
}

/// One line of a suggestion's change, on a tint of what it does.
/// How many lines before a suggestion's show where it is.
const SUGGESTION_CONTEXT = 2;

/// One line of a suggestion's change, on a tint of what it does; a line
/// around it, `mark` a space, plain and faint.
fn diffLine(id: usize, mark: u8, text: []const u8) void {
    const context = mark == ' ';
    const hue = if (mark == '+') style.success() else if (context) style.textFaint() else style.danger();
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = !context,
        .color_fill = .{ .color = style.tint(hue) },
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer line.deinit();
    dvui.label(@src(), "{c}", .{mark}, .{ .font = style.graphMono(), .color_text = .{ .color = hue }, .min_size_content = .{ .w = 12 }, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{text}, .{ .font = style.graphMono(), .color_text = .{ .color = if (context) style.textFaint() else style.text() }, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
}

/// The branch a request is checked out as here: its own name, or
/// `pr/N` for one from a fork.
fn onRequestBranch(d: pr.Detail) bool {
    const h = history orelse return false;
    const head = h.head orelse return false;
    var buf: [32]u8 = undefined;
    const local = if (d.fork) std.fmt.bufPrint(&buf, "pr/{d}", .{d.number}) catch return false else d.head;
    return std.mem.eql(u8, head, local);
}

/// A suggestion written into the file here, over the lines it was left on —
/// once they still read as the comment saw them; otherwise the file moved
/// on since, and it would land on the wrong lines. The change is then the
/// working copy's, to look over, commit and push.
fn applySuggestion(number: u32, t: pr.Thread, code: []const u8) void {
    if (applySuggestionTo(dvui.currentWindow().arena(), repo_path.items, t, code)) |message| return setCommandError(message);
    markApplied(number, t.id);
    workChanged("Applying");
}

/// The suggestions applied here, by their thread's id, for request
/// `pr_applied_for`: their button says so rather than offer them again.
/// Fixed room, nothing to free: a review holds a handful.
var pr_applied: [16][64]u8 = undefined;
var pr_applied_len: [16]u8 = @splat(0);
var pr_applied_n: usize = 0;
var pr_applied_for: u32 = 0;

fn markApplied(number: u32, id: []const u8) void {
    if (pr_applied_for != number) {
        pr_applied_for = number;
        pr_applied_n = 0;
    }
    if (id.len > 64 or suggestionApplied(number, id)) return;
    const slot = pr_applied_n % pr_applied.len;
    @memcpy(pr_applied[slot][0..id.len], id);
    pr_applied_len[slot] = @intCast(id.len);
    pr_applied_n += 1;
}

fn suggestionApplied(number: u32, id: []const u8) bool {
    if (pr_applied_for != number) return false;
    for (0..@min(pr_applied_n, pr_applied.len)) |i| {
        if (std.mem.eql(u8, pr_applied[i][0..pr_applied_len[i]], id)) return true;
    }
    return false;
}

/// What went wrong, or null once it is written. In `a`, an arena.
fn applySuggestionTo(a: std.mem.Allocator, root: []const u8, t: pr.Thread, code: []const u8) ?[]const u8 {
    if (t.line == 0) return "GitHub did not say which lines that suggestion is for.";
    const abs = std.fs.path.join(a, &.{ root, t.path }) catch return "Out of memory.";
    const text = std.Io.Dir.cwd().readFileAlloc(app_io, abs, a, .limited(64 << 20)) catch return "Could not read that file here.";
    const crlf = std.mem.indexOf(u8, text, "\r\n") != null;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| lines.append(a, std.mem.trimEnd(u8, l, "\r")) catch return "Out of memory.";
    // A last newline leaves an empty piece after it, which is no line.
    const ends_nl = text.len > 0 and text[text.len - 1] == '\n';
    if (ends_nl) _ = lines.pop();

    const span = threadSpan(t);
    const first = t.line + 1 - span;
    const moved = std.fmt.allocPrint(a, "{s} has changed since that comment: apply it by hand.", .{t.path}) catch "The file has changed since that comment.";
    if (t.line > lines.items.len) return moved;
    const seen = hunkTail(a, t.hunk, span);
    if (seen.len == span) for (seen, 0..) |want, i| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, want, "\r"), lines.items[first - 1 + i])) return moved;
    };

    var out: std.ArrayList(u8) = .empty;
    const eol: []const u8 = if (crlf) "\r\n" else "\n";
    var wrote: usize = 0;
    const put = struct {
        fn f(o: *std.ArrayList(u8), al: std.mem.Allocator, n: *usize, line: []const u8, sep: []const u8) void {
            if (n.* > 0) o.appendSlice(al, sep) catch {};
            o.appendSlice(al, line) catch {};
            n.* += 1;
        }
    }.f;
    for (lines.items[0 .. first - 1]) |l| put(&out, a, &wrote, l, eol);
    // An empty suggestion takes the lines out.
    if (code.len > 0) {
        var ct = std.mem.splitScalar(u8, code, '\n');
        while (ct.next()) |l| put(&out, a, &wrote, std.mem.trimEnd(u8, l, "\r"), eol);
    }
    for (lines.items[t.line..]) |l| put(&out, a, &wrote, l, eol);
    if (ends_nl and wrote > 0) out.appendSlice(a, eol) catch {};
    std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = abs, .data = out.items }) catch return "Could not write that file.";
    return null;
}

/// A word on a tint of its colour: Resolved, Outdated.
fn tinyBadge(src: std.builtin.SourceLocation, id: usize, text: []const u8, hue: dvui.Color) void {
    var b = dvui.box(src, .{}, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.tint(hue) },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .padding = .{ .x = style.space.xs, .w = style.space.xs },
        .margin = .{ .x = style.space.xs },
    });
    defer b.deinit();
    dvui.label(@src(), "{s}", .{text}, .{ .font = style.tiny(), .color_text = .{ .color = hue }, .padding = dvui.Rect.all(0) });
}

/// A GitHub node id as it goes into a query: letters, digits, `_` and `-`,
/// nothing that could close the string around it.
fn safeNodeId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn setThreadResolved(id: []const u8, resolved: bool) void {
    if (!safeNodeId(id)) return;
    const v = std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"id\":\"{s}\"}}", .{id}) catch return;
    if (resolved)
        requestGraphql("Resolving", "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id}}}", v, .none)
    else
        requestGraphql("Reopening", "mutation($id:ID!){unresolveReviewThread(input:{threadId:$id}){thread{id}}}", v, .none);
}

/// The reply goes in as a variable, never spliced into the query; the box
/// empties once GitHub has it.
fn replyToThread() void {
    const text = std.mem.trim(u8, pr_reply.items, " \n\t");
    if (text.len == 0 or !safeNodeId(pr_reply_id.items)) return;
    const a = dvui.currentWindow().arena();
    requestGraphql("Replying", "mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){comment{id}}}", jsonFields(a, &.{ .{ "id", pr_reply_id.items }, .{ "body", text } }), .clear_reply);
}

const PrAnswer = enum { comment, approve, request_changes };

/// The review box's three buttons: a comment on the conversation, or a
/// review with its verdict. The box empties once GitHub has it.
fn prAnswer(kind: PrAnswer) void {
    const text = std.mem.trim(u8, pr_comment.items, " \n\t");
    const number = pr_selected orelse return;
    const a = dvui.currentWindow().arena();
    var path: [512]u8 = undefined;
    switch (kind) {
        .comment => requestApi("Commenting", "POST", apiPath(&path, "/issues/{d}/comments", .{number}), jsonFields(a, &.{.{ "body", text }}), .clear_comment),
        .approve => requestApi("Approving", "POST", apiPath(&path, "/pulls/{d}/reviews", .{number}), jsonFields(a, &.{ .{ "event", "APPROVE" }, .{ "body", text } }), .clear_comment),
        .request_changes => requestApi("Requesting changes", "POST", apiPath(&path, "/pulls/{d}/reviews", .{number}), jsonFields(a, &.{ .{ "event", "REQUEST_CHANGES" }, .{ "body", text } }), .clear_comment),
    }
}

/// The branches panel, unless hidden by hand or squeezed out by the
/// changes panel being dragged wide.
pub fn leftShown() bool {
    return show_sidebar and active_view == .graph and !left_squeezed;
}

/// Set while the panel on the right is wide enough to push the branches out:
/// the mirror of the branches pushing it out, which the content split does
/// by collapsing under its own minimum.
var left_squeezed: bool = false;
/// The width of the window's body, last frame.
pub var body_width: f32 = 0;
/// Narrower than this, the commit list gives up the branches panel.
const GRAPH_MIN = 380;

/// History: the commit list, and what the selected commit — or the working
/// tree — holds, beside it.
fn graphView() void {
    var split = dvui.paned(@src(), .{
        .direction = .horizontal,
        // Under this there is no room for both, and the list is the view.
        .collapsed_size = 760,
        .split_ratio = if (show_detail) &detail_split else &all_split,
        .handle_size = 1,
        .draw_in_deinit = false,
    }, .{ .expand = .both, .background = false });
    defer split.deinit();
    if (show_detail and show_sidebar and active_view != .pulls and !split.collapsed()) {
        const graph_w = split.data().contentRect().w * detail_split;
        const left_w = body_width * sidebar_split;
        // Back only once there is room for it again, so the seam does not
        // flicker between the two.
        const squeeze = if (left_squeezed) graph_w - left_w < GRAPH_MIN + 40 else graph_w < GRAPH_MIN;
        if (squeeze != left_squeezed) {
            left_squeezed = squeeze;
            dvui.refresh(null, @src(), null);
        }
    } else if (left_squeezed) {
        // Nothing on the right to push it out any more — the changes panel
        // hidden, or the list alone under the collapse width.
        left_squeezed = false;
        dvui.refresh(null, @src(), null);
    }

    // A file's diff takes the graph's place, and the panel on the right —
    // where it was picked — stays put for the next one.
    if (split.showFirst()) {
        if (diffOpen()) diff_view.diffPanel() else graph_view.graphPanel();
    }
    if (show_detail and split.showSecond()) commit_view.detailPanel();
}

/// True when this key event is exactly `code`, with Ctrl held or not as
/// asked, and nothing else: no Shift — a chord with it is `pressedShift`'s,
/// so Ctrl+Shift+Z is never also Ctrl+Z — no Alt, which keeps out AltGr
/// (Windows sends it as Ctrl+Alt, so AltGr+Z on a layout that types with
/// it would otherwise undo), and no Windows or Command key, the system's.
///
/// dvui has a named-keybind table for this, with fallback chains and user
/// overrides; this many shortcuts do not need one.
pub fn pressed(ke: dvui.Event.Key, code: dvui.enums.Key, ctrl: bool) bool {
    return ke.code == code and ke.mod.control() == ctrl and !ke.mod.shift() and !ke.mod.alt() and !ke.mod.command();
}

/// As `pressed`, for Ctrl+Shift+`code`.
fn pressedShift(ke: dvui.Event.Key, code: dvui.enums.Key) bool {
    return ke.code == code and ke.mod.control() and ke.mod.shift() and !ke.mod.alt() and !ke.mod.command();
}

/// Everything that can be done without the mouse.
///
/// Runs after the whole frame is built, over the events no widget claimed:
/// that is what keeps Esc from closing the diff while someone is typing a
/// commit message, without this having to know where the focus is.
///
/// None of them is Ctrl+Space, Ctrl+Shift alone or Alt-anything: Windows
/// gives those to the input method, the keyboard layout and AltGr.
fn shortcuts() void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        // Whatever a shortcut changed is drawn now, not at the next mouse
        // move: most of them only flip state — the palette, a panel, a tab —
        // and nothing else asks for a frame.
        defer if (e.handled) dvui.refresh(null, @src(), null);

        const ke = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (ke.action == .up) continue;

        // In a conflicted file the keys answer it — before the history's
        // arrows below, which would otherwise take ↑ and ↓. Only where it
        // is on screen: not from the requests' view over it.
        if (active_view == .graph and rebase_view.isConflictView() and !typing() and conflictKey(ke)) {
            e.handled = true;
            continue;
        }
        // Over the requests: ↑ ↓ (or k j) along the list, 1 to 4 for its tabs.
        if (active_view == .pulls and !new_tab_open and !typing() and pullsKey(ke)) {
            e.handled = true;
            continue;
        }

        // Up and down walk the history the way they walk a mail list: the pane
        // on the right follows, which is the whole point of reading a diff.
        // The only keys held down to repeat. Not over the pull requests,
        // which hide the history: there they would move it out of sight.
        if (active_view == .graph and (pressed(ke, .up, false) or pressed(ke, .down, false))) {
            e.handled = true;
            stepCommit(if (ke.code == .up) -1 else 1);
            continue;
        }
        // Everything else once per press: a held Ctrl+Z must not undo the
        // history away one repeat at a time.
        if (ke.action != .down) continue;

        // Esc backs out of one thing at a time, innermost first: the bar you
        // are answering, then the pane you are reading.
        if (pressed(ke, .escape, false)) {
            e.handled = true;
            if (prompt != null) {
                clearPrompt();
            } else if (confirm != null) {
                clearConfirm();
            } else if (commit_view.picked_changes.items.len > 0) {
                commit_view.clearPickedChanges();
            } else if (searchFocused()) {
                // Esc in the search empties it, and a second one puts it
                // away. Only there: everywhere else it means the pane, and
                // closing the diff you were reading because the cursor
                // happened to be in a field is a surprise.
                if (commit_filter.items.len > 0) commit_filter.clearRetainingCapacity() else graph_view.closeSearch();
            } else if (new_tab_open and repo != null) {
                new_tab_open = false;
            } else if (active_view == .pulls) {
                // Out of the requests, back to the history, as the tab's
                // second click does.
                closePulls();
            } else if (diffOpen()) {
                closeDiff();
            } else if (selection != .none) {
                clearSelection();
            } else if (graph_view.file_history.items.len > 0) {
                graph_view.clearFileHistory();
            }
            continue;
        }

        const Run = *const fn () void;
        const chord: ?Run = blk: {
            if ((pressed(ke, .enter, true) or pressed(ke, .kp_enter, true)) and active_view == .pulls) break :blk struct {
                fn f() void {
                    // A reply being written goes to its thread; otherwise
                    // the review box's text, as a comment: the button that
                    // needs nothing more.
                    if (pr_reply_id.items.len > 0 and std.mem.trim(u8, pr_reply.items, " \n\t").len > 0) return replyToThread();
                    if (std.mem.trim(u8, pr_comment.items, " \n\t").len > 0) prAnswer(.comment);
                }
            }.f;
            if ((pressed(ke, .enter, true) or pressed(ke, .kp_enter, true)) and canCommit()) break :blk struct {
                fn f() void {
                    requestAction(.commit);
                }
            }.f;
            // With nothing to commit, the same keys go on with what is under
            // way once its conflicts are answered.
            if ((pressed(ke, .enter, true) or pressed(ke, .kp_enter, true)) and canContinue()) break :blk requestContinue;
            if (pressed(ke, .f5, false) or pressed(ke, .r, true)) break :blk struct {
                fn f() void {
                    requestAction(.refresh);
                }
            }.f;
            if (pressed(ke, .o, true)) break :blk struct {
                fn f() void {
                    requestAction(.open_repo);
                }
            }.f;
            if (pressed(ke, .t, true)) break :blk struct {
                fn f() void {
                    new_tab_open = true;
                }
            }.f;
            if (pressedShift(ke, .t)) break :blk openTerminal;
            if (pressed(ke, .p, true)) break :blk openPalette;
            if (pressed(ke, .comma, true)) break :blk struct {
                fn f() void {
                    openSettings(5);
                }
            }.f;
            if (pressed(ke, .b, true)) break :blk struct {
                fn f() void {
                    show_sidebar = !show_sidebar;
                }
            }.f;
            if (pressed(ke, .j, true)) break :blk struct {
                fn f() void {
                    show_detail = !show_detail;
                }
            }.f;
            // Ctrl+F: the commit search, where the graph is up.
            if (pressed(ke, .f, true)) break :blk struct {
                fn f() void {
                    // The search of what is on screen: the requests' in their
                    // view, not the hidden graph's.
                    if (active_view == .pulls) {
                        if (dvui.tagGet("pr_search")) |field| dvui.focusWidget(field.id, null, null);
                        return;
                    }
                    graph_view.search_open = true;
                    if (dvui.tagGet("commit_filter")) |field| dvui.focusWidget(field.id, null, null);
                }
            }.f;
            // Tab to tab, as a browser goes: Ctrl+Tab and Ctrl+PgDn on, the
            // Shift or PgUp back; Ctrl+Shift+PgUp/PgDn carries the tab along.
            if (pressed(ke, .tab, true) or pressed(ke, .page_down, true)) break :blk struct {
                fn f() void {
                    cycleTab(1);
                }
            }.f;
            if (pressedShift(ke, .tab) or pressed(ke, .page_up, true)) break :blk struct {
                fn f() void {
                    cycleTab(-1);
                }
            }.f;
            if (pressedShift(ke, .page_up)) break :blk struct {
                fn f() void {
                    shiftTab(-1);
                }
            }.f;
            if (pressedShift(ke, .page_down)) break :blk struct {
                fn f() void {
                    shiftTab(1);
                }
            }.f;
            // Not while typing: in a text field these are the field's own
            // close, undo and redo, and taking back a commit from inside the
            // message box is not what anybody pressed them for.
            if (typing()) break :blk null;
            if (pressed(ke, .w, true)) break :blk closeShownTab;
            if (pressed(ke, .z, true)) break :blk requestUndo;
            if (pressedShift(ke, .z) or pressed(ke, .y, true)) break :blk requestRedo;
            break :blk null;
        };
        if (chord) |run_it| {
            e.handled = true;
            run_it();
        }
    }
}

/// The requests' keys: ↑ ↓ or k j along the list, held to repeat; 1 2 3 4
/// for the conversation, the commits, the files and the checks.
fn pullsKey(ke: dvui.Event.Key) bool {
    if (pressed(ke, .down, false) or pressed(ke, .j, false)) {
        stepRequest(1);
        return true;
    }
    if (pressed(ke, .up, false) or pressed(ke, .k, false)) {
        stepRequest(-1);
        return true;
    }
    if (ke.action != .down) return false;
    const tabs = [_]struct { dvui.enums.Key, PrTab }{ .{ .one, .conversation }, .{ .two, .commits }, .{ .three, .files }, .{ .four, .checks } };
    for (tabs) |tab| if (pressed(ke, tab[0], false)) {
        pr_tab = tab[1];
        return true;
    };
    return false;
}

/// The conflict view's keys, GitComet's way: ↑ ↓ or F2 F3 from region to
/// region, 1 2 3 keep the left side, the right one or both, U or Ctrl+Z take
/// the last pick back, Enter stages a file with nothing left in it and goes
/// to the next, F4 goes to the next conflicted file. True when one was it.
fn conflictKey(ke: dvui.Event.Key) bool {
    const step: i2 = if (pressed(ke, .down, false) or pressed(ke, .f3, false) or pressed(ke, .j, false))
        1
    else if (pressed(ke, .up, false) or pressed(ke, .f2, false) or pressed(ke, .k, false))
        -1
    else
        0;
    if (step != 0) {
        moveConflictFocus(step);
        return true;
    }
    // Picks and stages once per press: a held key is not five picks.
    if (ke.action != .down) return false;
    if (pressed(ke, .one, false) or pressed(ke, .kp_1, false)) return pickFocused(.ours);
    if (pressed(ke, .two, false) or pressed(ke, .kp_2, false)) return pickFocused(.theirs);
    if (pressed(ke, .three, false) or pressed(ke, .kp_3, false)) return pickFocused(.both);
    if (pressed(ke, .u, false) or pressed(ke, .z, true)) {
        // Ctrl+Z here never reaches the reflog's undo: mid-merge it would
        // reset under it.
        if (resolve_undo.items.len > 0) requestAction(.undo_resolve);
        return true;
    }
    if ((pressed(ke, .enter, false) or pressed(ke, .kp_enter, false)) and conflicts.len == 0 and !conflict_binary and
        conflict_kind != .deleted_by_us and conflict_kind != .deleted_by_them)
    {
        requestAction(.stage_next);
        return true;
    }
    if (pressed(ke, .f4, false)) {
        openNextConflict();
        return true;
    }
    return false;
}

fn moveConflictFocus(step: i2) void {
    if (conflicts.len == 0) return;
    if (step > 0) {
        conflict_focus = @min(conflict_focus + 1, conflicts.len - 1);
    } else {
        conflict_focus -|= 1;
    }
    conflict_reveal = true;
}

fn pickFocused(side: git.ConflictSide) bool {
    if (conflict_focus >= conflicts.len) return false;
    requestResolve(conflict_focus, side);
    return true;
}

/// The tab `delta` along from the one shown, across groups, round the ends.
fn cycleTab(delta: i2) void {
    if (repo == null) return;
    var total: usize = 0;
    var at: usize = 0;
    for (tab_strip.groups.items, 0..) |group, g| {
        if (group.ws != tab_strip.active_ws) continue;
        if (g == tab_strip.active_group) at = total + tab_strip.active_tab;
        total += group.tabs.items.len;
    }
    if (total < 2) return;
    const next = (at + total + @as(usize, if (delta > 0) 1 else total - 1)) % total;
    var base: usize = 0;
    for (tab_strip.groups.items, 0..) |group, g| {
        if (group.ws != tab_strip.active_ws) continue;
        if (next < base + group.tabs.items.len) return requestTab(.{ .select_in = .{ g, next - base } });
        base += group.tabs.items.len;
    }
}

/// The tab shown, one place left or right in its group.
fn shiftTab(delta: i2) void {
    if (repo == null or new_tab_open) return;
    if (delta < 0 and tab_strip.active_tab == 0) return;
    const to = if (delta < 0) tab_strip.active_tab - 1 else tab_strip.active_tab + 1;
    requestTab(.{ .tab_at = .{ tab_strip.active_group, tab_strip.active_tab, tab_strip.active_group, to } });
}

/// Whether a text field has the keyboard — the one a focused text entry asks
/// the backend to put an input method over.
pub fn typing() bool {
    return dvui.currentWindow().textInputRequested() != null;
}

/// True when the commit search box is what has the keyboard.
fn searchFocused() bool {
    const field = dvui.tagGet("commit_filter") orelse return false;
    const focused = dvui.focusedWidgetId() orelse return false;
    return focused == field.id;
}

/// Whether the commit button — and Ctrl+Enter — would do anything.
///
/// Amending rewrites the last commit, so it is legitimate with nothing staged:
/// that is how you fix a message.
pub fn canCommit() bool {
    if (commit_summary.items.len == 0) return false;
    if (amend) return true;
    const w = work orelse return false;
    return w.staged.len > 0;
}

/// Select the commit `delta` rows from the one selected now.
///
/// Only from the graph or another commit: in a file diff, a blame or the rebase
/// composer, an arrow key means what that pane says it means.
pub fn stepCommit(delta: i2) void {
    const h = history orelse return;

    // The commits the search lets through — every one without a search —
    // in the list's order: while searching, ↑ and ↓ go match to match.
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(gpa);
    graph_view.shownRows(gpa, h.commits, &rows);
    if (rows.items.len == 0) return;

    const row: usize = switch (selection) {
        .none => if (delta > 0) 0 else rows.items.len - 1,
        .commit => |id| blk: {
            const index = h.indexOf(id) orelse break :blk 0;
            const at = std.mem.indexOfScalar(u32, rows.items, @intCast(index)) orelse {
                // A commit the search leaves out: the next match that way.
                const after = for (rows.items, 0..) |r, k| {
                    if (r > index) break k;
                } else rows.items.len;
                if (delta > 0) break :blk if (after < rows.items.len) after else return;
                break :blk if (after > 0) after - 1 else return;
            };
            const next = @as(i64, @intCast(at)) + delta;
            // Stop at the ends rather than wrapping: a list that wraps loses
            // you the moment you lean on the key.
            if (next < 0 or next >= rows.items.len) return;
            break :blk @intCast(next);
        },
        else => return,
    };

    selectCommit(h.commits[rows.items[row]].id);
    if (graph_view.listRow(rows.items[row], rows.items)) |at| revealCommit(at);
}

/// Scroll the graph so list row `row` is on screen, for whenever it comes back.
pub fn revealCommit(row: usize) void {
    const rh = style.graph_row;
    const y = @as(f32, @floatFromInt(row)) * rh;
    const view = graph_scroll.viewport;
    // Viewport height is last frame's, which is this frame's on every frame
    // but the first.
    if (view.h <= 0) return;

    if (y < view.y) {
        graph_scroll.viewport.y = y;
    } else if (y + rh > view.y + view.h) {
        graph_scroll.viewport.y = y + rh - view.h;
    }
}

/// Name the window after what it is showing.
///
/// Compared against what is already up rather than set every frame: this is a
/// call into the window manager, and the answer changes about once a minute.
var window_title: [256]u8 = undefined;
var window_title_len: usize = 0;

fn updateWindowTitle() void {
    var buf: [256]u8 = undefined;

    const text = blk: {
        if (repo == null) break :blk "Zit";
        const branch = if (history) |h| (h.head orelse "detached") else "";
        if (branch.len == 0) break :blk std.fmt.bufPrint(&buf, "{s} — Zit", .{repo_name}) catch "Zit";
        break :blk std.fmt.bufPrint(&buf, "{s} · {s} — Zit", .{ repo_name, branch }) catch "Zit";
    };

    if (std.mem.eql(u8, text, window_title[0..window_title_len])) return;
    if (text.len > window_title.len) return;

    @memcpy(window_title[0..text.len], text);
    window_title_len = text.len;

    const cw = dvui.currentWindow();
    cw.backend.title(cw, text);
}

// === Git identity ===
//
// The name and email every commit is signed with, which git refuses to commit
// without. Typed in, or taken from the GitHub account Zit is connected as —
// connecting it on the way if need be.

var identity_open: bool = false;
var identity_rect: dvui.Rect = .{};
var identity_name: std.ArrayList(u8) = .empty;
var identity_email: std.ArrayList(u8) = .empty;
var identity_note: []const u8 = "";

/// git's global `user.name` and `user.email`, into `name` and `email`, by one
/// `git` rather than one each: on Windows starting it is most of the wait.
/// Through `git`, not libgit2, which would not see the global config a test
/// hands over in `run.env_override`. True when both are set.
pub fn readIdentity(name: *std.ArrayList(u8), email: *std.ArrayList(u8)) bool {
    name.clearRetainingCapacity();
    email.clearRetainingCapacity();
    const answer = run.capture(gpa, app_io, ".", &.{ "git", "config", "--global", "--get-regexp", "^user\\.(name|email)$" }) catch return false;
    defer gpa.free(answer.out);
    if (!answer.ok) return false;
    var lines = std.mem.splitScalar(u8, answer.out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const out = if (std.mem.eql(u8, line[0..space], "user.name")) name else if (std.mem.eql(u8, line[0..space], "user.email")) email else continue;
        // Said twice, the last one holds.
        out.clearRetainingCapacity();
        out.appendSlice(gpa, std.mem.trim(u8, line[space + 1 ..], " ")) catch return false;
    }
    return name.items.len > 0 and email.items.len > 0;
}

fn identitySet() bool {
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    var email: std.ArrayList(u8) = .empty;
    defer email.deinit(gpa);
    return readIdentity(&name, &email);
}

pub fn openIdentity() void {
    identity_open = true;
    identity_rect = .{};
    identity_note = "";
    _ = readIdentity(&identity_name, &identity_email);
}

/// Fill the fields from the signed-in GitHub account. The noreply address
/// where the account keeps its email private: commits still link to it.
/// A request to GitHub, on this thread: a click's worth of wait.
fn fillFromGithub() bool {
    if (!github.signedIn()) return false;
    const got = github.call("GET", "/user", null) catch return false;
    defer got.deinit();
    const answer = got.answer();
    if (!answer.ok()) return false;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const user = std.json.parseFromSliceLeaky(struct {
        login: []const u8 = "",
        id: u64 = 0,
        name: ?[]const u8 = null,
        email: ?[]const u8 = null,
    }, a.allocator(), answer.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return false;
    if (user.login.len == 0) return false;

    identity_name.clearRetainingCapacity();
    identity_name.appendSlice(gpa, user.name orelse user.login) catch {};
    identity_email.clearRetainingCapacity();
    if (user.email) |email| {
        identity_email.appendSlice(gpa, email) catch {};
    } else {
        identity_email.print(gpa, "{d}+{s}@users.noreply.github.com", .{ user.id, user.login }) catch {};
    }
    return true;
}

pub fn signInWithGithub() void {
    if (fillFromGithub()) {
        identity_note = "Filled in from your GitHub account.";
        return;
    }
    // Not signed in: Zit's own sign-in, and the fields filled once it lands.
    connect_fills_identity = true;
    openConnect();
}

fn saveIdentity() void {
    const name = std.mem.trim(u8, identity_name.items, " ");
    const email = std.mem.trim(u8, identity_email.items, " ");
    if (name.len == 0 or email.len == 0) {
        identity_note = "Both a name and an email are needed.";
        return;
    }
    for ([_][2][]const u8{ .{ "user.name", name }, .{ "user.email", email } }) |kv| {
        var outcome = run.git(gpa, app_io, ".", &.{ "config", "--global", kv[0], kv[1] }) catch {
            identity_note = "Could not run git. Is it installed?";
            return;
        };
        defer outcome.deinit(gpa);
        if (!outcome.ok) {
            identity_note = "git would not save it.";
            return;
        }
    }
    identity_open = false;
    window_chrome.me_loaded = false;
}

fn identityDialog() void {
    if (!identity_open) return;

    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &identity_rect, &identity_open, style.surface(), 480, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);

    dialogHeader(@src(), dvui.entypo.user, "Who are you, to git?", "Every commit carries a name and an email. Set once, for every repository", &identity_open);

    var body = dialogBody(@src(), null);

    {
        var gh_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer gh_row.deinit();
        const busy = connect_open;
        if (dialog_views.dialogButton(@src(), if (busy) "Waiting for GitHub…" else "Sign in with GitHub", true) and !busy) signInWithGithub();
        dvui.label(@src(), "or type them in", .{}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.md },
            .padding = dvui.Rect.all(0),
        });
    }

    var entered = false;
    _ = dialog_views.dialogField(@src(), 10, "Name", &identity_name, "Ada Lovelace", identity_name.items.len == 0, &entered);
    _ = dialog_views.dialogField(@src(), 11, "Email", &identity_email, "ada@example.com", false, &entered);

    if (identity_note.len > 0) {
        dvui.label(@src(), "{s}", .{identity_note}, .{
            .font = style.small(),
            .color_text = .{ .color = style.accent() },
            .margin = .{ .h = style.space.lg },
            .padding = dvui.Rect.all(0),
        });
    }

    body.deinit();
    {
        var foot = dialogFooter(@src());
        defer foot.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButton(@src(), "Later", false)) identity_open = false;
        if (dialog_views.dialogButton(@src(), "Save", true) or entered) saveIdentity();
    }

    if (dialog_views.escapePressed()) identity_open = false;
}

pub fn openSettings(section: usize) void {
    settings_open = true;
    settings_rect = .{};
    signing_loaded = false;
    repo_prefs_loaded = false;
    editors_loaded = false;
    // The repository whose settings show: the one open, to start with.
    if (repo != null) {
        repo_settings_path.clearRetainingCapacity();
        repo_settings_path.appendSlice(gpa, repo_path.items) catch {};
    }
    settings_page = section;
}

/// The settings, in one dialog: the sections down the left, grouped by what
/// they are about — Zit itself, then the commits made from it — and the one
/// picked on the right. Everything is saved as it is changed.
var settings_open = false;
var settings_rect: dvui.Rect = .{};
/// The section shown, by id.
var settings_page: usize = 5;

const SettingsPage = struct { id: usize, icon: []const u8, title: []const u8, hint: []const u8 };
/// In the order the list shows them; a null is the next group's caption.
const settings_pages = [_]?SettingsPage{
    null,
    .{ .id = 5, .icon = dvui.entypo.cog, .title = "General", .hint = "Tabs, new repositories, fetching" },
    .{ .id = 3, .icon = dvui.entypo.merge, .title = "Integrations", .hint = "GitHub: pull requests, issues, checks and the account" },
    .{ .id = 0, .icon = dvui.entypo.palette, .title = "Appearance", .hint = "The theme, the size of the text, the pictures" },
    null,
    .{ .id = 1, .icon = dvui.entypo.user, .title = "Git identity", .hint = "The name and email your commits carry" },
    .{ .id = 2, .icon = dvui.entypo.pencil, .title = "Commit messages", .hint = "Ticket, conventional commits, template" },
    .{ .id = 6, .icon = dvui.entypo.lock, .title = "Commit signing", .hint = "GPG or SSH, for commits and tags" },
    null,
    .{ .id = REPO_PAGE, .icon = dvui.entypo.folder, .title = "Repositories", .hint = "Its own identity, pull and signing — in its .git/config" },
};
const settings_groups = [_][]const u8{ "Zit", "Commits", "Repositories" };
/// The page of one repository's settings, which it the nav lists by name.
const REPO_PAGE = 7;

fn settingsDialog() void {
    if (!settings_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &settings_rect, &settings_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);

    dialogHeader(@src(), dvui.entypo.cog, "Settings", "Zit " ++ APP_VERSION ++ " · everything is saved as you change it", &settings_open);

    // One size whichever section shows, so the dialog does not jump.
    const w: f32 = @min(860, win.w - 80);
    const h: f32 = @max(240, @min(520, win.h - 240));
    {
        var split = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = w, .h = h },
            .max_size_content = .size(.{ .w = w, .h = h }),
            .background = false,
        });
        defer split.deinit();
        settingsNav();
        // Its ground the dialog's: dvui's scroll container paints its own,
        // the window's darker one, under whatever it holds.
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .color_fill = .{ .color = style.surface() } });
        defer scroll.deinit();
        // On the dialog's ground, over the scroll container's darker one.
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.xl, .h = style.space.xl },
        });
        defer body.deinit();

        if (SettingsCard.begin(5)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();

            var changed = settingsSwitch(0, &tab_strip.remember_tabs, "Reopen your tabs", "Start where you left off, rather than on the start page");

            settingsField(@src(), "Default branch", "The first branch of a repository made here");
            const branch = dialog_views.textField(@src(), .{
                .text = .{ .array_list = .{ .backing = &tab_strip.default_branch, .allocator = gpa, .limit = 128 } },
                .placeholder = "main",
            }, settingsInput().override(.{
                .tag = "default_branch",
            }));
            if (branch.text_changed) changed = true;
            branch.deinit();

            settingsField(@src(), "External editor", "What a file from a diff opens with");
            if (editorChoice()) changed = true;

            settingsField(@src(), "Terminal", "What Terminal opens, in the repository's folder");
            if (terminalChoice()) changed = true;

            settingsField(@src(), "Fetch in the background", "Every remote, quietly — the counts on Pull and Push stay true");
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
                defer row.deinit();
                for ([_]u32{ 0, 5, 10, 30 }, 0..) |minutes, i| {
                    var buf: [16]u8 = undefined;
                    const caption = if (minutes == 0) "Never" else std.fmt.bufPrint(&buf, "every {d} min", .{minutes}) catch "?";
                    var chip = dvui.box(@src(), .{}, .{ .id_extra = i, .background = false });
                    defer chip.deinit();
                    if (dialog_views.chipButton(@src(), if (tab_strip.auto_fetch_minutes == minutes) dvui.entypo.check else dvui.entypo.clock, caption, tab_strip.auto_fetch_minutes == minutes)) {
                        tab_strip.auto_fetch_minutes = minutes;
                        changed = true;
                    }
                }
            }
            changed = settingsSwitch(1, &tab_strip.prune_on_fetch, "Prune when fetching", "Drop the remote branches deleted on the remote") or changed;

            if (changed) tab_strip.saveWorkspace();
        }
        if (SettingsCard.begin(3)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();
            var on = tab_strip.integrations;
            if (settingsSwitch(0, &on, "Use GitHub", "Pull requests, issues, checks and the account. Off: none of it, and nothing asked of GitHub")) tab_strip.setIntegrations(on);
            // Who Zit is connected as, and the way in or out.
            if (tab_strip.integrations) {
                window_chrome.loadMe();
                settingsField(@src(), "Account", "A code typed on github.com — the token it gives is kept readable by you alone");
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = style.surface() },
                    .border = dvui.Rect.all(1),
                    .color_border = .{ .color = style.border() },
                    .corners = style.radius.row,
                    .padding = dvui.Rect.all(style.space.md),
                });
                defer row.deinit();
                dvui.icon(@src(), "gh_state", if (window_chrome.me_gh.items.len > 0) dvui.entypo.check else dvui.entypo.login, .{ .fill_color = .{ .color = if (window_chrome.me_gh.items.len > 0) style.success() else style.textFaint() } }, .{
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = style.space.md },
                });
                if (window_chrome.me_gh.items.len > 0)
                    dvui.label(@src(), "Connected as {s}", .{window_chrome.me_gh.items}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) })
                else
                    dvui.label(@src(), "Not connected", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
                if (window_chrome.me_gh.items.len > 0) {
                    if (dialog_views.dialogButton(@src(), "Disconnect", false)) ask(.sign_out, window_chrome.me_gh.items);
                } else if (dialog_views.dialogButton(@src(), "Connect GitHub", true)) openConnect();
            }
        }
        if (SettingsCard.begin(0)) |card| {
            defer card.end();
            // Three a row: Zit's own, then Catppuccin's.
            for (0..(style.themes.len + 2) / 3) |r| {
                var cards = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                    .id_extra = r,
                    .expand = .horizontal,
                    .background = false,
                    .padding = settings_body_pad,
                });
                defer cards.deinit();
                for (r * 3..@min(r * 3 + 3, style.themes.len)) |i| {
                    if (themeCard(@src(), i) and i != theme_index) pickTheme(i);
                }
            }
            {
                var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = settings_body_pad });
                defer section.deinit();
                settingsField(@src(), "Text size", "The app's words, apart from the zoom");
                const ui_steps = [_]f32{ 0.9, 1, 1.08, 1.16 };
                if (choiceChips(10, &.{ "Small", "Default", "Large", "Larger" }, nearestStep(&ui_steps, style.ui_scale))) |i| {
                    style.ui_scale = ui_steps[i];
                    tab_strip.saveWorkspace();
                }
                settingsField(@src(), "Editor text size", "The code of a diff or a blame");
                const code_steps = [_]f32{ 10.0 / 11.0, 1, 12.0 / 11.0, 13.0 / 11.0, 14.0 / 11.0 };
                if (choiceChips(11, &.{ "10", "11", "12", "13", "14" }, nearestStep(&code_steps, style.code_scale))) |i| {
                    style.code_scale = code_steps[i];
                    tab_strip.saveWorkspace();
                }
            }
            {
                var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = settings_body_pad });
                defer section.deinit();
                if (settingsSwitch(0, &tab_strip.show_avatars, "Pictures in the graph", "Each commit its author's picture. Off: a dot")) tab_strip.saveWorkspace();
            }
        }
        if (SettingsCard.begin(REPO_PAGE)) |card| {
            defer card.end();
            repoSettings();
        }
        if (SettingsCard.begin(1)) |card| {
            defer card.end();
            window_chrome.loadMe();
            const me = window_chrome.meAsCommit();
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer row.deinit();
            search_view.avatarSized(@src(), 0, me, null, null, 32);
            {
                var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.xs } });
                defer col.deinit();
                const set = window_chrome.me_name.items.len > 0 and window_chrome.me_email.items.len > 0;
                dvui.label(@src(), "{s}", .{if (set) me.author else "Not set yet"}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
                dvui.label(@src(), "{s}", .{if (set) me.email else "Commits need a name and an email"}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0) });
                dvui.label(@src(), "For every repository, in git's global config", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2 } });
            }
            if (dialog_views.dialogButton(@src(), "Edit…", false)) openIdentity();
        }
        if (SettingsCard.begin(2)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();

            var changed = false;
            changed = settingsSwitch(0, &commit_prefs.ticket, "Ticket from the branch", "PROJ-80-Back-Login puts PROJ-80 in the message") or changed;
            if (commit_prefs.ticket) {
                changed = settingsSwitch(1, &commit_prefs.ticket_footer, "Ticket as a trailer", "Refs: PROJ-80 at the end, rather than at the head of the summary") or changed;
            }
            changed = settingsSwitch(2, &commit_prefs.conventional, "Conventional commits", "A type and a scope before the summary: feat(api): …") or changed;
            changed = settingsSwitch(3, &commit_prefs.wrap_body, "Wrap the description", "Long lines broken at 72 columns, as git log expects") or changed;
            changed = settingsSwitch(4, &commit_prefs.signoff, "Sign off", "A Signed-off-by line on every commit") or changed;

            dvui.label(@src(), "Template", .{}, .{
                .font = style.small(),
                .color_text = .{ .color = style.text() },
                .margin = .{ .y = style.space.md },
                .padding = dvui.Rect.all(0),
            });
            dvui.label(@src(), "Used when git's commit.template names none. The first line is the summary.", .{}, .{
                .font = style.tiny(),
                .color_text = .{ .color = style.textFaint() },
                .margin = .{ .h = style.space.sm },
                .padding = dvui.Rect.all(0),
            });
            const te = dialog_views.textField(@src(), .{
                .text = .{ .array_list = .{ .backing = &commit_template, .allocator = gpa, .limit = 4096 } },
                .multiline = true,
                .break_lines = true,
                .placeholder = "e.g. a summary line, then the sections every description should have",
            }, settingsInput().override(.{
                .tag = "commit_template",
                .min_size_content = .{ .h = 72 },
            }));
            if (te.text_changed) changed = true;
            te.deinit();

            if (changed) tab_strip.saveWorkspace();
        }
        if (SettingsCard.begin(6)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();
            loadSigning();

            // Whether anything can sign at all, before the switches that ask it to.
            {
                const loading = !signing_loaded;
                const ready = signing_key.items.len > 0;
                var note = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = if (loading) style.surfaceRaised() else if (ready) style.success().lerp(style.background(), 0.88) else style.get().orange.lerp(style.background(), 0.86) },
                    .corners = style.radius.input,
                    .padding = dvui.Rect.all(style.space.md),
                    .margin = .{ .h = style.space.md },
                });
                defer note.deinit();
                dvui.icon(@src(), "sign_state", if (loading) dvui.entypo.cycle else if (ready) dvui.entypo.check else dvui.entypo.warning, .{ .fill_color = .{ .color = if (loading) style.textMuted() else if (ready) style.success() else style.get().orange } }, .{
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = style.space.md },
                });
                dvui.label(@src(), "{s}", .{if (loading) "Reading git's configuration…" else if (ready) "A signing key is set: commits and tags can be signed." else "No signing key set yet: git cannot sign until one is."}, .{
                    .font = style.small(),
                    .color_text = .{ .color = style.text() },
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                });
            }

            var changed = settingsSwitch(0, &commit_prefs.sign, "Sign every commit", "-S on each commit made here; git's own commit.gpgsign signs the rest");
            changed = settingsSwitch(1, &commit_prefs.sign_tags, "Sign tags", "The tags made here are annotated and signed") or changed;
            if (changed) tab_strip.saveWorkspace();

            settingsField(@src(), "Format", "Saved in git's global config, gpg.format");
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
                defer row.deinit();
                for ([_]struct { []const u8, []const u8 }{ .{ "GPG", "openpgp" }, .{ "SSH", "ssh" } }, 0..) |format, i| {
                    var chip = dvui.box(@src(), .{}, .{ .id_extra = i, .background = false });
                    defer chip.deinit();
                    const on = std.mem.eql(u8, signing_format, format[1]);
                    if (dialog_views.chipButton(@src(), if (on) dvui.entypo.check else dvui.entypo.lock, format[0], on)) setGlobalConfig("gpg.format", format[1]);
                }
            }

            settingsField(@src(), "Signing key", "A GPG key id, or the path to an SSH public key — user.signingkey");
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
                defer row.deinit();
                const key = dialog_views.textField(@src(), .{
                    .text = .{ .array_list = .{ .backing = &signing_key, .allocator = gpa, .limit = 512 } },
                    .placeholder = if (std.mem.eql(u8, signing_format, "ssh")) "~/.ssh/id_ed25519.pub" else "e.g. 3AA5C34371567BD2",
                }, settingsInput().override(.{
                    .tag = "signing_key",
                    .margin = .{ .w = style.space.sm },
                }));
                key.deinit();
                if (dialog_views.dialogButton(@src(), "Save", true)) setGlobalConfig("user.signingkey", std.mem.trim(u8, signing_key.items, " "));
            }
        }
    }

    if (dialog_views.escapePressed()) settings_open = false;
}

/// Every key Zit answers to, from the footer's keyboard button.
pub var keys_open = false;
pub var keys_rect: dvui.Rect = .{};

fn keysDialog() void {
    if (!keys_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &keys_rect, &keys_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);

    dialogHeader(@src(), dvui.entypo.keyboard, "Keyboard shortcuts", "Everything here is a key away", &keys_open);
    // No taller than most of the window: the list scrolls under its head.
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .min_size_content = .{ .w = 520 + 2 * style.space.xl, .h = @min(560, win.h * 0.7) },
        .max_size_content = .height(@min(560, win.h * 0.7)),
        .background = false,
        .color_fill = .{ .color = style.surface() },
    });
    defer scroll.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 520 },
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .padding = .{ .x = style.space.xl, .y = style.space.xs, .w = style.space.xl, .h = style.space.xl },
    });
    defer body.deinit();
    settingsGroup(@src(), 0, "Anywhere");
    {
        var card = shortcutCard(@src(), 0);
        defer card.deinit();
        shortcutRow(@src(), "Ctrl+P", "Command palette: any action, branch or repo");
        shortcutRow(@src(), "Ctrl+T", "New tab: open, clone or create");
        shortcutRow(@src(), "Ctrl+O", "Open a folder");
        shortcutRow(@src(), "Ctrl+W", "Close this tab");
        shortcutRow(@src(), "Ctrl+Tab, Ctrl+PgDn", "Next tab (Shift+Tab, PgUp: previous)");
        shortcutRow(@src(), "Ctrl+,", "Settings");
        shortcutRow(@src(), "Ctrl+Shift+T", "A terminal in this repository's folder");
        shortcutRow(@src(), "F5", "Refresh");
    }
    settingsGroup(@src(), 0, "History");
    {
        var card = shortcutCard(@src(), 1);
        defer card.deinit();
        shortcutRow(@src(), "↑ ↓", "Previous / next commit");
        shortcutRow(@src(), "Ctrl+F", "Search the commits");
        shortcutRow(@src(), "Ctrl+Z", "Undo the last commit, checkout, merge…");
        shortcutRow(@src(), "Ctrl+Shift+Z, Ctrl+Y", "Redo what was just undone");
        shortcutRow(@src(), "Esc", "Back to the graph, or cancel the bar");
    }
    settingsGroup(@src(), 0, "Changes");
    {
        var card = shortcutCard(@src(), 2);
        defer card.deinit();
        shortcutRow(@src(), "Ctrl+Enter", "Commit what is staged");
        shortcutRow(@src(), "Ctrl+Enter", "Continue a merge or rebase, its conflicts resolved");
    }
    settingsGroup(@src(), 0, "Conflicts");
    {
        var card = shortcutCard(@src(), 5);
        defer card.deinit();
        shortcutRow(@src(), "↑ ↓, F2 F3", "Previous / next conflict in the file");
        shortcutRow(@src(), "1, 2, 3", "Keep the left side, the right one, or both");
        shortcutRow(@src(), "U, Ctrl+Z", "Take the last pick back");
        shortcutRow(@src(), "Enter", "Stage a resolved file and open the next");
        shortcutRow(@src(), "F4", "Next conflicted file");
    }
    settingsGroup(@src(), 0, "Pull requests");
    {
        var card = shortcutCard(@src(), 6);
        defer card.deinit();
        shortcutRow(@src(), "↑ ↓, K J", "Previous / next request in the list");
        shortcutRow(@src(), "1, 2, 3, 4", "Conversation, commits, files, checks");
        shortcutRow(@src(), "Ctrl+F", "Search the requests");
        shortcutRow(@src(), "Ctrl+Enter", "Send what is in the review box, as a comment");
    }
    settingsGroup(@src(), 0, "Panels");
    {
        var card = shortcutCard(@src(), 3);
        defer card.deinit();
        shortcutRow(@src(), "Ctrl+B", "Show or hide the branches panel");
        shortcutRow(@src(), "Ctrl+J", "Show or hide the changes panel");
        shortcutRow(@src(), "Ctrl+Shift+PgUp/PgDn", "Move this tab left / right");
        shortcutRow(@src(), "Ctrl+Plus, Ctrl+Minus", "Zoom in / out, from 70 to 200 %");
        shortcutRow(@src(), "Ctrl+0", "Back to 100 %");
    }

    if (dialog_views.escapePressed()) keys_open = false;
}

/// The card a run of shortcuts sits on.
fn shortcutCard(src: std.builtin.SourceLocation, id: usize) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
        .padding = .{ .x = style.space.md, .y = style.space.xs, .w = style.space.md, .h = style.space.xs },
    });
}

/// Light or dark, from a key or a menu: Zit's own of either.
fn setTheme(dark: bool) void {
    pickTheme(if (dark) 0 else 1);
}

fn pickTheme(index: usize) void {
    theme_index = index;
    applyTheme();
    tab_strip.saveWorkspace();
}

const settings_body_pad: dvui.Rect = .{ .x = 0, .y = style.space.xs, .w = 0, .h = style.space.sm };

/// A dialog's head: its icon on a tile, its title and a line under it, and
/// the × that closes it.
pub fn dialogHeader(src: std.builtin.SourceLocation, icon: []const u8, title: []const u8, hint: []const u8, open: *bool) void {
    // The dialog's own ground, said outright: dvui fills a box with a border
    // on one side in the theme's darker colour unless told.
    var head = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.lg, .h = style.space.lg },
    });
    defer head.deinit();
    iconTile(@src(), icon, 40, 18);
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.md } });
        defer col.deinit();
        dvui.label(@src(), "{s}", .{title}, .{ .font = style.title(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "{s}", .{hint}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2 } });
    }
    if (dialog_views.iconButton(@src(), "dialog_close", "Close — Esc", dvui.entypo.cross, style.textMuted())) open.* = false;
}

/// A dialog's body, under its header: every dialog's padding, `width` wide
/// when it is not null.
pub fn dialogBody(src: std.builtin.SourceLocation, width: ?f32) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .min_size_content = if (width) |w| .{ .w = w } else null,
        .max_size_content = if (width) |w| .width(w) else null,
        .background = false,
        .padding = dvui.Rect.all(style.space.xl),
    });
}

/// A dialog's foot: across the whole dialog under a rule. What goes on the
/// left first, then a spacer, then Cancel and the button that answers it.
pub fn dialogFooter(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .y = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.xl, .h = style.space.lg },
    });
}

/// The eye that shows or hides a ref in the graph: drawn here, an outline
/// with its pupil, and struck through for hidden — entypo's are a filled
/// blot at this size. Turned into TinyVG once, on first use.
pub fn eyeIcon(hidden: bool) []const u8 {
    const slot = if (hidden) &eye_tvg[1] else &eye_tvg[0];
    if (slot.*) |bytes| return bytes;
    // Kept for the whole run, so not from `gpa`: two small icons, never freed.
    const bytes = dvui.svgToTvg(std.heap.page_allocator, if (hidden) EYE_OFF_SVG else EYE_SVG) catch
        return if (hidden) dvui.entypo.eye_with_line else dvui.entypo.eye;
    slot.* = bytes;
    return bytes;
}
var eye_tvg: [2]?[]const u8 = .{ null, null };

const EYE_PATHS =
    \\<path fill-rule="evenodd" d="M12 5C6.5 5 2.7 8.6 1 12c1.7 3.4 5.5 7 11 7s9.3-3.6 11-7c-1.7-3.4-5.5-7-11-7zM12 7c-4.2 0-7.3 2.6-8.8 5 1.5 2.4 4.6 5 8.8 5s7.3-2.6 8.8-5c-1.5-2.4-4.6-5-8.8-5zM15 12C15 13.66 13.66 15 12 15C10.34 15 9 13.66 9 12C9 10.34 10.34 9 12 9C13.66 9 15 10.34 15 12z"/>
;
const EYE_SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\">" ++ EYE_PATHS ++ "</svg>";
const EYE_OFF_SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\">" ++ EYE_PATHS ++
    "<path d=\"M3.7 2.3L21.7 20.3L20.3 21.7L2.3 3.7Z\"/></svg>";

/// An icon on a rounded tile of the accent's tint.
fn iconTile(src: std.builtin.SourceLocation, icon: []const u8, side: f32, glyph: f32) void {
    var tile = dvui.box(src, .{}, .{
        .background = true,
        .color_fill = .{ .color = style.accentDim() },
        .corners = style.radius.row,
        .min_size_content = .{ .w = side, .h = side },
        .max_size_content = .size(.{ .w = side, .h = side }),
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    defer tile.deinit();
    dvui.icon(@src(), "tile_icon", icon, .{ .fill_color = .{ .color = style.accent() } }, .{
        .min_size_content = .{ .w = glyph, .h = glyph },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
}

/// A settings text field: flush with the text over it, framed, roomy.
fn settingsInput() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        .font = style.small(),
    };
}

/// The small caps over a run of settings cards.
fn settingsGroup(src: std.builtin.SourceLocation, id: usize, title: []const u8) void {
    var buf: [32]u8 = undefined;
    const caps = std.ascii.upperString(&buf, title[0..@min(title.len, buf.len)]);
    dvui.label(src, "{s}", .{caps}, .{
        .id_extra = id,
        .font = style.section(),
        .color_text = .{ .color = style.textFaint() },
        .margin = .{ .x = style.space.xs, .y = style.space.lg, .h = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
}

/// The sections, down the left: a group's caption, then its sections, the
/// one shown lit.
fn settingsNav() void {
    var nav = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 200 },
        .expand = .vertical,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .w = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.sm, .h = style.space.sm },
    });
    defer nav.deinit();
    var group: usize = 0;
    for (settings_pages, 0..) |entry, i| {
        const page = entry orelse {
            settingsGroup(@src(), group, settings_groups[group]);
            group += 1;
            continue;
        };
        // The repositories' group: an entry for each, its badge for an icon.
        if (page.id == REPO_PAGE) {
            const known = knownRepos();
            if (known.len == 0) dvui.label(@src(), "None yet", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = .{ .x = style.space.sm, .y = style.space.sm } });
            for (known, 0..) |path, r| {
                const on = settings_page == REPO_PAGE and std.mem.eql(u8, path, repo_settings_path.items);
                var rb: dvui.ButtonWidget = undefined;
                rb.init(@src(), .{ .draw_focus = false }, .{
                    .id_extra = 1000 + r,
                    .tag = dialog_views.frameTag("settings_repo", git.repoName(path)),
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = if (on) style.accentDim() else style.surface() },
                    .color_fill_hover = .{ .color = if (on) style.accentDim() else style.rowHover() },
                    .corners = style.radius.input,
                    .margin = .{ .h = 2 },
                    .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.sm, .h = style.space.xs },
                });
                rb.processEvents();
                rb.drawBackground();
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
                    defer row.deinit();
                    tabBadge(git.repoName(path), on);
                    var fit: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
                    dvui.label(@src(), "{s}", .{graph_view.fitText(&fit, git.repoName(path), style.small(), 130)}, .{ .font = if (on) style.smallBold() else style.small(), .color_text = .{ .color = if (on) style.text() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
                }
                if (rb.hovered()) dvui.tooltip(@src(), .{ .active_rect = rb.data().borderRectScale().r, .position = .horizontal, .delay = 400_000 }, "{s}", .{path}, .{ .font = style.small() });
                if (rb.clicked()) {
                    settings_page = REPO_PAGE;
                    repo_settings_path.clearRetainingCapacity();
                    repo_settings_path.appendSlice(gpa, path) catch {};
                    repo_prefs_loaded = false;
                }
                rb.deinit();
            }
            continue;
        }
        const shown = settings_page == page.id;
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .tag = dialog_views.frameTag("settings", page.title),
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (shown) style.accentDim() else style.surface() },
            .color_fill_hover = .{ .color = if (shown) style.accentDim() else style.rowHover() },
            .corners = style.radius.input,
            .margin = .{ .h = 2 },
            .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
        });
        bw.processEvents();
        bw.drawBackground();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer row.deinit();
            dvui.icon(@src(), "page_icon", page.icon, .{ .fill_color = .{ .color = if (shown) style.accent() else style.textMuted() } }, .{
                .min_size_content = .{ .w = 14, .h = 14 },
                .gravity_y = 0.5,
                .margin = .{ .w = style.space.md },
            });
            dvui.label(@src(), "{s}", .{page.title}, .{ .font = if (shown) style.smallBold() else style.small(), .color_text = .{ .color = if (shown) style.text() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
        if (bw.clicked()) {
            settings_page = page.id;
            signing_loaded = false;
            repo_prefs_loaded = false;
        }
        bw.deinit();
    }
}

/// One section of the settings, drawn only while it is the one picked: its
/// head — icon, title, what is in it — then whatever the caller fills in
/// before `end`.
const SettingsCard = struct {
    inner: *dvui.BoxWidget,

    fn begin(id: usize) ?SettingsCard {
        if (settings_page != id) return null;
        const page = for (settings_pages) |entry| {
            if (entry) |p| if (p.id == id) break p;
        } else return null;
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.md } });
            defer row.deinit();
            iconTile(@src(), page.icon, 32, 16);
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.md } });
            defer col.deinit();
            // A repository's page goes by its name, its folder under it.
            const one = id == REPO_PAGE and repo_settings_path.items.len > 0;
            dvui.label(@src(), "{s}", .{if (one) git.repoName(repo_settings_path.items) else page.title}, .{ .font = style.bodyBold(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
            dvui.label(@src(), "{s}", .{if (one) repo_settings_path.items else page.hint}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 1 } });
        }
        return .{ .inner = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .border = .{ .y = 1 },
            .color_border = .{ .color = style.border() },
            .padding = .{ .y = style.space.sm },
        }) };
    }

    fn end(self: SettingsCard) void {
        self.inner.deinit();
    }
};

/// A setting's name and what it does, over the control the caller draws.
fn settingsField(src: std.builtin.SourceLocation, title: []const u8, hint: []const u8) void {
    var col = dvui.box(src, .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.md, .h = style.space.sm } });
    defer col.deinit();
    dvui.label(@src(), "{s}", .{title}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{hint}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2 } });
}

/// What git's global config says about signing, read when the section is
/// opened rather than every frame.
var signing_loaded = false;
var signing_format: []const u8 = "openpgp";
var signing_key: std.ArrayList(u8) = .empty;

/// The signing settings come from one `git` process on another thread: on
/// Windows, starting git takes long enough that waiting for it here froze the
/// window. Until it answers `signing_loaded` is false, and the page says so.
var signing_job: ?*run.Capture = null;

fn loadSigning() void {
    if (signing_loaded) return;
    const job_now = signing_job orelse blk: {
        const started = run.Capture.start(gpa, app_io, ".", &.{ "git", "config", "--global", "--get-regexp", "^(user\\.signingkey|gpg\\.format)$" }) catch {
            // Nothing to show, and no use asking again every frame.
            signing_loaded = true;
            return;
        };
        signing_job = started;
        break :blk started;
    };
    if (!job_now.finished()) return;
    signing_job = null;
    defer job_now.deinit(app_io);

    signing_loaded = true;
    signing_key.clearRetainingCapacity();
    signing_format = "openpgp";
    if (!job_now.ok) return;
    var lines = std.mem.splitScalar(u8, job_now.out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const value = std.mem.trim(u8, line[space + 1 ..], " ");
        if (std.mem.eql(u8, line[0..space], "user.signingkey")) {
            signing_key.clearRetainingCapacity();
            signing_key.appendSlice(gpa, value) catch {};
        } else if (std.mem.eql(u8, line[0..space], "gpg.format")) {
            signing_format = if (std.mem.eql(u8, value, "ssh")) "ssh" else "openpgp";
        }
    }
}

// === This repository's settings ===
//
// What git keeps in the repository's own .git/config: read when the page is
// opened, written as it is changed, so git — and any other tool — goes by
// them too. Unset, the global ones hold.

var repo_prefs_loaded = false;
var repo_prefs_job: ?*run.Capture = null;
/// Which repository's settings the page shows, picked from every one Zit
/// knows; owned.
var repo_settings_path: std.ArrayList(u8) = .empty;
var repo_name_local: std.ArrayList(u8) = .empty;
var repo_email_local: std.ArrayList(u8) = .empty;
/// How `git pull` joins what it fetched: as set everywhere, or here.
var repo_pull: enum { global, merge, rebase, ff_only } = .global;
/// `fetch.prune` and `commit.gpgsign` here: unset, on, off.
var repo_prune: Tri = .global;
var repo_sign: Tri = .global;
const Tri = enum { global, on, off };

fn loadRepoPrefs() void {
    if (repo_prefs_loaded or repo_settings_path.items.len == 0) return;
    const job_now = repo_prefs_job orelse blk: {
        const started = run.Capture.start(gpa, app_io, repo_settings_path.items, &.{ "git", "config", "--local", "--get-regexp", "^(user\\.name|user\\.email|pull\\.rebase|pull\\.ff|fetch\\.prune|commit\\.gpgsign)$" }) catch {
            repo_prefs_loaded = true;
            return;
        };
        repo_prefs_job = started;
        break :blk started;
    };
    if (!job_now.finished()) return;
    repo_prefs_job = null;
    defer job_now.deinit(app_io);
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
            repo_name_local.appendSlice(gpa, value) catch {};
        } else if (std.mem.eql(u8, key, "user.email")) {
            repo_email_local.appendSlice(gpa, value) catch {};
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
fn setLocalConfig(key: []const u8, value: []const u8) void {
    const where = repo_settings_path.items;
    if (where.len == 0) return;
    var outcome = (if (value.len == 0)
        run.git(gpa, app_io, where, &.{ "config", "--local", "--unset-all", key })
    else
        run.git(gpa, app_io, where, &.{ "config", "--local", key, value })) catch return setCommandError("Could not run git. Is it on your PATH?");
    defer outcome.deinit(gpa);
    // Unsetting what was never set is git's exit 5: nothing to say.
    if (!outcome.ok and value.len > 0) setCommandError(if (outcome.message.len > 0) outcome.message else "git config failed.");
    repo_prefs_loaded = false;
}

/// Which of `steps` `value` is closest to: a saved factor read back as the
/// chip it was picked from.
fn nearestStep(steps: []const f32, value: f32) usize {
    var best: usize = 0;
    for (steps, 0..) |v, i| if (@abs(v - value) < @abs(steps[best] - value)) {
        best = i;
    };
    return best;
}

/// One choice out of a few, as a row of chips: the one picked ticked.
fn choiceChips(id: usize, options: []const []const u8, current: usize) ?usize {
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
fn knownRepos() []const []const u8 {
    const a = dvui.currentWindow().arena();
    var known: std.ArrayList([]const u8) = .empty;
    if (repo != null and !isOpenTab(repo_path.items)) known.append(a, repo_path.items) catch {};
    for (tab_strip.groups.items, 0..) |group, gi| for (group.tabs.items, 0..) |tab, ti| {
        if (!listedEarlier(gi, ti, tab.path)) known.append(a, tab.path) catch {};
    };
    for (tab_strip.recent.items) |path| if (!isOpenTab(path)) known.append(a, path) catch {};
    return known.items;
}

fn repoSettings() void {
    var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = settings_body_pad });
    defer section.deinit();

    const known = knownRepos();
    if (known.len == 0) {
        dvui.label(@src(), "No repository yet. Open one and its settings are here.", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
        return;
    }
    if (repo_settings_path.items.len == 0) repo_settings_path.appendSlice(gpa, known[0]) catch {};

    loadRepoPrefs();
    if (!repo_prefs_loaded) {
        dvui.label(@src(), "Reading its config…", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
        return;
    }

    settingsField(@src(), "Name and email here", "Commits in this repository only — work or personal. Empty: the global ones");
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false });
        defer row.deinit();
        for ([_]*std.ArrayList(u8){ &repo_name_local, &repo_email_local }, [_][]const u8{ window_chrome.me_name.items, window_chrome.me_email.items }, 0..) |list, global, i| {
            var cell = dvui.box(@src(), .{}, .{ .id_extra = i, .expand = .horizontal, .background = false, .margin = .{ .w = if (i == 0) style.space.sm else 0 } });
            defer cell.deinit();
            const te = dialog_views.textField(@src(), .{
                .text = .{ .array_list = .{ .backing = list, .allocator = gpa, .limit = 256 } },
                .placeholder = if (global.len > 0) global else if (i == 0) "Name" else "Email",
            }, settingsInput().override(.{ .tag = if (i == 0) "repo:name" else "repo:email" }));
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

    settingsField(@src(), "Pull", "How Pull joins what it fetched — pull.rebase and pull.ff");
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

    settingsField(@src(), "Prune when fetching", "Drop the remote branches deleted on the remote — fetch.prune");
    if (choiceChips(1, &.{ "As everywhere", "On", "Off" }, @backingInt(repo_prune))) |i| {
        setLocalConfig("fetch.prune", switch (i) {
            0 => "",
            1 => "true",
            else => "false",
        });
        // What Fetch passes follows: the open repository's config read again.
        if (repo != null and std.mem.eql(u8, repo_settings_path.items, repo_path.items)) commit_view.startRepoConfig();
    }

    settingsField(@src(), "Sign commits", "Every commit made here signed with your key — commit.gpgsign");
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
var editors_loaded = false;
var editors_job: ?*run.Capture = null;

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
        const started = run.Capture.start(gpa, app_io, ".", argv) catch {
            editors_loaded = true;
            return;
        };
        editors_job = started;
        break :blk started;
    };
    if (!job_now.finished()) return;
    editors_job = null;
    defer job_now.deinit(app_io);
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
fn editorChoice() bool {
    loadEditors();
    const current = std.mem.trim(u8, tab_strip.editor_cmd.items, " ");
    var face: []const u8 = if (current.len == 0) "System default" else current;
    for (known_editors) |e| if (std.mem.eql(u8, e[0], current)) {
        face = e[1];
    };
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.sm } });
    defer cell.deinit();
    const p = picker(EDITOR_PICKER, face, "", "settings:editor");
    defer p.end();
    const m = p.menu orelse return false;
    if (!editors_loaded) dvui.label(@src(), "Looking for the editors on this computer…", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm } });
    var picked: ?[]const u8 = null;
    if (pickRow(0, "System default", "what the system opens the file with", current.len == 0, null)) picked = "";
    for (known_editors, 0..) |e, i| {
        if (!editors_found[i]) continue;
        if (pickRow(i + 1, e[1], e[0], std.mem.eql(u8, current, e[0]), null)) picked = e[0];
    }
    const cmd = picked orelse return false;
    m.close();
    tab_strip.editor_cmd.clearRetainingCapacity();
    tab_strip.editor_cmd.appendSlice(gpa, cmd) catch {};
    return true;
}

/// The terminal setting, as a select: the first found, or one of those
/// installed here. True when it changed.
fn terminalChoice() bool {
    loadEditors();
    const current = std.mem.trim(u8, tab_strip.terminal_cmd.items, " ");
    var face: []const u8 = "Automatic";
    for (known_terminals) |e| if (std.mem.eql(u8, e[0], current)) {
        face = e[1];
    };
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.sm } });
    defer cell.deinit();
    const p = picker(TERMINAL_PICKER, face, "", "settings:terminal");
    defer p.end();
    const m = p.menu orelse return false;
    if (!editors_loaded) dvui.label(@src(), "Looking for the terminals on this computer…", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm } });
    var picked: ?[]const u8 = null;
    if (pickRow(0, "Automatic", if (@import("builtin").os.tag == .windows) "Windows Terminal where there is one" else "$TERMINAL, then the first found", current.len == 0, null)) picked = "";
    for (known_terminals, 0..) |e, i| {
        if (!terminals_found[i]) continue;
        if (pickRow(i + 1, e[1], e[0], std.mem.eql(u8, current, e[0]), null)) picked = e[0];
    }
    const cmd = picked orelse return false;
    m.close();
    tab_strip.terminal_cmd.clearRetainingCapacity();
    tab_strip.terminal_cmd.appendSlice(gpa, cmd) catch {};
    return true;
}

/// Picker ids of the settings' selects, apart from those of the dialogs.
const EDITOR_PICKER = 50;
const TERMINAL_PICKER = 51;

/// `path` — the repository's file — in the editor the settings name, or the
/// system's choice for it.
pub fn openInEditor(path: []const u8) void {
    if (repo == null) return;
    const a = dvui.currentWindow().arena();
    const full = std.fs.path.join(a, &.{ repo_path.items, path }) catch return;
    const cmd = std.mem.trim(u8, tab_strip.editor_cmd.items, " ");
    if (cmd.len == 0) return run.open(app_io, repo_path.items, full) catch setCommandError("Could not open the file.");
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (words.next()) |w| argv.append(a, w) catch return;
    argv.append(a, full) catch return;
    // Not waited on: an editor can stay open for hours.
    run.startDetached(app_io, repo_path.items, argv.items) catch setCommandError("Could not start the editor. Is it on your PATH?");
}

/// `git config --global key value` — the empty value unsets it — then read
/// back, so what is shown is what git has.
fn setGlobalConfig(key: []const u8, value: []const u8) void {
    var outcome = (if (value.len == 0)
        run.git(gpa, app_io, ".", &.{ "config", "--global", "--unset", key })
    else
        run.git(gpa, app_io, ".", &.{ "config", "--global", key, value })) catch return setCommandError("Could not run git. Is it on your PATH?");
    defer outcome.deinit(gpa);
    if (!outcome.ok and value.len > 0) setCommandError(if (outcome.message.len > 0) outcome.message else "git config failed.");
    signing_loaded = false;
}

/// One setting: what it is and what it does, its switch on the right.
/// True when it was flipped.
fn settingsSwitch(id: usize, value: *bool, title: []const u8, hint: []const u8) bool {
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
fn themeCard(src: std.builtin.SourceLocation, id: usize) bool {
    const t = style.themes[id];
    const caption = t.name;
    const selected = id == theme_index;
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

fn shortcutRow(src: std.builtin.SourceLocation, keys: []const u8, what: []const u8) void {
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
    .{ .name = "Continue the merge or rebase", .icon = dvui.entypo.controller_play, .keys = "Ctrl+Enter", .when = canContinue, .run = requestContinue },
    .{ .name = "Skip the commit it stopped on", .icon = dvui.entypo.controller_next, .when = canSkip, .run = requestSkipStep },
    .{ .name = "Abort the merge or rebase", .icon = dvui.entypo.circle_with_cross, .when = midOperation, .run = requestAbortOperation },
    .{ .name = "Fetch all remotes", .icon = dvui.entypo.cw, .run = struct {
        fn f() void {
            requestNetwork("Fetching", tab_strip.fetchAllArgs(false));
        }
    }.f },
    .{ .name = "Pull", .icon = dvui.entypo.download, .run = struct {
        fn f() void {
            requestNetwork("Pulling", &.{"pull"});
        }
    }.f },
    .{ .name = "Pull, rebasing local commits", .icon = dvui.entypo.level_down, .run = struct {
        fn f() void {
            requestNetwork("Pulling", &.{ "pull", "--rebase" });
        }
    }.f },
    .{ .name = "Push", .icon = dvui.entypo.upload, .run = struct {
        fn f() void {
            requestNetwork("Pushing", &.{ "-c", "push.autoSetupRemote=true", "push" });
        }
    }.f },
    .{ .name = "Force push…", .icon = dvui.entypo.warning, .run = struct {
        fn f() void {
            ask(.force_push, "");
        }
    }.f },
    .{ .name = "Undo the last action", .icon = dvui.entypo.ccw, .keys = "Ctrl+Z", .run = requestUndo },
    .{ .name = "Redo what was just undone", .icon = dvui.entypo.cw, .keys = "Ctrl+Shift+Z", .run = requestRedo },
    .{ .name = "New branch…", .icon = dvui.entypo.flow_branch, .run = struct {
        fn f() void {
            askName(.new_branch, "");
        }
    }.f },
    .{ .name = "New tag…", .icon = dvui.entypo.tag, .run = struct {
        fn f() void {
            askName(.new_tag, "");
        }
    }.f },
    .{ .name = "Stash everything", .icon = dvui.entypo.archive, .run = struct {
        fn f() void {
            requestLocal("Stashing", &.{ "stash", "push", "-u" });
        }
    }.f },
    .{ .name = "Stash everything, with a message…", .icon = dvui.entypo.archive, .run = struct {
        fn f() void {
            askName(.stash, "");
        }
    }.f },
    .{ .name = "Pop the last stash", .icon = dvui.entypo.install, .run = struct {
        fn f() void {
            requestLocal("Popping the stash", &.{ "stash", "pop" });
        }
    }.f },
    .{ .name = "Stage everything", .icon = dvui.entypo.squared_plus, .run = struct {
        fn f() void {
            commit_view.requestStageAll();
        }
    }.f },
    .{ .name = "Unstage everything", .icon = dvui.entypo.squared_minus, .run = struct {
        fn f() void {
            request(&.{ "reset", "-q", "--", "." });
        }
    }.f },
    .{ .name = "Discard every unstaged change…", .icon = dvui.entypo.trash, .run = struct {
        fn f() void {
            ask(.discard, "");
        }
    }.f },
    .{ .name = "Add a remote…", .icon = dvui.entypo.cloud, .run = struct {
        fn f() void {
            askName(.add_remote, "");
        }
    }.f },
    .{ .name = "Refresh", .icon = dvui.entypo.retweet, .keys = "F5", .run = struct {
        fn f() void {
            requestAction(.refresh);
        }
    }.f },
    .{ .name = "Open a repository…", .icon = dvui.entypo.folder, .keys = "Ctrl+O", .needs_repo = false, .run = struct {
        fn f() void {
            requestAction(.open_repo);
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
    .{ .name = "Open a terminal here", .icon = dvui.entypo.code, .keys = "Ctrl+Shift+T", .run = openTerminal },
    .{ .name = "New tab", .icon = dvui.entypo.browser, .keys = "Ctrl+T", .needs_repo = false, .run = struct {
        fn f() void {
            new_tab_open = true;
        }
    }.f },
    .{ .name = "Close this tab", .icon = dvui.entypo.cross, .keys = "Ctrl+W", .run = closeShownTab },
    .{ .name = "Show or hide the branches panel", .icon = dvui.entypo.align_left, .keys = "Ctrl+B", .run = struct {
        fn f() void {
            show_sidebar = !show_sidebar;
        }
    }.f },
    .{ .name = "Show or hide the changes panel", .icon = dvui.entypo.align_right, .keys = "Ctrl+J", .run = struct {
        fn f() void {
            show_detail = !show_detail;
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
    .{ .name = "Git identity: name, email, GitHub sign-in", .icon = dvui.entypo.user, .needs_repo = false, .run = openIdentity },
    .{ .name = "Settings", .icon = dvui.entypo.cog, .needs_repo = false, .run = struct {
        fn f() void {
            openSettings(5);
        }
    }.f },
    .{ .name = "Keyboard shortcuts", .icon = dvui.entypo.keyboard, .needs_repo = false, .run = struct {
        fn f() void {
            keys_open = true;
            keys_rect = .{};
        }
    }.f },
    .{ .name = "Switch theme, light or dark", .icon = dvui.entypo.light_up, .needs_repo = false, .run = struct {
        fn f() void {
            setTheme(!dark_theme);
        }
    }.f },
};

var palette_open: bool = false;
var palette_text: std.ArrayList(u8) = .empty;
var palette_pick: usize = 0;
var palette_rect: dvui.Rect = .{};

fn openPalette() void {
    palette_open = true;
    palette_rect = .{};
    palette_text.clearRetainingCapacity();
    palette_pick = 0;
}

/// Every letter of `needle`, in order, somewhere in `hay`, ignoring case: "psh"
/// finds "Push". Loose on purpose; the list is short and the order says the rest.
fn fuzzy(hay: []const u8, needle: []const u8) bool {
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

fn palette() void {
    if (!palette_open) return;

    // Gathered first, so the keys below know how many there are.
    var items: [PALETTE_ROWS]PaletteItem = undefined;
    var labels: [PALETTE_ROWS][]const u8 = undefined;
    var n: usize = 0;
    const needle = std.mem.trim(u8, palette_text.items, " ");

    for (commands, 0..) |cmd, i| {
        if (n == PALETTE_ROWS) break;
        if (cmd.needs_repo and repo == null) continue;
        if (cmd.when) |can| if (!can()) continue;
        if (!fuzzy(cmd.name, needle)) continue;
        items[n] = .{ .command = i };
        labels[n] = cmd.name;
        n += 1;
    }
    if (history) |h| {
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
            if (listedEarlier(gi, ti, tab.path)) continue;
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
        .text = .{ .array_list = .{ .backing = &palette_text, .allocator = gpa, .limit = 128 } },
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
        if (pressed(ke, .down, false)) {
            e.handled = true;
            if (palette_pick + 1 < n) palette_pick += 1;
        } else if (pressed(ke, .up, false)) {
            e.handled = true;
            palette_pick -|= 1;
        } else if (pressed(ke, .escape, false)) {
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
            .ref => |r| .{ if (history.?.refs[r].kind == .remote) dvui.entypo.cloud else dvui.entypo.flow_branch, "switch to" },
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
        .ref => |i| checkout(history.?.refs[i]),
        .repo => |r| requestOpenKnown(tab_strip.groups.items[r.group].tabs.items[r.tab].path),
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
fn tabStrip() void {
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
    workspaceSwitcher();
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

// === Connecting GitHub ===
//
// OAuth's device flow, as GitKraken signs in: GitHub hands Zit a code, the
// browser opens on github.com/login/device with the code in the clipboard,
// and once it is approved there the token comes back to Zit's asking.

var connect_open = false;
var connect_rect: dvui.Rect = .{};
var connect_job: ?*run.Capture = null;
var connect_state: enum { asking, waiting, user, done, failed } = .asking;
/// GitHub's code to type, and what Zit asks with; owned.
var connect_code: std.ArrayList(u8) = .empty;
var connect_device: std.ArrayList(u8) = .empty;
var connect_uri: std.ArrayList(u8) = .empty;
var connect_interval_s: u32 = 5;
var connect_note: std.ArrayList(u8) = .empty;
/// Asked from the identity dialog: its fields filled once connected.
var connect_fills_identity = false;

/// The dialog, and OAuth's device flow under way: a code from GitHub, typed
/// on its page in the browser. Also its Try again.
pub fn openConnect() void {
    connect_open = true;
    connect_rect = .{};
    connect_state = .asking;
    connect_code.clearRetainingCapacity();
    connect_note.clearRetainingCapacity();
    if (connect_job) |j| j.deinit(app_io);
    connect_job = github.startDevice() catch {
        connectFailed("Could not run curl. Is it installed?");
        return;
    };
}

fn connectFailed(why: []const u8) void {
    connect_state = .failed;
    connect_rect = .{};
    connect_note.clearRetainingCapacity();
    connect_note.appendSlice(gpa, why) catch {};
}

fn closeConnect() void {
    connect_open = false;
    if (connect_job) |j| j.deinit(app_io);
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
        defer w.deinit(app_io);
        var a: std.heap.ArenaAllocator = .init(gpa);
        defer a.deinit();
        if (!w.ok) return connectFailed(if (w.err.items.len > 0) w.err.items else "No answer from GitHub.");
        switch (connect_state) {
            .asking => {
                const d = github.parseDevice(a.allocator(), w.out) catch return connectFailed("GitHub would not give a code. Is Device Flow on for Zit's OAuth App?");
                connect_code.clearRetainingCapacity();
                connect_code.appendSlice(gpa, d.user_code) catch {};
                connect_device.clearRetainingCapacity();
                connect_device.appendSlice(gpa, d.device_code) catch {};
                connect_uri.clearRetainingCapacity();
                connect_uri.appendSlice(gpa, d.verification_uri) catch {};
                connect_interval_s = @max(d.interval, 5);
                connect_state = .waiting;
                // Where the browser page can take it.
                dvui.clipboardTextSet(connect_code.items);
                openUrl(connect_uri.items);
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
                if (!tab_strip.integrations) tab_strip.setIntegrations(true) else refreshRequests();
                avatars.setGithubRepo(githubRemote());
                if (connect_fills_identity) {
                    connect_fills_identity = false;
                    identity_note = if (fillFromGithub()) "Filled in from your GitHub account." else "Connected.";
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

fn connectDialog() void {
    if (!connect_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &connect_rect, &connect_open, style.surface(), 420, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    pumpConnect(fw.data().id);
    dialogHeader(@src(), dvui.entypo.login, "Connect GitHub", "Pull requests, issues and checks, as your account", &connect_open);

    var body = dialogBody(@src(), null);
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
        if (dialog_views.dialogButton(@src(), "Open the page again", false)) openUrl(connect_uri.items);
    }
    body.deinit();
    {
        var foot = dialogFooter(@src());
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
    if (bw.clicked()) requestTab(.{ .group_toggle = g });
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
                requestTab(.{ .group_color = .{ g, c } });
            }
            bw.deinit();
        }
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.pencil, "Rename the group…", false)) {
        fw.close();
        group_target = .{ g, 0 };
        openWorkspaceDialog(.group_rename);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.squared_minus, "Ungroup", false)) {
        fw.close();
        requestTab(.{ .ungroup = g });
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.cross, "Close the group", false)) {
        fw.close();
        requestTab(.{ .close_group = g });
    }
}

/// Switch to workspace `w`, in this window and this view: the group and tab
/// it was on, its first tab, or its start page when it has none.
fn selectWorkspace(w: usize) void {
    if (w >= tab_strip.workspaces.items.len) return;
    tab_strip.active_ws = w;
    const at = tab_strip.workspaces.items[w];
    if (at.group < tab_strip.groups.items.len and tab_strip.groups.items[at.group].ws == w and at.tab < tab_strip.groups.items[at.group].tabs.items.len) {
        new_tab_open = false;
        return tab_strip.selectTabIn(at.group, at.tab);
    }
    tab_strip.selectAnyTab();
    tab_strip.saveWorkspace();
}

/// A new workspace, with an empty group to open repositories into, switched
/// to. Its index.
fn newWorkspace(name: []const u8, color: u8) ?usize {
    const owned = gpa.dupe(u8, name) catch return null;
    tab_strip.workspaces.append(gpa, .{ .name = owned, .color = color }) catch {
        gpa.free(owned);
        return null;
    };
    const w = tab_strip.workspaces.items.len - 1;
    tab_strip.ensureWorkspaceGroups();
    return w;
}

/// Workspace `w` and its tabs gone — the tabs to the recent list — unless
/// it is the last one.
fn deleteWorkspace(w: usize) void {
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
    gpa.free(tab_strip.workspaces.orderedRemove(w).name);
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
fn workspaceSwitcher() void {
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
            if (i != tab_strip.active_ws) requestTab(.{ .select_ws = i });
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
        requestTab(.{ .close_ws = tab_strip.active_ws });
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
var ws_dialog: ?WorkspaceDialog = null;
var ws_rect: dvui.Rect = .{};
var ws_name: std.ArrayList(u8) = .empty;
var ws_color: u8 = 0;

fn openWorkspaceDialog(kind: WorkspaceDialog) void {
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
        ws_name.appendSlice(gpa, tab_strip.workspaces.items[tab_strip.active_ws].name) catch {};
        ws_color = tab_strip.workspaces.items[tab_strip.active_ws].color;
    }
    if (kind == .group_rename and group_target[0] < tab_strip.groups.items.len) {
        const group = tab_strip.groups.items[group_target[0]];
        ws_name.appendSlice(gpa, tab_strip.groupLabel(group)) catch {};
        ws_color = group.color;
    }
}

fn workspaceDialog() void {
    const kind = ws_dialog orelse return;
    var open = true;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &ws_rect, &open, style.surface(), 400, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    const is_group = kind == .group or kind == .group_rename;
    if (kind == .group)
        dialogHeader(@src(), dvui.entypo.plus, "New group", "The tab under a coloured dot, with the ones you add to it", &open)
    else if (kind == .group_rename)
        dialogHeader(@src(), dvui.entypo.pencil, "Rename the group", "Its name beside its dot; none leaves the dot alone", &open)
    else
        dialogHeader(@src(), dvui.entypo.layers, if (kind == .rename) "Rename the workspace" else "New workspace", "A set of groups and tabs, switched to in this window", &open);

    var body = dialogBody(@src(), null);
    var entered = false;
    // A group's name is optional: without one, the group is its dot.
    _ = dialog_views.dialogField(@src(), 0, if (is_group) "Name (optional)" else "Name", &ws_name, "e.g. Client work", true, &entered);
    dialog_views.dialogLabel(@src(), "Colour");
    if (colorSwatches(@src(), ws_color, .{ .y = style.space.xs, .h = style.space.lg })) |c| ws_color = @intCast(c);

    const named = is_group or std.mem.trim(u8, ws_name.items, " \t").len > 0;
    body.deinit();
    {
        var line = dialogFooter(@src());
        defer line.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButton(@src(), "Cancel", false)) open = false;
        if ((dialog_views.dialogButton(@src(), if (kind == .rename or kind == .group_rename) "Rename" else "Create", named) or entered) and named) requestTab(.workspace_named);
    }
    if (dialog_views.escapePressed() or !open) ws_dialog = null;
}

/// What the dialog was answered with, applied between frames.
fn applyWorkspaceDialog() void {
    const kind = ws_dialog orelse return;
    ws_dialog = null;
    const typed = std.mem.trim(u8, ws_name.items, " \t");
    const name = if ((kind == .group or kind == .group_rename) and typed.len == 0) tab_strip.GROUP_MARK else typed;
    if (name.len == 0) return;
    switch (kind) {
        .new => if (newWorkspace(name, ws_color)) |w| selectWorkspace(w),
        .with_tab => if (newWorkspace(name, ws_color)) |w| {
            moveTabToWorkspace(group_target[0], group_target[1], w);
            selectWorkspace(w);
        },
        .group => {
            const g0 = group_target[0];
            const t0 = group_target[1];
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
            const g = group_target[0];
            // Only a group: tabs in no group are not renamed into one.
            if (g >= tab_strip.groups.items.len or tab_strip.groups.items[g].name.len == 0) return;
            tab_strip.groups.items[g].color = ws_color;
            tab_strip.renameGroup(g, name);
        },
        .rename => if (tab_strip.active_ws < tab_strip.workspaces.items.len) {
            const owned = gpa.dupe(u8, name) catch return;
            gpa.free(tab_strip.workspaces.items[tab_strip.active_ws].name);
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
        group_target = .{ g, t };
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
            requestTab(.{ .tab_to = .{ g, t, gi } });
        }
    }
    if (tab_strip.groups.items[g].name.len > 0 and graph_view.menuIcon(@src(), dvui.entypo.squared_minus, "Remove from the group", false)) {
        fw.close();
        requestTab(.{ .tab_out = .{ g, t } });
    }
    for (tab_strip.workspaces.items, 0..) |w, wi| {
        if (wi == tab_strip.groups.items[g].ws) continue;
        const caption = std.fmt.allocPrint(dvui.currentWindow().arena(), "Move to workspace {s}", .{tab_strip.workspaceName(w)}) catch continue;
        if (graph_view.menuIconAt(@src(), wi + 1000, dvui.entypo.layers, caption)) {
            fw.close();
            requestTab(.{ .tab_to = .{ g, t, firstGroupOf(wi) } });
        }
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.plus, "Move to a new workspace…", false)) {
        fw.close();
        group_target = .{ g, t };
        openWorkspaceDialog(.with_tab);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.cross, "Close", false)) {
        fw.close();
        requestTab(.{ .close_in = .{ g, t } });
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
            requestTab(.{ .tab_to = .{ tab_drag[0], tab_drag[1], g } });
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
            requestTab(.{ .tab_at = .{ tab_drag[0], tab_drag[1], slot[0], slot[1] } });
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
    if (active) active_tab_foot = .{ .x = face_rs.r.x + side, .y = face_rs.r.y + face_rs.r.h, .w = face_rs.r.w - 2 * side, .h = s };
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
fn tabBadge(name: []const u8, active: bool) void {
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
fn listedEarlier(group_index: usize, tab_index: usize, path: []const u8) bool {
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
    const h = history orelse return;
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
    if (dialog_views.linkButtonTagged(@src(), "Abort", style.danger(), "op:abort")) requestAbortOperation();
    if (canSkip() and next != .skip) {
        if (dialog_views.linkButtonTagged(@src(), "Skip", style.textMuted(), "op:skip")) requestSkipStep();
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
        .skip => if (opButton(@src(), "Skip empty", "op:skip")) requestLocal("Skipping", &.{ cmd, "--skip" }),
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
fn opTitle(buf: []u8) []const u8 {
    const h = history orelse return "";
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
    const h = history orelse return "";
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

fn opNext() OpNext {
    if (dialog_views.conflictCount() > 0) return .resolve;
    const h = history orelse return .proceed;
    const w = work orelse return .proceed;
    // A merge with nothing to add still makes its merge commit.
    if (h.state != .merge and w.staged.len == 0) return .skip;
    return .proceed;
}

/// Skip goes with the operations that replay one commit after another.
fn canSkip() bool {
    const h = history orelse return false;
    return h.state == .rebase or h.state == .cherrypick or h.state == .revert;
}

/// A merge, rebase, cherry-pick or revert is under way: starting another is
/// refused by git, and offered by nothing.
pub fn midOperation() bool {
    const h = history orelse return false;
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
fn requestContinue() void {
    const cmd = operationCommand() orelse return;
    requestLocal("Continuing", &.{ "-c", "core.editor=true", cmd, "--continue" });
}

/// Whether the file open is one of the conflicted ones.
pub fn viewingConflict() bool {
    return switch (selection) {
        .change => |side| side == .unstaged and selectedStatus(.unstaged) == .conflicted,
        else => false,
    };
}

/// The conflicted file after the one open, round the end — the first when
/// none is open.
fn openNextConflict() void {
    const w = work orelse return;
    const open: []const u8 = if (viewingConflict()) selected_path.items else "";
    var first: ?[]const u8 = null;
    var past = open.len == 0;
    for (w.unstaged) |change| {
        if (change.status != .conflicted) continue;
        if (first == null) first = change.path;
        if (past and !std.mem.eql(u8, change.path, open)) {
            active_view = .graph;
            return selectChange(change.path, .unstaged);
        }
        if (std.mem.eql(u8, change.path, open)) past = true;
    }
    if (first) |p| {
        active_view = .graph;
        selectChange(p, .unstaged);
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
fn confirmToast() void {
    const c = confirm orelse {
        confirm_rect = .{};
        return;
    };
    // Esc is Cancel: the toast is what waits on an answer.
    if (dialog_views.escapePressed()) return clearConfirm();

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
    if (dialog_views.linkButtonTagged(@src(), "Cancel", style.textMuted(), "confirm:cancel")) clearConfirm();
    if (dialog_views.alertButton(@src(), confirmVerb(c.kind), style.danger(), "confirm:yes")) requestAction(.confirmed);
}

/// The button that does what the toast asks, named for it.
fn confirmVerb(kind: Confirm.Kind) []const u8 {
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

// === Creating a request ===
//
// Filled in from what is already known, no guessing: the base is where the
// remote's HEAD points, the title the branch's one commit or its name, the
// description the repository's template and the commits it brings.

var pr_new_open = false;
var pr_new_rect: dvui.Rect = .{};
var pr_new_title: std.ArrayList(u8) = .empty;
var pr_new_body: std.ArrayList(u8) = .empty;
var pr_new_base: std.ArrayList(u8) = .empty;
var pr_new_reviewers: std.ArrayList(u8) = .empty;
var pr_new_draft = false;
/// The branch it comes from: the one checked out, unless another is picked.
var pr_new_head: std.ArrayList(u8) = .empty;
/// Who it is assigned to, and its labels: comma-separated, as picked.
var pr_new_assignees: std.ArrayList(u8) = .empty;
var pr_new_labels: std.ArrayList(u8) = .empty;
/// What is typed over the list of the picker open, and which one that is:
/// another opening starts with nothing typed.
var pick_filter: std.ArrayList(u8) = .empty;
var pick_open: ?usize = null;
/// The request is being made: the dialog waits on it, then gives way to it.
var pr_creating = false;
/// The number GitHub gave the one just made, until the calls after it —
/// its reviewers, assignees, labels — are done and it can be opened.
var pr_created: u32 = 0;

pub fn openPrCreate() void {
    const h = history orelse return;
    const branch = h.head orelse return setCommandError("Check out a branch first: a request is made from one.");
    pr_new_open = true;
    pr_new_rect = .{};
    pr_new_draft = false;
    for ([_]*std.ArrayList(u8){ &pr_new_title, &pr_new_body, &pr_new_base, &pr_new_reviewers, &pr_new_head, &pr_new_assignees, &pr_new_labels }) |t| t.clearRetainingCapacity();
    pr_new_head.appendSlice(gpa, branch) catch {};
    // Who can be asked, the labels: read while the form is filled in.
    pr.loadMeta(repo_path.items);

    // The base: what the remote calls its HEAD, "origin/main" -> "main".
    const remote = defaultRemote() orelse "origin";
    var ref_buf: [96]u8 = undefined;
    const head_ref = std.fmt.bufPrint(&ref_buf, "refs/remotes/{s}/HEAD", .{remote}) catch "";
    if (run.capture(gpa, app_io, repo_path.items, &.{ "git", "symbolic-ref", "-q", "--short", head_ref })) |answer| {
        defer gpa.free(answer.out);
        const name = std.mem.trim(u8, answer.out, " \r\n");
        if (answer.ok and std.mem.startsWith(u8, name, remote) and name.len > remote.len + 1) pr_new_base.appendSlice(gpa, name[remote.len + 1 ..]) catch {};
    } else |_| {}
    if (pr_new_base.items.len == 0) pr_new_base.appendSlice(gpa, if (tab_strip.default_branch.items.len > 0) tab_strip.default_branch.items else "main") catch {};

    // The commits it brings, oldest first.
    var range_buf: [256]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buf, "{s}/{s}..HEAD", .{ remote, pr_new_base.items }) catch "";
    var subjects: []const u8 = "";
    const log = run.capture(gpa, app_io, repo_path.items, &.{ "git", "log", "--reverse", "--format=%s", range }) catch null;
    defer if (log) |l| gpa.free(l.out);
    if (log) |l| if (l.ok) {
        subjects = std.mem.trim(u8, l.out, "\n");
    };
    const count = if (subjects.len == 0) 0 else std.mem.count(u8, subjects, "\n") + 1;

    // One commit says what it does; several, the branch's name does.
    if (count == 1) pr_new_title.appendSlice(gpa, subjects) catch {} else pr_new_title.appendSlice(gpa, humanBranch(dvui.currentWindow().arena(), branch)) catch {};

    if (prTemplate()) |template| {
        defer gpa.free(template);
        pr_new_body.appendSlice(gpa, std.mem.trim(u8, template, " \n")) catch {};
        pr_new_body.appendSlice(gpa, "\n\n") catch {};
    }
    if (count > 1) {
        pr_new_body.appendSlice(gpa, "## Commits\n\n") catch {};
        var it = std.mem.splitScalar(u8, subjects, '\n');
        while (it.next()) |subject| pr_new_body.print(gpa, "- {s}\n", .{subject}) catch {};
    }
}

/// "PROJ-81-Front-Login" -> "PROJ-81: Front Login"; "feat/new-thing"
/// -> "feat: new thing". The ticket or the prefix kept as it is written.
fn humanBranch(a: std.mem.Allocator, branch: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = branch;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        out.print(a, "{s}: ", .{rest[0..slash]}) catch return branch;
        rest = rest[slash + 1 ..];
    } else if (ticketOf(rest)) |ticket| {
        out.print(a, "{s}: ", .{ticket}) catch return branch;
        rest = std.mem.trimStart(u8, rest[ticket.len..], "-_");
    }
    for (rest) |ch| out.append(a, if (ch == '-' or ch == '_') ' ' else ch) catch return branch;
    return out.items;
}

/// "PROJ-81-…" -> "PROJ-81": letters, a dash, digits, at the start.
fn ticketOf(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < name.len and std.ascii.isAlphabetic(name[i])) i += 1;
    if (i == 0 or i >= name.len or name[i] != '-') return null;
    var j = i + 1;
    while (j < name.len and std.ascii.isDigit(name[j])) j += 1;
    if (j == i + 1) return null;
    return name[0..j];
}

/// The repository's pull request template, where GitHub looks for one.
fn prTemplate() ?[]u8 {
    const places = [_][]const u8{ ".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", "docs/pull_request_template.md", "pull_request_template.md", ".gitlab/merge_request_templates/Default.md" };
    const dir = std.Io.Dir.cwd();
    for (places) |place| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ std.mem.trimEnd(u8, repo_path.items, "/"), place }) catch continue;
        return dir.readFileAlloc(app_io, path, gpa, .limited(64 * 1024)) catch continue;
    }
    return null;
}

fn clearPrCreate() void {
    pr_new_open = false;
    for ([_]*std.ArrayList(u8){ &pr_new_title, &pr_new_body, &pr_new_base, &pr_new_reviewers }) |t| {
        t.deinit(gpa);
        t.* = .empty;
    }
}

fn prCreateDialog() void {
    if (!pr_new_open) return;
    const h = history orelse return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &pr_new_rect, &pr_new_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    dialogHeader(@src(), dvui.entypo.merge, "New pull request", h.head orelse "", &pr_new_open);

    // A fixed width: the description comes filled in with the template and
    // the commits, and its longest line would otherwise set the dialog's.
    var body = dialogBody(@src(), @min(PR_CREATE_W, win.w - 80));

    // The two branches, as GitHub's compare bar has them: into, from.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        branchPicker(0, "Into", &pr_new_base, .remote);
        branchPicker(1, "From", &pr_new_head, .local);
    }

    // Pushed first: the host can only open one on a branch it has.
    const head = std.mem.trim(u8, pr_new_head.items, " ");
    const on_head = if (h.head) |name| std.mem.eql(u8, name, head) else false;
    const pushed = if (on_head)
        h.tracking.upstream != null and h.tracking.ahead == 0
    else
        remoteHas(head);
    if (!pushed and head.len > 0) {
        const orange = style.get().orange;
        var note = dialog_views.alertBox(@src(), 0, orange, dvui.entypo.upload, .{ .h = style.space.lg });
        defer note.deinit();
        const missing = !on_head or h.tracking.upstream == null;
        dialog_views.alertText(@src(), if (missing) "The branch is not on the remote yet: push it first." else "Some commits are not pushed yet: push them first.", orange);
        if (dialog_views.alertButton(@src(), "Push", orange, "pr_new:push")) {
            if (on_head) {
                requestNetwork("Pushing", &.{ "-c", "push.autoSetupRemote=true", "push" });
            } else if (defaultRemote()) |remote| requestNetwork("Pushing", &.{ "push", "-u", remote, head });
        }
    }

    var entered = false;
    _ = dialog_views.dialogField(@src(), 0, "Title", &pr_new_title, "What it does", true, &entered);
    dialog_views.dialogLabel(@src(), "Description");
    {
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_new_body, .allocator = gpa, .limit = 65536 } },
            .multiline = true,
            .break_lines = true,
            .placeholder = "Why, and how to try it",
        }, settingsInput().override(.{ .tag = "pr_new:body", .min_size_content = .{ .h = 160 }, .max_size_content = .size(.{ .w = 0, .h = 260 }), .margin = .{ .h = style.space.lg } }));
        te.deinit();
    }

    // Who, and what it is about: GitHub's sidebar, as three pickers.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        peoplePicker(2, "Reviewers", &pr_new_reviewers, "Ask for reviews", true, "pr_new:reviewers");
        peoplePicker(3, "Assignees", &pr_new_assignees, "Assign someone", false, "pr_new:assignees");
        labelPicker(4, &pr_new_labels, "pr_new:labels");
    }
    // What GitHub refused, where it was asked.
    if (!pr_creating) if (tab_strip.command_error) |why| {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .background = false, .padding = dvui.Rect.all(0) });
        tl.addText(dialog_views.firstLine(why), .{ .font = style.small(), .color_text = .{ .color = style.danger() } });
        tl.deinit();
    };
    body.deinit();

    {
        var line = dialogFooter(@src());
        defer line.deinit();
        typePicker(5, &pr_new_draft, "pr_new:type");
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (pr_creating) {
            // Waiting on GitHub: what for, and nothing to click twice.
            rebase_view.loadingSpinner(@src());
            dvui.label(@src(), "Creating the pull request…", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        } else {
            if (dialog_views.dialogButton(@src(), "Cancel", false)) pr_new_open = false;
            if (pushed and dialog_views.dialogButton(@src(), if (pr_new_draft) "Create draft" else "Create pull request", true)) createRequest();
        }
    }
    if (dialog_views.escapePressed() and pick_open == null and !pr_creating) pr_new_open = false;
}

/// The create dialog's width: two branches side by side, three pickers.
const PR_CREATE_W: f32 = 620;

/// Whether the default remote has a branch of that name, as last fetched.
fn remoteHas(branch: []const u8) bool {
    const h = history orelse return false;
    const remote = defaultRemote() orelse return false;
    for (h.refs) |ref| {
        if (ref.kind != .remote) continue;
        const split = splitRemoteRef(ref.name);
        if (std.mem.eql(u8, split.remote, remote) and std.mem.eql(u8, split.branch, branch)) return true;
    }
    return false;
}

/// A field that drops a list to pick from: what is picked on its face, or
/// what to do when nothing is. `end` closes it.
pub const Picker = struct {
    button: window_chrome.DropButton,
    menu: ?*dvui.FloatingMenuWidget,
    id: usize,

    pub fn end(self: Picker) void {
        self.button.end(self.menu);
    }
};

fn picker(id: usize, face: []const u8, placeholder: []const u8, tag: []const u8) Picker {
    var button = window_chrome.DropButton.begin(@src(), .{
        .id_extra = id,
        .tag = tag,
        .expand = .horizontal,
        .gravity_y = 0,
        .background = false,
        .color_fill_hover = .{ .color = style.rowHover() },
        .corners = style.radius.input,
        .padding = dvui.Rect.all(0),
    });
    const field_w = button.item.data().rect.w;
    button.min_w = @max(field_w, 240);
    {
        const lit = button.item.show_active or button.item.mouse_over;
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (lit) style.rowHover() else style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
        });
        defer box.deinit();
        var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
        const text = if (face.len > 0) face else placeholder;
        dvui.label(@src(), "{s}", .{graph_view.fitText(&buf, text, style.small(), @max(40, field_w - 48))}, .{
            .font = style.small(),
            .color_text = .{ .color = if (face.len > 0) style.text() else style.textFaint() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
        dvui.icon(@src(), "pick_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs },
        });
    }
    const menu = button.open();
    // Opened afresh: nothing typed over its list yet.
    if (menu != null and pick_open != id) {
        pick_open = id;
        pick_filter.clearRetainingCapacity();
    } else if (menu == null and pick_open == id) pick_open = null;
    return .{ .button = button, .menu = menu, .id = id };
}

/// The field typed over a picker's list, and whether `text` gets through it.
fn pickSearch(placeholder: []const u8) void {
    dialog_views.focusOnce(dialog_views.searchField(@src(), &pick_filter, placeholder, "pick_filter", .{ .x = style.space.xs, .y = style.space.xs, .w = style.space.xs, .h = style.space.sm }));
}

fn pickShown(text: []const u8, also: []const u8) bool {
    const needle = std.mem.trim(u8, pick_filter.items, " ");
    if (needle.len == 0) return true;
    return std.ascii.findIgnoreCase(text, needle) != null or std.ascii.findIgnoreCase(also, needle) != null;
}

/// The scrolling list under a picker's search: as tall as it needs, up to
/// a bound.
pub fn pickList() *dvui.ScrollAreaWidget {
    return dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .max_size_content = .height(@min(300, dvui.windowRect().h * 0.5)),
        .background = false,
    });
}

/// One row of a picker's list: a tick when picked, a colour where it has
/// one, its name, what more there is to say of it.
pub fn pickRow(id: usize, text: []const u8, sub: []const u8, picked: bool, hue: ?dvui.Color) bool {
    var mi = dvui.menuItem(@src(), .{}, .{
        .id_extra = id,
        .tag = dialog_views.frameTag("pick", text),
        .expand = .horizontal,
        .corners = style.radius.input,
        .color_fill_hover = .{ .color = style.accentDim() },
        .padding = .{ .x = style.space.md, .y = graph_view.MENU_ROW_PAD_Y, .w = style.space.md, .h = graph_view.MENU_ROW_PAD_Y },
    });
    defer mi.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer row.deinit();
    dvui.icon(@src(), "pick_tick", dvui.entypo.check, .{ .fill_color = .{ .color = if (picked) style.accent() else dvui.Color.transparent } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    if (hue) |c| {
        var dot = dvui.box(@src(), .{}, .{
            .background = true,
            .color_fill = .{ .color = c },
            .corners = .all(5),
            .min_size_content = .{ .w = 10, .h = 10 },
            .max_size_content = .size(.{ .w = 10, .h = 10 }),
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
        });
        dot.deinit();
    }
    dvui.label(@src(), "{s}", .{text}, .{
        .font = if (picked) style.smallBold() else style.small(),
        .color_text = .{ .color = style.text() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    if (sub.len > 0) dvui.label(@src(), "{s}", .{sub}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    return mi.activeRect() != null;
}

const BranchSide = enum { remote, local };

/// A branch to pick: the remote's for where it goes, yours for where it
/// comes from.
fn branchPicker(id: usize, caption: []const u8, value: *std.ArrayList(u8), side: BranchSide) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false, .margin = .{ .w = if (side == .remote) style.space.md else 0 } });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), caption);
    const p = picker(id, value.items, "Pick a branch", if (side == .remote) "pr_new:base" else "pr_new:head");
    defer p.end();
    const m = p.menu orelse return;
    const h = history orelse return;
    pickSearch("Find a branch…");
    var list = pickList();
    defer list.deinit();
    const remote = defaultRemote() orelse "origin";
    var shown: usize = 0;
    for (h.refs, 0..) |ref, i| {
        const name = switch (side) {
            .remote => blk: {
                if (ref.kind != .remote) continue;
                const split = splitRemoteRef(ref.name);
                if (!std.mem.eql(u8, split.remote, remote) or std.mem.eql(u8, split.branch, "HEAD")) continue;
                break :blk split.branch;
            },
            .local => if (ref.kind == .local) ref.name else continue,
        };
        if (!pickShown(name, "")) continue;
        if (shown >= dialog_views.MAX_BRANCH_CHOICES) break;
        shown += 1;
        if (pickRow(i, name, if (side == .local and !remoteHas(name)) "not pushed" else "", std.mem.eql(u8, value.items, name), null)) {
            value.clearRetainingCapacity();
            value.appendSlice(gpa, name) catch {};
            m.close();
        }
    }
    if (shown == 0) dialog_views.dropHeading(@src(), 20, "NO BRANCH BY THAT NAME");
}

/// People to pick, from those who can be asked on the host: reviewers or
/// assignees.
fn peoplePicker(id: usize, caption: []const u8, list: *std.ArrayList(u8), placeholder: []const u8, reviewers: bool, tag: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false, .margin = .{ .w = style.space.md } });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), caption);
    const p = picker(id, list.items, placeholder, tag);
    defer p.end();
    _ = p.menu orelse return;
    _ = peopleRows(list, reviewers);
}

/// A people picker's list: a field to narrow it, then everyone who can be
/// asked, ticked where they are in `list` — you are not among the
/// reviewers of your own request. The login a click toggled, if one did.
fn peopleRows(list: *std.ArrayList(u8), reviewers: bool) ?[]const u8 {
    switch (pr.meta_status) {
        .idle, .loading => {
            dialog_views.dropHeading(@src(), 0, "LOADING…");
            return null;
        },
        .failed => {
            dialog_views.dropHeading(@src(), 0, "COULD NOT READ WHO CAN BE ASKED");
            return null;
        },
        .ready => {},
    }
    pickSearch("Find someone…");
    var rows = pickList();
    defer rows.deinit();
    var shown: usize = 0;
    var toggled: ?[]const u8 = null;
    for (pr.meta.people, 0..) |person, i| {
        if (reviewers and window_chrome.me_gh.items.len > 0 and std.ascii.eqlIgnoreCase(person.login, window_chrome.me_gh.items)) continue;
        if (!pickShown(person.login, person.name)) continue;
        shown += 1;
        if (pickRow(i, person.login, person.name, listHas(list.items, person.login), null)) {
            listToggle(list, person.login);
            toggled = person.login;
        }
    }
    if (shown == 0) dialog_views.dropHeading(@src(), 1, "NOBODY BY THAT NAME");
    return toggled;
}

/// The repository's labels, each with its colour and what it is for.
fn labelPicker(id: usize, list: *std.ArrayList(u8), tag: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), "Labels");
    const p = picker(id, list.items, "Add labels", tag);
    defer p.end();
    _ = p.menu orelse return;
    _ = labelRows(list);
}

/// A label picker's list; the label a click toggled, if one did.
fn labelRows(list: *std.ArrayList(u8)) ?[]const u8 {
    switch (pr.meta_status) {
        .idle, .loading => {
            dialog_views.dropHeading(@src(), 0, "LOADING…");
            return null;
        },
        .failed => {
            dialog_views.dropHeading(@src(), 0, "COULD NOT READ THE LABELS");
            return null;
        },
        .ready => {},
    }
    pickSearch("Find a label…");
    var rows = pickList();
    defer rows.deinit();
    var shown: usize = 0;
    var toggled: ?[]const u8 = null;
    for (pr.meta.labels, 0..) |label, i| {
        if (!pickShown(label.name, label.description)) continue;
        shown += 1;
        if (pickRow(i, label.name, label.description, listHas(list.items, label.name), labelColor(label.color))) {
            listToggle(list, label.name);
            toggled = label.name;
        }
    }
    if (shown == 0) dialog_views.dropHeading(@src(), 1, if (pr.meta.labels.len == 0) "THE REPOSITORY HAS NO LABELS" else "NO LABEL BY THAT NAME");
    return toggled;
}

/// Ready for review, or a draft.
fn typePicker(id: usize, draft: *bool, tag: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .min_size_content = .{ .w = 200 }, .background = false, .gravity_y = 0.5 });
    defer cell.deinit();
    const p = picker(id, if (draft.*) "Draft" else "Ready for review", "", tag);
    defer p.end();
    const m = p.menu orelse return;
    if (pickRow(0, "Ready for review", "reviewers are told", !draft.*, null)) {
        draft.* = false;
        m.close();
    }
    if (pickRow(1, "Draft", "nobody is asked yet", draft.*, null)) {
        draft.* = true;
        m.close();
    }
}

/// A field that shows what cannot be picked here: the branch a request
/// comes from, once it is made.
fn fixedField(id: usize, caption: []const u8, value: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), caption);
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
    });
    defer box.deinit();
    dvui.label(@src(), "{s}", .{value}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
}

/// Whether `item` is in the comma-separated `list`.
fn listHas(list: []const u8, item: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " "), item)) return true;
    return false;
}

/// `item` added to the comma-separated `list`, or taken out of it.
fn listToggle(list: *std.ArrayList(u8), item: []const u8) void {
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(gpa);
    var found = false;
    var it = std.mem.splitScalar(u8, list.items, ',');
    while (it.next()) |raw| {
        const x = std.mem.trim(u8, raw, " ");
        if (x.len == 0) continue;
        if (std.mem.eql(u8, x, item)) {
            found = true;
            continue;
        }
        if (next.items.len > 0) next.appendSlice(gpa, ", ") catch return;
        next.appendSlice(gpa, x) catch return;
    }
    if (!found) {
        if (next.items.len > 0) next.appendSlice(gpa, ", ") catch return;
        next.appendSlice(gpa, item) catch return;
    }
    list.clearRetainingCapacity();
    list.appendSlice(gpa, next.items) catch {};
}

/// The comma-separated `text` as a JSON list of strings, in `a`: names
/// with spaces in them — a label's — kept whole.
fn jsonCommaList(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return "[]";
    var it = std.mem.splitScalar(u8, text, ',');
    var first = true;
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " \t\n");
        if (word.len == 0) continue;
        if (!first) out.append(a, ',') catch return "[]";
        first = false;
        github.jsonString(a, &out, word) catch return "[]";
    }
    out.append(a, ']') catch return "[]";
    return out.items;
}

fn createRequest() void {
    const title = std.mem.trim(u8, pr_new_title.items, " \n\t");
    const base = std.mem.trim(u8, pr_new_base.items, " ");
    if (title.len == 0 or base.len == 0) return setCommandError("A title and a branch to merge into are needed.");
    const head = std.mem.trim(u8, pr_new_head.items, " ");
    if (head.len == 0) return setCommandError("Pick the branch it comes from.");
    const a = dvui.currentWindow().arena();
    var body: std.ArrayList(u8) = .empty;
    body.appendSlice(a, jsonFields(a, &.{ .{ "title", title }, .{ "body", pr_new_body.items }, .{ "head", head }, .{ "base", base } })) catch return;
    // The draft flag is a JSON boolean, after the strings.
    if (pr_new_draft) {
        _ = body.pop();
        body.appendSlice(a, ",\"draft\":true}") catch return;
    }
    // Asked for, assigned and labelled once GitHub has given it a number.
    api_reviewers.clearRetainingCapacity();
    const reviewers = jsonList(a, pr_new_reviewers.items);
    if (reviewers.len > 2) api_reviewers.appendSlice(gpa, reviewers) catch {};
    api_assignees.clearRetainingCapacity();
    const assignees = jsonList(a, pr_new_assignees.items);
    if (assignees.len > 2) api_assignees.appendSlice(gpa, assignees) catch {};
    api_labels.clearRetainingCapacity();
    const labels = jsonCommaList(a, pr_new_labels.items);
    if (labels.len > 2) api_labels.appendSlice(gpa, labels) catch {};
    var path: [512]u8 = undefined;
    requestApi("Creating", "POST", apiPath(&path, "/pulls", .{}), body.items, .ask_reviewers);
    // Open until it is made: then it closes, and the request opens.
    pr_creating = api_job != null or api_queue.items.len > 0;
    if (!pr_creating) pr_new_open = false;
}

/// One open request: its number and title, and the two things to do with one
/// from here — check it out, or read it on the host.
pub fn requestRow(src: std.builtin.SourceLocation, entry: pr.Request, id: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();

    dvui.label(@src(), "#{d}", .{entry.number}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = if (entry.draft) style.textFaint() else style.accent() },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    dvui.label(@src(), "{s}", .{entry.title}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = dvui.Rect.all(0),
    });

    // The row itself opens the request in the pull-request tab.
    if (dvui.clicked(row.data(), .{})) {
        openPulls();
        selectRequest(entry.number);
    }

    if (dialog_views.iconButton(@src(), "request_checkout", "Check it out", dvui.entypo.download, style.textMuted())) checkoutRequest(entry.number, entry.branch, false);
    if (dialog_views.iconButton(@src(), "request_web", "Open it on the web", dvui.entypo.popup, style.textFaint())) openOnGithub("/pull/{d}", .{entry.number});
}

/// One open issue: its number and title, a label or two, and the page it
/// is on, where it is read and answered.
pub fn issueRow(src: std.builtin.SourceLocation, entry: pr.Issue, id: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();

    dvui.label(@src(), "#{d}", .{entry.number}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = style.get().green },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    dvui.label(@src(), "{s}", .{entry.title}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = dvui.Rect.all(0),
    });
    for (entry.labels[0..@min(entry.labels.len, 2)], 0..) |name, i| {
        dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = i,
            .font = style.tiny(),
            .color_text = .{ .color = style.textMuted() },
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .corners = style.radius.tag,
            .gravity_y = 0.5,
            .max_size_content = .width(80),
            .margin = .{ .x = style.space.xs },
            .padding = .{ .x = style.space.xs, .w = style.space.xs },
        });
    }

    const clicked = dvui.clicked(row.data(), .{});
    if (dialog_views.iconButton(@src(), "issue_web", "Open it on the web", dvui.entypo.popup, style.textFaint()) or clicked) openOnGithub("/issues/{d}", .{entry.number});
}

/// One worktree: where it is, and the two things to do with one — open it in
/// a tab of its own, or remove it.
pub fn worktreeRow(src: std.builtin.SourceLocation, entry: git.Worktree, id: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
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
    dvui.label(@src(), "{s}", .{entry.path}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });

    if (hover) {
        if (dialog_views.iconButton(@src(), "worktree_open", "Open in a tab", dvui.entypo.popup, style.textMuted())) {
            requestOpenKnown(entry.path);
        }
        if (dialog_views.iconButton(@src(), "worktree_remove", "Remove this worktree", dvui.entypo.cross, style.textFaint())) {
            ask(.remove_worktree, entry.path);
        }
    }
    const more = if (hover) moreButton(dialog_views.frameTag("more", entry.name)) else null;
    // After the buttons, so the row does not take their presses.
    if (dvui.clicked(row.data(), .{})) revealInGraph(entry.head);
    worktreeMenu(entry, id, row_rect, more);
}

fn worktreeMenu(entry: git.Worktree, id: usize, rect: dvui.Rect.Physical, open_at: ?dvui.Point.Physical) void {
    const ctx = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();
    openContextAt(ctx, open_at);
    const cp = ctx.activePoint() orelse return;
    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();
    graph_view.menuTitle(entry.name, "worktree");
    if (graph_view.menuIcon(@src(), dvui.entypo.popup, "Open in a tab", false)) {
        fw.close();
        requestOpenKnown(entry.path);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.flow_branch, "Show in the graph", false)) {
        fw.close();
        revealInGraph(entry.head);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.clipboard, "Copy the path", false)) {
        fw.close();
        dvui.clipboardTextSet(entry.path);
    }
    graph_view.menuSeparator(1);
    if (graph_view.menuIcon(@src(), dvui.entypo.cross, "Remove this worktree…", true)) {
        fw.close();
        ask(.remove_worktree, entry.path);
    }
}

/// One stash, with the two things you do to one.
///
/// Drop goes through the confirmation toast: it is the one of the three that
/// nothing gets back.
pub fn stashRow(src: std.builtin.SourceLocation, entry: git.Stash, id: usize) void {
    var short_tag: [8]u8 = undefined;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        // By its sha, for a test to hover it.
        .tag = dialog_views.frameTag("stash", git.oidShort(entry.id, &short_tag)),
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();
    const row_rect = row.data().borderRectScale().r;
    const hover = row_rect.contains(dvui.currentWindow().mouse_pt);
    if (hover) row_rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });

    dvui.label(@src(), "{s}", .{entry.message}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = dvui.Rect.all(0),
    });

    // Apply keeps the stash, pop takes it off the stack — the distinction every
    // git GUI shows, because getting it wrong the other way loses the entry.
    var short: [8]u8 = undefined;
    if (hover) {
        if (dialog_views.iconButtonTagged(@src(), "stash_apply", "Apply, and keep the stash", dvui.entypo.download, style.textFaint(), dialog_views.frameTag("stash_apply", git.oidShort(entry.id, &short)))) {
            rebase_view.requestStash("apply", entry.id);
        }
        if (dialog_views.iconButton(@src(), "stash_pop", "Apply, and drop the stash", dvui.entypo.@"export", style.textMuted())) {
            rebase_view.requestStash("pop", entry.id);
        }
        if (dialog_views.iconButton(@src(), "stash_drop", "Delete this stash", dvui.entypo.trash, style.textFaint())) {
            var hex: [41]u8 = undefined;
            ask(.stash_drop, git.oidHex(entry.id, &hex));
        }
    }
    const more = if (hover) moreButton(dialog_views.frameTag("more", git.oidShort(entry.id, &short))) else null;
    // The commit it was made on: the stash commit itself is not in the graph.
    if (dvui.clicked(row.data(), .{})) revealInGraph(entry.base);
    stashMenu(entry, id, row_rect, more);
}

pub fn stashMenu(entry: git.Stash, id: usize, rect: dvui.Rect.Physical, open_at: ?dvui.Point.Physical) void {
    const ctx = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();
    openContextAt(ctx, open_at);
    const cp = ctx.activePoint() orelse return;
    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();
    graph_view.menuTitle(entry.message, "stash");
    if (graph_view.menuIcon(@src(), dvui.entypo.download, "Apply, and keep the stash", false)) {
        fw.close();
        rebase_view.requestStash("apply", entry.id);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.@"export", "Pop: apply, and drop the stash", false)) {
        fw.close();
        rebase_view.requestStash("pop", entry.id);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.flow_branch, "Show where it was made", false)) {
        fw.close();
        revealInGraph(entry.base);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.text_document, "Show its changes", false)) {
        fw.close();
        selectCommit(entry.id);
    }
    graph_view.menuSeparator(1);
    if (graph_view.menuIcon(@src(), dvui.entypo.trash, "Delete this stash…", true)) {
        fw.close();
        var hex: [41]u8 = undefined;
        ask(.stash_drop, git.oidHex(entry.id, &hex));
    }
}

/// A branch last committed to longer ago than this reads as done with.
const STALE_AFTER_S: i64 = 30 * 86400;

/// One ref. Double-click is what checks out, like every other git GUI: a single
/// click on a branch list should never move the working tree.
pub fn refRow(src: std.builtin.SourceLocation, ref: git.Ref, id: usize) bool {
    // Three siblings on one line — the eye, the button that is the ref, the
    // ⋯ — rather than icons inside the button: nested in it, they never saw
    // their clicks.
    var line = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        // Exactly a line high: `sideRows` places lines by arithmetic.
        .min_size_content = .{ .h = style.side_row },
        .max_size_content = .height(style.side_row),
        .background = false,
        // The name lands on the section title's column, past the gutter.
        .padding = .{ .x = rebase_view.SIDE_TEXT_X - rebase_view.SIDE_GUTTER - rebase_view.SIDE_REF_PAD + (if (ref.kind == .remote) rebase_view.SIDE_NEST else 0), .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer line.deinit();
    const line_rect = line.data().borderRectScale().r;
    const hover = line_rect.contains(dvui.currentWindow().mouse_pt);
    const hidden = graph_view.isHidden(ref.name);
    // Drawn by hand, before anything on it: the box picked its background
    // before it knew where the mouse was. The drop's tint goes on below,
    // once the button has said whether one is over it.
    if (ref.head or hover) line_rect.fill(.{}, .{ .color = .{ .color = if (ref.head) style.rowSelected() else style.rowHover() }, .fade = 0 });

    // Far left, in the gutter, the eye: in the graph or out of it, a click
    // either way. The branch checked out is always in: its gutter holds the
    // tick that says it is the current one, so its name lines up with the
    // others'.
    if (ref.head) {
        dvui.icon(@src(), "head_check", dvui.entypo.check, .{ .fill_color = .{ .color = style.accent() } }, .{
            .min_size_content = .{ .w = 11, .h = 11 },
            .gravity_y = 0.5,
            .margin = .{ .x = (rebase_view.SIDE_GUTTER - 11) / 2, .w = (rebase_view.SIDE_GUTTER - 11) / 2 },
        });
    } else if (dialog_views.iconButtonTagged(@src(), "ref_eye", if (hidden) "Show in the graph" else "Hide from the graph", eyeIcon(hidden), if (hidden) style.textMuted() else if (hover) style.textFaint() else dvui.Color.transparent, dialog_views.frameTag("eye", ref.name))) {
        graph_view.toggleHidden(ref);
    }

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        // Local branches by name, so a test can find the row to drag.
        .tag = if (ref.kind == .local) ref.name else null,
        // The whole line, so the name is centred on it like the eye and the ⋯
        // beside it, not on a button as high as its text sitting at the top.
        .expand = .both,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    // Before the button sees them: a press may be the start of a drag, and a
    // release over this row may be the end of one.
    const drop_target = graph_view.branchDrop(bw.data(), ref);
    bw.processEvents();
    graph_view.branchDragStart(bw.data(), ref);
    if (drop_target) bw.data().borderRectScale().r.fill(.{}, .{ .color = .{ .color = style.accentDim() }, .fade = 0 });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = false,
            .padding = .{ .x = rebase_view.SIDE_REF_PAD },
        });
        defer row.deinit();
        // Out of the graph, whatever put it out — hidden, another shown
        // alone, the remote branches off: said by fading it.
        const out_of_graph = !graph_view.graphFilter().walks(ref);

        // A branch nobody has committed to in a month, faded like one out of
        // the graph: still there, probably done with.
        const stale = ref.kind != .tag and !ref.head and ref.time > 0 and frame_now_s - ref.time > STALE_AFTER_S;

        // Listed under its remote, so the remote's name would only repeat it.
        const shown = if (ref.kind == .remote) splitRemoteRef(ref.name).branch else ref.name;
        dvui.label(@src(), "{s}", .{shown}, .{
            .font = if (ref.head) style.smallBold() else style.small(),
            .color_text = .{ .color = if (out_of_graph or stale) style.textFaint() else if (ref.head) style.text() else style.textMuted() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
        // Pinned: said at the end of the line, with what the branch owes its
        // upstream, so the names keep one left edge.
        if (graph_view.hasName(graph_view.graph_pinned.items, ref.name)) {
            dvui.icon(@src(), "pinned", dvui.entypo.pin, .{ .fill_color = .{ .color = style.accent() } }, .{
                .min_size_content = .{ .w = 10, .h = 10 },
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.xs },
            });
        }
        search_view.trackingMarks(ref.tracking, style.textMuted());
        search_view.requestBadge(ref, style.textMuted());
    }

    // Tags name a commit, not a branch to work on; checking one out detaches
    // HEAD, which is not what a click in a list should do.
    // One click brings its commit up in the graph; the second of a double
    // checks it out.
    const clicked = bw.clicked();
    if (clicked) revealInGraph(ref.target);
    const activated = ref.kind != .tag and clicked and rebase_view.isDoubleClick(bw.data().id);
    if (bw.hovered() and ref.time > 0) {
        var when: [32]u8 = undefined;
        // Right of the whole line, past the sidebar's edge: right of the name
        // alone it sat on the ⋯ the hover had just brought up.
        dvui.tooltip(@src(), .{ .active_rect = line_rect, .position = .horizontal, .delay = 500_000 }, "Last commit {s}", .{search_view.relativeTime(&when, ref.time)}, .{
            .font = style.small(),
            .id_extra = id,
        });
    }
    bw.deinit();

    // Far right on hover, the ⋯: the right-click menu, for a mouse that
    // does not think of right-clicking.
    const more = if (hover) moreButton(dialog_views.frameTag("more", ref.name)) else null;
    graph_view.refMenu(@src(), ref, id, line_rect, more);
    return activated;
}

/// The ⋯ at a hovered row's end. Where it was clicked, to open the row's
/// menu at; null otherwise. Only on the hovered row: kept on every row,
/// invisible, it took its width from every name in the sidebar.
fn moreButton(tag: ?[]const u8) ?dvui.Point.Physical {
    if (!dialog_views.iconButtonTagged(@src(), "row_more", "More…", dvui.entypo.dots_three_horizontal, style.textMuted(), tag)) return null;
    return dvui.currentWindow().mouse_pt;
}

/// Open a row's right-click menu as a right-click at `at` would: what the
/// ⋯ does.
pub fn openContextAt(ctx: *dvui.ContextWidget, at: ?dvui.Point.Physical) void {
    const p = at orelse return;
    dvui.focusWidget(ctx.data().id, null, null);
    ctx.focused = true;
    ctx.activePt = p.toNatural();
}

// === Bottom ===

fn statusBar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .min_size_content = .{ .h = style.statusbar_height },
        .padding = .{ .x = style.space.md, .w = style.space.sm },
        .border = .{ .y = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer bar.deinit();

    // Each panel's fold on its own side: the branches' at this end.
    panelToggle(@src(), &show_sidebar, dvui.entypo.align_left, "Branches panel — Ctrl+B", "status:sidebar");
    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm, .w = style.space.md },
        .color_fill = .{ .color = style.border() },
    });

    // What the repository holds, each with its icon.
    if (history) |h| {
        statusStat(@src(), dvui.entypo.flow_line, h.commits.len, "commit", "commits");
        statusStat(@src(), dvui.entypo.flow_branch, h.refCount(.local), "branch", "branches");
        statusStat(@src(), dvui.entypo.archive, h.stashes.len, "stash", "stashes");
    }

    // What is running, and what failed: the one line about the last command,
    // on a pill of its colour. Both at once: a job clears the line as it
    // starts, so a failure beside it came after — a click refused because
    // it is running, say — and would otherwise sit unseen behind it.
    if (tab_strip.job != null) {
        statusPill(@src(), style.accent(), dvui.entypo.cycle, tab_strip.job_label, "…");
    } else if (api_job != null) {
        statusPill(@src(), style.accent(), dvui.entypo.cycle, api_label, "…");
    }
    if (tab_strip.command_error) |message| {
        statusPill(@src(), style.danger(), dvui.entypo.warning, dialog_views.firstLine(message), "");
        if (dialog_views.iconButton(@src(), "dismiss_error", "Dismiss", dvui.entypo.cross, style.textMuted())) {
            clearCommandError();
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.md, .w = style.space.sm },
        .color_fill = .{ .color = style.border() },
    });

    // The zoom, only when it is not 100 %: a click puts it back.
    if (tab_strip.zoom != 1.0) {
        var buf: [8]u8 = undefined;
        const caption = std.fmt.bufPrint(&buf, "{d}%", .{@round(tab_strip.zoom * 100)}) catch "";
        if (dialog_views.linkButtonTagged(@src(), caption, style.textMuted(), "status:zoom")) tab_strip.setZoom(1.0);
    }

    // The keys, then the changes panel's fold, on its side.
    if (dialog_views.iconButtonTagged(@src(), "status_keys", "Keyboard shortcuts", dvui.entypo.keyboard, if (keys_open) style.accent() else style.textMuted(), "status:keys")) {
        keys_open = true;
        keys_rect = .{};
    }
    panelToggle(@src(), &show_detail, dvui.entypo.align_right, "Changes panel — Ctrl+J", "status:detail");

    // The version, at the far end: a click shows what this one can do.
    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm, .w = style.space.sm },
        .color_fill = .{ .color = style.border() },
    });
    if (dialog_views.linkButtonTagged(@src(), "v" ++ APP_VERSION, if (features_open) style.accent() else style.textMuted(), "status:version")) {
        features_open = true;
        features_rect = .{};
    }
}

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

fn featuresDialog() void {
    if (!features_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &features_rect, &features_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    dialogHeader(@src(), dvui.entypo.info_with_circle, "About Zit", "Version " ++ APP_VERSION ++ " · " ++ PLATFORM, &features_open);

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
            .source = .{ .imageFile = .{ .bytes = @embedFile("brand/zit-icon-256.png"), .name = "zit" } },
            .shrink = .both,
        }, .{ .min_size_content = .{ .w = 56, .h = 56 }, .max_size_content = .size(.{ .w = 56, .h = 56 }), .gravity_y = 0.5, .margin = .{ .w = style.space.lg } });
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false });
        defer col.deinit();
        dvui.label(@src(), "Zit " ++ APP_VERSION, .{}, .{ .font = style.title().withSize(18 * style.ui_scale), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "A fast, native Git client for Linux and Windows, written in Zig.", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2, .h = style.space.md } });
        var links = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        defer links.deinit();
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.book, "Documentation", true, "about:docs")) openUrl(SITE_URL);
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.star, "What's new", false, "about:changelog")) openUrl(SITE_URL ++ "project/changelog/");
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.code, "Source", false, "about:repo")) openUrl(REPO_URL);
        if (dialog_views.chipButtonTagged(@src(), dvui.entypo.bug, "Report a problem", false, "about:issue")) openUrl(REPO_URL ++ "/issues/new");
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
            iconTile(@src(), feature.icon, 32, 16);
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
var features_page: usize = 0;

/// Where Zit is: its documentation, and its sources.
pub const SITE_URL = "https://damienmonchaty.github.io/zit/";
const REPO_URL = "https://github.com/DamienMonchaty/zit";
const PLATFORM = switch (@import("builtin").os.tag) {
    .windows => "Windows",
    .macos => "macOS",
    else => "Linux",
} ++ " " ++ @tagName(@import("builtin").cpu.arch);

/// A panel's fold button in the status bar: lit while the panel is shown.
fn panelToggle(src: std.builtin.SourceLocation, shown: *bool, icon: []const u8, hint: []const u8, tag: []const u8) void {
    if (dialog_views.iconButtonTagged(src, tag, hint, icon, if (shown.*) style.accent() else style.textFaint(), tag)) shown.* = !shown.*;
}

/// One count in the status bar, after its icon. English plurals, which is
/// all this needs: "1 stash", "2 stashes".
fn statusStat(src: std.builtin.SourceLocation, icon: []const u8, n: usize, one: []const u8, many: []const u8) void {
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
fn statusPill(src: std.builtin.SourceLocation, color: dvui.Color, icon: []const u8, text: []const u8, tail: []const u8) void {
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
fn startScreen() void {
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
                .bytes = if (dark_theme) @embedFile("brand/zit-logo-light.png") else @embedFile("brand/zit-logo-dark.png"),
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
        if (repo == null) dvui.label(@src(), "{s}", .{message}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textFaint() },
            .padding = dvui.Rect.all(0),
            .margin = .{ .h = style.space.md },
        });
    }

    {
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false, .margin = .{ .h = style.space.xl } });
        defer actions.deinit();
        if (startAction(@src(), dvui.entypo.folder, "Open a folder", "Ctrl+O", "start:Open a repository", true)) requestAction(.open_repo);
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
        if (listedEarlier(gi, ti, tab.path) or !startMatches(needle, tab.path)) continue;
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
        if (pressed(ke, .down, false)) {
            e.handled = true;
            if (start_pick + 1 < shown.items.len) start_pick += 1;
        } else if (pressed(ke, .up, false)) {
            e.handled = true;
            start_pick -|= 1;
        }
    };
    if (dialog_views.search_entered == field) {
        dialog_views.search_entered = null;
        if (start_pick < shown.items.len) requestOpenKnown(shown.items[start_pick]);
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

fn isOpenTab(path: []const u8) bool {
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
            tabBadge(git.repoName(path), open or picked);
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
    if (bw.clicked()) requestOpenKnown(path);
    bw.deinit();

    if (dialog_views.iconButton(@src(), "forget_repo", "Remove from Zit…", dvui.entypo.cross, if (hover or picked) style.textFaint() else dvui.Color.transparent)) {
        dialog_views.askForget(path);
    }
}

// === Tests ===

/// `commitMatches` and `commitShown` against the search box as it stands.
fn matchesNow(commit: git.Commit) bool {
    var buf: [graph_view.MAX_TERMS]graph_view.Term = undefined;
    return graph_view.commitMatches(commit, graph_view.parseQuery(commit_filter.items, &buf));
}

fn shownNow(commit: git.Commit, index: usize) bool {
    var buf: [graph_view.MAX_TERMS]graph_view.Term = undefined;
    return graph_view.commitShown(commit, index, graph_view.parseQuery(commit_filter.items, &buf));
}

test {
    std.testing.refAllDecls(@This());
    _ = avatars;
    _ = pr;
    _ = syntax;
    _ = watch;
    _ = github;
}

test "relative times round down to the largest unit that fits" {
    var buf: [32]u8 = undefined;
    // Pinned rather than read from the clock, so the test cannot drift.
    frame_now_s = 1_700_000_000;
    const now = frame_now_s;

    try std.testing.expectEqualStrings("just now", search_view.relativeTime(&buf, now - 5));
    try std.testing.expectEqualStrings("1 minute ago", search_view.relativeTime(&buf, now - 90));
    try std.testing.expectEqualStrings("2 hours ago", search_view.relativeTime(&buf, now - 7300));
    try std.testing.expectEqualStrings("5 days ago", search_view.relativeTime(&buf, now - 5 * 86400));
    try std.testing.expectEqualStrings("3 weeks ago", search_view.relativeTime(&buf, now - 21 * 86400));
    try std.testing.expectEqualStrings("in the future", search_view.relativeTime(&buf, now + 60));
}

test "only the headline of a git error reaches the toolbar" {
    try std.testing.expectEqualStrings(
        "error: pathspec 'nope' did not match",
        dialog_views.firstLine("error: pathspec 'nope' did not match\nDid you mean...\n"),
    );
    try std.testing.expectEqualStrings("short", dialog_views.firstLine("short"));
}

// The whole layout, rendered once.
//
// Immediate-mode UI fails at runtime, not at compile time — a bad gravity, a
// widget id collision or a deinit in the wrong order all build fine and then
// panic on frame one. This is the smallest thing that catches that.
test "the layout renders a frame" {
    // Needs a video backend; `SDL_VIDEODRIVER=dummy` is enough, and is what CI
    // should set.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    gpa = std.testing.allocator;
    // `appInit` normally sets these; this test drives `appFrame` directly.
    app_io = std.testing.io;
    defer resetUiGlobals();
    defer {
        commit_summary.deinit(gpa);
        commit_description.deinit(gpa);
        commit_summary = .empty;
        commit_description = .empty;
    }

    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(appFrame);
}

// The write path, end to end, against a real repository: every command Zit
// sends is a string, and only running it says whether it means what it looks
// like.
test "stage, commit and switch branches through the real git commands" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    // An identity of its own, so the test does not depend on the config of
    // whoever is running it.
    try expectGit(dir, &.{ "init", "-q", "-b", "main" });
    try expectGit(dir, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(dir, &.{ "config", "user.name", "Zit Test" });
    // Unsigned: the machine running this may sign every commit, and a GPG
    // passphrase prompt per test repo is not a test suite.
    try expectGit(dir, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(dir, &.{ "config", "tag.gpgsign", "false" });

    try tmp.dir.writeFile(app_io, .{ .sub_path = "hello.txt", .data = "one\n" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    try std.testing.expect(repo != null);
    try std.testing.expectEqual(@as(usize, 1), work.?.unstaged.len);
    try std.testing.expectEqual(git.Status.added, work.?.unstaged[0].status);

    // Stage.
    gitDo(&.{ "add", "-A" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 0), work.?.unstaged.len);

    // Unstage, and back again.
    gitDo(&.{ "reset", "-q", "--", "." });
    try std.testing.expectEqual(@as(usize, 0), work.?.staged.len);
    gitDo(&.{ "add", "-A" });
    try std.testing.expectEqual(@as(usize, 1), work.?.staged.len);

    // Commit.
    try commit_summary.appendSlice(gpa, "first commit");
    doCommit();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), history.?.commits.len);
    try std.testing.expectEqualStrings("first commit", history.?.commits[0].summary);
    try std.testing.expectEqual(@as(usize, 0), work.?.staged.len);
    // A successful commit clears the box it came from.
    try std.testing.expectEqual(@as(usize, 0), commit_summary.items.len);

    // Typed into while the commit ran: the box keeps the new text.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "hello.txt", .data = "two\n" });
    gitDo(&.{ "add", "-A" });
    try commit_summary.appendSlice(gpa, "second commit");
    doCommit();
    try commit_summary.appendSlice(gpa, ", and more");
    try pumpJob();
    try std.testing.expectEqualStrings("second commit", history.?.commits[0].summary);
    try std.testing.expectEqualStrings("second commit, and more", commit_summary.items);
    commit_summary.clearRetainingCapacity();

    // Requesting must not touch the repository: the UI is still iterating the
    // snapshot at that point. This is the use-after-free rule, as a test.
    const before = work.?.unstaged.ptr;
    request(&.{ "add", "-A" });
    try std.testing.expectEqual(before, work.?.unstaged.ptr);
    try std.testing.expect(runAction());

    // Switch to a branch whose name would be read as a path by `checkout --`.
    gitDo(&.{ "branch", "hello.txt" });
    const branch = findRef("hello.txt") orelse return error.BranchNotListed;
    checkout(branch);
    try std.testing.expect(runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("hello.txt", history.?.head.?);
    // The file is still there: this switched branch, it did not restore a path.
    try std.testing.expectEqual(@as(usize, 0), work.?.unstaged.len);

    // And back.
    const main_branch = findRef("main") orelse return error.BranchNotListed;
    checkout(main_branch);
    try std.testing.expect(runAction());
    try pumpJob();
    try std.testing.expectEqualStrings("main", history.?.head.?);
}

/// What the views added since 0.1.2 keep from one frame to the next — the
/// authors' index, a conflicted file's picks, the pull requests' cards and
/// form, the pickers' filters — freed at exit as between tests. Tests had
/// them freed; the exit did not: a Debug run's leak report is worth reading
/// only with nothing in it Zit meant to keep.
fn freeViews() void {
    graph_view.known_authors.deinit(gpa);
    graph_view.known_authors = .empty;
    _ = graph_view.authors_arena.reset(.free_all);
    graph_view.authors_seq = null;
    clearResolveUndo();
    resolve_undo.deinit(gpa);
    resolve_undo = .empty;
    conflict_path.deinit(gpa);
    conflict_path = .empty;
    pr_cards.deinit(gpa);
    pr_cards = .empty;
    for ([_]*std.ArrayList(u8){ &pr_new_head, &pr_new_assignees, &pr_new_labels, &pick_filter, &side_list }) |l| {
        l.deinit(gpa);
        l.* = .empty;
    }
}

/// The UI globals that outlive a test the way they outlive a frame.
///
/// Reset, not merely freed: `deinit` leaves an ArrayList undefined rather than
/// empty, and the next test to render a frame reads straight through it.
fn resetUiGlobals() void {
    tab_strip.zoom = 1.0;
    commit_view.commit_scroll = .{};
    commit_view.clearPickedChanges();
    commit_view.picked_changes.deinit(gpa);
    commit_view.picked_changes = .empty;
    commit_view.picked_set.deinit(gpa);
    commit_view.picked_set = .empty;
    redo_from = null;
    commit_view.clearFoldedDirs();
    commit_view.commit_all_files = false;
    commit_view.changes_scroll = @splat(.{ .vertical = .given });
    commit_view.changes_folded_lists = .{ false, false };
    search_view.branch_width = 0;
    search_view.clearSearchHits();
    search_view.reapSearchFetches(true);
    graph_view.clearGraphPrefs();
    graph_view.hidden_set.deinit(gpa);
    graph_view.hidden_set = .empty;
    graph_view.graph_hidden.deinit(gpa);
    graph_view.graph_only.deinit(gpa);
    graph_view.graph_hidden = .empty;
    graph_view.graph_only = .empty;
    graph_view.graph_pinned.deinit(gpa);
    graph_view.graph_pinned = .empty;
    settings_open = false;
    settings_page = 5;
    keys_open = false;
    features_open = false;
    active_view = .graph;
    left_squeezed = false;
    diff_view.section_collapsed = @splat(true);
    forgetTabs();
    tab_strip.groups.deinit(gpa);
    tab_strip.groups = .empty;
    tab_strip.workspaces.deinit(gpa);
    tab_strip.workspaces = .empty;
    ws_name.deinit(gpa);
    ws_name = .empty;
    ws_dialog = null;
    window_chrome.tab_revealed = null;
    tab_strip.config_dir.deinit(gpa);
    tab_strip.config_dir = .empty;

    commit_filter.deinit(gpa);
    commit_summary.deinit(gpa);
    commit_description.deinit(gpa);
    commit_scope.deinit(gpa);
    commit_scope = .empty;
    commit_template.deinit(gpa);
    commit_template = .empty;
    commit_view.clearCoAuthors();
    co_authors.deinit(gpa);
    co_authors = .empty;
    commit_prefs = .{};
    commit_type = null;
    template_due = true;
    selected_path.deinit(gpa);
    prompt_text.deinit(gpa);
    rebase_steps.deinit(gpa);
    palette_text.deinit(gpa);
    palette_text = .empty;
    dialog_views.branch_filter.deinit(gpa);
    dialog_views.branch_filter = .empty;
    window_chrome.switch_filter.deinit(gpa);
    window_chrome.switch_filter = .empty;
    graph_view.author_filter.deinit(gpa);
    graph_view.author_filter = .empty;
    graph_view.clearNames(&graph_view.author_only);
    graph_view.author_only.deinit(gpa);
    graph_view.author_only = .empty;
    freeViews();
    rebase_view.sidebar_filter.deinit(gpa);
    tab_strip.default_branch.deinit(gpa);
    tab_strip.default_branch = .empty;
    tab_strip.editor_cmd.deinit(gpa);
    tab_strip.editor_cmd = .empty;
    tab_strip.terminal_cmd.deinit(gpa);
    tab_strip.terminal_cmd = .empty;
    diff_view.clearImagePair();
    signing_key.deinit(gpa);
    signing_key = .empty;
    signing_loaded = false;
    if (repo_prefs_job) |j| j.deinit(app_io);
    repo_prefs_job = null;
    repo_prefs_loaded = false;
    repo_name_local.deinit(gpa);
    repo_name_local = .empty;
    repo_email_local.deinit(gpa);
    repo_email_local = .empty;
    repo_settings_path.deinit(gpa);
    repo_settings_path = .empty;
    if (editors_job) |j| j.deinit(app_io);
    editors_job = null;
    editors_loaded = false;
    if (signing_job) |j| j.deinit(app_io);
    signing_job = null;
    if (commit_view.repo_config_job) |j| j.deinit(app_io);
    commit_view.repo_config_job = null;
    commit_view.git_template_path.deinit(gpa);
    commit_view.git_template_path = .empty;
    commit_sent.deinit(gpa);
    commit_sent = .empty;
    job_after = .remote;
    action_after = .remote;
    rebase_view.sidebar_filter = .empty;

    tab_strip.clearRecent();
    tab_strip.recent.deinit(gpa);
    tab_strip.recent = .empty;
    pick_open = null;
    clearJobSteps();
    job_steps.deinit(gpa);
    job_steps = .empty;
    pr_cards_all = null;
    conflict_focus = 0;
    dialog_views.clearForget();
    identity_name.deinit(gpa);
    identity_name = .empty;
    identity_email.deinit(gpa);
    identity_email = .empty;
    identity_open = false;
    window_chrome.forgetMe();
    graph_view.clearDrop();
    graph_view.drag_source.deinit(gpa);
    graph_view.drag_source = .empty;
    for ([_]*std.ArrayList(u8){ &dialog_views.dialog_url, &dialog_views.dialog_parent, &dialog_views.dialog_name, &dialog_views.dialog_branch }) |list| {
        list.deinit(gpa);
        list.* = .empty;
    }
    dialog_views.repo_dialog = .none;
    picked_lines.deinit(gpa);
    picked_lines = .empty;
    pr_comment.deinit(gpa);
    clearPrEdit();
    clearPrCreate();
    pr_search.deinit(gpa);
    pr_search = .empty;
    pr_filter = .open;
    pr_comment = .empty;
    pr_reply.deinit(gpa);
    pr_reply = .empty;
    pr_reply_id.deinit(gpa);
    pr_reply_id = .empty;
    pr_threads_all = false;
    pr_applied_n = 0;
    pr_applied_for = 0;
    pr_scroll_thread = false;
    pr_selected = null;
    diff_view.split_rows.deinit(gpa);
    diff_view.split_rows = .empty;
    palette_open = false;
    graph_view.clearFileHistory();
    graph_view.file_history.deinit(gpa);
    clone_dest.deinit(gpa);

    graph_view.file_history = .empty;
    clone_dest = .empty;
    commit_filter = .empty;
    commit_summary = .empty;
    commit_description = .empty;
    selected_path = .empty;
    prompt_text = .empty;
    rebase_steps = .empty;
}

/// Drop the strip without freeing the list itself, which is what a restart does
/// to it — the file on disk is the only thing that survives one.
fn forgetTabs() void {
    for (tab_strip.groups.items) |*group| group.deinit();
    tab_strip.groups.clearRetainingCapacity();
    tab_strip.freeWorkspaces();
    tab_strip.clearRecent();
    tab_strip.active_group = 0;
    tab_strip.active_tab = 0;
}

fn findCommit(summary: []const u8) ?git.Commit {
    const h = history orelse return null;
    for (h.commits) |commit| {
        if (std.mem.eql(u8, commit.summary, summary)) return commit;
    }
    return null;
}

fn findRef(name: []const u8) ?git.Ref {
    const h = history orelse return null;
    for (h.refs) |ref| {
        if (std.mem.eql(u8, ref.name, name)) return ref;
    }
    return null;
}

fn expectGit(dir: []const u8, args: []const []const u8) !void {
    var outcome = try run.git(std.testing.allocator, app_io, dir, args);
    defer outcome.deinit(std.testing.allocator);
    if (!outcome.ok) {
        std.debug.print("git {s} failed: {s}\n", .{ args[0], outcome.message });
        return error.GitFailed;
    }
}

fn expectRun(argv: []const []const u8) !void {
    const answer = try run.capture(std.testing.allocator, app_io, ".", argv);
    std.testing.allocator.free(answer.out);
    if (!answer.ok) return error.CommandFailed;
}

/// A repository with one commit and an identity of its own, so a test does not
/// depend on the git config of whoever is running it.
fn makeTestRepo(tmp: *std.testing.TmpDir, dir: []const u8, path: []const u8, data: []const u8) !void {
    try expectGit(dir, &.{ "init", "-q", "-b", "main" });
    try expectGit(dir, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(dir, &.{ "config", "user.name", "Zit Test" });
    // Unsigned: the machine running this may sign every commit, and a GPG
    // passphrase prompt per test repo is not a test suite.
    try expectGit(dir, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(dir, &.{ "config", "tag.gpgsign", "false" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = path, .data = data });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "base" });
}

test "files touched without being changed are hashed once, and the repository's index is never written" {
    app_io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var copy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const copy = try std.fmt.bufPrint(&copy_buf, ".zig-cache/tmp/{s}/index", .{scratch.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "two more" });

    // Touched: the same bytes, another time — 2001, well before the index.
    const touched: std.Io.Timestamp = .{ .nanoseconds = 978_307_200 * std.time.ns_per_s };
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        var f = try tmp.dir.openFile(app_io, name, .{ .mode = .read_write });
        defer f.close(app_io);
        try f.setTimestamps(app_io, .{ .access_timestamp = .{ .new = touched }, .modify_timestamp = .{ .new = touched } });
    }
    const index_before = try tmp.dir.readFileAlloc(app_io, ".git/index", a, .unlimited);
    defer a.free(index_before);
    const stat_before = try tmp.dir.statFile(app_io, ".git/index", .{});

    var cache = try git.StatusCache.open(a, dir, copy);
    defer cache.deinit(a, app_io);

    // The first read hashes the three to find them unchanged; the next,
    // none: their new stats are in the copy.
    var first = try cache.readWork(a, app_io);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.unstaged.len);
    try std.testing.expectEqual(@as(usize, 3), first.hashed);
    var second = try cache.readWork(a, app_io);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), second.unstaged.len);
    try std.testing.expectEqual(@as(usize, 0), second.hashed);

    // The repository's own index is as it was — so a plain read still
    // hashes them all.
    const index_after = try tmp.dir.readFileAlloc(app_io, ".git/index", a, .unlimited);
    defer a.free(index_after);
    try std.testing.expectEqualSlices(u8, index_before, index_after);
    try std.testing.expectEqual(stat_before.mtime.nanoseconds, (try tmp.dir.statFile(app_io, ".git/index", .{})).mtime.nanoseconds);
    var r = try git.Repo.open(dir);
    defer r.deinit();
    var plain = try r.readWork(a);
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 3), plain.hashed);

    // A change is still one.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b, edited\n" });
    var edited = try cache.readWork(a, app_io);
    defer edited.deinit();
    try std.testing.expectEqual(@as(usize, 1), edited.unstaged.len);
    try std.testing.expectEqualStrings("b.txt", edited.unstaged[0].path);

    // The repository's index rewritten by git: the copy taken again.
    try expectGit(dir, &.{ "add", "b.txt" });
    var staged = try cache.readWork(a, app_io);
    defer staged.deinit();
    try std.testing.expectEqual(@as(usize, 1), staged.staged.len);
    try std.testing.expectEqual(@as(usize, 0), staged.unstaged.len);
}

// Twelve lines, edited at both ends: far enough apart that git's three lines of
// context do not run the two edits together into one hunk.
const TWELVE_LINES = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";
const TWELVE_EDITED = "one\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\ntwelve\n";
/// What `makeConflictedPair` leaves on main, and so what "keep ours" means.
const TWELVE_LINES_MAIN = "main\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";

// Hunk staging, end to end, against a real repository.
//
// The patch is rebuilt by hand and fed to `git apply` on stdin, so nothing here
// is checked by the compiler: a wrong flag, a dropped header line or a reversed
// direction all produce a patch that builds fine and stages the wrong thing.
test "staging one hunk moves that hunk and leaves the other alone" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app_io, .{ .sub_path = "lines.txt", .data = TWELVE_EDITED });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    const r = repo orelse return error.RepoNotOpen;

    {
        var unstaged = try r.readWorkDiff(gpa, .unstaged, "lines.txt");
        defer unstaged.deinit();
        try std.testing.expectEqual(@as(usize, 1), unstaged.files.len);
        try std.testing.expectEqual(@as(u32, 2), unstaged.files[0].hunk_count);

        rebase_view.requestHunk(unstaged.files[0], 0, .unstaged);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    {
        // One hunk on each side: the one that was staged, and the one that was
        // left behind. Either count being 2 means the patch carried both.
        var staged = try r.readWorkDiff(gpa, .staged, "lines.txt");
        defer staged.deinit();
        try std.testing.expectEqual(@as(usize, 1), staged.files.len);
        try std.testing.expectEqual(@as(u32, 1), staged.files[0].hunk_count);

        var rest = try r.readWorkDiff(gpa, .unstaged, "lines.txt");
        defer rest.deinit();
        try std.testing.expectEqual(@as(usize, 1), rest.files.len);
        try std.testing.expectEqual(@as(u32, 1), rest.files[0].hunk_count);

        // And back out again. The reverse apply is a different command, and
        // getting its direction wrong stages more rather than less.
        rebase_view.requestHunk(staged.files[0], 0, .staged);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    var empty = try r.readWorkDiff(gpa, .staged, "lines.txt");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.files.len);
}

// Rows are positioned by hand inside a scroll area and share widget ids with
// the graph: the kind of thing that builds fine and panics on frame one.
test "the diff pane renders both a file diff and a commit diff" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    try style.applyEmbedded(gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app_io, .{ .sub_path = "lines.txt", .data = TWELVE_EDITED });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    selectChange("lines.txt", .unstaged);
    try dvui.testing.settle(appFrame);
    // The pane found its file rather than clearing the selection and falling
    // back to the graph.
    try std.testing.expectEqual(@as(usize, 1), diff.?.files.len);

    selectCommit(history.?.commits[0].id);
    try dvui.testing.settle(appFrame);
    try std.testing.expectEqual(@as(usize, 1), diff.?.files.len);

    // Closing it puts the graph back.
    clearSelection();
    try dvui.testing.settle(appFrame);
    try std.testing.expectEqual(@as(?git.Diff, null), diff);
}

test "the pull requests open in their tab, and Ctrl+W leaves it, not the repository" {
    defer active_view = .graph;
    openPulls();
    try std.testing.expect(active_view == .pulls);
    closeShownTab();
    try std.testing.expect(active_view == .graph);
}

test "branches are ticked to show alone one by one, and unticked the same way" {
    gpa = std.testing.allocator;
    defer resetUiGlobals();
    graph_view.toggleOnly("a");
    graph_view.toggleOnly("b");
    try std.testing.expectEqual(@as(usize, 2), graph_view.graph_only.items.len);
    graph_view.toggleOnly("a");
    try std.testing.expectEqual(@as(usize, 1), graph_view.graph_only.items.len);
    try std.testing.expectEqualStrings("b", graph_view.graph_only.items[0]);
    graph_view.setSolo(null);
    try std.testing.expectEqual(@as(usize, 0), graph_view.graph_only.items.len);
}

test "the zoom steps a tenth at a time, within its bounds, and Ctrl+0 or the status bar puts it back" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try expectNoTag("status:zoom");

    try pressFrame(.equal, .lcontrol);
    try pressFrame(.kp_add, .lcontrol);
    try std.testing.expectEqual(@as(f32, 1.2), tab_strip.zoom);
    try std.testing.expectEqual(@as(f32, 1.2), dvui.currentWindow().content_scale);
    // Held at the top, whatever is pressed past it.
    for (0..12) |_| try pressFrame(.equal, .lcontrol);
    try std.testing.expectEqual(tab_strip.ZOOM_MAX, tab_strip.zoom);
    try pressFrame(.zero, .lcontrol);
    try std.testing.expectEqual(@as(f32, 1.0), tab_strip.zoom);
    for (0..6) |_| try pressFrame(.minus, .lcontrol);
    try std.testing.expectEqual(tab_strip.ZOOM_MIN, tab_strip.zoom);

    // Off 100 %, the status bar says so, and its click comes back.
    try clickAt(try tagCenter("status:zoom"));
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(f32, 1.0), tab_strip.zoom);
    try expectNoTag("status:zoom");
    // A file edited by hand.
    try std.testing.expectEqual(@as(f32, 1.0), tab_strip.zoomStep(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1.3), tab_strip.zoomStep(1.27));
}

test "down and up walk the history, and the commit pane follows" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(gpa, true);
    try git.init();
    defer git.shutdown();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "three" });
    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    selectCommit(history.?.commits[0].id);
    try dvui.testing.settle(frameArrowCursor);
    try pressFrame(.down, .none);
    try std.testing.expect(git.oidEql(selection.commit, history.?.commits[1].id));
    try pressFrame(.down, .none);
    try std.testing.expect(git.oidEql(selection.commit, history.?.commits[2].id));
    try pressFrame(.up, .none);
    try std.testing.expect(git.oidEql(selection.commit, history.?.commits[1].id));
    // Rewritten under the selection, as a rebase or an amend does: the pane
    // goes back to the working tree rather than a commit with no message.
    selectCommit(history.?.commits[0].id);
    try expectGit(dir, &.{ "commit", "-q", "--amend", "--allow-empty", "-m", "three, again" });
    reloadHistory();
    try std.testing.expect(selection == .none);
}

test "a body's trailers come apart from its text, co-authors among them" {
    const body = "Fixes the race.\n\nMore words.\n\nCo-authored-by: Ann Lee <ann@x.invalid>\nSigned-off-by: Bo <bo@x.invalid>";
    const split = commit_view.splitTrailers(body);
    try std.testing.expectEqualStrings("Fixes the race.\n\nMore words.", split.text);
    var it = commit_view.trailerLines(split.trailers);
    const first = it.next().?;
    try std.testing.expectEqualStrings("Co-authored-by", first.key);
    try std.testing.expectEqualStrings("Ann Lee <ann@x.invalid>", first.value);
    try std.testing.expectEqualStrings("Signed-off-by", it.next().?.key);
    try std.testing.expect(it.next() == null);
    // No trailer block: all text.
    try std.testing.expectEqualStrings("Just a line: with a colon in it", commit_view.splitTrailers("Just a line: with a colon in it").text);
}

test "the sidebar filter keeps the names that contain it, whatever their case" {
    gpa = std.testing.allocator;
    defer resetUiGlobals();
    try std.testing.expect(rebase_view.sidebarMatches("feat/alpha"));
    try rebase_view.sidebar_filter.appendSlice(gpa, " ALP ");
    try std.testing.expect(rebase_view.sidebarFiltering());
    try std.testing.expect(rebase_view.sidebarMatches("feat/alpha"));
    try std.testing.expect(rebase_view.sidebarMatches("origin/feat/Alpha"));
    try std.testing.expect(!rebase_view.sidebarMatches("feat/beta"));
}

test "a narrow list gives up the sha, then the author, before the message" {
    defer graph_scroll.viewport.w = 0;
    graph_scroll.viewport.w = 2000;
    try std.testing.expect(graph_view.columnsShown().sha and graph_view.columnsShown().author);
    // Room for the message only once the sha is gone.
    graph_scroll.viewport.w = 2 * style.space.lg + search_view.graphLead() + graph_view.col_time + graph_view.col_author + 2 * style.space.md + graph_view.MESSAGE_MIN + 10;
    try std.testing.expect(!graph_view.columnsShown().sha and graph_view.columnsShown().author);
    graph_scroll.viewport.w = 400;
    try std.testing.expect(!graph_view.columnsShown().sha and !graph_view.columnsShown().author);

    // And a frame that narrow still draws.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(gpa, true);
    try git.init();
    defer git.shutdown();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    try dvui.testing.settle(frameArrowCursor);

    // The pull requests' tab beside the repository's draws too.
    openPulls();
    try dvui.testing.settle(frameArrowCursor);
    closePulls();

    // The floating search closes from its ×, over the rows.
    graph_view.search_open = true;
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("search:close"));
    try std.testing.expect(!graph_view.search_open);
}

test "the branches panel comes back once the changes panel that pushed it out is hidden" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    defer show_detail = true;

    try style.applyEmbedded(gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // As the changes panel leaves it when dragged wide, then Ctrl+J.
    left_squeezed = true;
    show_detail = false;
    try dvui.testing.settle(appFrame);
    try std.testing.expect(!left_squeezed);
    try std.testing.expect(leftShown());
}

// The filtered list numbers its own rows on top of a virtualised scroll: easy
// to render beautifully and show the wrong commit.
test "searching the history narrows the list to what matches" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    try style.applyEmbedded(gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "teach the parser about tabs" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    const commits = history.?.commits;
    try std.testing.expectEqual(@as(usize, 2), commits.len);

    // Nothing typed: the whole history.
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(matchesNow(commits[1]));

    // The message, case-insensitively.
    try commit_filter.appendSlice(gpa, "PARSER");
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(!matchesNow(commits[1]));

    // The author, which is the other thing people have in hand.
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "zit test");
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(matchesNow(commits[1]));

    // And the start of a sha.
    var sha: [8]u8 = undefined;
    const short = git.oidShort(commits[1].id, &sha);
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, short[0..4]);
    try std.testing.expect(matchesNow(commits[1]));

    // The filtered pane renders: its rows are numbered by position in the
    // results, not by position in the history.
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "tabs");
    try dvui.testing.settle(appFrame);

    // A search that finds nothing still leaves the box on screen to clear.
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "nothing here matches this");
    try dvui.testing.settle(appFrame);
}

/// A repository stopped in the middle of a conflicted merge: two branches that
/// rewrite the same line, which is the cheapest conflict there is. The merge
/// itself is left to the caller, because it goes through `gitDo`.
fn makeConflictedPair(tmp: *std.testing.TmpDir, dir: []const u8) !void {
    try makeTestRepo(tmp, dir, "lines.txt", TWELVE_LINES);

    try expectGit(dir, &.{ "switch", "-qc", "other" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "lines.txt", .data = "other\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" });
    try expectGit(dir, &.{ "commit", "-qam", "other side" });

    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "lines.txt", .data = "main\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" });
    try expectGit(dir, &.{ "commit", "-qam", "main side" });
}

// The continue button sends `-c core.editor=true`, and that flag is the whole
// reason this test is worth its runtime: without it `git merge --continue`
// opens an editor, and `run.git` blocks the UI thread until something closes
// it — a frozen window with no way back. A test that hangs here has found it.
test "a conflicted merge is resolved and continued" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // Expected to stop. A conflicted merge does not move HEAD, so this also
    // covers `gitDo` re-reading the history on its failure path — without that
    // the toolbar never says it is under way. A stop is not an error: no red line,
    // and the conflicted file is open.
    gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(selection == .change);
    try std.testing.expectEqualStrings("lines.txt", selected_path.items);
    try std.testing.expectEqual(git.State.merge, history.?.state);
    try std.testing.expect(dialog_views.conflictCount() > 0);

    // Resolve it the way a person would, then stage the result.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "lines.txt", .data = TWELVE_LINES });
    gitDo(&.{ "add", "--", "lines.txt" });
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());

    const cmd = history.?.state.command() orelse return error.NoCommandForState;
    gitDo(&.{ "-c", "core.editor=true", cmd, "--continue" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, history.?.state);

    // The merge commit is there, with both sides under it.
    try std.testing.expectEqual(@as(usize, 2), history.?.commits[0].parents.len);
}

// The other half of the toolbar's controls. It also pins the libgit2 state
// mapping: a state that came back as `.other` has no `command()`, so they would offer
// nothing and leave the repository stuck mid-merge.
test "a conflicted merge aborts back to a clean tree" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, history.?.state);

    const cmd = history.?.state.command() orelse return error.NoCommandForState;
    gitDo(&.{ cmd, "--abort" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, history.?.state);
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());
    try std.testing.expectEqual(@as(usize, 0), work.?.unstaged.len);
}

// A merge under way, from the toolbar's end as a person goes at it: Resolve
// opens the conflicted file, Abort asks in a toast — Esc lets it be, its
// button does it.
test "a merge under way is driven from the toolbar, its abort asked in a toast" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    defer clearConfirm();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try expectNoTag("op:abort");

    gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, history.?.state);
    try dvui.testing.settle(frameArrowCursor);
    clearSelection();
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("op:resolve"));
    try std.testing.expect(viewingConflict());

    try clickAt(try tagCenter("op:abort"));
    try std.testing.expectEqual(Confirm.Kind.abort_operation, confirm.?.kind);
    _ = try tagRect("confirm:yes");
    try pressFrame(.escape, .none);
    try std.testing.expect(confirm == null);
    try expectNoTag("confirm:yes");
    try std.testing.expectEqual(git.State.merge, history.?.state);

    try clickAt(try tagCenter("op:abort"));
    try clickAt(try tagCenter("confirm:yes"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, history.?.state);
    try expectNoTag("op:abort");
}

// What could quietly break a merge in the middle of resolving it: staging a
// file with its markers still in, an undo that resets under the merge, an
// abort that throws the resolutions away. Each is asked first, or refused.
test "mid-merge, staging markers and aborting are asked first, and undo is refused" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    defer clearConfirm();

    gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, history.?.state);

    // The file still has its markers: staging it, alone or with everything,
    // waits for a yes.
    commit_view.requestStage("lines.txt", "lines.txt", true);
    try std.testing.expect(confirm != null and confirm.?.kind == .stage_markers);
    try std.testing.expect(dialog_views.conflictCount() > 0);
    clearConfirm();
    commit_view.requestStageAll();
    try std.testing.expect(confirm != null and confirm.?.kind == .stage_markers);
    try std.testing.expectEqualStrings("", confirm.?.arg);
    clearConfirm();

    // Undo would reset under the merge.
    requestUndo();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(@as(Action, .none), action);
    try std.testing.expectEqual(git.State.merge, history.?.state);
    clearCommandError();

    // Abort: asked, then done.
    requestAbortOperation();
    try std.testing.expect(confirm != null and confirm.?.kind == .abort_operation);
    try std.testing.expectEqual(git.State.merge, history.?.state);
    runConfirmed();
    _ = runAction();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, history.?.state);
}

// "Open this file" sends the user to an editor; a pick made afterwards from
// the copy read before must not write over what they did there.
test "a pick refuses to write over a file changed since it was shown" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "merge", "--no-edit", "other" });
    selectChange("lines.txt", .unstaged);
    loadConflicts();
    try std.testing.expect(conflicts.len > 0);

    const edited = "edited elsewhere\n";
    try tmp.dir.writeFile(app_io, .{ .sub_path = "lines.txt", .data = edited });
    requestResolve(0, .ours);
    _ = runAction();
    try std.testing.expect(tab_strip.command_error != null);

    const now = try tmp.dir.readFileAlloc(app_io, "lines.txt", gpa, .limited(1024));
    defer gpa.free(now);
    try std.testing.expectEqualStrings(edited, now);
}

// A rebase git refuses to start — here, over uncommitted changes — leaves
// the composed plan on screen, to run again once the tree is clean.
test "a refused interactive rebase keeps its plan" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    const second = findCommit("second") orelse return error.CommitNotFound;
    beginRebase(second.parents[0]);
    try std.testing.expectEqual(@as(usize, 1), rebase_steps.items.len);

    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    rebase_steps.items[0].action = .drop;
    runRebase();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(git.State.none, history.?.state);
    try std.testing.expect(selection == .rebase);
    try std.testing.expectEqual(@as(usize, 1), rebase_steps.items.len);
    // git copied its list; Zit's own is gone either way.
    var todo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const todo = try std.fmt.bufPrint(&todo_buf, "{s}zit-rebase-todo", .{repo.?.gitdir()});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(app_io, todo, .{}));
}

// The strip reads what git keeps for a rebase: the branch, where it goes,
// the step it stopped on and its commit — and the conflict's sides by name,
// "ours" being the base there. Continue goes on from it once resolved.
test "a rebase stopped on a conflict says where it is, and continues" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "f.txt", "base\n");
    try expectGit(dir, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "feat\n" });
    try expectGit(dir, &.{ "commit", "-qam", "feat changes f" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "g.txt", .data = "g\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "feat adds g" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "main\n" });
    try expectGit(dir, &.{ "commit", "-qam", "main changes f" });
    try expectGit(dir, &.{ "switch", "-q", "feat" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "rebase", "main" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.rebase, history.?.state);
    try std.testing.expectEqualStrings("feat", rebase_view.op_info.branch);
    try std.testing.expectEqualStrings("main", rebase_view.op_info.onto);
    try std.testing.expectEqual(@as(u32, 1), rebase_view.op_info.step);
    try std.testing.expectEqual(@as(u32, 2), rebase_view.op_info.total);
    try std.testing.expectEqualStrings("feat changes f", rebase_view.op_info.subject);
    var title_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Rebasing feat onto main", opTitle(&title_buf));
    try std.testing.expectEqualStrings("main", rebase_view.sideNames().ours);
    try std.testing.expectEqualStrings("feat", rebase_view.sideNames().theirs);
    try std.testing.expect(std.mem.indexOf(u8, rebase_view.sideNames().theirs_role, rebase_view.op_info.commit) != null);
    try std.testing.expect(opNext() == .resolve);
    try std.testing.expect(!canContinue());

    // Answered and staged: Continue, which replays the second commit too.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "both\n" });
    gitDo(&.{ "add", "--", "f.txt" });
    try std.testing.expect(opNext() == .proceed);
    try std.testing.expect(canContinue());
    requestContinue();
    _ = runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, history.?.state);
    try std.testing.expectEqualStrings("feat adds g", history.?.commits[0].summary);
    try std.testing.expectEqualStrings("feat changes f", history.?.commits[1].summary);
    try std.testing.expectEqualStrings("main changes f", history.?.commits[2].summary);
}

// Resolved to what the base already had, a commit is left with nothing to
// apply: git refuses to continue with it, and the strip offers Skip instead.
test "a rebase step left empty by its resolution is skipped, not continued" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "f.txt", "base\n");
    try expectGit(dir, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "feat\n" });
    try expectGit(dir, &.{ "commit", "-qam", "feat changes f" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "main\n" });
    try expectGit(dir, &.{ "commit", "-qam", "main changes f" });
    try expectGit(dir, &.{ "switch", "-q", "feat" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "rebase", "main" });
    try std.testing.expectEqual(git.State.rebase, history.?.state);
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "main\n" });
    gitDo(&.{ "add", "--", "f.txt" });
    try std.testing.expect(opNext() == .skip);
    try std.testing.expect(!canContinue());
}

// After a rebase the branch and its upstream have parted ways: Push turns
// into a force push, which says what it replaces.
/// A bare remote and a clone of it, the clone's `main` pushed: for the
/// pull request flows, which fetch and push.
fn makeRemotePair(tmp: *std.testing.TmpDir, root: []const u8, up: []const u8, down: []const u8) !void {
    try expectGit(root, &.{ "init", "-q", "--bare", "-b", "main", "up.git" });
    try tmp.dir.createDirPath(app_io, "down");
    try makeTestRepo(tmp, down, "down/f.txt", "base\n");
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "main" });
}

// Checking a request out as `gh pr checkout` does: a branch that tracks the
// remote's, made — or switched to and fast-forwarded when it is behind —
// and a fork's request on `pr/N`, never on a branch of yours of its name.
test "a pull request is checked out tracking its branch, brought up to date, and a fork's apart" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up.git", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeRemotePair(&tmp, root, up, down);
    try expectGit(down, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "down/g.txt", .data = "one\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "feat one" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "down/g.txt", .data = "two\n" });
    try expectGit(down, &.{ "commit", "-qam", "feat two" });
    try expectGit(down, &.{ "push", "-q", "origin", "feat" });
    // The request as a fork would send it: only under refs/pull.
    try expectGit(up, &.{ "update-ref", "refs/pull/7/head", "refs/heads/feat" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    try expectGit(down, &.{ "branch", "-qD", "feat" });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // Not here yet: made, tracking the remote's.
    checkoutRequest(3, "feat", false);
    _ = runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("feat", history.?.head.?);
    try std.testing.expectEqualStrings("origin/feat", history.?.tracking.upstream.?);

    // Here but behind: switched to, and brought up to date.
    try expectGit(down, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    reloadHistory();
    checkoutRequest(3, "feat", false);
    _ = runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("feat", history.?.head.?);
    try std.testing.expectEqualStrings("feat two", history.?.commits[0].summary);

    // From a fork, its branch named "main": on pr/7, and main left alone.
    try expectGit(down, &.{ "switch", "-q", "main" });
    reloadHistory();
    checkoutRequest(7, "main", true);
    _ = runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("pr/7", history.?.head.?);
    try std.testing.expectEqualStrings("feat two", history.?.commits[0].summary);
    try std.testing.expect(isLocalBranch("main"));
}

// A request in conflict with its base, rebased onto it here: fetched,
// checked out, rebased — stopping at the conflict, in the conflict view,
// with the bar to go on from.
test "a pull request in conflict is rebased onto its base here, stopping at the conflict" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up.git", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeRemotePair(&tmp, root, up, down);
    try expectGit(down, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "down/f.txt", .data = "feat\n" });
    try expectGit(down, &.{ "commit", "-qam", "feat changes f" });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "feat" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "down/f.txt", .data = "main\n" });
    try expectGit(down, &.{ "commit", "-qam", "main changes f" });
    try expectGit(down, &.{ "push", "-q", "origin", "main" });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    resolveRequestLocally(.{ .number = 3, .head = "feat", .base = "main", .mergeable = "CONFLICTING" }, true);
    _ = runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.rebase, history.?.state);
    try std.testing.expect(dialog_views.conflictCount() > 0);
    try std.testing.expectEqualStrings("feat", rebase_view.op_info.branch);
    try std.testing.expectEqualStrings("f.txt", selected_path.items);
}

test "after a rebase, Push is a force push that says what it replaces" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up.git", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();

    try expectGit(root, &.{ "init", "-q", "--bare", "-b", "main", "up.git" });
    try tmp.dir.createDirPath(app_io, "down");
    try makeTestRepo(&tmp, down, "down/a.txt", "a\n");
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "main" });
    try expectGit(down, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "down/f.txt", .data = "f\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "feat" });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "feat" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "down/b.txt", .data = "b\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "main moves" });
    try expectGit(down, &.{ "switch", "-q", "feat" });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    try std.testing.expect(!window_chrome.rebasedSinceUpstream());

    gitDo(&.{ "rebase", "main" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(window_chrome.rebasedSinceUpstream());
    var buf: [512]u8 = undefined;
    const text = dialog_views.forcePushText(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "origin/feat") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 commit there") != null);
}

// The conflict view driven by the keys alone, as GitComet's is: 2 keeps the
// right side, U takes it back, 1 keeps the left, Enter stages the file.
test "a conflicted file is answered from the keys: a pick, its undo, Enter to stage" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(gpa, true);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "merge", "--no-edit", "other" });
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(rebase_view.isConflictView());
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);

    try pressFrame(.two, .none);
    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
    try std.testing.expectEqual(@as(usize, 1), resolve_undo.items.len);
    {
        const now = try tmp.dir.readFileAlloc(app_io, "lines.txt", gpa, .limited(4096));
        defer gpa.free(now);
        try std.testing.expect(std.mem.startsWith(u8, now, "other"));
    }

    try pressFrame(.u, .none);
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqual(@as(usize, 0), resolve_undo.items.len);

    try pressFrame(.one, .none);
    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
    try pressFrame(.enter, .none);
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());
    try std.testing.expectEqual(git.State.merge, history.?.state);
    const now = try tmp.dir.readFileAlloc(app_io, "lines.txt", gpa, .limited(4096));
    defer gpa.free(now);
    try std.testing.expect(std.mem.startsWith(u8, now, "main"));
}

// git wrote plain markers, as it does by default: the base comes from the
// index, and a conflict where each side changed different lines resolves
// in one click, each line from the side that changed it.
test "a conflict of changes on neighbouring lines is resolved safely, with its base" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "n.txt", "a = 1\nb = 2\nc = 3\n");
    try expectGit(dir, &.{ "switch", "-qc", "other" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "n.txt", .data = "a = 1\nb = 20\nc = 3\n" });
    try expectGit(dir, &.{ "commit", "-qam", "b" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "n.txt", .data = "a = 10\nb = 2\nc = 30\n" });
    try expectGit(dir, &.{ "commit", "-qam", "a and c" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "-c", "merge.conflictStyle=merge", "merge", "--no-edit", "other" });
    try std.testing.expectEqualStrings("n.txt", selected_path.items);
    loadConflicts();
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expect(conflicts[0].has_base);
    try std.testing.expect(git.sameText("a = 1\nb = 2\nc = 3\n", conflicts[0].base));
    try std.testing.expectEqual(@as(?git.AutoReason, .lines_apart), conflict_autos[0]);

    requestAction(.resolve_safe);
    _ = runAction();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    const now = try tmp.dir.readFileAlloc(app_io, "n.txt", gpa, .limited(4096));
    defer gpa.free(now);
    try std.testing.expect(git.sameText("a = 10\nb = 20\nc = 30\n", now));
}

// A file one side deleted and the other changed: no regions, a question —
// keep it or let it go — answered and staged in one click.
test "a file deleted on one side is kept or deleted in one click" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "notes.txt", "notes\n");
    try expectGit(dir, &.{ "switch", "-qc", "other" });
    try expectGit(dir, &.{ "rm", "-q", "notes.txt" });
    try expectGit(dir, &.{ "commit", "-qm", "no notes" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "notes.txt", .data = "notes, edited\n" });
    try expectGit(dir, &.{ "commit", "-qam", "edited notes" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqualStrings("notes.txt", selected_path.items);
    loadConflicts();
    try std.testing.expectEqual(git.ConflictKind.deleted_by_them, conflict_kind);
    try std.testing.expect(wholeFileConflict());

    // "Delete it": the side that deleted it.
    rebase_view.takeFile(.theirs);
    _ = runAction();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(app_io, "notes.txt", .{}));
}

test "a review written for one pull request is not carried to another" {
    gpa = std.testing.allocator;
    defer pr_comment.clearAndFree(gpa);
    defer pr_selected = null;
    pr_selected = 5;
    try pr_comment.appendSlice(gpa, "looks good");
    selectRequest(5);
    try std.testing.expectEqualStrings("looks good", pr_comment.items);
    selectRequest(7);
    try std.testing.expectEqual(@as(usize, 0), pr_comment.items.len);
}

// The parser is unit-tested in `git.zig`; what this covers is the rest of the
// loop — reading the file git left behind, writing the chosen side back, and
// git agreeing afterwards that there is nothing left to resolve.
test "a conflict is resolved region by region, then staged" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, history.?.state);

    selectChange("lines.txt", .unstaged);
    ensureDiff();
    try std.testing.expect(rebase_view.isConflictView());
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqualStrings("main\n", conflicts[0].ours);
    try std.testing.expectEqualStrings("other\n", conflicts[0].theirs);

    requestResolve(0, .ours);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    // Our side is what landed, and no marker survived it.
    const resolved = try tmp.dir.readFileAlloc(app_io, "lines.txt", gpa, .limited(64 * 1024));
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings(TWELVE_LINES_MAIN, resolved);

    diff_stale = true;
    ensureDiff();
    try std.testing.expectEqual(@as(usize, 0), conflicts.len);

    // Staging is what tells git the conflict is over; until then it is still
    // mid-merge no matter how clean the file looks.
    gitDo(&.{ "add", "--", "lines.txt" });
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());

    gitDo(&.{ "-c", "core.editor=true", "merge", "--continue" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, history.?.state);
}

// The mechanism is a config trick — `sequence.editor=cp <our todo>` — and
// nothing about it is checked by the compiler. If git ignored it, or the todo
// were written in the wrong order, the rebase would still "succeed" and quietly
// do something other than what was composed.
test "an interactive rebase folds one commit into the one before it" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "third" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    try std.testing.expectEqual(@as(usize, 3), history.?.commits.len);

    // Starting at "second" means "second" and "third" are both replayed, so the
    // list is composed from its parent.
    const second = findCommit("second") orelse return error.CommitNotFound;
    beginRebase(if (second.parents.len > 0) second.parents[0] else null);
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 2), rebase_steps.items.len);

    // Newest first, the order the graph shows — the todo gets reversed.
    try std.testing.expectEqualStrings("third", rebase_steps.items[0].summary);
    try std.testing.expectEqualStrings("second", rebase_steps.items[1].summary);

    rebase_steps.items[0].action = .fixup;
    runRebase();

    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, history.?.state);
    try std.testing.expectEqual(@as(usize, 2), history.?.commits.len);
    try std.testing.expectEqualStrings("second", history.?.commits[0].summary);

    // Folded, not dropped: the surviving commit carries what "third" added.
    var folded = try repo.?.readCommitDiff(gpa, history.?.commits[0].id);
    defer folded.deinit();
    try std.testing.expect(folded.find("b.txt") != null);
    try std.testing.expect(folded.find("c.txt") != null);

    // Composing is over once it runs.
    try std.testing.expectEqual(@as(usize, 0), rebase_steps.items.len);
}

test "a rebase onto a commit off the current branch is refused, not attempted" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // "other side" is on the other branch: walking first parents from HEAD
    // never reaches it, and replaying onto it is a different operation.
    const other = findCommit("other side") orelse return error.CommitNotFound;
    beginRebase(other.id);

    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(@as(usize, 0), rebase_steps.items.len);
    try std.testing.expectEqual(Selection.none, std.meta.activeTag(selection));

    // A merge in the range: git would stop on its `pick`, so the list is
    // never composed.
    try expectGit(dir, &.{ "merge", "-q", "-s", "ours", "-m", "merged", "other" });
    graph_view.refreshHistory();
    clearCommandError();
    const main_side = findCommit("main side") orelse return error.CommitNotFound;
    beginRebase(main_side.parents[0]);
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(@as(usize, 0), rebase_steps.items.len);
    try std.testing.expectEqual(Selection.none, std.meta.activeTag(selection));
}

test "a branch named like a tag merges the branch, not the tag" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "tag", "v1" });
    try expectGit(dir, &.{ "switch", "-q", "-c", "v1" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on the branch" });
    try expectGit(dir, &.{ "switch", "-q", "main" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // Bare where nothing else shares the name, so merge messages read as usual.
    var ref_buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("main", graph_view.refArg(&ref_buf, "main", .local));

    request(&.{ "merge", "--no-edit", "--no-ff", graph_view.refArg(&ref_buf, "v1", .local) });
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 2), history.?.commits[0].parents.len);
}

test "blame names the author of each line" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "lines.txt", "one\ntwo\n");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    selectBlame("lines.txt");
    ensureDiff();

    const b = blame_view orelse return error.NoBlame;
    // Two lines, not three: the trailing newline is not a line.
    try std.testing.expectEqual(@as(usize, 2), b.lines.len);
    try std.testing.expectEqualStrings("one", b.lines[0].text);
    try std.testing.expectEqualStrings("two", b.lines[1].text);
    try std.testing.expectEqualStrings("Zit Test", b.lines[0].author);
    try std.testing.expect(b.lines[0].time > 0);

    // An edit not committed yet belongs to nobody, whoever wrote the line it
    // replaced.
    var edited = try repo.?.readBlame(gpa, "lines.txt", "one\nTWO\n");
    defer edited.deinit();
    try std.testing.expect(edited.lines[0].time > 0);
    try std.testing.expectEqual(@as(i64, 0), edited.lines[1].time);
    try std.testing.expectEqualStrings("", edited.lines[1].author);

    // Emptied and not committed: nothing to blame, not a line from HEAD.
    var emptied = try repo.?.readBlame(gpa, "lines.txt", "");
    defer emptied.deinit();
    try std.testing.expectEqual(@as(usize, 0), emptied.lines.len);

    // Commits made on a detached HEAD are on no branch, and still on the graph.
    try expectGit(dir, &.{ "switch", "-q", "--detach" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "adrift" });
    graph_view.refreshHistory();
    try std.testing.expect(findCommit("adrift") != null);
}

test "a hard reset waits for the confirmation" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    defer clearConfirm();
    try std.testing.expectEqual(@as(usize, 2), history.?.commits.len);

    const base = findCommit("base") orelse return error.CommitNotFound;
    var sha_buf: [8]u8 = undefined;
    ask(.reset_hard, git.oidShort(base.id, &sha_buf));

    // Asking must not do it.
    try std.testing.expectEqual(@as(usize, 2), history.?.commits.len);

    runConfirmed();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), history.?.commits.len);
    // Answered once, and gone.
    try std.testing.expect(confirm == null);
}

test "the new branch dialog creates a branch, and stays open when the name is taken" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    defer clearPrompt();

    askName(.new_branch, "");
    try prompt_text.appendSlice(gpa, "feature");
    runPrompt();

    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("feature") != null);
    // A create that worked closes the dialog.
    try std.testing.expect(prompt == null);

    // The same name again fails, and the dialog stays up with the text in it so
    // the name can be fixed rather than retyped.
    askName(.new_branch, "");
    try prompt_text.appendSlice(gpa, "feature");
    runPrompt();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expect(prompt != null);

    // A dash would make it an option: `--force`, `-D`. Refused before git
    // sees it, with the dialog still open.
    clearCommandError();
    askName(.new_branch, "");
    try prompt_text.appendSlice(gpa, "-D");
    runPrompt();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expect(prompt != null);
    try std.testing.expect(findRef("-D") == null);

    // On screen: a dialog over the window, typed into at once — Enter makes
    // the branch — and Esc lets it be.
    clearCommandError();
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    askName(.new_branch, "");
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagRect("prompt:go");
    try typeText("typed");
    try pressFrame(.enter, .none);
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("typed") != null);
    try std.testing.expect(prompt == null);
    askName(.new_tag, "");
    try dvui.testing.settle(frameArrowCursor);
    try pressFrame(.escape, .none);
    try std.testing.expect(prompt == null);
    try expectNoTag("prompt:go");
}

// Rows are positioned by hand inside scroll areas and share widget ids with
// the graph: the kind of thing that builds fine and panics on frame one.
test "the conflict, rebase and blame panes each render a frame" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    try style.applyEmbedded(gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeConflictedPair(&tmp, dir);

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // Conflicts, the toolbar saying so.
    gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, history.?.state);
    selectChange("lines.txt", .unstaged);
    try dvui.testing.settle(appFrame);
    try std.testing.expect(rebase_view.isConflictView());
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);

    gitDo(&.{ "merge", "--abort" });
    clearSelection();

    // The rebase composer.
    const head = history.?.commits[0];
    beginRebase(if (head.parents.len > 0) head.parents[0] else null);
    try std.testing.expectEqual(Selection.rebase, std.meta.activeTag(selection));
    try dvui.testing.settle(appFrame);
    try std.testing.expectEqual(@as(usize, 1), rebase_steps.items.len);

    clearSelection();

    selectBlame("lines.txt");
    try dvui.testing.settle(appFrame);
    try std.testing.expect(blame_view != null);

    // And back to the graph.
    clearSelection();
    try dvui.testing.settle(appFrame);
    try std.testing.expect(blame_view == null);
}

test "LFS is offered only where the repository actually uses it" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // No `.gitattributes` at all, which is most repositories.
    try std.testing.expect(!tab_strip.uses_lfs);

    // One that mentions another filter is still not an LFS repository.
    try tmp.dir.writeFile(app_io, .{ .sub_path = ".gitattributes", .data = "*.txt text\n" });
    openRepo(dir);
    try std.testing.expect(!tab_strip.uses_lfs);

    try tmp.dir.writeFile(app_io, .{
        .sub_path = ".gitattributes",
        .data = "*.psd filter=lfs diff=lfs merge=lfs -text\n",
    });
    openRepo(dir);
    try std.testing.expect(tab_strip.uses_lfs);
}

/// Two repositories, the second with the first as its `origin`.
///
/// A path is a remote as far as git is concerned, which is what makes the
/// networked path testable without a network.
fn makeUpstreamPair(tmp: *std.testing.TmpDir, root: []const u8, up: []const u8, down: []const u8) !void {
    try expectGit(root, &.{ "init", "-q", "-b", "main", "up" });
    try expectGit(up, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(up, &.{ "config", "user.name", "Zit Test" });
    // Unsigned: the machine running this may sign every commit, and a GPG
    // passphrase prompt per test repo is not a test suite.
    try expectGit(up, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(up, &.{ "config", "tag.gpgsign", "false" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "up/a.txt", .data = "a\n" });
    try expectGit(up, &.{ "add", "-A" });
    try expectGit(up, &.{ "commit", "-qm", "upstream commit" });

    try expectGit(root, &.{ "init", "-q", "-b", "main", "down" });
    try expectGit(down, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(down, &.{ "config", "user.name", "Zit Test" });
    // Unsigned, as above.
    try expectGit(down, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(down, &.{ "config", "tag.gpgsign", "false" });
}

/// Absolute path of `rel`, which is what a remote URL has to be: git resolves
/// it from inside the repository, not from where the test is running.
fn absPath(buf: []u8, rel: []const u8) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(app_io, &cwd_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ cwd_buf[0..len], rel });
}

/// Let a job land, the way a frame would.
fn pumpJob() !void {
    var waited: usize = 0;
    while (tab_strip.job != null and waited < 1000) : (waited += 1) {
        collectJob();
        if (tab_strip.job != null) try std.Io.sleep(app_io, .fromMilliseconds(10), .awake);
    }
    if (tab_strip.job != null) return error.JobNeverFinished;
}

/// As `pumpJob`, then the frames after it: what the job changed is on screen,
/// and its tags with it, before the next click looks for them. Without them
/// the click aims at the last frame drawn, which may be from while it ran.
fn pumpJobFrame() !void {
    try pumpJob();
    try dvui.testing.settle(frameArrowCursor);
}

// Nothing about the threading is checked by the compiler: a job that never
// completes, or one whose result is never folded in, looks exactly like one
// that worked until you notice the refs did not move.
test "a networked command runs off the UI thread and folds its result in" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    requestNetwork("Fetching", &.{ "fetch", "origin" });
    try std.testing.expect(runAction());

    const started = tab_strip.job orelse return error.NoJobStarted;
    // Ran inline on this thread instead: every fetch would freeze the window.
    try std.testing.expect(!started.inline_run);

    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    // The result was folded in, not merely awaited: the snapshot has the ref.
    try std.testing.expect(findRef("origin/main") != null);
    // And the remote shows up where the sidebar reads it from.
    try std.testing.expectEqual(@as(usize, 1), history.?.remotes.len);
}

// The counts on Pull and Push. They come from libgit2, not a command, so
// nothing else in the suite would notice them going wrong.
test "the branch knows how far it is from its upstream" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "-B", "main", "origin/main" });
    try expectGit(down, &.{ "branch", "--set-upstream-to=origin/main", "main" });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // Level with the upstream: both buttons carry no count.
    try std.testing.expectEqual(@as(usize, 0), history.?.tracking.ahead);
    try std.testing.expectEqual(@as(usize, 0), history.?.tracking.behind);
    try std.testing.expectEqualStrings("origin/main", history.?.tracking.upstream.?);

    // One commit here and nowhere else is one commit to push.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "down/b.txt", .data = "b\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "local work" });
    reloadHistory();

    try std.testing.expectEqual(@as(usize, 1), history.?.tracking.ahead);
    try std.testing.expectEqual(@as(usize, 0), history.?.tracking.behind);

    // A branch with no upstream at all says nothing rather than guessing.
    try expectGit(down, &.{ "checkout", "-q", "-b", "solo" });
    reloadHistory();
    try std.testing.expectEqual(@as(?[]const u8, null), history.?.tracking.upstream);
    try std.testing.expectEqual(@as(usize, 0), history.?.tracking.ahead);
}

// The argv a caller hands to a job points into a snapshot that the poll timer
// is free to throw away a fraction of a second later. If the job did not copy
// it, this is the test that finds out — and the symptom in the app would be a
// fetch of a remote whose name had turned to garbage.
test "a job keeps its own copy of the command it was handed" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });

    // Heap-allocated, so the allocator can hand the bytes straight back out.
    const name = try gpa.dupe(u8, "origin");
    const cwd = try gpa.dupe(u8, down);

    var running = try run.Job.start(gpa, app_io, cwd, &.{ "fetch", name }, .{});

    // Gone before the command can have finished — exactly what a snapshot
    // refresh does to an argv still in flight.
    @memset(name, 'x');
    @memset(cwd, 'x');
    gpa.free(name);
    gpa.free(cwd);

    var waited: usize = 0;
    while (!running.finished() and waited < 1000) : (waited += 1) {
        try std.Io.sleep(app_io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(running.finished());

    var outcome = running.finish(gpa, app_io) orelse return error.GitNeverRan;
    defer outcome.deinit(gpa);

    // It fetched "origin" from the right directory, not "xxxxxx" from nowhere.
    try std.testing.expect(outcome.ok);
}

test "a command that lands after the repository changed is discarded, not reported" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    // No remote called "origin", so the fetch is going to fail — which is what
    // makes it visible whether the failure gets reported.
    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    requestNetwork("Fetching", &.{ "fetch", "origin" });
    try std.testing.expect(runAction());
    try std.testing.expect(tab_strip.job != null);

    // Away before it lands.
    dialog_views.closeRepo();
    try pumpJob();

    // The failure belonged to a repository nobody is looking at any more.
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
}

/// A config directory of its own, under the test's temporary directory.
///
/// Without this every one of these tests would write the real workspace file,
/// and running the suite would rearrange the tabs of whoever ran it.
fn useTestConfig(root: []const u8) !void {
    try tab_strip.config_dir.appendSlice(gpa, root);
    try tab_strip.config_dir.appendSlice(gpa, "/cfg");
}

test "the tab strip comes back after a restart" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });

    // A first run, with nothing to restore.
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.activeGroup().?.tabs.items.len);

    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);

    // The restart: everything in memory goes, and only the file is left.
    dialog_views.closeRepo();
    forgetTabs();
    tab_strip.loadWorkspace();

    const group = tab_strip.activeGroup() orelse return error.NoGroup;
    try std.testing.expectEqual(@as(usize, 2), group.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);
    // Stored as the working directory libgit2 resolved, not as the relative
    // path they were opened with.
    try std.testing.expect(std.mem.endsWith(u8, group.tabs.items[0].path, "/a/"));
    try std.testing.expect(std.mem.endsWith(u8, group.tabs.items[1].path, "/b/"));

    // And the one that was in front opens again.
    tab_strip.restoreActiveTab();
    try std.testing.expect(repo != null);
    try std.testing.expectEqualStrings("b", repo_name);

    // And the strip that shows them draws, both tabs in it.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(appFrame);
}

test "the same repository opened from inside itself reuses its tab" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try tmp.dir.createDirPath(app_io, "a/deep/inside");

    var deep_buf: [std.fs.max_path_bytes]u8 = undefined;
    const deep = try std.fmt.bufPrint(&deep_buf, "{s}/a/deep/inside", .{root});

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(deep);

    // One repository, one tab: libgit2 searched upward and resolved both to the
    // same working directory, which is what the tab is keyed on.
    try std.testing.expectEqual(@as(usize, 1), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_tab);
}

test "closing a tab falls onto its neighbour, and closing the last leaves nothing open" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    var buf_c: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    const b = try std.fmt.bufPrint(&buf_b, "{s}/b", .{root});
    const c = try std.fmt.bufPrint(&buf_c, "{s}/c", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "c" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    tab_strip.openAndRemember(c);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.active_tab);

    // Picking a folder that is no repository leaves the open one open.
    var buf_none: [std.fs.max_path_bytes]u8 = undefined;
    tab_strip.openAndRemember(try std.fmt.bufPrint(&buf_none, "{s}/none", .{root}));
    try std.testing.expectEqualStrings("c", repo_name);
    try std.testing.expect(tab_strip.command_error != null);
    clearCommandError();

    // Amend ticked here, or a branch dropped on another, does not follow
    // onto the next tab.
    amend = true;
    defer amend = false;
    graph_view.setDrop("feat", "main");

    // Close the one in front: the neighbour takes over, and opens.
    tab_strip.closeTab(2);
    try std.testing.expect(!amend);
    try std.testing.expect(graph_view.drop == null);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);
    try std.testing.expectEqualStrings("b", repo_name);

    // Closing one to the left of where you are looking must leave you looking
    // at the same repository, at its new index.
    tab_strip.closeTab(0);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_tab);
    try std.testing.expectEqualStrings("b", repo_name);

    tab_strip.closeTab(0);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expect(repo == null);
}

test "a tab dragged onto another takes its place, and the one shown stays shown" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();

    tab_strip.loadWorkspace();
    var bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "a", "b", "c" }, 0..) |name, i| {
        try expectGit(root, &.{ "init", "-q", "-b", "main", name });
        tab_strip.openAndRemember(try std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ root, name }));
    }
    const tabs = &tab_strip.groups.items[0].tabs;
    const order = struct {
        fn of(list: []const tab_strip.Tab, buf: *[3]u8) []const u8 {
            for (list, 0..) |tab, i| buf[i] = git.repoName(tab.path)[0];
            return buf[0..list.len];
        }
    };
    var buf: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    try std.testing.expectEqualStrings("c", repo_name);

    // a onto c, rightwards: it lands after it.
    tab_strip.moveTabTo(0, 0, 0, 2);
    try std.testing.expectEqualStrings("bca", order.of(tabs.items, &buf));
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);

    // a back onto b, leftwards: it lands before it.
    tab_strip.moveTabTo(0, 2, 0, 0);
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    try std.testing.expectEqual(@as(usize, 2), tab_strip.active_tab);

    // Onto itself, or past the end: nothing, then the end.
    tab_strip.moveTabTo(0, 1, 0, 1);
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    tab_strip.moveTabTo(0, 2, 0, 99);
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    try std.testing.expectEqualStrings("c", repo_name);

    // Into another group, before the tab it was dropped on.
    tab_strip.groupTab("Side", 0, 0);
    try std.testing.expectEqualStrings("bc", order.of(tab_strip.groups.items[0].tabs.items, &buf));
    tab_strip.moveTabTo(0, 1, 1, 0);
    try std.testing.expectEqualStrings("ca", order.of(tab_strip.groups.items[1].tabs.items, &buf));
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_group);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_tab);
    try std.testing.expectEqualStrings("c", repo_name);
}

test "workspaces hold their own groups, and switching opens the tab each was on" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    var buf_c: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    const b = try std.fmt.bufPrint(&buf_b, "{s}/b", .{root});
    const c = try std.fmt.bufPrint(&buf_c, "{s}/c", .{root});
    inline for (.{ "a", "b", "c" }) |name| try expectGit(root, &.{ "init", "-q", "-b", "main", name });

    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 1), tab_strip.workspaces.items.len);
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    // Groups as ever, inside the workspace.
    tab_strip.groupTab("Side", 0, 1);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[1].name);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.groups.items[1].ws);

    // A new workspace: empty, its own group, nothing open.
    const w = newWorkspace("Client", 3).?;
    selectWorkspace(w);
    try std.testing.expectEqual(w, tab_strip.active_ws);
    try std.testing.expect(repo == null and new_tab_open);
    tab_strip.openAndRemember(c);
    try std.testing.expectEqual(w, tab_strip.groups.items[tab_strip.active_group].ws);

    // Back: b, where it was, in its group.
    selectWorkspace(0);
    try std.testing.expectEqualStrings("b", repo_name);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[tab_strip.active_group].name);
    selectWorkspace(w);
    try std.testing.expectEqualStrings("c", repo_name);

    // All of it after a restart.
    tab_strip.saveWorkspace();
    dialog_views.closeRepo();
    forgetTabs();
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 2), tab_strip.workspaces.items.len);
    try std.testing.expectEqualStrings("Client", tab_strip.workspaces.items[1].name);
    try std.testing.expectEqual(@as(u8, 3), tab_strip.workspaces.items[1].color);
    var side = false;
    for (tab_strip.groups.items) |g| side = side or (std.mem.eql(u8, g.name, "Side") and g.ws == 0);
    try std.testing.expect(side);

    // Deleted: its tabs to the recent list, the other workspace stays.
    deleteWorkspace(1);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.workspaces.items.len);
    for (tab_strip.groups.items) |g| try std.testing.expectEqual(@as(usize, 0), g.ws);
}

test "a group is made in a dialog, with its colour and no name" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);

    group_target = .{ 0, 0 };
    openWorkspaceDialog(.group);
    try std.testing.expect(ws_dialog == .group);
    try std.testing.expect(prompt == null);
    // Only a colour asked for: a group is its dot.
    ws_color = 4;
    applyWorkspaceDialog();
    try std.testing.expect(ws_dialog == null);
    // Its only tab gone, the group it came from goes too.
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings(tab_strip.GROUP_MARK, tab_strip.groups.items[0].name);
    try std.testing.expectEqual(@as(u8, 4), tab_strip.groups.items[0].color);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);
    try std.testing.expectEqualStrings("", tab_strip.groupLabel(tab_strip.groups.items[0]));

    // Named, then the name taken off again: still a group, its dot alone.
    group_target = .{ 0, 0 };
    openWorkspaceDialog(.group_rename);
    try std.testing.expectEqual(@as(u8, 4), ws_color);
    ws_name.appendSlice(gpa, " Client ") catch unreachable;
    applyWorkspaceDialog();
    try std.testing.expectEqualStrings("Client", tab_strip.groupLabel(tab_strip.groups.items[0]));
    openWorkspaceDialog(.group_rename);
    try std.testing.expectEqualStrings("Client", ws_name.items);
    ws_name.clearRetainingCapacity();
    applyWorkspaceDialog();
    try std.testing.expectEqualStrings(tab_strip.GROUP_MARK, tab_strip.groups.items[0].name);

    // Let go past the last tab: out of the group, which goes, empty.
    tab_strip.tabToEnd(0, 0);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.groups.items[0].name.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_group);
}

test "a group keeps its own tabs, and the last group cannot be closed" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    const b = try std.fmt.bufPrint(&buf_b, "{s}/b", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);

    tab_strip.openAndRemember(b);
    // Two tabs in no group to begin with.
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("", tab_strip.groups.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items[0].tabs.items.len);

    // b into a group of its own, still the one open.
    tab_strip.groupTab("Side", 0, 1);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_group);
    try std.testing.expectEqualStrings("b", repo_name);

    // A tab of the other group, picked straight from the strip.
    tab_strip.selectTabIn(0, 0);
    try std.testing.expectEqualStrings("a", repo_name);

    // Both groups survive the restart, with their tabs, colour and fold.
    tab_strip.groups.items[1].collapsed = true;
    tab_strip.groups.items[1].color = 3;
    tab_strip.saveWorkspace();
    dialog_views.closeRepo();
    forgetTabs();
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[1].name);
    try std.testing.expect(tab_strip.groups.items[1].collapsed);
    try std.testing.expectEqual(@as(u8, 3), tab_strip.groups.items[1].color);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[1].tabs.items.len);

    // Out of the group again: the group, empty, goes.
    tab_strip.ungroupTab(1, 0);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("", tab_strip.groups.items[1].name);

    // Closing a group closes its tabs; the last one standing stays.
    tab_strip.closeGroup(0);
    tab_strip.closeGroup(0);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.groups.items[0].tabs.items.len);
}

test "First-parent shows the mainline through a merge, All branches the side branch too" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    defer graph_view.graph_first_parent = false;
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-q", "-c", "side" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "b.txt" });
    try expectGit(dir, &.{ "commit", "-q", "-m", "on the side" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try expectGit(dir, &.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    try std.testing.expectEqual(@as(usize, 3), history.?.commits.len);

    graph_view.graph_first_parent = true;
    reloadHistory();
    try std.testing.expectEqual(@as(usize, 2), history.?.commits.len);
    for (history.?.commits) |c| try std.testing.expect(!std.mem.eql(u8, c.summary, "on the side"));
    // The merge is still a merge, drawn without a line to the side.
    try std.testing.expectEqual(@as(u16, 1), lanes.?.lane_count);
}

/// Type `text` into the open prompt and answer it, the way Enter would.
fn answerPrompt(text: []const u8) !void {
    prompt_text.clearRetainingCapacity();
    try prompt_text.appendSlice(gpa, text);
    requestAction(.prompt);
    try std.testing.expect(runAction());
}

/// Say yes to the open confirmation.
fn answerConfirm() !void {
    try std.testing.expect(confirm != null);
    requestAction(.confirmed);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?Confirm, null), confirm);
}

// Each is one argv built from a prompt; only running it says the words are in
// the right order.
test "renames, a named stash and a forced delete go through git" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });
    try expectGit(dir, &.{ "remote", "add", "origin", "/nowhere" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    askNameWith(.rename_branch, "feat", "feat");
    // Pre-filled with the old name, so a typo is fixed rather than retyped.
    try std.testing.expectEqualStrings("feat", prompt_text.items);
    try answerPrompt("renamed");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("renamed") != null);
    try std.testing.expect(findRef("feat") == null);
    try std.testing.expectEqual(@as(?Prompt, null), prompt);

    askNameWith(.rename_remote, "origin", "origin");
    try answerPrompt("up");
    askNameWith(.remote_url, "up", "/nowhere");
    try answerPrompt("/elsewhere");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("up", history.?.remotes[0].name);
    try std.testing.expectEqualStrings("/elsewhere", history.?.remotes[0].url);

    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    askName(.stash, "");
    try answerPrompt("half a thought");
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), history.?.stashes.len);
    try std.testing.expect(std.mem.indexOf(u8, history.?.stashes[0].message, "half a thought") != null);

    // Its drop asked for, then another stash pushed on top while the bar is
    // up: the one asked about goes, not the new stash@{0}.
    var stash_hex: [41]u8 = undefined;
    ask(.stash_drop, git.oidHex(history.?.stashes[0].id, &stash_hex));
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "changed again\n" });
    try expectGit(dir, &.{ "stash", "push", "-m", "newer" });
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), history.?.stashes.len);
    try std.testing.expect(std.mem.indexOf(u8, history.?.stashes[0].message, "newer") != null);

    // Another pushed from a terminal, with the list not read again: the row
    // still says stash@{0} for "newer", and pop takes that one, not "newest".
    const newer = history.?.stashes[0].id;
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "third\n" });
    try expectGit(dir, &.{ "stash", "push", "-m", "newest" });
    rebase_view.requestStash("pop", newer);
    try std.testing.expect(runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    const popped = try tmp.dir.readFileAlloc(app_io, "a.txt", gpa, .limited(64));
    defer gpa.free(popped);
    try std.testing.expectEqualStrings("changed again\n", popped);
    try std.testing.expectEqual(@as(usize, 1), history.?.stashes.len);
    try std.testing.expect(std.mem.indexOf(u8, history.?.stashes[0].message, "newest") != null);
    try expectGit(dir, &.{ "checkout", "--", "a.txt" });

    // A branch with a commit no other branch has: `-d` refuses it, which is
    // why `-D` exists and why it asks.
    try expectGit(dir, &.{ "switch", "-q", "-c", "lost" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "only here" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    reloadHistory();

    gitDo(&.{ "branch", "-d", "lost" });
    try std.testing.expect(tab_strip.command_error != null);
    ask(.delete_branch_force, "lost");
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("lost") == null);
}

// The reverse of staging a hunk, and the file-level "put it back how it was".
// Both write the working tree, which is exactly what nothing else here does.
test "a hunk is discarded alone, and a file comes back from a commit" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app_io, .{ .sub_path = "lines.txt", .data = TWELVE_EDITED });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    const r = repo orelse return error.RepoNotOpen;

    {
        var unstaged = try r.readWorkDiff(gpa, .unstaged, "lines.txt");
        defer unstaged.deinit();
        try std.testing.expectEqual(@as(u32, 2), unstaged.files[0].hunk_count);
        rebase_view.askDiscardHunk(unstaged.files[0], 0);
    }
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const after = try tmp.dir.readFileAlloc(app_io, "lines.txt", gpa, .limited(1 << 16));
    defer gpa.free(after);
    // The first edit is gone, the last one is still there.
    try std.testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\ntwelve\n", after);

    try expectGit(dir, &.{ "commit", "-qam", "twelve" });
    reloadHistory();
    const base = findCommit("base") orelse return error.CommitNotFound;

    var arg_buf: [64]u8 = undefined;
    var sha_buf: [8]u8 = undefined;
    ask(.restore_file, try std.fmt.bufPrint(&arg_buf, "{s} lines.txt", .{git.oidShort(base.id, &sha_buf)}));
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const restored = try tmp.dir.readFileAlloc(app_io, "lines.txt", gpa, .limited(1 << 16));
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(TWELVE_LINES, restored);
}

// File history is a filter over the graph, worked out in git.zig; the merge
// case is the one that is easy to get wrong in either direction.
test "a file's history lists the commits that changed it, and only those" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    try expectGit(dir, &.{ "switch", "-q", "-c", "side" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "a, on a branch\n" });
    try expectGit(dir, &.{ "commit", "-qam", "a on side" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "b only" });
    // Carries side's change to a.txt in, without changing it itself.
    try expectGit(dir, &.{ "merge", "-q", "--no-ff", "--no-edit", "side" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    graph_view.showFileHistory("a.txt");
    const h = history.?;
    var shown: usize = 0;
    for (h.commits, 0..) |commit, i| {
        if (shownNow(commit, i)) shown += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), shown);

    const want = [_][]const u8{ "base", "a on side" };
    for (want) |summary| {
        const commit = findCommit(summary) orelse return error.CommitNotFound;
        try std.testing.expect(shownNow(commit, h.indexOf(commit.id).?));
    }
    const other = findCommit("b only") orelse return error.CommitNotFound;
    try std.testing.expect(!shownNow(other, h.indexOf(other.id).?));

    // Re-marked when the history is re-read: the flags are by index.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "again\n" });
    gitDo(&.{ "commit", "-qam", "a again" });
    const latest = findCommit("a again") orelse return error.CommitNotFound;
    try std.testing.expect(shownNow(latest, history.?.indexOf(latest.id).?));

    // And gone when asked.
    graph_view.clearFileHistory();
    try std.testing.expect(shownNow(other, history.?.indexOf(other.id).?));
}

test "ignoring a file appends it to .gitignore and it drops out of the changes" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    // A .gitignore without its last newline: the new line must not be glued on.
    try makeTestRepo(&tmp, dir, ".gitignore", "*.log");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "scratch.txt", .data = "x\n" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    try std.testing.expectEqual(@as(usize, 1), work.?.unstaged.len);

    commit_view.ignorePath("scratch.txt");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const text = try tmp.dir.readFileAlloc(app_io, ".gitignore", gpa, .limited(1 << 16));
    defer gpa.free(text);
    try std.testing.expectEqualStrings("*.log\n/scratch.txt\n", text);
    // The only change left is the .gitignore itself.
    try std.testing.expectEqual(@as(usize, 1), work.?.unstaged.len);
    try std.testing.expectEqualStrings(".gitignore", work.?.unstaged[0].path);

    // A name that reads as a glob: escaped, it ignores itself, and not the
    // `a1.txt` the bare pattern would have meant.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a[1].txt", .data = "x\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a1.txt", .data = "x\n" });
    reloadWork();
    commit_view.ignorePath("a[1].txt");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 2), work.?.unstaged.len);
    for (work.?.unstaged) |change| try std.testing.expect(!std.mem.eql(u8, change.path, "a[1].txt"));
}

// All go off-thread, two of them after a confirmation: a path no other test
// takes.
test "branches and tags are pushed, force pushed and deleted on the remote" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "--no-track", "-B", "feat", "origin/main" });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // The toolbar's push, on a branch with no upstream yet.
    requestNetwork("Pushing", &.{ "-c", "push.autoSetupRemote=true", "push" });
    try std.testing.expect(runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("origin/feat") != null);
    try std.testing.expect(history.?.tracking.upstream != null);

    // Rewrite what was pushed, and force it over.
    try expectGit(down, &.{ "commit", "-q", "--amend", "-m", "rewritten" });
    reloadHistory();
    ask(.force_push, "");
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    // The remote now has the rewritten commit, not the one it had.
    try std.testing.expect(findCommit("rewritten") != null);
    try std.testing.expectEqual(@as(usize, 0), history.?.tracking.ahead);
    try std.testing.expectEqual(@as(usize, 0), history.?.tracking.behind);

    ask(.delete_remote_branch, "origin/feat");
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var gone = try run.git(gpa, app_io, up, &.{ "rev-parse", "--verify", "-q", "refs/heads/feat" });
        defer gone.deinit(gpa);
        try std.testing.expect(!gone.ok);
    }

    try expectGit(down, &.{ "tag", "v1" });
    reloadHistory();
    requestNetwork("Pushing", &.{ "push", defaultRemote().?, "v1" });
    try std.testing.expect(runAction());
    try pumpJob();
    try expectGit(up, &.{ "rev-parse", "--verify", "-q", "refs/tags/v1" });

    ask(.delete_remote_tag, "v1");
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var gone = try run.git(gpa, app_io, up, &.{ "rev-parse", "--verify", "-q", "refs/tags/v1" });
        defer gone.deinit(gpa);
        try std.testing.expect(!gone.ok);
    }
}

/// The subject of `rev` in `dir`, for checking where a pull left things.
fn subjectAt(dir: []const u8, rev: []const u8) ![]u8 {
    const answer = try run.capture(gpa, app_io, dir, &.{ "git", "log", "-1", "--format=%s", rev });
    if (!answer.ok) {
        gpa.free(answer.out);
        return error.NoSuchRevision;
    }
    return answer.out;
}

fn expectSubject(dir: []const u8, rev: []const u8, want: []const u8) !void {
    const got = try subjectAt(dir, rev);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, got, "\n"));
}

/// A commit of one new file, made from a terminal behind the app's back.
fn commitFile(tmp: *std.testing.TmpDir, dir: []const u8, sub_path: []const u8, message: []const u8) !void {
    try tmp.dir.writeFile(app_io, .{ .sub_path = sub_path, .data = message });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", message });
}

test "fetch, and each pull the menu offers, through the toolbar" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "-B", "main", "--track", "origin/main" });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // The remote moves on; Fetch is what tells the branch it is behind.
    try commitFile(&tmp, up, "up/b.txt", "upstream two");
    try clickAt(try tagCenter("toolbar:Fetch"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), history.?.tracking.behind);

    // Fast-forward only, from behind.
    try clickAt(try tagCenter("toolbar:pull_menu"));
    try clickAt(try tagCenter("menu:Pull, fast-forward only"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(down, "HEAD", "upstream two");
    try std.testing.expectEqual(@as(usize, 0), history.?.tracking.behind);

    // Both sides move: rebasing puts the local commit back on top.
    try commitFile(&tmp, up, "up/c.txt", "upstream three");
    try commitFile(&tmp, down, "down/d.txt", "local one");
    reloadHistory();
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:pull_menu"));
    try clickAt(try tagCenter("menu:Pull, rebasing local commits"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(down, "HEAD", "local one");
    try expectSubject(down, "HEAD~1", "upstream three");

    // And again: merging joins the two in a merge commit, no editor asked for.
    try commitFile(&tmp, up, "up/e.txt", "upstream four");
    try commitFile(&tmp, down, "down/f.txt", "local two");
    reloadHistory();
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:pull_menu"));
    try clickAt(try tagCenter("menu:Pull, merging"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(down, "HEAD^1", "local two");
    try expectSubject(down, "HEAD^2", "upstream four");
}

/// Where the graph draws the commit `summary`, for clicking on it.
fn commitCenter(summary: []const u8) !dvui.Point.Physical {
    const c = findCommit(summary) orelse return error.NoSuchCommit;
    var short: [8]u8 = undefined;
    var tag_buf: [32]u8 = undefined;
    return tagCenter(try std.fmt.bufPrint(&tag_buf, "commit:{s}", .{git.oidShort(c.id, &short)}));
}

test "a commit's menu leads with check out, and resets from a submenu" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });
    try commitFile(&tmp, dir, "b.txt", "second");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try rightClickAt(try commitCenter("base"));
    const branch_row = try tagCenter("menu:Check out feat");
    const detach_row = try tagCenter("menu:Check out this commit (detaches HEAD)");
    const reset_row = try tagCenter("menu:Reset branch here");
    try std.testing.expect(branch_row.y < detach_row.y and detach_row.y < reset_row.y);
    // The three resets are not top-level rows.
    try std.testing.expect(dvui.tagGet("menu:Soft — keep changes staged") == null);

    try clickAt(reset_row);
    try clickAt(try tagCenter("menu:Soft — keep changes staged"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "base");
    // Soft: what the second commit added is staged, not lost.
    {
        var staged = try run.git(gpa, app_io, dir, &.{ "diff", "--cached", "--quiet", "--", "b.txt" });
        defer staged.deinit(gpa);
        try std.testing.expect(!staged.ok);
    }

    // Esc leaves the pull requests for the history.
    active_view = .pulls;
    try pressFrame(.escape, .none);
    try std.testing.expectEqual(.graph, active_view);
}

// A merge is neither picked nor reverted without naming its first parent.
test "cherry-pick and revert from a commit's menu, a merge's too" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-q", "-c", "feat" });
    try commitFile(&tmp, dir, "g.txt", "feat work");
    try expectGit(dir, &.{ "switch", "-q", "main" });
    // Main moves too: picked onto the commit it was made on, in the same
    // second, a cherry-pick is the very same commit, and nothing is left to
    // merge later.
    try commitFile(&tmp, dir, "m.txt", "main moves");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Cherry-picked from feat onto main.
    try rightClickAt(try commitCenter("feat work"));
    try clickAt(try tagCenter("menu:Cherry-pick onto current branch"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "feat work");
    try expectGit(dir, &.{ "rev-parse", "--verify", "-q", "HEAD:g.txt" });

    // Reverted: the file it added is gone again.
    try dvui.testing.settle(frameArrowCursor);
    {
        // Two commits say "feat work" now; the one on main is HEAD's.
        var short: [8]u8 = undefined;
        var tag_buf: [32]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tag_buf, "commit:{s}", .{git.oidShort(history.?.head_oid.?, &short)});
        try rightClickAt(try tagCenter(tag));
    }
    try clickAt(try tagCenter("menu:Revert"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "Revert \"feat work\"");
    {
        var gone = try run.git(gpa, app_io, dir, &.{ "rev-parse", "--verify", "-q", "HEAD:g.txt" });
        defer gone.deinit(gpa);
        try std.testing.expect(!gone.ok);
    }

    // A merge of feat, reverted: its change against main goes, the merge stays.
    try expectGit(dir, &.{ "merge", "-q", "--no-ff", "--no-edit", "-m", "merge feat", "feat" });
    reloadHistory();
    try dvui.testing.settle(frameArrowCursor);
    try rightClickAt(try commitCenter("merge feat"));
    try clickAt(try tagCenter("menu:Revert"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "Revert \"merge feat\"");
    try expectSubject(dir, "HEAD~1", "merge feat");
}

test "stash apply keeps the stash, amend starts from the last message, a tag from a commit's menu" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "commit", "-q", "--amend", "-m", "first\n\nwith a body" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Stashed, then applied from its row: the change back, the stash kept.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "edited\n" });
    reloadWork();
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:Stash"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 0), search_view.changeCount());
    {
        var short: [8]u8 = undefined;
        var tag_buf: [32]u8 = undefined;
        // Its buttons show on hover.
        try hoverAt(try tagCenter(try std.fmt.bufPrint(&tag_buf, "stash:{s}", .{git.oidShort(history.?.stashes[0].id, &short)})));
        try clickAt(try tagCenter(try std.fmt.bufPrint(&tag_buf, "stash_apply:{s}", .{git.oidShort(history.?.stashes[0].id, &short)})));
    }
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), search_view.changeCount());
    try std.testing.expectEqual(@as(usize, 1), history.?.stashes.len);

    // Amend ticked: the last message to start from, the button live at once.
    try clickAt(try tagCenter("link:stage_all"));
    try pumpJobFrame();
    try clickAt(try tagCenter("commit:amend"));
    try std.testing.expect(amend);
    try std.testing.expectEqualStrings("first", commit_summary.items);
    try std.testing.expectEqualStrings("with a body", commit_description.items);
    try clickAt(try tagCenter("commit_button"));
    // A commit is a job: waited for, as Stash and Stage all are. The
    // frames of the click alone were sometimes over before git was —
    // the commit not in the history yet, the job left running into the
    // next test.
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), history.?.commits.len);
    try expectSubject(dir, "HEAD", "first");
    try expectGit(dir, &.{ "diff", "--quiet", "HEAD", "--", "a.txt" });

    // A tag, from the commit's menu and its dialog.
    try rightClickAt(try commitCenter("first"));
    try clickAt(try tagCenter("menu:Tag this commit"));
    try std.testing.expect(prompt != null);
    try typeText("v0.1");
    try clickAt(try tagCenter("prompt:go"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("v0.1") != null);
}

test "the toolbar's branch menu filters and switches branches" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);
    try expectGit(up, &.{ "branch", "remote-only" });
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "-B", "main", "--track", "origin/main" });
    try expectGit(down, &.{ "branch", "feature" });

    openRepo(down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Narrowed by what is typed: main goes, feature stays.
    try clickAt(try tagCenter("toolbar:branch"));
    try typeText("feat");
    try std.testing.expect(dvui.tagGet("switch:main") == null);
    try clickAt(try tagCenter("switch:feature"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("feature", history.?.head.?);

    // A branch only the remote has: switched to, and tracked.
    try clickAt(try tagCenter("toolbar:branch"));
    try std.testing.expectEqual(@as(usize, 0), window_chrome.switch_filter.items.len);
    try clickAt(try tagCenter("switch:origin/remote-only"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("remote-only", history.?.head.?);
    try expectGit(down, &.{ "rev-parse", "--verify", "-q", "remote-only@{upstream}" });
}

// The avatar's menu: signing goes to its card in the settings, and signing
// out of GitHub only ever asks first. Never answered here — it would sign the
// machine running the tests out.
test "the avatar's menu opens the signing card, and asks before signing out" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    defer clearConfirm();
    // Who the menu says is signed in, without asking GitHub.
    window_chrome.me_loaded = true;
    try window_chrome.me_gh.appendSlice(gpa, "tester");

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("toolbar:user"));
    try clickAt(try tagCenter("menu:Commit signature"));
    try std.testing.expect(settings_open);
    try std.testing.expectEqual(@as(usize, 6), settings_page);
    // Another section from the list, and back.
    try clickAt(try tagCenter("settings:Integrations"));
    try std.testing.expectEqual(@as(usize, 3), settings_page);
    try clickAt(try tagCenter("settings:Commit signing"));
    try std.testing.expectEqual(@as(usize, 6), settings_page);
    try pressFrame(.escape, .none);
    try std.testing.expect(!settings_open);

    try clickAt(try tagCenter("toolbar:user"));
    try clickAt(try tagCenter("menu:Sign out of GitHub (tester)"));
    try std.testing.expect(confirm != null);
    try std.testing.expectEqual(Confirm.Kind.sign_out, confirm.?.kind);
    try std.testing.expectEqualStrings("tester", confirm.?.arg);
    try clickAt(try tagCenter("confirm:cancel"));
    try std.testing.expect(confirm == null);
}

// One person under two spellings and two addresses is one author once the
// repository's .mailmap says so: one row in the menu, every commit theirs.
test "the authors are read through .mailmap, one person once" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=ann", "-c", "user.email=ann@home.invalid", "commit", "-qm", "from home" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=Ann Lee", "-c", "user.email=ann@work.invalid", "commit", "-qm", "from work" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = ".mailmap", .data = "Ann Lee <ann@work.invalid> <ann@home.invalid>\n" });

    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const ann = graph_view.authorByKey("Ann Lee\nann@work.invalid") orelse return error.AuthorMissing;
    try std.testing.expectEqualStrings("Ann Lee", ann.name);
    try std.testing.expectEqual(@as(usize, 2), ann.count);
    try std.testing.expectEqual(@as(?graph_view.AuthorEntry, null), graph_view.authorByKey("ann\nann@home.invalid"));
    // A team sharing one address stays apart, by name.
    try std.testing.expect(graph_view.sameAuthor("Ann Lee\nANN@work.invalid", ann.key));
    try std.testing.expect(!graph_view.sameAuthor("Bo\nann@work.invalid", ann.key));

    // Theirs alone, from the commit's own menu's words, then Enter in the
    // menu's field taking the first author it shows.
    graph_view.onlyAuthor(ann.key);
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(gpa);
    graph_view.shownRows(gpa, history.?.commits, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);

    graph_view.clearAuthors();
    try clickAt(try tagCenter("header:author"));
    try typeText("test");
    try pressFrame(.enter, .none);
    try std.testing.expectEqual(@as(usize, 1), graph_view.author_only.items.len);
    try std.testing.expectEqualStrings("Zit Test\ntest@zync.invalid", graph_view.author_only.items[0]);
    // The one picked stays at the top of the menu, to be taken off from.
    try clickAt(try tagCenter("header:author"));
    try clickAt(try tagCenter("author:Zit Test"));
    try std.testing.expectEqual(@as(usize, 1), graph_view.author_only.items.len);
}

// Narrowed to one author, the history holds theirs alone, each joined to
// the nearest of theirs before it: a lane from the newest to the oldest,
// through the commits left out, as `git log --author --graph` draws it.
test "an author filter leaves the others' commits out and joins the lanes over them" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=Bo", "-c", "user.email=bo@x.invalid", "commit", "-qm", "by bo" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "mine again" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    try std.testing.expectEqual(@as(usize, 3), history.?.commits.len);

    graph_view.onlyAuthor("Zit Test\ntest@zync.invalid");
    const h = history.?;
    try std.testing.expectEqual(@as(usize, 2), h.commits.len);
    try std.testing.expectEqualStrings("mine again", h.commits[0].summary);
    try std.testing.expectEqualStrings("base", h.commits[1].summary);
    // Joined over Bo's.
    try std.testing.expectEqual(@as(usize, 1), h.commits[0].parents.len);
    try std.testing.expect(git.oidEql(h.commits[0].parents[0], h.commits[1].id));
    try std.testing.expectEqual(@as(usize, 1), lanes.?.lane_count);

    graph_view.clearAuthors();
    try std.testing.expectEqual(@as(usize, 3), history.?.commits.len);
}

test "the author column filters the list, and the version opens the features" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=Bo Chen", "-c", "user.email=bo@x.invalid", "commit", "-qm", "by bo" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("header:author"));
    try clickAt(try tagCenter("author:Bo Chen"));
    try std.testing.expect(graph_view.listFiltered());
    {
        var rows: std.ArrayList(u32) = .empty;
        defer rows.deinit(gpa);
        graph_view.shownRows(gpa, history.?.commits, &rows);
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
        try std.testing.expectEqualStrings("by bo", history.?.commits[rows.items[0]].summary);
    }
    // A click on a name shows theirs alone and closes the menu; the header
    // says whose; All authors, in the menu again, brings everyone back.
    try expectNoTag("author_filter");
    try clickAt(try tagCenter("header:author"));
    try clickAt(try tagCenter("pick:All authors"));
    try std.testing.expect(!graph_view.listFiltered());

    try clickAt(try tagCenter("status:version"));
    try std.testing.expect(features_open);
    try pressFrame(.escape, .none);
    try std.testing.expect(!features_open);
}

test "a request's lists, run ids and checks read the way the commands want them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[\"ann\",\"bo\",\"core\"]", jsonList(a, " ann, bo ,core,"));
    try std.testing.expectEqualStrings("[]", jsonList(a, " , "));

    try std.testing.expectEqualStrings("123", runIdOf("https://github.com/o/r/actions/runs/123/job/456").?);
    try std.testing.expectEqualStrings("9", runIdOf("https://github.com/o/r/actions/runs/9").?);
    try std.testing.expect(runIdOf("https://ci.example.com/build/1") == null);
    try std.testing.expect(runIdOf("https://github.com/o/r/actions/runs/x1/job/2") == null);

    const t = tallyChecks(&.{
        .{ .name = "a", .result = "SUCCESS" },
        .{ .name = "b", .result = "SKIPPED" },
        .{ .name = "c", .result = "FAILURE" },
        .{ .name = "d", .result = "IN_PROGRESS" },
    });
    try std.testing.expectEqual(@as(usize, 2), t.passed);
    try std.testing.expectEqual(@as(usize, 1), t.failed);
    try std.testing.expectEqual(@as(usize, 1), t.running);
}

test "the request list's tabs and search let the right ones through" {
    gpa = std.testing.allocator;
    defer resetUiGlobals();
    try window_chrome.me_gh.appendSlice(gpa, "me");
    const mine: pr.Request = .{ .number = 7, .title = "Add login", .branch = "PROJ-25", .author = "me", .draft = true };
    const asks: pr.Request = .{ .number = 12, .title = "API module", .branch = "PROJ-39", .author = "ann", .draft = false, .reviewers = &.{ "bo", "Me" } };
    const other: pr.Request = .{ .number = 30, .title = "Docs", .branch = "PROJ-33", .author = "bo", .draft = false };
    const list = [_]pr.Request{ mine, asks, other };
    pr.list = &list;
    defer pr.list = &.{};

    try std.testing.expectEqual(@as(usize, 1), requestsToReview());
    pr_filter = .review;
    try std.testing.expect(requestShown(asks) and !requestShown(mine) and !requestShown(other));
    pr_filter = .mine;
    try std.testing.expect(requestShown(mine) and !requestShown(asks));
    pr_filter = .drafts;
    try std.testing.expect(requestShown(mine) and !requestShown(other));

    pr_filter = .open;
    try pr_search.appendSlice(gpa, "api");
    try std.testing.expect(requestShown(asks) and !requestShown(other));
    pr_search.clearRetainingCapacity();
    try pr_search.appendSlice(gpa, "#30");
    try std.testing.expect(requestShown(other) and !requestShown(asks));
    pr_search.clearRetainingCapacity();
    try pr_search.appendSlice(gpa, "proj-25");
    try std.testing.expect(requestShown(mine) and !requestShown(other));
}

test "a new request's title comes from its branch's name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("PROJ-81: Front Login", humanBranch(a, "PROJ-81-Front-Login"));
    try std.testing.expectEqualStrings("feat: new thing", humanBranch(a, "feat/new-thing"));
    try std.testing.expectEqualStrings("cleanup", humanBranch(a, "cleanup"));
    try std.testing.expectEqualStrings("PROJ-7", ticketOf("PROJ-7").?);
    try std.testing.expect(ticketOf("v1-2") == null);
    try std.testing.expect(ticketOf("fix-it") == null);
}

test "a comment's inline marks come off, and plain text is left as it is" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("use QUERY here, not the bold", plainInline(a, "use `QUERY` here, not the **bold**"));
    try std.testing.expectEqualStrings("snake_case stays", plainInline(a, "snake_case stays"));
    const same = "nothing to strip";
    try std.testing.expect(plainInline(a, same).ptr == same.ptr);
}

// The request pane draws in full — head, tabs, the conversation's timeline
// with a folded run of reviews, threads, the answer and the merge — and each
// other tab, without a widget left open.
test "a picker's list toggles, and a label with spaces in it stays whole" {
    gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    listToggle(&list, "ann");
    listToggle(&list, "good first issue");
    try std.testing.expectEqualStrings("ann, good first issue", list.items);
    try std.testing.expect(listHas(list.items, "good first issue"));
    try std.testing.expect(!listHas(list.items, "good"));
    listToggle(&list, "ann");
    try std.testing.expectEqualStrings("good first issue", list.items);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("[\"good first issue\",\"bug\"]", jsonCommaList(arena.allocator(), "good first issue, bug,"));
}

// The create dialog as GitHub's page has it: the people and the labels
// picked from lists the host gave, the type from a list of two.
test "a new pull request's reviewers, labels and type are picked from lists" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-qc", "feat/login-form" });
    openRepo(dir);
    defer dialog_views.closeRepo();
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    pr.meta = .{
        .people = &.{ .{ .login = "ann", .name = "Ann Lee" }, .{ .login = "bo" } },
        .labels = &.{ .{ .name = "bug", .color = "d73a4a" }, .{ .name = "good first issue", .color = "7057ff" } },
    };
    pr.meta_status = .ready;
    defer {
        pr.meta = .{};
        pr.meta_status = .idle;
    }

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1400, .h = 860 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    openPrCreate();
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqualStrings("feat/login-form", pr_new_head.items);

    try clickAt(try tagCenter("pr_new:labels"));
    try clickAt(try tagCenter("pick:good first issue"));
    try std.testing.expectEqualStrings("good first issue", pr_new_labels.items);
    try pressFrame(.escape, .none);

    try clickAt(try tagCenter("pr_new:reviewers"));
    try clickAt(try tagCenter("pick:bo"));
    try std.testing.expectEqualStrings("bo", pr_new_reviewers.items);
    try pressFrame(.escape, .none);

    try clickAt(try tagCenter("pr_new:type"));
    try clickAt(try tagCenter("pick:Draft"));
    try std.testing.expect(pr_new_draft);
    try std.testing.expect(pr_new_open);
}

// GitHub's sidebar: a section's head drops its list, and a tick there is
// sent at once — refused here, with no one signed in, which is the point:
// it was sent, and the list kept the tick.
test "the request's sidebar picks its labels from a list, sent at once" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    pr.detail = .{
        .number = 42,
        .title = "Login form",
        .author = "damien",
        .state = "OPEN",
        .head = "feat/login-form",
        .base = "main",
        .reviewers = &.{.{ .login = "ann", .state = "APPROVED" }},
        .labels = &.{.{ .name = "enhancement", .color = "a2eeef" }},
    };
    defer pr.detail = null;
    pr.meta = .{ .labels = &.{ .{ .name = "bug", .color = "d73a4a" }, .{ .name = "enhancement", .color = "a2eeef" } } };
    pr.meta_status = .ready;
    defer {
        pr.meta = .{};
        pr.meta_status = .idle;
    }
    pr_selected = 42;
    active_view = .pulls;
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1600, .h = 800 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("side:Labels"));
    try clickAt(try tagCenter("pick:bug"));
    try std.testing.expect(listHas(side_list.items, "bug"));
    try std.testing.expect(listHas(side_list.items, "enhancement"));
    try std.testing.expect(tab_strip.command_error != null);

    // The edit dialog opens on the request as it is.
    openPrEdit(pr.detail.?);
    defer clearPrEdit();
    try std.testing.expectEqualStrings("main", pr_edit_base.items);
    try std.testing.expect(sameNames(pr_edit_reviewers.items, &.{"ann"}));
    try std.testing.expect(sameNames(pr_edit_labels.items, &.{"enhancement"}));
    try std.testing.expect(!sameNames(pr_edit_labels.items, &.{ "enhancement", "bug" }));
}

// A suggestion as GitHub writes it, and written into the file: over the
// lines it was left on, only while they read as the comment saw them.
test "a suggestion goes over the lines it was left on, while they still read as the comment saw them" {
    app_io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // The block, and the words around it.
    const sg = suggestionOf("Use it:\n```suggestion\nif (ok(x)) go();\n```\nThanks.").?;
    try std.testing.expectEqualStrings("Use it:\n", sg.before);
    try std.testing.expectEqualStrings("if (ok(x)) go();", sg.code);
    try std.testing.expectEqualStrings("Thanks.", sg.after);
    try std.testing.expect(suggestionOf("no block here") == null);
    try std.testing.expectEqualStrings("", suggestionOf("```suggestion\n```").?.code);

    // One line, in a file with CRLF ends, which it keeps.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.js", .data = "one\r\nif (x) go();\r\nthree\r\n" });
    const one: pr.Thread = .{ .path = "a.js", .line = 2, .hunk = "@@ -1,2 +1,2 @@\n one\n-if (y) go();\n+if (x) go();" };
    try std.testing.expectEqual(@as(?[]const u8, null), applySuggestionTo(a, dir, one, "if (ok(x)) go();"));
    try std.testing.expectEqualStrings("one\r\nif (ok(x)) go();\r\nthree\r\n", try tmp.dir.readFileAlloc(app_io, "a.js", a, .limited(1024)));
    // Twice: the line no longer reads as the comment saw it, and is left be.
    try std.testing.expect(applySuggestionTo(a, dir, one, "if (ok(x)) go();") != null);
    try std.testing.expectEqualStrings("one\r\nif (ok(x)) go();\r\nthree\r\n", try tmp.dir.readFileAlloc(app_io, "a.js", a, .limited(1024)));

    // Two lines into one, in a file with no last newline; then an empty
    // suggestion takes a line out.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "a\nb\nc\nd" });
    const two: pr.Thread = .{ .path = "b.txt", .start_line = 2, .line = 3, .hunk = "@@ -1 +1,3 @@\n a\n+b\n+c" };
    try std.testing.expectEqual(@as(?[]const u8, null), applySuggestionTo(a, dir, two, "bc"));
    try std.testing.expectEqualStrings("a\nbc\nd", try tmp.dir.readFileAlloc(app_io, "b.txt", a, .limited(1024)));
    const gone: pr.Thread = .{ .path = "b.txt", .line = 1, .hunk = "@@ -0,0 +1 @@\n+a" };
    try std.testing.expectEqual(@as(?[]const u8, null), applySuggestionTo(a, dir, gone, ""));
    try std.testing.expectEqualStrings("bc\nd", try tmp.dir.readFileAlloc(app_io, "b.txt", a, .limited(1024)));
    // Past the end of the file: changed since.
    try std.testing.expect(applySuggestionTo(a, dir, .{ .path = "b.txt", .line = 9 }, "x") != null);
}

// Picked, a request is read in full off the window's thread: its head is
// there at once from the list, the rest loading under it — not a blank pane.
test "a request being read shows its head from the list, the rest loading" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();

    var listed = [_]pr.Request{.{ .number = 9, .title = "Faster search", .branch = "feat/search", .author = "ann", .draft = false, .base = "main" }};
    pr.list = &listed;
    defer pr.list = &.{};
    pr.detail = null;
    pr_selected = 9;
    active_view = .pulls;
    pr.host = .github;
    defer pr.host = .none;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagRect("pr:loading");
    // Not one the list has: the pane loading, with no head to guess at.
    pr_selected = 10;
    try dvui.testing.settle(frameArrowCursor);
    try expectNoTag("pr:loading");
}

// A request someone asked changes of, as its author meets it: who asked and
// how much is left, the conversations under the review that opened them —
// a resolved one folded — and a suggestion applied from the click.
test "changes asked for: threads under their review, a suggestion applied from its button" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "login.ts", "const f = el();\nif (email) submit();\n");
    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    pr.detail = .{
        .number = 16,
        .id = "PR_1",
        .title = "Login form",
        .author = "me",
        .state = "OPEN",
        // Its branch is the one checked out here.
        .head = "main",
        .base = "dev",
        .mergeable = "MERGEABLE",
        .review = "CHANGES_REQUESTED",
        .reviews = &.{.{ .id = "R1", .author = "ann", .body = "A couple of things.", .when = "2026-10-21T11:00:00Z", .state = "CHANGES_REQUESTED" }},
        .reviewers = &.{.{ .login = "ann", .state = "CHANGES_REQUESTED" }},
        .threads = &.{
            .{ .id = "T1", .review = "R1", .path = "login.ts", .line = 2, .can_reply = true, .can_resolve = true, .hunk = "@@ -1 +1,2 @@\n const f = el();\n+if (email) submit();", .comments = &.{.{ .author = "ann", .body = "Use the validator:\n```suggestion\nif (isEmail(email)) submit();\n```", .when = "2026-10-21T11:00:00Z" }} },
            .{ .id = "T2", .review = "R1", .path = "login.ts", .line = 1, .resolved = true, .can_unresolve = true, .comments = &.{.{ .author = "ann", .body = "fine now", .when = "2026-10-21T11:00:00Z" }} },
        },
    };
    defer pr.detail = null;
    pr_selected = 16;
    active_view = .pulls;
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    pr_tab = .conversation;
    try dvui.testing.settle(frameArrowCursor);

    // On its branch already: asking again is what is left to do, and each
    // reviewer who answered can be asked again too.
    _ = try tagRect("pr:rerequest");
    _ = try tagRect("pr:rerequest:ann");
    try expectNoTag("pr:fix");
    // The open one shows its answers; the resolved one is folded to its head.
    _ = try tagRect("pr:resolve:T1");
    try expectNoTag("pr:unresolve:T2");
    try clickAt(try tagCenter("pr:threads_all"));
    _ = try tagRect("pr:unresolve:T2");

    // The suggestion, into the file here; its button then says so, and
    // leads to the change.
    try clickAt(try tagCenter("pr:apply:T1"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectNoTag("pr:apply:T1");
    _ = try tagRect("pr:applied:T1");
    const now = try tmp.dir.readFileAlloc(app_io, "login.ts", gpa, .limited(1024));
    defer gpa.free(now);
    try std.testing.expectEqualStrings("const f = el();\nif (isEmail(email)) submit();\n", now);

    // To the conversations from the readiness line.
    try clickAt(try tagCenter("pr:to_threads"));
    try std.testing.expect(!pr_scroll_thread);

    // To the change it made, in the working copy.
    try clickAt(try tagCenter("pr:applied:T1"));
    try std.testing.expectEqual(View.graph, active_view);
    try std.testing.expectEqualStrings("login.ts", selected_path.items);
}

test "a request's pane draws every tab" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();

    const review = pr.Note{ .author = "ann", .body = "part of a review", .when = "2026-10-20T10:00:00Z", .state = "COMMENTED" };
    pr.detail = .{
        .number = 7,
        .title = "Login",
        .body = "## Why\n- one\n- [x] done\n> quoted\n```\ncode\n```\nplain **bold**",
        .author = "me",
        .state = "OPEN",
        .head = "feat",
        .base = "main",
        .comments = &.{.{ .author = "bo", .body = "looks fine", .when = "2026-10-21T10:00:00Z" }},
        .reviews = &.{ review, review, review, review, .{ .author = "ann", .when = "2026-10-20T11:00:00Z", .state = "APPROVED" } },
        .checks = &.{ .{ .name = "build", .result = "SUCCESS", .group = "CI", .seconds = 75 }, .{ .name = "lint", .result = "FAILURE", .group = "CI", .url = "https://github.com/o/r/actions/runs/5/job/6" } },
        .reviewers = &.{.{ .login = "ann", .state = "APPROVED" }},
        .labels = &.{.{ .name = "bug", .color = "d73a4a" }},
        .commits = &.{.{ .oid = "0123456789abcdef0123456789abcdef01234567", .headline = "add login", .author = "me", .when = 1 }},
        .file_list = &.{.{ .path = "src/a.zig", .additions = 3, .deletions = 1 }},
        .threads = &.{.{ .id = "T1", .path = "src/a.zig", .line = 2, .comments = &.{.{ .author = "ann", .body = "why?", .when = "2026-10-20T10:30:00Z" }} }},
    };
    defer pr.detail = null;
    pr_selected = 7;
    active_view = .pulls;
    // The pane is drawn only on a host; nothing is asked of it here.
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    for ([_]PrTab{ .conversation, .commits, .files, .checks }) |tab| {
        pr_tab = tab;
        try dvui.testing.settle(frameArrowCursor);
    }
    pr_tab = .conversation;
    try dvui.testing.settle(frameArrowCursor);
    // The four bare reviews in a row: the middle two folded behind a button.
    try std.testing.expect(pr_runs_open == 0);

    // Six steps: the description and the last three open, the oldest folded
    // to their head; Expand all opens the lot, a click on a head folds one.
    try std.testing.expect(cardOpen(0, true));
    try std.testing.expect(!cardOpen(1, 1 + CARDS_OPEN_AT_END >= 6));
    try clickAt(try tagCenter("pr:expand_all"));
    try std.testing.expectEqual(@as(?bool, true), pr_cards_all);
    try std.testing.expect(cardOpen(1, false));
    try clickAt(try tagCenter("pr:collapse_all"));
    try std.testing.expect(!cardOpen(0, true));
}

// The requests from the keys: the checked-out branch's own picked to begin
// with, ↑ and ↓ along the list in its order, a number for a tab.
test "the requests are walked from the keys, starting at the checked-out branch's" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();

    var list = [_]pr.Request{
        .{ .number = 1, .title = "newest", .branch = "feat-a", .author = "ann", .draft = false, .updated = 30 },
        .{ .number = 2, .title = "this branch", .branch = "main", .author = "bo", .draft = false, .updated = 20 },
        .{ .number = 3, .title = "oldest", .branch = "x", .author = "carl", .draft = false, .updated = 10 },
    };
    pr.list = &list;
    defer pr.list = &.{};
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    active_view = .pulls;
    defer pr_selected = null;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(?u32, 2), pr_selected);

    try pressFrame(.down, .none);
    try std.testing.expectEqual(@as(?u32, 3), pr_selected);
    try pressFrame(.down, .none);
    try std.testing.expectEqual(@as(?u32, 3), pr_selected);
    try pressFrame(.up, .none);
    try pressFrame(.k, .none);
    try std.testing.expectEqual(@as(?u32, 1), pr_selected);
    try pressFrame(.four, .none);
    try std.testing.expect(pr_tab == .checks);

    // A filter clicked switches the list to the merged ones, shorter than the
    // open: drawn from the one list, not the other's indexes. This crashed.
    var past = [_]pr.Request{.{ .number = 9, .title = "merged", .branch = "old", .author = "ann", .draft = false, .updated = 5 }};
    pr.past = &past;
    defer pr.past = &.{};
    try clickAt(try tagCenter("pr:filter"));
    try clickAt(try tagCenter("pick:Merged"));
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(pr_filter == .merged);
    try pressFrame(.down, .none);
    try std.testing.expectEqual(@as(?u32, 9), pr_selected);
    try clickAt(try tagCenter("pr:filter"));
    try clickAt(try tagCenter("pick:Open"));
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(pr_filter == .open);
}

// A clone starts with no repository at all, and opens the one it makes. (A new
// repository is the dialog's other half, tested with its refusals below.)
test "a clone opens in a tab" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    var root_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    dialog_views.openRepoDialog(.clone);
    try dialog_views.dialog_url.appendSlice(gpa, try absPath(&abs_buf, up));
    dialog_views.dialog_parent.clearRetainingCapacity();
    try dialog_views.dialog_parent.appendSlice(gpa, try absPath(&root_abs_buf, root));
    try dialog_views.dialog_name.appendSlice(gpa, "cloned");
    requestAction(.repo_dialog);
    try std.testing.expect(runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(std.mem.endsWith(u8, repo_path.items, "cloned/"));
    try std.testing.expect(findCommit("upstream commit") != null);
    try std.testing.expect(findRef("origin/main") != null);
}

test "a leading tilde means home, and only a leading one" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = homeDir() orelse return error.SkipZigTest;
    const got = expandHome(&buf, "~/dev/x");
    try std.testing.expect(std.mem.startsWith(u8, got, home));
    try std.testing.expect(std.mem.endsWith(u8, got, "/dev/x"));
    try std.testing.expectEqualStrings("/abs/~/x", expandHome(&buf, "/abs/~/x"));
    try std.testing.expectEqualStrings("rel", expandHome(&buf, "rel"));
}

test "undo takes back a commit and a checkout, and undoing an undo redoes" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    requestUndo();
    // The commit by its full sha: seven characters can be ambiguous.
    try std.testing.expectEqual(@as(usize, 40), action_argv[2].len);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findCommit("second") == null);
    // Nothing lost: what the commit carried is staged again.
    try std.testing.expectEqual(@as(usize, 1), work.?.staged.len);

    requestUndo();
    try std.testing.expect(runAction());
    try std.testing.expect(findCommit("second") != null);
    try std.testing.expectEqual(@as(usize, 0), work.?.staged.len);

    // Switched outside Zit, at the same commit: the poll still notices, so
    // Undo takes back the switch and not the redo before it.
    try expectGit(dir, &.{ "switch", "-q", "-c", "elsewhere" });
    poll();
    try std.testing.expectEqualStrings("elsewhere", history.?.head.?);
    requestUndo();
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("main", history.?.head.?);

    // A reset outside Zit onto the commit HEAD is already on: same oid, same
    // branch, and still the move Undo has to see.
    try expectGit(dir, &.{ "reset", "-q", "HEAD" });
    poll();
    try std.testing.expect(std.mem.startsWith(u8, history.?.last_move.?.message, "reset:"));
}

test "redo takes back the last undo, and only while nothing has moved since" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // Nothing undone yet: nothing to redo.
    requestRedo();
    try std.testing.expect(tab_strip.command_error != null);
    clearCommandError();

    requestUndo();
    try std.testing.expect(runAction());
    try std.testing.expect(findCommit("second") == null);
    requestRedo();
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findCommit("second") != null);
    // Redone once; a second redo has nothing to take back.
    requestRedo();
    try std.testing.expect(tab_strip.command_error != null);
    clearCommandError();

    // Undone, then something else moves HEAD: the redo is gone with it.
    requestUndo();
    try std.testing.expect(runAction());
    try expectGit(dir, &.{ "commit", "-qm", "another" });
    poll();
    try std.testing.expect(!canRedo());
    requestRedo();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expect(findCommit("second") == null);
    clearCommandError();

    // From the toolbar: Redo beside Undo, deaf until an undo, then taking
    // it back, and deaf again.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:Redo"));
    try std.testing.expect(findCommit("another") != null);
    try clickAt(try tagCenter("toolbar:Undo"));
    try std.testing.expect(findCommit("another") == null);
    try std.testing.expect(canRedo());
    try std.testing.expectEqualStrings("commit: another", redo_what[0..redo_what_len]);
    try clickAt(try tagCenter("toolbar:Redo"));
    try std.testing.expect(findCommit("another") != null);
    try std.testing.expect(!canRedo());
}

test "with the integrations off, no pull requests, issues or GitHub account" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    defer tab_strip.integrations = true;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();

    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    active_view = .pulls;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:user"));
    try std.testing.expect(dvui.tagGet("menu:Sign in with GitHub") != null);
    try pressFrame(.escape, .none);

    tab_strip.setIntegrations(false);
    try std.testing.expectEqual(pr.Host.none, pr.host);
    try std.testing.expectEqual(.graph, active_view);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:user"));
    try std.testing.expect(dvui.tagGet("menu:Settings — Ctrl+,") != null);
    try std.testing.expect(dvui.tagGet("menu:Sign in with GitHub") == null);
}

test "a chord with Shift, AltGr or the Windows key is not the chord without" {
    const Mod = dvui.enums.Mod;
    const with = struct {
        fn f(mods: []const Mod) Mod {
            var m: u16 = 0;
            for (mods) |x| m |= @backingInt(x);
            return @fromBackingInt(@intCast(m));
        }
    }.f;
    const key = struct {
        fn f(code: dvui.enums.Key, mod: Mod) dvui.Event.Key {
            return .{ .code = code, .action = .down, .mod = mod };
        }
    }.f;
    try std.testing.expect(pressed(key(.z, .lcontrol), .z, true));
    try std.testing.expect(pressed(key(.z, .rcontrol), .z, true));
    // Ctrl+Shift+Z is the redo, not also the undo.
    try std.testing.expect(!pressed(key(.z, with(&.{ .lcontrol, .lshift })), .z, true));
    try std.testing.expect(pressedShift(key(.z, with(&.{ .lcontrol, .lshift })), .z));
    // AltGr, which Windows sends as Ctrl+Alt: neither.
    try std.testing.expect(!pressed(key(.z, with(&.{ .lcontrol, .ralt })), .z, true));
    try std.testing.expect(!pressedShift(key(.z, with(&.{ .lcontrol, .ralt, .lshift })), .z));
    try std.testing.expect(!pressed(key(.z, with(&.{ .lcontrol, .lcommand })), .z, true));
    // Shift+↓ selects text; it does not walk the history.
    try std.testing.expect(!pressed(key(.down, .lshift), .down, false));
}

test "commit messages: ticket, type, wrap and trailers" {
    try std.testing.expectEqualStrings("PROJ-80", commit_view.branchTicket("PROJ-80-Back-Login").?);
    try std.testing.expectEqualStrings("WEB-345", commit_view.branchTicket("feature/WEB-345-v1-login").?);
    try std.testing.expect(commit_view.branchTicket("main") == null);
    try std.testing.expect(commit_view.branchTicket("develop") == null);
    try std.testing.expect(commit_view.branchTicket("fix-X-1") == null);

    try std.testing.expectEqualStrings("api", commit_view.summaryScope("feat(api): add x").?);
    try std.testing.expect(commit_view.summaryScope("Merge (x): y") == null);
    try std.testing.expect(commit_view.summaryScope("fix: plain") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("PROJ-80: add x", try commit_view.composeSummary(a, "add x", null, "", "PROJ-80"));
    try std.testing.expectEqualStrings("feat(api): PROJ-80 add x", try commit_view.composeSummary(a, " add x ", "feat", "api", "PROJ-80"));
    try std.testing.expectEqualStrings("fix: PROJ-80 done", try commit_view.composeSummary(a, "PROJ-80 done", "fix", "", "PROJ-80"));
    try std.testing.expectEqualStrings("add x", try commit_view.composeSummary(a, "add x", null, "", null));

    try std.testing.expectEqualStrings("aaa bbb\nccc", try commit_view.wrapBody(a, "aaa bbb ccc", 7));
    try std.testing.expectEqualStrings("short\n\n- keep", try commit_view.wrapBody(a, "short\n\n- keep", 72));

    const authors = [_][]const u8{"Ann <ann@x.io>"};
    try std.testing.expectEqualStrings(
        "PROJ-1: s\n\nbody\n\nRefs: PROJ-2\nCo-authored-by: Ann <ann@x.io>",
        try commit_view.composeMessage(a, "PROJ-1: s", "body\n", true, "PROJ-2", &authors),
    );
    try std.testing.expectEqualStrings("s", try commit_view.composeMessage(a, "s", "  ", true, null, &.{}));
    // A ticket already in the summary is not repeated as a trailer.
    try std.testing.expectEqualStrings("PROJ-2 s", try commit_view.composeMessage(a, "PROJ-2 s", "", true, "PROJ-2", &.{}));
}

test "the palette finds commands by loose letters, and draws" {
    try std.testing.expect(fuzzy("Push", "psh"));
    try std.testing.expect(fuzzy("Pull, rebasing local commits", "pull reb"));
    try std.testing.expect(!fuzzy("Fetch all remotes", "push"));
    try std.testing.expect(fuzzy("anything", ""));

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(gpa, true);

    openPalette();
    try palette_text.appendSlice(gpa, "theme");
    try dvui.testing.settle(appFrame);
    try std.testing.expect(palette_open);
}

test "search terms: fields, dates, and path and code through git" {
    var buf: [graph_view.MAX_TERMS]graph_view.Term = undefined;
    const t = graph_view.parseQuery("fix author:\"Ann Lee\" after:2026-10-01 path:src/", &buf);
    try std.testing.expectEqual(@as(usize, 4), t.len);
    try std.testing.expectEqualStrings("Ann Lee", t[1].text);
    try std.testing.expectEqual(@as(i64, 1790812800), t[2].time);
    try std.testing.expect(t[3].kind == .path);
    try std.testing.expectEqual(@as(?i64, 0), graph_view.parseDay("1970-01-01"));
    try std.testing.expectEqual(@as(?i64, null), graph_view.parseDay("2026-02-31"));
    try std.testing.expect(graph_view.parseDay("2024-02-29") != null);
    // A date that is not one yet is left out, for both ends alike.
    try std.testing.expectEqual(@as(usize, 1), graph_view.parseQuery("before:2026- after:x fix", &buf).len);

    var win = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 600 } });
    defer win.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.createDirPath(app_io, "src");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "src/b.ts", .data = "const needle = 1;\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "add b" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    const commits = history.?.commits;

    try commit_filter.appendSlice(gpa, "author:zit msg:add");
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(!matchesNow(commits[1]));

    inline for (.{ "path:b.ts", "code:needle" }) |query| {
        commit_filter.clearRetainingCapacity();
        try commit_filter.appendSlice(gpa, query);
        search_view.updateSearchHits();
        var waited: usize = 0;
        while (!search_view.search_hits.ready and waited < 500) : (waited += 1) {
            try std.Io.sleep(app_io, .fromMilliseconds(10), .awake);
            search_view.updateSearchHits();
        }
        try std.testing.expect(matchesNow(commits[0]));
        try std.testing.expect(!matchesNow(commits[1]));
    }

    // A commit made after the search is in it once the history is read again:
    // the hits for "code:needle" have landed, and the query does not change.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "src/b.ts", .data = "const needle = 1;\nconst needle2 = 2;\n" });
    try expectGit(dir, &.{ "commit", "-qam", "more needles" });
    reloadHistory();
    var waited: usize = 0;
    search_view.updateSearchHits();
    while ((!search_view.search_hits.ready or search_view.search_hits.seq != graph_view.history_seq or search_view.search_hits.running != null) and waited < 500) : (waited += 1) {
        try std.Io.sleep(app_io, .fromMilliseconds(10), .awake);
        search_view.updateSearchHits();
    }
    try std.testing.expect(matchesNow(history.?.commits[0]));
    try std.testing.expectEqualStrings("more needles", history.?.commits[0].summary);

    // The whole sha finds it, not only its first seven.
    var hex: [41]u8 = undefined;
    commit_filter.clearRetainingCapacity();
    try commit_filter.print(gpa, "sha:{s}", .{git.oidHex(history.?.commits[1].id, &hex)});
    try std.testing.expect(matchesNow(history.?.commits[1]));
    try std.testing.expect(!matchesNow(history.?.commits[0]));

    // ↓ goes to the next row shown, past the ones the search hides.
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "msg:e");
    selectCommit(history.?.commits[0].id);
    stepCommit(1);
    try std.testing.expect(git.oidEql(selection.commit, history.?.commits[2].id));
    clearSelection();

    // Let go of mid-search, as a tab switch does: nothing waits for it, and
    // it is freed once it is done.
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "code:needle2");
    search_view.updateSearchHits();
    try std.testing.expect(search_view.search_hits.running != null);
    search_view.clearSearchHits();
    try std.testing.expect(search_view.search_hits.running == null);
    waited = 0;
    while (search_view.search_retired.items.len > 0 and waited < 500) : (waited += 1) {
        try std.Io.sleep(app_io, .fromMilliseconds(10), .awake);
        search_view.reapSearchFetches(false);
    }
    try std.testing.expectEqual(@as(usize, 0), search_view.search_retired.items.len);

    // Typed over mid-search: the new one starts now, the old one retired.
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "code:needle2");
    search_view.updateSearchHits();
    try std.testing.expect(search_view.search_hits.running != null);
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "code:needle");
    search_view.updateSearchHits();
    const now = search_view.search_hits.running orelse return error.NoSearch;
    try std.testing.expectEqualStrings(search_view.search_hits.key.items, now.key);
    waited = 0;
    while ((!search_view.search_hits.ready or search_view.search_retired.items.len > 0) and waited < 500) : (waited += 1) {
        try std.Io.sleep(app_io, .fromMilliseconds(10), .awake);
        search_view.updateSearchHits();
    }
    try std.testing.expect(matchesNow(history.?.commits[0]));

    // Two paths would be git's OR: refused, and said why.
    commit_filter.clearRetainingCapacity();
    try commit_filter.appendSlice(gpa, "path:b.ts path:a.txt");
    search_view.updateSearchHits();
    try std.testing.expect(search_view.search_hits.ready and search_view.search_hits.err.items.len > 0);
    try std.testing.expect(!matchesNow(history.?.commits[1]));
}

test "showing one branch alone while scrolled far down does not crash" {
    var win = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 400 } });
    defer win.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for (0..30) |i| {
        var msg: [16]u8 = undefined;
        try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", try std.fmt.bufPrint(&msg, "c{d}", .{i}) });
    }
    try expectGit(dir, &.{ "branch", "short", "HEAD~29" });
    openRepo(dir);
    defer dialog_views.closeRepo();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    // Scrolled to the bottom of 31 commits, then down to 2: the list once
    // asked for rows 25 to 2, a range that runs backwards.
    graph_scroll.viewport.y = 25 * style.graph_row;
    graph_view.setSolo("short");
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, 2), history.?.commits.len);
}

test "a branch hidden from the graph stays hidden, and one can be shown alone" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "checkout", "-q", "-b", "side" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "on side" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "on main" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    try std.testing.expectEqual(@as(usize, 3), history.?.commits.len);

    graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "side");
    try std.testing.expectEqual(@as(usize, 2), history.?.commits.len);
    // Kept in the repository: read back as it would be on the next open.
    graph_view.loadGraphPrefs();
    try std.testing.expect(graph_view.isHidden("side"));

    graph_view.setSolo("side");
    try std.testing.expectEqual(@as(usize, 2), history.?.commits.len);
    try std.testing.expect(findCommit("on side") != null);
    try std.testing.expect(findCommit("on main") == null);
    graph_view.setSolo(null);

    graph_view.unhideAll();
    try std.testing.expectEqual(@as(usize, 3), history.?.commits.len);
    graph_view.loadGraphPrefs();
    try std.testing.expectEqual(@as(usize, 0), graph_view.graph_hidden.items.len);

    graph_view.toggleGraphPref(&graph_view.graph_pinned, "zit.pinned", "side");
    graph_view.loadGraphPrefs();
    try std.testing.expect(graph_view.hasName(graph_view.graph_pinned.items, "side"));

    // Compared with main, side brings b.txt — and not main's own c.txt,
    // which is after where the two parted.
    var side_tip: git.Oid = undefined;
    for (history.?.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "side")) side_tip = ref.target;
    }
    startCompare(history.?.head_oid.?, side_tip, "main", "side");
    ensureDiff();
    try std.testing.expectEqual(@as(usize, 1), diff.?.files.len);
    try std.testing.expectEqualStrings("b.txt", diff.?.files[0].path);
    clearSelection();
}

test "a file's history follows it back through a rename" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    // Enough content that git calls the move a rename, not a delete and an add.
    try makeTestRepo(&tmp, dir, "old.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app_io, .{ .sub_path = "old.txt", .data = TWELVE_EDITED });
    try expectGit(dir, &.{ "commit", "-qam", "edit under the old name" });
    try expectGit(dir, &.{ "mv", "old.txt", "new.txt" });
    try expectGit(dir, &.{ "commit", "-qm", "rename" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "other.txt", .data = "x\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "unrelated" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    graph_view.showFileHistory("new.txt");
    const h = history.?;
    for ([_][]const u8{ "rename", "edit under the old name", "base" }) |summary| {
        const commit = findCommit(summary) orelse return error.CommitNotFound;
        try std.testing.expect(shownNow(commit, h.indexOf(commit.id).?));
    }
    const other = findCommit("unrelated") orelse return error.CommitNotFound;
    try std.testing.expect(!shownNow(other, h.indexOf(other.id).?));
}

test "changes picked together are stashed or staged together, and only they" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "b" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "a2\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b2\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "c.txt", .data = "new\n" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    try std.testing.expectEqual(@as(usize, 3), work.?.unstaged.len);

    // a and the new c stashed; b stays.
    commit_view.toggleChangePick(.unstaged, "a.txt");
    commit_view.toggleChangePick(.unstaged, "c.txt");
    try std.testing.expectEqual(@as(usize, 2), commit_view.pickedIn(.unstaged, work.?.unstaged));
    commit_view.requestPicked(.stash, .unstaged, work.?.unstaged);
    try std.testing.expectEqual(@as(usize, 0), commit_view.picked_changes.items.len);
    try std.testing.expect(runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), work.?.unstaged.len);
    try std.testing.expectEqualStrings("b.txt", work.?.unstaged[0].path);
    try std.testing.expectEqual(@as(usize, 1), history.?.stashes.len);

    // Back, then two of the three staged.
    rebase_view.requestStash("pop", history.?.stashes[0].id);
    try std.testing.expect(runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(usize, 3), work.?.unstaged.len);
    commit_view.toggleChangePick(.unstaged, "b.txt");
    commit_view.toggleChangePick(.unstaged, "c.txt");
    // Picking on the other side starts over.
    commit_view.toggleChangePick(.staged, "x");
    try std.testing.expectEqual(@as(usize, 0), commit_view.pickedIn(.unstaged, work.?.unstaged));
    commit_view.toggleChangePick(.unstaged, "b.txt");
    commit_view.toggleChangePick(.unstaged, "c.txt");
    commit_view.requestPicked(.stage, .unstaged, work.?.unstaged);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(usize, 2), work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 1), work.?.unstaged.len);
    try std.testing.expectEqualStrings("a.txt", work.?.unstaged[0].path);
}

test "picked lines of a new file go into the index alone" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "new.txt", .data = "one\ntwo\nthree\n" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    const r = repo orelse return error.RepoNotOpen;

    {
        var d = try r.readWorkDiff(gpa, .unstaged, "new.txt");
        defer d.deinit();
        const file = d.files[0];
        try std.testing.expectEqual(git.Status.added, file.status);
        for (file.lines, 0..) |l, i| {
            if (l.kind == .addition and !std.mem.eql(u8, l.text, "two")) rebase_view.togglePicked(i, file.lines.len);
        }
        rebase_view.requestLines(file, 0, .unstaged, false);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const index = try run.capture(gpa, app_io, dir, &.{ "git", "show", ":new.txt" });
    defer gpa.free(index.out);
    try std.testing.expect(index.ok);
    // `capture` trims the last newline.
    try std.testing.expectEqualStrings("one\nthree", index.out);
}

test "picked lines are staged and unstaged alone" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "f.txt", "1\n2\n3\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "one\n2\nthree\n" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();
    const r = repo orelse return error.RepoNotOpen;

    // A pick outlives the poll's re-read of a file nobody touched, and goes
    // once the file does change.
    selectChange("f.txt", .unstaged);
    ensureDiff();
    rebase_view.togglePicked(1, diff.?.files[0].lines.len);
    poll();
    ensureDiff();
    try std.testing.expect(rebase_view.isPicked(1));
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "one\n2\nthree\nfour\n" });
    poll();
    ensureDiff();
    try std.testing.expect(!rebase_view.isPicked(1));
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "one\n2\nthree\n" });
    clearSelection();

    {
        var d = try r.readWorkDiff(gpa, .unstaged, "f.txt");
        defer d.deinit();
        const file = d.files[0];
        try std.testing.expectEqual(@as(u32, 1), file.hunk_count);
        // The first deletion and its addition: "1" -> "one".
        for (file.lines, 0..) |l, i| {
            if ((l.kind == .deletion and std.mem.eql(u8, l.text, "1")) or (l.kind == .addition and std.mem.eql(u8, l.text, "one"))) {
                rebase_view.togglePicked(i, file.lines.len);
            }
        }
        try std.testing.expectEqual(@as(usize, 2), rebase_view.pickedInHunk(file, 0));
        rebase_view.requestLines(file, 0, .unstaged, false);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    var staged = try run.git(gpa, app_io, dir, &.{ "diff", "--cached", "--quiet", "--", "f.txt" });
    staged.deinit(gpa);
    try std.testing.expect(!staged.ok);
    {
        var show = try r.readWorkDiff(gpa, .staged, "f.txt");
        defer show.deinit();
        var adds: usize = 0;
        for (show.files[0].lines) |l| {
            if (l.kind == .addition) {
                adds += 1;
                try std.testing.expectEqualStrings("one", l.text);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), adds);

        // And back out: the staged side, reversed.
        picked_lines.clearRetainingCapacity();
        for (show.files[0].lines, 0..) |l, i| {
            if (l.kind == .addition or l.kind == .deletion) rebase_view.togglePicked(i, show.files[0].lines.len);
        }
        rebase_view.requestLines(show.files[0], 0, .staged, false);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    var none = try r.readWorkDiff(gpa, .staged, "f.txt");
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.files.len);

    // A last line with no newline. The marker under it is part of the patch,
    // and picking only the line added after it makes the old last line gain a
    // newline — the marker must not end up in the middle of the hunk.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "1\n2\n3" });
    try expectGit(dir, &.{ "commit", "-qam", "no newline" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "1\n2\n3\n4\n" });
    {
        var d = try r.readWorkDiff(gpa, .unstaged, "f.txt");
        defer d.deinit();
        rebase_view.requestHunk(d.files[0], 0, .unstaged);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var d = try r.readWorkDiff(gpa, .staged, "f.txt");
        defer d.deinit();
        rebase_view.requestHunk(d.files[0], 0, .staged);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var d = try r.readWorkDiff(gpa, .unstaged, "f.txt");
        defer d.deinit();
        picked_lines.clearRetainingCapacity();
        for (d.files[0].lines, 0..) |l, i| {
            if (l.kind == .addition and std.mem.eql(u8, l.text, "4")) rebase_view.togglePicked(i, d.files[0].lines.len);
        }
        rebase_view.requestLines(d.files[0], 0, .unstaged, false);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    var nonl_rest = try r.readWorkDiff(gpa, .unstaged, "f.txt");
    defer nonl_rest.deinit();
    try std.testing.expectEqual(@as(usize, 0), nonl_rest.files.len);

    // CRLF: the `\r` stays in the patch, or it does not apply.
    try expectGit(dir, &.{ "reset", "-q" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "a\r\nb\r\n" });
    try expectGit(dir, &.{ "commit", "-qam", "crlf" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "a\r\nc\r\n" });
    {
        var d = try r.readWorkDiff(gpa, .unstaged, "f.txt");
        defer d.deinit();
        rebase_view.requestHunk(d.files[0], 0, .unstaged);
        try std.testing.expect(runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    var crlf_rest = try r.readWorkDiff(gpa, .unstaged, "f.txt");
    defer crlf_rest.deinit();
    try std.testing.expectEqual(@as(usize, 0), crlf_rest.files.len);

    // A staged rename is two paths, and unstaging takes back both.
    try expectGit(dir, &.{ "commit", "-qm", "c" });
    try expectGit(dir, &.{ "mv", "f.txt", "[g].txt" });
    reloadWork();
    const moved = work.?.staged[0];
    try std.testing.expectEqualStrings("[g].txt", moved.path);
    try std.testing.expectEqualStrings("f.txt", moved.old_path);
    request(&.{ "--literal-pathspecs", "reset", "-q", "--", moved.path, moved.old_path });
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(usize, 0), work.?.staged.len);

    // Which leaves it renamed on disk only. Discarding that brings the old
    // name back and takes the new one away — and `[g].txt` is a name, not a
    // glob that would also clean the untracked `g.txt` beside it.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "g.txt", .data = "decoy\n" });
    reloadWork();
    const renamed = for (work.?.unstaged) |ch| {
        if (std.mem.eql(u8, ch.path, "[g].txt")) break ch;
    } else return error.RenameNotListed;
    try std.testing.expectEqual(git.Status.renamed, renamed.status);
    try std.testing.expectEqualStrings("f.txt", renamed.old_path);
    // Its diff is the rename too, not a new file with the old one lost.
    {
        var d = try repo.?.readWorkDiffFrom(gpa, .unstaged, renamed.path, renamed.old_path);
        defer d.deinit();
        try std.testing.expectEqual(@as(usize, 1), d.files.len);
        try std.testing.expectEqual(git.Status.renamed, d.files[0].status);
    }
    doDiscard("[g].txt");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    const back = try tmp.dir.readFileAlloc(app_io, "f.txt", gpa, .limited(1 << 16));
    defer gpa.free(back);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(app_io, "[g].txt", gpa, .limited(1 << 16)));
    const decoy = try tmp.dir.readFileAlloc(app_io, "g.txt", gpa, .limited(1 << 16));
    defer gpa.free(decoy);
}

test "discarding everything stops at a restore that failed, and needs none for untracked files" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try tmp.dir.createDirPath(app_io, "ro");
    try makeTestRepo(&tmp, dir, "ro/f.txt", "f\n");

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // A tracked edit git cannot write back — its folder read-only — beside an
    // untracked file: the error stays up, and the untracked file stays too.
    try tmp.dir.writeFile(app_io, .{ .sub_path = "ro/f.txt", .data = "edited\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "u.txt", .data = "u\n" });
    var ro_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ro = try std.fmt.bufPrint(&ro_buf, "{s}/ro", .{dir});
    try expectRun(&.{ "chmod", "555", ro });
    defer expectRun(&.{ "chmod", "755", ro }) catch {};
    reloadWork();
    doDiscard("");
    try std.testing.expect(tab_strip.command_error != null);
    const kept = try tmp.dir.readFileAlloc(app_io, "u.txt", gpa, .limited(64));
    gpa.free(kept);
    clearCommandError();

    // Untracked files alone: nothing for `restore` to name, and no error for it.
    try expectRun(&.{ "chmod", "755", ro });
    try expectGit(dir, &.{ "checkout", "--", "ro/f.txt" });
    reloadWork();
    doDiscard("");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(app_io, "u.txt", gpa, .limited(64)));
}

test "a worktree is added, listed, and removed" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/main", .{root});

    try git.init();
    defer git.shutdown();
    try expectGit(root, &.{ "init", "-q", "-b", "main", "main" });
    try expectGit(dir, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(dir, &.{ "config", "user.name", "Zit Test" });
    try expectGit(dir, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "base" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    var line_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const wt = try absPath(&abs_buf, try std.fmt.bufPrint(&line_buf, "{s}/side", .{root}));
    var answer_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    askName(.add_worktree, "");
    try answerPrompt(try std.fmt.bufPrint(&answer_buf, "{s} feature", .{wt}));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), history.?.worktrees.len);
    try std.testing.expect(findRef("feature") != null);

    ask(.remove_worktree, history.?.worktrees[0].path);
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 0), history.?.worktrees.len);
}

test "the new repository dialog makes the folder, the first commit, and a tab" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = try absPath(&abs_buf, root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();
    tab_strip.loadWorkspace();

    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("https://github.com/me/zync.git"));
    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("git@github.com:me/zync"));
    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("C:\\src\\zync\\"));
    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("D:zync.git"));

    dialog_views.openRepoDialog(.create);
    try std.testing.expect(!dialog_views.dialogReady());
    dialog_views.dialog_parent.clearRetainingCapacity();
    try dialog_views.dialog_parent.appendSlice(gpa, abs_root);
    try dialog_views.dialog_name.appendSlice(gpa, "fresh");
    try std.testing.expect(dialog_views.dialogReady());

    // The dialog runs git in a folder with no config of its own, so the first
    // commit reads the global one: point that at a file of the test's, with an
    // identity and signing off, rather than at whoever runs the suite.
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/gitconfig", .{abs_root});
    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = cfg, .data = "[user]\n\temail = test@zync.invalid\n\tname = Zit Test\n[commit]\n\tgpgsign = false\n" });
    var env = try isolatedEnv(cfg, abs_root);
    defer env.deinit();
    run.env_override = &env;
    defer run.env_override = null;
    try std.testing.expect(dialog_views.dialog_readme);

    requestAction(.repo_dialog);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(dialog_views.RepoDialog.none, dialog_views.repo_dialog);
    try std.testing.expect(repo != null);
    try std.testing.expect(std.mem.endsWith(u8, repo_path.items, "fresh/"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("main", history.?.head.?);
    try std.testing.expect(findCommit("Initial commit") != null);

    // The same name again: a folder with things in it is refused, not
    // initialised over, and keeps its single commit.
    dialog_views.openRepoDialog(.create);
    dialog_views.dialog_parent.clearRetainingCapacity();
    try dialog_views.dialog_parent.appendSlice(gpa, abs_root);
    try dialog_views.dialog_name.appendSlice(gpa, "fresh");
    requestAction(.repo_dialog);
    _ = runAction();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(dialog_views.RepoDialog.create, dialog_views.repo_dialog);
    reloadHistory();
    try std.testing.expectEqual(@as(usize, 1), history.?.commits.len);
    dialog_views.repo_dialog = .none;
}

test "a branch dropped onto another merges into it, or rebases onto it" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-q", "-c", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "f.txt", .data = "f\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "feature work" });
    try expectGit(dir, &.{ "switch", "-q", "-c", "other", "main" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "o.txt", .data = "o\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "other work" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    // Merge feat into main, while other is checked out.
    graph_view.setDrop("feat", "main");
    graph_view.drop_action = .merge;
    requestAction(.drop);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("main", history.?.head.?);
    try std.testing.expect(graph_view.drop == null);
    var feature_hex: [41]u8 = undefined;
    try expectGit(dir, &.{ "merge-base", "--is-ancestor", git.oidHex(findCommit("feature work").?.id, &feature_hex), "main" });

    // Rebase other onto main.
    graph_view.setDrop("other", "main");
    graph_view.drop_action = .rebase;
    requestAction(.drop);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectGit(dir, &.{ "merge-base", "--is-ancestor", "main", "other" });

    // A remote branch rebases the local one tracking it, whatever its name,
    // and is refused when none does.
    try expectGit(dir, &.{ "remote", "add", "origin", "/nowhere" });
    try expectGit(dir, &.{ "update-ref", "refs/remotes/origin/up", "feat" });
    try expectGit(dir, &.{ "update-ref", "refs/remotes/origin/lone", "feat" });
    try expectGit(dir, &.{ "config", "branch.feat.remote", "origin" });
    try expectGit(dir, &.{ "config", "branch.feat.merge", "refs/heads/up" });
    reloadHistory();
    graph_view.setDrop("origin/up", "other");
    graph_view.drop_action = .rebase;
    requestAction(.drop);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectGit(dir, &.{ "merge-base", "--is-ancestor", "other", "feat" });
    graph_view.setDrop("origin/lone", "other");
    requestAction(.drop);
    try std.testing.expect(runAction());
    try std.testing.expect(tab_strip.command_error != null);
}

// The gesture itself: press on one branch row, move across to another, let
// go. Nothing but driving the mouse says the button gave the capture up.
test "dragging a branch row onto another opens the drop menu where it was let go" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    // Folded by default; these rows are what the test works on.
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });

    openRepo(dir);
    defer dialog_views.closeRepo();

    // The dummy video driver has no system cursors and logs an error for every
    // cursor change, which fails the test; asking for the arrow last in every
    // frame means the cursor never changes.
    const frameArrow = struct {
        fn f() !dvui.App.Result {
            const r = try appFrame();
            dvui.currentWindow().cursor_requested = .arrow;
            dvui.currentWindow().dragging.cursor = null;
            return r;
        }
    }.f;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrow);

    const from = (dvui.tagGet("feat") orelse return error.TagNotFound).rect.center();
    const to = (dvui.tagGet("main") orelse return error.TagNotFound).rect.center();
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrow);
    // In steps, past the drag threshold and across the rows between.
    for (1..9) |i| {
        const f = @as(f32, @floatFromInt(i)) / 8;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + (to.x - from.x) * f, .y = from.y + (to.y - from.y) * f } });
        _ = try dvui.testing.step(frameArrow);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrow);

    const d = graph_view.drop orelse return error.NoDrop;
    try std.testing.expectEqualStrings("feat", d.source);
    try std.testing.expectEqualStrings("main", d.target);

    // Its two answers, in a menu by the row it fell on; Esc lets it be.
    {
        const merge = try tagRect("menu:Merge feat into main");
        _ = try tagRect("menu:Rebase feat onto main");
        try std.testing.expect(@abs(merge.y - to.y) < 40);
    }
    try pressFrame(.escape, .none);
    try std.testing.expect(graph_view.drop == null);
    try expectNoTag("menu:Merge feat into main");

    // As does a click outside it.
    graph_view.setDrop("feat", "main");
    graph_view.drop_at = to.toNatural();
    try dvui.testing.settle(frameArrow);
    {
        const menu = try tagRect("menu:Merge feat into main");
        try clickAt(.{ .x = menu.x + menu.w + 200, .y = menu.y + 200 });
    }
    try std.testing.expect(graph_view.drop == null);
    try expectNoTag("menu:Merge feat into main");

    // And one of its rows does what it says.
    graph_view.setDrop("feat", "main");
    graph_view.drop_at = to.toNatural();
    try dvui.testing.settle(frameArrow);
    try clickAt(try tagCenter("menu:Merge feat into main"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(graph_view.drop == null);
    try expectNoTag("menu:Merge feat into main");
}

/// The allocator a test runs Zit on, counting what goes through it.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len) self.allocs += 1;
        return self.child.rawResize(mem, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawRemap(mem, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
    }
};

// Idle is a frame drawn again with nothing changed — the mouse over the
// window, a poll that found nothing. It may use the frame's arena, which dvui
// keeps; it must not go to the heap.
test "a frame drawn again with nothing changed allocates nothing" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    gpa = counting.allocator();
    app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try expectGit(dir, &.{ "branch", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    // A commit picked, its diff open: the busiest screen idle can be.
    try clickAt(try commitCenter("second"));
    try dvui.testing.settle(frameArrowCursor);

    const before = counting.allocs;
    // It does count: opening the repository went through it.
    try std.testing.expect(before > 0);
    for (0..5) |_| _ = try dvui.testing.step(frameArrowCursor);
    try std.testing.expectEqual(before, counting.allocs);
}

// The same, on the screens added since: a filter narrowing the history, a
// dialog waiting for a name, a toast waiting for a yes.
test "a frame drawn again allocates nothing, a filter on, a dialog or a toast up" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    gpa = counting.allocator();
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try expectGit(dir, &.{ "-c", "user.name=Ann", "-c", "user.email=ann@x.invalid", "commit", "-q", "--allow-empty", "-m", "by ann" });
    try expectGit(dir, &.{ "branch", "feat" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const Idle = struct {
        /// Heap allocations over five frames once nothing more is asked.
        fn allocs(c: *CountingAllocator) !usize {
            try dvui.testing.settle(frameArrowCursor);
            const before = c.allocs;
            for (0..5) |_| _ = try dvui.testing.step(frameArrowCursor);
            return c.allocs - before;
        }
    };
    var found: [4]usize = undefined;
    // One author's commits alone.
    graph_view.onlyAuthor((graph_view.authorByKey("Ann\nann@x.invalid") orelse return error.AuthorMissing).key);
    found[0] = try Idle.allocs(&counting);
    graph_view.clearAuthors();
    // A search typed into the commit filter.
    commit_filter.appendSlice(gpa, "second") catch unreachable;
    found[1] = try Idle.allocs(&counting);
    commit_filter.clearRetainingCapacity();
    // A dialog asking for a name.
    askNameWith(.rename_branch, "feat", "feat");
    found[2] = try Idle.allocs(&counting);
    clearPrompt();
    // A toast asking for a yes. Its first frames are its first draw —
    // dvui setting its window up, 2 allocations — so the next five count.
    ask(.discard, "a.txt");
    _ = try Idle.allocs(&counting);
    found[3] = try Idle.allocs(&counting);
    clearConfirm();

    if (!std.mem.allEqual(usize, &found, 0)) {
        std.debug.print("heap allocations over 5 idle frames: author filter {d}, search {d}, dialog {d}, toast {d}\n", .{ found[0], found[1], found[2], found[3] });
        return error.FramesAllocate;
    }
}

// The mouse swept over every part of the window, then left alone: the frames
// it asked for stop within a few, not 100 later — no hover that keeps
// drawing, no widget whose size goes back and forth.
test "after the mouse has swept the window, frames stop" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);
    stillUi();
    defer {
        dvui.reduce_motion = false;
        dvui.hover_fade_secs = 0.12;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try expectGit(dir, &.{ "branch", "feat" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const cw = dvui.currentWindow();
    const size = dvui.windowRectPixels();
    var y: f32 = 5;
    while (y < size.h) : (y += 70) {
        var x: f32 = 5;
        while (x < size.w) : (x += 110) {
            _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
            _ = try dvui.testing.step(frameArrowCursor);
        }
    }
    // Left where it is: a frame or two for what the last move lit.
    var frames: usize = 0;
    while (frames < 100) : (frames += 1) {
        const wait = try dvui.testing.step(frameArrowCursor);
        if (wait == null or wait.? != 0) break;
    }
    try std.testing.expect(frames < 5);
}

test "opening and closing everything, again and again, leaks nothing" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "new.txt", .data = "new\n" });

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    for (0..3) |_| {
        openRepo(dir);
        try dvui.testing.settle(frameArrowCursor);
        // A commit, its files, one of them whole, all the tree; a change;
        // the search; a pick of changes; a ref hidden and shown.
        const head = history.?.commits[0].id;
        selectCommit(head);
        commit_view.commit_all_files = true;
        try dvui.testing.settle(frameArrowCursor);
        selectCommitFile(head, "a.txt");
        try dvui.testing.settle(frameArrowCursor);
        selectChange("a.txt", .unstaged);
        commit_view.toggleChangePick(.unstaged, "new.txt");
        commit_filter.appendSlice(gpa, "second") catch unreachable;
        try dvui.testing.settle(frameArrowCursor);
        commit_filter.clearRetainingCapacity();
        graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "main");
        graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "main");
        try dvui.testing.settle(frameArrowCursor);
        // The views since: one author's commits, a dialog, a toast.
        graph_view.onlyAuthor((graph_view.authorByKey("Zit Test\ntest@zync.invalid") orelse return error.AuthorMissing).key);
        try dvui.testing.settle(frameArrowCursor);
        graph_view.clearAuthors();
        askNameWith(.rename_branch, "main", "main");
        try dvui.testing.settle(frameArrowCursor);
        clearPrompt();
        ask(.discard, "a.txt");
        try dvui.testing.settle(frameArrowCursor);
        clearConfirm();
        try dvui.testing.settle(frameArrowCursor);
        dialog_views.closeRepo();
        try dvui.testing.settle(frameArrowCursor);
    }
}

test "a search fades the commits it leaves out, and the arrows go match to match" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for ([_][]const u8{ "one fix", "two", "three fix" }) |msg| {
        try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", msg });
    }
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    commit_filter.appendSlice(gpa, "fix") catch unreachable;
    try dvui.testing.settle(frameArrowCursor);

    // "two" is still in the graph, in its place.
    const h = history.?;
    var short: [8]u8 = undefined;
    const two = h.commits[1];
    try std.testing.expectEqualStrings("two", two.summary);
    var tag_buf: [16]u8 = undefined;
    try std.testing.expect(dvui.tagGet(try std.fmt.bufPrint(&tag_buf, "commit:{s}", .{git.oidShort(two.id, &short)})) != null);
    try std.testing.expectEqual(@as(usize, 2), graph_view.list_matches);

    stepCommit(1);
    try std.testing.expectEqualStrings("three fix", diff_view.commitSummary(selection.commit));
    stepCommit(1);
    try std.testing.expectEqualStrings("one fix", diff_view.commitSummary(selection.commit));
    // From a commit the search leaves out, the next match that way.
    selectCommit(two.id);
    stepCommit(-1);
    try std.testing.expectEqualStrings("three fix", diff_view.commitSummary(selection.commit));
}

// A commit picked lists its files without reading their lines — over
// thousands of files, reading them all froze the window for seconds — and
// one file opened is read alone.
test "a commit's files are listed without their lines, and the file open read alone" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "b.txt", .data = "b\nbb\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "two more" });
    openRepo(dir);
    defer dialog_views.closeRepo();
    const head = history.?.commits[0].id;

    var listed = try repo.?.readCommitDiffLines(gpa, head, .none);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 2), listed.files.len);
    for (listed.files) |f| {
        try std.testing.expectEqual(git.Status.added, f.status);
        try std.testing.expectEqual(@as(usize, 0), f.lines.len);
    }

    // Picked: its two files listed, no line read.
    selectCommit(head);
    ensureDiff();
    try std.testing.expectEqual(@as(usize, 2), diff_all.len);
    for (diff_all) |f| try std.testing.expectEqual(@as(usize, 0), f.lines.len);
    // One opened: its hunk header and its two lines, the list still whole.
    selectCommitFile(head, "b.txt");
    ensureDiff();
    try std.testing.expectEqual(@as(usize, 1), diff.?.files.len);
    try std.testing.expectEqualStrings("b.txt", diff.?.files[0].path);
    try std.testing.expectEqual(@as(usize, 3), diff.?.files[0].lines.len);
    try std.testing.expectEqual(@as(usize, 2), diff_all.len);
}

test "a commit's files: all of its tree, and an unchanged one read whole" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "first\nsecond\n");
    try tmp.dir.createDirPath(app_io, "sub");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "sub/b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "add b" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    const head = history.?.commits[0].id;
    selectCommit(head);
    ensureDiff();
    try std.testing.expectEqual(@as(usize, 1), diff_all.len);

    commit_view.loadTreeFiles(head);
    try std.testing.expectEqual(@as(usize, 2), commit_view.tree_files.paths.len);
    try std.testing.expectEqualStrings("a.txt", commit_view.tree_files.paths[0]);
    try std.testing.expectEqualStrings("sub/b.txt", commit_view.tree_files.paths[1]);
    try std.testing.expectEqual(git.Status.unchanged, commit_view.tree_files.status[0]);
    try std.testing.expectEqual(git.Status.added, commit_view.tree_files.status[1]);

    // The one it did not change: the file as it stood, every line context.
    selectCommitFile(head, "a.txt");
    ensureDiff();
    const f = diff.?.files[0];
    try std.testing.expectEqual(git.Status.unchanged, f.status);
    try std.testing.expectEqual(@as(usize, 2), f.lines.len);
    try std.testing.expectEqualStrings("second", f.lines[1].text);
    // The commit's own list is still its changes.
    try std.testing.expectEqual(@as(usize, 1), diff_all.len);
}

test "dragging a branch's tag in the graph onto another opens the drop menu" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    defer graph_view.clearDrop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "checkout", "-q", "-b", "feat" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on feat" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const from = try tagCenter("ref:feat");
    const to = try tagCenter("ref:main");
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    for (1..9) |i| {
        const f = @as(f32, @floatFromInt(i)) / 8;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + (to.x - from.x) * f, .y = from.y + (to.y - from.y) * f } });
        _ = try dvui.testing.step(frameArrowCursor);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrowCursor);

    const d = graph_view.drop orelse return error.NoDrop;
    try std.testing.expectEqualStrings("feat", d.source);
    try std.testing.expectEqualStrings("main", d.target);

    // A press on a tag that never moves is a click on its commit.
    graph_view.clearDrop();
    try clickAt(try tagCenter("ref:feat"));
    try std.testing.expect(graph_view.drop == null);
    try std.testing.expectEqualStrings("on feat", diff_view.commitSummary(selection.commit));
}

test "a long list of changes is built a screenful at a time, scrolls, and leaves the commit box in sight" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "staged.txt", .data = "s\n" });
    try expectGit(dir, &.{ "add", "staged.txt" });
    try tmp.dir.createDirPath(app_io, "src");
    const n = 600;
    for (0..n) |i| {
        var name: [32]u8 = undefined;
        try tmp.dir.writeFile(app_io, .{ .sub_path = try std.fmt.bufPrint(&name, "src/f-{d:0>4}.txt", .{i}), .data = "x\n" });
    }
    openRepo(dir);
    defer dialog_views.closeRepo();
    reloadWork();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, n), work.?.unstaged.len);

    // The commit box in the window, under the staged file.
    const button = try tagRect("commit_button");
    try std.testing.expect(button.y + button.h <= dvui.windowRectPixels().h);
    _ = try tagCenter("staged:staged.txt");
    // The first files built, the last not.
    _ = try tagCenter("unstaged:src/f-0000.txt");
    try expectNoTag("unstaged:src/f-0599.txt");

    // Its title folds it, as a sidebar section's does, and opens it again;
    // the staged list stays.
    try clickAt(try tagCenter("fold:unstaged"));
    try expectNoTag("unstaged:src/f-0000.txt");
    _ = try tagCenter("staged:staged.txt");
    try clickAt(try tagCenter("fold:unstaged"));
    _ = try tagCenter("unstaged:src/f-0000.txt");

    // Scrolled to the end: the last file, and the commit box where it was.
    commit_view.changes_scroll[0].viewport.y = commit_view.changes_scroll[0].scrollMax(.vertical);
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagCenter("unstaged:src/f-0599.txt");
    try std.testing.expectEqual(button.y, (try tagRect("commit_button")).y);

    // Most of them staged while it is scrolled to its end: the shorter list
    // draws, still scrolled past its end for a frame.
    try expectGit(dir, &.{ "add", "src/f-00*", "src/f-01*", "src/f-02*", "src/f-03*", "src/f-04*" });
    reloadWork();
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, 100), work.?.unstaged.len);
    // The file at the top of what is in view is drawn: f-0500 is row 0 now.
    {
        const in_view: usize = @intFromFloat(@ceil(commit_view.changes_scroll[0].viewport.y / style.row_height));
        try std.testing.expect(in_view < 100);
        var name: [40]u8 = undefined;
        _ = try tagCenter(try std.fmt.bufPrint(&name, "unstaged:src/f-{d:0>4}.txt", .{500 + in_view}));
    }

    // The tree: the folder's line first, the files set in under it.
    changes_view = .tree;
    defer changes_view = .path;
    commit_view.changes_scroll[0].viewport.y = 0;
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, 100 + 1), commit_view.changeRows(0, work.?.unstaged));
    const folder = try tagRect("unstaged:src/");
    const file = try tagRect("unstaged:src/f-0500.txt");
    try std.testing.expect(file.y > folder.y);

    // Folded by a click: one line, its files gone.
    try clickAt(.{ .x = folder.x + 40, .y = folder.y + folder.h / 2 });
    try std.testing.expectEqual(@as(usize, 1), commit_view.changeRows(0, work.?.unstaged));
    try expectNoTag("unstaged:src/f-0500.txt");

    // Its + stages the whole folder.
    try clickAt(.{ .x = folder.x + folder.w - 16, .y = folder.y + folder.h / 2 });
    try pumpJob();
    try std.testing.expectEqual(@as(usize, 0), work.?.unstaged.len);
    try std.testing.expectEqual(@as(usize, n + 1), work.?.staged.len);
}

test "a tree lists a folder's folders before its files, each by name, with what is in them" {
    gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const paths = [_][]const u8{ "b.txt", "a/z.txt", "a/b/c.txt", "A.md", "a/b/d.txt", "c/e.txt", "x/y/z/w.txt", "x/y/z/v.txt" };
    const rows = try commit_view.treeRows(arena.allocator(), &paths);

    const want = [_]struct { u16, []const u8, ?u32, u32, u32 }{
        .{ 0, "a", null, 4, 3 },
        .{ 1, "b", null, 2, 2 },
        .{ 2, "c.txt", 2, 0, 0 },
        .{ 2, "d.txt", 4, 0, 0 },
        .{ 1, "z.txt", 1, 0, 0 },
        .{ 0, "c", null, 1, 1 },
        .{ 1, "e.txt", 5, 0, 0 },
        // Folders holding one folder and nothing else: one line.
        .{ 0, "x/y/z", null, 2, 2 },
        .{ 1, "v.txt", 7, 0, 0 },
        .{ 1, "w.txt", 6, 0, 0 },
        .{ 0, "A.md", 3, 0, 0 },
        .{ 0, "b.txt", 0, 0, 0 },
    };
    try std.testing.expectEqual(want.len, rows.len);
    for (want, rows) |w, r| {
        try std.testing.expectEqual(w[0], r.depth);
        try std.testing.expectEqualStrings(w[1], r.name);
        try std.testing.expectEqual(w[2], r.file);
        try std.testing.expectEqual(w[3], r.inside);
        try std.testing.expectEqual(w[4], r.files);
    }
    try std.testing.expectEqualStrings("a/b", rows[1].path);
    // Folded by the deepest of them.
    try std.testing.expectEqualStrings("x/y/z", rows[7].path);

    // Folding "a" hides its four lines; the next shown is "c".
    var folded: std.StringHashMapUnmanaged(void) = .empty;
    defer folded.deinit(gpa);
    try folded.put(gpa, "a", {});
    var it: commit_view.TreeShown = .{ .rows = rows, .folded = &folded };
    try std.testing.expectEqualStrings("a", it.next().?.row.name);
    const c = it.next().?;
    try std.testing.expectEqualStrings("c", c.row.name);
    // The files folded away still count toward the next one's place.
    try std.testing.expectEqual(@as(u32, 3), c.pos);
}

test "a branch's name sits in the branch column, and dragging the column's edge shows more of it" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const name = "feature/a-branch-with-a-name-longer-than-its-column";
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "checkout", "-q", "-b", name });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on the branch" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // In the column, from its left, cut to it.
    const head = (dvui.tagGet("header:branches") orelse return error.TagNotFound).rect;
    const before = (dvui.tagGet("ref:" ++ name) orelse return error.TagNotFound).rect;
    try std.testing.expect(before.x >= head.x and before.x - head.x < 8);
    try std.testing.expect(before.x + before.w <= head.x + head.w);

    // The column's right edge, dragged to the right.
    const from: dvui.Point.Physical = .{ .x = head.x + head.w, .y = head.y + head.h / 2 };
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    for (1..9) |i| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + 15 * @as(f32, @floatFromInt(i)), .y = from.y } });
        _ = try dvui.testing.step(frameArrowCursor);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrowCursor);

    try std.testing.expect(search_view.branch_width > search_view.BRANCH_DEFAULT_W + 60);
    const after = (dvui.tagGet("ref:" ++ name) orelse return error.TagNotFound).rect;
    try std.testing.expect(after.w > before.w + 60);
    const wider = (dvui.tagGet("header:branches") orelse return error.TagNotFound).rect;
    try std.testing.expect(after.x + after.w <= wider.x + wider.w);
}

test "a hidden branch leaves the graph with its remote copy, and a hidden tag's name goes" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    // The tag alone on its commit, main moved on past it.
    try expectGit(dir, &.{ "tag", "v1" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "second" });
    try expectGit(dir, &.{ "checkout", "-q", "-b", "feat" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on feat" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    // Pushed: its remote copy at the same commit, and tracked.
    try expectGit(dir, &.{ "remote", "add", "origin", "https://example.invalid/zit.git" });
    try expectGit(dir, &.{ "update-ref", "refs/remotes/origin/feat", "feat" });
    try expectGit(dir, &.{ "branch", "-q", "-u", "origin/feat", "feat" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(findCommit("on feat") != null);
    _ = try tagCenter("ref:feat");
    _ = try tagCenter("ref:v1");

    // Its eye: the branch out, its remote copy with it — the commit only
    // they reach gone, and neither name drawn.
    graph_view.toggleHidden(findRef("feat") orelse return error.BranchNotListed);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(graph_view.isHidden("feat") and graph_view.isHidden("origin/feat"));
    try std.testing.expect(findCommit("on feat") == null);
    try expectNoTag("ref:feat");
    try expectNoTag("ref:origin/feat");

    // Back, both.
    graph_view.toggleHidden(findRef("feat") orelse return error.BranchNotListed);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(!graph_view.isHidden("feat") and !graph_view.isHidden("origin/feat"));
    try std.testing.expect(findCommit("on feat") != null);
    _ = try tagCenter("ref:feat");

    // A tag hidden: its commit is main's too and stays, its name does not.
    graph_view.toggleHidden(findRef("v1") orelse return error.TagNotListed);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(findCommit("base") != null);
    try expectNoTag("ref:v1");
}

test "the sidebar's eyes hide one ref or a whole section, and its ⋯ opens the menu" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });
    try expectGit(dir, &.{ "branch", "side" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("eye:feat"));
    try std.testing.expect(graph_view.isHidden("feat"));
    try clickAt(try tagCenter("eye:feat"));
    try std.testing.expect(!graph_view.isHidden("feat"));

    // The whole section out — the branch checked out stays — then back,
    // from the section's menu.
    try hoverAt(try tagCenter("section:LOCAL"));
    try clickAt(try tagCenter("section-more:LOCAL"));
    try clickAt(try tagCenter("menu:Hide all the branches from the graph"));
    try std.testing.expect(graph_view.isHidden("feat"));
    try std.testing.expect(graph_view.isHidden("side"));
    try std.testing.expect(!graph_view.isHidden("main"));
    try hoverAt(try tagCenter("section:LOCAL"));
    try clickAt(try tagCenter("section-more:LOCAL"));
    try clickAt(try tagCenter("menu:Show all the branches in the graph"));
    try std.testing.expectEqual(@as(usize, 0), graph_view.graph_hidden.items.len);

    try hoverAt(try tagCenter("feat"));
    try clickAt(try tagCenter("more:feat"));
    try std.testing.expect(dvui.tagGet("menu:Check out") != null);
    try pressFrame(.escape, .none);

    // A section header's ⋯ opens its right-click menu too, and the section
    // stays folded or open as it was.
    const open = diff_view.section_collapsed[@backingInt(diff_view.Section.local)];
    try hoverAt(try tagCenter("section:LOCAL"));
    try clickAt(try tagCenter("section-more:LOCAL"));
    _ = try tagCenter("menu:New branch here");
    try std.testing.expectEqual(open, diff_view.section_collapsed[@backingInt(diff_view.Section.local)]);
    try pressFrame(.escape, .none);

    // Signing, flipped beside the commit's title.
    const was = commit_prefs.sign;
    try clickAt(try tagCenter("commit:sign"));
    try std.testing.expect(commit_prefs.sign != was);
    commit_prefs.sign = was;
}

// A section of many branches builds only the lines on screen: scrolled to
// its end, the last branch is there and the first is not — and the hidden
// ones, a set, are still told apart.
test "a long section builds the lines it shows, wherever it is scrolled" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    // b00 … b59: sorted by name, b59 last.
    for (0..60) |i| {
        var name_buf: [8]u8 = undefined;
        try expectGit(dir, &.{ "branch", try std.fmt.bufPrint(&name_buf, "b{d:0>2}", .{i}) });
    }
    openRepo(dir);
    defer dialog_views.closeRepo();
    graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "b59");
    try std.testing.expect(graph_view.isHidden("b59") and !graph_view.isHidden("b58"));

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(dvui.tagGet("b00") != null);
    try std.testing.expect(dvui.tagGet("b59") == null);

    const si = &rebase_view.section_scroll[@backingInt(diff_view.Section.local)];
    si.viewport.y = si.virtual_size.h;
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(dvui.tagGet("b59") != null);
    try std.testing.expect(dvui.tagGet("b00") == null);
    // Its eye says hidden, from the set.
    try std.testing.expect(dvui.tagGet("eye:b59") != null);
}

test "dragging a tab onto another moves it there" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();

    tab_strip.loadWorkspace();
    var bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "a", "b", "c" }, 0..) |name, i| {
        try expectGit(root, &.{ "init", "-q", "-b", "main", name });
        tab_strip.openAndRemember(try std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ root, name }));
    }

    // See "dragging a branch row onto another opens the drop menu where it was let go".
    const frameArrow = struct {
        fn f() !dvui.App.Result {
            const r = try appFrame();
            dvui.currentWindow().cursor_requested = .arrow;
            dvui.currentWindow().dragging.cursor = null;
            return r;
        }
    }.f;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrow);

    const from = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect.center();
    const to = (dvui.tagGet("tab:2") orelse return error.TagNotFound).rect.center();
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrow);
    for (1..9) |i| {
        const f = @as(f32, @floatFromInt(i)) / 8;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + (to.x - from.x) * f, .y = from.y } });
        _ = try dvui.testing.step(frameArrow);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrow);

    const tabs = tab_strip.groups.items[0].tabs.items;
    try std.testing.expectEqualStrings("b", git.repoName(tabs[0].path));
    try std.testing.expectEqualStrings("c", git.repoName(tabs[1].path));
    try std.testing.expectEqualStrings("a", git.repoName(tabs[2].path));
    try std.testing.expectEqualStrings("c", repo_name);
}

// More tabs than the strip is wide: they scroll in what the strip leaves
// them, the window's own buttons stay in the window, and a tab switched to
// out of sight is scrolled to.
test "more tabs than fit scroll, and leave the window's buttons where they are" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();

    tab_strip.loadWorkspace();
    const names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa" };
    var bufs: [names.len][std.fs.max_path_bytes]u8 = undefined;
    for (names, 0..) |name, i| {
        try expectGit(root, &.{ "init", "-q", "-b", "main", name });
        tab_strip.openAndRemember(try std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ root, name }));
    }

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 700, .h = 600 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const close = (dvui.tagGet("window:close") orelse return error.TagNotFound).rect;
    try std.testing.expect(close.x + close.w <= dvui.windowRectPixels().w);
    const controls = (dvui.tagGet("window:minimise") orelse return error.TagNotFound).rect;

    // The last opened is the active one, and in sight: the strip scrolled to it.
    const last = (dvui.tagGet("tab:9") orelse return error.TagNotFound).rect;
    try std.testing.expect(last.x >= 0 and last.x + last.w <= controls.x);
    const first_before = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect;
    try std.testing.expect(first_before.x < 0);

    // Ctrl+Tab goes round to the first, scrolled back into sight.
    try pressFrame(.tab, .lcontrol);
    try std.testing.expectEqualStrings("alpha", repo_name);
    const first = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect;
    try std.testing.expect(first.x >= 0 and first.x + first.w <= controls.x);
}

// The seam is only a 1px line and the cursor, no grab handle; it must still
// drag.
test "the sidebar seam still drags" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    // Folded by default; these rows are what the test works on.
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();

    const frameArrow = struct {
        fn f() !dvui.App.Result {
            const r = try appFrame();
            dvui.currentWindow().cursor_requested = .arrow;
            dvui.currentWindow().dragging.cursor = null;
            return r;
        }
    }.f;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrow);

    // The seam is just right of the sidebar: find it from a branch row,
    // which spans the sidebar's width.
    const before = sidebar_split;
    const field = (dvui.tagGet("main") orelse return error.TagNotFound).rect;
    const cw = dvui.currentWindow();
    // Right of the field by its margin is the seam.
    var x = field.x + field.w;
    const y = field.y + 200;
    // Sweep right until a press there starts dragging the split.
    var moved = false;
    for (0..40) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
        _ = try cw.addEventMouseButton(.left, .press);
        _ = try dvui.testing.step(frameArrow);
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x + 60, .y = y } });
        _ = try dvui.testing.step(frameArrow);
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x + 120, .y = y } });
        _ = try dvui.testing.step(frameArrow);
        _ = try cw.addEventMouseButton(.left, .release);
        _ = try dvui.testing.step(frameArrow);
        if (sidebar_split != before) {
            moved = true;
            break;
        }
        x += 1;
    }
    try std.testing.expect(moved);
    try std.testing.expect(sidebar_split > before);
}

// The asynchronous first read, which the app uses and the rest of the suite
// does not: it lands, it is the history that was asked for, and the loading
// screen draws while it is out.
test "a history read off the UI thread lands in place of the loading screen" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    openRepo(dir);
    defer dialog_views.closeRepo();
    if (history) |*h| h.deinit();
    history = null;
    if (lanes) |*l| l.deinit();
    lanes = null;

    // Asked for twice, as a quick tab switch does: the first is not awaited
    // but left to finish, and freed once it has.
    graph_view.startHistoryLoad();
    graph_view.startHistoryLoad();
    defer {
        graph_view.history_retired.deinit(gpa);
        graph_view.history_retired = .empty;
    }
    try std.testing.expect(historyLoading());
    {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
        defer t.deinit();
        try style.applyEmbedded(gpa, true);
        // The loading screen refreshes itself, so this is a frame, not a settle.
        _ = try dvui.testing.step(appFrame);
    }

    var waited: usize = 0;
    while ((graph_view.collectHistoryLoad() or graph_view.history_retired.items.len > 0) and waited < 500) : (waited += 1) {
        try std.Io.sleep(app_io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(graph_view.history_load == null);
    try std.testing.expectEqual(@as(usize, 0), graph_view.history_retired.items.len);
    try std.testing.expect(findCommit("base") != null);
    try std.testing.expect(lanes != null);
}

test "the identity dialog saves a name and email to the global config" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = try absPath(&abs_buf, root);

    // A global config of the test's own, empty: a machine nobody set up.
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/gitconfig", .{abs_root});
    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = cfg, .data = "" });
    var env = try isolatedEnv(cfg, abs_root);
    defer env.deinit();
    run.env_override = &env;
    defer run.env_override = null;

    try std.testing.expect(!identitySet());
    openIdentity();
    try std.testing.expect(identity_open);

    // Half of it is refused, and the dialog stays.
    try identity_name.appendSlice(gpa, "Ada Lovelace");
    saveIdentity();
    try std.testing.expect(identity_open);

    try identity_email.appendSlice(gpa, "ada@example.com");
    saveIdentity();
    try std.testing.expect(!identity_open);
    try std.testing.expect(identitySet());

    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(gpa);
    var email: std.ArrayList(u8) = .empty;
    defer email.deinit(gpa);
    try std.testing.expect(readIdentity(&name, &email));
    try std.testing.expectEqualStrings("Ada Lovelace", name.items);
    try std.testing.expectEqualStrings("ada@example.com", email.items);
}

/// An environment for git with nothing of the machine's in it but PATH: its
/// global config is `cfg`, its home is `home`, so neither the identity nor
/// the signing settings of whoever runs the suite leak in.
fn isolatedEnv(cfg: []const u8, home: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    try env.put("PATH", std.mem.span(std.c.getenv("PATH") orelse "/usr/bin:/bin"));
    try env.put("HOME", home);
    try env.put("GIT_CONFIG_GLOBAL", cfg);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    return env;
}

// Closing a tab is not forgetting: the repository moves to the recent list,
// survives a restart there, and only the start page's × — after a yes —
// takes it away.
test "a closed tab is remembered, and only forgetting removes it" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);
    const path = try gpa.dupe(u8, repo_path.items);
    defer gpa.free(path);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);

    tab_strip.closeTab(0);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.recent.items.len);
    try std.testing.expectEqualStrings(path, tab_strip.recent.items[0]);

    // Through a restart.
    forgetTabs();
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 1), tab_strip.recent.items.len);

    // Opened again: a tab, so not also a recent one.
    tab_strip.openAndRemember(path);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);
    tab_strip.closeTab(0);

    dialog_views.askForget(path);
    requestAction(.forget);
    try std.testing.expect(runAction());
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);
    try std.testing.expect(dialog_views.forget_path == null);
    // Nothing on disk went with it.
    try expectGit(a, &.{ "rev-parse", "--git-dir" });

    // Opened again while it is a tab of another group: that tab, not a second.
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    const b_path = try gpa.dupe(u8, repo_path.items);
    defer gpa.free(b_path);
    tab_strip.groupTab("Side", 0, 1);
    tab_strip.selectTabIn(0, 0);
    tab_strip.openAndRemember(b);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_group);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);

    // Forgotten while it is the only tab of the active group and a tab of
    // another one too: the group goes, and what opens is not b again.
    try tab_strip.groups.items[0].tabs.append(gpa, .{ .path = try gpa.dupe(u8, b_path) });
    tab_strip.forgetRepo(b_path);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);
    try std.testing.expectEqualStrings("a", repo_name);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);

    // Forgotten while the only tab of a group that is not the active one: no
    // empty group left behind.
    tab_strip.openAndRemember(b);
    tab_strip.groupTab("Solo", 0, 1);
    tab_strip.selectTabIn(0, 0);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    tab_strip.forgetRepo(b_path);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("a", repo_name);
}

/// One frame with the cursor pinned to the arrow: the dummy video driver logs
/// an error for every cursor change, and a logged error fails the test.
fn frameArrowCursor() !dvui.App.Result {
    const r = try appFrame();
    dvui.currentWindow().cursor_requested = .arrow;
    dvui.currentWindow().dragging.cursor = null;
    return r;
}

/// A real click — press and release, a frame each — at `p`, then let the
/// action it asked for run.
fn clickAt(p: dvui.Point.Physical) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = p });
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrowCursor);
}

// The buttons inside a file row, clicked the way a person clicks them. A row
// is itself a button, and a button nested in one can lose the press to it —
// which builds, renders and does nothing.
test "the stage and unstage buttons on a file row work when clicked" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a.txt", .data = "changed\n" });

    openRepo(dir);
    defer dialog_views.closeRepo();
    defer clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Stage: the last icon on the unstaged row, at its right edge.
    {
        const row = (dvui.tagGet("unstaged:a.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16, .y = row.y + row.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 1), work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 0), work.?.unstaged.len);

    // And unstage, from the staged row.
    {
        const row = (dvui.tagGet("staged:a.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16, .y = row.y + row.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 0), work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 1), work.?.unstaged.len);
}

/// Where `tag` is on screen; says which when it is not.
fn tagRect(tag: []const u8) !dvui.Rect.Physical {
    const data = dvui.tagGet(tag) orelse {
        std.debug.print("tag \"{s}\" not on screen\n", .{tag});
        return error.TagNotFound;
    };
    return data.rect;
}

/// `tag` not drawn this frame; says which when it is.
fn expectNoTag(tag: []const u8) !void {
    if (dvui.tagGet(tag) != null) {
        std.debug.print("tag \"{s}\" on screen, and should not be\n", .{tag});
        return error.TagOnScreen;
    }
}

/// The centre of a tagged widget, failing the test if it is not on screen.
fn tagCenter(tag: []const u8) !dvui.Point.Physical {
    const data = dvui.tagGet(tag) orelse {
        std.debug.print("tag \"{s}\" not on screen\n", .{tag});
        return error.TagNotFound;
    };
    return data.rect.center();
}

/// Two clicks inside the double-click window: a frame is 100ms in the test
/// window, so they go a frame apart rather than through `clickAt`'s settle.
fn doubleClickAt(p: dvui.Point.Physical) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = p });
    _ = try dvui.testing.step(frameArrowCursor);
    for (0..2) |_| {
        _ = try cw.addEventMouseButton(.left, .press);
        _ = try dvui.testing.step(frameArrowCursor);
        _ = try cw.addEventMouseButton(.left, .release);
        _ = try dvui.testing.step(frameArrowCursor);
    }
    try dvui.testing.settle(frameArrowCursor);
}

/// The mouse moved onto `p`, and the frames that follow drawn.
fn hoverAt(p: dvui.Point.Physical) !void {
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = p });
    try dvui.testing.settle(frameArrowCursor);
}

fn rightClickAt(p: dvui.Point.Physical) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = p });
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.right, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.right, .release);
    try dvui.testing.settle(frameArrowCursor);
}

fn pressFrame(code: dvui.enums.Key, mod: dvui.enums.Mod) !void {
    try dvui.testing.pressKey(code, mod);
    try dvui.testing.settle(frameArrowCursor);
}

fn typeText(text: []const u8) !void {
    try dvui.testing.writeText(text);
    try dvui.testing.settle(frameArrowCursor);
}

// Every control a day of work goes through, driven by mouse and keyboard and
// checked against git: the function-level tests prove the commands, this
// proves the clicks reach them.
test "audit: the main controls do what they say when clicked" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    // Folded by default; these rows are what the test works on.
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b", .{root});

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer clearCommandError();

    try tmp.dir.createDirPath(app_io, "a");
    try makeTestRepo(&tmp, a, "a/one.txt", "one\n");
    try expectGit(a, &.{ "branch", "feat" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(b);
    tab_strip.openAndRemember(a);
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a/one.txt", .data = "one, edited\n" });
    try tmp.dir.writeFile(app_io, .{ .sub_path = "a/two.txt", .data = "two\n" });
    reloadWork();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Toolbar: Stash takes both changes away, Pop brings them back.
    try clickAt(try tagCenter("toolbar:Stash"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 1), history.?.stashes.len);
    try std.testing.expectEqual(@as(usize, 0), search_view.changeCount());
    try clickAt(try tagCenter("toolbar:Pop"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 0), history.?.stashes.len);
    try std.testing.expectEqual(@as(usize, 2), work.?.unstaged.len);

    // Stage all — a job — and Unstage all.
    try clickAt(try tagCenter("link:stage_all"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 2), work.?.staged.len);
    try clickAt(try tagCenter("link:unstage_all"));
    try std.testing.expectEqual(@as(usize, 0), work.?.staged.len);

    // A file opens its diff in the centre, the graph view staying the view;
    // Split, and back to the graph by the button.
    {
        const row = (dvui.tagGet("unstaged:two.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + 60, .y = row.y + row.h / 2 });
    }
    try std.testing.expect(diffOpen());
    try std.testing.expectEqual(View.graph, active_view);
    try clickAt(try tagCenter("diff:split"));
    try std.testing.expect(diff_view.diff_split);
    try clickAt(try tagCenter("diff:unified"));
    closeDiff();
    try std.testing.expect(!diffOpen());

    // A commit, then the uncommitted-changes row brings the changes back.
    selectCommit(findCommit("base").?.id);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("wip_row"));
    try std.testing.expectEqual(Selection.none, std.meta.activeTag(selection));

    // Discard one file through its trash icon and the confirmation: the
    // trash sits left of the stage icon.
    {
        const row = (dvui.tagGet("unstaged:one.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16 - 26, .y = row.y + row.h / 2 });
    }
    try std.testing.expect(confirm != null);
    try clickAt(try tagCenter("confirm:yes"));
    try std.testing.expectEqual(@as(usize, 1), work.?.unstaged.len);
    try std.testing.expectEqualStrings("two.txt", work.?.unstaged[0].path);

    // Stage it, type a summary, commit — by the button.
    {
        const row = (dvui.tagGet("unstaged:two.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16, .y = row.y + row.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 1), work.?.staged.len);
    try clickAt(try tagCenter("commit_summary"));
    try typeText("audit commit");
    try std.testing.expectEqualStrings("audit commit", commit_summary.items);
    try clickAt(try tagCenter("commit_button"));
    // A commit is a job: waited for, as Stash and Stage all are. The
    // frames of the click alone were sometimes over before git was —
    // the commit not in the history yet, the job left running into the
    // next test.
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findCommit("audit commit") != null);
    try std.testing.expectEqual(@as(usize, 0), commit_summary.items.len);

    // Undo it from the toolbar: gone, its file staged again.
    try clickAt(try tagCenter("toolbar:Undo"));
    try std.testing.expect(findCommit("audit commit") == null);
    try std.testing.expectEqual(@as(usize, 1), work.?.staged.len);

    // Right-click a branch, rename it from the menu through its dialog.
    try rightClickAt(try tagCenter("feat"));
    try clickAt(try tagCenter("menu:Rename…"));
    try std.testing.expect(prompt != null);
    try std.testing.expectEqualStrings("feat", prompt_text.items);
    try typeText("ure");
    try clickAt(try tagCenter("prompt:go"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("feature") != null);

    // Double-click a branch to check it out.
    try doubleClickAt(try tagCenter("feature"));
    try pumpJobFrame();
    try std.testing.expectEqualStrings("feature", history.?.head.?);

    // The palette: Ctrl+P, a few letters, Enter.
    try pressFrame(.p, .lcontrol);
    try std.testing.expect(palette_open);
    try typeText("stash ever");
    try pressFrame(.enter, .none);
    try std.testing.expect(!palette_open);
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 1), history.?.stashes.len);

    // Settings from the menu on the face: switch to the light theme, Esc out.
    try clickAt(try tagCenter("toolbar:user"));
    try clickAt(try tagCenter("menu:Settings — Ctrl+,"));
    try std.testing.expect(settings_open);
    try clickAt(try tagCenter("settings:Appearance"));
    try clickAt(try tagCenter("theme:Zit Light"));
    try std.testing.expect(!dark_theme);
    try pressFrame(.escape, .none);
    try std.testing.expect(!settings_open);

    // The keys, from the footer.
    try clickAt(try tagCenter("status:keys"));
    try std.testing.expect(keys_open);
    try pressFrame(.escape, .none);
    try std.testing.expect(!keys_open);

    // Tabs: the other one, then its × — closed, and remembered.
    try clickAt(try tagCenter("tab:0"));
    try std.testing.expect(std.mem.endsWith(u8, repo_path.items, "/b/"));
    {
        const name = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = name.x + name.w + 12, .y = name.y + name.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 1), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.recent.items.len);

    // A new tab, and the Clone card on its page opens the dialog.
    try pressFrame(.t, .lcontrol);
    try std.testing.expect(new_tab_open);
    try clickAt(try tagCenter("start:Clone"));
    try std.testing.expectEqual(dialog_views.RepoDialog.clone, dialog_views.repo_dialog);
    try clickAt(try tagCenter("dialog:Cancel"));
    try std.testing.expectEqual(dialog_views.RepoDialog.none, dialog_views.repo_dialog);
}

// The code GitHub hands out, big enough to copy by eye, in a dialog that
// keeps its width. Nothing here reaches GitHub: the flow is set, not started.
test "the connect dialog shows the code and keeps its width" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 700 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    try style.applyEmbedded(gpa, true);
    defer resetUiGlobals();
    defer {
        closeConnect();
        connect_code.deinit(gpa);
        connect_code = .empty;
        connect_note.deinit(gpa);
        connect_note = .empty;
    }

    connect_open = true;
    connect_rect = .{};
    connect_state = .waiting;
    try connect_code.appendSlice(gpa, "ABCD-1234");
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(connect_rect.w <= 440);

    // A failure says why, and Cancel closes.
    connectFailed("GitHub did not accept the sign-in.");
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(dvui.tagGet("dialog:Try again") != null);
    try clickAt(try tagCenter("dialog:Cancel"));
    try std.testing.expect(!connect_open);
}

test "a long message is cut with an ellipsis, a short one left alone" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 200 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    try style.applyEmbedded(gpa, true);
    const font = style.graphText();
    var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;

    try std.testing.expectEqualStrings("short", graph_view.fitText(&buf, "short", font, 500));
    const long = "feat(parser): handle every edge case anybody has ever thought of, twice";
    const cut = graph_view.fitText(&buf, long, font, 120);
    try std.testing.expect(std.mem.endsWith(u8, cut, "…"));
    try std.testing.expect(cut.len < long.len);
    try std.testing.expect(font.textSize(cut).w <= 120);
    // Never inside a UTF-8 sequence.
    try std.testing.expect(std.unicode.utf8ValidateSlice(graph_view.fitText(&buf, "éééééééééééééééééééééééé", font, 40)));
}

test "the split view sets each removed line against the line that replaced it" {
    gpa = std.testing.allocator;
    defer resetUiGlobals();
    var lines = [_]git.DiffLine{
        .{ .kind = .hunk_header, .text = "@@ -1,4 +1,3 @@", .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .context, .text = "a", .old_no = 1, .new_no = 1, .hunk = 0 },
        .{ .kind = .deletion, .text = "b", .old_no = 2, .new_no = 0, .hunk = 0 },
        .{ .kind = .deletion, .text = "c", .old_no = 3, .new_no = 0, .hunk = 0 },
        .{ .kind = .addition, .text = "B", .old_no = 0, .new_no = 2, .hunk = 0 },
        .{ .kind = .context, .text = "d", .old_no = 4, .new_no = 3, .hunk = 0 },
    };
    var files = [_]git.FileDiff{.{ .path = "f", .old_path = "f", .status = .modified, .lines = &lines, .hunk_count = 1, .binary = false }};
    diff = .{ .arena = .init(gpa), .files = &files };
    defer {
        diff.?.arena.deinit();
        diff = null;
    }
    diff_view.buildSplitRows();

    const r = diff_view.split_rows.items;
    // file (two rows high), hunk, a|a, b|B, c|-, d|d
    try std.testing.expectEqual(@as(usize, 7), r.len);
    try std.testing.expect(r[1].kind == .pad);
    try std.testing.expectEqual(@as(u32, 2), r[4].left);
    try std.testing.expectEqual(@as(u32, 4), r[4].right);
    try std.testing.expectEqual(@as(u32, 3), r[5].left);
    try std.testing.expectEqual(diff_view.NO_LINE, r[5].right);
    try std.testing.expectEqual(@as(u32, 5), r[6].left);
}

test "a commit date reads as a date, and fits its column" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 200 } });
    defer t.deinit();
    gpa = std.testing.allocator;
    try style.applyEmbedded(gpa, true);
    var buf: [32]u8 = undefined;
    const text = search_view.absoluteTime(&buf, 1_761_000_000);
    try std.testing.expectEqual(@as(usize, 16), text.len);
    try std.testing.expectEqual(@as(u8, '-'), text[4]);
    try std.testing.expectEqual(@as(u8, ':'), text[13]);
    try std.testing.expect(style.graphMono().textSize("2026-10-21 18:05").w <= style.time_column);
}

test "a commit's files: only the rows in sight are built, however many" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for (0..300) |i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(app_io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d:0>3}.txt", .{i}), .data = "x\n" });
    }
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "three hundred" });
    openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    selectCommit(history.?.commits[0].id);
    try dvui.testing.settle(frameArrowCursor);

    // The first of the 300 built, the last not: the pane shows a few dozen.
    _ = try tagCenter("file:f000.txt");
    try expectNoTag("file:f299.txt");

    // Scrolled to the end of the pane: the other way round.
    commit_view.commit_scroll.viewport.y = commit_view.commit_scroll.scrollMax(.vertical);
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagCenter("file:f299.txt");
    try expectNoTag("file:f000.txt");
}

test "the authors' menu builds the rows in sight, and its search still finds the rest" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for (0..60) |i| {
        var name: [32]u8 = undefined;
        var mail: [48]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "user.name=A{d:0>2}", .{i});
        const m = try std.fmt.bufPrint(&mail, "user.email=a{d:0>2}@x.invalid", .{i});
        try expectGit(dir, &.{ "-c", n, "-c", m, "commit", "-q", "--allow-empty", "-m", "c" });
    }
    openRepo(dir);
    defer dialog_views.closeRepo();

    // Wide: the author column only shows with room left for the messages,
    // whatever widths the tests before this one left.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1900, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Newest first: the last to commit is in sight, the first is not built.
    try clickAt(try tagCenter("header:author"));
    _ = try tagCenter("author:A59");
    try expectNoTag("author:A00");
    // Asked for by name, it is the one row.
    try typeText("A00");
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagCenter("author:A00");
    try expectNoTag("author:A59");
}

test "changes picked: asked by path, taken off again, one side at a time" {
    gpa = std.testing.allocator;
    defer resetUiGlobals();
    commit_view.toggleChangePick(.unstaged, "a.txt");
    commit_view.toggleChangePick(.unstaged, "b.txt");
    try std.testing.expect(commit_view.isChangePicked(.unstaged, "a.txt"));
    try std.testing.expect(commit_view.isChangePicked(.unstaged, "b.txt"));
    try std.testing.expect(!commit_view.isChangePicked(.staged, "a.txt"));

    // Picked again: off, in the list and in the set alike.
    commit_view.toggleChangePick(.unstaged, "a.txt");
    try std.testing.expect(!commit_view.isChangePicked(.unstaged, "a.txt"));
    try std.testing.expectEqual(@as(usize, 1), commit_view.picked_changes.items.len);
    const changes = [_]git.Change{
        .{ .path = "a.txt", .old_path = "a.txt", .status = .modified },
        .{ .path = "b.txt", .old_path = "b.txt", .status = .modified },
    };
    try std.testing.expectEqual(@as(usize, 1), commit_view.pickedIn(.unstaged, &changes));

    // The other side's pick starts over.
    commit_view.toggleChangePick(.staged, "c.txt");
    try std.testing.expect(!commit_view.isChangePicked(.unstaged, "b.txt"));
    try std.testing.expect(commit_view.isChangePicked(.staged, "c.txt"));
    commit_view.clearPickedChanges();
    try std.testing.expect(!commit_view.isChangePicked(.staged, "c.txt"));
    try std.testing.expectEqual(@as(u32, 0), commit_view.picked_set.count());
}

test "a repository's own settings are written to its config and read back" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    openRepo(dir);
    defer dialog_views.closeRepo();
    repo_settings_path.appendSlice(gpa, dir) catch unreachable;

    setLocalConfig("user.name", "Work Me");
    setLocalConfig("pull.ff", "only");
    setLocalConfig("commit.gpgsign", "false");
    while (!repo_prefs_loaded) loadRepoPrefs();
    try std.testing.expectEqualStrings("Work Me", repo_name_local.items);
    try std.testing.expect(repo_pull == .ff_only);
    try std.testing.expect(repo_sign == .off);
    try std.testing.expect(repo_prune == .global);

    // Back to as everywhere: unset, and nothing said about it.
    setLocalConfig("pull.ff", "");
    setLocalConfig("pull.ff", "");
    while (!repo_prefs_loaded) loadRepoPrefs();
    try std.testing.expect(repo_pull == .global);
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
}

test "a summary typed past 72 goes on in the description, and says so" {
    gpa = std.testing.allocator;
    app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(gpa, true);
    openRepo(dir);
    defer dialog_views.closeRepo();
    try dvui.testing.settle(frameArrowCursor);

    // Key by key, as it is typed: the move happens mid-word, and the rest of
    // the word follows it into the description.
    try clickAt(try tagCenter("commit_summary"));
    for ("Settings for this repository, and a file opened in your editor of choice today") |ch| try typeText(&.{ch});
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqualStrings("Settings for this repository, and a file opened in your editor of choice", commit_summary.items);
    try std.testing.expectEqualStrings("today", commit_description.items);
    try std.testing.expect(commit_view.summary_moved);
    try std.testing.expect(dvui.tagGet("commit:drop_stop") == null);

    // A full stop is pointed out, and dropped in a click.
    commit_summary.clearRetainingCapacity();
    commit_description.clearRetainingCapacity();
    try commit_summary.appendSlice(gpa, "Fix the parser.");
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("commit:drop_stop"));
    try std.testing.expectEqualStrings("Fix the parser", commit_summary.items);
}

// The documentation's screenshots, of a made-up repository: run by
// scripts/screenshots.sh, which makes the repository first and sets
// ZIT_SHOTS; skipped otherwise, so the suite never writes into the tree.
test "docs screenshots" {
    if (std.c.getenv("ZIT_SHOTS") == null) return error.SkipZigTest;
    gpa = std.heap.c_allocator;
    app_io = std.testing.io;
    try git.init();
    defer git.shutdown();
    diff_view.section_collapsed = @splat(false);
    diff_view.section_collapsed[@backingInt(diff_view.Section.tags)] = true;
    stillUi();
    try window_chrome.me_name.appendSlice(gpa, "Alice Martin");
    try window_chrome.me_email.appendSlice(gpa, "alice@acme.dev");
    window_chrome.me_loaded = true;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1440, .h = 900 }, .allocator = std.heap.c_allocator });
    defer t.deinit();
    const demo = "/tmp/acme-web";
    try tab_strip.recent.append(gpa, try gpa.dupe(u8, "/home/alice/dev/acme-api/"));
    try tab_strip.recent.append(gpa, try gpa.dupe(u8, "/home/alice/dev/design-system/"));

    for ([_]bool{ true, false }) |dark| {
        dark_theme = dark;
        theme_index = if (dark) 0 else 1;
        applyTheme();
        const sfx: []const u8 = if (dark) "dark" else "light";
        openRepo(demo);
        clearSelection();
        try docShot("zit", sfx);
        if (!dark) {
            dialog_views.closeRepo();
            continue;
        }
        const h = history.?;
        selectCommit(h.commits[3].id);
        try docShot("commit", sfx);
        // The commit that validates the login's email: a diff worth reading.
        for (h.commits) |c| if (std.mem.eql(u8, c.summary, "WEB-12: validate the email field")) {
            selectCommit(c.id);
            try docShot("zz", sfx);
            selectCommitFile(c.id, "src/components/Login.tsx");
        };
        try docShot("diff", sfx);
        selectChange("src/components/Search.tsx", .unstaged);
        try commit_summary.appendSlice(gpa, "WEB-18: keyboard navigation in the results");
        try docShot("changes", sfx);
        commit_summary.clearRetainingCapacity();
        clearSelection();
        graph_view.search_open = true;
        try commit_filter.appendSlice(gpa, "author:chloe");
        try docShot("search", sfx);
        commit_filter.clearRetainingCapacity();
        graph_view.search_open = false;
        palette_open = true;
        try docShot("palette", sfx);
        palette_open = false;
        openSettings(0);
        try docShot("settings-appearance", sfx);
        settings_open = false;
        try docShot("zz", sfx);
        openSettings(REPO_PAGE);
        try docShot("settings-repository", sfx);
        settings_open = false;
        features_open = true;
        features_page = 0;
        try docShot("about", sfx);
        features_open = false;
        new_tab_open = true;
        try docShot("start", sfx);
        new_tab_open = false;
        dialog_views.closeRepo();
    }
}

/// One screenshot for the documentation, once the frame has settled:
/// docs/screenshots/{name}-{theme}.png, or {name}.png for the dark one of
/// the home page's pair.
fn docShot(name: []const u8, sfx: []const u8) !void {
    for (0..12) |_| try dvui.testing.settle(frameArrowCursor);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 20);
    defer out.deinit();
    try dvui.testing.capturePng(frameArrowCursor, null, &out.writer);
    var path: [256]u8 = undefined;
    // A shot only to let the frame before settle: not kept.
    if (std.mem.eql(u8, name, "zz")) return;
    const p = try std.fmt.bufPrint(&path, "docs/screenshots/{s}-{s}.png", .{ name, sfx });
    try std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = p, .data = out.written() });
}

test "a column dragged as wide as it may go hides none" {
    defer resetUiGlobals();
    const saved = .{ graph_scroll.viewport.w, graph_view.col_author, graph_view.col_sha, graph_view.col_time };
    defer {
        graph_scroll.viewport.w = saved[0];
        graph_view.col_author = saved[1];
        graph_view.col_sha = saved[2];
        graph_view.col_time = saved[3];
    }
    graph_scroll.viewport.w = 1200;
    graph_view.col_author += graph_view.messageSpare();
    try std.testing.expect(graph_view.columnsShown().author and graph_view.columnsShown().sha);
    try std.testing.expectEqual(@as(f32, 0), graph_view.messageSpare());
    // A pixel past the cap: the sha goes, as it did under the drag.
    graph_view.col_author += 1;
    try std.testing.expect(!graph_view.columnsShown().sha);
}
