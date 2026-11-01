//! GitHub's pull requests, issues and checks, read through its GraphQL API
//! (`github.zig`: Zit's own sign-in, then `curl`). Listing goes off the UI
//! thread like any network read; everything that acts on a request is a call
//! the caller runs as a job.

const std = @import("std");
const run = @import("run.zig");
const github = @import("github.zig");

pub const Host = enum { none, github };

pub const Request = struct {
    number: u32,
    title: []const u8,
    branch: []const u8,
    author: []const u8,
    draft: bool,
    /// Where it merges into.
    base: []const u8 = "",
    /// GitHub's word for where review stands: APPROVED, CHANGES_REQUESTED,
    /// REVIEW_REQUIRED, or empty.
    review: []const u8 = "",
    /// Lines added and removed.
    additions: u32 = 0,
    deletions: u32 = 0,
    labels: []const Label = &.{},
    /// Seconds since the epoch; 0 when unknown.
    created: i64 = 0,
    updated: i64 = 0,
    /// Git says it cannot merge as it stands.
    conflict: bool = false,
    /// The head commit, for its checks. Empty when unknown.
    sha: []const u8 = "",
    /// Who is asked to review it, by login.
    reviewers: []const []const u8 = &.{},
};

pub const Label = struct {
    name: []const u8,
    /// "rrggbb", or empty for the host's default.
    color: []const u8 = "",
};

/// "2026-10-23T14:30:00Z" (or with a fraction or an offset after the
/// seconds, which are ignored) as seconds since the epoch; 0 if it is not one.
pub fn isoSeconds(text: []const u8) i64 {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or text[13] != ':' or text[16] != ':') return 0;
    const num = struct {
        fn f(t: []const u8) ?i64 {
            return std.fmt.parseInt(i64, t, 10) catch null;
        }
    }.f;
    const y = num(text[0..4]) orelse return 0;
    const m = num(text[5..7]) orelse return 0;
    const d = num(text[8..10]) orelse return 0;
    const hh = num(text[11..13]) orelse return 0;
    const mm = num(text[14..16]) orelse return 0;
    const ss = num(text[17..19]) orelse return 0;
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

/// One pull request in full: what the detail pane shows.
pub const Detail = struct {
    number: u32,
    /// GitHub's node id: what its mutations name the request by.
    id: []const u8 = "",
    title: []const u8 = "",
    body: []const u8 = "",
    author: []const u8 = "",
    state: []const u8 = "",
    draft: bool = false,
    review: []const u8 = "",
    /// MERGEABLE, CONFLICTING or UNKNOWN.
    mergeable: []const u8 = "",
    head: []const u8 = "",
    /// The head branch lives in a fork, not in this repository.
    fork: bool = false,
    base: []const u8 = "",
    url: []const u8 = "",
    additions: u32 = 0,
    deletions: u32 = 0,
    files: u32 = 0,
    comments: []const Note = &.{},
    reviews: []const Note = &.{},
    checks: []const Check = &.{},
    /// Line comments, grouped the way GitHub groups them.
    threads: []const Thread = &.{},
    labels: []const Label = &.{},
    assignees: []const []const u8 = &.{},
    /// Everyone asked or who answered, with where they stand.
    reviewers: []const Reviewer = &.{},
    /// GitHub's mergeStateStatus: CLEAN, BEHIND, BLOCKED, DIRTY, UNSTABLE,
    /// DRAFT, HAS_HOOKS or UNKNOWN.
    merge_state: []const u8 = "",
    commits: []const PrCommit = &.{},
    file_list: []const PrFile = &.{},
    head_sha: []const u8 = "",
    /// Set to merge itself once the checks pass.
    auto_merge: bool = false,
    created: i64 = 0,
};

pub const Reviewer = struct {
    login: []const u8,
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, or REQUESTED for
    /// one asked who has not answered.
    state: []const u8,
};

pub const PrCommit = struct {
    oid: []const u8,
    headline: []const u8,
    author: []const u8,
    when: i64,
};

pub const PrFile = struct {
    path: []const u8,
    additions: u32 = 0,
    deletions: u32 = 0,
};

/// A conversation on a line of the diff: where, whether it is settled, and
/// what was said, first comment first.
pub const Thread = struct {
    /// GitHub's node id, what resolving and replying name it by.
    id: []const u8 = "",
    resolved: bool = false,
    /// The line it was left on has changed since.
    outdated: bool = false,
    path: []const u8 = "",
    /// The line now, or where it was when the line has gone; 0 for neither.
    line: u32 = 0,
    /// Where it starts when it was left on several lines, through `line`;
    /// 0 for one line.
    start_line: u32 = 0,
    /// The diff the first comment was left under, ending at its line.
    hunk: []const u8 = "",
    /// The review it was opened with, by its id: GitHub shows it under it.
    review: []const u8 = "",
    can_resolve: bool = false,
    can_unresolve: bool = false,
    can_reply: bool = false,
    comments: []const Note = &.{},
};

/// A comment or a review: who, what they said, and for a review its verdict.
pub const Note = struct {
    /// A review's node id, what its threads name it by; empty for a comment.
    id: []const u8 = "",
    author: []const u8 = "",
    body: []const u8 = "",
    when: []const u8 = "",
    state: []const u8 = "",
};

pub const Check = struct {
    name: []const u8 = "",
    /// SUCCESS, FAILURE, PENDING… whichever word the check reported.
    result: []const u8 = "",
    /// The workflow a check run belongs to; empty for a status.
    group: []const u8 = "",
    /// Where its log is.
    url: []const u8 = "",
    /// How long it ran, in seconds; 0 if unknown or still running.
    seconds: i64 = 0,
};

pub const Status = enum { idle, loading, ready, failed };

// === The queries ===
//
// GraphQL keeps connections as `{nodes:[…]}`, the shape the readers below take.

/// Open, merged or closed requests, newest change first.
const LIST_QUERY =
    \\query($owner:String!,$name:String!,$states:[PullRequestState!]!,$first:Int!){repository(owner:$owner,name:$name){
    \\pullRequests(states:$states,first:$first,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{
    \\number title headRefName baseRefName isDraft reviewDecision additions deletions createdAt updatedAt mergeable headRefOid
    \\author{login} labels(first:20){nodes{name color}}
    \\reviewRequests(first:20){nodes{requestedReviewer{... on User{login} ... on Team{name} ... on Bot{login}}}}}}}}
;

