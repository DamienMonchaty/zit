//! Everything Zit *reads* from a repository, through libgit2.
//!
//! Writes and anything touching the network go through the `git` binary
//! instead (see `run.zig`): credential helpers, the SSH agent, hooks and GPG
//! signing all work for free there, and each of them is a callback maze in
//! libgit2. Reading is the opposite trade — a revwalk beats parsing `git log`
//! output — so it lives here.
//!
//! Every read produces a *snapshot* owned by its own arena (`History`, `Work`).
//! Refreshing throws the arena away and builds a new one rather than patching
//! the old one in place: a git repository is changed by other processes behind
//! Zit's back, and incremental update of a structure nobody else respects is
//! where this kind of program rots.

const std = @import("std");

pub const c = @cImport({
    @cInclude("git2.h");
});

pub const Error = error{Git};

/// How far back the graph reads. Deep enough that no ordinary repository hits
/// it, cheap enough that opening one is instant.
///
/// ponytail: hard cap, no paging. Add "load more" at the bottom of the graph if
/// anyone actually scrolls into it.
pub const MAX_COMMITS: usize = 5000;

/// Message from libgit2's thread-local error slot. Valid until the next failing
/// libgit2 call on this thread, so copy it if it has to outlive the call site.
pub fn lastError() []const u8 {
    const none = "Could not read the repository.";
    // Never null in libgit2 1.8 and later: a "no error" of class NONE instead.
    const e = c.git_error_last() orelse return none;
    if (e.*.klass == c.GIT_ERROR_NONE) return none;
    const msg = e.*.message orelse return none;
    return std.mem.span(msg);
}

/// In `git2/sys/errors.h`, which `git2.h` leaves out.
extern fn git_error_clear() void;

/// Turn a libgit2 return code into a Zig error, logging what libgit2 said.
/// Every raw `c.git_*` call goes through this — a silently ignored negative
/// return is how you end up rendering an empty history and calling it a bug in
/// the graph code.
fn check(code: c_int) Error!void {
    if (code >= 0) return;
    std.log.err("libgit2: {s}", .{lastError()});
    return error.Git;
}

pub fn init() Error!void {
    const count = c.git_libgit2_init();
    if (count < 0) return check(count);

    // libgit2's defaults are sized for a server: a 256MB object cache and a
    // gigabyte of mapped pack windows. A desktop client reads a history once
    // per refresh and keeps its own snapshot of it, so the cache mostly holds
    // objects nobody will ask for again.
    _ = c.git_libgit2_opts(c.GIT_OPT_SET_CACHE_MAX_SIZE, @as(isize, 16 * 1024 * 1024));
    // Small windows into the packfiles, few of them mapped at once: a page
    // of a pack that was read stays in the process's RSS for as long as its
    // window is mapped, and 32 MB windows keep most of a pack resident.
    // Re-mapping is cheap — the kernel still has the pages cached.
    _ = c.git_libgit2_opts(c.GIT_OPT_SET_MWINDOW_SIZE, @as(usize, 1024 * 1024));
    _ = c.git_libgit2_opts(c.GIT_OPT_SET_MWINDOW_MAPPED_LIMIT, @as(usize, 8 * 1024 * 1024));
}

pub fn shutdown() void {
    _ = c.git_libgit2_shutdown();
}

pub const Oid = c.git_oid;

pub fn oidEql(a: Oid, b: Oid) bool {
    return c.git_oid_equal(&a, &b) != 0;
}

/// Abbreviated hex, the seven characters every git UI shows.
pub fn oidShort(oid: Oid, buf: *[8]u8) []const u8 {
    _ = c.git_oid_tostr(buf, buf.len, &oid);
    return buf[0..7];
}

/// Full hex, for the clipboard: seven characters are fine to read and the
/// wrong thing to paste into a script or a ticket.
pub fn oidHex(oid: Oid, buf: *[41]u8) []const u8 {
    _ = c.git_oid_tostr(buf, buf.len, &oid);
    return buf[0..40];
}

/// A full sha back into an id; null for anything else.
pub fn oidFromHex(hex: []const u8) ?Oid {
    if (hex.len != 40) return null;
    var oid: Oid = undefined;
    if (c.git_oid_fromstrn(&oid, hex.ptr, hex.len) < 0) return null;
    return oid;
}

// === Refs ===

pub const Ref = struct {
    /// "main", "origin/main", "v1.2.0".
    name: []const u8,
    kind: Kind,
    /// The commit it points at, after peeling annotated tags.
    target: Oid,
    /// True for the branch HEAD is on.
    head: bool,
    /// A local branch's distance from its upstream; empty for the others.
    tracking: Tracking = .{},
    /// When the commit it points at was made, seconds since the epoch.
    time: i64 = 0,

    pub const Kind = enum { local, remote, tag };
};

// === Commits ===

pub const Commit = struct {
    id: Oid,
    /// First line of the message. Empty for a commit with no message.
    summary: []const u8,
    /// The first line of the rest of the message — a hint of it beside the
    /// summary. Empty when the summary is all there is.
    body: []const u8 = "",
    author: []const u8,
    /// What the avatar is looked up by. Empty when the commit has none.
    email: []const u8 = "",
    /// Seconds since the epoch, in the author's own timezone-free terms.
    time: i64,
    /// In the history's arena. A slice: almost every commit has one parent.
    parents: []const Oid = &.{},
};

// === Working tree ===

pub const Status = enum {
    added,
    modified,
    deleted,
    renamed,
    conflicted,
    /// A file of a commit's whole tree that the commit did not touch.
    unchanged,

    /// The single character shown next to the path in the changes list.
    pub fn glyph(self: Status) []const u8 {
        return switch (self) {
            .added => "+",
            .modified => "~",
            .deleted => "-",
            .renamed => "→",
            .conflicted => "!",
            .unchanged => " ",
        };
    }

    /// The letter on the file flag — git's own porcelain letters, which is
    /// what anyone who has read `git status` is expecting.
    pub fn letter(self: Status) []const u8 {
        return switch (self) {
            .added => "A",
            .modified => "M",
            .deleted => "D",
            .renamed => "R",
            .conflicted => "!",
            .unchanged => "",
        };
    }
};

pub const Change = struct {
    path: []const u8,
    status: Status,
    /// Where a rename came from; the same as `path` for anything else. A
    /// rename is two paths to git, and staging, unstaging or discarding only
    /// the new one leaves the old one half done.
    old_path: []const u8 = "",
};

// === Stashes ===

pub const Stash = struct {
    message: []const u8,
    /// The stash commit: what still names this entry once others are pushed
    /// on top and `stash@{n}` moves.
    id: Oid,
    /// The commit it was made on — what the graph shows, since the stash
    /// commit itself is not walked. Zero when it could not be read.
    base: Oid = std.mem.zeroes(Oid),
};

// === Diffs ===

/// A diff is stored as one flat list of lines per file rather than as nested
/// hunks: the view scrolls through it linearly, and `hunk` is enough to group
/// them again when a hunk is staged.
pub const DiffLine = struct {
    kind: Kind,
    text: []const u8,
    /// 0 when the line does not exist on that side.
    old_no: u32,
    new_no: u32,
    /// Which hunk of its file this line belongs to.
    hunk: u32,

    pub const Kind = enum { hunk_header, context, addition, deletion, no_newline };
};

pub const FileDiff = struct {
    path: []const u8,
    old_path: []const u8,
    status: Status,
    /// The file mode on whichever side it exists, which is what a patch
    /// creating or deleting it has to name.
    mode: u32 = 0o100644,
    lines: []DiffLine,
    hunk_count: u32,
    /// Binary files have no lines to show, only the fact that they changed.
    binary: bool,
};

pub const Diff = struct {
    arena: std.heap.ArenaAllocator,
    files: []FileDiff = &.{},

    pub fn deinit(self: *Diff) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: Diff, path: []const u8) ?FileDiff {
        for (self.files) |f| {
            if (std.mem.eql(u8, f.path, path)) return f;
        }
        return null;
    }
};

/// Which refs the graph is walked from. The default walks them all.
pub const RefFilter = struct {
    /// Branches left out of the graph; the one checked out never is.
    hidden: []const []const u8 = &.{},
    /// Only these, when any are named.
    only: []const []const u8 = &.{},
    /// Remote branches walked too.
    remotes: bool = true,

    /// `hidden` as a set, where the caller keeps one, so each ref is one lookup.
    hidden_set: ?*const std.StringHashMapUnmanaged(void) = null,

    pub fn walks(self: RefFilter, r: Ref) bool {
        if (self.only.len > 0) {
            for (self.only) |name| if (std.mem.eql(u8, name, r.name)) return true;
            return false;
        }
        if (r.head) return true;
        if (!self.remotes and r.kind == .remote) return false;
        if (self.hidden_set) |set| return !set.contains(r.name);
        for (self.hidden) |name| if (std.mem.eql(u8, name, r.name)) return false;
        return true;
    }
};

/// How every diff is read. Set from the UI thread only, between reads; diffs
/// are read on it too.
pub var diff_options: struct {
    ignore_whitespace: bool = false,
    /// Lines of context around each change; git's default is 3.
    context: u32 = 3,
} = .{};

/// Files past this are diffed as binary — "no lines to show" — rather than
/// read: a diff of a 100 MB dump is not read on a screen, and its lines cost
/// about three times their size here. libgit2's own default is 512 MB.
const MAX_DIFF_FILE: i64 = 16 * 1024 * 1024;

fn applyDiffOptions(opts: *c.git_diff_options) void {
    opts.context_lines = diff_options.context;
    opts.max_size = MAX_DIFF_FILE;
    if (diff_options.ignore_whitespace) opts.flags |= c.GIT_DIFF_IGNORE_WHITESPACE;
}

/// Which half of the working tree a diff is taken from.
pub const DiffSide = enum {
    /// HEAD to index: what a commit would record.
    staged,
    /// Index to working tree: what is not staged yet.
    unstaged,
};

/// What git is in the middle of, if anything. Drives the banner that offers
/// continue/abort.
pub const State = enum {
    none,
    merge,
    revert,
    cherrypick,
    bisect,
    rebase,
    apply_mailbox,
    other,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .none => "",
            .merge => "Merging",
            .revert => "Reverting",
            .cherrypick => "Cherry-picking",
            .bisect => "Bisecting",
            .rebase => "Rebasing",
            .apply_mailbox => "Applying patches",
            .other => "In progress",
        };
    }

    /// The subcommand whose `--continue` / `--abort` applies.
    pub fn command(self: State) ?[]const u8 {
        return switch (self) {
            .merge => "merge",
            .revert => "revert",
            .cherrypick => "cherry-pick",
            .rebase => "rebase",
            .bisect, .apply_mailbox, .other, .none => null,
        };
    }
};

// === Remotes ===

pub const Remote = struct {
    name: []const u8,
    /// The fetch URL. Empty for a remote configured with a push URL only.
    url: []const u8,
};

/// A linked working tree: another checkout of this repository, in a folder of
/// its own, on a branch of its own.
pub const Worktree = struct {
    name: []const u8,
    /// Absolute, as git recorded it.
    path: []const u8,
    /// The commit its HEAD is on; zero when it could not be read.
    head: Oid = std.mem.zeroes(Oid),
};

// === Blame ===

pub const BlameLine = struct {
    id: Oid,
    author: []const u8,
    /// Seconds since the epoch. 0 where libgit2 gave no signature, which is
    /// what an uncommitted line looks like.
    time: i64,
    text: []const u8,
};

