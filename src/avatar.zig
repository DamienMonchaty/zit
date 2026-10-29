//! Author pictures, cached on disk.
//!
//! Three places to look, in order, the first answer winning:
//!
//! 1. A GitHub `noreply` address names its account outright.
//! 2. When the repository lives on GitHub and Zit is connected to it, GitHub
//!    itself says whose a commit is, with the account's picture — which is
//!    how colleagues whose work email has no Gravatar still get a face.
//! 3. Gravatar, by the md5 of the lower-cased address.
//!
//! Fetched by `curl` rather than `std.http`: it already knows the user's
//! proxy and CA settings, and one picture at a time off the UI thread is all
//! this needs. GitHub is asked as Zit's own sign-in (`github.zig`). A miss
//! everywhere is remembered as an empty `<hash>.miss` beside the pictures, so
//! it costs one lookup ever. A failure that is not a miss — offline, a
//! timeout — stops the lookups until the app closes.
//!
//! Every lookup tells GitHub or Gravatar which author is being looked at.
//! With the GitHub switch off (`use_github`), only Gravatar is asked.

const std = @import("std");
const run = @import("run.zig");
const pr = @import("pr.zig");
const gh_api = @import("github.zig");

const Entry = union(enum) {
    /// Queued or being fetched.
    pending,
    none,
    /// PNG or JPEG bytes, owned.
    image: []u8,
};

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
/// The cache directory, no trailing slash. Empty means no pictures at all.
var dir: std.ArrayList(u8) = .empty;
/// Keyed by normalised email, owned. Outlives every history snapshot: the
/// pictures do not change when the graph is re-read.
var map: std.StringHashMapUnmanaged(Entry) = .empty;
var queue: std.ArrayList(Job) = .empty;
var worker: ?*Fetch = null;
/// "owner/repo" of the open repository's GitHub remote, empty when it has
/// none. Read by the worker, so only written while none is running.
var github: std.ArrayList(u8) = .empty;
var pending_github: std.ArrayList(u8) = .empty;
/// A lookup failed for want of a network: none more until the app closes.
var stopped = false;

/// Pixels asked for: three times the disc, so it stays sharp on HiDPI.
const SIZE = 64;
/// Longest email worth looking up. Past this it is not an address.
const MAX_EMAIL = 254;

/// The address the person at this machine commits with, lowercased: their
/// picture is the one of the GitHub account Zit is connected as, as GitKraken shows
/// it, whatever GitHub or Gravatar say about the address.
var self_email: std.ArrayList(u8) = .empty;

pub fn setSelfEmail(email: []const u8) void {
    // Not set up — tests, or no cache folder — so nothing is looked up.
    if (dir.items.len == 0) return;
    const trimmed = std.mem.trim(u8, email, " \t\r\n<>");
    if (trimmed.len > MAX_EMAIL) return;
    self_email.clearRetainingCapacity();
    self_email.appendSlice(gpa, trimmed) catch return;
    for (self_email.items) |*ch| ch.* = std.ascii.toLower(ch.*);
}

fn isSelf(key: []const u8) bool {
    return self_email.items.len > 0 and std.mem.eql(u8, key, self_email.items);
}

/// A picture's URL at Zit's size, into `buf`.
fn sized(buf: []u8, url: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}s={d}", .{ url, if (std.mem.indexOfScalar(u8, url, '?') != null) "&" else "?", SIZE }) catch null;
}

