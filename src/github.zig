//! GitHub, spoken to directly: Zit's own sign-in (OAuth's device flow: a code
//! to type on github.com, nothing to install) and its own token, then the REST
//! and GraphQL APIs.
//!
//! Every request is `curl`, already what fetches the pictures, so there is no
//! TLS here. The token never reaches a command line: it lives in a file of
//! the user's own (0600) holding the very header line, which curl reads with
//! `-H @file`, and a request's body goes in on standard input.

const std = @import("std");
const builtin = @import("builtin");
const run = @import("run.zig");

/// The OAuth App Zit signs in as (github.com/settings/applications), device
/// flow on. Public by design: the device flow needs no secret.
pub const CLIENT_ID = "Ov23lioNe1gRkBs8j14h";
/// What the token may do: the repositories' pull requests, issues and checks,
/// private ones too; the organisations they are in, to list them.
const SCOPES = "repo read:org";
pub const API = "https://api.github.com";

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
/// `<config>/github-auth`: "Authorization: Bearer <token>". Empty when there
/// is nowhere to keep it.
var auth_path: std.ArrayList(u8) = .empty;
/// `<config>/github-user`: the login it belongs to, for the menus.
var user_path: std.ArrayList(u8) = .empty;

pub fn init(allocator: std.mem.Allocator, the_io: std.Io, config_dir: []const u8) void {
    gpa = allocator;
    io = the_io;
    auth_path.clearRetainingCapacity();
    user_path.clearRetainingCapacity();
    if (config_dir.len == 0) return;
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    auth_path.print(gpa, "{s}" ++ sep ++ "github-auth", .{config_dir}) catch {};
    user_path.print(gpa, "{s}" ++ sep ++ "github-user", .{config_dir}) catch {};
}

pub fn deinit() void {
    auth_path.deinit(gpa);
    auth_path = .empty;
    user_path.deinit(gpa);
    user_path = .empty;
}

/// Whether Zit holds a token.
pub fn signedIn() bool {
    if (auth_path.items.len == 0) return false;
    std.Io.Dir.cwd().access(io, auth_path.items, .{}) catch return false;
    return true;
}

/// The login signed in, into `out`; empty when none.
pub fn login(out: *std.ArrayList(u8)) void {
    out.clearRetainingCapacity();
    if (!signedIn()) return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, user_path.items, gpa, .limited(256)) catch return;
    defer gpa.free(text);
    out.appendSlice(gpa, std.mem.trim(u8, text, " \r\n")) catch {};
}

/// Keep `token`, and the `user` it is: readable by this user alone.
pub fn save(token: []const u8, user: []const u8) !void {
    if (auth_path.items.len == 0) return error.NoConfigDir;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.print(gpa, "Authorization: Bearer {s}\n", .{token});
    try writePrivate(auth_path.items, line.items);
    try writePrivate(user_path.items, user);
}

/// Name the account the kept token is, once GitHub has said — the token as
/// it is.
pub fn saveUser(user: []const u8) !void {
    if (user_path.items.len == 0) return error.NoConfigDir;
    try writePrivate(user_path.items, user);
}

/// Forget the token. GitHub keeps the authorisation until it is revoked in
/// its settings, which needs the app's secret to do from here.
pub fn signOut() void {
    if (auth_path.items.len == 0) return;
    std.Io.Dir.cwd().deleteFile(io, auth_path.items) catch {};
    std.Io.Dir.cwd().deleteFile(io, user_path.items) catch {};
}

fn writePrivate(path: []const u8, bytes: []const u8) !void {
    // Made afresh, so the mode below is the file's: a file that was there
    // keeps whatever it had.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const Perm = std.Io.File.Permissions;
    const private: Perm = if (@hasDecl(Perm, "toMode")) @enumFromInt(0o600) else .default_file;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = private });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

// === Requests ===

/// The `curl` command line for `method` on `url`, with the token's header
/// and, with `body`, the body on standard input. The HTTP status is printed
/// on a last line of its own (`split`). Into `a`.
pub fn argv(a: std.mem.Allocator, method: []const u8, url: []const u8, body: bool) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(a, &.{ "curl", "-sS", "--max-time", "30", "-X", method });
    if (signedIn()) try list.appendSlice(a, &.{ "-H", try std.fmt.allocPrint(a, "@{s}", .{auth_path.items}) });
    try list.appendSlice(a, &.{
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2022-11-28",
        "-H", "User-Agent: Zit",
    });
    if (body) try list.appendSlice(a, &.{ "-H", "Content-Type: application/json", "--data-binary", "@-" });
    try list.appendSlice(a, &.{ "-w", "\n%{http_code}", url });
    return list.toOwnedSlice(a);
}

/// A request off the UI thread: `path` under the API, or a whole URL.
pub fn start(cwd: []const u8, method: []const u8, path: []const u8, body: ?[]const u8) !*run.Capture {
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const url = if (std.mem.startsWith(u8, path, "https://")) path else try std.fmt.allocPrint(a.allocator(), API ++ "{s}", .{path});
    return run.Capture.startInput(gpa, io, cwd, try argv(a.allocator(), method, url, body != null), body);
}

