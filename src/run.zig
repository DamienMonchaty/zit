//! Everything Zit *writes* to a repository, by running the `git` binary.
//!
//! Not libgit2: staging, committing and checking out have to honour the
//! credential helpers, the SSH agent, hooks, GPG signing and the user's own
//! config, and every one of those is a callback maze in libgit2 and free here.
//! Reads stay on libgit2, where a revwalk beats parsing text (see `git.zig`).

const std = @import("std");

/// What `git` did. `message` is stderr, trimmed — the thing worth showing when
/// a command fails — and, when it failed, what it printed on stdout after it.
pub const Outcome = struct {
    ok: bool,
    message: []u8,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        gpa.free(self.message);
        self.* = undefined;
    }
};

/// The environment every child gets instead of the process's own, when set.
///
/// For tests only: a child inherits the environment the process started
/// with, so `setenv` never reaches it, and a test that needs git to see a
/// global config of its own has to hand over a whole environment.
pub var env_override: ?*const std.process.Environ.Map = null;

/// Longest stderr, and stdout, kept from a failing command. A conflicted rebase
/// can print a lot; the first lines are the ones that say what happened.
const STDERR_LIMIT: usize = 8 * 1024;

/// Run `git <args...>` inside `cwd`.
///
/// Blocks until the command finishes, so callers on the UI thread should only
/// use it for commands that return promptly. Anything that talks to a remote
/// goes through `Job` instead, which runs it somewhere else.
pub fn git(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const []const u8,
) !Outcome {
    return gitInput(gpa, io, cwd, args, null);
}

/// As `git`, with `input` fed to the command's standard input — which is how a
/// single hunk is staged: `git apply --cached -` reading a patch Zit built.
pub fn gitInput(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const []const u8,
    input: ?[]const u8,
) !Outcome {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);

    return exec(gpa, io, cwd, argv.items, input);
}

/// Hand `path` to whatever the desktop opens that kind of file with.
///
/// Not waited for, and no pipe to it: `xdg-open` on a desktop it does not
/// know (Hyprland, sway, i3) runs the application itself, in the foreground,
/// so waiting — or reading a pipe the application inherits — freezes the
/// window until that editor or browser is closed. A thread of its own reaps it.
///
/// ponytail: only a launcher that cannot start is reported; one that runs and
/// finds no application for the file fails in silence. Wait a moment on the
/// reaping thread and post its exit code back if that is ever missed.
pub fn open(io: std.Io, cwd: []const u8, path: []const u8) !void {
    const opener = switch (@import("builtin").os.tag) {
        .macos => "open",
        .windows => "explorer",
        else => "xdg-open",
    };
    return startDetached(io, cwd, &.{ opener, path });
}

/// Start `argv` with no pipe to Zit and return at once; a thread of its own
/// waits for it, so it leaves no zombie behind.
fn startDetached(io: std.Io, cwd: []const u8, argv: []const []const u8) !void {
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env_override,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const reaper = try std.Thread.spawn(.{}, reap, .{ io, child });
    reaper.detach();
}

fn reap(io: std.Io, child: std.process.Child) void {
    var c = child;
    _ = c.wait(io) catch {};
}

/// Run `argv` in `cwd`, keeping stderr and the exit status: the body of
/// `gitInput`, and of a `Job` running another program.
fn exec(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    input: ?[]const u8,
) !Outcome {
    var ran = try runToEnd(gpa, io, cwd, argv, input, STDERR_LIMIT, STDERR_LIMIT);
    defer ran.deinit(gpa);
    const heads = ran.heads;
    const ok = ran.code == 0;

    // git says some of its failures on stdout — "CONFLICT (content): …",
    // "nothing to commit" — so a failure carries both, stderr first.
    const err_text = std.mem.trim(u8, heads.err.items, " \t\r\n");
    const out_text = if (ok) "" else std.mem.trim(u8, heads.out.items, " \t\r\n");
    const sep: []const u8 = if (err_text.len > 0 and out_text.len > 0) "\n" else "";
    const message = try std.mem.concat(gpa, u8, &.{ err_text, sep, out_text });
    return .{ .ok = ok, .message = message };
}

/// The first bytes of what a child wrote on each stream.
const Heads = struct { out: std.ArrayList(u8) = .empty, err: std.ArrayList(u8) = .empty };

/// What a child wrote, and its exit status — 255 for one that did not exit.
const Ran = struct {
    heads: Heads,
    code: u32,

    fn deinit(self: *Ran, gpa: std.mem.Allocator) void {
        self.heads.out.deinit(gpa);
        self.heads.err.deinit(gpa);
    }
};