/// The signed-in account's picture.
fn selfUrl(buf: []u8) ?[]const u8 {
    if (!gh_api.signedIn()) return null;
    const got = gh_api.call("GET", "/user", null) catch return null;
    defer got.deinit();
    const answer = got.answer();
    if (!answer.ok()) return null;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const user = std.json.parseFromSliceLeaky(struct { avatar_url: ?[]const u8 = null }, a.allocator(), answer.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return sized(buf, user.avatar_url orelse return null);
}

const Job = struct {
    /// Points at `map`'s key.
    key: []const u8,
    /// The address is `self_email`: asked of GitHub as the signed-in user.
    self: bool = false,
    /// A commit by this author, for asking GitHub whose it is. Empty when the
    /// caller had none.
    sha: [40]u8,
};

const Fetch = struct {
    job: Job,
    hex: [32]u8,
    done: std.atomic.Value(bool) = .init(false),
    /// 0 found, 22 nowhere had one (a 404, or no picture in the answer),
    /// anything else a failure to reach them.
    code: u32 = 255,
    /// GitHub could not say whose the commit is — one not pushed yet, most
    /// often the user's own newest. A miss then is only a miss for now.
    unsure: bool = false,
    future: ?std.Io.Future(void) = null,

    fn work(self: *Fetch) void {
        defer run.wakeUp();
        defer self.done.store(true, .release);
        var url_buf: [512]u8 = undefined;

        const ask_github = use_github.load(.acquire);
        if (self.job.self and ask_github) {
            if (selfUrl(&url_buf)) |url| {
                self.code = download(&self.hex, url);
                if (self.code != 22) return;
            }
        }
        if (ask_github) {
            if (noreplyUrl(&url_buf, self.job.key)) |url| {
                self.code = download(&self.hex, url);
                if (self.code != 22) return;
            }
        }
        // No commit of theirs to ask about — a co-author, named only in a
        // trailer: GitHub's commit search finds the account by the address.
        if (ask_github and self.job.sha[0] == 0) {
            if (searchUrl(&url_buf, self.job.key)) |url| {
                self.code = download(&self.hex, url);
                if (self.code != 22) return;
            }
        }
        if (ask_github and github.items.len > 0 and self.job.sha[0] != 0) {
            switch (githubUrl(&url_buf, &self.job.sha)) {
                .url => |url| {
                    self.code = download(&self.hex, url);
                    if (self.code != 22) return;
                },
                .no_account, .unavailable => {},
                .unknown => self.unsure = true,
            }
        }
        const url = std.fmt.bufPrint(&url_buf, "https://www.gravatar.com/avatar/{s}?s={d}&d=404", .{ &self.hex, SIZE }) catch return;
        self.code = download(&self.hex, url);
    }
};

/// 0 saved, 22 the server has none — a 404, or an answer that is no picture —
/// and 255 for anything else: offline, a timeout, a 429 or a 5xx, none of
/// which says anything about next time. curl prints the status; into `.part`
/// and renamed after, so a download cut short never sits in the cache as a
/// picture. `-g` so a `{` or `[` in the URL is not a curl pattern.
fn download(hex: *const [32]u8, url: []const u8) u32 {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/{s}.part", .{ dir.items, hex }) catch return 255;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}.png", .{ dir.items, hex }) catch return 255;

    const answer = run.capture(gpa, io, ".", &.{ "curl", "-gsSL", "--max-time", "10", "--max-filesize", "1048576", "-w", "%{http_code}", "-o", tmp, url }) catch return 255;
    defer gpa.free(answer.out);
    const code: u32 = blk: {
        if (!answer.ok) break :blk 255;
        if (std.mem.eql(u8, answer.out, "404")) break :blk 22;
        if (!std.mem.eql(u8, answer.out, "200")) break :blk 255;
        // An empty body leaves no file at all: a miss as much as HTML is.
        const head = std.Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .limited(1 << 20)) catch break :blk 22;
        defer gpa.free(head);
        break :blk if (isImage(head)) 0 else 22;
    };
    if (code != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return code;
    }
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), dest, io) catch return 255;
    return 0;
}

/// PNG or JPEG, by their first bytes: what the cache promises to hold.
fn isImage(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG") or std.mem.startsWith(u8, bytes, "\xff\xd8\xff");
}

/// `12345+login@users.noreply.github.com` -> that account's picture; the
/// older `login@users.noreply.github.com` too.
fn noreplyUrl(buf: []u8, email: []const u8) ?[]const u8 {
    const suffix = "@users.noreply.github.com";
    if (!std.mem.endsWith(u8, email, suffix)) return null;
    const local = email[0 .. email.len - suffix.len];
    // Ids are digits and logins letters, digits, dashes and (managed users)
    // underscores: anything else is not GitHub's, and would not go into a URL
    // as it is.
    for (local) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '+') return null;
    if (std.mem.indexOfScalar(u8, local, '+')) |plus| {
        return std.fmt.bufPrint(buf, "https://avatars.githubusercontent.com/u/{s}?s={d}", .{ local[0..plus], SIZE }) catch null;
    }
    return std.fmt.bufPrint(buf, "https://github.com/{s}.png?size={d}", .{ local, SIZE }) catch null;
}

