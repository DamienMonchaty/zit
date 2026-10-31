//! Where Zit remembers what you had open.
//!
//! One small JSON file under the user's config directory: the groups of
//! repositories, and which one was in front. None of it is essential, so a
//! missing or unreadable file reads as an empty workspace rather than an error,
//! and every write is best effort — losing the tab list is a nuisance, and
//! refusing to start over it would be worse than the nuisance.

const std = @import("std");

/// A named set of repositories, which is all a tab group is.
pub const Group = struct {
    name: []const u8,
    /// Working directories, absolute, exactly as libgit2 resolved them — so the
    /// same repository reached by two different paths is still one entry.
    repos: []const []const u8,
    /// Index into the strip's group colours.
    color: u8 = 0,
    /// Folded to its label in the strip. Read from files of before the
    /// workspaces, never acted on.
    collapsed: bool = false,
    /// The tab it was on, reopened when it is switched back to.
    last: usize = 0,
};

/// The file's whole contents.
///
/// Every field has a default, so a file written by an older Zit still loads.
/// A file that is not JSON at all loads as nothing; `load` moves it aside
/// first, so the empty workspace saved next does not overwrite it.
pub const File = struct {
    groups: []const Group = &.{},
    active_group: usize = 0,
    active_repo: usize = 0,
    /// Which of the two compiled-in themes to start in.
    dark: bool = true,
    /// Repositories that were open once and whose tab has since been closed,
    /// newest first. Closing a tab is not forgetting the repository.
    recent: []const []const u8 = &.{},
    commit: CommitPrefs = .{},
    /// Fetch every remote this often, quietly; 0 never.
    auto_fetch_minutes: u32 = 10,
    /// Remote branches drawn in the graph.
    show_remote_branches: bool = true,
    /// The graph's history mode: first parents from HEAD, or every branch.
    first_parent: bool = false,
    /// The graph column's width as dragged; 0 is as wide as the lanes need.
    graph_width: f32 = 0,
    /// The branch column's width as dragged; 0 is its default.
    branch_width: f32 = 0,
    /// Open last run's tabs again at start, rather than the start page.
    remember_tabs: bool = true,
    /// The first branch of a repository made from the new-repository dialog.
    default_branch: []const u8 = "main",
    /// Fetches drop the remote branches deleted on the remote.
    prune: bool = true,
    /// GitHub, through Zit's own sign-in: pull requests, issues, checks, the
    /// account. Off, Zit is a git client and nothing more.
    integrations: bool = true,
};

/// How a commit message is put together. Global rather than per repository:
/// the ticket is found by its shape, so one setting fits every repository.
pub const CommitPrefs = struct {
    /// Put the ticket the branch is named after (`PROJ-80-…`) in the message.
    ticket: bool = true,
    /// …as a `Refs: PROJ-80` trailer rather than at the head of the summary.
    ticket_footer: bool = false,
    /// A type menu and a scope field before the summary: `feat(api): …`.
    conventional: bool = false,
    /// Break the description's long lines at 72 columns, as git log expects.
    wrap_body: bool = true,
    signoff: bool = false,
    /// `-S`. Off still signs when git's own `commit.gpgsign` says to.
    sign: bool = false,
    /// `-s` on the tags made here: an annotated, signed tag.
    sign_tags: bool = false,
    /// What a new message starts from when git's `commit.template` names
    /// nothing.
    template: []const u8 = "",
};

/// A loaded `File` and whatever owns its strings.
pub const Loaded = struct {
    parsed: ?std.json.Parsed(File),
    file: File,

    pub fn deinit(self: *Loaded) void {
        if (self.parsed) |*p| p.deinit();
        self.* = undefined;
    }
};

const FILE_NAME = "workspace.json";

/// Bigger than any plausible tab list, small enough that a file which is not
/// really a workspace cannot eat memory on the way to being rejected.
const MAX_BYTES: usize = 1 << 20;

pub const Kind = enum { config, cache };

/// Zit's own folder of `kind`, then `sub` inside it when it is not empty:
/// `$XDG_CONFIG_HOME/zit`, else `$HOME/.config/zit` — `.cache` for a cache.
/// On Windows %APPDATA% for settings, which roam, and %LOCALAPPDATA% for a
/// cache, which is machine-local.
///
/// Null when the environment names none of them, which is simply when Zit
/// does not remember anything between runs.
pub fn appDir(env: std.process.Environ.Map, buf: []u8, kind: Kind, sub: []const u8) ?[]const u8 {
    const windows = @import("builtin").os.tag == .windows;
    const sep = if (windows) "\\" else "/";
    const base: ?[]const u8 = if (windows)
        env.get(if (kind == .config) "APPDATA" else "LOCALAPPDATA") orelse return null
    else blk: {
        // Set but empty is how a shell says "unset" by accident.
        const xdg = env.get(if (kind == .config) "XDG_CONFIG_HOME" else "XDG_CACHE_HOME") orelse break :blk null;
        break :blk if (xdg.len > 0) xdg else null;
    };
    const root = if (base) |b|
        std.fmt.bufPrint(buf, "{s}" ++ sep ++ "zit", .{b}) catch return null
    else blk: {
        const home = env.get("HOME") orelse return null;
        if (home.len == 0) return null;
        break :blk std.fmt.bufPrint(buf, "{s}/{s}/zit", .{ home, if (kind == .config) ".config" else ".cache" }) catch return null;
    };
    if (sub.len == 0) return root;
    const tail = std.fmt.bufPrint(buf[root.len..], sep ++ "{s}", .{sub}) catch return null;
    return buf[0 .. root.len + tail.len];
}