/// A GraphQL query or mutation off the UI thread; `variables` is a JSON
/// object, "{}" for none.
pub fn graphql(cwd: []const u8, query: []const u8, variables: []const u8) !*run.Capture {
    const body = try graphqlBody(gpa, query, variables);
    defer gpa.free(body);
    return start(cwd, "POST", "/graphql", body);
}

pub fn graphqlBody(a: std.mem.Allocator, query: []const u8, variables: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"query\":");
    try jsonString(a, &out, query);
    try out.print(a, ",\"variables\":{s}}}", .{variables});
    return out.toOwnedSlice(a);
}

/// A request run to its end on this thread — for the worker threads that
/// already are off the UI's. The answer's body is owned by the caller.
pub fn call(method: []const u8, path: []const u8, body: ?[]const u8) !Owned {
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const url = if (std.mem.startsWith(u8, path, "https://")) path else try std.fmt.allocPrint(a.allocator(), API ++ "{s}", .{path});
    const got = try run.captureInput(gpa, io, ".", try argv(a.allocator(), method, url, body != null), body, null);
    return .{ .raw = got.out, .ok = got.ok };
}

/// What `call` answered, owning the text `answer` points into.
pub const Owned = struct {
    raw: []u8,
    ok: bool,

    pub fn answer(self: Owned) Answer {
        return if (self.ok) split(self.raw) else .{ .code = 0, .body = "" };
    }

    pub fn deinit(self: Owned) void {
        gpa.free(self.raw);
    }
};

/// An answer: its HTTP status — 0 when there was none, curl having failed —
/// and its body.
pub const Answer = struct {
    code: u16,
    body: []const u8,

    pub fn ok(self: Answer) bool {
        return self.code >= 200 and self.code < 300 and !hasErrors(self.body);
    }
};

/// The body and the status `argv`'s `-w` put on the last line.
pub fn split(out: []const u8) Answer {
    const nl = std.mem.lastIndexOfScalar(u8, out, '\n') orelse
        return .{ .code = std.fmt.parseInt(u16, std.mem.trim(u8, out, " \r\n"), 10) catch 0, .body = "" };
    const code = std.fmt.parseInt(u16, std.mem.trim(u8, out[nl + 1 ..], " \r\n"), 10) catch 0;
    return .{ .code = code, .body = out[0..nl] };
}

/// GraphQL answers 200 with what went wrong in an `errors` list.
fn hasErrors(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"errors\":[") != null;
}

/// What to tell the user about an answer that is not a success, in GitHub's
/// own words where it gave any; into `a`. Null for a success.
pub fn failure(a: std.mem.Allocator, got: Answer) ?[]const u8 {
    if (got.ok()) return null;
    if (got.code == 0) return "No answer from GitHub: offline, or curl is missing.";
    if (got.code == 401) return "GitHub no longer accepts Zit's sign-in: connect again (Settings › GitHub).";
    const said = message(a, got.body);
    if (got.code == 403 or got.code == 429) return std.fmt.allocPrint(a, "GitHub refused: {s}", .{said orelse "rate-limited, or not allowed"}) catch "GitHub refused.";
    if (got.code == 404) return std.fmt.allocPrint(a, "GitHub does not show Zit that repository: {s}", .{said orelse "not found, or the account cannot see it"}) catch "Not found on GitHub.";
    return said orelse (std.fmt.allocPrint(a, "GitHub answered {d}.", .{got.code}) catch "GitHub failed.");
}

/// The `message` of a REST error, or the first of GraphQL's `errors`.
fn message(a: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const Shape = struct {
        message: ?[]const u8 = null,
        errors: ?[]const struct { message: ?[]const u8 = null } = null,
    };
    const got = std.json.parseFromSliceLeaky(Shape, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (got.errors) |es| if (es.len > 0) if (es[0].message) |m| return m;
    return got.message;
}

/// `text` as a JSON string, quotes and all, onto `out`.
pub fn jsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '"');
    for (text) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...0x1f => try out.print(a, "\\u{x:0>4}", .{ch}),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

/// `{"owner":…,"name":…}` for a GraphQL query, from `owner/name`; into `a`.
pub fn repoVars(a: std.mem.Allocator, owner_name: []const u8, extra: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, owner_name, '/') orelse return error.NotASlug;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"owner\":");
    try jsonString(a, &out, owner_name[0..slash]);
    try out.appendSlice(a, ",\"name\":");
    try jsonString(a, &out, owner_name[slash + 1 ..]);
    try out.print(a, "{s}}}", .{extra});
    return out.toOwnedSlice(a);
}

// === Signing in: the device flow ===
//
// Zit asks GitHub for a code, the user types it at github.com/login/device
// and approves, and Zit — asking every few seconds — gets the token.

/// The first step's answer: the code to show, where to type it, and what
/// Zit asks with afterwards.
pub const Device = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32 = 5,
    expires_in: u32 = 900,
};