/// One request in full, its review threads and its head's checks with it.
const DETAIL_QUERY =
    \\query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
    \\id number title body state isDraft reviewDecision mergeable mergeStateStatus headRefName baseRefName url isCrossRepository
    \\additions deletions changedFiles createdAt headRefOid author{login} autoMergeRequest{enabledAt}
    \\comments(first:100){nodes{author{login} body createdAt}}
    \\reviews(first:100){nodes{id author{login} body submittedAt state}}
    \\latestReviews(first:50){nodes{author{login} state}}
    \\reviewRequests(first:50){nodes{requestedReviewer{... on User{login} ... on Team{name} ... on Bot{login}}}}
    \\labels(first:30){nodes{name color}}
    \\assignees(first:20){nodes{login}}
    \\commits(first:100){nodes{commit{oid messageHeadline committedDate authors(first:1){nodes{name user{login}}}}}}
    \\files(first:100){nodes{path additions deletions}}
    \\head:commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename
    \\... on CheckRun{name conclusion status detailsUrl startedAt completedAt checkSuite{workflowRun{workflow{name}}}}
    \\... on StatusContext{context state targetUrl}}}}}}}
    \\reviewThreads(first:100){nodes{id isResolved isOutdated path line originalLine startLine originalStartLine
    \\viewerCanResolve viewerCanUnresolve viewerCanReply
    \\comments(first:100){nodes{author{login} body createdAt diffHunk pullRequestReview{id}}}}}}}}
;

/// What a new request can be given: who it can be assigned to or asked to
/// review, the labels it can carry, the branch it goes into by default.
const META_QUERY =
    \\query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
    \\defaultBranchRef{name}
    \\assignableUsers(first:100){nodes{login name}}
    \\labels(first:100,orderBy:{field:NAME,direction:ASC}){nodes{name color description}}}}
;

const ISSUES_QUERY =
    \\query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
    \\issues(states:OPEN,first:100,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number title author{login} labels(first:20){nodes{name}}}}}}
;

/// `T`'s GraphQL connection: its nodes, any of which may be null.
fn Nodes(comptime T: type) type {
    return struct { nodes: []const ?T = &.{} };
}
const Who = struct { login: ?[]const u8 = null };
/// Whoever a review was asked of: a person, a team or a bot.
const Asked = struct { requestedReviewer: ?struct { login: ?[]const u8 = null, name: ?[]const u8 = null } = null };
const LabelNode = struct { name: ?[]const u8 = null, color: ?[]const u8 = null };
const json_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// A GitHub login, or "ghost" — GitHub's own name for a deleted account.
fn who(w: ?Who) []const u8 {
    const v = w orelse return "ghost";
    return v.login orelse "ghost";
}

pub var host: Host = .none;
pub var status: Status = .idle;
/// Why the listing failed, in GitHub's words where it gave any.
pub var last_error: std.ArrayList(u8) = .empty;
/// Owned by `arena`, replaced whole on each listing.
pub var list: []const Request = &.{};

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
var arena: ?std.heap.ArenaAllocator = null;
var worker: ?*run.Capture = null;
var initialised = false;
/// The repository the listing and the detail are for: the last one asked
/// about. An answer for any other is dropped when it lands.
var current: std.ArrayList(u8) = .empty;
/// `owner/name` on GitHub of the repository at `current`.
var slug: std.ArrayList(u8) = .empty;
/// A listing was asked for while one was out; it is asked again when that
/// one lands.
var again = false;

pub fn init(allocator: std.mem.Allocator, the_io: std.Io) void {
    gpa = allocator;
    io = the_io;
    initialised = true;
}

pub fn deinit() void {
    if (!initialised) return;
    if (issues_worker) |w| w.deinit(io);
    issues_worker = null;
    clearIssues();
    issues_error.deinit(gpa);
    issues_error = .empty;
    if (ci_worker) |w| w.deinit(io);
    ci_worker = null;
    ci_states.deinit(gpa);
    ci_states = .empty;
    ci_asked.deinit(gpa);
    ci_asked = .empty;
    if (worker) |w| finish(w);
    if (past_worker) |w| w.deinit(io);
    past_worker = null;
    clearPast();
    if (detail_worker) |w| {
        if (w.future) |*f| f.await(io);
        finishDetail(w);
    }
    clearDetail();
    if (meta_worker) |w| w.deinit(io);
    meta_worker = null;
    clearMeta();
    meta_for.deinit(gpa);
    meta_for = .empty;
    current.deinit(gpa);
    current = .empty;
    slug.deinit(gpa);
    slug = .empty;
    again = false;
    if (arena) |*a| a.deinit();
    arena = null;
    list = &.{};
    host = .none;
    status = .idle;
    last_error.deinit(gpa);
    last_error = .empty;
}

/// Which host a remote URL is on, by the name of its host — the path may say
/// anything. Enterprise hosts named otherwise are not guessed at.
pub fn hostOf(url: []const u8) Host {
    const r = splitRemote(url) orelse return .none;
    if (std.mem.indexOf(u8, r.host, "github") != null) return .github;
    return .none;
}

pub const Remote = struct { host: []const u8, path: []const u8 };