/// Read the workspace out of `dir`.
///
/// Never fails. No file, no directory, and malformed JSON all mean the same
/// thing here — that there is nothing to restore — and the caller has the same
/// answer for all three. A file that is there but will not load is kept, as
/// `workspace.json.bak`: the next save would otherwise replace it with nothing.
pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) Loaded {
    const empty: Loaded = .{ .parsed = null, .file = .{} };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, FILE_NAME }) catch return empty;
    var bak_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bak = std.fmt.bufPrint(&bak_buf, "{s}.bak", .{path}) catch return empty;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_BYTES)) catch |err| {
        if (err != error.FileNotFound) std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), bak, io) catch {};
        return empty;
    };
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(File, gpa, bytes, .{
        .ignore_unknown_fields = true,
        // Without this, a string that needed no unescaping is a slice into
        // `bytes` — which is freed on the way out of this function, leaving
        // every path in the workspace pointing at nothing.
        .allocate = .alloc_always,
    }) catch {
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), bak, io) catch {};
        return empty;
    };

    return .{ .parsed = parsed, .file = parsed.value };
}

/// Write the workspace into `dir`, creating the directory if it is not there.
///
/// Silent: this runs on every tab change, and a config directory that cannot
/// be written is not worth interrupting someone's work over. False when it
/// could not be written: the caller tries again.
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, file: File) bool {
    // Indented rather than minified. It is a config file, and the first thing
    // anyone does with one of those is open it.
    const text = std.json.Stringify.valueAlloc(gpa, file, .{ .whitespace = .indent_2 }) catch return false;
    defer gpa.free(text);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, FILE_NAME }) catch return false;

    // Written beside it, flushed to the disk, and only then renamed over it: a
    // crash or a power cut halfway leaves the old file whole, never an empty
    // one the rename reached the disk before the bytes did.
    var out = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true }) catch return false;
    defer out.deinit(io);
    out.file.writeStreamingAll(io, text) catch return false;
    out.file.sync(io) catch return false;
    out.replace(io) catch return false;
    return true;
}

test "a workspace survives a round trip through the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/cfg", .{tmp.sub_path});

    const written: File = .{
        .groups = &.{
            .{ .name = "Work", .repos = &.{ "/home/me/dev/a/", "/home/me/dev/b/" } },
            // A path with a quote in it is the one that would break a hand-rolled
            // writer, and paths are user data.
            .{ .name = "Odd \"one\"", .repos = &.{"/home/me/it's here/"} },
        },
        .active_group = 1,
        .active_repo = 0,
    };
    try std.testing.expect(save(gpa, io, dir, written));

    var read = load(gpa, io, dir);
    defer read.deinit();

    try std.testing.expectEqual(@as(usize, 2), read.file.groups.len);
    try std.testing.expectEqualStrings("Work", read.file.groups[0].name);
    try std.testing.expectEqualStrings("/home/me/dev/b/", read.file.groups[0].repos[1]);
    try std.testing.expectEqualStrings("Odd \"one\"", read.file.groups[1].name);
    try std.testing.expectEqualStrings("/home/me/it's here/", read.file.groups[1].repos[0]);
    try std.testing.expectEqual(@as(usize, 1), read.file.active_group);
}

test "a missing or corrupt workspace reads as an empty one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // Nothing written yet.
    var missing = load(gpa, io, dir);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.file.groups.len);

    // Something that is not JSON at all, which is what a hand edit gone wrong
    // leaves behind. It loads as nothing, but it is kept for the next save not
    // to replace with nothing.
    const junk = "{\"groups\": [{\"name\"";
    try tmp.dir.writeFile(io, .{ .sub_path = FILE_NAME, .data = junk });
    var broken = load(gpa, io, dir);
    defer broken.deinit();
    try std.testing.expectEqual(@as(usize, 0), broken.file.groups.len);
    try std.testing.expect(save(gpa, io, dir, .{}));
    var kept_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(junk, try tmp.dir.readFile(io, FILE_NAME ++ ".bak", &kept_buf));
}

test "a workspace from a version that knew more fields still loads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try tmp.dir.writeFile(io, .{
        .sub_path = FILE_NAME,
        .data =
        \\{
        \\  "groups": [{ "name": "Main", "repos": ["/tmp/r/"], "colour": "blue" }],
        \\  "active_group": 0,
        \\  "window_width": 900
        \\}
        ,
    });

    var read = load(gpa, io, dir);
    defer read.deinit();

    try std.testing.expectEqual(@as(usize, 1), read.file.groups.len);
    try std.testing.expectEqualStrings("/tmp/r/", read.file.groups[0].repos[0]);
    // Absent, so it falls back rather than refusing the whole file.
    try std.testing.expectEqual(@as(usize, 0), read.file.active_repo);
}

test "appDir prefers XDG, falls back to HOME, and gives up without either" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), appDir(env, &buf, .config, ""));

    try env.put("HOME", "/home/me");
    try std.testing.expectEqualStrings("/home/me/.config/zit", appDir(env, &buf, .config, "").?);

    try env.put("XDG_CONFIG_HOME", "/xdg");
    try std.testing.expectEqualStrings("/xdg/zit", appDir(env, &buf, .config, "").?);

    // Set but empty is how a shell says "unset" by accident; HOME still wins.
    try env.put("XDG_CONFIG_HOME", "");
    try std.testing.expectEqualStrings("/home/me/.config/zit", appDir(env, &buf, .config, "").?);
    try std.testing.expectEqualStrings("/home/me/.cache/zit/avatars", appDir(env, &buf, .cache, "avatars").?);
}
