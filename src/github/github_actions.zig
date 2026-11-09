const std = @import("std");
const dvui = @import("dvui");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const pr = @import("pr.zig");
const github = @import("github.zig");
const tab_strip = @import("../ui/tab_strip.zig");
const window_chrome = @import("../ui/window_chrome.zig");
const graph_view = @import("../ui/graph_view.zig");
const rebase_view = @import("../ui/rebase_view.zig");
const commit_view = @import("../ui/commit_view.zig");
const identity_view = @import("../ui/identity_view.zig");
const repo_io = @import("../core/repo_io.zig");
const app = @import("../main.zig");

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

pub var api_job: ?*run.Capture = null;
pub var api_label: []const u8 = "";
var api_then: ApiThen = .none;
/// The calls waiting behind the one out.
pub var api_queue: std.ArrayList(ApiCall) = .empty;
/// For `.ask_reviewers`: the JSON lists, owned — whom to ask, whom to
/// assign, which labels.
pub var api_reviewers: std.ArrayList(u8) = .empty;
pub var api_assignees: std.ArrayList(u8) = .empty;
pub var api_labels: std.ArrayList(u8) = .empty;
/// Fetch once the run succeeds: it moved branches on the remote.
pub var api_fetch_after = false;
/// For `.gone`: the request merged or closed, and what it now is.
var api_gone_number: u32 = 0;
var api_gone_state: []const u8 = "";

/// `owner/name` on GitHub of the open repository; empty when it is not there.
pub var repo_slug: std.ArrayList(u8) = .empty;

/// `/repos/<owner>/<name>` followed by `fmt`, into `buf`; null when the
/// repository is not on GitHub.
pub fn apiPath(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    if (repo_slug.items.len == 0) return null;
    const head = std.fmt.bufPrint(buf, "/repos/{s}", .{repo_slug.items}) catch return null;
    const tail = std.fmt.bufPrint(buf[head.len..], fmt, args) catch return null;
    return buf[0 .. head.len + tail.len];
}

/// Queue a call; it starts at once when none is out.
pub fn requestApi(label: []const u8, method: []const u8, path: ?[]const u8, body: ?[]const u8, then: ApiThen) void {
    const p = path orelse return setCommandError("This repository is not on GitHub.");
    if (!github.signedIn()) return setCommandError("Connect GitHub first: Settings › GitHub.");
    const call: ApiCall = .{
        .label = label,
        .method = method,
        .path = app.gpa.dupe(u8, p) catch return,
        .body = if (body) |b| app.gpa.dupe(u8, b) catch null else null,
        .then = then,
    };
    api_queue.append(app.gpa, call) catch return freeCall(call);
    if (api_job == null) startNextApi();
}

/// A GraphQL mutation, `variables` a JSON object.
pub fn requestGraphql(label: []const u8, query: []const u8, variables: []const u8, then: ApiThen) void {
    const body = github.graphqlBody(app.gpa, query, variables) catch return;
    defer app.gpa.free(body);
    requestApi(label, "POST", "/graphql", body, then);
}

fn freeCall(call: ApiCall) void {
    app.gpa.free(call.path);
    if (call.body) |b| app.gpa.free(b);
}

fn startNextApi() void {
    if (api_queue.items.len == 0) return;
    const call = api_queue.orderedRemove(0);
    defer freeCall(call);
    api_job = github.start(if (app.repo_path.items.len > 0) app.repo_path.items else ".", call.method, call.path, call.body) catch {
        clearApiQueue();
        return setCommandError("Could not run curl. Is it installed?");
    };
    api_label = call.label;
    api_then = call.then;
    clearCommandError();
}

pub fn clearApiQueue() void {
    for (api_queue.items) |c| freeCall(c);
    api_queue.clearRetainingCapacity();
    api_fetch_after = false;
}