pub const Blame = struct {
    arena: std.heap.ArenaAllocator,
    lines: []BlameLine = &.{},

    pub fn deinit(self: *Blame) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// === Conflicts ===

/// One `<<<<<<< / ======= / >>>>>>>` region of a file git left conflicted.
///
/// The slices point into the text this was parsed from, which the caller owns.
pub const Conflict = struct {
    /// Byte range of the whole region, markers included: replacing
    /// `text[start..end]` with one of the sides is what resolving it means.
    start: usize,
    end: usize,
    ours: []const u8,
    theirs: []const u8,
    /// The common ancestor, there only when `merge.conflictStyle` is diff3 or
    /// zdiff3. Shown when present, because it is what makes a conflict
    /// readable, and never required.
    base: []const u8,
};

pub const ConflictSide = enum { ours, theirs, both };

const OURS_MARK = "<<<<<<<";
const BASE_MARK = "|||||||";
const SPLIT_MARK = "=======";
const THEIRS_MARK = ">>>>>>>";

/// Index of the next line at or after `from` that is a `mark` line. `from`
/// must itself be the start of a line.
///
/// Git's rule: exactly the seven characters, then a space or the end of the
/// line. `========` is a rule in a README, not a split.
fn findMarker(text: []const u8, from: usize, mark: []const u8) ?usize {
    var i = from;
    while (i < text.len) {
        const stop = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..stop];
        if (std.mem.startsWith(u8, line, mark) and
            (line.len == mark.len or line[mark.len] == ' ' or line[mark.len] == '\r')) return i;
        if (stop == text.len) return null;
        i = stop + 1;
    }
    return null;
}

/// One past the newline that ends the line containing `i`, or the end of text.
fn lineEnd(text: []const u8, i: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return text.len;
    return nl + 1;
}

/// Every conflict region in `text`.
///
/// A marker only counts at the start of a line, which is what git itself
/// requires: a `=======` in the middle of a line of code is not a conflict, and
/// treating it as one would corrupt the file the moment it was resolved.
pub fn parseConflicts(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]Conflict {
    var out: std.ArrayList(Conflict) = .empty;
    errdefer out.deinit(gpa);

    var pos: usize = 0;
    while (pos < text.len) {
        const open = findMarker(text, pos, OURS_MARK) orelse break;
        const ours_start = lineEnd(text, open);

        // A region missing its `=======` or `>>>>>>>` was edited over by hand.
        // Skip past the opener rather than guess where it was meant to end —
        // and the next opener ends the search, or this one would borrow the
        // next region's split and closer and swallow everything in between.
        const next_open = findMarker(text, ours_start, OURS_MARK) orelse text.len;
        const split = findMarker(text, ours_start, SPLIT_MARK) orelse text.len;
        const close = if (split < next_open) findMarker(text, split, THEIRS_MARK) orelse text.len else text.len;
        if (close >= next_open) {
            pos = ours_start;
            continue;
        }

        // Only a `|||||||` before the split is this region's base; a later one
        // belongs to the next conflict down the file.
        const base_at = blk: {
            const at = findMarker(text, ours_start, BASE_MARK) orelse break :blk null;
            break :blk if (at < split) at else null;
        };

        const ours_end = base_at orelse split;
        const end = lineEnd(text, close);

        out.append(gpa, .{
            .start = open,
            .end = end,
            .ours = text[ours_start..ours_end],
            .theirs = text[lineEnd(text, split)..close],
            .base = if (base_at) |at| text[lineEnd(text, at)..split] else "",
        }) catch return error.OutOfMemory;

        pos = end;
    }

    return out.toOwnedSlice(gpa);
}

/// `text` with one conflict replaced by the side chosen for it.
///
/// One region at a time: resolving shifts the offsets of every conflict after
/// it, so the caller re-reads and re-parses rather than reusing a stale list.
pub fn resolveConflict(
    gpa: std.mem.Allocator,
    text: []const u8,
    conflict: Conflict,
    side: ConflictSide,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, text[0..conflict.start]);
    switch (side) {
        .ours => try out.appendSlice(gpa, conflict.ours),
        .theirs => try out.appendSlice(gpa, conflict.theirs),
        .both => {
            try out.appendSlice(gpa, conflict.ours);
            try out.appendSlice(gpa, conflict.theirs);
        },
    }
    try out.appendSlice(gpa, text[conflict.end..]);

    return out.toOwnedSlice(gpa);
}

// === Undo ===

/// How to take back the move the reflog last recorded, as git arguments.
///
/// A checkout goes back to where it came from. A commit, reset, cherry-pick
/// or revert goes back with `--soft`: the branch moves, and what it carried
/// stays staged, so nothing is lost and undoing the undo is a redo. Merges,
/// pulls and rebases bring in other people's work, so they go back with
/// `--keep`, which refuses rather than overwrite anything uncommitted — and to
/// ORIG_HEAD, because their reflog entry's old side is a step in the middle.
///
/// `sha` is the old id, already formatted; `branch_exists` says whether a
/// name checkout left from is a local branch rather than a commit.
pub fn undoArgs(message: []const u8, sha: []const u8, branch_exists: *const fn ([]const u8) bool, out: *[4][]const u8) ?[]const []const u8 {
    if (std.mem.startsWith(u8, message, "checkout: moving from ")) {
        const rest = message["checkout: moving from ".len..];
        const to = std.mem.indexOf(u8, rest, " to ") orelse return null;
        const from = rest[0..to];
        out.* = .{ "switch", from, "", "" };
        if (branch_exists(from)) return out[0..2];
        out.* = .{ "switch", "--detach", from, "" };
        return out[0..3];
    }

    // A merge concluded after a conflict is recorded by `commit (merge)`, and
    // undoing one of these writes `reset: moving to ORIG_HEAD`, which also
    // points ORIG_HEAD back at where it came from — so the redo is the same
    // `--keep` and keeps the tree in step, where `--soft` would stage the
    // whole merge in reverse.
    const via_orig = std.mem.eql(u8, message, "reset: moving to ORIG_HEAD") or
        for ([_][]const u8{ "merge", "pull", "rebase", "commit (merge)" }) |prefix| {
            if (std.mem.startsWith(u8, message, prefix)) break true;
        } else false;
    if (via_orig) {
        out.* = .{ "reset", "--keep", "ORIG_HEAD", "" };
        return out[0..3];
    }

    for ([_][]const u8{ "commit", "reset", "cherry-pick", "revert" }) |prefix| {
        if (!std.mem.startsWith(u8, message, prefix)) continue;
        // The first commit has nothing before it to go back to.
        if (std.mem.startsWith(u8, message, "commit (initial)")) return null;
        out.* = .{ "reset", "--soft", sha, "" };
        return out[0..3];
    }
    return null;
}

test "undo goes back the way the reflog says it came" {
    const has = struct {
        fn f(name: []const u8) bool {
            return std.mem.eql(u8, name, "main");
        }
    }.f;
    var out: [4][]const u8 = undefined;

    const back = undoArgs("checkout: moving from main to feat", "abc", has, &out).?;
    try std.testing.expectEqualStrings("main", back[1]);
    try std.testing.expectEqual(@as(usize, 2), back.len);

    const detached = undoArgs("checkout: moving from 1234567 to main", "abc", has, &out).?;
    try std.testing.expectEqualStrings("--detach", detached[1]);

    const commit = undoArgs("commit: add a thing", "abc", has, &out).?;
    try std.testing.expectEqualStrings("--soft", commit[1]);
    try std.testing.expectEqualStrings("abc", commit[2]);

    try std.testing.expectEqualStrings("ORIG_HEAD", undoArgs("rebase (finish): returning to refs/heads/x", "abc", has, &out).?[2]);

    const concluded = undoArgs("commit (merge): Merge branch 'x'", "abc", has, &out).?;
    try std.testing.expectEqualStrings("--keep", concluded[1]);
    try std.testing.expectEqualStrings("ORIG_HEAD", concluded[2]);
    // The redo of an undone merge: the tree comes back with it.
    const redo = undoArgs("reset: moving to ORIG_HEAD", "abc", has, &out).?;
    try std.testing.expectEqualStrings("--keep", redo[1]);
    // The redo of an undone commit is still soft.
    try std.testing.expectEqualStrings("--soft", undoArgs("reset: moving to abc", "abc", has, &out).?[1]);
    try std.testing.expectEqual(@as(?[]const []const u8, null), undoArgs("commit (initial): first", "abc", has, &out));
    try std.testing.expectEqual(@as(?[]const []const u8, null), undoArgs("clone: from somewhere", "abc", has, &out));
}

// === Interactive rebase ===

/// What to do with one commit in a rebase todo list.
pub const RebaseAction = enum {
    pick,
    reword,
    squash,
    fixup,
    drop,

    /// The word `git rebase -i` reads, which is also what the button shows.
    pub fn verb(self: RebaseAction) []const u8 {
        return switch (self) {
            .pick => "pick",
            .reword => "reword",
            .squash => "squash",
            .fixup => "fixup",
            .drop => "drop",
        };
    }

    /// What it does, for the row that is not just a verb.
    pub fn hint(self: RebaseAction) []const u8 {
        return switch (self) {
            .pick => "keep",
            .reword => "keep, new message",
            .squash => "fold up, merge messages",
            .fixup => "fold up, drop message",
            .drop => "discard",
        };
    }
};

pub const RebaseStep = struct {
    id: Oid,
    summary: []const u8,
    action: RebaseAction = .pick,
};

/// The todo list `git rebase -i` reads, oldest first — the opposite of the
/// order the graph shows them in, so the caller passes them already reversed.
pub fn rebaseTodo(gpa: std.mem.Allocator, steps: []const RebaseStep) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // The first commit that survives cannot fold into the one above it, because
    // there is nothing above it: git stops with "cannot squash without a
    // previous commit", mid-rebase. Demote it here rather than let that happen.
    var first_kept = true;

    for (steps) |step| {
        var action = step.action;
        if (action != .drop) {
            if (first_kept and (action == .squash or action == .fixup)) action = .pick;
            first_kept = false;
        }

        // The full sha: a short one can name two commits, and git stops on it.
        var buf: [41]u8 = undefined;
        try out.appendSlice(gpa, action.verb());
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, oidHex(step.id, &buf));
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, step.summary);
        try out.append(gpa, '\n');
    }

    // An empty list is how you tell git to call the whole thing off, and `noop`
    // is how you say "no commits, but do finish".
    if (out.items.len == 0) try out.appendSlice(gpa, "noop\n");

    return out.toOwnedSlice(gpa);
}

// === Snapshots ===

/// How far the checked-out branch is from the branch it tracks.
///
/// All zero when there is no upstream, which is also what "nothing worth
/// saying" looks like — a branch nobody has pushed yet is not an error.
pub const Tracking = struct {
    ahead: usize = 0,
    behind: usize = 0,
    /// "origin/main", for the tooltip. Null when there is no upstream.
    upstream: ?[]const u8 = null,
};

/// One reflog entry: what git wrote about the move, and where HEAD was before.
pub const Move = struct {
    message: []const u8,
    old: Oid,
};