/// Spawn `argv` in `cwd`, feed it `input`, read both its streams to their end
/// and wait for it: what `exec` and `captureWithError` both are underneath.
fn runToEnd(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    input: ?[]const u8,
    out_limit: usize,
    err_limit: usize,
) !Ran {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env_override,
        .stdin = if (input == null) .ignore else .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    // Written and closed before the output is drained: git will not finish
    // reading the patch until it sees EOF, and it will not say what went wrong
    // until it has finished.
    if (input) |bytes| {
        var stdin = child.stdin.?;
        child.stdin = null;
        stdin.writeStreamingAll(io, bytes) catch {};
        stdin.close(io);
    }

    var heads = try drain(gpa, io, &child, out_limit, err_limit);
    errdefer {
        heads.out.deinit(gpa);
        heads.err.deinit(gpa);
    }
    const code: u32 = switch (try child.wait(io)) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .heads = heads, .code = code };
}

/// Read the child's stdout and stderr to their end, both at once, keeping the
/// first `out_limit` and `err_limit` bytes and throwing the rest away.
///
/// Both at once, because a child blocked on a full stderr never closes its
/// stdout. To the end, because `wait` reaps the child before it closes the
/// pipes: one left blocked on a pipe nobody reads would never exit.
fn drain(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child, out_limit: usize, err_limit: usize) !Heads {
    var heads: Heads = .{};
    errdefer heads.out.deinit(gpa);
    errdefer heads.err.deinit(gpa);

    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    const lists = [2]*std.ArrayList(u8){ &heads.out, &heads.err };
    const limits = [2]usize{ out_limit, err_limit };
    while (true) {
        mr.fill(4096, .none) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        for (lists, limits, 0..) |list, limit, i| {
            const r = mr.reader(i);
            const got = r.buffered();
            try list.appendSlice(gpa, got[0..@min(got.len, limit - list.items.len)]);
            r.tossBuffered();
        }
    }
    try mr.checkAnyError();
    return heads;
}

/// What a captured program printed, and whether it exited cleanly. `out` is
/// the caller's to free.
pub const Captured = struct { ok: bool, out: []u8 };

/// Run `argv` and keep what it prints, trimmed — for the callers that want an
/// answer rather than a status.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) !Captured {
    return captureWithError(gpa, io, cwd, argv, null);
}

/// As `capture`, keeping the first line of what the program said on stderr
/// in `err_out` — the reason it failed, for the caller to show.
pub fn captureWithError(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8, err_out: ?*std.ArrayList(u8)) !Captured {
    return captureInput(gpa, io, cwd, argv, null, err_out);
}

/// Most a capture keeps of what a program prints. A pull request read whole
/// from GitHub — its comments, files and review threads — runs to a few
/// hundred KB.
const CAPTURE_LIMIT: usize = 8 * 1024 * 1024;

/// As `captureWithError`, with `input` on the program's standard input —
/// a request's body for `curl`, kept off its command line.
pub fn captureInput(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8, input: ?[]const u8, err_out: ?*std.ArrayList(u8)) !Captured {
    var ran = try runToEnd(gpa, io, cwd, argv, input, CAPTURE_LIMIT, 8 * 1024);
    defer ran.deinit(gpa);
    const heads = ran.heads;

    if (err_out) |e| {
        const trimmed = std.mem.trim(u8, heads.err.items, " \t\r\n");
        const first = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
        e.clearRetainingCapacity();
        e.appendSlice(gpa, first) catch {};
    }

    return .{ .ok = ran.code == 0, .out = try gpa.dupe(u8, std.mem.trim(u8, heads.out.items, " \t\r\n")) };
}