/// The host and the path of a remote URL — `https://host/path`,
/// `ssh://user@host:port/path` or git's scp-like `user@host:path` — without
/// the user or the port. Null for a local path.
pub fn splitRemote(url: []const u8) ?Remote {
    if (std.mem.indexOf(u8, url, "://")) |i| {
        const rest = url[i + 3 ..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        var name = rest[0..end];
        if (std.mem.lastIndexOfScalar(u8, name, '@')) |at| name = name[at + 1 ..];
        if (std.mem.indexOfScalar(u8, name, ':')) |colon| name = name[0..colon];
        return .{ .host = name, .path = if (end < rest.len) rest[end + 1 ..] else "" };
    }
    // As git reads it: a slash before the first colon makes it a path.
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
    var name = url[0..colon];
    if (std.mem.lastIndexOfScalar(u8, name, '@')) |at| name = name[at + 1 ..];
    return .{ .host = name, .path = url[colon + 1 ..] };
}

/// The variables of a query about the repository, `extra` (",\"k\":v"…)
/// after its owner and name; in `gpa`, freed by the caller.
fn vars(extra: []const u8) ![]u8 {
    return github.repoVars(gpa, slug.items, extra);
}

/// What a capture of an API call says went wrong, into `out`; true when
/// nothing did, and `body` is then the answer.
fn answerOf(w: *run.Capture, out: *std.ArrayList(u8), body: *[]const u8) bool {
    out.clearRetainingCapacity();
    if (!w.ok) {
        out.appendSlice(gpa, if (w.err.items.len > 0) w.err.items else "curl failed.") catch {};
        return false;
    }
    const got = github.split(w.out);
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    if (github.failure(a.allocator(), got)) |why| {
        out.appendSlice(gpa, why) catch {};
        return false;
    }
    body.* = got.body;
    return true;
}

/// List the open requests of the repository at `cwd`, `owner_name` on
/// GitHub. A listing already out is left to land, then dropped if it was for
/// another repository, and this one asked for after it.
pub fn refresh(cwd: []const u8, for_host: Host, owner_name: []const u8) void {
    // No host is no host, asked for before anything is set up or not.
    if (for_host == .none) host = .none;
    if (!initialised) return;
    host = for_host;
    // Another repository's list would offer its numbers to act on in this one.
    if (!std.mem.eql(u8, cwd, current.items)) clear();
    setCurrent(cwd);
    if (!std.mem.eql(u8, owner_name, slug.items)) {
        slug.clearRetainingCapacity();
        slug.appendSlice(gpa, owner_name) catch {};
    }
    again = false;
    if (for_host == .none) {
        clear();
        return;
    }
    if (!github.signedIn()) {
        clear();
        status = .failed;
        last_error.clearRetainingCapacity();
        last_error.appendSlice(gpa, "Not connected to GitHub.") catch {};
        return;
    }
    if (worker != null) {
        again = true;
        status = .loading;
        return;
    }
    const v = vars(",\"states\":[\"OPEN\"],\"first\":100") catch return;
    defer gpa.free(v);
    worker = github.graphql(cwd, LIST_QUERY, v) catch return;
    status = .loading;
}

fn setCurrent(cwd: []const u8) void {
    // Re-asking about the same one passes `current` itself.
    if (std.mem.eql(u8, cwd, current.items)) return;
    current.clearRetainingCapacity();
    current.appendSlice(gpa, cwd) catch {};
}

fn clear() void {
    if (arena) |*a| a.deinit();
    arena = null;
    list = &.{};
    status = .idle;
    clearPast();
}

// === Merged and closed ones ===
//
// Asked for only when their tab is opened: the open ones are what everything
// else reads — the sidebar, the branch badges, the checks — and stay as they are.

pub const Past = enum { merged, closed };
pub var past: []const Request = &.{};
pub var past_status: Status = .idle;
pub var past_kind: Past = .merged;
var past_arena: ?std.heap.ArenaAllocator = null;
var past_worker: ?*run.Capture = null;
var past_worker_kind: Past = .merged;

fn clearPast() void {
    if (past_arena) |*a| a.deinit();
    past_arena = null;
    past = &.{};
    past_status = .idle;
}

pub fn refreshPast(cwd: []const u8, kind: Past) void {
    if (!initialised or host == .none or past_worker != null or !github.signedIn()) return;
    past_kind = kind;
    const v = vars(if (kind == .merged) ",\"states\":[\"MERGED\"],\"first\":50" else ",\"states\":[\"CLOSED\"],\"first\":50") catch return;
    defer gpa.free(v);
    past_worker = github.graphql(cwd, LIST_QUERY, v) catch return;
    past_worker_kind = kind;
    past_status = .loading;
}

/// Land a finished listing of merged or closed ones. A listing still out
/// wakes the window itself when it lands (`run.wake`).
pub fn pumpPast() bool {
    const w = past_worker orelse return false;
    if (!w.finished()) return false;
    defer {
        w.deinit(io);
        past_worker = null;
    }
    // Another repository's, or another tab's by now.
    if (!std.mem.eql(u8, w.cwd, current.items) or past_worker_kind != past_kind) return false;
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    var body: []const u8 = "";
    if (answerOf(w, &why, &body)) {
        if (parse(body)) |next| {
            clearPast();
            past_arena = next.arena;
            past = next.list;
            past_status = .ready;
            return false;
        }
    }
    past_status = .failed;
    return false;
}

/// Land a finished listing. Once a frame. A listing still out wakes the
/// window itself when it lands (`run.wake`).
pub fn pump() bool {
    const w = worker orelse return false;
    if (!w.finished()) return false;

    // Asked about another repository since: not this one's answer.
    if (!std.mem.eql(u8, w.cwd, current.items)) {
        finish(w);
        if (again) refresh(current.items, host, slug.items);
        return worker != null;
    }
    var body: []const u8 = "";
    if (answerOf(w, &last_error, &body)) {
        if (parse(body)) |next| {
            clear();
            arena = next.arena;
            list = next.list;
            status = .ready;
        } else {
            status = .failed;
            last_error.print(gpa, "its answer could not be read ({s})", .{parse_error}) catch {};
        }
    } else {
        status = .failed;
    }
    finish(w);
    if (again) refresh(current.items, host, slug.items);
    return worker != null;
}

fn finish(w: *run.Capture) void {
    w.deinit(io);
    worker = null;
}

/// Why the last answer would not read, for the message.
var parse_error: []const u8 = "";

const Parsed = struct { arena: std.heap.ArenaAllocator, list: []const Request };

fn parse(json: []const u8) ?Parsed {
    var a: std.heap.ArenaAllocator = .init(gpa);
    const list_out = parseInto(a.allocator(), json) catch |e| {
        parse_error = @errorName(e);
        a.deinit();
        return null;
    };
    return .{ .arena = a, .list = list_out };
}

fn parseInto(alloc: std.mem.Allocator, json: []const u8) ![]const Request {
    // Every field may be null: a deleted account's pull requests have no
    // author, an unreviewed one no review decision.
    const Node = struct {
        number: u32,
        title: ?[]const u8 = null,
        headRefName: ?[]const u8 = null,
        baseRefName: ?[]const u8 = null,
        isDraft: ?bool = null,
        reviewDecision: ?[]const u8 = null,
        author: ?Who = null,
        additions: ?u32 = null,
        deletions: ?u32 = null,
        labels: ?Nodes(LabelNode) = null,
        createdAt: ?[]const u8 = null,
        updatedAt: ?[]const u8 = null,
        mergeable: ?[]const u8 = null,
        headRefOid: ?[]const u8 = null,
        reviewRequests: ?Nodes(Asked) = null,
    };
    const Answer = struct { data: ?struct { repository: ?struct { pullRequests: Nodes(Node) = .{} } = null } = null };
    const got = try std.json.parseFromSliceLeaky(Answer, alloc, json, json_opts);
    const data = got.data orelse return error.NoData;
    const repo = data.repository orelse return error.NoRepository;
    var out: std.ArrayList(Request) = .empty;
    for (repo.pullRequests.nodes) |maybe| {
        const it = maybe orelse continue;
        var labels: std.ArrayList(Label) = .empty;
        if (it.labels) |ls| for (ls.nodes) |l| if (l) |label| try labels.append(alloc, .{ .name = label.name orelse continue, .color = label.color orelse "" });
        var reviewers: std.ArrayList([]const u8) = .empty;
        if (it.reviewRequests) |rs| for (rs.nodes) |r| if (r) |asked| if (asked.requestedReviewer) |rr| try reviewers.append(alloc, rr.login orelse rr.name orelse continue);
        try out.append(alloc, .{
            .number = it.number,
            .title = it.title orelse "",
            .branch = it.headRefName orelse "",
            .base = it.baseRefName orelse "",
            .author = who(it.author),
            .draft = it.isDraft orelse false,
            .review = it.reviewDecision orelse "",
            .additions = it.additions orelse 0,
            .deletions = it.deletions orelse 0,
            .labels = try labels.toOwnedSlice(alloc),
            .created = isoSeconds(it.createdAt orelse ""),
            .updated = isoSeconds(it.updatedAt orelse ""),
            .conflict = std.mem.eql(u8, it.mergeable orelse "", "CONFLICTING"),
            .sha = it.headRefOid orelse "",
            .reviewers = try reviewers.toOwnedSlice(alloc),
        });
    }
    return out.toOwnedSlice(alloc);
}

// === One request in full ===

pub var detail: ?Detail = null;
pub var detail_status: Status = .idle;
var detail_arena: ?std.heap.ArenaAllocator = null;
var detail_worker: ?*DetailFetch = null;
/// The request the detail is wanted for, null once it is cleared. A read out
/// for any other is dropped when it lands, and this one read instead.
var wanted: ?u32 = null;

const DetailFetch = struct {
    cwd: []u8,
    /// Its variables, owner and name included, made on the UI thread.
    variables: []u8,
    number: u32,
    done: std.atomic.Value(bool) = .init(false),
    ok: bool = false,
    /// The answer's body when `ok`, and otherwise why it failed. Owned.
    out: []u8 = &.{},
    future: ?std.Io.Future(void) = null,

    fn work(self: *DetailFetch) void {
        defer run.wakeUp();
        defer self.done.store(true, .release);
        const body = github.graphqlBody(gpa, DETAIL_QUERY, self.variables) catch return;
        defer gpa.free(body);
        const got = github.call("POST", "/graphql", body) catch return;
        defer got.deinit();
        var a: std.heap.ArenaAllocator = .init(gpa);
        defer a.deinit();
        const answer = got.answer();
        if (github.failure(a.allocator(), answer)) |why| {
            self.out = gpa.dupe(u8, why) catch &.{};
            return;
        }
        self.out = gpa.dupe(u8, answer.body) catch return;
        self.ok = true;
    }
};

/// Read request `number` in full, off the UI thread.
pub fn loadDetail(cwd: []const u8, number: u32) void {
    if (!initialised or host == .none or !github.signedIn()) return;
    setCurrent(cwd);
    wanted = number;
    if (detail_worker != null) return;
    var extra: [32]u8 = undefined;
    const v = vars(std.fmt.bufPrint(&extra, ",\"number\":{d}", .{number}) catch return) catch return;
    const w = gpa.create(DetailFetch) catch return gpa.free(v);
    w.* = .{ .cwd = gpa.dupe(u8, cwd) catch {
        gpa.free(v);
        gpa.destroy(w);
        return;
    }, .variables = v, .number = number };
    detail_worker = w;
    detail_status = .loading;
    w.future = io.concurrent(DetailFetch.work, .{w}) catch blk: {
        w.work();
        break :blk null;
    };
}

pub fn clearDetail() void {
    if (detail_arena) |*a| a.deinit();
    detail_arena = null;
    detail = null;
    detail_status = .idle;
    wanted = null;
}

fn finishDetail(w: *DetailFetch) void {
    gpa.free(w.out);
    gpa.free(w.variables);
    gpa.free(w.cwd);
    gpa.destroy(w);
    detail_worker = null;
}

/// Land a finished detail read. Once a frame.
pub fn pumpDetail() bool {
    const w = detail_worker orelse return false;
    if (!w.done.load(.acquire)) return false;
    if (w.future) |*f| f.await(io);
    // Another request picked, or another repository, while this one was out.
    if (wanted != w.number or !std.mem.eql(u8, w.cwd, current.items)) {
        finishDetail(w);
        if (wanted) |n| loadDetail(current.items, n);
        return detail_worker != null;
    }
    defer finishDetail(w);
    if (!w.ok) {
        detail_status = .failed;
        return false;
    }
    var a: std.heap.ArenaAllocator = .init(gpa);
    const parsed = parseDetail(a.allocator(), w.out) catch {
        a.deinit();
        detail_status = .failed;
        return false;
    };
    clearDetail();
    detail_arena = a;
    detail = parsed;
    detail_status = .ready;
    return false;
}

const Comment = struct {
    author: ?Who = null,
    body: ?[]const u8 = null,
    createdAt: ?[]const u8 = null,
    diffHunk: ?[]const u8 = null,
    pullRequestReview: ?struct { id: []const u8 = "" } = null,
};
const ThreadNode = struct {
    id: []const u8 = "",
    isResolved: bool = false,
    isOutdated: bool = false,
    path: ?[]const u8 = null,
    line: ?u32 = null,
    originalLine: ?u32 = null,
    startLine: ?u32 = null,
    originalStartLine: ?u32 = null,
    viewerCanResolve: bool = false,
    viewerCanUnresolve: bool = false,
    viewerCanReply: bool = false,
    comments: Nodes(Comment) = .{},
};

fn readThreads(alloc: std.mem.Allocator, nodes: []const ?ThreadNode) ![]const Thread {
    var out: std.ArrayList(Thread) = .empty;
    for (nodes) |maybe| {
        const n = maybe orelse continue;
        var notes: std.ArrayList(Note) = .empty;
        var hunk: []const u8 = "";
        var review: []const u8 = "";
        for (n.comments.nodes) |mc| {
            const c = mc orelse continue;
            if (notes.items.len == 0) {
                hunk = c.diffHunk orelse "";
                review = if (c.pullRequestReview) |r| r.id else "";
            }
            try notes.append(alloc, .{ .author = who(c.author), .body = c.body orelse "", .when = c.createdAt orelse "" });
        }
        try out.append(alloc, .{
            .id = n.id,
            .resolved = n.isResolved,
            .outdated = n.isOutdated,
            .path = n.path orelse "",
            // Its first line from the same side as its last: where it is now,
            // or where it was when the line has gone.
            .line = n.line orelse n.originalLine orelse 0,
            .start_line = if (n.line != null) n.startLine orelse 0 else n.originalStartLine orelse 0,
            .hunk = hunk,
            .review = review,
            .can_resolve = n.viewerCanResolve,
            .can_unresolve = n.viewerCanUnresolve,
            .can_reply = n.viewerCanReply,
            .comments = try notes.toOwnedSlice(alloc),
        });
    }
    return out.toOwnedSlice(alloc);
}

fn parseDetail(alloc: std.mem.Allocator, json: []const u8) !Detail {
    // A check run says name/conclusion/status, a commit status
    // context/state: both are read, whichever is there wins.
    const Context = struct {
        name: []const u8 = "",
        context: []const u8 = "",
        conclusion: ?[]const u8 = null,
        status: ?[]const u8 = null,
        state: ?[]const u8 = null,
        detailsUrl: ?[]const u8 = null,
        targetUrl: ?[]const u8 = null,
        startedAt: ?[]const u8 = null,
        completedAt: ?[]const u8 = null,
        checkSuite: ?struct { workflowRun: ?struct { workflow: ?struct { name: ?[]const u8 = null } = null } = null } = null,
    };
    const Pr = struct {
        id: []const u8 = "",
        number: u32,
        title: ?[]const u8 = null,
        body: ?[]const u8 = null,
        author: ?Who = null,
        state: ?[]const u8 = null,
        isDraft: bool = false,
        reviewDecision: ?[]const u8 = null,
        mergeable: ?[]const u8 = null,
        mergeStateStatus: ?[]const u8 = null,
        headRefName: ?[]const u8 = null,
        baseRefName: ?[]const u8 = null,
        url: ?[]const u8 = null,
        isCrossRepository: bool = false,
        additions: u32 = 0,
        deletions: u32 = 0,
        changedFiles: u32 = 0,
        createdAt: ?[]const u8 = null,
        headRefOid: ?[]const u8 = null,
        autoMergeRequest: ?struct { enabledAt: ?[]const u8 = null } = null,
        comments: Nodes(struct { author: ?Who = null, body: ?[]const u8 = null, createdAt: ?[]const u8 = null }) = .{},
        reviews: Nodes(struct { id: []const u8 = "", author: ?Who = null, body: ?[]const u8 = null, submittedAt: ?[]const u8 = null, state: ?[]const u8 = null }) = .{},
        latestReviews: Nodes(struct { author: ?Who = null, state: ?[]const u8 = null }) = .{},
        reviewRequests: Nodes(Asked) = .{},
        labels: Nodes(LabelNode) = .{},
        assignees: Nodes(Who) = .{},
        commits: Nodes(struct { commit: ?struct {
            oid: []const u8 = "",
            messageHeadline: []const u8 = "",
            committedDate: []const u8 = "",
            authors: Nodes(struct { name: ?[]const u8 = null, user: ?Who = null }) = .{},
        } = null }) = .{},
        files: Nodes(struct { path: []const u8 = "", additions: u32 = 0, deletions: u32 = 0 }) = .{},
        head: Nodes(struct { commit: ?struct { statusCheckRollup: ?struct { contexts: Nodes(Context) = .{} } = null } = null }) = .{},
        reviewThreads: Nodes(ThreadNode) = .{},
    };
    const Answer = struct { data: ?struct { repository: ?struct { pullRequest: ?Pr = null } = null } = null };
    const got = try std.json.parseFromSliceLeaky(Answer, alloc, json, json_opts);
    const d = ((got.data orelse return error.NoData).repository orelse return error.NoRepository).pullRequest orelse return error.NoPullRequest;

    var comments: std.ArrayList(Note) = .empty;
    for (d.comments.nodes) |m| if (m) |c| try comments.append(alloc, .{ .author = who(c.author), .body = c.body orelse "", .when = c.createdAt orelse "" });
    var reviews: std.ArrayList(Note) = .empty;
    for (d.reviews.nodes) |m| if (m) |r| try reviews.append(alloc, .{ .id = r.id, .author = who(r.author), .body = r.body orelse "", .when = r.submittedAt orelse "", .state = r.state orelse "" });

    var checks: std.ArrayList(Check) = .empty;
    if (d.head.nodes.len > 0) if (d.head.nodes[d.head.nodes.len - 1]) |h| if (h.commit) |c| if (c.statusCheckRollup) |rollup| {
        for (rollup.contexts.nodes) |m| {
            const k = m orelse continue;
            const began = isoSeconds(k.startedAt orelse "");
            const ended = isoSeconds(k.completedAt orelse "");
            const workflow: []const u8 = if (k.checkSuite) |cs| if (cs.workflowRun) |run_| if (run_.workflow) |wf| wf.name orelse "" else "" else "" else "";
            try checks.append(alloc, .{
                .name = if (k.name.len > 0) k.name else k.context,
                .result = k.conclusion orelse k.state orelse k.status orelse "",
                .group = workflow,
                .url = k.detailsUrl orelse k.targetUrl orelse "",
                .seconds = if (began > 0 and ended >= began) ended - began else 0,
            });
        }
    };

    var labels: std.ArrayList(Label) = .empty;
    for (d.labels.nodes) |m| if (m) |l| try labels.append(alloc, .{ .name = l.name orelse continue, .color = l.color orelse "" });
    var assignees: std.ArrayList([]const u8) = .empty;
    for (d.assignees.nodes) |m| if (m) |w| try assignees.append(alloc, w.login orelse continue);
    // Those who answered, in their latest word; then those asked who have
    // not yet.
    var reviewers: std.ArrayList(Reviewer) = .empty;
    for (d.latestReviews.nodes) |m| if (m) |r| try reviewers.append(alloc, .{ .login = who(r.author), .state = r.state orelse "" });
    for (d.reviewRequests.nodes) |m| if (m) |asked| if (asked.requestedReviewer) |rr| try reviewers.append(alloc, .{ .login = rr.login orelse rr.name orelse continue, .state = "REQUESTED" });
    var commits: std.ArrayList(PrCommit) = .empty;
    for (d.commits.nodes) |m| if (m) |node| if (node.commit) |c| {
        var author: []const u8 = "";
        if (c.authors.nodes.len > 0) if (c.authors.nodes[0]) |first| {
            author = if (first.user) |u| u.login orelse first.name orelse "" else first.name orelse "";
        };
        try commits.append(alloc, .{ .oid = c.oid, .headline = c.messageHeadline, .author = author, .when = isoSeconds(c.committedDate) });
    };
    var files: std.ArrayList(PrFile) = .empty;
    for (d.files.nodes) |m| if (m) |f| try files.append(alloc, .{ .path = f.path, .additions = f.additions, .deletions = f.deletions });

    return .{
        .id = d.id,
        .number = d.number,
        .title = d.title orelse "",
        .body = d.body orelse "",
        .author = who(d.author),
        .state = d.state orelse "",
        .draft = d.isDraft,
        .review = d.reviewDecision orelse "",
        .mergeable = d.mergeable orelse "",
        .head = d.headRefName orelse "",
        .fork = d.isCrossRepository,
        .base = d.baseRefName orelse "",
        .url = d.url orelse "",
        .additions = d.additions,
        .deletions = d.deletions,
        .files = d.changedFiles,
        .comments = try comments.toOwnedSlice(alloc),
        .reviews = try reviews.toOwnedSlice(alloc),
        .checks = try checks.toOwnedSlice(alloc),
        .threads = try readThreads(alloc, d.reviewThreads.nodes),
        .labels = try labels.toOwnedSlice(alloc),
        .assignees = try assignees.toOwnedSlice(alloc),
        .reviewers = try reviewers.toOwnedSlice(alloc),
        .merge_state = d.mergeStateStatus orelse "",
        .commits = try commits.toOwnedSlice(alloc),
        .file_list = try files.toOwnedSlice(alloc),
        .head_sha = d.headRefOid orelse "",
        .auto_merge = d.autoMergeRequest != null,
        .created = isoSeconds(d.createdAt orelse ""),
    };
}

// === CI ===
//
// What GitHub's checks said about the newest commits, one GraphQL query for
// all of them — a request per commit would be forty a refresh.

pub const Ci = enum { pending, success, failure };

/// A commit by its full sha, as GitHub names it.
pub const Sha = [40]u8;

/// Kept across reads: a finished check does not change, and a commit seen
/// with none is asked again only while it is among the newest.
var ci_states: std.AutoHashMapUnmanaged(Sha, Ci) = .empty;
var ci_worker: ?*run.Capture = null;
/// The commits the query out asked about, in the order of its `c0`, `c1`….
var ci_asked: std.ArrayList(Sha) = .empty;
var ci_last_s: i64 = 0;
const CI_EVERY_S = 60;

pub fn ciOf(sha: Sha) ?Ci {
    return ci_states.get(sha);
}

/// Ask about `shas`, the newest commits, at most once a minute. Finished
/// ones are not asked again.
pub fn ciRefresh(cwd: []const u8, shas: []const Sha, now_s: i64) void {
    if (!initialised or host != .github or ci_worker != null or !github.signedIn()) return;
    if (now_s - ci_last_s < CI_EVERY_S) return;
    ci_last_s = now_s;

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(gpa);
    ci_asked.clearRetainingCapacity();
    query.appendSlice(gpa, "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){") catch return;
    for (shas) |sha| {
        if (ci_states.get(sha)) |known| if (known != .pending) continue;
        query.print(gpa, "c{d}:object(oid:\"{s}\"){{... on Commit{{statusCheckRollup{{state}}}}}}", .{ ci_asked.items.len, &sha }) catch return;
        ci_asked.append(gpa, sha) catch return;
    }
    if (ci_asked.items.len == 0) return;
    query.appendSlice(gpa, "}}") catch return;
    const v = vars("") catch return;
    defer gpa.free(v);
    ci_worker = github.graphql(cwd, query.items, v) catch null;
}

/// Land a finished CI read. Once a frame; true when one landed.
pub fn ciPump() bool {
    const w = ci_worker orelse return false;
    if (!w.finished()) return false;
    defer {
        w.deinit(io);
        ci_worker = null;
    }
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    var body: []const u8 = "";
    if (!answerOf(w, &why, &body)) return false;
    readCi(body) catch return false;
    return true;
}

fn readCi(json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const data = parsed.value.object.get("data") orelse return;
    if (data != .object) return;
    const repo = data.object.get("repository") orelse return;
    if (repo != .object) return;
    for (ci_asked.items, 0..) |sha, i| {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "c{d}", .{i}) catch continue;
        const commit = repo.object.get(key) orelse continue;
        if (commit != .object) continue;
        const rollup = commit.object.get("statusCheckRollup") orelse continue;
        if (rollup != .object) continue;
        const state = rollup.object.get("state") orelse continue;
        if (state != .string) continue;
        const ci: Ci = if (std.mem.eql(u8, state.string, "SUCCESS"))
            .success
        else if (std.mem.eql(u8, state.string, "FAILURE") or std.mem.eql(u8, state.string, "ERROR"))
            .failure
        else
            .pending;
        try ci_states.put(gpa, sha, ci);
    }
}