fn formArgv(a: std.mem.Allocator, url: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ "curl", "-sS", "--max-time", "30", "-X", "POST", "-H", "Accept: application/json", "-H", "User-Agent: Zit", "--data-binary", "@-", url });
}

/// Ask for a code.
pub fn startDevice() !*run.Capture {
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const form = "client_id=" ++ CLIENT_ID ++ "&scope=repo%20read%3Aorg";
    _ = SCOPES;
    return run.Capture.startInput(gpa, io, ".", try formArgv(a.allocator(), "https://github.com/login/device/code"), form);
}

pub fn parseDevice(a: std.mem.Allocator, body: []const u8) !Device {
    return std.json.parseFromSliceLeaky(Device, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Ask whether the code was approved yet.
pub fn pollDevice(device_code: []const u8) !*run.Capture {
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const form = try std.fmt.allocPrint(a.allocator(), "client_id=" ++ CLIENT_ID ++ "&device_code={s}&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code", .{device_code});
    return run.Capture.startInput(gpa, io, ".", try formArgv(a.allocator(), "https://github.com/login/oauth/access_token"), form);
}

/// What a poll said: the token; not yet; slower; or that it is over.
pub const Poll = union(enum) {
    token: []const u8,
    pending,
    slow_down,
    expired,
    denied,
    failed: []const u8,
};

pub fn parsePoll(a: std.mem.Allocator, body: []const u8) Poll {
    const Shape = struct { access_token: ?[]const u8 = null, @"error": ?[]const u8 = null, error_description: ?[]const u8 = null };
    const got = std.json.parseFromSliceLeaky(Shape, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{ .failed = "GitHub's answer could not be read." };
    if (got.access_token) |t| return .{ .token = t };
    const e = got.@"error" orelse return .{ .failed = "GitHub gave no token." };
    if (std.mem.eql(u8, e, "authorization_pending")) return .pending;
    if (std.mem.eql(u8, e, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, e, "expired_token")) return .expired;
    if (std.mem.eql(u8, e, "access_denied")) return .denied;
    return .{ .failed = got.error_description orelse e };
}

// === Tests ===

test "an answer's status, success, and what to say when it is not one" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const good = split("{\"data\":{}}\n200");
    try std.testing.expectEqual(@as(u16, 200), good.code);
    try std.testing.expect(good.ok());
    try std.testing.expect(failure(a.allocator(), good) == null);
    // GraphQL's failures are a 200 with errors in it.
    const gql = split("{\"data\":null,\"errors\":[{\"message\":\"Could not resolve to a Repository\"}]}\n200");
    try std.testing.expect(!gql.ok());
    try std.testing.expectEqualStrings("Could not resolve to a Repository", failure(a.allocator(), gql).?);
    const rest = split("{\"message\":\"Pull Request is not mergeable\"}\n405");
    try std.testing.expectEqualStrings("Pull Request is not mergeable", failure(a.allocator(), rest).?);
    try std.testing.expect(std.mem.indexOf(u8, failure(a.allocator(), split("\n401")).?, "connect again") != null);
    try std.testing.expectEqual(@as(u16, 0), split("").code);
}

test "a GraphQL body carries the query escaped and the variables as they are" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const body = try graphqlBody(a.allocator(), "query{a(\"x\")}", try repoVars(a.allocator(), "o/r", ",\"number\":5"));
    try std.testing.expectEqualStrings("{\"query\":\"query{a(\\\"x\\\")}\",\"variables\":{\"owner\":\"o\",\"name\":\"r\",\"number\":5}}", body);
}

test "the device flow's answers" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const d = try parseDevice(a.allocator(), "{\"device_code\":\"dc\",\"user_code\":\"WDJB-MJHT\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":900,\"interval\":5}");
    try std.testing.expectEqualStrings("WDJB-MJHT", d.user_code);
    try std.testing.expectEqual(@as(u32, 5), d.interval);
    try std.testing.expectEqualStrings("gho_x", parsePoll(a.allocator(), "{\"access_token\":\"gho_x\",\"token_type\":\"bearer\"}").token);
    try std.testing.expectEqual(Poll.pending, parsePoll(a.allocator(), "{\"error\":\"authorization_pending\"}"));
    try std.testing.expectEqual(Poll.denied, parsePoll(a.allocator(), "{\"error\":\"access_denied\"}"));
}

test "the token outlives naming its account" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/cfg", .{tmp.sub_path});
    init(std.testing.allocator, std.testing.io, dir);
    defer deinit();

    try save("ghp_abc", "");
    try saveUser("someone");
    try std.testing.expect(signedIn());

    var buf: [128]u8 = undefined;
    const auth = try std.Io.Dir.cwd().readFile(io, auth_path.items, &buf);
    try std.testing.expectEqualStrings("Authorization: Bearer ghp_abc\n", auth);
    var who: std.ArrayList(u8) = .empty;
    defer who.deinit(gpa);
    login(&who);
    try std.testing.expectEqualStrings("someone", who.items);

    signOut();
    try std.testing.expect(!signedIn());
}