/// Start a program that is meant to outlive the call — a terminal — with no
/// pipe to Zit at all: its standard streams go nowhere. A pipe, as `capture`
/// opens, is inherited by whatever the program starts, and reading it to its
/// end waits for that to exit — on Windows, for the terminal to be closed.
/// Waits only for the launcher itself, which returns at once. True when it
/// said it succeeded.
pub fn launch(io: std.Io, cwd: []const u8, argv: []const []const u8) !bool {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env_override,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return switch (try child.wait(io)) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Single-quote `text` for the shell.
///
/// Needed because git always launches an editor through a shell, so driving
/// `rebase -i` means handing it a command line with a path in it. A quote
/// inside that path is what makes this more than cosmetic: unescaped, it would
/// end the quoting and run whatever followed it as a command.
///
/// Returns null rather than truncating when `buf` is too small — a half-quoted
/// path is exactly the thing this exists to prevent.
pub fn shellQuote(buf: []u8, text: []const u8) ?[]const u8 {
    var n: usize = 0;

    const push = struct {
        fn f(dst: []u8, at: *usize, bytes: []const u8) bool {
            if (at.* + bytes.len > dst.len) return false;
            @memcpy(dst[at.*..][0..bytes.len], bytes);
            at.* += bytes.len;
            return true;
        }
    }.f;

    if (!push(buf, &n, "'")) return null;
    for (text) |ch| {
        // Close the quoting, emit an escaped quote, open it again: the only way
        // to get a literal ' inside a single-quoted string.
        if (!push(buf, &n, if (ch == '\'') "'\\''" else &[_]u8{ch})) return null;
    }
    if (!push(buf, &n, "'")) return null;

    return buf[0..n];
}

test "output past the limit is cut, not lost, and does not hang the call" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Megabytes on both streams: both must be read to their end past the
    // limits, or this never returns.
    const loud = "yes | head -c 3000000 >&2; yes | head -c 3000000; exit 1";
    var outcome = try exec(gpa, io, ".", &.{ "sh", "-c", loud }, null);
    defer outcome.deinit(gpa);
    try std.testing.expect(!outcome.ok);
    try std.testing.expect(outcome.message.len > STDERR_LIMIT and outcome.message.len <= 2 * STDERR_LIMIT + 1);
    try std.testing.expect(std.mem.startsWith(u8, outcome.message, "y\ny\n"));

    const answer = try capture(gpa, io, ".", &.{ "sh", "-c", "yes | head -c 3000000 >&2; yes | head -c 12000000" });
    defer gpa.free(answer.out);
    try std.testing.expect(answer.ok);
    try std.testing.expect(answer.out.len > 0 and answer.out.len <= CAPTURE_LIMIT);
    try std.testing.expect(std.mem.startsWith(u8, answer.out, "y\ny\n"));

    // What git says on stdout when it fails is part of the message.
    var conflict = try exec(gpa, io, ".", &.{ "sh", "-c", "echo 'CONFLICT (content): a.txt'; exit 1" }, null);
    defer conflict.deinit(gpa);
    try std.testing.expectEqualStrings("CONFLICT (content): a.txt", conflict.message);
}

test "shell quoting survives spaces, and closes a quote someone put in a path" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("'/home/me/dev/zync'", shellQuote(&buf, "/home/me/dev/zync").?);
    try std.testing.expectEqualStrings("'/home/me/my repo'", shellQuote(&buf, "/home/me/my repo").?);

    // Without the escape this would end the quoted string and leave `rm -rf ~`
    // sitting on the command line git hands to the shell.
    try std.testing.expectEqualStrings(
        "'/tmp/'\\''; rm -rf ~; echo '\\'''",
        shellQuote(&buf, "/tmp/'; rm -rf ~; echo '").?,
    );

    // A buffer that cannot hold the whole thing yields nothing, never a
    // half-quoted path.
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), shellQuote(&tiny, "/some/long/path"));
}