// === Issues ===
//
// The open issues, listed the way the requests are, into an arena of their
// own. Opening and filing one is GitHub's own page.

pub const Issue = struct {
    number: u32,
    title: []const u8,
    author: []const u8,
    /// Its labels' names, for the chips beside it.
    labels: []const []const u8 = &.{},
};

pub var issues: []const Issue = &.{};
pub var issues_status: Status = .idle;
/// Why the last listing failed, for the message.
pub var issues_error: std.ArrayList(u8) = .empty;
var issues_arena: ?std.heap.ArenaAllocator = null;
var issues_worker: ?*run.Capture = null;

fn clearIssues() void {
    if (issues_arena) |*a| a.deinit();
    issues_arena = null;
    issues = &.{};
    issues_status = .idle;
}

/// List the open issues of the repository the requests were last listed
/// for. A listing already out is left to land.
pub fn refreshIssues(cwd: []const u8) void {
    if (!initialised or issues_worker != null) return;
    if (host == .none or !github.signedIn()) return clearIssues();
    const v = vars("") catch return;
    defer gpa.free(v);
    issues_worker = github.graphql(cwd, ISSUES_QUERY, v) catch return;
    issues_status = .loading;
}

/// Land a finished listing. Once a frame; true when one landed.
pub fn pumpIssues() bool {
    const w = issues_worker orelse return false;
    if (!w.finished()) return false;
    defer {
        w.deinit(io);
        issues_worker = null;
    }
    // Another repository since: not this one's answer.
    if (host == .none or !std.mem.eql(u8, w.cwd, current.items)) {
        clearIssues();
        return true;
    }
    var body: []const u8 = "";
    if (!answerOf(w, &issues_error, &body)) {
        issues_status = .failed;
        return true;
    }
    var a: std.heap.ArenaAllocator = .init(gpa);
    const list_out = parseIssues(a.allocator(), body) catch |e| {
        a.deinit();
        issues_status = .failed;
        issues_error.print(gpa, "its answer could not be read ({s})", .{@errorName(e)}) catch {};
        return true;
    };
    clearIssues();
    issues_arena = a;
    issues = list_out;
    issues_status = .ready;
    return true;
}

