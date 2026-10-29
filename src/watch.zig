//! Telling Zit a repository changed, instead of Zit asking every 0.7 s.
//!
//! inotify, on a thread of its own: a watch on every directory of the working
//! tree git does not ignore, and on the few places in `.git` whose changes
//! move what Zit shows — HEAD, the index, the refs, the reflog Undo reads,
//! the state files of a merge or a rebase. Never `objects/`, which a fetch
//! fills with thousands of files that say nothing until a ref moves. A burst
//! of events — an editor's save, a checkout — is waited out (`QUIET_MS`)
//! and becomes one signal: `changed` set, and the UI woken.
//!
//! Linux only. Elsewhere `start` says so and Zit keeps polling; a watcher
//! that cannot have all the watches it needs (`fs.inotify.max_user_watches`)
//! says so through `failed`, and Zit polls then too.

const std = @import("std");
const builtin = @import("builtin");
const git = @import("git.zig");
const linux = std.os.linux;

pub const supported = builtin.os.tag == .linux;

/// How long a burst has to be quiet before it is reported.
const QUIET_MS = 150;

const WORK_MASK = linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM |
    linux.IN.MOVED_TO | linux.IN.ATTRIB | linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW | linux.IN.EXCL_UNLINK;
const GIT_MASK = linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM |
    linux.IN.MOVED_TO | linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW;

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// With its trailing slash, as libgit2 gives it.
    workdir: []u8,
    gitdir: []u8,
    commondir: []u8,
    wake: *const fn () void,

    /// Set when something changed; taken by the UI.
    changed: std.atomic.Value(bool) = .init(false),
    /// Set when the watcher gave up: too many directories, or no inotify.
    failed: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Directories watched, once set up: for PERF.md and the limit.
    count: std.atomic.Value(usize) = .init(0),

    fd: i32 = -1,
    stop_pipe: [2]i32 = .{ -1, -1 },
    thread: ?std.Thread = null,
    /// Watch descriptor to the directory it watches, absolute, no trailing
    /// slash; owned. The thread's alone.
    dirs: std.AutoHashMapUnmanaged(i32, Dir) = .empty,

    const Dir = struct { path: []u8, in_git: bool };

    /// Start watching the repository at `workdir`. `wake` is called from the
    /// watcher's thread after `changed` is set.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, workdir: []const u8, gitdir: []const u8, commondir: []const u8, wake: *const fn () void) !*Watcher {
        if (comptime !supported) return error.Unsupported;
        const self = try gpa.create(Watcher);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .workdir = &.{}, .gitdir = &.{}, .commondir = &.{}, .wake = wake };
        errdefer self.freePaths();
        self.workdir = try gpa.dupe(u8, workdir);
        self.gitdir = try gpa.dupe(u8, gitdir);
        self.commondir = try gpa.dupe(u8, commondir);

        const fd = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        if (linux.errno(fd) != .SUCCESS) return error.NoInotify;
        self.fd = @intCast(fd);
        errdefer _ = linux.close(self.fd);
        if (linux.errno(linux.pipe2(&self.stop_pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.NoPipe;
        errdefer for (self.stop_pipe) |p| {
            _ = linux.close(p);
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stop and free. Does not wait on anything but the thread, which wakes
    /// for the stop pipe even in the middle of setting up.
    pub fn stop(self: *Watcher) void {
        self.stopping.store(true, .release);
        _ = linux.write(self.stop_pipe[1], "x", 1);
        if (self.thread) |t| t.join();
        var it = self.dirs.valueIterator();
        while (it.next()) |d| self.gpa.free(d.path);
        self.dirs.deinit(self.gpa);
        _ = linux.close(self.fd);
        for (self.stop_pipe) |p| _ = linux.close(p);
        self.freePaths();
        self.gpa.destroy(self);
    }

    /// Whether something changed since the last time this was asked.
    pub fn take(self: *Watcher) bool {
        return self.changed.swap(false, .acq_rel);
    }

    fn freePaths(self: *Watcher) void {
        self.gpa.free(self.workdir);
        self.gpa.free(self.gitdir);
        self.gpa.free(self.commondir);
    }

    fn run(self: *Watcher) void {
        // A handle of its own: libgit2's are not shared across threads, and
        // this one only answers "is this ignored".
        var repo = git.Repo.open(self.workdir) catch return self.fail();
        defer repo.deinit();
        self.setUp(&repo) catch return self.fail();
        self.count.store(self.dirs.count(), .release);

        var buf: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var pending = false;
        while (true) {
            var fds = [_]linux.pollfd{
                .{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_pipe[0], .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, fds.len, if (pending) QUIET_MS else -1);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return self.fail(),
            }
            if (fds[1].revents != 0) return;
            if (rc == 0) {
                // Quiet for long enough: one signal for the burst.
                pending = false;
                self.changed.store(true, .release);
                self.wake();
                continue;
            }
            if (self.drain(&repo, &buf) catch return self.fail()) pending = true;
        }
    }

    fn fail(self: *Watcher) void {
        self.failed.store(true, .release);
        self.wake();
    }

    fn setUp(self: *Watcher, repo: *git.Repo) !void {
        const work = std.mem.trimEnd(u8, self.workdir, "/");
        const gitdir = std.mem.trimEnd(u8, self.gitdir, "/");
        const common = std.mem.trimEnd(u8, self.commondir, "/");
        try self.addTree(repo, work, false);
        // HEAD, the index, packed-refs, ORIG_HEAD, MERGE_HEAD, a rebase's
        // folder appearing; the reflog Undo reads; every ref.
        try self.add(gitdir, true);
        if (!std.mem.eql(u8, gitdir, common)) try self.add(common, true);
        var logs_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&logs_buf, "{s}/logs", .{gitdir})) |logs| self.add(logs, true) catch {} else |_| {}
        var refs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const refs = try std.fmt.bufPrint(&refs_buf, "{s}/refs", .{common});
        try self.addTree(repo, refs, true);
    }

    /// One directory. A folder that cannot be watched — gone, not
    /// readable — is skipped; running out of watches is not.
    fn add(self: *Watcher, path: []const u8, in_git: bool) !void {
        var z_buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&z_buf, "{s}", .{path}, 0) catch return;
        const wd = linux.inotify_add_watch(self.fd, z, if (in_git) GIT_MASK else WORK_MASK);
        switch (linux.errno(wd)) {
            .SUCCESS => {},
            .NOSPC => return error.TooManyWatches,
            else => return,
        }
        const gop = try self.dirs.getOrPut(self.gpa, @intCast(wd));
        // The same directory watched again keeps its descriptor.
        if (gop.found_existing) return;
        gop.value_ptr.* = .{ .path = try self.gpa.dupe(u8, path), .in_git = in_git };
    }

    /// `root` and every directory under it that git does not ignore — never
    /// `.git`, never into a symlink.
    fn addTree(self: *Watcher, repo: *git.Repo, root: []const u8, in_git: bool) !void {
        var stack: std.ArrayList([]u8) = .empty;
        defer {
            for (stack.items) |p| self.gpa.free(p);
            stack.deinit(self.gpa);
        }
        try stack.append(self.gpa, try self.gpa.dupe(u8, root));
        while (stack.pop()) |path| {
            defer self.gpa.free(path);
            if (self.stopping.load(.acquire)) return;
            try self.add(path, in_git);
            var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            var it = dir.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                const child = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ path, entry.name });
                if (!in_git and self.ignored(repo, child, true)) {
                    self.gpa.free(child);
                    continue;
                }
                stack.append(self.gpa, child) catch |err| {
                    self.gpa.free(child);
                    return err;
                };
            }
        }
    }

    /// Whether git ignores `abs`, a path under the working tree.
    fn ignored(self: *Watcher, repo: *git.Repo, abs: []const u8, dir: bool) bool {
        const work = std.mem.trimEnd(u8, self.workdir, "/");
        if (abs.len <= work.len) return false;
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        // A trailing slash is what matches a `build/` pattern to a directory.
        const rel = std.fmt.bufPrintSentinel(&rel_buf, "{s}{s}", .{ abs[work.len + 1 ..], if (dir) "/" else "" }, 0) catch return false;
        return repo.isIgnored(rel);
    }

    /// Everything waiting on the descriptor. True when any of it is worth a
    /// re-read.
    fn drain(self: *Watcher, repo: *git.Repo, buf: []align(@alignOf(linux.inotify_event)) u8) !bool {
        var relevant = false;
        while (true) {
            const n = linux.read(self.fd, buf.ptr, buf.len);
            switch (linux.errno(n)) {
                .SUCCESS => {},
                .AGAIN => return relevant,
                .INTR => continue,
                else => return error.ReadFailed,
            }
            if (n == 0) return relevant;
            var at: usize = 0;
            while (at < n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(buf.ptr + at));
                at += @sizeOf(linux.inotify_event) + ev.len;
                if (try self.event(repo, ev)) relevant = true;
            }
        }
    }

    fn event(self: *Watcher, repo: *git.Repo, ev: *const linux.inotify_event) !bool {
        // The kernel dropped events: something changed, no knowing what.
        if (ev.mask & linux.IN.Q_OVERFLOW != 0) return true;
        if (ev.mask & linux.IN.IGNORED != 0) {
            // Its directory went: the watch with it.
            if (self.dirs.fetchRemove(ev.wd)) |kv| self.gpa.free(kv.value.path);
            return false;
        }
        const dir = self.dirs.get(ev.wd) orelse return false;
        const name = ev.getName() orelse return false;
        // Git's own write-then-rename: the rename to the real name is the
        // change, the lock file says nothing.
        if (std.mem.endsWith(u8, name, ".lock")) return false;
        if (dir.in_git) {
            // A folder appearing under refs/ — `refs/heads/feat/` for a first
            // `feat/x` branch — gets its watch, and its refs are a change.
            if (ev.mask & linux.IN.ISDIR != 0 and ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
                var child_buf: [std.fs.max_path_bytes]u8 = undefined;
                const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir.path, name }) catch return true;
                if (std.mem.indexOf(u8, child, "/refs") != null) try self.addTree(repo, child, true);
            }
            return !std.mem.eql(u8, name, "objects");
        }
        if (std.mem.eql(u8, name, ".git")) return false;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir.path, name }) catch return true;
        const is_dir = ev.mask & linux.IN.ISDIR != 0;
        if (self.ignored(repo, path, is_dir)) return false;
        // A new folder: watched, and walked — files may be in it already,
        // written before its watch existed.
        if (is_dir and ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) try self.addTree(repo, path, false);
        return true;
    }
};