/// A `git` command running somewhere other than the caller's thread.
///
/// This is what keeps a `fetch` over a slow link from freezing the window.
/// Local commands stay synchronous: they finish in milliseconds, and one code
/// path that completes before it returns is worth more than uniformity.
pub const Job = struct {
    /// Owns the copies of everything the command needs.
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,

    /// Written by the worker once, read by the caller until it flips. The only
    /// field that crosses threads while the job is live.
    done: std.atomic.Value(bool),

    /// Null when git could not be started at all, which is a different thing to
    /// say than a command that ran and failed.
    outcome: ?Outcome,

    future: ?std.Io.Future(void),

    /// True when there was no concurrency to be had and the command ran on the
    /// calling thread after all. The work still happens; the window just stops
    /// for its duration.
    inline_run: bool,

    pub const Options = struct {
        /// For the program's standard input.
        input: ?[]const u8 = null,
    };

    /// Begin `git <args...>` in `cwd`.
    ///
    /// Every argument is copied. A caller routinely hands over an argv that
    /// points into a history or work snapshot, and the UI is free to throw
    /// those away — and does, on a timer — while the command is still running.
    pub fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const []const u8,
        opts: Options,
    ) !*Job {
        const input = opts.input;
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);

        job.* = .{
            .arena = .init(gpa),
            .argv = &.{},
            .cwd = "",
            .input = null,
            .done = .init(false),
            .outcome = null,
            .future = null,
            .inline_run = false,
        };
        errdefer job.arena.deinit();

        const arena = job.arena.allocator();

        const argv = try arena.alloc([]const u8, args.len);
        for (args, 0..) |arg, i| argv[i] = try arena.dupe(u8, arg);
        job.argv = argv;
        job.cwd = try arena.dupe(u8, cwd);
        if (input) |bytes| job.input = try arena.dupe(u8, bytes);

        job.future = io.concurrent(work, .{ job, io, gpa }) catch |err| switch (err) {
            // Run it here rather than not at all.
            error.ConcurrencyUnavailable => {
                job.inline_run = true;
                work(job, io, gpa);
                return job;
            },
        };

        return job;
    }

    /// Whether the result is ready. Cheap enough to call every frame.
    pub fn finished(job: *const Job) bool {
        return job.done.load(.acquire);
    }

    /// Take the result and free the job.
    ///
    /// Blocks until the command finishes, so call it when `finished` says yes —
    /// or at shutdown, where blocking is the point: the worker writes into
    /// memory this process is about to give back.
    pub fn finish(job: *Job, gpa: std.mem.Allocator, io: std.Io) ?Outcome {
        if (job.future) |*f| f.await(io);

        // The arena holds argv and cwd; the message inside the outcome is the
        // caller's to free, and outlives this.
        const outcome = job.outcome;
        job.arena.deinit();
        gpa.destroy(job);
        return outcome;
    }

    fn work(job: *Job, io: std.Io, gpa: std.mem.Allocator) void {
        job.outcome = gitInput(gpa, io, job.cwd, job.argv, job.input) catch null;
        job.done.store(true, .release);
        wakeUp();
    }
};

/// Called by a worker thread when it has finished — a `Job`, a `Capture`, any
/// of the others that answer a frame later — so the window draws the answer
/// now, rather than at the next thing that wakes it. Null until the app sets
/// it, and in tests.
pub var wake: ?*const fn () void = null;

pub fn wakeUp() void {
    if (wake) |w| w();
}

/// A program run to its end on another thread for what it prints: a read
/// whose answer may land frames later — a search, a call to GitHub. Every
/// argument is copied, as for a `Job`.
pub const Capture = struct {
    gpa: std.mem.Allocator,
    /// Owns `argv` and `cwd`.
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8 = &.{},
    cwd: []const u8 = "",
    done: std.atomic.Value(bool) = .init(false),
    ok: bool = false,
    /// Standard output, trimmed. Owned.
    out: []u8 = &.{},
    /// The first line of standard error — or why the program could not be run.
    err: std.ArrayList(u8) = .empty,
    future: ?std.Io.Future(void) = null,
    /// For the program's standard input; owned by `arena`.
    input: ?[]const u8 = null,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) !*Capture {
        return startInput(gpa, io, cwd, args, null);
    }

    /// As `start`, with `input` written to the program's standard input.
    pub fn startInput(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8, input: ?[]const u8) !*Capture {
        const self = try gpa.create(Capture);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .arena = .init(gpa) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const argv = try a.alloc([]const u8, args.len);
        for (args, 0..) |arg, i| argv[i] = try a.dupe(u8, arg);
        self.argv = argv;
        self.cwd = try a.dupe(u8, cwd);
        if (input) |bytes| self.input = try a.dupe(u8, bytes);
        self.future = io.concurrent(work, .{ self, io }) catch blk: {
            work(self, io);
            break :blk null;
        };
        return self;
    }

    fn work(self: *Capture, io: std.Io) void {
        defer wakeUp();
        defer self.done.store(true, .release);
        const answer = captureInput(self.gpa, io, self.cwd, self.argv, self.input, &self.err) catch |e| {
            // Not even started: most often the program is not installed.
            self.err.clearRetainingCapacity();
            self.err.print(self.gpa, "{s} could not be run ({s})", .{ self.argv[0], @errorName(e) }) catch {};
            return;
        };
        self.ok = answer.ok;
        self.out = answer.out;
    }

    /// Whether the answer is in. Cheap enough to call every frame.
    pub fn finished(self: *const Capture) bool {
        return self.done.load(.acquire);
    }

    /// Free it, waiting for the program first if it is still running.
    pub fn deinit(self: *Capture, io: std.Io) void {
        if (self.future) |*f| f.await(io);
        self.gpa.free(self.out);
        self.err.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }
};

test "a program handed off is not waited for" {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    try startDetached(io, ".", &.{ "sleep", "3" });
    const took = start.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(took.toMilliseconds() < 1000);
}