// === What a new request can be given ===
//
// Read when the create dialog opens, for its pickers: the people, the
// labels, the default base. Once per repository; kept until another is
// asked for.

pub const Person = struct {
    login: []const u8,
    /// Their name on the host, empty where they gave none.
    name: []const u8 = "",
};

pub const RepoLabel = struct {
    name: []const u8,
    color: []const u8 = "",
    description: []const u8 = "",
};

pub const Meta = struct {
    default_branch: []const u8 = "",
    people: []const Person = &.{},
    labels: []const RepoLabel = &.{},
};

pub var meta: Meta = .{};
pub var meta_status: Status = .idle;
var meta_arena: ?std.heap.ArenaAllocator = null;
var meta_worker: ?*run.Capture = null;
/// The repository `meta` is for: asked again only for another.
var meta_for: std.ArrayList(u8) = .empty;

pub fn clearMeta() void {
    if (meta_arena) |*a| a.deinit();
    meta_arena = null;
    meta = .{};
    meta_status = .idle;
    meta_for.clearRetainingCapacity();
}

/// Ask for what a new request of the repository at `cwd` can be given,
/// unless it is already here or on its way.
pub fn loadMeta(cwd: []const u8) void {
    if (!initialised or meta_worker != null) return;
    if (host == .none or !github.signedIn()) return;
    if (meta_status == .ready and std.mem.eql(u8, meta_for.items, cwd)) return;
    setCurrent(cwd);
    const v = vars("") catch return;
    defer gpa.free(v);
    meta_worker = github.graphql(cwd, META_QUERY, v) catch return;
    meta_status = .loading;
}

