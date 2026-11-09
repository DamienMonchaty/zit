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
//! On Windows, ReadDirectoryChangesExW instead: one handle that sees a whole
//! tree — the working tree, `.git` inside it as a rule — so nothing to walk
//! and no watch per folder, but every event under it comes in, an ignored
//! folder's too, and is sorted here.
//!
//! Elsewhere `start` says so and Zit keeps polling; a watcher that cannot
//! have all the watches it needs (`fs.inotify.max_user_watches`), or a
//! folder Windows will not watch (some network shares), says so through
//! `failed`, and Zit polls then too.

const std = @import("std");
const builtin = @import("builtin");
const git = @import("git.zig");
const linux = std.os.linux;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;
pub const supported = builtin.os.tag == .linux or is_windows;

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

    /// Windows: the trees watched — the working tree, and git's folders
    /// where it does not hold them — and what ends the thread's wait.
    roots: if (is_windows) [MAX_ROOTS]Root else void = if (is_windows) undefined else {},
    root_count: usize = 0,
    stop_event: if (is_windows) ?windows.HANDLE else void = if (is_windows) null else {},

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

        if (is_windows) {
            try self.openRoots();
            errdefer self.closeRoots();
            // Windows commits a thread's whole stack when it starts: Zig's
            // default, 16 MB, was that much more of the process's commit
            // charge. Two path buffers and libgit2's ignore lookup fit in 1.
            self.thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, runWindows, .{self});
            return self;
        }

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
        if (is_windows) {
            if (self.stop_event) |e| _ = win32.SetEvent(e);
            if (self.thread) |t| t.join();
            self.closeRoots();
            self.freePaths();
            self.gpa.destroy(self);
            return;
        }
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
            return gitRelevant(name);
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

    // === Windows ===

    fn openRoots(self: *Watcher) !void {
        errdefer self.closeRoots();
        self.stop_event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.NoEvent;
        try self.openRoot(self.workdir);
        // git's folders, where the working tree's handle does not see them
        // already: a linked worktree's.
        if (!std.mem.startsWith(u8, self.commondir, self.workdir)) try self.openRoot(self.commondir);
        if (!std.mem.startsWith(u8, self.gitdir, self.workdir) and !std.mem.startsWith(u8, self.gitdir, self.commondir))
            try self.openRoot(self.gitdir);
    }

    fn openRoot(self: *Watcher, path: []const u8) !void {
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(self.gpa, std.mem.trimEnd(u8, path, "/"));
        defer self.gpa.free(wide);
        for (wide) |*c| {
            if (c.* == '/') c.* = '\\';
        }
        const handle = win32.CreateFileW(wide.ptr, win32.FILE_LIST_DIRECTORY, win32.FILE_SHARE_ALL, null, win32.OPEN_EXISTING, win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.CannotWatch;
        errdefer windows.CloseHandle(handle);
        const done = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.NoEvent;
        const root = &self.roots[self.root_count];
        root.path = path;
        root.handle = handle;
        root.event = done;
        root.overlapped = .{};
        self.root_count += 1;
    }

    fn closeRoots(self: *Watcher) void {
        for (self.roots[0..self.root_count]) |*root| {
            // The kernel writes into `buf` until the read is cancelled, and
            // this memory is about to go.
            if (win32.CancelIoEx(root.handle, &root.overlapped).toBool()) {
                var len: u32 = 0;
                _ = win32.GetOverlappedResult(root.handle, &root.overlapped, &len, .TRUE);
            }
            windows.CloseHandle(root.event);
            windows.CloseHandle(root.handle);
        }
        self.root_count = 0;
        if (self.stop_event) |e| windows.CloseHandle(e);
        self.stop_event = null;
    }

    fn runWindows(self: *Watcher) void {
        var repo = git.Repo.open(self.workdir) catch return self.fail();
        defer repo.deinit();
        const roots = self.roots[0..self.root_count];
        var waits: [MAX_ROOTS + 1]windows.HANDLE = undefined;
        for (roots, 0..) |*root, i| {
            listen(root) catch return self.fail();
            waits[i] = root.event;
        }
        waits[roots.len] = self.stop_event.?;
        self.count.store(roots.len, .release);

        var pending = false;
        while (true) {
            const at = win32.WaitForMultipleObjects(@intCast(roots.len + 1), &waits, .FALSE, if (pending) QUIET_MS else win32.INFINITE);
            if (at == win32.WAIT_TIMEOUT) {
                // Quiet for long enough: one signal for the burst.
                pending = false;
                self.changed.store(true, .release);
                self.wake();
                continue;
            }
            if (at == roots.len) return;
            if (at > roots.len) return self.fail();
            const root = &roots[at];
            var len: u32 = 0;
            const relevant = if (win32.GetOverlappedResult(root.handle, &root.overlapped, &len, .FALSE).toBool())
                // Nothing in it: the buffer overflowed — something changed,
                // no knowing what.
                len == 0 or self.sortEvents(&repo, root, root.buf[0..len])
            else switch (windows.GetLastError()) {
                .NOTIFY_ENUM_DIR => true,
                // The folder went, or its volume.
                else => return self.fail(),
            };
            listen(root) catch return self.fail();
            if (relevant) pending = true;
        }
    }

    fn listen(root: *Root) !void {
        root.overlapped = .{ .event = root.event };
        if (!win32.ReadDirectoryChangesExW(root.handle, &root.buf, root.buf.len, .TRUE, win32.NOTIFY_CHANGES, null, &root.overlapped, null, win32.NOTIFY_EXTENDED).toBool())
            return error.CannotWatch;
    }

    /// Whether any of the events in `bytes` is worth a re-read. The first
    /// that is settles it: nothing else is done for the rest.
    fn sortEvents(self: *Watcher, repo: *git.Repo, root: *const Root, bytes: []u8) bool {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var at: usize = 0;
        while (at + @sizeOf(windows.FILE.NOTIFY.EXTENDED_INFORMATION) <= bytes.len) {
            // Each entry starts on a 4-byte boundary, not on its 64-bit
            // fields' 8.
            const info: *align(4) const windows.FILE.NOTIFY.EXTENDED_INFORMATION = @ptrCast(@alignCast(bytes.ptr + at));
            const name_ptr: [*]const u16 = @ptrCast(&info.FileName);
            const name = name_ptr[0 .. info.FileNameLength / 2];
            // Too long to spell out: count it as a change.
            if (root.path.len + name.len * 3 > path_buf.len) return true;
            @memcpy(path_buf[0..root.path.len], root.path);
            const len = root.path.len + std.unicode.wtf16LeToWtf8(path_buf[root.path.len..], name);
            std.mem.replaceScalar(u8, path_buf[root.path.len..len], '\\', '/');
            const is_dir = info.FileAttributes.DIRECTORY;
            if (self.relevantOnWindows(repo, path_buf[0..len], is_dir, info.Action == win32.FILE_ACTION_MODIFIED)) return true;
            if (info.NextEntryOffset == 0) break;
            at += info.NextEntryOffset;
        }
        return false;
    }

    /// Whether a change at `path` — absolute, with forward slashes — moves
    /// anything Zit shows.
    fn relevantOnWindows(self: *Watcher, repo: *git.Repo, path: []const u8, is_dir: bool, modified: bool) bool {
        // A folder's own times move with every name in it, and each of those
        // comes as its own event. `.git`'s move with every lock file git
        // makes, and its `hooks/` with every status Git LFS reads.
        if (is_dir and modified) return false;
        for ([_][]const u8{ self.gitdir, self.commondir }) |dir| {
            if (std.mem.startsWith(u8, path, dir)) return gitRelevant(path[dir.len..]);
        }
        if (!std.mem.startsWith(u8, path, self.workdir)) return false;
        const rel = path[self.workdir.len..];
        // Another repository's — a submodule's, a clone inside this one —
        // or the `.git` file of a linked worktree.
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".git")) return false;
        }
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        // A trailing slash is what matches a `build/` pattern to a directory.
        const rel_z = std.fmt.bufPrintSentinel(&rel_buf, "{s}{s}", .{ rel, if (is_dir) "/" else "" }, 0) catch return true;
        return !repo.isIgnored(rel_z);
    }
};