/// Refs, commits and the counts the sidebar shows. Rebuilt when HEAD moves or
/// after Zit itself writes.
pub const History = struct {
    arena: std.heap.ArenaAllocator,
    refs: []Ref = &.{},
    commits: []Commit = &.{},
    stashes: []Stash = &.{},
    remotes: []Remote = &.{},
    worktrees: []Worktree = &.{},
    /// What git is in the middle of, if anything.
    state: State = .none,
    /// Short name of the checked-out branch. Null on an unborn branch (a fresh
    /// `git init`) or a detached HEAD, which `detached` tells apart.
    head: ?[]const u8 = null,
    /// What Pull and Push would actually do.
    tracking: Tracking = .{},
    detached: bool = false,
    head_oid: ?Oid = null,
    /// The newest entry of HEAD's reflog — the last thing that moved it, and
    /// what Undo takes back. Null on a repository with no reflog yet.
    last_move: ?Move = null,

    pub fn deinit(self: *History) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Index of a commit by id, for jumping from a ref to its row.
    pub fn indexOf(self: History, id: Oid) ?usize {
        for (self.commits, 0..) |cm, i| {
            if (oidEql(cm.id, id)) return i;
        }
        return null;
    }

    pub fn refCount(self: History, kind: Ref.Kind) usize {
        var n: usize = 0;
        for (self.refs) |r| {
            if (r.kind == kind) n += 1;
        }
        return n;
    }
};