const GithubAnswer = union(enum) {
    url: []const u8,
    /// GitHub has the commit and no account behind it.
    no_account,
    /// GitHub did not say yet: not pushed, rate-limited, down.
    unknown,
    /// Not connected, offline: nothing to ask, so Gravatar's answer
    /// stands.
    unavailable,
};

/// Ask GitHub who wrote `sha`, and where their picture is.
fn githubUrl(buf: []u8, sha: *const [40]u8) GithubAnswer {
    if (!gh_api.signedIn()) return .unavailable;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/repos/{s}/commits/{s}", .{ github.items, sha }) catch return .unavailable;
    const got = gh_api.call("GET", path, null) catch return .unavailable;
    defer got.deinit();
    const answer = got.answer();
    // GitHub answered without settling it — a 422 for a commit not pushed, a
    // rate limit, a 5xx — so it may next time. Signed out, offline or a
    // repository it cannot see (404) will not change by asking again.
    if (answer.code == 0 or answer.code == 401 or answer.code == 404) return .unavailable;
    if (!answer.ok()) return .unknown;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const commit = std.json.parseFromSliceLeaky(struct { author: ?struct { avatar_url: ?[]const u8 = null } = null }, a.allocator(), answer.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .unknown;
    const author = commit.author orelse return .no_account;
    return .{ .url = sized(buf, author.avatar_url orelse return .no_account) orelse return .unknown };
}

/// The picture of the GitHub account behind `email`, found through any
/// commit it authored anywhere on GitHub. Null when not connected, offline,
/// or GitHub knows no such account.
fn searchUrl(buf: []u8, email: []const u8) ?[]const u8 {
    if (!gh_api.signedIn()) return null;
    var path_buf: [MAX_EMAIL * 3 + 64]u8 = undefined;
    var w: usize = 0;
    const head = "/search/commits?per_page=1&q=author-email:";
    @memcpy(path_buf[0..head.len], head);
    w = head.len;
    // The address percent-encoded: `+` and `@` mean other things in a query.
    for (email) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_') {
            path_buf[w] = ch;
            w += 1;
        } else {
            _ = std.fmt.bufPrint(path_buf[w..], "%{X:0>2}", .{ch}) catch return null;
            w += 3;
        }
    }
    const got = gh_api.call("GET", path_buf[0..w], null) catch return null;
    defer got.deinit();
    const answer = got.answer();
    if (!answer.ok()) return null;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const found = std.json.parseFromSliceLeaky(struct { items: []const struct { author: ?struct { avatar_url: ?[]const u8 = null } = null } = &.{} }, a.allocator(), answer.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (found.items.len == 0) return null;
    const author = found.items[0].author orelse return null;
    return sized(buf, author.avatar_url orelse return null);
}

/// "owner/repo" out of a GitHub remote URL, https or ssh — `ssh.github.com`
/// is its ssh over port 443. Null for anywhere else.
pub fn githubSlug(url: []const u8) ?[]const u8 {
    const r = pr.splitRemote(url) orelse return null;
    if (!std.mem.eql(u8, r.host, "github.com") and !std.mem.eql(u8, r.host, "www.github.com") and !std.mem.eql(u8, r.host, "ssh.github.com")) return null;
    var rest = std.mem.trim(u8, r.path, "/");
    if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - 4];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or slash + 1 >= rest.len or std.mem.indexOfScalar(u8, rest[slash + 1 ..], '/') != null) return null;
    return rest;
}

/// Whether GitHub may be asked at all — the integrations switch. Off, only
/// Gravatar is: no `noreply` picture, no search, no commit lookup.
pub var use_github: std.atomic.Value(bool) = .init(true);

/// The repository commits are asked about. Applied between fetches, never
/// under one.
pub fn setGithubRepo(slug: ?[]const u8) void {
    // Not set up: no cache, no lookups, nothing to point anywhere.
    if (dir.items.len == 0) return;
    pending_github.clearRetainingCapacity();
    if (slug) |s| pending_github.appendSlice(gpa, s) catch {};
    if (worker == null) swapGithub();
}