/// Whether a change at `sub`, a path under one of git's folders, is one. Not
/// the object store, which a fetch fills with thousands of files that say
/// nothing until a ref moves; not a lock file, which git renames onto the
/// real name — the rename is the change; not FETCH_HEAD, which every fetch
/// rewrites, one that moves no ref too.
fn gitRelevant(sub: []const u8) bool {
    if (std.mem.endsWith(u8, sub, ".lock")) return false;
    const first = sub[0 .. std.mem.indexOfScalar(u8, sub, '/') orelse sub.len];
    return !std.mem.eql(u8, first, "objects") and !std.mem.eql(u8, sub, "FETCH_HEAD");
}

/// The working tree, the gitdir, the commondir: what a repository can need
/// watched on Windows, at most.
const MAX_ROOTS = 3;

/// One tree watched on Windows.
const Root = struct {
    /// With its trailing slash: what the events' names are relative to.
    path: []const u8,
    handle: windows.HANDLE,
    event: windows.HANDLE,
    overlapped: Overlapped,
    /// 64 KB: the most a notification can carry from a network share.
    buf: [64 * 1024]u8 align(@alignOf(windows.FILE.NOTIFY.EXTENDED_INFORMATION)),
};

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?windows.HANDLE = null,
};

/// What Zig's standard library does not declare.
const win32 = struct {
    const FILE_LIST_DIRECTORY = 0x1;
    const FILE_SHARE_ALL = 0x1 | 0x2 | 0x4;
    const OPEN_EXISTING = 3;
    const FILE_FLAG_BACKUP_SEMANTICS = 0x0200_0000;
    const FILE_FLAG_OVERLAPPED = 0x4000_0000;
    /// Names coming and going, folders' too, and writes: not attributes or
    /// access times, which git does not show.
    const NOTIFY_CHANGES = 0x1 | 0x2 | 0x8 | 0x10;
    /// ReadDirectoryNotifyExtendedInformation: each event says whether its
    /// name is a folder.
    const NOTIFY_EXTENDED: c_int = 2;
    const FILE_ACTION_MODIFIED = 3;
    const WAIT_TIMEOUT = 0x102;
    const INFINITE = 0xFFFF_FFFF;

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual_reset: windows.BOOL, initial: windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadDirectoryChangesExW(dir: windows.HANDLE, buf: *anyopaque, len: u32, subtree: windows.BOOL, filter: u32, returned: ?*u32, overlapped: *Overlapped, routine: ?*anyopaque, class: c_int) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetOverlappedResult(file: windows.HANDLE, overlapped: *Overlapped, transferred: *u32, wait: windows.BOOL) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CancelIoEx(file: windows.HANDLE, overlapped: ?*Overlapped) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const windows.HANDLE, all: windows.BOOL, ms: u32) callconv(.winapi) u32;
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
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "zig-out/\n*.o\n" });
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
    // An ignored file in a folder that is not — whose own times it moves.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.o", .data = "o" });
    try testing.expect(!changedWithin(w, 400));
    // What a fetch that moved nothing leaves, and the lock git takes first.
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/FETCH_HEAD", .data = "f" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/index.lock", .data = "l" });
    try testing.expect(!changedWithin(w, 400));
    // A ref moving is a change.
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/refs/heads/main", .data = "0000000000000000000000000000000000000000\n" });
    try testing.expect(changedWithin(w, 1000));
}