/// What is uncommitted. Cheap enough to re-read on a timer, which is how Zit
/// notices a file you changed in your editor.
pub const Work = struct {
    arena: std.heap.ArenaAllocator,
    staged: []Change = &.{},
    unstaged: []Change = &.{},

    pub fn deinit(self: *Work) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// === Repository ===

pub const Repo = struct {
    ptr: *c.git_repository,

    /// Opens the repository containing `path`, searching upward like `git`
    /// itself does, so pointing Zit at a subdirectory works.
    ///
    /// Takes a plain slice and NUL-terminates it here: libgit2 needs a C
    /// string, and that is this layer's problem, not every caller's.
    pub fn open(path: []const u8) Error!Repo {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.Git;

        var out: ?*c.git_repository = null;
        // Not `check`: "there is no repository here" is a normal answer, and
        // the caller says so in the UI. Only real failures are worth a log.
        const rc = c.git_repository_open_ext(&out, path_z.ptr, 0, null);
        if (rc == c.GIT_ENOTFOUND) return error.Git;
        try check(rc);
        return .{ .ptr = out.? };
    }

    pub fn deinit(self: *Repo) void {
        c.git_repository_free(self.ptr);
        self.* = undefined;
    }

    /// Working directory, with its trailing slash. Null for a bare repo.
    pub fn workdir(self: Repo) ?[]const u8 {
        const p = c.git_repository_workdir(self.ptr) orelse return null;
        return std.mem.span(p);
    }

    pub fn headDetached(self: Repo) bool {
        return c.git_repository_head_detached(self.ptr) == 1;
    }

    /// The commit HEAD resolves to, or null on an unborn branch.
    pub fn headOid(self: Repo) ?Oid {
        var oid: Oid = undefined;
        if (c.git_reference_name_to_id(&oid, self.ptr, "HEAD") < 0) return null;
        return oid;
    }

    /// Short name of the checked-out branch, copied into `arena`. Null on an
    /// unborn branch or a detached HEAD.
    pub fn headBranch(self: Repo, arena: std.mem.Allocator) Error!?[]const u8 {
        var ref: ?*c.git_reference = null;
        // Not errors, just states a repository is legitimately in.
        if (c.git_repository_head(&ref, self.ptr) < 0) return null;
        defer c.git_reference_free(ref);

        if (c.git_reference_is_branch(ref) != 1) return null;

        // Copied whole: a fixed buffer made a long branch name read as no
        // branch at all, which the UI takes for an unborn one.
        return arena.dupe(u8, std.mem.span(c.git_reference_shorthand(ref))) catch error.Git;
    }

    /// Read refs, commits and the sidebar counts into a fresh snapshot: the
    /// graph walked from the refs `filter` keeps only, every ref still listed.
    pub fn readHistoryFiltered(self: Repo, gpa: std.mem.Allocator, filter: RefFilter) Error!History {
        var out: History = .{ .arena = .init(gpa) };
        errdefer out.arena.deinit();
        const arena = out.arena.allocator();

        out.detached = self.headDetached();
        out.head_oid = self.headOid();

        if (try self.headBranch(arena)) |name| {
            out.head = name;
            out.tracking = self.readTracking(arena, name);
        }
        // What those were allowed to fail at — a branch with no upstream,
        // HEAD with no commit — must not be what `lastError` reports when a
        // read below fails, as running out of memory does without a word.
        git_error_clear();

        out.refs = try self.readRefs(arena);
        out.commits = try self.readCommits(gpa, arena, out.refs, filter);
        out.stashes = try self.readStashes(arena);
        out.remotes = try self.readRemotes(arena);
        out.worktrees = self.readWorktrees(arena);
        out.state = self.state();
        out.last_move = self.readLastMove(arena);

        return out;
    }

    pub fn readLastMove(self: Repo, arena: std.mem.Allocator) ?Move {
        var log: ?*c.git_reflog = null;
        if (c.git_reflog_read(&log, self.ptr, "HEAD") < 0) return null;
        defer c.git_reflog_free(log);

        if (c.git_reflog_entrycount(log) == 0) return null;
        const entry = c.git_reflog_entry_byindex(log, 0) orelse return null;
        const message = if (c.git_reflog_entry_message(entry)) |m| std.mem.span(m) else "";
        return .{
            .message = arena.dupe(u8, std.mem.trimEnd(u8, message, "\n")) catch return null,
            .old = c.git_reflog_entry_id_old(entry).*,
        };
    }

    /// Ahead/behind against the branch's upstream.
    ///
    /// Not routed through `check`: a branch with no upstream is the normal
    /// state of a branch nobody has pushed, and logging it as a libgit2 error
    /// would be noise on every refresh.
    fn readTracking(self: Repo, arena: std.mem.Allocator, branch: []const u8) Tracking {
        const name = arena.dupeZ(u8, branch) catch return .{};
        var local: ?*c.git_reference = null;
        if (c.git_branch_lookup(&local, self.ptr, name.ptr, c.GIT_BRANCH_LOCAL) != 0) return .{};
        defer c.git_reference_free(local);
        return self.trackingOf(arena, local);
    }

    /// How far local branch `local` is from its upstream; empty when it has none.
    fn trackingOf(self: Repo, arena: std.mem.Allocator, local: ?*c.git_reference) Tracking {
        var out: Tracking = .{};
        var upstream: ?*c.git_reference = null;
        if (c.git_branch_upstream(&upstream, local) != 0) return out;
        defer c.git_reference_free(upstream);

        const local_oid = c.git_reference_target(local) orelse return out;
        const upstream_oid = c.git_reference_target(upstream) orelse return out;

        var ahead: usize = 0;
        var behind: usize = 0;
        if (c.git_graph_ahead_behind(&ahead, &behind, self.ptr, local_oid, upstream_oid) != 0) return out;

        out.ahead = ahead;
        out.behind = behind;
        if (c.git_reference_shorthand(upstream)) |short| {
            out.upstream = arena.dupe(u8, std.mem.span(short)) catch null;
        }
        return out;
    }

    fn readRefs(self: Repo, arena: std.mem.Allocator) Error![]Ref {
        var refs: std.ArrayList(Ref) = .empty;

        var iter: ?*c.git_reference_iterator = null;
        try check(c.git_reference_iterator_new(&iter, self.ptr));
        defer c.git_reference_iterator_free(iter);

        while (true) {
            var ref: ?*c.git_reference = null;
            const rc = c.git_reference_next(&ref, iter);
            if (rc == c.GIT_ITEROVER) break;
            try check(rc);
            defer c.git_reference_free(ref);

            const kind: Ref.Kind = if (c.git_reference_is_branch(ref) == 1)
                .local
            else if (c.git_reference_is_remote(ref) == 1)
                .remote
            else if (c.git_reference_is_tag(ref) == 1)
                .tag
            else
                // refs/notes, refs/stash and anything else a tool left behind:
                // not something to show in a branch list.
                continue;

            const name = std.mem.span(c.git_reference_shorthand(ref));

            // "origin/HEAD" is a symbolic pointer at the remote's default
            // branch, not a branch of its own; every git GUI hides it. Only a
            // remote's: a local branch may well be called `feature/HEAD`.
            if (kind == .remote and std.mem.endsWith(u8, name, "/HEAD")) continue;

            // Peel rather than read the target directly: an annotated tag
            // points at a tag object, and the graph only knows about commits.
            var obj: ?*c.git_object = null;
            if (c.git_reference_peel(&obj, ref, c.GIT_OBJECT_COMMIT) < 0) continue;
            defer c.git_object_free(obj);

            refs.append(arena, .{
                .name = arena.dupe(u8, name) catch return error.Git,
                .kind = kind,
                .target = c.git_object_id(obj).*,
                .head = kind == .local and c.git_branch_is_head(ref) == 1,
                .tracking = if (kind == .local) self.trackingOf(arena, ref) else .{},
                .time = c.git_commit_time(@ptrCast(obj)),
            }) catch return error.Git;
        }
        // A branch with no upstream is the usual case, not a failure: what it
        // left in libgit2's last error is not what a read after this failed of.
        git_error_clear();

        const items = refs.toOwnedSlice(arena) catch return error.Git;
        std.mem.sort(Ref, items, {}, refLessThan);
        return items;
    }

    /// The commits, into `arena`. The list grows on `gpa` and is copied into
    /// the arena once, at its size, so outgrown buffers are not left there.
    /// Authors and addresses are stored once each, however many commits.
    fn readCommits(self: Repo, gpa: std.mem.Allocator, arena: std.mem.Allocator, refs: []const Ref, filter_in: RefFilter) Error![]Commit {
        var hidden_set: std.StringHashMapUnmanaged(void) = .empty;
        defer hidden_set.deinit(gpa);
        var filter = filter_in;
        if (filter.hidden_set == null and filter.hidden.len > 0) {
            for (filter.hidden) |name| hidden_set.put(gpa, name, {}) catch return error.Git;
            filter.hidden_set = &hidden_set;
        }
        var walk: ?*c.git_revwalk = null;
        try check(c.git_revwalk_new(&walk, self.ptr));
        defer c.git_revwalk_free(walk);

        // Topological first so parents never appear above their children, then
        // by time so independent branches interleave the way they happened.
        try check(c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL | c.GIT_SORT_TIME));

        // Every ref, not just HEAD: a branch that is not an ancestor of HEAD
        // still belongs on the graph, which is the whole point of drawing one.
        var pushed = false;
        for (refs) |r| {
            if (!filter.walks(r)) continue;
            if (c.git_revwalk_push(walk, &r.target) == 0) pushed = true;
        }
        // HEAD itself too, unless branches are picked to show alone: a
        // detached HEAD is on no ref, and the commits made there belong on
        // the graph.
        if (filter.only.len == 0) {
            if (self.headOid()) |head| {
                if (c.git_revwalk_push(walk, &head) == 0) pushed = true;
            }
        }
        // A filter that keeps nothing — its branch was deleted — keeps all.
        if (!pushed) {
            for (refs) |r| {
                if (c.git_revwalk_push(walk, &r.target) == 0) pushed = true;
            }
        }
        if (!pushed) return &.{};

        var commits: std.ArrayList(Commit) = .empty;
        defer commits.deinit(gpa);
        var names: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer names.deinit(gpa);
        const intern = struct {
            fn f(map: *std.StringHashMapUnmanaged([]const u8), g: std.mem.Allocator, a: std.mem.Allocator, text: []const u8) Error![]const u8 {
                if (map.get(text)) |known| return known;
                const owned = a.dupe(u8, text) catch return error.Git;
                map.put(g, owned, owned) catch {};
                return owned;
            }
        }.f;

        var oid: Oid = undefined;
        while (commits.items.len < MAX_COMMITS and c.git_revwalk_next(&oid, walk) == 0) {
            var commit: ?*c.git_commit = null;
            if (c.git_commit_lookup(&commit, self.ptr, &oid) < 0) continue;
            defer c.git_commit_free(commit);

            var entry: Commit = .{
                .id = oid,
                .summary = "",
                .author = "",
                .time = c.git_commit_time(commit),
            };

            if (c.git_commit_summary(commit)) |s| {
                entry.summary = arena.dupe(u8, std.mem.span(s)) catch return error.Git;
            }
            if (c.git_commit_body(commit)) |b| {
                const text = std.mem.trim(u8, std.mem.span(b), " \t\r\n");
                const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
                entry.body = arena.dupe(u8, std.mem.trimEnd(u8, first, " \t\r")) catch return error.Git;
            }
            if (c.git_commit_author(commit)) |sig| {
                if (sig.*.name) |n| entry.author = try intern(&names, gpa, arena, std.mem.span(n));
                if (sig.*.email) |e| entry.email = try intern(&names, gpa, arena, std.mem.span(e));
            }

            const n = c.git_commit_parentcount(commit);
            if (n > 0) {
                const parents = arena.alloc(Oid, n) catch return error.Git;
                var kept: usize = 0;
                for (0..n) |i| {
                    // Packed from the front: a parent that did not resolve
                    // must not leave a hole.
                    parents[kept] = (c.git_commit_parent_id(commit, @intCast(i)) orelse continue).*;
                    kept += 1;
                }
                entry.parents = parents[0..kept];
            }

            commits.append(gpa, entry) catch return error.Git;
        }

        return arena.dupe(Commit, commits.items) catch return error.Git;
    }

    /// Staged and unstaged changes, in a fresh snapshot.
    pub fn readWork(self: Repo, gpa: std.mem.Allocator) Error!Work {
        var out: Work = .{ .arena = .init(gpa) };
        errdefer out.arena.deinit();
        const arena = out.arena.allocator();

        var opts: c.git_status_options = undefined;
        try check(c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION));
        opts.show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
        opts.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED |
            // Without this an untracked directory shows as one entry; you want
            // the files, because that is what you stage.
            c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS |
            c.GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
            c.GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR |
            c.GIT_STATUS_OPT_SORT_CASE_INSENSITIVELY;

        var list: ?*c.git_status_list = null;
        try check(c.git_status_list_new(&list, self.ptr, &opts));
        defer c.git_status_list_free(list);

        var staged: std.ArrayList(Change) = .empty;
        var unstaged: std.ArrayList(Change) = .empty;

        const count = c.git_status_list_entrycount(list);
        for (0..count) |i| {
            const e = c.git_status_byindex(list, i) orelse continue;
            const bits = e.*.status;

            // A file can be in both lists at once — staged edit, then edited
            // again — and showing it twice is correct, not a duplicate.
            if (e.*.head_to_index) |delta| {
                if (stagedStatus(bits)) |status| {
                    staged.append(arena, .{
                        .path = try dupePath(arena, delta.*.new_file.path, delta.*.old_file.path),
                        .old_path = try dupePath(arena, delta.*.old_file.path, delta.*.new_file.path),
                        .status = status,
                    }) catch return error.Git;
                }
            }
            if (e.*.index_to_workdir) |delta| {
                if (unstagedStatus(bits)) |status| {
                    unstaged.append(arena, .{
                        .path = try dupePath(arena, delta.*.new_file.path, delta.*.old_file.path),
                        .old_path = try dupePath(arena, delta.*.old_file.path, delta.*.new_file.path),
                        .status = status,
                    }) catch return error.Git;
                }
            }
        }

        out.staged = staged.toOwnedSlice(arena) catch return error.Git;
        out.unstaged = unstaged.toOwnedSlice(arena) catch return error.Git;
        return out;
    }

    pub fn state(self: Repo) State {
        return switch (c.git_repository_state(self.ptr)) {
            c.GIT_REPOSITORY_STATE_NONE => .none,
            c.GIT_REPOSITORY_STATE_MERGE => .merge,
            c.GIT_REPOSITORY_STATE_REVERT, c.GIT_REPOSITORY_STATE_REVERT_SEQUENCE => .revert,
            c.GIT_REPOSITORY_STATE_CHERRYPICK, c.GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE => .cherrypick,
            c.GIT_REPOSITORY_STATE_BISECT => .bisect,
            c.GIT_REPOSITORY_STATE_REBASE,
            c.GIT_REPOSITORY_STATE_REBASE_INTERACTIVE,
            c.GIT_REPOSITORY_STATE_REBASE_MERGE,
            => .rebase,
            c.GIT_REPOSITORY_STATE_APPLY_MAILBOX,
            c.GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE,
            => .apply_mailbox,
            else => .other,
        };
    }

    fn readStashes(self: Repo, arena: std.mem.Allocator) Error![]Stash {
        var ctx: StashCtx = .{ .arena = arena, .list = .empty };
        _ = c.git_stash_foreach(self.ptr, collectStash, &ctx);
        if (ctx.failed) return error.Git;
        for (ctx.list.items) |*entry| {
            var commit: ?*c.git_commit = null;
            if (c.git_commit_lookup(&commit, self.ptr, &entry.id) < 0) continue;
            defer c.git_commit_free(commit);
            if (c.git_commit_parent_id(commit, 0)) |parent| entry.base = parent.*;
        }
        return ctx.list.toOwnedSlice(arena) catch return error.Git;
    }

    /// The diff for one side of the working tree, optionally narrowed to a
    /// single path.
    pub fn readWorkDiff(self: Repo, gpa: std.mem.Allocator, side: DiffSide, path: ?[]const u8) Error!Diff {
        return self.readWorkDiffFrom(gpa, side, path, path);
    }

    /// As `readWorkDiff`, for a file the status saw renamed from `old_path`:
    /// both names go into the pathspec, so the diff can pair them up again.
    pub fn readWorkDiffFrom(self: Repo, gpa: std.mem.Allocator, side: DiffSide, path: ?[]const u8, old_path: ?[]const u8) Error!Diff {
        var out: Diff = .{ .arena = .init(gpa) };
        errdefer out.arena.deinit();
        const arena = out.arena.allocator();

        var opts: c.git_diff_options = undefined;
        try check(c.git_diff_options_init(&opts, c.GIT_DIFF_OPTIONS_VERSION));
        // Untracked files are changes too; without this the diff for a new file
        // is empty and the panel looks broken.
        opts.flags = c.GIT_DIFF_INCLUDE_UNTRACKED | c.GIT_DIFF_SHOW_UNTRACKED_CONTENT |
            c.GIT_DIFF_RECURSE_UNTRACKED_DIRS |
            // The path is a file's name, not a glob: `pages/[id].tsx` must
            // not bring `pages/i.tsx` along.
            c.GIT_DIFF_DISABLE_PATHSPEC_MATCH;
        applyDiffOptions(&opts);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var old_buf: [std.fs.max_path_bytes]u8 = undefined;
        var path_ptrs: [2][*c]const u8 = undefined;
        if (path) |p| {
            const z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{p}, 0) catch return error.Git;
            path_ptrs[0] = z.ptr;
            opts.pathspec.strings = @ptrCast(&path_ptrs);
            opts.pathspec.count = 1;
            if (old_path) |o| if (!std.mem.eql(u8, o, p)) {
                const oz = std.fmt.bufPrintSentinel(&old_buf, "{s}", .{o}, 0) catch return error.Git;
                path_ptrs[1] = oz.ptr;
                opts.pathspec.count = 2;
            };
        }

        var diff: ?*c.git_diff = null;
        switch (side) {
            .unstaged => try check(c.git_diff_index_to_workdir(&diff, self.ptr, null, &opts)),
            .staged => {
                // No HEAD yet: everything in the index is new, and diffing
                // against an empty tree is what says so.
                const tree: ?*c.git_tree = self.headTree();
                defer if (tree) |t| c.git_tree_free(t);
                try check(c.git_diff_tree_to_index(&diff, self.ptr, tree, null, &opts));
            },
        }
        defer c.git_diff_free(diff);
        // A rename as one file, the way the status already lists it. Untracked
        // counts on the working-tree side: a moved file is untracked there.
        var find: c.git_diff_find_options = undefined;
        try check(c.git_diff_find_options_init(&find, c.GIT_DIFF_FIND_OPTIONS_VERSION));
        find.flags = c.GIT_DIFF_FIND_RENAMES | c.GIT_DIFF_FIND_FOR_UNTRACKED;
        try check(c.git_diff_find_similar(diff, &find));

        out.files = try collectDiff(arena, diff.?);
        return out;
    }

    /// The diff a commit introduced, against its first parent — a root
    /// commit's against nothing. First parent only: a merge's full diff is a
    /// combined diff, which is a different thing to read and to render.
    pub fn readCommitDiff(self: Repo, gpa: std.mem.Allocator, id: Oid) Error!Diff {
        var commit: ?*c.git_commit = null;
        try check(c.git_commit_lookup(&commit, self.ptr, &id));
        defer c.git_commit_free(commit);
        const parent: ?Oid = if (c.git_commit_parentcount(commit) > 0) c.git_commit_parent_id(commit, 0).* else null;
        return self.readRangeDiff(gpa, parent, id);
    }

    /// What changed from commit `from` to commit `to`, whatever lies between;
    /// from nothing at all when `from` is null.
    pub fn readRangeDiff(self: Repo, gpa: std.mem.Allocator, from: ?Oid, to: Oid) Error!Diff {
        var out: Diff = .{ .arena = .init(gpa) };
        errdefer out.arena.deinit();
        const arena = out.arena.allocator();

        const old_tree: ?*c.git_tree = if (from) |f| self.commitTree(f) orelse return error.Git else null;
        defer if (old_tree) |t| c.git_tree_free(t);
        const new_tree = self.commitTree(to) orelse return error.Git;
        defer c.git_tree_free(new_tree);

        var opts: c.git_diff_options = undefined;
        try check(c.git_diff_options_init(&opts, c.GIT_DIFF_OPTIONS_VERSION));
        applyDiffOptions(&opts);

        var diff: ?*c.git_diff = null;
        try check(c.git_diff_tree_to_tree(&diff, self.ptr, old_tree, new_tree, &opts));
        defer c.git_diff_free(diff);
        // A rename as one file rather than a deletion and an addition.
        try check(c.git_diff_find_similar(diff, null));

        out.files = try collectDiff(arena, diff.?);
        return out;
    }

    /// Where two histories last met.
    pub fn mergeBase(self: Repo, a: Oid, b: Oid) ?Oid {
        var out: Oid = undefined;
        if (c.git_merge_base(&out, self.ptr, &a, &b) < 0) return null;
        return out;
    }

    fn headTree(self: Repo) ?*c.git_tree {
        return self.commitTree(self.headOid() orelse return null);
    }

    /// The tree of commit `id`, for the caller to free; null when either is
    /// not there.
    fn commitTree(self: Repo, id: Oid) ?*c.git_tree {
        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, self.ptr, &id) < 0) return null;
        defer c.git_commit_free(commit);
        var tree: ?*c.git_tree = null;
        if (c.git_commit_tree(&tree, commit) < 0) return null;
        return tree;
    }

    fn readRemotes(self: Repo, arena: std.mem.Allocator) Error![]Remote {
        var names: c.git_strarray = std.mem.zeroes(c.git_strarray);
        try check(c.git_remote_list(&names, self.ptr));
        defer c.git_strarray_dispose(&names);

        var out: std.ArrayList(Remote) = .empty;
        for (0..names.count) |i| {
            var remote: ?*c.git_remote = null;
            // A name in the list that will not look up is a broken config
            // entry; the other remotes are still worth showing.
            if (c.git_remote_lookup(&remote, self.ptr, names.strings[i]) < 0) continue;
            defer c.git_remote_free(remote);

            const url = if (c.git_remote_url(remote)) |u| std.mem.span(u) else "";
            out.append(arena, .{
                .name = arena.dupe(u8, std.mem.span(names.strings[i])) catch return error.Git,
                .url = arena.dupe(u8, url) catch return error.Git,
            }) catch return error.Git;
        }

        return out.toOwnedSlice(arena) catch return error.Git;
    }

    /// Best effort: a worktree whose folder has gone is still listed by git
    /// until pruned, and one that will not look up is simply left out.
    fn readWorktrees(self: Repo, arena: std.mem.Allocator) []Worktree {
        var names: c.git_strarray = std.mem.zeroes(c.git_strarray);
        if (c.git_worktree_list(&names, self.ptr) < 0) return &.{};
        defer c.git_strarray_dispose(&names);

        var out: std.ArrayList(Worktree) = .empty;
        for (0..names.count) |i| {
            var wt: ?*c.git_worktree = null;
            if (c.git_worktree_lookup(&wt, self.ptr, names.strings[i]) < 0) continue;
            defer c.git_worktree_free(wt);
            const path = c.git_worktree_path(wt) orelse continue;
            var head = std.mem.zeroes(Oid);
            var sub: ?*c.git_repository = null;
            if (c.git_repository_open_from_worktree(&sub, wt) == 0) {
                defer c.git_repository_free(sub);
                _ = c.git_reference_name_to_id(&head, sub, "HEAD");
            }
            out.append(arena, .{
                .name = arena.dupe(u8, std.mem.span(names.strings[i])) catch return &.{},
                .path = arena.dupe(u8, std.mem.span(path)) catch return &.{},
                .head = head,
            }) catch return &.{};
        }
        return out.toOwnedSlice(arena) catch &.{};
    }

    /// A commit's whole message, trimmed, copied into `arena`; empty when the
    /// commit cannot be read.
    pub fn commitMessage(self: Repo, arena: std.mem.Allocator, id: Oid) []const u8 {
        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, self.ptr, &id) < 0) return "";
        defer c.git_commit_free(commit);
        const message = c.git_commit_message(commit) orelse return "";
        return arena.dupe(u8, std.mem.trim(u8, std.mem.span(message), " \t\r\n")) catch "";
    }

    /// Who last touched each line of a tracked file. `text` is the file as the
    /// caller read it, so this layer stays out of the filesystem.
    ///
    /// ponytail: no `-C`/`-M` copy and rename detection. Those are what make
    /// blame slow, and the answer without them is the one you wanted anyway
    /// nine times in ten; add the flags behind a toggle if the tenth matters.
    pub fn readBlame(
        self: Repo,
        gpa: std.mem.Allocator,
        rel_path: []const u8,
        text: []const u8,
    ) Error!Blame {
        var out: Blame = .{ .arena = .init(gpa) };
        errdefer out.arena.deinit();
        const arena = out.arena.allocator();
        // No lines to name an author for — and libgit2 refuses an empty buffer.
        if (text.len == 0) return out;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{rel_path}, 0) catch return error.Git;

        var opts: c.git_blame_options = undefined;
        try check(c.git_blame_options_init(&opts, c.GIT_BLAME_OPTIONS_VERSION));

        var committed: ?*c.git_blame = null;
        try check(c.git_blame_file(&committed, self.ptr, path_z.ptr, &opts));
        defer c.git_blame_free(committed);

        // That is HEAD's blame; laid over the copy on disk it would credit an
        // edit nobody committed to whoever wrote the line before. Re-blamed
        // against the text itself, uncommitted lines come out unattributed.
        var blame: ?*c.git_blame = null;
        try check(c.git_blame_buffer(&blame, committed, text.ptr, text.len));
        defer c.git_blame_free(blame);

        // The trailing newline every text file ends with would otherwise split
        // into a last line that is not one.
        var body = text;
        if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];

        // At its size from the start: grown in the arena, each buffer it
        // outgrew would stay there beside it.
        var lines: std.ArrayList(BlameLine) = .empty;
        lines.ensureTotalCapacityPrecise(arena, std.mem.count(u8, body, "\n") + 1) catch return error.Git;
        var it = std.mem.splitScalar(u8, body, '\n');
        var n: usize = 0;
        while (it.next()) |line| {
            n += 1;

            var entry: BlameLine = .{
                .id = std.mem.zeroes(Oid),
                .author = "",
                .time = 0,
                .text = arena.dupe(u8, trimEol(line)) catch return error.Git,
            };

            // Null for a line git has no history for — one added since the last
            // commit. It still gets a row, just an unattributed one.
            if (c.git_blame_get_hunk_byline(blame, n)) |hunk| {
                entry.id = hunk.*.final_commit_id;
                if (hunk.*.final_signature) |sig| {
                    if (sig.*.name) |name| {
                        entry.author = arena.dupe(u8, std.mem.span(name)) catch return error.Git;
                    }
                    entry.time = sig.*.when.time;
                }
            }

            lines.append(arena, entry) catch return error.Git;
        }

        out.lines = lines.toOwnedSlice(arena) catch return error.Git;
        return out;
    }

    /// Which of `commits` changed `rel_path`, one flag per commit, same order.
    /// A commit counts when the path differs from every parent — what
    /// `git log --follow -- <path>` shows, so a merge that only carried a
    /// change in does not. A directory works too: its tree id changes with
    /// anything in it.
    ///
    /// Renames are followed: where a commit is the one that brought the path
    /// into being, and its diff says it came from another name, the older
    /// commits are read under that name instead.
    ///
    /// ponytail: one name at a time, switched in history order, so two branches
    /// carrying the file under different names at once can be misread; and a
    /// tree lookup per commit and parent. Fine at MAX_COMMITS.
    pub fn touching(self: Repo, gpa: std.mem.Allocator, commits: []const Commit, rel_path: []const u8) Error![]bool {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{rel_path}, 0) catch return error.Git;

        const out = gpa.alloc(bool, commits.len) catch return error.Git;
        for (commits, out) |cm, *flag| {
            const mine = self.entryAt(cm.id, path_z);
            flag.* = mine != null;
            var parent_lacks = cm.parents.len > 0;
            for (cm.parents) |p| {
                const theirs = self.entryAt(p, path_z);
                if (theirs != null) parent_lacks = false;
                const same = if (mine != null and theirs != null) oidEql(mine.?, theirs.?) else mine == null and theirs == null;
                if (same) {
                    flag.* = false;
                    break;
                }
                flag.* = true;
            }

            // Born here: under another name before, if git calls it a rename.
            if (mine != null and parent_lacks) {
                var old_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (self.renamedFrom(cm, path_z, &old_buf)) |old| {
                    path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{old}, 0) catch return error.Git;
                }
            }
        }
        return out;
    }

    /// The name `path` had in this commit's first parent, if the commit renamed
    /// it. Null where it was simply added.
    fn renamedFrom(self: Repo, cm: Commit, path: [*:0]const u8, buf: []u8) ?[]const u8 {
        if (cm.parents.len == 0) return null;
        const new_tree = self.commitTree(cm.id) orelse return null;
        defer c.git_tree_free(new_tree);
        const old_tree = self.commitTree(cm.parents[0]) orelse return null;
        defer c.git_tree_free(old_tree);

        var diff: ?*c.git_diff = null;
        if (c.git_diff_tree_to_tree(&diff, self.ptr, old_tree, new_tree, null) < 0) return null;
        defer c.git_diff_free(diff);
        if (c.git_diff_find_similar(diff, null) < 0) return null;

        const want = std.mem.span(path);
        for (0..c.git_diff_num_deltas(diff)) |i| {
            const d = c.git_diff_get_delta(diff, i) orelse continue;
            if (d.*.status != c.GIT_DELTA_RENAMED) continue;
            const new_path = std.mem.span(d.*.new_file.path orelse continue);
            if (!std.mem.eql(u8, new_path, want)) continue;
            const old_path = std.mem.span(d.*.old_file.path orelse continue);
            if (old_path.len > buf.len) return null;
            @memcpy(buf[0..old_path.len], old_path);
            return buf[0..old_path.len];
        }
        return null;
    }

    /// Every file in a commit's tree, folder by folder, as git orders them.
    pub fn treePaths(self: Repo, arena: std.mem.Allocator, id: Oid) []const []const u8 {
        const tree = self.commitTree(id) orelse return &.{};
        defer c.git_tree_free(tree);
        var ctx: TreeCtx = .{ .arena = arena };
        _ = c.git_tree_walk(tree, c.GIT_TREEWALK_PRE, collectTreePath, &ctx);
        return ctx.list.toOwnedSlice(arena) catch &.{};
    }

    /// A file as a commit has it, every line a context line: what the diff
    /// pane shows for a file the commit did not change.
    pub fn readFileAt(self: Repo, gpa: std.mem.Allocator, id: Oid, path: []const u8) Error!Diff {
        var out: Diff = .{ .arena = .init(gpa) };
        errdefer out.arena.deinit();
        const arena = out.arena.allocator();

        const path_z = arena.dupeZ(u8, path) catch return error.Git;
        const blob_id = self.entryAt(id, path_z) orelse return error.Git;
        var blob: ?*c.git_blob = null;
        try check(c.git_blob_lookup(&blob, self.ptr, &blob_id));
        defer c.git_blob_free(blob);

        const binary = c.git_blob_is_binary(blob) == 1;
        var lines: std.ArrayList(DiffLine) = .empty;
        if (!binary) {
            const size: usize = @intCast(c.git_blob_rawsize(blob));
            const raw: ?[*]const u8 = @ptrCast(c.git_blob_rawcontent(blob));
            const text = if (raw) |b| arena.dupe(u8, b[0..size]) catch return error.Git else "";
            const body = std.mem.trimEnd(u8, text, "\n");
            lines.ensureTotalCapacityPrecise(arena, std.mem.count(u8, body, "\n") + 1) catch return error.Git;
            var it = std.mem.splitScalar(u8, body, '\n');
            var n: u32 = 1;
            while (it.next()) |line| : (n += 1) {
                lines.append(arena, .{ .kind = .context, .text = std.mem.trimEnd(u8, line, "\r"), .old_no = n, .new_no = n, .hunk = 0 }) catch return error.Git;
            }
        }
        const files = arena.alloc(FileDiff, 1) catch return error.Git;
        const owned = arena.dupe(u8, path) catch return error.Git;
        files[0] = .{
            .path = owned,
            .old_path = owned,
            .status = .unchanged,
            .lines = lines.items,
            .hunk_count = 0,
            .binary = binary,
        };
        out.files = files;
        return out;
    }

    /// The blob or tree id at `path` in a commit, null where it does not exist.
    fn entryAt(self: Repo, id: Oid, path: [*:0]const u8) ?Oid {
        const tree = self.commitTree(id) orelse return null;
        defer c.git_tree_free(tree);

        var entry: ?*c.git_tree_entry = null;
        if (c.git_tree_entry_bypath(&entry, tree, path) < 0) return null;
        defer c.git_tree_entry_free(entry);

        return c.git_tree_entry_id(entry).*;
    }

    /// Whether git's ignore rules leave out `rel_path`, relative to the
    /// working tree — a directory with a trailing slash, for `build/`-style
    /// patterns. A tracked file under an ignored pattern still answers yes.
    pub fn isIgnored(self: Repo, rel_path: [*:0]const u8) bool {
        var ignored: c_int = 0;
        if (c.git_ignore_path_is_ignored(&ignored, self.ptr, rel_path) < 0) return false;
        return ignored == 1;
    }

    /// Where the refs live: the gitdir, or for a linked worktree the main
    /// repository's. With its trailing slash.
    pub fn commondir(self: Repo) []const u8 {
        const p = c.git_repository_commondir(self.ptr) orelse return self.gitdir();
        return std.mem.span(p);
    }

    /// The `.git` directory, with its trailing slash. Where Zit puts the files
    /// it has to hand to `git` itself, a rebase todo list being the only one.
    pub fn gitdir(self: Repo) []const u8 {
        const p = c.git_repository_path(self.ptr) orelse return "";
        return std.mem.span(p);
    }

    /// Every value of `key` in the repository's own config file — what
    /// `git config --local --get-all` answers — with no `git` to start.
    /// Copied into `arena`; empty when the key is not there.
    ///
    /// The file is opened afresh each time: the config libgit2 keeps for a
    /// repository would miss what `git config` wrote since.
    pub fn localConfigAll(self: Repo, arena: std.mem.Allocator, key: [:0]const u8) Error![]const []const u8 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}config", .{self.commondir()}, 0) catch return error.Git;
        var cfg: ?*c.git_config = null;
        try check(c.git_config_open_ondisk(&cfg, path.ptr));
        defer c.git_config_free(cfg);

        var iter: ?*c.git_config_iterator = null;
        const opened = c.git_config_multivar_iterator_new(&iter, cfg, key.ptr, null);
        if (opened == c.GIT_ENOTFOUND) return &.{};
        try check(opened);
        defer c.git_config_iterator_free(iter);

        var values: std.ArrayList([]const u8) = .empty;
        var entry: ?*c.git_config_entry = null;
        while (true) {
            const rc = c.git_config_next(&entry, iter);
            if (rc == c.GIT_ITEROVER) break;
            try check(rc);
            const value = arena.dupe(u8, std.mem.span(entry.?.value)) catch return error.Git;
            values.append(arena, value) catch return error.Git;
        }
        return values.toOwnedSlice(arena) catch return error.Git;
    }

    /// Where the stash whose commit is `id` is in the list now: the `n` of
    /// `stash@{n}`, the only name `pop` and `drop` take. Read afresh, as a
    /// stash pushed or dropped since — in a terminal, say — moves every
    /// index. Null when it is gone.
    pub fn stashIndex(self: Repo, id: Oid) ?usize {
        var find: StashFind = .{ .id = id };
        _ = c.git_stash_foreach(self.ptr, findStash, &find);
        return find.at;
    }
};

