//! Zit — a desktop git client.
//!
//! Reads go through libgit2 (`git/git.zig`), writes through the `git` binary
//! (`core/run.zig`), the graph's lanes are computed in `git/graph.zig`, and
//! every visual value lives in `ui/style.zig`. Each screen has its file in
//! `ui/`, GitHub's side in `github/`; what is left here is the app's state,
//! its start and its frame. The tests are in `tests.zig`.

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
const identity_view = @import("ui/identity_view.zig");
const repo_settings = @import("ui/repo_settings.zig");
const command_palette = @import("ui/command_palette.zig");
const home_page = @import("ui/home_page.zig");
const repo_io = @import("core/repo_io.zig");
const github_actions = @import("github/github_actions.zig");
const github_connect = @import("github/github_connect.zig");
const pr_list = @import("ui/pr_list.zig");
const pr_conversation = @import("ui/pr_conversation.zig");
const pr_editor = @import("ui/pr_editor.zig");
const pr_create = @import("ui/pr_create.zig");
const app_tests = @import("tests.zig");

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
        if (repo_io.mallopt) |set| _ = set(repo_io.M_ARENA_MAX, 1);
        // A fixed mmap threshold: glibc's moves up to whatever large block
        // was last freed — up to 32 MB — and the next ones come out of the
        // heap instead, where a free gives nothing back until a trim. Fixed,
        // a snapshot's arena pages or a big diff are their own mapping, and
        // their free is the system's at once.
        if (repo_io.mallopt) |set| _ = set(repo_io.M_MMAP_THRESHOLD, 128 * 1024);
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
pub const APP_VERSION = std.fmt.comptimePrint("{s}", .{@import("build_options").version});

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
pub var show_sidebar: bool = true;
pub var show_detail: bool = true;
/// What a hidden panel's seam points at instead: no room on that side. The
/// paned widget writes through it while dragging, so these are not consts.
var no_split: f32 = 0;
pub var all_split: f32 = 1;
/// The new-tab page — GitKraken's "open, clone or start a repository" —
/// over whatever is open, until a repository is picked or it is closed.
pub var new_tab_open: bool = false;
/// The pull requests: a tab of their own, always at the strip's right end
/// on a host that has them, showing when `active_view` is `.pulls`.
pub fn openPulls() void {
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
pub const Confirm = struct {
    kind: Kind,
    /// Path, stash commit or sha the action applies to. Empty where the kind needs
    /// no argument, which is what "discard everything" is.
    arg: []u8,

    pub const Kind = enum {
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

pub var confirm: ?Confirm = null;

/// A name Zit needs before it can run something, in the same slot and for the
/// same reason: a modal over the graph hides the thing you are naming.
pub const Prompt = struct {
    kind: Kind,
    /// The commit a branch or tag is created at. Empty means HEAD.
    arg: []u8,

    pub const Kind = enum {
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
pub const Selection = union(enum) {
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
pub const MAX_RESOLVE_UNDO = 1000;

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
pub var rebase_arena: ?std.heap.ArenaAllocator = null;
/// Full sha of the commit the list replays onto — the one below the oldest
/// step, left exactly where it is; seven characters can name two commits. Empty when `rebase_root` says there is none.
pub var rebase_base: [41]u8 = undefined;
pub var rebase_base_len: usize = 0;
pub var rebase_root: bool = false;

/// Most commits Zit will put into one interactive rebase.
///
/// ponytail: a cap, not paging. A rebase longer than this is not one anybody
/// composes by clicking, and the list is built by walking first parents.
pub const MAX_REBASE_STEPS: usize = 200;

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
pub fn diffOpen() bool {
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

pub fn clearRebase() void {
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
pub fn selectedAbsPath(buf: []u8) ?[]const u8 {
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
        github_actions.setCommandError("Could not read that file.");
        return clearSelection();
    };
    defer gpa.free(text);

    blame_view = r.readBlame(gpa, selected_path.items, text) catch {
        github_actions.setCommandError("git has no history for that file yet.");
        return clearSelection();
    };
}

/// Read the conflicted file and find its regions.
///
/// Straight off disk, markers and all: that is where git leaves a conflict and
/// where an editor would resolve one, so it is the one copy everything agrees
/// on.
pub fn loadConflicts() void {
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
        if (conflict_kind != .deleted_by_us and conflict_kind != .deleted_by_them) github_actions.setCommandError("Could not read that conflicted file.");
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
        .change => |side| r.readWorkDiffFrom(gpa, side, selected_path.items, github_actions.oldPathOf(side, selected_path.items)) catch return clearSelection(),
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
    repo_io.stillUi();

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
    repo_io.initStatusCache(init.environ_map.*);
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
    if (window_chrome.me_name.items.len == 0 or window_chrome.me_email.items.len == 0) identity_view.openIdentity();
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
pub fn applyTheme() void {
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
    if (repo_io.work_load) |load| load.free();
    repo_io.work_load = null;
    dialog_views.closeRepo();
    repo_io.status_cache_file.deinit(gpa);
    git.shutdown();
    avatars.deinit();
    pr.deinit();
    // Before its paths go: a call still out finishes first.
    if (github_actions.api_job) |w| w.deinit(app_io);
    github_actions.api_job = null;
    github_actions.clearApiQueue();
    github_actions.api_queue.deinit(gpa);
    github_actions.api_reviewers.deinit(gpa);
    github_actions.api_assignees.deinit(gpa);
    github_actions.api_labels.deinit(gpa);
    github_actions.repo_slug.deinit(gpa);
    github_actions.clearJobSteps();
    github_actions.job_steps.deinit(gpa);
    github_connect.closeConnect();
    for ([_]*std.ArrayList(u8){ &github_connect.connect_code, &github_connect.connect_device, &github_connect.connect_uri, &github_connect.connect_note }) |l| l.deinit(gpa);
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
    github_actions.clearCommandError();
    github_actions.clearConfirm();
    github_actions.clearPrompt();
    prompt_text.deinit(gpa);
    clearSelection();
    rebase_steps.deinit(gpa);
    selected_path.deinit(gpa);
    github_actions.clone_dest.deinit(gpa);
    graph_view.clearFileHistory();
    graph_view.file_history.deinit(gpa);
    command_palette.palette_text.deinit(gpa);
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
    identity_view.signing_key.deinit(gpa);
    if (identity_view.signing_job) |j| j.deinit(app_io);
    if (repo_settings.repo_prefs_job) |j| j.deinit(app_io);
    repo_settings.repo_name_local.deinit(gpa);
    repo_settings.repo_email_local.deinit(gpa);
    repo_settings.repo_settings_path.deinit(gpa);
    if (repo_settings.editors_job) |j| j.deinit(app_io);
    if (commit_view.repo_config_job) |j| j.deinit(app_io);
    commit_view.git_template_path.deinit(gpa);
    github_actions.commit_sent.deinit(gpa);
    tab_strip.clearRecent();
    tab_strip.recent.deinit(gpa);
    dialog_views.clearForget();
    identity_view.identity_name.deinit(gpa);
    identity_view.identity_email.deinit(gpa);
    window_chrome.forgetMe();
    graph_view.clearDrop();
    graph_view.drag_source.deinit(gpa);
    picked_lines.deinit(gpa);
    pr_list.pr_comment.deinit(gpa);
    pr_editor.clearPrEdit();
    pr_create.clearPrCreate();
    pr_list.pr_search.deinit(gpa);
    pr_list.pr_search = .empty;
    pr_list.pr_filter = .open;
    pr_list.pr_reply.deinit(gpa);
    pr_list.pr_reply_id.deinit(gpa);
    diff_view.split_rows.deinit(gpa);
    for ([_]*std.ArrayList(u8){ &dialog_views.dialog_url, &dialog_views.dialog_parent, &dialog_views.dialog_name, &dialog_views.dialog_branch }) |list| list.deinit(gpa);
    freeViews();
    if (repo_io.action_input) |patch| gpa.free(patch);
    repo_io.action_input = null;

    for (tab_strip.groups.items) |*group| group.deinit();
    tab_strip.groups.deinit(gpa);
    tab_strip.freeWorkspaces();
    tab_strip.workspaces.deinit(gpa);
    github_connect.ws_name.deinit(gpa);
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

    repo_io.detectLfs();
    graph_view.loadGraphPrefs();
    commit_view.startRepoConfig();
    // Off the UI thread too, beside the history's: under the loading screen,
    // which is up longer than 11,000 files take to stat.
    repo_io.workChanged("Reading the changes");
    // The first read of a repository is the slow one — packfiles not yet in
    // the page cache — so it happens off the UI thread, with the loading
    // screen in the meantime. Tests read it in place: they assert on it straight after.
    if (@import("builtin").is_test) {
        repo_io.reloadHistory();
        historyArrived();
    } else {
        graph_view.startHistoryLoad();
    }
}

/// What needs the history once it is there: the remotes it lists say where
/// pictures and pull requests come from.
pub fn historyArrived() void {
    avatars.setGithubRepo(if (tab_strip.integrations) repo_io.githubRemote() else null);
    repo_io.refreshRequests();
}

// === Frame ===

pub fn appFrame() !dvui.App.Result {
    tab_strip.in_frame = true;
    defer tab_strip.in_frame = false;
    frame_now_s = @intCast(@divFloor(std.Io.Timestamp.now(app_io, .real).nanoseconds, std.time.ns_per_s));
    // Before anything is collected: a worker finishing after this point
    // wakes the window again rather than finding the flag still set.
    wake_pending.store(false, .release);

    // Before any widget: this rebuilds the snapshots the panels below iterate.
    github_actions.collectJob();
    github_actions.collectApi();
    commit_view.collectRepoConfig();
    dialog_views.takeFolder();
    if (repo_io.collectWorkLoad()) dvui.refresh(null, @src(), null);
    if (graph_view.collectHistoryLoad()) dvui.refresh(null, @src(), null);
    pr_editor.updateWindowTitle();
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
    repo_io.askCi();

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
        repo_io.poll();
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
    command_palette.tabStrip();
    if (!start_page) window_chrome.titlebar();
    // A name asked for in a dialog; a yes or no in a toast low on the
    // right; a dropped branch's merge or rebase in a menu where it fell.
    dialog_views.promptDialog();
    github_connect.confirmToast();
    graph_view.dropMenu();

    command_palette.palette();
    dialog_views.repoDialog();
    identity_view.identityDialog();
    github_connect.connectDialog();
    github_connect.workspaceDialog();
    identity_view.settingsDialog();
    identity_view.keysDialog();
    pr_editor.prEditDialog();
    pr_create.prCreateDialog();
    home_page.featuresDialog();
    graph_view.dragGhost();
    dialog_views.forgetDialog();

    if (start_page) {
        home_page.startScreen();
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
            .split_ratio = if (pr_editor.leftShown()) &sidebar_split else &no_split,
            // A fixed 1px seam: dvui's dynamic handle widens the gap as the
            // mouse nears, which shoves both panes aside. The cursor is the
            // only sign needed.
            .handle_size = 1,
            .draw_in_deinit = false,
        }, .{ .expand = .both, .background = false });
        defer split.deinit();
        pr_editor.body_width = split.data().contentRect().w;

        if (pr_editor.leftShown() and split.showFirst()) refs_panel.sidebarPane();
        if (split.showSecond()) contentPane();
    }

    statusBar();

    // After every widget, and before the action below runs: a key a text field
    // consumed is already marked handled by the time this sees it.
    pr_editor.shortcuts();

    // After every widget: see `Action`. The frame just drawn was built from the
    // old snapshot, so ask for another one rather than leaving it on screen
    // until the poll timer comes round.
    if (repo_io.runAction()) dvui.refresh(null, @src(), null);

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
pub const View = enum { graph, pulls };

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
        .graph => if (repo_io.historyLoading()) repo_io.loadingScreen() else pr_editor.graphView(),
        .pulls => pr_list.pullsView(),
    }
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
    home_page.panelToggle(@src(), &show_sidebar, dvui.entypo.align_left, "Branches panel — Ctrl+B", "status:sidebar");
    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm, .w = style.space.md },
        .color_fill = .{ .color = style.border() },
    });

    // What the repository holds, each with its icon.
    if (history) |h| {
        home_page.statusStat(@src(), dvui.entypo.flow_line, h.commits.len, "commit", "commits");
        home_page.statusStat(@src(), dvui.entypo.flow_branch, h.refCount(.local), "branch", "branches");
        home_page.statusStat(@src(), dvui.entypo.archive, h.stashes.len, "stash", "stashes");
    }

    // What is running, and what failed: the one line about the last command,
    // on a pill of its colour. Both at once: a job clears the line as it
    // starts, so a failure beside it came after — a click refused because
    // it is running, say — and would otherwise sit unseen behind it.
    if (tab_strip.job != null) {
        home_page.statusPill(@src(), style.accent(), dvui.entypo.cycle, tab_strip.job_label, "…");
    } else if (github_actions.api_job != null) {
        home_page.statusPill(@src(), style.accent(), dvui.entypo.cycle, github_actions.api_label, "…");
    }
    if (tab_strip.command_error) |message| {
        home_page.statusPill(@src(), style.danger(), dvui.entypo.warning, dialog_views.firstLine(message), "");
        if (dialog_views.iconButton(@src(), "dismiss_error", "Dismiss", dvui.entypo.cross, style.textMuted())) {
            github_actions.clearCommandError();
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
    if (dialog_views.iconButtonTagged(@src(), "status_keys", "Keyboard shortcuts", dvui.entypo.keyboard, if (identity_view.keys_open) style.accent() else style.textMuted(), "status:keys")) {
        identity_view.keys_open = true;
        identity_view.keys_rect = .{};
    }
    home_page.panelToggle(@src(), &show_detail, dvui.entypo.align_right, "Changes panel — Ctrl+J", "status:detail");

    // The version, at the far end: a click shows what this one can do.
    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm, .w = style.space.sm },
        .color_fill = .{ .color = style.border() },
    });
    if (dialog_views.linkButtonTagged(@src(), "v" ++ APP_VERSION, if (home_page.features_open) style.accent() else style.textMuted(), "status:version")) {
        home_page.features_open = true;
        home_page.features_rect = .{};
    }
}

/// What the views added since 0.1.2 keep from one frame to the next — the
/// authors' index, a conflicted file's picks, the pull requests' cards and
/// form, the pickers' filters — freed at exit as between tests. Tests had
/// them freed; the exit did not: a Debug run's leak report is worth reading
/// only with nothing in it Zit meant to keep.
pub fn freeViews() void {
    graph_view.known_authors.deinit(gpa);
    graph_view.known_authors = .empty;
    _ = graph_view.authors_arena.reset(.free_all);
    graph_view.authors_seq = null;
    clearResolveUndo();
    resolve_undo.deinit(gpa);
    resolve_undo = .empty;
    conflict_path.deinit(gpa);
    conflict_path = .empty;
    pr_conversation.pr_cards.deinit(gpa);
    pr_conversation.pr_cards = .empty;
    for ([_]*std.ArrayList(u8){ &pr_create.pr_new_head, &pr_create.pr_new_assignees, &pr_create.pr_new_labels, &pr_create.pick_filter, &pr_conversation.side_list }) |l| {
        l.deinit(gpa);
        l.* = .empty;
    }
}

test {
    _ = app_tests;
}