/// Land it. Once a frame; true when it landed.
pub fn pumpMeta() bool {
    const w = meta_worker orelse return false;
    if (!w.finished()) return false;
    defer {
        w.deinit(io);
        meta_worker = null;
    }
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    var body: []const u8 = "";
    if (!answerOf(w, &why, &body)) {
        meta_status = .failed;
        return true;
    }
    var a: std.heap.ArenaAllocator = .init(gpa);
    const got = parseMeta(a.allocator(), body) catch {
        a.deinit();
        meta_status = .failed;
        return true;
    };
    clearMeta();
    meta_arena = a;
    meta = got;
    meta_for.appendSlice(gpa, w.cwd) catch {};
    meta_status = .ready;
    return true;
}

fn parseMeta(alloc: std.mem.Allocator, json: []const u8) !Meta {
    const PersonNode = struct { login: ?[]const u8 = null, name: ?[]const u8 = null };
    const LabelMeta = struct { name: ?[]const u8 = null, color: ?[]const u8 = null, description: ?[]const u8 = null };
    const Answer = struct { data: ?struct { repository: ?struct {
        defaultBranchRef: ?struct { name: ?[]const u8 = null } = null,
        assignableUsers: Nodes(PersonNode) = .{},
        labels: Nodes(LabelMeta) = .{},
    } = null } = null };
    const got = try std.json.parseFromSliceLeaky(Answer, alloc, json, json_opts);
    const repo = (got.data orelse return error.NoData).repository orelse return error.NoRepository;
    var people: std.ArrayList(Person) = .empty;
    for (repo.assignableUsers.nodes) |maybe| {
        const p = maybe orelse continue;
        try people.append(alloc, .{ .login = p.login orelse continue, .name = p.name orelse "" });
    }
    var labels: std.ArrayList(RepoLabel) = .empty;
    for (repo.labels.nodes) |maybe| {
        const l = maybe orelse continue;
        try labels.append(alloc, .{ .name = l.name orelse continue, .color = l.color orelse "", .description = l.description orelse "" });
    }
    return .{
        .default_branch = if (repo.defaultBranchRef) |b| b.name orelse "" else "",
        .people = try people.toOwnedSlice(alloc),
        .labels = try labels.toOwnedSlice(alloc),
    };
}