const StashFind = struct { id: Oid, at: ?usize = null };

fn findStash(index: usize, _: [*c]const u8, stash_id: [*c]const c.git_oid, payload: ?*anyopaque) callconv(.c) c_int {
    const find: *StashFind = @ptrCast(@alignCast(payload.?));
    if (!oidEql(stash_id.*, find.id)) return 0;
    find.at = index;
    // Non-zero stops the walk.
    return 1;
}

/// A deleted file has no `new_file.path`; fall back to the old one so the row
/// is not blank.
fn dupePath(arena: std.mem.Allocator, new_path: [*c]const u8, old_path: [*c]const u8) Error![]const u8 {
    const p = new_path orelse old_path orelse return "";
    return arena.dupe(u8, std.mem.span(p)) catch error.Git;
}

fn stagedStatus(bits: c_uint) ?Status {
    if (bits & c.GIT_STATUS_CONFLICTED != 0) return .conflicted;
    if (bits & c.GIT_STATUS_INDEX_NEW != 0) return .added;
    if (bits & c.GIT_STATUS_INDEX_DELETED != 0) return .deleted;
    if (bits & c.GIT_STATUS_INDEX_RENAMED != 0) return .renamed;
    // A typechange (file became a symlink) is a modification as far as the
    // changes list is concerned.
    if (bits & (c.GIT_STATUS_INDEX_MODIFIED | c.GIT_STATUS_INDEX_TYPECHANGE) != 0) return .modified;
    return null;
}