fn swapGithub() void {
    github.clearRetainingCapacity();
    github.appendSlice(gpa, pending_github.items) catch {};
}

pub fn init(allocator: std.mem.Allocator, the_io: std.Io, cache_dir: []const u8) void {
    gpa = allocator;
    io = the_io;
    dir.appendSlice(gpa, cache_dir) catch return;
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch dir.clearRetainingCapacity();
}

pub fn deinit() void {
    if (self_email.capacity > 0) self_email.deinit(gpa);
    self_email = .empty;
    if (worker) |w| {
        if (w.future) |*f| f.await(io);
        gpa.destroy(w);
        worker = null;
    }
    var it = map.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .image) gpa.free(e.value_ptr.image);
        gpa.free(e.key_ptr.*);
    }
    map.deinit(gpa);
    queue.deinit(gpa);
    dir.deinit(gpa);
    github.deinit(gpa);
    pending_github.deinit(gpa);
    map = .empty;
    queue = .empty;
    stopped = false;
    dir = .empty;
    github = .empty;
    pending_github = .empty;
}

/// The picture for `email`, if there is one yet. The first call for an email
/// reads the disk cache or queues a lookup; later ones are a hash lookup.
/// `sha` is any commit of theirs, hex, for asking GitHub.
pub fn get(email: []const u8, sha: []const u8) ?[]const u8 {
    if (dir.items.len == 0) return null;

    var norm_buf: [MAX_EMAIL]u8 = undefined;
    const trimmed = std.mem.trim(u8, email, " \t<>");
    if (trimmed.len == 0 or trimmed.len > norm_buf.len) return null;
    const key = std.ascii.lowerString(&norm_buf, trimmed);

    if (map.get(key)) |entry| return switch (entry) {
        .image => |bytes| bytes,
        else => null,
    };

    const owned = gpa.dupe(u8, key) catch return null;
    map.put(gpa, owned, .pending) catch {
        gpa.free(owned);
        return null;
    };

    const hex = hashHex(owned);
    if (readCached(&hex, "png")) |bytes| {
        if (bytes.len > 0) {
            map.putAssumeCapacity(owned, .{ .image = bytes });
            return bytes;
        }
        gpa.free(bytes);
    }
    // A miss is remembered, except for the person at this machine: their
    // address may have been looked up before Zit was connected, or on a
    // commit GitHub had not seen yet.
    const self = isSelf(owned);
    if (readCached(&hex, "miss")) |marker| {
        gpa.free(marker);
        if (!self) {
            map.putAssumeCapacity(owned, .none);
            return null;
        }
    }

    if (stopped) {
        map.putAssumeCapacity(owned, .none);
        return null;
    }
    var job: Job = .{ .key = owned, .sha = @splat(0), .self = self };
    if (sha.len == 40) @memcpy(&job.sha, sha);
    queue.append(gpa, job) catch map.putAssumeCapacity(owned, .none);
    // Queued during a frame, started by the next: ask for it, since nothing
    // else may come to draw one.
    if (worker == null) run.wakeUp();
    return null;
}

/// Land a finished lookup and start the next. Once a frame, on the UI thread.
/// True when a picture landed. A lookup still out says nothing: its end
/// wakes the window (`run.wake`), and drawing meanwhile would draw the same.
pub fn pump() bool {
    var landed = false;
    if (worker) |w| {
        if (!w.done.load(.acquire)) return false;
        if (w.future) |*f| f.await(io);

        const entry: Entry = switch (w.code) {
            0 => if (readCached(&w.hex, "png")) |bytes| .{ .image = bytes } else .none,
            // Nobody had one: not next launch either. Delete the `.miss`
            // files to look again.
            22 => blk: {
                if (!w.unsure) writeMarker(&w.hex);
                break :blk .none;
            },
            // Offline, a timeout, no curl: the next one would fail the same
            // way, ten seconds of redraw each. Stop for this session; the
            // queued ones stay pending and show their initials.
            else => blk: {
                queue.clearRetainingCapacity();
                stopped = true;
                break :blk .none;
            },
        };
        // Only a picture changes what is drawn: a miss leaves the initials.
        landed = entry == .image;
        if (map.getPtr(w.job.key)) |slot| slot.* = entry else if (entry == .image) gpa.free(entry.image);

        gpa.destroy(w);
        worker = null;
        swapGithub();
    }

    if (queue.items.len == 0) return landed;

    const job = queue.orderedRemove(0);
    const w = gpa.create(Fetch) catch return false;
    w.* = .{ .job = job, .hex = hashHex(job.key) };
    worker = w;
    w.future = io.concurrent(Fetch.work, .{w}) catch blk: {
        w.work();
        break :blk null;
    };
    return landed;
}

