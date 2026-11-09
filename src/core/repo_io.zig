const std = @import("std");
const dvui = @import("dvui");
const style = @import("../ui/style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("run.zig");
const store = @import("store.zig");
const avatars = @import("../github/avatar.zig");
const pr = @import("../github/pr.zig");
const tab_strip = @import("../ui/tab_strip.zig");
const graph_view = @import("../ui/graph_view.zig");
const diff_view = @import("../ui/diff_view.zig");
const rebase_view = @import("../ui/rebase_view.zig");
const commit_view = @import("../ui/commit_view.zig");
const dialog_views = @import("../ui/dialog_views.zig");
const app = @import("../main.zig");

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
        defer app.wakeUi();
        defer self.done.store(true, .release);
        if (status_cache_file.items.len > 0 and status_cache_lock.tryLock()) {
            defer status_cache_lock.unlock(app.app_io);
            defer if (status_cache_drop.swap(false, .acq_rel)) dropStatusCache();
            if (statusCacheFor(self.path)) |cache| {
                if (cache.readWork(app.gpa, app.app_io)) |w| {
                    self.work = w;
                    return;
                } else |_| dropStatusCache();
            }
        }
        var r = git.Repo.open(self.path) catch return;
        defer r.deinit();
        self.work = r.readWork(app.gpa) catch null;
    }

    pub fn free(self: *WorkLoad) void {
        if (self.future) |*f| f.await(app.app_io);
        if (self.work) |*w| w.deinit();
        app.gpa.free(self.path);
        app.gpa.destroy(self);
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
pub var status_cache_file: std.ArrayList(u8) = .empty;

/// The cache for `path`, opened — and the last repository's dropped — if
/// it is not that one's. Called with `status_cache_lock` held.
fn statusCacheFor(path: []const u8) ?*git.StatusCache {
    if (status_cache) |cache| if (!std.mem.eql(u8, cache.path, path)) dropStatusCache();
    if (status_cache == null) status_cache = git.StatusCache.open(app.gpa, path, status_cache_file.items) catch return null;
    return &status_cache.?;
}

/// Called with `status_cache_lock` held, or with no read left to hold it.
fn dropStatusCache() void {
    if (status_cache) |*cache| cache.deinit(app.gpa, app.app_io);
    status_cache = null;
}

/// The closed repository's cache let go of: now, or as the read holding it
/// ends — which is not waited for, as `closeRepo` waits for no read.
pub fn releaseStatusCache() void {
    if (status_cache_lock.tryLock()) {
        defer status_cache_lock.unlock(app.app_io);
        dropStatusCache();
    } else status_cache_drop.store(true, .release);
}

pub fn initStatusCache(env: std.process.Environ.Map) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = store.appDir(env, &buf, .cache, "") orelse return;
    std.Io.Dir.cwd().createDirPath(app.app_io, dir) catch return;
    var id: [8]u8 = undefined;
    app.app_io.random(&id);
    const sep = if (@import("builtin").os.tag == .windows) "\\" else "/";
    status_cache_file.print(app.gpa, "{s}" ++ sep ++ "index-{x}", .{ dir, id[0..] }) catch status_cache_file.clearRetainingCapacity();
}

pub var work_load: ?*WorkLoad = null;
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
pub var command_label: []const u8 = "Reading the changes";

/// "Staging" for `git add`: what a command does, in the words the veil over
/// the changes uses while they are read again after it.
pub fn commandLabel(args: []const []const u8) []const u8 {
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
    if (app.repo == null) return;
    if (work_load != null) {
        work_again = true;
        return;
    }
    const load = app.gpa.create(WorkLoad) catch return;
    load.* = .{ .path = app.gpa.dupe(u8, app.repo_path.items) catch {
        app.gpa.destroy(load);
        return;
    }, .gen = work_gen };
    work_load = load;
    load.future = app.app_io.concurrent(WorkLoad.run, .{load}) catch blk: {
        load.run();
        break :blk null;
    };
}