fn unstagedStatus(bits: c_uint) ?Status {
    if (bits & c.GIT_STATUS_CONFLICTED != 0) return .conflicted;
    if (bits & c.GIT_STATUS_WT_NEW != 0) return .added;
    if (bits & c.GIT_STATUS_WT_DELETED != 0) return .deleted;
    if (bits & c.GIT_STATUS_WT_RENAMED != 0) return .renamed;
    if (bits & (c.GIT_STATUS_WT_MODIFIED | c.GIT_STATUS_WT_TYPECHANGE) != 0) return .modified;
    return null;
}

const TreeCtx = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,
};

fn collectTreePath(root: [*c]const u8, entry: ?*const c.git_tree_entry, payload: ?*anyopaque) callconv(.c) c_int {
    const ctx: *TreeCtx = @ptrCast(@alignCast(payload.?));
    if (c.git_tree_entry_type(entry) != c.GIT_OBJECT_BLOB) return 0;
    const path = std.mem.concat(ctx.arena, u8, &.{ std.mem.span(root), std.mem.span(c.git_tree_entry_name(entry)) }) catch return -1;
    ctx.list.append(ctx.arena, path) catch return -1;
    return 0;
}

const StashCtx = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Stash),
    failed: bool = false,
};

fn collectStash(_: usize, message: [*c]const u8, stash_id: [*c]const c.git_oid, payload: ?*anyopaque) callconv(.c) c_int {
    const ctx: *StashCtx = @ptrCast(@alignCast(payload.?));

    const text = if (message) |m| std.mem.span(m) else "";
    const owned = ctx.arena.dupe(u8, text) catch {
        ctx.failed = true;
        return -1;
    };
    ctx.list.append(ctx.arena, .{ .message = owned, .id = stash_id.* }) catch {
        ctx.failed = true;
        return -1;
    };
    return 0;
}

/// Walk a libgit2 diff into the flat per-file line lists the view renders.
///
/// Every list at its size from the start — libgit2 knows each hunk's line
/// count — since one grown in the arena leaves each buffer it outgrew there.
fn collectDiff(arena: std.mem.Allocator, diff: *c.git_diff) Error![]FileDiff {
    var files: std.ArrayList(FileDiff) = .empty;

    const count = c.git_diff_num_deltas(diff);
    files.ensureTotalCapacityPrecise(arena, count) catch return error.Git;
    for (0..count) |i| {
        var patch: ?*c.git_patch = null;
        if (c.git_patch_from_diff(&patch, diff, i) < 0) continue;
        defer c.git_patch_free(patch);

        const delta = c.git_patch_get_delta(patch);
        const binary = delta.*.flags & c.GIT_DIFF_FLAG_BINARY != 0;

        var lines: std.ArrayList(DiffLine) = .empty;
        var hunk_count: u32 = 0;

        if (!binary) {
            const hunks = c.git_patch_num_hunks(patch);
            hunk_count = @intCast(hunks);
            var total: usize = hunks;
            for (0..hunks) |h| total += @intCast(@max(0, c.git_patch_num_lines_in_hunk(patch, h)));
            lines.ensureTotalCapacityPrecise(arena, total) catch return error.Git;

            for (0..hunks) |h| {
                var hunk: [*c]const c.git_diff_hunk = undefined;
                var line_count: usize = 0;
                if (c.git_patch_get_hunk(&hunk, &line_count, patch, h) < 0) continue;

                lines.append(arena, .{
                    .kind = .hunk_header,
                    .text = arena.dupe(u8, trimEol(hunk.*.header[0..hunk.*.header_len])) catch return error.Git,
                    .old_no = 0,
                    .new_no = 0,
                    .hunk = @intCast(h),
                }) catch return error.Git;

                for (0..line_count) |l| {
                    var line: [*c]const c.git_diff_line = undefined;
                    if (c.git_patch_get_line_in_hunk(&line, patch, h, l) < 0) continue;

                    const kind: DiffLine.Kind = switch (line.*.origin) {
                        '+' => .addition,
                        '-' => .deletion,
                        // libgit2 marks a missing trailing newline with its own
                        // origins. They are part of the patch, so they have to
                        // survive into a reconstructed one.
                        '=', '>', '<' => .no_newline,
                        else => .context,
                    };

                    lines.append(arena, .{
                        .kind = kind,
                        // libgit2 hands the marker over wrapped in newlines of
                        // its own, which would put a bare `\` line in a patch.
                        .text = if (kind == .no_newline) NO_NEWLINE else arena.dupe(u8, trimEol(line.*.content[0..line.*.content_len])) catch return error.Git,
                        .old_no = if (line.*.old_lineno < 0) 0 else @intCast(line.*.old_lineno),
                        .new_no = if (line.*.new_lineno < 0) 0 else @intCast(line.*.new_lineno),
                        .hunk = @intCast(h),
                    }) catch return error.Git;
                }
            }
        }

        files.append(arena, .{
            .path = try dupePath(arena, delta.*.new_file.path, delta.*.old_file.path),
            .old_path = try dupePath(arena, delta.*.old_file.path, delta.*.new_file.path),
            .status = deltaStatus(delta.*.status),
            .mode = if (delta.*.new_file.mode != 0) delta.*.new_file.mode else delta.*.old_file.mode,
            .lines = lines.toOwnedSlice(arena) catch return error.Git,
            .hunk_count = hunk_count,
            .binary = binary,
        }) catch return error.Git;
    }

    return files.toOwnedSlice(arena) catch return error.Git;
}

/// libgit2 hands back diff lines with their newline attached; the view adds its
/// own line breaks. A `\r` stays: it is part of a CRLF file's lines, and a
/// patch rebuilt without it does not apply. The view drops it when drawing.
fn trimEol(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\n");
}

/// The whole marker line, as git writes it under a line that has no newline.
pub const NO_NEWLINE = "\\ No newline at end of file";

fn deltaStatus(delta: c.git_delta_t) Status {
    return switch (delta) {
        c.GIT_DELTA_ADDED, c.GIT_DELTA_UNTRACKED, c.GIT_DELTA_COPIED => .added,
        c.GIT_DELTA_DELETED => .deleted,
        c.GIT_DELTA_RENAMED => .renamed,
        c.GIT_DELTA_CONFLICTED => .conflicted,
        else => .modified,
    };
}

/// Local branches first, then remotes, then tags — the order the sidebar shows
/// them in — and alphabetical within each, except that the checked-out branch
/// sorts to the top of the locals.
fn refLessThan(_: void, a: Ref, b: Ref) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.head != b.head) return a.head;
    return naturalLess(a.name, b.name);
}

/// Names compared the way people number them: runs of digits by value, so
/// PROJ-25 comes before PROJ-100 and v1.9 before v1.10. Case-insensitive
/// otherwise, with the exact bytes breaking ties.
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const si = i;
            const sj = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
            // Leading zeros carry no value; longer means bigger after them.
            const na = std.mem.trimStart(u8, a[si..i], "0");
            const nb = std.mem.trimStart(u8, b[sj..j], "0");
            if (na.len != nb.len) return na.len < nb.len;
            switch (std.mem.order(u8, na, nb)) {
                .lt => return true,
                .gt => return false,
                .eq => continue,
            }
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    if (a.len - i != b.len - j) return a.len - i < b.len - j;
    return std.mem.lessThan(u8, a, b);
}