fn hashHex(key: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(key, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn readCached(hex: *const [32]u8, ext: []const u8) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.{s}", .{ dir.items, hex, ext }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
}

fn writeMarker(hex: *const [32]u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.miss", .{ dir.items, hex }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" }) catch {};
}

test "the key is Gravatar's: md5 of the trimmed, lower-cased address" {
    // The example from Gravatar's own documentation.
    const hex = hashHex("myemailaddress@example.com");
    try std.testing.expectEqualStrings("0bc83cb571cd1c50ba6f3e8a78ef1346", &hex);
}

test "GitHub addresses and remotes are read for what they name" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://avatars.githubusercontent.com/u/90600764?s=64",
        noreplyUrl(&buf, "90600764+meretof@users.noreply.github.com").?,
    );
    try std.testing.expectEqualStrings("https://github.com/octo.png?size=64", noreplyUrl(&buf, "octo@users.noreply.github.com").?);
    try std.testing.expectEqual(@as(?[]const u8, null), noreplyUrl(&buf, "someone@example.com"));

    try std.testing.expectEqualStrings("acme/api", githubSlug("https://github.com/acme/api.git").?);
    try std.testing.expectEqualStrings("me/zync", githubSlug("git@github.com:me/zync.git").?);
    try std.testing.expectEqual(@as(?[]const u8, null), githubSlug("https://gitlab.com/me/zync.git"));
    try std.testing.expectEqual(@as(?[]const u8, null), githubSlug("https://notgithub.com/o/r.git"));
    try std.testing.expectEqual(@as(?[]const u8, null), githubSlug("git@gitlab.com:me/github.com.git"));
    try std.testing.expectEqualStrings("o/r", githubSlug("https://github.com/o/r.git/").?);
    try std.testing.expectEqualStrings("o/r", githubSlug("ssh://git@ssh.github.com:443/o/r.git").?);
    try std.testing.expectEqual(@as(?[]const u8, null), noreplyUrl(&buf, "a{b} c@users.noreply.github.com"));

    try std.testing.expect(isImage("\x89PNG\r\n"));
    try std.testing.expect(isImage("\xff\xd8\xff\xe0"));
    try std.testing.expect(!isImage("<!DOCTYPE html>"));
    try std.testing.expect(!isImage(""));
}

test "a cached picture and a cached miss are both answered from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    init(std.testing.allocator, std.testing.io, cache);
    defer deinit();

    const have = hashHex("have@x.invalid");
    const miss = hashHex("miss@x.invalid");
    var name_buf: [64]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "{s}.png", .{&have}), .data = "PNG" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "{s}.miss", .{&miss}), .data = "" });

    try std.testing.expectEqualStrings("PNG", get(" Have@X.invalid ", "").?);
    try std.testing.expectEqual(@as(?[]const u8, null), get("miss@x.invalid", ""));
    // Neither went to the network.
    try std.testing.expectEqual(@as(usize, 0), queue.items.len);
    // An unknown one is queued once, however often it is asked for.
    _ = get("new@x.invalid", "");
    _ = get("NEW@x.invalid", "");
    _ = get("other@x.invalid", "");
    try std.testing.expectEqual(@as(usize, 2), queue.items.len);

    // A lookup that failed for want of a network takes the queue with it,
    // rather than timing out once per author.
    const w = try gpa.create(Fetch);
    w.* = .{ .job = queue.orderedRemove(0), .hex = undefined, .code = 6 };
    w.done.store(true, .release);
    worker = w;
    try std.testing.expect(!pump());
    try std.testing.expectEqual(@as(usize, 0), queue.items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), get("other@x.invalid", ""));
    // Nor does an author seen for the first time after it.
    _ = get("later@x.invalid", "");
    try std.testing.expectEqual(@as(usize, 0), queue.items.len);
}