fn parseIssues(alloc: std.mem.Allocator, json: []const u8) ![]const Issue {
    const Node = struct {
        number: u32,
        title: ?[]const u8 = null,
        author: ?Who = null,
        labels: ?Nodes(struct { name: ?[]const u8 = null }) = null,
    };
    const Answer = struct { data: ?struct { repository: ?struct { issues: Nodes(Node) = .{} } = null } = null };
    const got = try std.json.parseFromSliceLeaky(Answer, alloc, json, json_opts);
    const repo = (got.data orelse return error.NoData).repository orelse return error.NoRepository;
    var out: std.ArrayList(Issue) = .empty;
    for (repo.issues.nodes) |maybe| {
        const it = maybe orelse continue;
        var labels: std.ArrayList([]const u8) = .empty;
        if (it.labels) |ls| for (ls.nodes) |l| if (l) |label| if (label.name) |n| try labels.append(alloc, n);
        try out.append(alloc, .{
            .number = it.number,
            .title = it.title orelse "",
            .author = who(it.author),
            .labels = try labels.toOwnedSlice(alloc),
        });
    }
    return out.toOwnedSlice(alloc);
}

// === Tests ===
//
// The shapes below are GitHub's own answers to the queries above, cut down
// from ones taken on a real repository.

test "a listing reads its size, labels, dates, conflict, head and reviewers" {
    init(std.testing.allocator, std.testing.io);
    defer deinit();
    const json =
        \\{"data":{"repository":{"pullRequests":{"nodes":[
        \\{"number":4,"title":"t","headRefName":"x","baseRefName":"main","isDraft":false,"reviewDecision":"APPROVED","author":{"login":"a"},"additions":12,"deletions":3,
        \\"labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},"createdAt":"2026-10-20T10:00:00Z","updatedAt":"2026-10-23T14:30:05Z",
        \\"mergeable":"CONFLICTING","headRefOid":"abc","reviewRequests":{"nodes":[{"requestedReviewer":{"login":"bo"}},{"requestedReviewer":{"name":"core"}}]}},
        \\null,
        \\{"number":9,"title":null,"headRefName":"y","author":null,"isDraft":null,"reviewDecision":null,"labels":null,"reviewRequests":null}]}}}}
    ;
    var got = parse(json).?;
    defer got.arena.deinit();
    try std.testing.expectEqual(@as(usize, 2), got.list.len);
    const r = got.list[0];
    try std.testing.expectEqual(@as(u32, 12), r.additions);
    try std.testing.expectEqualStrings("d73a4a", r.labels[0].color);
    try std.testing.expect(r.conflict);
    try std.testing.expectEqualStrings("abc", r.sha);
    try std.testing.expectEqualStrings("APPROVED", r.review);
    try std.testing.expectEqualStrings("core", r.reviewers[1]);
    try std.testing.expectEqual(@as(i64, 1792765805), r.updated);
    // Nulls everywhere a deleted account or an untouched request leaves them.
    try std.testing.expectEqualStrings("ghost", got.list[1].author);
    try std.testing.expectEqualStrings("", got.list[1].review);
    try std.testing.expectEqual(@as(i64, 0), isoSeconds("yesterday"));
    // A repository GitHub does not show this account.
    try std.testing.expect(parse("{\"data\":{\"repository\":null}}") == null);
}