test "branch names sort by their numbers, not their digits" {
    try std.testing.expect(naturalLess("PROJ-25-x", "PROJ-100-y"));
    try std.testing.expect(!naturalLess("PROJ-100-y", "PROJ-25-x"));
    try std.testing.expect(naturalLess("v1.9", "v1.10"));
    try std.testing.expect(naturalLess("feature/a", "Feature/b"));
    try std.testing.expect(naturalLess("main", "main2"));
    try std.testing.expect(!naturalLess("same", "same"));
}

/// Last path component, for the tab label: "/home/me/dev/zync/" -> "zync".
pub fn repoName(workdir_path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, workdir_path, "/");
    return std.fs.path.basename(trimmed);
}

test "repoName ignores the trailing slash libgit2 hands back" {
    try std.testing.expectEqualStrings("zync", repoName("/home/me/dev/zync/"));
    try std.testing.expectEqualStrings("zync", repoName("/home/me/dev/zync"));
    try std.testing.expectEqualStrings("", repoName("/"));
}

test "status bits map to one status each, conflicts winning" {
    // A staged rename that was then edited in the working tree: two rows, two
    // different statuses, from one set of bits.
    const bits: c_uint = c.GIT_STATUS_INDEX_RENAMED | c.GIT_STATUS_WT_MODIFIED;
    try std.testing.expectEqual(Status.renamed, stagedStatus(bits).?);
    try std.testing.expectEqual(Status.modified, unstagedStatus(bits).?);

    // Conflict beats everything else set alongside it.
    const conflicted: c_uint = c.GIT_STATUS_CONFLICTED | c.GIT_STATUS_WT_MODIFIED;
    try std.testing.expectEqual(Status.conflicted, unstagedStatus(conflicted).?);

    // A clean file produces no row at all.
    try std.testing.expectEqual(@as(?Status, null), stagedStatus(0));
    try std.testing.expectEqual(@as(?Status, null), unstagedStatus(0));
}

test "refs sort by kind, with the checked-out branch first" {
    var refs = [_]Ref{
        .{ .name = "v1.0", .kind = .tag, .target = undefined, .head = false },
        .{ .name = "origin/main", .kind = .remote, .target = undefined, .head = false },
        .{ .name = "zzz", .kind = .local, .target = undefined, .head = false },
        .{ .name = "main", .kind = .local, .target = undefined, .head = true },
        .{ .name = "aaa", .kind = .local, .target = undefined, .head = false },
    };
    std.mem.sort(Ref, &refs, {}, refLessThan);

    try std.testing.expectEqualStrings("main", refs[0].name);
    try std.testing.expectEqualStrings("aaa", refs[1].name);
    try std.testing.expectEqualStrings("zzz", refs[2].name);
    try std.testing.expectEqualStrings("origin/main", refs[3].name);
    try std.testing.expectEqualStrings("v1.0", refs[4].name);
}

/// The unified-diff prefix for a line, which is also exactly what a
/// reconstructed patch needs in front of it.
pub fn linePrefix(kind: DiffLine.Kind) []const u8 {
    return switch (kind) {
        .hunk_header => "",
        .context => " ",
        .addition => "+",
        .deletion => "-",
        // The marker's `\` is already the first character of its text.
        .no_newline => "",
    };
}

test "a hunk round-trips into a patch git would accept" {
    const lines = [_]DiffLine{
        .{ .kind = .hunk_header, .text = "@@ -1,2 +1,3 @@", .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .context, .text = "keep", .old_no = 1, .new_no = 1, .hunk = 0 },
        .{ .kind = .deletion, .text = "old", .old_no = 2, .new_no = 0, .hunk = 0 },
        .{ .kind = .addition, .text = "new", .old_no = 0, .new_no = 2, .hunk = 0 },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (lines) |l| {
        try buf.appendSlice(std.testing.allocator, linePrefix(l.kind));
        try buf.appendSlice(std.testing.allocator, l.text);
        try buf.append(std.testing.allocator, '\n');
    }

    try std.testing.expectEqualStrings(
        \\@@ -1,2 +1,3 @@
        \\ keep
        \\-old
        \\+new
        \\
    , buf.items);
}

/// Rebuild one hunk as a unified patch `git apply` will accept.
///
/// The header libgit2 produced is reused verbatim rather than recomputed: it
/// already describes the same "old" side that `git apply --cached` applies
/// against, in both directions — forward to stage an unstaged hunk, reversed to
/// take a staged one back out — so there are no line numbers to redo.
///
/// ponytail: text hunks only. A mode change, a rename or a binary file needs
/// header lines this does not write; the caller stages those whole-file, which
/// is what the row buttons already do.
pub fn patchForHunk(gpa: std.mem.Allocator, file: FileDiff, hunk: u32) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try patchHeader(gpa, &out, file);
    for (file.lines) |l| {
        if (l.hunk != hunk) continue;
        try out.appendSlice(gpa, linePrefix(l.kind));
        try out.appendSlice(gpa, l.text);
        try out.append(gpa, '\n');
    }

    return out.toOwnedSlice(gpa);
}

/// A patch of only the `picked` lines of one hunk — `picked[i]` for
/// `file.lines[i]` — the way `git add -p` edits a hunk by hand.
///
/// `reverse` is for a patch git will apply backwards (unstaging, discarding):
/// the lines left out must then read as they are on the side being kept. So a
/// change not picked becomes context where it exists on the target side, and
/// vanishes where it does not; which side that is flips with the direction.
///
/// A new file staged forward is the one creation that works line by line:
/// the unpicked additions simply are not in it, and the file goes into the
/// index holding the picked ones — after which it is a file like any other.
/// Null for the rest of creation and deletion: there is no context to keep
/// the unpicked lines in.
pub fn patchForLines(gpa: std.mem.Allocator, file: FileDiff, hunk: u32, picked: []const bool, reverse: bool) error{OutOfMemory}!?[]u8 {
    if (file.status == .deleted or (file.status == .added and reverse)) return null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    var old_start: u32 = 0;
    var new_start: u32 = 0;
    var old_len: u32 = 0;
    var new_len: u32 = 0;
    var any = false;
    // Whether the line before was written, which is what a "\ No newline"
    // marker belongs to.
    var last_kept = false;
    // Where in `body` the last line written starts, and what it was.
    var last_at: usize = 0;
    var last_kind: DiffLine.Kind = .hunk_header;
    // A last line with no newline, kept as context, whose marker is held
    // back: context claims both sides end there, which stops being true the
    // moment a picked line follows it.
    var held: ?usize = null;

    for (file.lines, 0..) |l, i| {
        if (l.hunk != hunk) continue;
        const pick = i < picked.len and picked[i];
        const kind: ?DiffLine.Kind = switch (l.kind) {
            .hunk_header => {
                const starts = parseHunkStarts(l.text) orelse return null;
                old_start = starts[0];
                new_start = starts[1];
                continue;
            },
            .context => .context,
            .no_newline => if (last_kept) .no_newline else null,
            // Forward, the old side is what is kept: an unpicked deletion stays
            // as context, an unpicked addition is not there. Backwards, the
            // new side is, and it is the other way round.
            .addition => if (pick) .addition else if (reverse) .context else null,
            .deletion => if (pick) .deletion else if (reverse) null else .context,
        };
        last_kept = kind != null;
        const k = kind orelse continue;
        if (pick) any = true;

        if (k == .no_newline and last_kind == .context) {
            held = last_at;
            continue;
        }
        if (held) |at| {
            // Something follows the unterminated line, so the side being
            // written gives it a newline: `-line`, the marker, `+line`. The
            // counts are what context had already added.
            const text = try gpa.dupe(u8, body.items[at + 1 .. body.items.len - 1]);
            defer gpa.free(text);
            body.shrinkRetainingCapacity(at);
            try body.print(gpa, "-{s}\n{s}\n+{s}\n", .{ text, NO_NEWLINE, text });
            held = null;
        }
        // The mirror case: a marker already written, and then a line both
        // sides share. Its line is no longer last, so it keeps a newline.
        if (k == .context and last_kind == .no_newline) body.shrinkRetainingCapacity(last_at);
        last_at = body.items.len;
        last_kind = k;

        switch (k) {
            .context => {
                old_len += 1;
                new_len += 1;
            },
            .addition => new_len += 1,
            .deletion => old_len += 1,
            else => {},
        }
        try body.appendSlice(gpa, linePrefix(k));
        try body.appendSlice(gpa, l.text);
        try body.append(gpa, '\n');
    }
    if (held != null) {
        try body.appendSlice(gpa, NO_NEWLINE);
        try body.append(gpa, '\n');
    }
    if (!any) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try patchHeader(gpa, &out, file);
    try out.print(gpa, "@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_len, new_start, new_len });
    try out.appendSlice(gpa, body.items);
    return try out.toOwnedSlice(gpa);
}

/// "@@ -12,7 +12,8 @@ fn x" -> 12, 12. A missing count is git's way of saying 1.
fn parseHunkStarts(header: []const u8) ?[2]u32 {
    var it = std.mem.tokenizeScalar(u8, header, ' ');
    if (!std.mem.eql(u8, it.next() orelse return null, "@@")) return null;
    const old = it.next() orelse return null;
    const new = it.next() orelse return null;
    if (old.len < 2 or old[0] != '-' or new.len < 2 or new[0] != '+') return null;
    const o = std.mem.indexOfScalar(u8, old, ',') orelse old.len;
    const n = std.mem.indexOfScalar(u8, new, ',') orelse new.len;
    return .{
        std.fmt.parseInt(u32, old[1..o], 10) catch return null,
        std.fmt.parseInt(u32, new[1..n], 10) catch return null,
    };
}

test "a patch of picked lines keeps the rest as the side it applies to" {
    var lines = [_]DiffLine{
        .{ .kind = .hunk_header, .text = "@@ -1,3 +1,3 @@", .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .context, .text = "a", .old_no = 1, .new_no = 1, .hunk = 0 },
        .{ .kind = .deletion, .text = "b", .old_no = 2, .new_no = 0, .hunk = 0 },
        .{ .kind = .deletion, .text = "c", .old_no = 3, .new_no = 0, .hunk = 0 },
        .{ .kind = .addition, .text = "B", .old_no = 0, .new_no = 2, .hunk = 0 },
        .{ .kind = .addition, .text = "C", .old_no = 0, .new_no = 3, .hunk = 0 },
    };
    const file: FileDiff = .{ .path = "f", .old_path = "f", .status = .modified, .lines = &lines, .hunk_count = 1, .binary = false };
    const picked = [_]bool{ false, false, true, false, true, false };

    const fwd = (try patchForLines(std.testing.allocator, file, 0, &picked, false)).?;
    defer std.testing.allocator.free(fwd);
    try std.testing.expect(std.mem.endsWith(u8, fwd, "@@ -1,3 +1,3 @@\n a\n-b\n c\n+B\n"));

    const back = (try patchForLines(std.testing.allocator, file, 0, &picked, true)).?;
    defer std.testing.allocator.free(back);
    try std.testing.expect(std.mem.endsWith(u8, back, "@@ -1,3 +1,3 @@\n a\n-b\n+B\n C\n"));

    const none = [_]bool{false} ** 6;
    try std.testing.expectEqual(@as(?[]u8, null), try patchForLines(std.testing.allocator, file, 0, &none, false));

    // "3" lost its newline's absence and gained a "4". Unstaging only the
    // deletion keeps the additions as context, so the marker cannot stay
    // where it was, in the middle of the hunk.
    var eof = [_]DiffLine{
        .{ .kind = .hunk_header, .text = "@@ -3 +3,2 @@", .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .deletion, .text = "3", .old_no = 3, .new_no = 0, .hunk = 0 },
        .{ .kind = .no_newline, .text = NO_NEWLINE, .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .addition, .text = "3", .old_no = 0, .new_no = 3, .hunk = 0 },
        .{ .kind = .addition, .text = "4", .old_no = 0, .new_no = 4, .hunk = 0 },
    };
    const eof_file: FileDiff = .{ .path = "f", .old_path = "f", .status = .modified, .lines = &eof, .hunk_count = 1, .binary = false };
    const del_only = [_]bool{ false, true, false, false, false };
    const mirror = (try patchForLines(std.testing.allocator, eof_file, 0, &del_only, true)).?;
    defer std.testing.allocator.free(mirror);
    try std.testing.expect(std.mem.endsWith(u8, mirror, "@@ -3,3 +3,2 @@\n-3\n 3\n 4\n"));
}

/// The `diff --git`, mode and `---`/`+++` lines every patch here opens with.
fn patchHeader(gpa: std.mem.Allocator, out: *std.ArrayList(u8), file: FileDiff) error{OutOfMemory}!void {
    // The `diff --git` line always names both real paths; it is the `---`/`+++`
    // pair below that says /dev/null for a side the file did not exist on.
    try out.appendSlice(gpa, "diff --git ");
    try patchPath(gpa, out, "a/", file.old_path);
    try out.append(gpa, ' ');
    try patchPath(gpa, out, "b/", file.path);
    try out.append(gpa, '\n');

    switch (file.status) {
        .added => try out.print(gpa, "new file mode {o}\n", .{file.mode}),
        .deleted => try out.print(gpa, "deleted file mode {o}\n", .{file.mode}),
        else => {},
    }

    try out.appendSlice(gpa, "--- ");
    if (file.status == .added) try out.appendSlice(gpa, "/dev/null") else try patchPath(gpa, out, "a/", file.old_path);
    try out.append(gpa, '\n');

    try out.appendSlice(gpa, "+++ ");
    if (file.status == .deleted) try out.appendSlice(gpa, "/dev/null") else try patchPath(gpa, out, "b/", file.path);
    try out.append(gpa, '\n');
}

/// `prefix` and `path` as git writes them in a patch: bare, or — for a name
/// with a quote, a backslash or a control character in it, which would end
/// the line or the name early — in double quotes with C escapes, as `git apply`
/// reads them back.
fn patchPath(gpa: std.mem.Allocator, out: *std.ArrayList(u8), prefix: []const u8, path: []const u8) error{OutOfMemory}!void {
    const quote = for (path) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20 or ch == 0x7f) break true;
    } else false;
    if (!quote) {
        try out.appendSlice(gpa, prefix);
        return out.appendSlice(gpa, path);
    }
    try out.append(gpa, '"');
    try out.appendSlice(gpa, prefix);
    for (path) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        0...8, 11...0x1f, 0x7f => try out.print(gpa, "\\{o:0>3}", .{ch}),
        else => try out.append(gpa, ch),
    };
    try out.append(gpa, '"');
}