/// Land a finished call: GitHub's words if it failed — and the rest of the
/// run dropped — else what it sets off, the next call, and once the run is
/// done the requests read again.
pub fn collectApi() void {
    const w = api_job orelse return;
    if (!w.finished()) return;
    defer {
        w.deinit(app.app_io);
        api_job = null;
        api_label = "";
    }
    var a: std.heap.ArenaAllocator = .init(app.gpa);
    defer a.deinit();
    const failed: ?[]const u8 = if (!w.ok)
        (if (w.err.items.len > 0) a.allocator().dupe(u8, w.err.items) catch "curl failed." else "curl failed.")
    else
        github.failure(a.allocator(), github.split(w.out));
    // A branch already deleted is what was asked for; and a failure there
    // does not keep the list from being read again.
    if (failed != null and api_then == .branch_after_merge) {
        if (api_queue.items.len > 0) return startNextApi();
        repo_io.refreshRequests();
        if (app.pr_selected) |n| pr.loadDetail(app.repo_path.items, n);
        return;
    }
    if (failed) |why| {
        clearApiQueue();
        setCommandError(why);
        // The dialog stays, with what went wrong, to try again.
        app.pr_creating = false;
        app.pr_created = 0;
        return;
    }
    switch (api_then) {
        .none => {},
        .clear_comment => app.pr_comment.clearRetainingCapacity(),
        .clear_reply => {
            app.pr_reply.clearRetainingCapacity();
            app.pr_reply_id.clearRetainingCapacity();
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
    if (app.pr_created != 0) {
        const n = app.pr_created;
        app.pr_created = 0;
        app.pr_creating = false;
        app.pr_new_open = false;
        app.new_tab_open = false;
        app.pr_filter = .open;
        app.active_view = .pulls;
        repo_io.refreshRequests();
        return app.selectRequest(n);
    }
    repo_io.refreshRequests();
    if (app.pr_selected) |n| pr.loadDetail(app.repo_path.items, n);
    if (api_fetch_after) {
        api_fetch_after = false;
        repo_io.requestNetwork("Fetching", tab_strip.fetchAllArgs(true));
        tab_strip.job_quiet = repo_io.action == .network;
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
    var a: std.heap.ArenaAllocator = .init(app.gpa);
    defer a.deinit();
    const made = std.json.parseFromSliceLeaky(struct { number: u32 = 0 }, a.allocator(), body, .{ .ignore_unknown_fields = true }) catch return;
    if (made.number == 0) return;
    // Opened once the calls below are done, with what they set on it.
    app.pr_created = made.number;
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
pub fn jsonFields(a: std.mem.Allocator, pairs: []const [2][]const u8) []const u8 {
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
pub fn jsonList(a: std.mem.Allocator, text: []const u8) []const u8 {
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
pub fn checkoutRequest(number: u32, branch: []const u8, fork: bool) void {
    if (branch.len == 0) return setCommandError("GitHub did not say which branch that request is.");
    const remote = defaultRemote() orelse return setCommandError("There is no remote to fetch it from.");
    if (app.midOperation()) return setCommandError("Finish or abort what is under way first.");
    if (fork) {
        var spec_buf: [32]u8 = undefined;
        repo_io.requestNetwork("Fetching", &.{ "fetch", remote, std.fmt.bufPrint(&spec_buf, "pull/{d}/head", .{number}) catch return });
        queueRequestBranch(number, branch, remote, true);
    } else {
        repo_io.requestNetwork("Fetching", &.{ "fetch", remote, branch });
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
pub fn resolveRequestLocally(d: pr.Detail, rebase: bool) void {
    if (d.fork) return setCommandError("Its branch is in a fork: check it out and bring the base in by hand.");
    const remote = defaultRemote() orelse return setCommandError("There is no remote to fetch it from.");
    if (app.midOperation()) return setCommandError("Finish or abort what is under way first.");
    if (app.work) |w| if (w.staged.len > 0 or hasTrackedChanges(w)) {
        return setCommandError("Commit or stash your changes first: the branch is about to change under them.");
    };
    repo_io.requestNetwork("Fetching", &.{ "fetch", remote, d.base, d.head });
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
pub var job_steps: std.ArrayList(JobStep) = .empty;

fn queueStep(label: []const u8, args: []const []const u8) void {
    // Only behind a job that was queued.
    if (repo_io.action != .network) return clearJobSteps();
    const argv = app.gpa.alloc([]u8, args.len) catch return clearJobSteps();
    for (args, 0..) |arg, i| {
        argv[i] = app.gpa.dupe(u8, arg) catch {
            for (argv[0..i]) |done| app.gpa.free(done);
            app.gpa.free(argv);
            return clearJobSteps();
        };
    }
    job_steps.append(app.gpa, .{ .label = label, .argv = argv }) catch {
        freeStep(.{ .label = label, .argv = argv });
        clearJobSteps();
    };
}

fn freeStep(step: JobStep) void {
    for (step.argv) |arg| app.gpa.free(arg);
    app.gpa.free(step.argv);
}

pub fn clearJobSteps() void {
    for (job_steps.items) |step| freeStep(step);
    job_steps.clearRetainingCapacity();
}

/// Open `url` in the browser.
pub fn openUrl(url: []const u8) void {
    run.open(app.app_io, ".", url) catch setCommandError("Could not open the browser.");
}

/// The repository's page on GitHub, `tail` after it, in the browser.
pub fn openOnGithub(comptime tail: []const u8, args: anytype) void {
    if (repo_slug.items.len == 0) return setCommandError("This repository is not on GitHub.");
    var buf: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "https://github.com/{s}", .{repo_slug.items}) catch return;
    const rest = std.fmt.bufPrint(buf[head.len..], tail, args) catch return;
    openUrl(buf[0 .. head.len + rest.len]);
}

pub fn startJob() void {
    // Copied by the job, and owned here either way.
    defer if (repo_io.action_input) |bytes| {
        app.gpa.free(bytes);
        repo_io.action_input = null;
    };
    const after = action_after;
    action_after = .remote;
    if (app.repo == null or tab_strip.job != null) return;
    tab_strip.job = run.Job.start(app.gpa, app.app_io, app.repo_path.items, repo_io.action_argv[0..repo_io.action_argc], .{ .input = repo_io.action_input }) catch {
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
pub var action_after: JobAfter = .remote;

/// As `requestNetwork`, for a command of the repository's own.
pub fn requestLocal(label: []const u8, args: []const []const u8) void {
    repo_io.requestNetwork(label, args);
    if (repo_io.action == .network) action_after = .local;
}

/// Start a networked command now, from inside `runAction` — for the ones that
/// first went through a confirmation or a prompt, which already were the
/// deferred action.
fn startNetwork(label: []const u8, args: []const []const u8) void {
    // A confirmed force push dropped here has to say so.
    if (tab_strip.job != null) return setCommandError(repo_io.BUSY);
    if (!repo_io.setArgv(args)) return;
    tab_strip.job_label = label;
    startJob();
}

/// As `startNetwork`, for a command of the repository's own, with what to
/// do once it lands.
pub fn startLocal(label: []const u8, args: []const []const u8, after: JobAfter) void {
    if (tab_strip.job != null) return setCommandError(repo_io.BUSY);
    action_after = after;
    startNetwork(label, args);
}

/// Where a running clone is going, owned. Set while that job is out; it is the
/// one job with no repository behind it, and it opens one when it lands.
pub var clone_dest: std.ArrayList(u8) = .empty;

pub fn startClone(url: []const u8, dest: []const u8) void {
    if (tab_strip.job != null) return;

    clone_dest.clearRetainingCapacity();
    clone_dest.appendSlice(app.gpa, dest) catch return;

    // From the process's own directory: there may be no repository to run in,
    // and a relative destination then means what it does in a terminal.
    tab_strip.job = run.Job.start(app.gpa, app.app_io, ".", &.{ "clone", "--", url, dest }, .{}) catch {
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
pub fn collectJob() void {
    const running = tab_strip.job orelse return;
    if (!running.finished()) return;

    if (clone_dest.items.len > 0) {
        tab_strip.job = null;
        tab_strip.job_label = "";
        defer clone_dest.clearRetainingCapacity();

        var result = running.finish(app.gpa, app.app_io) orelse return setCommandError("Could not run git. Is it on your PATH?");
        defer result.deinit(app.gpa);
        if (!result.ok) return setCommandError(if (result.message.len > 0) result.message else "git clone failed.");

        clearCommandError();
        tab_strip.openAndRemember(clone_dest.items);
        return;
    }

    // Read before `finish`, which frees the copy: the repository can be closed
    // or swapped while a fetch is in flight, and that fetch has nothing to say
    // about whatever is on screen now.
    const still_current = app.repo != null and std.mem.eql(u8, running.cwd, app.repo_path.items);

    tab_strip.job = null;
    // Its words go on over the changes while they are read again after it.
    // A literal, as every job's label is: it outlives the job.
    repo_io.command_label = if (tab_strip.job_label.len > 0) tab_strip.job_label else "Reading the changes";
    tab_strip.job_label = "";
    const quiet = tab_strip.job_quiet;
    tab_strip.job_quiet = false;
    const after = job_after;
    job_after = .remote;

    var outcome = running.finish(app.gpa, app.app_io);
    if (!still_current) {
        if (outcome) |*o| o.deinit(app.gpa);
        return;
    }
    if (quiet) {
        if (outcome) |*o| {
            if (!o.ok) {
                o.deinit(app.gpa);
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
    repo_io.refreshRequests();
    if (app.pr_selected) |n| pr.loadDetail(app.repo_path.items, n);
}

/// Fold the result of a command back into the UI. Shared by the synchronous
/// path and by a job coming back off another thread.
fn applyOutcome(outcome: ?run.Outcome) void {
    var result = outcome orelse {
        setCommandError("Could not run git. Is it on your PATH?");
        return;
    };
    defer result.deinit(app.gpa);

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
    repo_io.workChanged(repo_io.command_label);
    repo_io.command_label = "Reading the changes";
}

/// Whether a failed command stopped a merge, rebase, cherry-pick or revert
/// at a conflict — git's way of handing it over — rather than failing.
fn stoppedAtConflict(message: []const u8) bool {
    const r = app.repo orelse return false;
    if (r.state() == .none) return false;
    for ([_][]const u8{ "CONFLICT", "could not apply", "fix conflicts" }) |sign| {
        if (std.mem.indexOf(u8, message, sign) != null) return true;
    }
    return false;
}

/// Set when an operation stopped at a conflict: the first conflicted file
/// is opened as soon as the changes are read again.
pub var open_first_conflict = false;

/// Run a git command in the repository and fold the result back into the UI.
pub fn gitDo(args: []const []const u8) void {
    gitDoInput(args, null);
}

/// As `gitDo`, with `input` on the command's standard input — which is how a
/// single hunk is staged: `git apply --cached -` reading a patch Zit rebuilt.
pub fn gitDoInput(args: []const []const u8, input: ?[]const u8) void {
    if (app.repo == null) return;

    const outcome = run.gitInput(app.gpa, app.app_io, app.repo_path.items, args, input) catch null;
    repo_io.command_label = repo_io.commandLabel(args);
    applyOutcome(outcome);
}

/// Compose a rebase of every commit from HEAD down to `onto`, which stays where
/// it is — exactly the set `git rebase -i <onto>` replays. Null means down to
/// the root, which git spells `--root`.
pub fn beginRebase(onto: ?git.Oid) void {
    const h = app.history orelse return;
    app.clearSelection();

    var arena = std.heap.ArenaAllocator.init(app.gpa);
    const a = arena.allocator();

    var id = h.head_oid orelse {
        arena.deinit();
        setCommandError("Nothing is checked out to rebase.");
        return;
    };

    var reached = false;
    var guard: usize = 0;
    while (guard <= app.MAX_REBASE_STEPS) : (guard += 1) {
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
            app.clearRebase();
            setCommandError("There is a merge in that range; an interactive rebase here would flatten it.");
            return;
        }

        app.rebase_steps.append(app.gpa, .{
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
                app.rebase_root = true;
            }
            break;
        }
        id = commit.parents[0];
    }

    // First parents from HEAD is the line git replays. A commit off that line
    // is on another branch, and "rebase onto it" means something else — which
    // the branch menu already offers.
    if (!reached or app.rebase_steps.items.len == 0) {
        arena.deinit();
        app.clearRebase();
        setCommandError("That commit is not on the current branch's first-parent line.");
        return;
    }

    app.rebase_arena = arena;
    if (!app.rebase_root) app.rebase_base_len = git.oidHex(onto.?, &app.rebase_base).len;
    app.selection = .rebase;
}

/// Hand the composed list to `git rebase -i` and let it run.
pub fn runRebase() void {
    const r = app.repo orelse return;
    if (app.rebase_steps.items.len == 0) return;

    // Oldest first: git replays a todo list top to bottom, the reverse of the
    // order the graph shows them in.
    var ordered: std.ArrayList(git.RebaseStep) = .empty;
    defer ordered.deinit(app.gpa);
    var i = app.rebase_steps.items.len;
    while (i > 0) {
        i -= 1;
        ordered.append(app.gpa, app.rebase_steps.items[i]) catch return;
    }

    const todo = git.rebaseTodo(app.gpa, ordered.items) catch return;
    defer app.gpa.free(todo);

    var todo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const todo_path = std.fmt.bufPrint(&todo_path_buf, "{s}zit-rebase-todo", .{r.gitdir()}) catch {
        setCommandError("That repository's path is too long to write a todo list into.");
        return;
    };

    std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = todo_path, .data = todo }) catch {
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
    if (app.rebase_root) {
        gitDo(&.{ "-c", "core.editor=true", "-c", cfg, "rebase", "-i", "--root" });
    } else {
        gitDo(&.{ "-c", "core.editor=true", "-c", cfg, "rebase", "-i", app.rebase_base[0..app.rebase_base_len] });
    }

    // git has its own copy of the list by now, if it started at all.
    std.Io.Dir.cwd().deleteFile(app.app_io, todo_path) catch {};

    // Refused before it began — a dirty tree, say: the plan stays on screen,
    // to run again once that is sorted. Otherwise it finished or stopped on
    // a conflict, the toolbar takes it from there, and the list is done.
    if (tab_strip.command_error != null and r.state() == .none) return;
    app.clearSelection();
}

/// Ctrl+W, from the keyboard or the palette: the new-tab page when it is up —
/// it is what is on screen — and only otherwise the repository under it.
pub fn closeShownTab() void {
    if (app.new_tab_open) {
        app.new_tab_open = false;
    } else if (app.active_view != .graph) {
        app.active_view = .graph;
    } else requestTab(.{ .close = tab_strip.active_tab });
}

pub fn requestTab(what: repo_io.TabAction) void {
    if (repo_io.action != .none) return;
    repo_io.tab_action = what;
    repo_io.action = .tabs;
}

pub fn requestOpenKnown(path: []const u8) void {
    if (repo_io.action != .none) return;
    const owned = app.gpa.dupe(u8, path) catch return;
    repo_io.tab_action = .{ .open = owned };
    repo_io.action = .tabs;
}

pub fn runTabAction() void {
    const what = repo_io.tab_action;
    repo_io.tab_action = .none;

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
        .select_ws => |w| app.selectWorkspace(w),
        .close_ws => |w| app.deleteWorkspace(w),
        .workspace_named => app.applyWorkspaceDialog(),
        .tab_out => |gt| tab_strip.ungroupTab(gt[0], gt[1]),
        .open => |path| {
            defer app.gpa.free(path);
            tab_strip.openAndRemember(path);
        },
    }
}

pub fn requestResolve(index: usize, side: git.ConflictSide) void {
    if (repo_io.action != .none) return;
    repo_io.action_conflict = index;
    repo_io.action_side = side;
    repo_io.action = .resolve;
}

/// Rewrite the conflicted file with one region replaced by the chosen side.
///
/// Nothing is staged here. The file still has to look right, and marking it
/// resolved is a separate, deliberate click — same as resolving in an editor.
pub fn runResolve() void {
    if (repo_io.action_conflict >= app.conflicts.len) return;
    const next = git.resolveConflict(app.gpa, app.conflict_text, app.conflicts[repo_io.action_conflict], repo_io.action_side) catch {
        setCommandError("Out of memory resolving that conflict.");
        return;
    };
    defer app.gpa.free(next);
    _ = writeConflictFile(next, true);
}

/// Every region that resolves on its own, at once: each keeps the side that
/// changed it, line by line at the finest. The file written in one pass —
/// one region at a time was a copy of all of it for each, 345 ms for 250
/// regions of a 1.3 MB lockfile.
pub fn runResolveSafe() void {
    const with = app.gpa.alloc(?[]const u8, app.conflicts.len) catch return;
    defer app.gpa.free(with);
    @memset(with, null);
    defer for (with) |w| if (w) |t| app.gpa.free(t);
    for (app.conflicts, with) |region, *w| {
        if (git.autoResolve(app.gpa, region) catch null) |auto| w.* = auto.text;
    }
    const text = git.replaceRegions(app.gpa, app.conflict_text, app.conflicts, with) catch return;
    defer app.gpa.free(text);
    _ = writeConflictFile(text, true);
}

/// U and Ctrl+Z in a conflicted file: the file as it was before the last pick.
pub fn runUndoResolve() void {
    const step = app.resolve_undo.pop() orelse return;
    defer step.deinit(app.gpa);
    const previous = (git.spliceUndo(app.gpa, app.conflict_text, step) catch return) orelse {
        // Edited since, another way than a pick: the picks before it no
        // longer fit it.
        app.clearResolveUndo();
        setCommandError("The file changed since that pick: there is nothing to take back.");
        return;
    };
    defer app.gpa.free(previous);
    _ = writeConflictFile(previous, false);
}

/// Write `next` over the open conflicted file, keeping what it was for U to
/// put back. Refused when the file changed on disk since it was shown:
/// "Open this file" invites an edit in another editor, and writing the
/// older copy over it would lose that edit without a word.
fn writeConflictFile(next: []const u8, keep_undo: bool) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = app.selectedAbsPath(&path_buf) orelse return false;

    const on_disk = std.Io.Dir.cwd().readFileAlloc(app.app_io, abs, app.gpa, .limited(app.MAX_CONFLICT_BYTES)) catch null;
    defer if (on_disk) |d| app.gpa.free(d);
    if (on_disk == null or !std.mem.eql(u8, on_disk.?, app.conflict_text)) {
        app.diff_stale = true;
        setCommandError("The file changed on disk since it was shown: here it is as it is now. Pick again.");
        return false;
    }

    if (keep_undo) {
        const step = git.spliceBetween(app.gpa, app.conflict_text, next) catch return false;
        if (app.resolve_undo.items.len == app.MAX_RESOLVE_UNDO) app.resolve_undo.orderedRemove(0).deinit(app.gpa);
        app.resolve_undo.append(app.gpa, step) catch {
            step.deinit(app.gpa);
            return false;
        };
    }
    std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = abs, .data = next }) catch {
        setCommandError("Could not write that file back.");
        return false;
    };

    clearCommandError();
    // The offsets of every region after the one just resolved have moved, so
    // the list is rebuilt rather than patched.
    app.diff_stale = true;
    repo_io.workChanged("Resolving");
    return true;
}

/// The whole file as one side has it, staged: `checkout --ours` or
/// `--theirs`, then `add` — or, where that side deleted it, `rm`. The
/// next conflicted file opens after it.
pub fn runTakeFile() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (app.selected_path.items.len > path_buf.len) return;
    @memcpy(path_buf[0..app.selected_path.items.len], app.selected_path.items);
    const file = path_buf[0..app.selected_path.items.len];
    const side = repo_io.action_side;

    const deleted = (app.conflict_kind == .deleted_by_us and side == .ours) or (app.conflict_kind == .deleted_by_them and side == .theirs);
    if (deleted) {
        gitDo(&.{ "--literal-pathspecs", "rm", "-q", "--", file });
    } else {
        // Deleted on the other side: what is on disk is already this one's.
        if (app.conflict_kind != .deleted_by_us and app.conflict_kind != .deleted_by_them) {
            gitDo(&.{ "--literal-pathspecs", "checkout", if (side == .theirs) "--theirs" else "--ours", "--", file });
            if (tab_strip.command_error != null) return;
        }
        gitDo(&.{ "--literal-pathspecs", "add", "--", file });
    }
    if (tab_strip.command_error != null) return;
    app.clearResolveUndo();
    open_first_conflict = true;
    repo_io.workChanged("Resolving");
}

/// A file with nothing left to resolve, staged, and the next one opened.
pub fn runStageNext() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (app.selected_path.items.len > path_buf.len) return;
    @memcpy(path_buf[0..app.selected_path.items.len], app.selected_path.items);
    const file = path_buf[0..app.selected_path.items.len];
    if (commit_view.markersLeft(file)) return ask(.stage_markers, file);
    gitDo(&.{ "--literal-pathspecs", "add", "--", file });
    if (tab_strip.command_error != null) return;
    app.clearResolveUndo();
    open_first_conflict = true;
    repo_io.workChanged("Resolving");
}

/// Take back whatever last moved HEAD, as the reflog tells it.
pub fn requestUndo() void {
    const h = app.history orelse return;
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
    repo_io.request(args);
}

/// HEAD before the last undo Zit made, while that undo can be redone.
pub var redo_from: ?git.Oid = null;
/// What that undo took back, in the reflog's words: Redo's hover.
pub var redo_what: [160]u8 = undefined;
pub var redo_what_len: usize = 0;

/// Whether Redo has something to take back: an undo made here, and nothing
/// moved HEAD since.
pub fn canRedo() bool {
    const h = app.history orelse return false;
    const from = redo_from orelse return false;
    const move = h.last_move orelse return false;
    return git.oidEql(move.old, from);
}

/// Undo's hover: what it would take back, as the reflog says it.
pub fn undoHint() []const u8 {
    const h = app.history orelse return "Undo";
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
    const h = app.history orelse return;
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
    const h = app.history orelse return false;
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
    repo_io.requestNetwork("Switching branch", &.{ "switch", name });
}

pub fn setCommandError(message: []const u8) void {
    clearCommandError();
    tab_strip.command_error = app.gpa.dupe(u8, message) catch null;
}

pub fn clearCommandError() void {
    if (tab_strip.command_error) |m| app.gpa.free(m);
    tab_strip.command_error = null;
}

pub fn ask(kind: app.Confirm.Kind, arg: []const u8) void {
    clearConfirm();
    app.confirm = .{ .kind = kind, .arg = app.gpa.dupe(u8, arg) catch return };
}

pub fn clearConfirm() void {
    if (app.confirm) |c| app.gpa.free(c.arg);
    app.confirm = null;
}

/// Run whatever was confirmed. Every branch here destroys work on purpose.
pub fn runConfirmed() void {
    const c = app.confirm orelse return;
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
            const method = ([_][]const u8{ "merge", "squash", "rebase" })[@min(app.pr_merge_method, 2)];
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
            if (app.pr_delete_branch) if (pr.detail) |d| if (d.number == number and d.head.len > 0 and !d.fork) {
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
            repo_io.request(&.{ "--literal-pathspecs", "add", "--", c.arg }),
        .abort_operation => if (operationCommand()) |cmd| repo_io.request(&.{ cmd, "--abort" }),
        .skip_step => if (operationCommand()) |cmd| requestLocal("Skipping", &.{ cmd, "--skip" }),
        // `checkout -m` writes the conflict again from the index's three
        // stages: every pick made in the file goes.
        .restart_file => {
            gitDo(&.{ "--literal-pathspecs", "checkout", "-m", "--", c.arg });
            if (tab_strip.command_error == null) app.clearResolveUndo();
            app.diff_stale = true;
        },
    }
    clearConfirm();
}

/// The subcommand of the operation under way — `rebase`, `merge`… — whose
/// `--continue`, `--skip` and `--abort` apply; null with none.
pub fn operationCommand() ?[]const u8 {
    const h = app.history orelse return null;
    return h.state.command();
}

/// Abort and Skip, each asked first: an abort throws away every conflict
/// resolved so far, and a skipped commit is gone from the branch.
pub fn requestAbortOperation() void {
    if (operationCommand() == null) return;
    ask(.abort_operation, "");
}

pub fn requestSkipStep() void {
    if (operationCommand() == null) return;
    ask(.skip_step, "");
}

pub fn askName(kind: app.Prompt.Kind, arg: []const u8) void {
    clearPrompt();
    app.prompt = .{ .kind = kind, .arg = app.gpa.dupe(u8, arg) catch return };
}

/// As `askName`, with the field already holding `text` — the current name, for
/// a rename, so a typo is fixed rather than retyped.
pub fn askNameWith(kind: app.Prompt.Kind, arg: []const u8, text: []const u8) void {
    askName(kind, arg);
    app.prompt_text.appendSlice(app.gpa, text) catch {};
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
    return repo_io.firstRemote([]const u8, struct {
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
    if (app.history) |h| for (h.remotes) |r| {
        if (r.name.len > remote.len and rebase_view.remoteOf(name, r.name)) remote = r.name;
    };
    if (remote.len == 0) {
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return .{ .remote = name, .branch = name };
        remote = name[0..slash];
    }
    return .{ .remote = remote, .branch = name[remote.len + 1 ..] };
}

pub fn clearPrompt() void {
    if (app.prompt) |p| app.gpa.free(p.arg);
    app.prompt = null;
    app.prompt_text.clearRetainingCapacity();
}

/// Run the command the name was for. A failure keeps the bar open with the text
/// still in it, because the usual failure is a name that is already taken.
pub fn runPrompt() void {
    const p = app.prompt orelse return;

    const name = std.mem.trim(u8, app.prompt_text.items, " \t");
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
        .new_tag => if (app.commit_prefs.sign_tags)
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
            tab_strip.groupTab(name, repo_io.group_target[0], repo_io.group_target[1]);
            return clearPrompt();
        },
        .rename_group => {
            tab_strip.renameGroup(repo_io.group_target[0], name);
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
pub fn doDiscard(path: []const u8) void {
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
    const w = app.work orelse return true;
    for (w.unstaged) |change| {
        if (change.status != .added and (path.len == 0 or std.mem.eql(u8, change.path, path))) return true;
    }
    return false;
}

/// Where the change at `path` was renamed from; `path` itself for anything
/// that was not renamed, or is no longer listed.
pub fn oldPathOf(side: git.DiffSide, path: []const u8) []const u8 {
    const w = app.work orelse return path;
    for (if (side == .staged) w.staged else w.unstaged) |change| {
        if (std.mem.eql(u8, change.path, path)) return change.old_path;
    }
    return path;
}

/// Amend ticked over an empty message: the last commit's, to edit rather than
/// type again — amending is most often fixing a word of it.
pub fn fillFromHead() void {
    if (app.commit_summary.items.len > 0 or app.commit_description.items.len > 0) return;
    const r = app.repo orelse return;
    const head = (app.history orelse return).head_oid orelse return;
    const whole = r.commitMessage(dvui.currentWindow().arena(), head);
    const nl = std.mem.indexOfScalar(u8, whole, '\n') orelse whole.len;
    app.commit_summary.appendSlice(app.gpa, std.mem.trimEnd(u8, whole[0..nl], " \r")) catch return;
    app.commit_description.appendSlice(app.gpa, std.mem.trim(u8, whole[nl..], " \t\r\n")) catch {};
}

pub fn doCommit() void {
    if (app.commit_summary.items.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const text = commit_view.commitMessage(arena.allocator()) catch return;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(app.gpa);

    args.append(app.gpa, "commit") catch return;
    if (app.amend) args.append(app.gpa, "--amend") catch return;
    if (app.commit_prefs.signoff) args.append(app.gpa, "--signoff") catch return;
    if (app.commit_prefs.sign) args.append(app.gpa, "-S") catch return;
    // One `-m` holding the whole message: two would put a blank line between
    // the description and the trailers git reads the co-authors from.
    args.append(app.gpa, "-m") catch return;
    args.append(app.gpa, text) catch return;

    // On another thread, with the status bar's pill: a commit runs the hooks
    // and the signing, which can wait on a passphrase, and on Windows even a
    // plain one held the window up.
    commit_sent.clearRetainingCapacity();
    commit_sent.appendSlice(app.gpa, text) catch {};
    startLocal("Committing", args.items, .commit);
}

/// The message of the commit out on its job. The box stays editable while it
/// runs; when it lands, the box is emptied only if it still says this.
pub var commit_sent: std.ArrayList(u8) = .empty;

/// A commit's outcome, folded in: the box emptied for the next one, or the
/// identity asked for when git said it has none.
fn commitLanded() void {
    // git's own words for an identity it does not have.
    if (tab_strip.command_error) |message| {
        if (std.mem.indexOf(u8, message, "tell me who you are") != null or std.mem.indexOf(u8, message, "user.email") != null) identity_view.openIdentity();
        return;
    }
    // Typed into while the commit ran: that is the next message, not this one.
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const now = commit_view.commitMessage(arena.allocator()) catch "";
    const unchanged = std.mem.eql(u8, now, commit_sent.items);
    commit_sent.clearRetainingCapacity();
    if (!unchanged) return;
    app.commit_summary.clearRetainingCapacity();
    app.commit_description.clearRetainingCapacity();
    app.amend = false;
    app.commit_type = null;
    app.commit_scope.clearRetainingCapacity();
    commit_view.clearCoAuthors();
    app.template_due = true;
}