// === Tests ===

const testing = std.testing;

var test_wakes: std.atomic.Value(u32) = .init(0);
fn testWake() void {
    _ = test_wakes.fetchAdd(1, .release);
}

/// Waits up to `ms` for `w` to report a change.
fn changedWithin(w: *Watcher, ms: u64) bool {
    var waited: u64 = 0;
    while (waited < ms) : (waited += 10) {
        if (w.take()) return true;
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "a change to the tree is reported once it is quiet; an ignored one is not" {
    if (!supported) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintSentinel(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);

    try git.init();
    defer git.shutdown();
    var made: ?*git.c.git_repository = null;
    if (git.c.git_repository_init(&made, rel.ptr, 0) < 0) return error.Git;
    git.c.git_repository_free(made);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "zig-out/\n" });
    try tmp.dir.createDirPath(io, "zig-out/bin");
    try tmp.dir.createDirPath(io, "src");

    var repo = try git.Repo.open(rel);
    defer repo.deinit();
    const w = try Watcher.start(testing.allocator, io, repo.workdir().?, repo.gitdir(), repo.commondir(), testWake);
    defer w.stop();
    // Set up: the tree's two folders, not zig-out's, and .git's.
    var waited: u32 = 0;
    while (w.count.load(.acquire) == 0 and waited < 200) : (waited += 1) io.sleep(.fromMilliseconds(10), .awake) catch {};
    try testing.expect(!w.failed.load(.acquire));
    var it = w.dirs.valueIterator();
    while (it.next()) |d| try testing.expect(std.mem.indexOf(u8, d.path, "zig-out") == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "x" });
    try testing.expect(changedWithin(w, 1000));

    // A file in a folder made after the watcher started.
    try tmp.dir.createDirPath(io, "src/new/deeper");
    try testing.expect(changedWithin(w, 1000));
    try tmp.dir.writeFile(io, .{ .sub_path = "src/new/deeper/b.zig", .data = "y" });
    try testing.expect(changedWithin(w, 1000));

    // Inside an ignored folder: nothing.
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/zit", .data = "z" });
    try testing.expect(!changedWithin(w, 400));
}