test "a path with a tab in it is quoted in a patch, as git writes it" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try patchPath(std.testing.allocator, &out, "b/", "odd\tname \"q\".txt");
    try std.testing.expectEqualStrings("\"b/odd\\tname \\\"q\\\".txt\"", out.items);
    out.clearRetainingCapacity();
    try patchPath(std.testing.allocator, &out, "a/", "plain name.txt");
    try std.testing.expectEqualStrings("a/plain name.txt", out.items);
}

test "a hunk patch carries the file headers, and only its own hunk" {
    var lines = [_]DiffLine{
        .{ .kind = .hunk_header, .text = "@@ -1,1 +1,2 @@", .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .context, .text = "keep", .old_no = 1, .new_no = 1, .hunk = 0 },
        .{ .kind = .addition, .text = "first", .old_no = 0, .new_no = 2, .hunk = 0 },
        .{ .kind = .hunk_header, .text = "@@ -9,1 +10,2 @@", .old_no = 0, .new_no = 0, .hunk = 1 },
        .{ .kind = .addition, .text = "second", .old_no = 0, .new_no = 11, .hunk = 1 },
    };
    const file: FileDiff = .{
        .path = "src/main.zig",
        .old_path = "src/main.zig",
        .status = .modified,
        .lines = &lines,
        .hunk_count = 2,
        .binary = false,
    };

    const patch = try patchForHunk(std.testing.allocator, file, 1);
    defer std.testing.allocator.free(patch);

    // Hunk 0's lines must not leak into hunk 1's patch: staging one hunk that
    // quietly carries another is the failure this whole path exists to avoid.
    try std.testing.expectEqualStrings(
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -9,1 +10,2 @@
        \\+second
        \\
    , patch);
}

test "a file that is new on one side says /dev/null on the other" {
    var lines = [_]DiffLine{
        .{ .kind = .hunk_header, .text = "@@ -0,0 +1 @@", .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .addition, .text = "hello", .old_no = 0, .new_no = 1, .hunk = 0 },
    };
    const added: FileDiff = .{
        .path = "new.txt",
        .old_path = "new.txt",
        .status = .added,
        .mode = 0o100755,
        .lines = &lines,
        .hunk_count = 1,
        .binary = false,
    };

    const patch = try patchForHunk(std.testing.allocator, added, 0);
    defer std.testing.allocator.free(patch);
    try std.testing.expectEqualStrings(
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100755
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1 @@
        \\+hello
        \\
    , patch);
}

test "a conflict region is found by its markers, and resolves to either side" {
    const text =
        "before\n" ++
        "<<<<<<< HEAD\n" ++
        "mine\n" ++
        "=======\n" ++
        "yours\n" ++
        ">>>>>>> other\n" ++
        "after\n";

    const found = try parseConflicts(std.testing.allocator, text);
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("mine\n", found[0].ours);
    try std.testing.expectEqualStrings("yours\n", found[0].theirs);
    try std.testing.expectEqualStrings("", found[0].base);

    const ours = try resolveConflict(std.testing.allocator, text, found[0], .ours);
    defer std.testing.allocator.free(ours);
    try std.testing.expectEqualStrings("before\nmine\nafter\n", ours);

    const theirs = try resolveConflict(std.testing.allocator, text, found[0], .theirs);
    defer std.testing.allocator.free(theirs);
    try std.testing.expectEqualStrings("before\nyours\nafter\n", theirs);

    const both = try resolveConflict(std.testing.allocator, text, found[0], .both);
    defer std.testing.allocator.free(both);
    try std.testing.expectEqualStrings("before\nmine\nyours\nafter\n", both);
}

test "diff3 style keeps the base out of both sides" {
    const text =
        "<<<<<<< HEAD\n" ++
        "mine\n" ++
        "||||||| base\n" ++
        "original\n" ++
        "=======\n" ++
        "yours\n" ++
        ">>>>>>> other\n";

    const found = try parseConflicts(std.testing.allocator, text);
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("mine\n", found[0].ours);
    try std.testing.expectEqualStrings("original\n", found[0].base);
    try std.testing.expectEqualStrings("yours\n", found[0].theirs);
}

test "a marker in the middle of a line is not a conflict" {
    // The case that would quietly eat half a file on resolve.
    const text =
        \\const rule = "=======";
        \\print("<<<<<<< not a marker");
        \\
    ;
    const found = try parseConflicts(std.testing.allocator, text);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "resolving one region leaves the others where they were" {
    const text =
        "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n" ++
        "middle\n" ++
        "<<<<<<< HEAD\nc\n=======\nd\n>>>>>>> x\n";

    const found = try parseConflicts(std.testing.allocator, text);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 2), found.len);

    const once = try resolveConflict(std.testing.allocator, text, found[0], .ours);
    defer std.testing.allocator.free(once);
    try std.testing.expectEqualStrings(
        "a\nmiddle\n<<<<<<< HEAD\nc\n=======\nd\n>>>>>>> x\n",
        once,
    );

    // The second is still there, at its new offset, for the next click.
    const rest = try parseConflicts(std.testing.allocator, once);
    defer std.testing.allocator.free(rest);
    try std.testing.expectEqual(@as(usize, 1), rest.len);
    try std.testing.expectEqualStrings("c\n", rest[0].ours);
}

test "an unterminated conflict marker is skipped, not guessed at" {
    const text = "<<<<<<< HEAD\nmine\nno end marker\n";
    const found = try parseConflicts(std.testing.allocator, text);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 0), found.len);

    // An orphan opener above a real region: only the real one, intact.
    const orphan = "<<<<<<< stray\nkeep\n<<<<<<< HEAD\r\na\n=======\r\nb\n>>>>>>> x\r\n";
    const one = try parseConflicts(std.testing.allocator, orphan);
    defer std.testing.allocator.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("a\n", one[0].ours);
    try std.testing.expectEqualStrings("b\n", one[0].theirs);

    // Eight of a kind, or seven run into a word, are not markers.
    const lookalikes = "<<<<<<<< HEAD\na\n========\nb\n>>>>>>>x\n";
    const none = try parseConflicts(std.testing.allocator, lookalikes);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "a rebase todo never opens with a squash" {
    const steps = [_]RebaseStep{
        // Dropping the first one leaves the squash below with nothing above it
        // to fold into: git stops mid-rebase, and the demotion is what prevents
        // that from ever being sent.
        .{ .id = std.mem.zeroes(Oid), .summary = "gone", .action = .drop },
        .{ .id = std.mem.zeroes(Oid), .summary = "second", .action = .squash },
        .{ .id = std.mem.zeroes(Oid), .summary = "third", .action = .squash },
    };

    const todo = try rebaseTodo(std.testing.allocator, &steps);
    defer std.testing.allocator.free(todo);

    try std.testing.expect(std.mem.startsWith(u8, todo, "drop "));
    try std.testing.expect(std.mem.indexOf(u8, todo, "\npick ") != null);
    try std.testing.expect(std.mem.endsWith(u8, todo, " third\n"));
    // Only the third stays a squash; the second was promoted to pick.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, todo, "squash "));
    try std.testing.expect(std.mem.startsWith(u8, todo, "drop " ++ "0" ** 40 ++ " gone\n"));
}

test "an empty rebase todo says noop rather than nothing" {
    const todo = try rebaseTodo(std.testing.allocator, &.{});
    defer std.testing.allocator.free(todo);
    try std.testing.expectEqualStrings("noop\n", todo);
}

test "a failure allowed and cleared is not the error reported next" {
    try init();
    defer shutdown();
    var missing: ?*c.git_repository = null;
    try std.testing.expect(c.git_repository_open(&missing, "/nonexistent/zit") < 0);
    git_error_clear();
    try std.testing.expectEqualStrings("Could not read the repository.", lastError());
}

test "a filter of picked branches walks those, and only those" {
    const z = std.mem.zeroes(Oid);
    const filter: RefFilter = .{ .only = &.{ "a", "c" } };
    try std.testing.expect(filter.walks(.{ .name = "a", .kind = .local, .target = z, .head = false }));
    try std.testing.expect(!filter.walks(.{ .name = "b", .kind = .local, .target = z, .head = true }));
    try std.testing.expect(filter.walks(.{ .name = "c", .kind = .remote, .target = z, .head = false }));
}