/// Once a frame, before anything draws: swap a finished read in, if it is
/// still the newest. True when one landed.
pub fn collectWorkLoad() bool {
    const load = work_load orelse return false;
    if (!load.done.load(.acquire)) return false;
    work_load = null;
    defer load.free();
    defer if (work_again) {
        work_again = false;
        refreshWork();
    };
    if (app.repo == null or !std.mem.eql(u8, load.path, app.repo_path.items) or load.gen != work_gen) return false;
    // The newest read is in, whatever it found.
    work_settling = false;
    var next = load.work orelse return false;
    load.work = null;
    // Nothing changed — the usual answer, on a timer or a watcher's word —
    // and nothing is drawn again. Except the open file's diff: its lines can
    // change with its status staying "modified".
    if (app.work) |w| if (sameWork(w, next)) {
        next.deinit();
        if (app.selection != .change) return false;
        app.diff_stale = true;
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
pub fn loadingScreen() void {
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
        _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = @embedFile("../brand/zit-icon-256.png"), .name = "zit" } }, .shrink = .both }, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = d, .h = d },
            .max_size_content = .size(.{ .w = d, .h = d }),
        });
    }
    dvui.label(@src(), "Loading {s}…", .{app.repo_name}, .{
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
pub fn stillUi() void {
    dvui.reduce_motion = true;
    dvui.hover_fade_secs = 0;
}

/// The next step of an animation, `ms` from now: a timer, not a refresh — a
/// refresh draws again at once, as fast as the display goes, for something
/// that moves a few times a second.
pub fn animateEvery(id: dvui.Id, ms: u32) void {
    if (dvui.timerDoneOrNone(id)) dvui.timer(id, @intCast(ms * 1000));
}

pub fn historyLoading() bool {
    return graph_view.history_load != null and app.history == null;
}

/// How many of the newest commits CI is asked about.
const CI_COMMITS = 40;
/// And how many pull requests' heads, on top.
const CI_REQUESTS = 30;

/// Ask the host what CI made of the newest commits; `pr` paces it.
pub fn askCi() void {
    if (@import("builtin").is_test) return;
    const h = app.history orelse return;
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
    pr.ciRefresh(app.repo_path.items, shas[0..n], app.frame_now_s);
}

/// Re-list the open pull requests, if the repository is on GitHub.
pub fn refreshRequests() void {
    app.repo_slug.clearRetainingCapacity();
    if (app.history == null or !tab_strip.integrations) return pr.refresh(app.repo_path.items, .none, "");
    // The first remote on GitHub, `origin` before the others.
    const found = firstRemote([]const u8, struct {
        fn pick(r: git.Remote) ?[]const u8 {
            return avatars.githubSlug(r.url);
        }
    }.pick);
    if (found) |s| app.repo_slug.appendSlice(app.gpa, s) catch {};
    pr.refresh(app.repo_path.items, if (found != null) .github else .none, app.repo_slug.items);
    pr.refreshIssues(app.repo_path.items);
}

/// What `pick` makes of the first remote it makes anything of — `origin`
/// before the others, then in the order they are listed.
pub fn firstRemote(comptime T: type, comptime pick: fn (git.Remote) ?T) ?T {
    const h = app.history orelse return null;
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
pub fn detectLfs() void {
    tab_strip.uses_lfs = false;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buf, "{s}.gitattributes", .{app.repo_path.items}) catch return;

    // Having no `.gitattributes` at all is the common case, not an error.
    const text = std.Io.Dir.cwd().readFileAlloc(app.app_io, abs, app.gpa, .limited(1 << 20)) catch return;
    defer app.gpa.free(text);

    tab_strip.uses_lfs = std.mem.indexOf(u8, text, "filter=lfs") != null;
}

/// Ask for a folder and open whatever repository contains it.
fn promptOpenRepo() void {
    dialog_views.pickFolder(.open_repo, "Open a repository", if (app.repo_path.items.len > 0) app.repo_path.items else null);
}

// === Reading ===

/// Refs, commits and lanes. Built into locals and swapped in at the end, so a
/// failed read leaves the previous graph on screen rather than an empty pane.
pub fn reloadHistory() void {
    const r = app.repo orelse return;
    graph_view.history_gen +%= 1;

    var next_history = r.readHistoryFiltered(app.gpa, graph_view.graphFilter()) catch {
        app.setCommandError(git.lastError());
        return;
    };
    var next_lanes = graph.build(app.gpa, next_history.commits, next_history.head_oid) catch {
        next_history.deinit();
        app.setCommandError("Out of memory laying out the graph.");
        return;
    };

    if (app.history) |*h| h.deinit();
    if (app.lanes) |*l| l.deinit();
    app.history = next_history;
    app.lanes = next_lanes;
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

pub fn reloadWork() void {
    const r = app.repo orelse return;
    work_gen +%= 1;
    const next = r.readWork(app.gpa) catch return;
    swapWork(next);
}

fn swapWork(next: git.Work) void {
    if (app.work) |*w| w.deinit();
    app.work = next;
    commit_view.work_version +%= 1;

    if (app.open_first_conflict) {
        app.open_first_conflict = false;
        for (next.unstaged) |change| {
            if (change.status != .conflicted) continue;
            app.active_view = .graph;
            app.selectChange(change.path, .unstaged);
            break;
        }
    }

    // A commit's diff cannot change, so only the working-tree side is worth
    // re-reading — and this runs on the poll timer.
    switch (app.selection) {
        .change => app.diff_stale = true,
        else => {},
    }
}

/// glibc's `mallopt`, for the arena count; null elsewhere, as `malloc_trim`.
pub const mallopt: ?*const fn (c_int, c_int) callconv(.c) c_int = if (@import("builtin").os.tag == .linux and @import("builtin").abi.isGnu())
    @extern(*const fn (c_int, c_int) callconv(.c) c_int, .{ .name = "mallopt" })
else
    null;
pub const M_ARENA_MAX: c_int = -8;
pub const M_MMAP_THRESHOLD: c_int = -3;

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
pub fn poll() void {
    const r = app.repo orelse return;
    // The first read is still out on its thread; reading it again here would
    // only do the same work twice, on the UI thread.
    if (graph_view.history_load != null) return refreshWork();

    refreshWork();
    autoFetch();

    const now = r.headOid();
    const known = if (app.history) |h| h.head_oid else null;
    const moved = if (now) |a|
        if (known) |b| !git.oidEql(a, b) else true
    else
        known != null;

    // A checkout of another branch at the same commit moves no oid, but it is
    // still a move: the branch shown, and the reflog entry Undo takes back.
    const name_now = r.headBranch(app.gpa) catch null;
    defer if (name_now) |n| app.gpa.free(n);
    const name_known = if (app.history) |h| h.head else null;
    const switched = if (name_now) |a|
        if (name_known) |b| !std.mem.eql(u8, a, b) else true
    else
        name_known != null;

    // A reset to the commit HEAD is already on moves neither: only the
    // reflog says so, and it is what Undo would act on.
    const move_now = r.readLastMove(app.gpa);
    defer if (move_now) |m| app.gpa.free(m.message);
    const move_known = if (app.history) |h| h.last_move else null;
    const logged = if (move_now) |a|
        if (move_known) |b| !git.oidEql(a.old, b.old) or !std.mem.eql(u8, a.message, b.message) else true
    else
        move_known != null;

    // A merge stopped on a conflict in a terminal moves none of the three:
    // only the repository's state says it is under way.
    const state_changed = if (app.history) |h| r.state() != h.state else false;

    if (moved or switched or logged or state_changed) graph_view.refreshHistory();
}

/// The quiet fetch, when it is due and nothing else is running.
fn autoFetch() void {
    // Tests drive their own fetches; one arriving on its own would race them.
    if (@import("builtin").is_test) return;
    if (tab_strip.auto_fetch_minutes == 0 or tab_strip.job != null or action != .none) return;
    if (app.frame_now_s - tab_strip.last_auto_fetch_s < @as(i64, tab_strip.auto_fetch_minutes) * 60) return;
    tab_strip.last_auto_fetch_s = app.frame_now_s;
    const h = app.history orelse return;
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
    if (app.repo == null) return;
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
    const ok = run.launch(app.app_io, app.repo_path.items, argv) catch return app.setCommandError("Could not start a terminal.");
    if (!ok) app.setCommandError("No terminal found. Set $TERMINAL to the one you use.");
}

// === Writing ===

/// What this frame asked the repository to do.
///
/// Nothing mutates the repository while the frame is being built. Every panel
/// iterates slices that live inside a snapshot arena (`History`, `Work`), and
/// any git command throws those arenas away and builds new ones — so a button
/// that ran `git add` in place left the loop around it walking freed memory.
/// One action is collected here and run in `runAction`, after the last widget.
pub const Action = enum {
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
pub var action_argv: [8][]const u8 = undefined;
pub var action_argc: usize = 0;
/// Holds the pending command's arguments: the callers build them in buffers
/// on their own stack, or in a snapshot a command throws away, and the
/// command runs after both are gone.
var action_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// Copy `args` in as the pending command's. False, with the error said, when
/// there was no memory for it.
pub fn setArgv(args: []const []const u8) bool {
    std.debug.assert(args.len <= action_argv.len);
    _ = action_arena.reset(.retain_capacity);
    for (args, 0..) |a, i| {
        action_argv[i] = action_arena.allocator().dupe(u8, a) catch {
            app.setCommandError("Out of memory.");
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
pub const TabAction = union(enum) {
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

pub var tab_action: TabAction = .none;
/// The group — and tab — a group prompt is about: the tab a new group
/// starts with, the group being renamed.
pub var group_target: [2]usize = .{ 0, 0 };

/// Which conflict region the pending `.resolve` applies to, and how.
pub var action_conflict: usize = 0;
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
pub fn runAction() bool {
    const pending = action;
    action = .none;

    switch (pending) {
        .none => return false,
        .run => {
            app.gitDoInput(action_argv[0..action_argc], action_input);
            if (action_input) |patch| app.gpa.free(patch);
            action_input = null;
        },
        .commit => app.doCommit(),
        .confirmed => app.runConfirmed(),
        .prompt => app.runPrompt(),
        .resolve => app.runResolve(),
        .resolve_safe => app.runResolveSafe(),
        .undo_resolve => app.runUndoResolve(),
        .take_file => app.runTakeFile(),
        .stage_next => app.runStageNext(),
        .rebase => app.runRebase(),
        .network => app.startJob(),
        .tabs => app.runTabAction(),
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
    if (tab_strip.job != null) return app.setCommandError(BUSY);
    if (!setArgv(args)) return;
    tab_strip.job_label = label;
    action = .network;
}

pub const BUSY = "Another command is still running. Try again when it finishes.";