test "a pull request reads in full: reviews, comments, checks and threads" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const json =
        \\{"data":{"repository":{"pullRequest":{"id":"PR_kw","number":61,"title":"Login","body":"Adds login","state":"OPEN","isDraft":false,
        \\"reviewDecision":"CHANGES_REQUESTED","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","headRefName":"PROJ-25","baseRefName":"develop",
        \\"url":"https://github.com/o/r/pull/61","additions":815,"deletions":2,"changedFiles":15,"createdAt":"2026-10-20T08:00:00Z","headRefOid":"abc",
        \\"author":{"login":"MeretoF"},"autoMergeRequest":null,
        \\"comments":{"nodes":[{"author":{"login":"MeretoF"},"body":"QUERY instead","createdAt":"2026-10-20T08:22:02Z"}]},
        \\"reviews":{"nodes":[{"id":"PRR_1","author":{"login":"Necrelox"},"body":"","submittedAt":"2026-10-20T10:15:10Z","state":"CHANGES_REQUESTED"}]},
        \\"latestReviews":{"nodes":[{"author":{"login":"Necrelox"},"state":"CHANGES_REQUESTED"}]},
        \\"reviewRequests":{"nodes":[{"requestedReviewer":{"login":"ann"}}]},
        \\"labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},"assignees":{"nodes":[{"login":"MeretoF"}]},
        \\"commits":{"nodes":[{"commit":{"oid":"0123","messageHeadline":"add login","committedDate":"2026-10-20T08:00:00Z","authors":{"nodes":[{"name":"Me","user":{"login":"me"}}]}}}]},
        \\"files":{"nodes":[{"path":"src/a.zig","additions":3,"deletions":1}]},
        \\"head":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
        \\{"__typename":"CheckRun","name":"build","conclusion":"SUCCESS","status":"COMPLETED","detailsUrl":"https://x/1","startedAt":"2026-10-20T08:00:00Z","completedAt":"2026-10-20T08:01:15Z","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},
        \\{"__typename":"StatusContext","context":"ci/lint","state":"PENDING","targetUrl":"https://x/2"}]}}}}]},
        \\"reviewThreads":{"nodes":[
        \\{"id":"PRRT_1","isResolved":true,"isOutdated":true,"path":"a.ts","line":null,"originalLine":34,"viewerCanResolve":false,"viewerCanUnresolve":true,"viewerCanReply":true,
        \\"comments":{"nodes":[{"author":{"login":"Necrelox"},"body":"use the db types","createdAt":"2026-10-20T08:38:54Z","diffHunk":"@@ -0,0 +1 @@\n+x"},{"author":null,"body":"ok","createdAt":"2026-10-20T09:00:00Z","diffHunk":"@@"}]}},
        \\{"id":"PRRT_2","isResolved":false,"isOutdated":false,"path":"b.ts","line":7,"originalLine":5,"comments":{"nodes":[]}},
        \\{"id":"PRRT_3","isResolved":false,"isOutdated":false,"path":"c.ts","line":5,"originalLine":5,"startLine":3,"originalStartLine":3,
        \\"comments":{"nodes":[{"author":{"login":"Necrelox"},"body":"this","createdAt":"2026-10-20T10:15:00Z","diffHunk":"@@","pullRequestReview":{"id":"PRR_1"}}]}}]}}}}}
    ;
    const d = try parseDetail(a.allocator(), json);
    try std.testing.expectEqualStrings("PR_kw", d.id);
    try std.testing.expectEqual(@as(u32, 61), d.number);
    try std.testing.expectEqualStrings("develop", d.base);
    try std.testing.expectEqualStrings("QUERY instead", d.comments[0].body);
    try std.testing.expectEqualStrings("CHANGES_REQUESTED", d.reviews[0].state);
    try std.testing.expectEqualStrings("PRR_1", d.reviews[0].id);
    try std.testing.expectEqualStrings("build", d.checks[0].name);
    try std.testing.expectEqualStrings("SUCCESS", d.checks[0].result);
    try std.testing.expectEqualStrings("CI", d.checks[0].group);
    try std.testing.expectEqual(@as(i64, 75), d.checks[0].seconds);
    try std.testing.expectEqualStrings("ci/lint", d.checks[1].name);
    try std.testing.expectEqualStrings("PENDING", d.checks[1].result);
    try std.testing.expectEqualStrings("REQUESTED", d.reviewers[1].state);
    try std.testing.expectEqualStrings("me", d.commits[0].author);
    try std.testing.expectEqual(@as(usize, 1), d.file_list.len);
    try std.testing.expect(!d.auto_merge);
    // Review threads: an outdated one by its original line.
    try std.testing.expectEqual(@as(usize, 3), d.threads.len);
    try std.testing.expectEqual(@as(u32, 34), d.threads[0].line);
    try std.testing.expect(d.threads[0].resolved and d.threads[0].outdated and d.threads[0].can_unresolve and !d.threads[0].can_resolve);
    try std.testing.expectEqualStrings("@@ -0,0 +1 @@\n+x", d.threads[0].hunk);
    try std.testing.expectEqualStrings("ghost", d.threads[0].comments[1].author);
    try std.testing.expectEqual(@as(u32, 7), d.threads[1].line);
    try std.testing.expectEqualStrings("", d.threads[1].hunk);
    // One on lines 3 to 5, opened with the review: shown under it.
    try std.testing.expectEqual(@as(u32, 3), d.threads[2].start_line);
    try std.testing.expectEqual(@as(u32, 5), d.threads[2].line);
    try std.testing.expectEqualStrings("PRR_1", d.threads[2].review);
    try std.testing.expectEqual(@as(u32, 0), d.threads[1].start_line);
}

test "a host by its remote, and answers for another repository dropped" {
    init(std.testing.allocator, std.testing.io);
    defer deinit();

    try std.testing.expectEqual(Host.github, hostOf("git@github.com:me/x.git"));
    try std.testing.expectEqual(Host.none, hostOf("https://gitlab.example.com/me/x"));
    try std.testing.expectEqual(Host.none, hostOf("ssh://git.example.com/x"));
    try std.testing.expectEqual(Host.github, hostOf("ssh://git@ssh.github.com:443/o/r.git"));
    try std.testing.expectEqual(Host.none, hostOf("/home/me/github/x"));
    try std.testing.expectEqualStrings("ssh.github.com", splitRemote("ssh://git@ssh.github.com:443/o/r.git").?.host);
    try std.testing.expectEqualStrings("me/x.git", splitRemote("git@github.com:me/x.git").?.path);

    // A listing asked about another repository is dropped when it lands.
    host = .github;
    setCurrent("/b");
    const w = try run.Capture.start(gpa, io, "/a", &.{"true"});
    while (!w.finished()) try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    worker = w;
    try std.testing.expect(!pump());
    try std.testing.expectEqual(@as(usize, 0), list.len);

    // As is a detail read for a request no longer picked.
    clearDetail();
    const dw = try gpa.create(DetailFetch);
    dw.* = .{ .cwd = try gpa.dupe(u8, "/b"), .variables = try gpa.dupe(u8, "{}"), .number = 5, .ok = true, .out = try gpa.dupe(u8, "{}") };
    dw.done.store(true, .release);
    detail_worker = dw;
    try std.testing.expect(!pumpDetail());
    try std.testing.expectEqual(@as(?Detail, null), detail);
}

test "a batch of commits' checks reads back by sha" {
    init(std.testing.allocator, std.testing.io);
    defer deinit();
    const a: Sha = "a".* ** 40;
    const b: Sha = "b".* ** 40;
    const c: Sha = "c".* ** 40;
    try ci_asked.appendSlice(gpa, &.{ a, b, c });
    try readCi(
        \\{"data":{"repository":{"c0":{"statusCheckRollup":{"state":"FAILURE"}},"c1":{"statusCheckRollup":null},"c2":{"statusCheckRollup":{"state":"PENDING"}}}}}
    );
    try std.testing.expectEqual(Ci.failure, ciOf(a).?);
    try std.testing.expectEqual(@as(?Ci, null), ciOf(b));
    try std.testing.expectEqual(Ci.pending, ciOf(c).?);
}

test "what a new request can be given reads into its shape" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const got = try parseMeta(a.allocator(),
        \\{"data":{"repository":{"defaultBranchRef":{"name":"develop"},"assignableUsers":{"nodes":[{"login":"ann","name":"Ann Lee"},{"login":"bo","name":null},null]},"labels":{"nodes":[{"name":"bug","color":"d73a4a","description":"Something is broken"},{"name":null}]}}}}
    );
    try std.testing.expectEqualStrings("develop", got.default_branch);
    try std.testing.expectEqual(@as(usize, 2), got.people.len);
    try std.testing.expectEqualStrings("Ann Lee", got.people[0].name);
    try std.testing.expectEqualStrings("", got.people[1].name);
    try std.testing.expectEqual(@as(usize, 1), got.labels.len);
    try std.testing.expectEqualStrings("d73a4a", got.labels[0].color);
}

test "issues read into their shape" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const got = try parseIssues(a.allocator(),
        \\{"data":{"repository":{"issues":{"nodes":[{"number":7,"title":"Crash on open","author":{"login":"ann"},"labels":{"nodes":[{"name":"bug"},{"name":"p1"}]}},{"number":8,"title":null,"author":null,"labels":null}]}}}}
    );
    try std.testing.expectEqual(@as(u32, 7), got[0].number);
    try std.testing.expectEqualStrings("p1", got[0].labels[1]);
    try std.testing.expectEqualStrings("ghost", got[1].author);
}
