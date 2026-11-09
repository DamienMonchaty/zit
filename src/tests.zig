const std = @import("std");
const dvui = @import("dvui");
const style = @import("ui/style.zig");
const git = @import("git/git.zig");
const graph = @import("git/graph.zig");
const run = @import("core/run.zig");
const avatars = @import("github/avatar.zig");
const pr = @import("github/pr.zig");
const syntax = @import("ui/syntax.zig");
const watch = @import("git/watch.zig");
const github = @import("github/github.zig");
const tab_strip = @import("ui/tab_strip.zig");
const window_chrome = @import("ui/window_chrome.zig");
const graph_view = @import("ui/graph_view.zig");
const search_view = @import("ui/search_view.zig");
const diff_view = @import("ui/diff_view.zig");
const rebase_view = @import("ui/rebase_view.zig");
const commit_view = @import("ui/commit_view.zig");
const dialog_views = @import("ui/dialog_views.zig");
const identity_view = @import("ui/identity_view.zig");
const repo_settings = @import("ui/repo_settings.zig");
const command_palette = @import("ui/command_palette.zig");
const home_page = @import("ui/home_page.zig");
const repo_io = @import("core/repo_io.zig");
const github_actions = @import("github/github_actions.zig");
const github_connect = @import("github/github_connect.zig");
const pr_list = @import("ui/pr_list.zig");
const pr_conversation = @import("ui/pr_conversation.zig");
const pr_editor = @import("ui/pr_editor.zig");
const pr_create = @import("ui/pr_create.zig");
const app = @import("main.zig");

// === Tests ===

/// `commitMatches` and `commitShown` against the search box as it stands.
fn matchesNow(commit: git.Commit) bool {
    var buf: [graph_view.MAX_TERMS]graph_view.Term = undefined;
    return graph_view.commitMatches(commit, graph_view.parseQuery(app.commit_filter.items, &buf));
}

fn shownNow(commit: git.Commit, index: usize) bool {
    var buf: [graph_view.MAX_TERMS]graph_view.Term = undefined;
    return graph_view.commitShown(commit, index, graph_view.parseQuery(app.commit_filter.items, &buf));
}

test {
    std.testing.refAllDecls(app);
    _ = avatars;
    _ = pr;
    _ = syntax;
    _ = watch;
    _ = github;
}

test "relative times round down to the largest unit that fits" {
    var buf: [32]u8 = undefined;
    // Pinned rather than read from the clock, so the test cannot drift.
    app.frame_now_s = 1_700_000_000;
    const now = app.frame_now_s;

    try std.testing.expectEqualStrings("just now", search_view.relativeTime(&buf, now - 5));
    try std.testing.expectEqualStrings("1 minute ago", search_view.relativeTime(&buf, now - 90));
    try std.testing.expectEqualStrings("2 hours ago", search_view.relativeTime(&buf, now - 7300));
    try std.testing.expectEqualStrings("5 days ago", search_view.relativeTime(&buf, now - 5 * 86400));
    try std.testing.expectEqualStrings("3 weeks ago", search_view.relativeTime(&buf, now - 21 * 86400));
    try std.testing.expectEqualStrings("in the future", search_view.relativeTime(&buf, now + 60));
}

test "only the headline of a git error reaches the toolbar" {
    try std.testing.expectEqualStrings(
        "error: pathspec 'nope' did not match",
        dialog_views.firstLine("error: pathspec 'nope' did not match\nDid you mean...\n"),
    );
    try std.testing.expectEqualStrings("short", dialog_views.firstLine("short"));
}

// The whole layout, rendered once.
//
// Immediate-mode UI fails at runtime, not at compile time — a bad gravity, a
// widget id collision or a deinit in the wrong order all build fine and then
// panic on frame one. This is the smallest thing that catches that.
test "the layout renders a frame" {
    // Needs a video backend; `SDL_VIDEODRIVER=dummy` is enough, and is what CI
    // should set.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    app.gpa = std.testing.allocator;
    // `appInit` normally sets these; this test drives `appFrame` directly.
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    defer {
        app.commit_summary.deinit(app.gpa);
        app.commit_description.deinit(app.gpa);
        app.commit_summary = .empty;
        app.commit_description = .empty;
    }

    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(app.appFrame);
}

// The write path, end to end, against a real repository: every command Zit
// sends is a string, and only running it says whether it means what it looks
// like.
test "stage, commit and switch branches through the real git commands" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    // An identity of its own, so the test does not depend on the config of
    // whoever is running it.
    try expectGit(dir, &.{ "init", "-q", "-b", "main" });
    try expectGit(dir, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(dir, &.{ "config", "user.name", "Zit Test" });
    // Unsigned: the machine running this may sign every commit, and a GPG
    // passphrase prompt per test repo is not a test suite.
    try expectGit(dir, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(dir, &.{ "config", "tag.gpgsign", "false" });

    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "hello.txt", .data = "one\n" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    try std.testing.expect(app.repo != null);
    try std.testing.expectEqual(@as(usize, 1), app.work.?.unstaged.len);
    try std.testing.expectEqual(git.Status.added, app.work.?.unstaged[0].status);

    // Stage.
    github_actions.gitDo(&.{ "add", "-A" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 0), app.work.?.unstaged.len);

    // Unstage, and back again.
    github_actions.gitDo(&.{ "reset", "-q", "--", "." });
    try std.testing.expectEqual(@as(usize, 0), app.work.?.staged.len);
    github_actions.gitDo(&.{ "add", "-A" });
    try std.testing.expectEqual(@as(usize, 1), app.work.?.staged.len);

    // Commit.
    try app.commit_summary.appendSlice(app.gpa, "first commit");
    github_actions.doCommit();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.commits.len);
    try std.testing.expectEqualStrings("first commit", app.history.?.commits[0].summary);
    try std.testing.expectEqual(@as(usize, 0), app.work.?.staged.len);
    // A successful commit clears the box it came from.
    try std.testing.expectEqual(@as(usize, 0), app.commit_summary.items.len);

    // Typed into while the commit ran: the box keeps the new text.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "hello.txt", .data = "two\n" });
    github_actions.gitDo(&.{ "add", "-A" });
    try app.commit_summary.appendSlice(app.gpa, "second commit");
    github_actions.doCommit();
    try app.commit_summary.appendSlice(app.gpa, ", and more");
    try pumpJob();
    try std.testing.expectEqualStrings("second commit", app.history.?.commits[0].summary);
    try std.testing.expectEqualStrings("second commit, and more", app.commit_summary.items);
    app.commit_summary.clearRetainingCapacity();

    // Requesting must not touch the repository: the UI is still iterating the
    // snapshot at that point. This is the use-after-free rule, as a test.
    const before = app.work.?.unstaged.ptr;
    repo_io.request(&.{ "add", "-A" });
    try std.testing.expectEqual(before, app.work.?.unstaged.ptr);
    try std.testing.expect(repo_io.runAction());

    // Switch to a branch whose name would be read as a path by `checkout --`.
    github_actions.gitDo(&.{ "branch", "hello.txt" });
    const branch = findRef("hello.txt") orelse return error.BranchNotListed;
    github_actions.checkout(branch);
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("hello.txt", app.history.?.head.?);
    // The file is still there: this switched branch, it did not restore a path.
    try std.testing.expectEqual(@as(usize, 0), app.work.?.unstaged.len);

    // And back.
    const main_branch = findRef("main") orelse return error.BranchNotListed;
    github_actions.checkout(main_branch);
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try std.testing.expectEqualStrings("main", app.history.?.head.?);
}

/// The UI globals that outlive a test the way they outlive a frame.
///
/// Reset, not merely freed: `deinit` leaves an ArrayList undefined rather than
/// empty, and the next test to render a frame reads straight through it.
fn resetUiGlobals() void {
    tab_strip.zoom = 1.0;
    commit_view.commit_scroll = .{};
    commit_view.clearPickedChanges();
    commit_view.picked_changes.deinit(app.gpa);
    commit_view.picked_changes = .empty;
    commit_view.picked_set.deinit(app.gpa);
    commit_view.picked_set = .empty;
    github_actions.redo_from = null;
    commit_view.clearFoldedDirs();
    commit_view.commit_all_files = false;
    commit_view.changes_scroll = @splat(.{ .vertical = .given });
    commit_view.changes_folded_lists = .{ false, false };
    search_view.branch_width = 0;
    search_view.clearSearchHits();
    search_view.reapSearchFetches(true);
    graph_view.clearGraphPrefs();
    graph_view.hidden_set.deinit(app.gpa);
    graph_view.hidden_set = .empty;
    graph_view.graph_hidden.deinit(app.gpa);
    graph_view.graph_only.deinit(app.gpa);
    graph_view.graph_hidden = .empty;
    graph_view.graph_only = .empty;
    graph_view.graph_pinned.deinit(app.gpa);
    graph_view.graph_pinned = .empty;
    identity_view.settings_open = false;
    identity_view.settings_page = 5;
    identity_view.keys_open = false;
    home_page.features_open = false;
    app.active_view = .graph;
    pr_editor.left_squeezed = false;
    diff_view.section_collapsed = @splat(true);
    forgetTabs();
    tab_strip.groups.deinit(app.gpa);
    tab_strip.groups = .empty;
    tab_strip.workspaces.deinit(app.gpa);
    tab_strip.workspaces = .empty;
    github_connect.ws_name.deinit(app.gpa);
    github_connect.ws_name = .empty;
    github_connect.ws_dialog = null;
    window_chrome.tab_revealed = null;
    tab_strip.config_dir.deinit(app.gpa);
    tab_strip.config_dir = .empty;

    app.commit_filter.deinit(app.gpa);
    app.commit_summary.deinit(app.gpa);
    app.commit_description.deinit(app.gpa);
    app.commit_scope.deinit(app.gpa);
    app.commit_scope = .empty;
    app.commit_template.deinit(app.gpa);
    app.commit_template = .empty;
    commit_view.clearCoAuthors();
    app.co_authors.deinit(app.gpa);
    app.co_authors = .empty;
    app.commit_prefs = .{};
    app.commit_type = null;
    app.template_due = true;
    app.selected_path.deinit(app.gpa);
    app.prompt_text.deinit(app.gpa);
    app.rebase_steps.deinit(app.gpa);
    command_palette.palette_text.deinit(app.gpa);
    command_palette.palette_text = .empty;
    dialog_views.branch_filter.deinit(app.gpa);
    dialog_views.branch_filter = .empty;
    window_chrome.switch_filter.deinit(app.gpa);
    window_chrome.switch_filter = .empty;
    graph_view.author_filter.deinit(app.gpa);
    graph_view.author_filter = .empty;
    graph_view.clearNames(&graph_view.author_only);
    graph_view.author_only.deinit(app.gpa);
    graph_view.author_only = .empty;
    app.freeViews();
    rebase_view.sidebar_filter.deinit(app.gpa);
    tab_strip.default_branch.deinit(app.gpa);
    tab_strip.default_branch = .empty;
    tab_strip.editor_cmd.deinit(app.gpa);
    tab_strip.editor_cmd = .empty;
    tab_strip.terminal_cmd.deinit(app.gpa);
    tab_strip.terminal_cmd = .empty;
    diff_view.clearImagePair();
    identity_view.signing_key.deinit(app.gpa);
    identity_view.signing_key = .empty;
    identity_view.signing_loaded = false;
    if (repo_settings.repo_prefs_job) |j| j.deinit(app.app_io);
    repo_settings.repo_prefs_job = null;
    repo_settings.repo_prefs_loaded = false;
    repo_settings.repo_name_local.deinit(app.gpa);
    repo_settings.repo_name_local = .empty;
    repo_settings.repo_email_local.deinit(app.gpa);
    repo_settings.repo_email_local = .empty;
    repo_settings.repo_settings_path.deinit(app.gpa);
    repo_settings.repo_settings_path = .empty;
    if (repo_settings.editors_job) |j| j.deinit(app.app_io);
    repo_settings.editors_job = null;
    repo_settings.editors_loaded = false;
    if (identity_view.signing_job) |j| j.deinit(app.app_io);
    identity_view.signing_job = null;
    if (commit_view.repo_config_job) |j| j.deinit(app.app_io);
    commit_view.repo_config_job = null;
    commit_view.git_template_path.deinit(app.gpa);
    commit_view.git_template_path = .empty;
    github_actions.commit_sent.deinit(app.gpa);
    github_actions.commit_sent = .empty;
    github_actions.job_after = .remote;
    github_actions.action_after = .remote;
    rebase_view.sidebar_filter = .empty;

    tab_strip.clearRecent();
    tab_strip.recent.deinit(app.gpa);
    tab_strip.recent = .empty;
    pr_create.pick_open = null;
    github_actions.clearJobSteps();
    github_actions.job_steps.deinit(app.gpa);
    github_actions.job_steps = .empty;
    pr_conversation.pr_cards_all = null;
    app.conflict_focus = 0;
    dialog_views.clearForget();
    identity_view.identity_name.deinit(app.gpa);
    identity_view.identity_name = .empty;
    identity_view.identity_email.deinit(app.gpa);
    identity_view.identity_email = .empty;
    identity_view.identity_open = false;
    window_chrome.forgetMe();
    graph_view.clearDrop();
    graph_view.drag_source.deinit(app.gpa);
    graph_view.drag_source = .empty;
    for ([_]*std.ArrayList(u8){ &dialog_views.dialog_url, &dialog_views.dialog_parent, &dialog_views.dialog_name, &dialog_views.dialog_branch }) |list| {
        list.deinit(app.gpa);
        list.* = .empty;
    }
    dialog_views.repo_dialog = .none;
    app.picked_lines.deinit(app.gpa);
    app.picked_lines = .empty;
    pr_list.pr_comment.deinit(app.gpa);
    pr_editor.clearPrEdit();
    pr_create.clearPrCreate();
    pr_list.pr_search.deinit(app.gpa);
    pr_list.pr_search = .empty;
    pr_list.pr_filter = .open;
    pr_list.pr_comment = .empty;
    pr_list.pr_reply.deinit(app.gpa);
    pr_list.pr_reply = .empty;
    pr_list.pr_reply_id.deinit(app.gpa);
    pr_list.pr_reply_id = .empty;
    pr_list.pr_threads_all = false;
    pr_editor.pr_applied_n = 0;
    pr_editor.pr_applied_for = 0;
    pr_editor.pr_scroll_thread = false;
    pr_list.pr_selected = null;
    diff_view.split_rows.deinit(app.gpa);
    diff_view.split_rows = .empty;
    command_palette.palette_open = false;
    graph_view.clearFileHistory();
    graph_view.file_history.deinit(app.gpa);
    github_actions.clone_dest.deinit(app.gpa);

    graph_view.file_history = .empty;
    github_actions.clone_dest = .empty;
    app.commit_filter = .empty;
    app.commit_summary = .empty;
    app.commit_description = .empty;
    app.selected_path = .empty;
    app.prompt_text = .empty;
    app.rebase_steps = .empty;
}

/// Drop the strip without freeing the list itself, which is what a restart does
/// to it — the file on disk is the only thing that survives one.
fn forgetTabs() void {
    for (tab_strip.groups.items) |*group| group.deinit();
    tab_strip.groups.clearRetainingCapacity();
    tab_strip.freeWorkspaces();
    tab_strip.clearRecent();
    tab_strip.active_group = 0;
    tab_strip.active_tab = 0;
}

fn findCommit(summary: []const u8) ?git.Commit {
    const h = app.history orelse return null;
    for (h.commits) |commit| {
        if (std.mem.eql(u8, commit.summary, summary)) return commit;
    }
    return null;
}

fn findRef(name: []const u8) ?git.Ref {
    const h = app.history orelse return null;
    for (h.refs) |ref| {
        if (std.mem.eql(u8, ref.name, name)) return ref;
    }
    return null;
}

fn expectGit(dir: []const u8, args: []const []const u8) !void {
    var outcome = try run.git(std.testing.allocator, app.app_io, dir, args);
    defer outcome.deinit(std.testing.allocator);
    if (!outcome.ok) {
        std.debug.print("git {s} failed: {s}\n", .{ args[0], outcome.message });
        return error.GitFailed;
    }
}

fn expectRun(argv: []const []const u8) !void {
    const answer = try run.capture(std.testing.allocator, app.app_io, ".", argv);
    std.testing.allocator.free(answer.out);
    if (!answer.ok) return error.CommandFailed;
}

/// A repository with one commit and an identity of its own, so a test does not
/// depend on the git config of whoever is running it.
fn makeTestRepo(tmp: *std.testing.TmpDir, dir: []const u8, path: []const u8, data: []const u8) !void {
    try expectGit(dir, &.{ "init", "-q", "-b", "main" });
    try expectGit(dir, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(dir, &.{ "config", "user.name", "Zit Test" });
    // Unsigned: the machine running this may sign every commit, and a GPG
    // passphrase prompt per test repo is not a test suite.
    try expectGit(dir, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(dir, &.{ "config", "tag.gpgsign", "false" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = path, .data = data });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "base" });
}

test "files touched without being changed are hashed once, and the repository's index is never written" {
    app.app_io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var copy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const copy = try std.fmt.bufPrint(&copy_buf, ".zig-cache/tmp/{s}/index", .{scratch.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "two more" });

    // Touched: the same bytes, another time — 2001, well before the index.
    const touched: std.Io.Timestamp = .{ .nanoseconds = 978_307_200 * std.time.ns_per_s };
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        var f = try tmp.dir.openFile(app.app_io, name, .{ .mode = .read_write });
        defer f.close(app.app_io);
        try f.setTimestamps(app.app_io, .{ .access_timestamp = .{ .new = touched }, .modify_timestamp = .{ .new = touched } });
    }
    const index_before = try tmp.dir.readFileAlloc(app.app_io, ".git/index", a, .unlimited);
    defer a.free(index_before);
    const stat_before = try tmp.dir.statFile(app.app_io, ".git/index", .{});

    var cache = try git.StatusCache.open(a, dir, copy);
    defer cache.deinit(a, app.app_io);

    // The first read hashes the three to find them unchanged; the next,
    // none: their new stats are in the copy.
    var first = try cache.readWork(a, app.app_io);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.unstaged.len);
    try std.testing.expectEqual(@as(usize, 3), first.hashed);
    var second = try cache.readWork(a, app.app_io);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), second.unstaged.len);
    try std.testing.expectEqual(@as(usize, 0), second.hashed);

    // The repository's own index is as it was — so a plain read still
    // hashes them all.
    const index_after = try tmp.dir.readFileAlloc(app.app_io, ".git/index", a, .unlimited);
    defer a.free(index_after);
    try std.testing.expectEqualSlices(u8, index_before, index_after);
    try std.testing.expectEqual(stat_before.mtime.nanoseconds, (try tmp.dir.statFile(app.app_io, ".git/index", .{})).mtime.nanoseconds);
    var r = try git.Repo.open(dir);
    defer r.deinit();
    var plain = try r.readWork(a);
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 3), plain.hashed);

    // A change is still one.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b, edited\n" });
    var edited = try cache.readWork(a, app.app_io);
    defer edited.deinit();
    try std.testing.expectEqual(@as(usize, 1), edited.unstaged.len);
    try std.testing.expectEqualStrings("b.txt", edited.unstaged[0].path);

    // The repository's index rewritten by git: the copy taken again.
    try expectGit(dir, &.{ "add", "b.txt" });
    var staged = try cache.readWork(a, app.app_io);
    defer staged.deinit();
    try std.testing.expectEqual(@as(usize, 1), staged.staged.len);
    try std.testing.expectEqual(@as(usize, 0), staged.unstaged.len);
}

// Twelve lines, edited at both ends: far enough apart that git's three lines of
// context do not run the two edits together into one hunk.
const TWELVE_LINES = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";
const TWELVE_EDITED = "one\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\ntwelve\n";
/// What `makeConflictedPair` leaves on main, and so what "keep ours" means.
const TWELVE_LINES_MAIN = "main\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";

// Hunk staging, end to end, against a real repository.
//
// The patch is rebuilt by hand and fed to `git apply` on stdin, so nothing here
// is checked by the compiler: a wrong flag, a dropped header line or a reversed
// direction all produce a patch that builds fine and stages the wrong thing.
test "staging one hunk moves that hunk and leaves the other alone" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "lines.txt", .data = TWELVE_EDITED });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    const r = app.repo orelse return error.RepoNotOpen;

    {
        var unstaged = try r.readWorkDiff(app.gpa, .unstaged, "lines.txt");
        defer unstaged.deinit();
        try std.testing.expectEqual(@as(usize, 1), unstaged.files.len);
        try std.testing.expectEqual(@as(u32, 2), unstaged.files[0].hunk_count);

        rebase_view.requestHunk(unstaged.files[0], 0, .unstaged);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    {
        // One hunk on each side: the one that was staged, and the one that was
        // left behind. Either count being 2 means the patch carried both.
        var staged = try r.readWorkDiff(app.gpa, .staged, "lines.txt");
        defer staged.deinit();
        try std.testing.expectEqual(@as(usize, 1), staged.files.len);
        try std.testing.expectEqual(@as(u32, 1), staged.files[0].hunk_count);

        var rest = try r.readWorkDiff(app.gpa, .unstaged, "lines.txt");
        defer rest.deinit();
        try std.testing.expectEqual(@as(usize, 1), rest.files.len);
        try std.testing.expectEqual(@as(u32, 1), rest.files[0].hunk_count);

        // And back out again. The reverse apply is a different command, and
        // getting its direction wrong stages more rather than less.
        rebase_view.requestHunk(staged.files[0], 0, .staged);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    var empty = try r.readWorkDiff(app.gpa, .staged, "lines.txt");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.files.len);
}

// Rows are positioned by hand inside a scroll area and share widget ids with
// the graph: the kind of thing that builds fine and panics on frame one.
test "the diff pane renders both a file diff and a commit diff" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    try style.applyEmbedded(app.gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "lines.txt", .data = TWELVE_EDITED });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    app.selectChange("lines.txt", .unstaged);
    try dvui.testing.settle(app.appFrame);
    // The pane found its file rather than clearing the selection and falling
    // back to the graph.
    try std.testing.expectEqual(@as(usize, 1), app.diff.?.files.len);

    app.selectCommit(app.history.?.commits[0].id);
    try dvui.testing.settle(app.appFrame);
    try std.testing.expectEqual(@as(usize, 1), app.diff.?.files.len);

    // Closing it puts the graph back.
    app.clearSelection();
    try dvui.testing.settle(app.appFrame);
    try std.testing.expectEqual(@as(?git.Diff, null), app.diff);
}

test "the pull requests open in their tab, and Ctrl+W leaves it, not the repository" {
    defer app.active_view = .graph;
    app.openPulls();
    try std.testing.expect(app.active_view == .pulls);
    github_actions.closeShownTab();
    try std.testing.expect(app.active_view == .graph);
}

test "branches are ticked to show alone one by one, and unticked the same way" {
    app.gpa = std.testing.allocator;
    defer resetUiGlobals();
    graph_view.toggleOnly("a");
    graph_view.toggleOnly("b");
    try std.testing.expectEqual(@as(usize, 2), graph_view.graph_only.items.len);
    graph_view.toggleOnly("a");
    try std.testing.expectEqual(@as(usize, 1), graph_view.graph_only.items.len);
    try std.testing.expectEqualStrings("b", graph_view.graph_only.items[0]);
    graph_view.setSolo(null);
    try std.testing.expectEqual(@as(usize, 0), graph_view.graph_only.items.len);
}

test "the zoom steps a tenth at a time, within its bounds, and Ctrl+0 or the status bar puts it back" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try expectNoTag("status:zoom");

    try pressFrame(.equal, .lcontrol);
    try pressFrame(.kp_add, .lcontrol);
    try std.testing.expectEqual(@as(f32, 1.2), tab_strip.zoom);
    try std.testing.expectEqual(@as(f32, 1.2), dvui.currentWindow().content_scale);
    // Held at the top, whatever is pressed past it.
    for (0..12) |_| try pressFrame(.equal, .lcontrol);
    try std.testing.expectEqual(tab_strip.ZOOM_MAX, tab_strip.zoom);
    try pressFrame(.zero, .lcontrol);
    try std.testing.expectEqual(@as(f32, 1.0), tab_strip.zoom);
    for (0..6) |_| try pressFrame(.minus, .lcontrol);
    try std.testing.expectEqual(tab_strip.ZOOM_MIN, tab_strip.zoom);

    // Off 100 %, the status bar says so, and its click comes back.
    try clickAt(try tagCenter("status:zoom"));
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(f32, 1.0), tab_strip.zoom);
    try expectNoTag("status:zoom");
    // A file edited by hand.
    try std.testing.expectEqual(@as(f32, 1.0), tab_strip.zoomStep(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1.3), tab_strip.zoomStep(1.27));
}

test "down and up walk the history, and the commit pane follows" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(app.gpa, true);
    try git.init();
    defer git.shutdown();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "three" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    app.selectCommit(app.history.?.commits[0].id);
    try dvui.testing.settle(frameArrowCursor);
    try pressFrame(.down, .none);
    try std.testing.expect(git.oidEql(app.selection.commit, app.history.?.commits[1].id));
    try pressFrame(.down, .none);
    try std.testing.expect(git.oidEql(app.selection.commit, app.history.?.commits[2].id));
    try pressFrame(.up, .none);
    try std.testing.expect(git.oidEql(app.selection.commit, app.history.?.commits[1].id));
    // Rewritten under the selection, as a rebase or an amend does: the pane
    // goes back to the working tree rather than a commit with no message.
    app.selectCommit(app.history.?.commits[0].id);
    try expectGit(dir, &.{ "commit", "-q", "--amend", "--allow-empty", "-m", "three, again" });
    repo_io.reloadHistory();
    try std.testing.expect(app.selection == .none);
}

test "a body's trailers come apart from its text, co-authors among them" {
    const body = "Fixes the race.\n\nMore words.\n\nCo-authored-by: Ann Lee <ann@x.invalid>\nSigned-off-by: Bo <bo@x.invalid>";
    const split = commit_view.splitTrailers(body);
    try std.testing.expectEqualStrings("Fixes the race.\n\nMore words.", split.text);
    var it = commit_view.trailerLines(split.trailers);
    const first = it.next().?;
    try std.testing.expectEqualStrings("Co-authored-by", first.key);
    try std.testing.expectEqualStrings("Ann Lee <ann@x.invalid>", first.value);
    try std.testing.expectEqualStrings("Signed-off-by", it.next().?.key);
    try std.testing.expect(it.next() == null);
    // No trailer block: all text.
    try std.testing.expectEqualStrings("Just a line: with a colon in it", commit_view.splitTrailers("Just a line: with a colon in it").text);
}

test "the sidebar filter keeps the names that contain it, whatever their case" {
    app.gpa = std.testing.allocator;
    defer resetUiGlobals();
    try std.testing.expect(rebase_view.sidebarMatches("feat/alpha"));
    try rebase_view.sidebar_filter.appendSlice(app.gpa, " ALP ");
    try std.testing.expect(rebase_view.sidebarFiltering());
    try std.testing.expect(rebase_view.sidebarMatches("feat/alpha"));
    try std.testing.expect(rebase_view.sidebarMatches("origin/feat/Alpha"));
    try std.testing.expect(!rebase_view.sidebarMatches("feat/beta"));
}

test "a narrow list gives up the sha, then the author, before the message" {
    defer app.graph_scroll.viewport.w = 0;
    app.graph_scroll.viewport.w = 2000;
    try std.testing.expect(graph_view.columnsShown().sha and graph_view.columnsShown().author);
    // Room for the message only once the sha is gone.
    app.graph_scroll.viewport.w = 2 * style.space.lg + search_view.graphLead() + graph_view.col_time + graph_view.col_author + 2 * style.space.md + graph_view.MESSAGE_MIN + 10;
    try std.testing.expect(!graph_view.columnsShown().sha and graph_view.columnsShown().author);
    app.graph_scroll.viewport.w = 400;
    try std.testing.expect(!graph_view.columnsShown().sha and !graph_view.columnsShown().author);

    // And a frame that narrow still draws.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(app.gpa, true);
    try git.init();
    defer git.shutdown();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    try dvui.testing.settle(frameArrowCursor);

    // The pull requests' tab beside the repository's draws too.
    app.openPulls();
    try dvui.testing.settle(frameArrowCursor);
    app.closePulls();

    // The floating search closes from its ×, over the rows.
    graph_view.search_open = true;
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("search:close"));
    try std.testing.expect(!graph_view.search_open);
}

test "the branches panel comes back once the changes panel that pushed it out is hidden" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    defer app.show_detail = true;

    try style.applyEmbedded(app.gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // As the changes panel leaves it when dragged wide, then Ctrl+J.
    pr_editor.left_squeezed = true;
    app.show_detail = false;
    try dvui.testing.settle(app.appFrame);
    try std.testing.expect(!pr_editor.left_squeezed);
    try std.testing.expect(pr_editor.leftShown());
}

// The filtered list numbers its own rows on top of a virtualised scroll: easy
// to render beautifully and show the wrong commit.
test "searching the history narrows the list to what matches" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    try style.applyEmbedded(app.gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "teach the parser about tabs" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    const commits = app.history.?.commits;
    try std.testing.expectEqual(@as(usize, 2), commits.len);

    // Nothing typed: the whole history.
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(matchesNow(commits[1]));

    // The message, case-insensitively.
    try app.commit_filter.appendSlice(app.gpa, "PARSER");
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(!matchesNow(commits[1]));

    // The author, which is the other thing people have in hand.
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "zit test");
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(matchesNow(commits[1]));

    // And the start of a sha.
    var sha: [8]u8 = undefined;
    const short = git.oidShort(commits[1].id, &sha);
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, short[0..4]);
    try std.testing.expect(matchesNow(commits[1]));

    // The filtered pane renders: its rows are numbered by position in the
    // results, not by position in the history.
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "tabs");
    try dvui.testing.settle(app.appFrame);

    // A search that finds nothing still leaves the box on screen to clear.
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "nothing here matches this");
    try dvui.testing.settle(app.appFrame);
}

/// A repository stopped in the middle of a conflicted merge: two branches that
/// rewrite the same line, which is the cheapest conflict there is. The merge
/// itself is left to the caller, because it goes through `gitDo`.
fn makeConflictedPair(tmp: *std.testing.TmpDir, dir: []const u8) !void {
    try makeTestRepo(tmp, dir, "lines.txt", TWELVE_LINES);

    try expectGit(dir, &.{ "switch", "-qc", "other" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "lines.txt", .data = "other\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" });
    try expectGit(dir, &.{ "commit", "-qam", "other side" });

    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "lines.txt", .data = "main\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" });
    try expectGit(dir, &.{ "commit", "-qam", "main side" });
}

// The continue button sends `-c core.editor=true`, and that flag is the whole
// reason this test is worth its runtime: without it `git merge --continue`
// opens an editor, and `run.git` blocks the UI thread until something closes
// it — a frozen window with no way back. A test that hangs here has found it.
test "a conflicted merge is resolved and continued" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // Expected to stop. A conflicted merge does not move HEAD, so this also
    // covers `gitDo` re-reading the history on its failure path — without that
    // the toolbar never says it is under way. A stop is not an error: no red line,
    // and the conflicted file is open.
    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(app.selection == .change);
    try std.testing.expectEqualStrings("lines.txt", app.selected_path.items);
    try std.testing.expectEqual(git.State.merge, app.history.?.state);
    try std.testing.expect(dialog_views.conflictCount() > 0);

    // Resolve it the way a person would, then stage the result.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "lines.txt", .data = TWELVE_LINES });
    github_actions.gitDo(&.{ "add", "--", "lines.txt" });
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());

    const cmd = app.history.?.state.command() orelse return error.NoCommandForState;
    github_actions.gitDo(&.{ "-c", "core.editor=true", cmd, "--continue" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, app.history.?.state);

    // The merge commit is there, with both sides under it.
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits[0].parents.len);
}

// The other half of the toolbar's controls. It also pins the libgit2 state
// mapping: a state that came back as `.other` has no `command()`, so they would offer
// nothing and leave the repository stuck mid-merge.
test "a conflicted merge aborts back to a clean tree" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, app.history.?.state);

    const cmd = app.history.?.state.command() orelse return error.NoCommandForState;
    github_actions.gitDo(&.{ cmd, "--abort" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, app.history.?.state);
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());
    try std.testing.expectEqual(@as(usize, 0), app.work.?.unstaged.len);
}

// A merge under way, from the toolbar's end as a person goes at it: Resolve
// opens the conflicted file, Abort asks in a toast — Esc lets it be, its
// button does it.
test "a merge under way is driven from the toolbar, its abort asked in a toast" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    defer github_actions.clearConfirm();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try expectNoTag("op:abort");

    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, app.history.?.state);
    try dvui.testing.settle(frameArrowCursor);
    app.clearSelection();
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("op:resolve"));
    try std.testing.expect(github_connect.viewingConflict());

    try clickAt(try tagCenter("op:abort"));
    try std.testing.expectEqual(app.Confirm.Kind.abort_operation, app.confirm.?.kind);
    _ = try tagRect("confirm:yes");
    try pressFrame(.escape, .none);
    try std.testing.expect(app.confirm == null);
    try expectNoTag("confirm:yes");
    try std.testing.expectEqual(git.State.merge, app.history.?.state);

    try clickAt(try tagCenter("op:abort"));
    try clickAt(try tagCenter("confirm:yes"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, app.history.?.state);
    try expectNoTag("op:abort");
}

// What could quietly break a merge in the middle of resolving it: staging a
// file with its markers still in, an undo that resets under the merge, an
// abort that throws the resolutions away. Each is asked first, or refused.
test "mid-merge, staging markers and aborting are asked first, and undo is refused" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    defer github_actions.clearConfirm();

    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, app.history.?.state);

    // The file still has its markers: staging it, alone or with everything,
    // waits for a yes.
    commit_view.requestStage("lines.txt", "lines.txt", true);
    try std.testing.expect(app.confirm != null and app.confirm.?.kind == .stage_markers);
    try std.testing.expect(dialog_views.conflictCount() > 0);
    github_actions.clearConfirm();
    commit_view.requestStageAll();
    try std.testing.expect(app.confirm != null and app.confirm.?.kind == .stage_markers);
    try std.testing.expectEqualStrings("", app.confirm.?.arg);
    github_actions.clearConfirm();

    // Undo would reset under the merge.
    github_actions.requestUndo();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(@as(repo_io.Action, .none), repo_io.action);
    try std.testing.expectEqual(git.State.merge, app.history.?.state);
    github_actions.clearCommandError();

    // Abort: asked, then done.
    github_actions.requestAbortOperation();
    try std.testing.expect(app.confirm != null and app.confirm.?.kind == .abort_operation);
    try std.testing.expectEqual(git.State.merge, app.history.?.state);
    github_actions.runConfirmed();
    _ = repo_io.runAction();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, app.history.?.state);
}

// "Open this file" sends the user to an editor; a pick made afterwards from
// the copy read before must not write over what they did there.
test "a pick refuses to write over a file changed since it was shown" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    app.selectChange("lines.txt", .unstaged);
    app.loadConflicts();
    try std.testing.expect(app.conflicts.len > 0);

    const edited = "edited elsewhere\n";
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "lines.txt", .data = edited });
    github_actions.requestResolve(0, .ours);
    _ = repo_io.runAction();
    try std.testing.expect(tab_strip.command_error != null);

    const now = try tmp.dir.readFileAlloc(app.app_io, "lines.txt", app.gpa, .limited(1024));
    defer app.gpa.free(now);
    try std.testing.expectEqualStrings(edited, now);
}

// A rebase git refuses to start — here, over uncommitted changes — leaves
// the composed plan on screen, to run again once the tree is clean.
test "a refused interactive rebase keeps its plan" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    const second = findCommit("second") orelse return error.CommitNotFound;
    github_actions.beginRebase(second.parents[0]);
    try std.testing.expectEqual(@as(usize, 1), app.rebase_steps.items.len);

    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    app.rebase_steps.items[0].action = .drop;
    github_actions.runRebase();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(git.State.none, app.history.?.state);
    try std.testing.expect(app.selection == .rebase);
    try std.testing.expectEqual(@as(usize, 1), app.rebase_steps.items.len);
    // git copied its list; Zit's own is gone either way.
    var todo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const todo = try std.fmt.bufPrint(&todo_buf, "{s}zit-rebase-todo", .{app.repo.?.gitdir()});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(app.app_io, todo, .{}));
}

// The strip reads what git keeps for a rebase: the branch, where it goes,
// the step it stopped on and its commit — and the conflict's sides by name,
// "ours" being the base there. Continue goes on from it once resolved.
test "a rebase stopped on a conflict says where it is, and continues" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "f.txt", "base\n");
    try expectGit(dir, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "feat\n" });
    try expectGit(dir, &.{ "commit", "-qam", "feat changes f" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "g.txt", .data = "g\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "feat adds g" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "main\n" });
    try expectGit(dir, &.{ "commit", "-qam", "main changes f" });
    try expectGit(dir, &.{ "switch", "-q", "feat" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "rebase", "main" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.rebase, app.history.?.state);
    try std.testing.expectEqualStrings("feat", rebase_view.op_info.branch);
    try std.testing.expectEqualStrings("main", rebase_view.op_info.onto);
    try std.testing.expectEqual(@as(u32, 1), rebase_view.op_info.step);
    try std.testing.expectEqual(@as(u32, 2), rebase_view.op_info.total);
    try std.testing.expectEqualStrings("feat changes f", rebase_view.op_info.subject);
    var title_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Rebasing feat onto main", github_connect.opTitle(&title_buf));
    try std.testing.expectEqualStrings("main", rebase_view.sideNames().ours);
    try std.testing.expectEqualStrings("feat", rebase_view.sideNames().theirs);
    try std.testing.expect(std.mem.indexOf(u8, rebase_view.sideNames().theirs_role, rebase_view.op_info.commit) != null);
    try std.testing.expect(github_connect.opNext() == .resolve);
    try std.testing.expect(!github_connect.canContinue());

    // Answered and staged: Continue, which replays the second commit too.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "both\n" });
    github_actions.gitDo(&.{ "add", "--", "f.txt" });
    try std.testing.expect(github_connect.opNext() == .proceed);
    try std.testing.expect(github_connect.canContinue());
    github_connect.requestContinue();
    _ = repo_io.runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, app.history.?.state);
    try std.testing.expectEqualStrings("feat adds g", app.history.?.commits[0].summary);
    try std.testing.expectEqualStrings("feat changes f", app.history.?.commits[1].summary);
    try std.testing.expectEqualStrings("main changes f", app.history.?.commits[2].summary);
}

// Resolved to what the base already had, a commit is left with nothing to
// apply: git refuses to continue with it, and the strip offers Skip instead.
test "a rebase step left empty by its resolution is skipped, not continued" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "f.txt", "base\n");
    try expectGit(dir, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "feat\n" });
    try expectGit(dir, &.{ "commit", "-qam", "feat changes f" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "main\n" });
    try expectGit(dir, &.{ "commit", "-qam", "main changes f" });
    try expectGit(dir, &.{ "switch", "-q", "feat" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "rebase", "main" });
    try std.testing.expectEqual(git.State.rebase, app.history.?.state);
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "main\n" });
    github_actions.gitDo(&.{ "add", "--", "f.txt" });
    try std.testing.expect(github_connect.opNext() == .skip);
    try std.testing.expect(!github_connect.canContinue());
}

// After a rebase the branch and its upstream have parted ways: Push turns
// into a force push, which says what it replaces.
/// A bare remote and a clone of it, the clone's `main` pushed: for the
/// pull request flows, which fetch and push.
fn makeRemotePair(tmp: *std.testing.TmpDir, root: []const u8, up: []const u8, down: []const u8) !void {
    try expectGit(root, &.{ "init", "-q", "--bare", "-b", "main", "up.git" });
    try tmp.dir.createDirPath(app.app_io, "down");
    try makeTestRepo(tmp, down, "down/f.txt", "base\n");
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "main" });
}

// Checking a request out as `gh pr checkout` does: a branch that tracks the
// remote's, made — or switched to and fast-forwarded when it is behind —
// and a fork's request on `pr/N`, never on a branch of yours of its name.
test "a pull request is checked out tracking its branch, brought up to date, and a fork's apart" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up.git", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeRemotePair(&tmp, root, up, down);
    try expectGit(down, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "down/g.txt", .data = "one\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "feat one" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "down/g.txt", .data = "two\n" });
    try expectGit(down, &.{ "commit", "-qam", "feat two" });
    try expectGit(down, &.{ "push", "-q", "origin", "feat" });
    // The request as a fork would send it: only under refs/pull.
    try expectGit(up, &.{ "update-ref", "refs/pull/7/head", "refs/heads/feat" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    try expectGit(down, &.{ "branch", "-qD", "feat" });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // Not here yet: made, tracking the remote's.
    github_actions.checkoutRequest(3, "feat", false);
    _ = repo_io.runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("feat", app.history.?.head.?);
    try std.testing.expectEqualStrings("origin/feat", app.history.?.tracking.upstream.?);

    // Here but behind: switched to, and brought up to date.
    try expectGit(down, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    repo_io.reloadHistory();
    github_actions.checkoutRequest(3, "feat", false);
    _ = repo_io.runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("feat", app.history.?.head.?);
    try std.testing.expectEqualStrings("feat two", app.history.?.commits[0].summary);

    // From a fork, its branch named "main": on pr/7, and main left alone.
    try expectGit(down, &.{ "switch", "-q", "main" });
    repo_io.reloadHistory();
    github_actions.checkoutRequest(7, "main", true);
    _ = repo_io.runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("pr/7", app.history.?.head.?);
    try std.testing.expectEqualStrings("feat two", app.history.?.commits[0].summary);
    try std.testing.expect(github_actions.isLocalBranch("main"));
}

// A request in conflict with its base, rebased onto it here: fetched,
// checked out, rebased — stopping at the conflict, in the conflict view,
// with the bar to go on from.
test "a pull request in conflict is rebased onto its base here, stopping at the conflict" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up.git", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeRemotePair(&tmp, root, up, down);
    try expectGit(down, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "down/f.txt", .data = "feat\n" });
    try expectGit(down, &.{ "commit", "-qam", "feat changes f" });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "feat" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "down/f.txt", .data = "main\n" });
    try expectGit(down, &.{ "commit", "-qam", "main changes f" });
    try expectGit(down, &.{ "push", "-q", "origin", "main" });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.resolveRequestLocally(.{ .number = 3, .head = "feat", .base = "main", .mergeable = "CONFLICTING" }, true);
    _ = repo_io.runAction();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.rebase, app.history.?.state);
    try std.testing.expect(dialog_views.conflictCount() > 0);
    try std.testing.expectEqualStrings("feat", rebase_view.op_info.branch);
    try std.testing.expectEqualStrings("f.txt", app.selected_path.items);
}

test "after a rebase, Push is a force push that says what it replaces" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up.git", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();

    try expectGit(root, &.{ "init", "-q", "--bare", "-b", "main", "up.git" });
    try tmp.dir.createDirPath(app.app_io, "down");
    try makeTestRepo(&tmp, down, "down/a.txt", "a\n");
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "main" });
    try expectGit(down, &.{ "switch", "-qc", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "down/f.txt", .data = "f\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "feat" });
    try expectGit(down, &.{ "push", "-q", "-u", "origin", "feat" });
    try expectGit(down, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "down/b.txt", .data = "b\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "main moves" });
    try expectGit(down, &.{ "switch", "-q", "feat" });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    try std.testing.expect(!window_chrome.rebasedSinceUpstream());

    github_actions.gitDo(&.{ "rebase", "main" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(window_chrome.rebasedSinceUpstream());
    var buf: [512]u8 = undefined;
    const text = dialog_views.forcePushText(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "origin/feat") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 commit there") != null);
}

// The conflict view driven by the keys alone, as GitComet's is: 2 keeps the
// right side, U takes it back, 1 keeps the left, Enter stages the file.
test "a conflicted file is answered from the keys: a pick, its undo, Enter to stage" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(app.gpa, true);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(rebase_view.isConflictView());
    try std.testing.expectEqual(@as(usize, 1), app.conflicts.len);

    try pressFrame(.two, .none);
    try std.testing.expectEqual(@as(usize, 0), app.conflicts.len);
    try std.testing.expectEqual(@as(usize, 1), app.resolve_undo.items.len);
    {
        const now = try tmp.dir.readFileAlloc(app.app_io, "lines.txt", app.gpa, .limited(4096));
        defer app.gpa.free(now);
        try std.testing.expect(std.mem.startsWith(u8, now, "other"));
    }

    try pressFrame(.u, .none);
    try std.testing.expectEqual(@as(usize, 1), app.conflicts.len);
    try std.testing.expectEqual(@as(usize, 0), app.resolve_undo.items.len);

    try pressFrame(.one, .none);
    try std.testing.expectEqual(@as(usize, 0), app.conflicts.len);
    try pressFrame(.enter, .none);
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());
    try std.testing.expectEqual(git.State.merge, app.history.?.state);
    const now = try tmp.dir.readFileAlloc(app.app_io, "lines.txt", app.gpa, .limited(4096));
    defer app.gpa.free(now);
    try std.testing.expect(std.mem.startsWith(u8, now, "main"));
}

// git wrote plain markers, as it does by default: the base comes from the
// index, and a conflict where each side changed different lines resolves
// in one click, each line from the side that changed it.
test "a conflict of changes on neighbouring lines is resolved safely, with its base" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "n.txt", "a = 1\nb = 2\nc = 3\n");
    try expectGit(dir, &.{ "switch", "-qc", "other" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "n.txt", .data = "a = 1\nb = 20\nc = 3\n" });
    try expectGit(dir, &.{ "commit", "-qam", "b" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "n.txt", .data = "a = 10\nb = 2\nc = 30\n" });
    try expectGit(dir, &.{ "commit", "-qam", "a and c" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "-c", "merge.conflictStyle=merge", "merge", "--no-edit", "other" });
    try std.testing.expectEqualStrings("n.txt", app.selected_path.items);
    app.loadConflicts();
    try std.testing.expectEqual(@as(usize, 1), app.conflicts.len);
    try std.testing.expect(app.conflicts[0].has_base);
    try std.testing.expect(git.sameText("a = 1\nb = 2\nc = 3\n", app.conflicts[0].base));
    try std.testing.expectEqual(@as(?git.AutoReason, .lines_apart), app.conflict_autos[0]);

    repo_io.requestAction(.resolve_safe);
    _ = repo_io.runAction();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    const now = try tmp.dir.readFileAlloc(app.app_io, "n.txt", app.gpa, .limited(4096));
    defer app.gpa.free(now);
    try std.testing.expect(git.sameText("a = 10\nb = 20\nc = 30\n", now));
}

// A file one side deleted and the other changed: no regions, a question —
// keep it or let it go — answered and staged in one click.
test "a file deleted on one side is kept or deleted in one click" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "notes.txt", "notes\n");
    try expectGit(dir, &.{ "switch", "-qc", "other" });
    try expectGit(dir, &.{ "rm", "-q", "notes.txt" });
    try expectGit(dir, &.{ "commit", "-qm", "no notes" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "notes.txt", .data = "notes, edited\n" });
    try expectGit(dir, &.{ "commit", "-qam", "edited notes" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqualStrings("notes.txt", app.selected_path.items);
    app.loadConflicts();
    try std.testing.expectEqual(git.ConflictKind.deleted_by_them, app.conflict_kind);
    try std.testing.expect(app.wholeFileConflict());

    // "Delete it": the side that deleted it.
    rebase_view.takeFile(.theirs);
    _ = repo_io.runAction();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(app.app_io, "notes.txt", .{}));
}

test "a review written for one pull request is not carried to another" {
    app.gpa = std.testing.allocator;
    defer pr_list.pr_comment.clearAndFree(app.gpa);
    defer pr_list.pr_selected = null;
    pr_list.pr_selected = 5;
    try pr_list.pr_comment.appendSlice(app.gpa, "looks good");
    pr_list.selectRequest(5);
    try std.testing.expectEqualStrings("looks good", pr_list.pr_comment.items);
    pr_list.selectRequest(7);
    try std.testing.expectEqual(@as(usize, 0), pr_list.pr_comment.items.len);
}

// The parser is unit-tested in `git.zig`; what this covers is the rest of the
// loop — reading the file git left behind, writing the chosen side back, and
// git agreeing afterwards that there is nothing left to resolve.
test "a conflict is resolved region by region, then staged" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, app.history.?.state);

    app.selectChange("lines.txt", .unstaged);
    app.ensureDiff();
    try std.testing.expect(rebase_view.isConflictView());
    try std.testing.expectEqual(@as(usize, 1), app.conflicts.len);
    try std.testing.expectEqualStrings("main\n", app.conflicts[0].ours);
    try std.testing.expectEqualStrings("other\n", app.conflicts[0].theirs);

    github_actions.requestResolve(0, .ours);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    // Our side is what landed, and no marker survived it.
    const resolved = try tmp.dir.readFileAlloc(app.app_io, "lines.txt", app.gpa, .limited(64 * 1024));
    defer app.gpa.free(resolved);
    try std.testing.expectEqualStrings(TWELVE_LINES_MAIN, resolved);

    app.diff_stale = true;
    app.ensureDiff();
    try std.testing.expectEqual(@as(usize, 0), app.conflicts.len);

    // Staging is what tells git the conflict is over; until then it is still
    // mid-merge no matter how clean the file looks.
    github_actions.gitDo(&.{ "add", "--", "lines.txt" });
    try std.testing.expectEqual(@as(usize, 0), dialog_views.conflictCount());

    github_actions.gitDo(&.{ "-c", "core.editor=true", "merge", "--continue" });
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, app.history.?.state);
}

// The mechanism is a config trick — `sequence.editor=cp <our todo>` — and
// nothing about it is checked by the compiler. If git ignored it, or the todo
// were written in the wrong order, the rebase would still "succeed" and quietly
// do something other than what was composed.
test "an interactive rebase folds one commit into the one before it" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "third" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    try std.testing.expectEqual(@as(usize, 3), app.history.?.commits.len);

    // Starting at "second" means "second" and "third" are both replayed, so the
    // list is composed from its parent.
    const second = findCommit("second") orelse return error.CommitNotFound;
    github_actions.beginRebase(if (second.parents.len > 0) second.parents[0] else null);
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 2), app.rebase_steps.items.len);

    // Newest first, the order the graph shows — the todo gets reversed.
    try std.testing.expectEqualStrings("third", app.rebase_steps.items[0].summary);
    try std.testing.expectEqualStrings("second", app.rebase_steps.items[1].summary);

    app.rebase_steps.items[0].action = .fixup;
    github_actions.runRebase();

    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(git.State.none, app.history.?.state);
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits.len);
    try std.testing.expectEqualStrings("second", app.history.?.commits[0].summary);

    // Folded, not dropped: the surviving commit carries what "third" added.
    var folded = try app.repo.?.readCommitDiff(app.gpa, app.history.?.commits[0].id);
    defer folded.deinit();
    try std.testing.expect(folded.find("b.txt") != null);
    try std.testing.expect(folded.find("c.txt") != null);

    // Composing is over once it runs.
    try std.testing.expectEqual(@as(usize, 0), app.rebase_steps.items.len);
}

test "a rebase onto a commit off the current branch is refused, not attempted" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // "other side" is on the other branch: walking first parents from HEAD
    // never reaches it, and replaying onto it is a different operation.
    const other = findCommit("other side") orelse return error.CommitNotFound;
    github_actions.beginRebase(other.id);

    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(@as(usize, 0), app.rebase_steps.items.len);
    try std.testing.expectEqual(app.Selection.none, std.meta.activeTag(app.selection));

    // A merge in the range: git would stop on its `pick`, so the list is
    // never composed.
    try expectGit(dir, &.{ "merge", "-q", "-s", "ours", "-m", "merged", "other" });
    graph_view.refreshHistory();
    github_actions.clearCommandError();
    const main_side = findCommit("main side") orelse return error.CommitNotFound;
    github_actions.beginRebase(main_side.parents[0]);
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(@as(usize, 0), app.rebase_steps.items.len);
    try std.testing.expectEqual(app.Selection.none, std.meta.activeTag(app.selection));
}

test "a branch named like a tag merges the branch, not the tag" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "tag", "v1" });
    try expectGit(dir, &.{ "switch", "-q", "-c", "v1" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on the branch" });
    try expectGit(dir, &.{ "switch", "-q", "main" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // Bare where nothing else shares the name, so merge messages read as usual.
    var ref_buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("main", graph_view.refArg(&ref_buf, "main", .local));

    repo_io.request(&.{ "merge", "--no-edit", "--no-ff", graph_view.refArg(&ref_buf, "v1", .local) });
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits[0].parents.len);
}

test "blame names the author of each line" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "lines.txt", "one\ntwo\n");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    app.selectBlame("lines.txt");
    app.ensureDiff();

    const b = app.blame_view orelse return error.NoBlame;
    // Two lines, not three: the trailing newline is not a line.
    try std.testing.expectEqual(@as(usize, 2), b.lines.len);
    try std.testing.expectEqualStrings("one", b.lines[0].text);
    try std.testing.expectEqualStrings("two", b.lines[1].text);
    try std.testing.expectEqualStrings("Zit Test", b.lines[0].author);
    try std.testing.expect(b.lines[0].time > 0);

    // An edit not committed yet belongs to nobody, whoever wrote the line it
    // replaced.
    var edited = try app.repo.?.readBlame(app.gpa, "lines.txt", "one\nTWO\n");
    defer edited.deinit();
    try std.testing.expect(edited.lines[0].time > 0);
    try std.testing.expectEqual(@as(i64, 0), edited.lines[1].time);
    try std.testing.expectEqualStrings("", edited.lines[1].author);

    // Emptied and not committed: nothing to blame, not a line from HEAD.
    var emptied = try app.repo.?.readBlame(app.gpa, "lines.txt", "");
    defer emptied.deinit();
    try std.testing.expectEqual(@as(usize, 0), emptied.lines.len);

    // Commits made on a detached HEAD are on no branch, and still on the graph.
    try expectGit(dir, &.{ "switch", "-q", "--detach" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "adrift" });
    graph_view.refreshHistory();
    try std.testing.expect(findCommit("adrift") != null);
}

test "a hard reset waits for the confirmation" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();

    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    defer github_actions.clearConfirm();
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits.len);

    const base = findCommit("base") orelse return error.CommitNotFound;
    var sha_buf: [8]u8 = undefined;
    github_actions.ask(.reset_hard, git.oidShort(base.id, &sha_buf));

    // Asking must not do it.
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits.len);

    github_actions.runConfirmed();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.commits.len);
    // Answered once, and gone.
    try std.testing.expect(app.confirm == null);
}

test "the new branch dialog creates a branch, and stays open when the name is taken" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    defer github_actions.clearPrompt();

    github_actions.askName(.new_branch, "");
    try app.prompt_text.appendSlice(app.gpa, "feature");
    github_actions.runPrompt();

    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("feature") != null);
    // A create that worked closes the dialog.
    try std.testing.expect(app.prompt == null);

    // The same name again fails, and the dialog stays up with the text in it so
    // the name can be fixed rather than retyped.
    github_actions.askName(.new_branch, "");
    try app.prompt_text.appendSlice(app.gpa, "feature");
    github_actions.runPrompt();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expect(app.prompt != null);

    // A dash would make it an option: `--force`, `-D`. Refused before git
    // sees it, with the dialog still open.
    github_actions.clearCommandError();
    github_actions.askName(.new_branch, "");
    try app.prompt_text.appendSlice(app.gpa, "-D");
    github_actions.runPrompt();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expect(app.prompt != null);
    try std.testing.expect(findRef("-D") == null);

    // On screen: a dialog over the window, typed into at once — Enter makes
    // the branch — and Esc lets it be.
    github_actions.clearCommandError();
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    github_actions.askName(.new_branch, "");
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagRect("prompt:go");
    try typeText("typed");
    try pressFrame(.enter, .none);
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("typed") != null);
    try std.testing.expect(app.prompt == null);
    github_actions.askName(.new_tag, "");
    try dvui.testing.settle(frameArrowCursor);
    try pressFrame(.escape, .none);
    try std.testing.expect(app.prompt == null);
    try expectNoTag("prompt:go");
}

// Rows are positioned by hand inside scroll areas and share widget ids with
// the graph: the kind of thing that builds fine and panics on frame one.
test "the conflict, rebase and blame panes each render a frame" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();

    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    try style.applyEmbedded(app.gpa, true);
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeConflictedPair(&tmp, dir);

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // Conflicts, the toolbar saying so.
    github_actions.gitDo(&.{ "merge", "--no-edit", "other" });
    try std.testing.expectEqual(git.State.merge, app.history.?.state);
    app.selectChange("lines.txt", .unstaged);
    try dvui.testing.settle(app.appFrame);
    try std.testing.expect(rebase_view.isConflictView());
    try std.testing.expectEqual(@as(usize, 1), app.conflicts.len);

    github_actions.gitDo(&.{ "merge", "--abort" });
    app.clearSelection();

    // The rebase composer.
    const head = app.history.?.commits[0];
    github_actions.beginRebase(if (head.parents.len > 0) head.parents[0] else null);
    try std.testing.expectEqual(app.Selection.rebase, std.meta.activeTag(app.selection));
    try dvui.testing.settle(app.appFrame);
    try std.testing.expectEqual(@as(usize, 1), app.rebase_steps.items.len);

    app.clearSelection();

    app.selectBlame("lines.txt");
    try dvui.testing.settle(app.appFrame);
    try std.testing.expect(app.blame_view != null);

    // And back to the graph.
    app.clearSelection();
    try dvui.testing.settle(app.appFrame);
    try std.testing.expect(app.blame_view == null);
}

test "LFS is offered only where the repository actually uses it" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // No `.gitattributes` at all, which is most repositories.
    try std.testing.expect(!tab_strip.uses_lfs);

    // One that mentions another filter is still not an LFS repository.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = ".gitattributes", .data = "*.txt text\n" });
    app.openRepo(dir);
    try std.testing.expect(!tab_strip.uses_lfs);

    try tmp.dir.writeFile(app.app_io, .{
        .sub_path = ".gitattributes",
        .data = "*.psd filter=lfs diff=lfs merge=lfs -text\n",
    });
    app.openRepo(dir);
    try std.testing.expect(tab_strip.uses_lfs);
}

/// Two repositories, the second with the first as its `origin`.
///
/// A path is a remote as far as git is concerned, which is what makes the
/// networked path testable without a network.
fn makeUpstreamPair(tmp: *std.testing.TmpDir, root: []const u8, up: []const u8, down: []const u8) !void {
    try expectGit(root, &.{ "init", "-q", "-b", "main", "up" });
    try expectGit(up, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(up, &.{ "config", "user.name", "Zit Test" });
    // Unsigned: the machine running this may sign every commit, and a GPG
    // passphrase prompt per test repo is not a test suite.
    try expectGit(up, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(up, &.{ "config", "tag.gpgsign", "false" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "up/a.txt", .data = "a\n" });
    try expectGit(up, &.{ "add", "-A" });
    try expectGit(up, &.{ "commit", "-qm", "upstream commit" });

    try expectGit(root, &.{ "init", "-q", "-b", "main", "down" });
    try expectGit(down, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(down, &.{ "config", "user.name", "Zit Test" });
    // Unsigned, as above.
    try expectGit(down, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(down, &.{ "config", "tag.gpgsign", "false" });
}

/// Absolute path of `rel`, which is what a remote URL has to be: git resolves
/// it from inside the repository, not from where the test is running.
fn absPath(buf: []u8, rel: []const u8) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(app.app_io, &cwd_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ cwd_buf[0..len], rel });
}

/// Let a job land, the way a frame would.
fn pumpJob() !void {
    var waited: usize = 0;
    while (tab_strip.job != null and waited < 1000) : (waited += 1) {
        github_actions.collectJob();
        if (tab_strip.job != null) try std.Io.sleep(app.app_io, .fromMilliseconds(10), .awake);
    }
    if (tab_strip.job != null) return error.JobNeverFinished;
}

/// As `pumpJob`, then the frames after it: what the job changed is on screen,
/// and its tags with it, before the next click looks for them. Without them
/// the click aims at the last frame drawn, which may be from while it ran.
fn pumpJobFrame() !void {
    try pumpJob();
    try dvui.testing.settle(frameArrowCursor);
}

// Nothing about the threading is checked by the compiler: a job that never
// completes, or one whose result is never folded in, looks exactly like one
// that worked until you notice the refs did not move.
test "a networked command runs off the UI thread and folds its result in" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    repo_io.requestNetwork("Fetching", &.{ "fetch", "origin" });
    try std.testing.expect(repo_io.runAction());

    const started = tab_strip.job orelse return error.NoJobStarted;
    // Ran inline on this thread instead: every fetch would freeze the window.
    try std.testing.expect(!started.inline_run);

    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    // The result was folded in, not merely awaited: the snapshot has the ref.
    try std.testing.expect(findRef("origin/main") != null);
    // And the remote shows up where the sidebar reads it from.
    try std.testing.expectEqual(@as(usize, 1), app.history.?.remotes.len);
}

// The counts on Pull and Push. They come from libgit2, not a command, so
// nothing else in the suite would notice them going wrong.
test "the branch knows how far it is from its upstream" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "-B", "main", "origin/main" });
    try expectGit(down, &.{ "branch", "--set-upstream-to=origin/main", "main" });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // Level with the upstream: both buttons carry no count.
    try std.testing.expectEqual(@as(usize, 0), app.history.?.tracking.ahead);
    try std.testing.expectEqual(@as(usize, 0), app.history.?.tracking.behind);
    try std.testing.expectEqualStrings("origin/main", app.history.?.tracking.upstream.?);

    // One commit here and nowhere else is one commit to push.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "down/b.txt", .data = "b\n" });
    try expectGit(down, &.{ "add", "-A" });
    try expectGit(down, &.{ "commit", "-qm", "local work" });
    repo_io.reloadHistory();

    try std.testing.expectEqual(@as(usize, 1), app.history.?.tracking.ahead);
    try std.testing.expectEqual(@as(usize, 0), app.history.?.tracking.behind);

    // A branch with no upstream at all says nothing rather than guessing.
    try expectGit(down, &.{ "checkout", "-q", "-b", "solo" });
    repo_io.reloadHistory();
    try std.testing.expectEqual(@as(?[]const u8, null), app.history.?.tracking.upstream);
    try std.testing.expectEqual(@as(usize, 0), app.history.?.tracking.ahead);
}

// The argv a caller hands to a job points into a snapshot that the poll timer
// is free to throw away a fraction of a second later. If the job did not copy
// it, this is the test that finds out — and the symptom in the app would be a
// fetch of a remote whose name had turned to garbage.
test "a job keeps its own copy of the command it was handed" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });

    // Heap-allocated, so the allocator can hand the bytes straight back out.
    const name = try app.gpa.dupe(u8, "origin");
    const cwd = try app.gpa.dupe(u8, down);

    var running = try run.Job.start(app.gpa, app.app_io, cwd, &.{ "fetch", name }, .{});

    // Gone before the command can have finished — exactly what a snapshot
    // refresh does to an argv still in flight.
    @memset(name, 'x');
    @memset(cwd, 'x');
    app.gpa.free(name);
    app.gpa.free(cwd);

    var waited: usize = 0;
    while (!running.finished() and waited < 1000) : (waited += 1) {
        try std.Io.sleep(app.app_io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(running.finished());

    var outcome = running.finish(app.gpa, app.app_io) orelse return error.GitNeverRan;
    defer outcome.deinit(app.gpa);

    // It fetched "origin" from the right directory, not "xxxxxx" from nowhere.
    try std.testing.expect(outcome.ok);
}

test "a command that lands after the repository changed is discarded, not reported" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    // No remote called "origin", so the fetch is going to fail — which is what
    // makes it visible whether the failure gets reported.
    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    repo_io.requestNetwork("Fetching", &.{ "fetch", "origin" });
    try std.testing.expect(repo_io.runAction());
    try std.testing.expect(tab_strip.job != null);

    // Away before it lands.
    dialog_views.closeRepo();
    try pumpJob();

    // The failure belonged to a repository nobody is looking at any more.
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
}

/// A config directory of its own, under the test's temporary directory.
///
/// Without this every one of these tests would write the real workspace file,
/// and running the suite would rearrange the tabs of whoever ran it.
fn useTestConfig(root: []const u8) !void {
    try tab_strip.config_dir.appendSlice(app.gpa, root);
    try tab_strip.config_dir.appendSlice(app.gpa, "/cfg");
}

test "the tab strip comes back after a restart" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });

    // A first run, with nothing to restore.
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.activeGroup().?.tabs.items.len);

    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);

    // The restart: everything in memory goes, and only the file is left.
    dialog_views.closeRepo();
    forgetTabs();
    tab_strip.loadWorkspace();

    const group = tab_strip.activeGroup() orelse return error.NoGroup;
    try std.testing.expectEqual(@as(usize, 2), group.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);
    // Stored as the working directory libgit2 resolved, not as the relative
    // path they were opened with.
    try std.testing.expect(std.mem.endsWith(u8, group.tabs.items[0].path, "/a/"));
    try std.testing.expect(std.mem.endsWith(u8, group.tabs.items[1].path, "/b/"));

    // And the one that was in front opens again.
    tab_strip.restoreActiveTab();
    try std.testing.expect(app.repo != null);
    try std.testing.expectEqualStrings("b", app.repo_name);

    // And the strip that shows them draws, both tabs in it.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(app.appFrame);
}

test "the same repository opened from inside itself reuses its tab" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try tmp.dir.createDirPath(app.app_io, "a/deep/inside");

    var deep_buf: [std.fs.max_path_bytes]u8 = undefined;
    const deep = try std.fmt.bufPrint(&deep_buf, "{s}/a/deep/inside", .{root});

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(deep);

    // One repository, one tab: libgit2 searched upward and resolved both to the
    // same working directory, which is what the tab is keyed on.
    try std.testing.expectEqual(@as(usize, 1), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_tab);
}

test "closing a tab falls onto its neighbour, and closing the last leaves nothing open" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    var buf_c: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    const b = try std.fmt.bufPrint(&buf_b, "{s}/b", .{root});
    const c = try std.fmt.bufPrint(&buf_c, "{s}/c", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "c" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    tab_strip.openAndRemember(c);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.active_tab);

    // Picking a folder that is no repository leaves the open one open.
    var buf_none: [std.fs.max_path_bytes]u8 = undefined;
    tab_strip.openAndRemember(try std.fmt.bufPrint(&buf_none, "{s}/none", .{root}));
    try std.testing.expectEqualStrings("c", app.repo_name);
    try std.testing.expect(tab_strip.command_error != null);
    github_actions.clearCommandError();

    // Amend ticked here, or a branch dropped on another, does not follow
    // onto the next tab.
    app.amend = true;
    defer app.amend = false;
    graph_view.setDrop("feat", "main");

    // Close the one in front: the neighbour takes over, and opens.
    tab_strip.closeTab(2);
    try std.testing.expect(!app.amend);
    try std.testing.expect(graph_view.drop == null);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);
    try std.testing.expectEqualStrings("b", app.repo_name);

    // Closing one to the left of where you are looking must leave you looking
    // at the same repository, at its new index.
    tab_strip.closeTab(0);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_tab);
    try std.testing.expectEqualStrings("b", app.repo_name);

    tab_strip.closeTab(0);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expect(app.repo == null);
}

test "a tab dragged onto another takes its place, and the one shown stays shown" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    tab_strip.loadWorkspace();
    var bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "a", "b", "c" }, 0..) |name, i| {
        try expectGit(root, &.{ "init", "-q", "-b", "main", name });
        tab_strip.openAndRemember(try std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ root, name }));
    }
    const tabs = &tab_strip.groups.items[0].tabs;
    const order = struct {
        fn of(list: []const tab_strip.Tab, buf: *[3]u8) []const u8 {
            for (list, 0..) |tab, i| buf[i] = git.repoName(tab.path)[0];
            return buf[0..list.len];
        }
    };
    var buf: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    try std.testing.expectEqualStrings("c", app.repo_name);

    // a onto c, rightwards: it lands after it.
    tab_strip.moveTabTo(0, 0, 0, 2);
    try std.testing.expectEqualStrings("bca", order.of(tabs.items, &buf));
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_tab);

    // a back onto b, leftwards: it lands before it.
    tab_strip.moveTabTo(0, 2, 0, 0);
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    try std.testing.expectEqual(@as(usize, 2), tab_strip.active_tab);

    // Onto itself, or past the end: nothing, then the end.
    tab_strip.moveTabTo(0, 1, 0, 1);
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    tab_strip.moveTabTo(0, 2, 0, 99);
    try std.testing.expectEqualStrings("abc", order.of(tabs.items, &buf));
    try std.testing.expectEqualStrings("c", app.repo_name);

    // Into another group, before the tab it was dropped on.
    tab_strip.groupTab("Side", 0, 0);
    try std.testing.expectEqualStrings("bc", order.of(tab_strip.groups.items[0].tabs.items, &buf));
    tab_strip.moveTabTo(0, 1, 1, 0);
    try std.testing.expectEqualStrings("ca", order.of(tab_strip.groups.items[1].tabs.items, &buf));
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_group);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_tab);
    try std.testing.expectEqualStrings("c", app.repo_name);
}

test "workspaces hold their own groups, and switching opens the tab each was on" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    var buf_c: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    const b = try std.fmt.bufPrint(&buf_b, "{s}/b", .{root});
    const c = try std.fmt.bufPrint(&buf_c, "{s}/c", .{root});
    inline for (.{ "a", "b", "c" }) |name| try expectGit(root, &.{ "init", "-q", "-b", "main", name });

    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 1), tab_strip.workspaces.items.len);
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    // Groups as ever, inside the workspace.
    tab_strip.groupTab("Side", 0, 1);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[1].name);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.groups.items[1].ws);

    // A new workspace: empty, its own group, nothing open.
    const w = github_connect.newWorkspace("Client", 3).?;
    github_connect.selectWorkspace(w);
    try std.testing.expectEqual(w, tab_strip.active_ws);
    try std.testing.expect(app.repo == null and app.new_tab_open);
    tab_strip.openAndRemember(c);
    try std.testing.expectEqual(w, tab_strip.groups.items[tab_strip.active_group].ws);

    // Back: b, where it was, in its group.
    github_connect.selectWorkspace(0);
    try std.testing.expectEqualStrings("b", app.repo_name);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[tab_strip.active_group].name);
    github_connect.selectWorkspace(w);
    try std.testing.expectEqualStrings("c", app.repo_name);

    // All of it after a restart.
    tab_strip.saveWorkspace();
    dialog_views.closeRepo();
    forgetTabs();
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 2), tab_strip.workspaces.items.len);
    try std.testing.expectEqualStrings("Client", tab_strip.workspaces.items[1].name);
    try std.testing.expectEqual(@as(u8, 3), tab_strip.workspaces.items[1].color);
    var side = false;
    for (tab_strip.groups.items) |g| side = side or (std.mem.eql(u8, g.name, "Side") and g.ws == 0);
    try std.testing.expect(side);

    // Deleted: its tabs to the recent list, the other workspace stays.
    github_connect.deleteWorkspace(1);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.workspaces.items.len);
    for (tab_strip.groups.items) |g| try std.testing.expectEqual(@as(usize, 0), g.ws);
}

test "a group is made in a dialog, with its colour and no name" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);

    repo_io.group_target = .{ 0, 0 };
    github_connect.openWorkspaceDialog(.group);
    try std.testing.expect(github_connect.ws_dialog == .group);
    try std.testing.expect(app.prompt == null);
    // Only a colour asked for: a group is its dot.
    github_connect.ws_color = 4;
    github_connect.applyWorkspaceDialog();
    try std.testing.expect(github_connect.ws_dialog == null);
    // Its only tab gone, the group it came from goes too.
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings(tab_strip.GROUP_MARK, tab_strip.groups.items[0].name);
    try std.testing.expectEqual(@as(u8, 4), tab_strip.groups.items[0].color);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);
    try std.testing.expectEqualStrings("", tab_strip.groupLabel(tab_strip.groups.items[0]));

    // Named, then the name taken off again: still a group, its dot alone.
    repo_io.group_target = .{ 0, 0 };
    github_connect.openWorkspaceDialog(.group_rename);
    try std.testing.expectEqual(@as(u8, 4), github_connect.ws_color);
    github_connect.ws_name.appendSlice(app.gpa, " Client ") catch unreachable;
    github_connect.applyWorkspaceDialog();
    try std.testing.expectEqualStrings("Client", tab_strip.groupLabel(tab_strip.groups.items[0]));
    github_connect.openWorkspaceDialog(.group_rename);
    try std.testing.expectEqualStrings("Client", github_connect.ws_name.items);
    github_connect.ws_name.clearRetainingCapacity();
    github_connect.applyWorkspaceDialog();
    try std.testing.expectEqualStrings(tab_strip.GROUP_MARK, tab_strip.groups.items[0].name);

    // Let go past the last tab: out of the group, which goes, empty.
    tab_strip.tabToEnd(0, 0);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.groups.items[0].name.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.active_group);
}

test "a group keeps its own tabs, and the last group cannot be closed" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&buf_a, "{s}/a", .{root});
    const b = try std.fmt.bufPrint(&buf_b, "{s}/b", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);

    tab_strip.openAndRemember(b);
    // Two tabs in no group to begin with.
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("", tab_strip.groups.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items[0].tabs.items.len);

    // b into a group of its own, still the one open.
    tab_strip.groupTab("Side", 0, 1);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_group);
    try std.testing.expectEqualStrings("b", app.repo_name);

    // A tab of the other group, picked straight from the strip.
    tab_strip.selectTabIn(0, 0);
    try std.testing.expectEqualStrings("a", app.repo_name);

    // Both groups survive the restart, with their tabs, colour and fold.
    tab_strip.groups.items[1].collapsed = true;
    tab_strip.groups.items[1].color = 3;
    tab_strip.saveWorkspace();
    dialog_views.closeRepo();
    forgetTabs();
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("Side", tab_strip.groups.items[1].name);
    try std.testing.expect(tab_strip.groups.items[1].collapsed);
    try std.testing.expectEqual(@as(u8, 3), tab_strip.groups.items[1].color);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[1].tabs.items.len);

    // Out of the group again: the group, empty, goes.
    tab_strip.ungroupTab(1, 0);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("", tab_strip.groups.items[1].name);

    // Closing a group closes its tabs; the last one standing stays.
    tab_strip.closeGroup(0);
    tab_strip.closeGroup(0);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.groups.items[0].tabs.items.len);
}

test "First-parent shows the mainline through a merge, All branches the side branch too" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    defer graph_view.graph_first_parent = false;
    try git.init();
    defer git.shutdown();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-q", "-c", "side" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "b.txt" });
    try expectGit(dir, &.{ "commit", "-q", "-m", "on the side" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try expectGit(dir, &.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    try std.testing.expectEqual(@as(usize, 3), app.history.?.commits.len);

    graph_view.graph_first_parent = true;
    repo_io.reloadHistory();
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits.len);
    for (app.history.?.commits) |c| try std.testing.expect(!std.mem.eql(u8, c.summary, "on the side"));
    // The merge is still a merge, drawn without a line to the side.
    try std.testing.expectEqual(@as(u16, 1), app.lanes.?.lane_count);
}

/// Type `text` into the open prompt and answer it, the way Enter would.
fn answerPrompt(text: []const u8) !void {
    app.prompt_text.clearRetainingCapacity();
    try app.prompt_text.appendSlice(app.gpa, text);
    repo_io.requestAction(.prompt);
    try std.testing.expect(repo_io.runAction());
}

/// Say yes to the open confirmation.
fn answerConfirm() !void {
    try std.testing.expect(app.confirm != null);
    repo_io.requestAction(.confirmed);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?app.Confirm, null), app.confirm);
}

// Each is one argv built from a prompt; only running it says the words are in
// the right order.
test "renames, a named stash and a forced delete go through git" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });
    try expectGit(dir, &.{ "remote", "add", "origin", "/nowhere" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.askNameWith(.rename_branch, "feat", "feat");
    // Pre-filled with the old name, so a typo is fixed rather than retyped.
    try std.testing.expectEqualStrings("feat", app.prompt_text.items);
    try answerPrompt("renamed");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("renamed") != null);
    try std.testing.expect(findRef("feat") == null);
    try std.testing.expectEqual(@as(?app.Prompt, null), app.prompt);

    github_actions.askNameWith(.rename_remote, "origin", "origin");
    try answerPrompt("up");
    github_actions.askNameWith(.remote_url, "up", "/nowhere");
    try answerPrompt("/elsewhere");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("up", app.history.?.remotes[0].name);
    try std.testing.expectEqualStrings("/elsewhere", app.history.?.remotes[0].url);

    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    github_actions.askName(.stash, "");
    try answerPrompt("half a thought");
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.stashes.len);
    try std.testing.expect(std.mem.indexOf(u8, app.history.?.stashes[0].message, "half a thought") != null);

    // Its drop asked for, then another stash pushed on top while the bar is
    // up: the one asked about goes, not the new stash@{0}.
    var stash_hex: [41]u8 = undefined;
    github_actions.ask(.stash_drop, git.oidHex(app.history.?.stashes[0].id, &stash_hex));
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "changed again\n" });
    try expectGit(dir, &.{ "stash", "push", "-m", "newer" });
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.stashes.len);
    try std.testing.expect(std.mem.indexOf(u8, app.history.?.stashes[0].message, "newer") != null);

    // Another pushed from a terminal, with the list not read again: the row
    // still says stash@{0} for "newer", and pop takes that one, not "newest".
    const newer = app.history.?.stashes[0].id;
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "third\n" });
    try expectGit(dir, &.{ "stash", "push", "-m", "newest" });
    rebase_view.requestStash("pop", newer);
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    const popped = try tmp.dir.readFileAlloc(app.app_io, "a.txt", app.gpa, .limited(64));
    defer app.gpa.free(popped);
    try std.testing.expectEqualStrings("changed again\n", popped);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.stashes.len);
    try std.testing.expect(std.mem.indexOf(u8, app.history.?.stashes[0].message, "newest") != null);
    try expectGit(dir, &.{ "checkout", "--", "a.txt" });

    // A branch with a commit no other branch has: `-d` refuses it, which is
    // why `-D` exists and why it asks.
    try expectGit(dir, &.{ "switch", "-q", "-c", "lost" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "only here" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    repo_io.reloadHistory();

    github_actions.gitDo(&.{ "branch", "-d", "lost" });
    try std.testing.expect(tab_strip.command_error != null);
    github_actions.ask(.delete_branch_force, "lost");
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("lost") == null);
}

// The reverse of staging a hunk, and the file-level "put it back how it was".
// Both write the working tree, which is exactly what nothing else here does.
test "a hunk is discarded alone, and a file comes back from a commit" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "lines.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "lines.txt", .data = TWELVE_EDITED });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    const r = app.repo orelse return error.RepoNotOpen;

    {
        var unstaged = try r.readWorkDiff(app.gpa, .unstaged, "lines.txt");
        defer unstaged.deinit();
        try std.testing.expectEqual(@as(u32, 2), unstaged.files[0].hunk_count);
        rebase_view.askDiscardHunk(unstaged.files[0], 0);
    }
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const after = try tmp.dir.readFileAlloc(app.app_io, "lines.txt", app.gpa, .limited(1 << 16));
    defer app.gpa.free(after);
    // The first edit is gone, the last one is still there.
    try std.testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\ntwelve\n", after);

    try expectGit(dir, &.{ "commit", "-qam", "twelve" });
    repo_io.reloadHistory();
    const base = findCommit("base") orelse return error.CommitNotFound;

    var arg_buf: [64]u8 = undefined;
    var sha_buf: [8]u8 = undefined;
    github_actions.ask(.restore_file, try std.fmt.bufPrint(&arg_buf, "{s} lines.txt", .{git.oidShort(base.id, &sha_buf)}));
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const restored = try tmp.dir.readFileAlloc(app.app_io, "lines.txt", app.gpa, .limited(1 << 16));
    defer app.gpa.free(restored);
    try std.testing.expectEqualStrings(TWELVE_LINES, restored);
}

// File history is a filter over the graph, worked out in git.zig; the merge
// case is the one that is easy to get wrong in either direction.
test "a file's history lists the commits that changed it, and only those" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    try expectGit(dir, &.{ "switch", "-q", "-c", "side" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "a, on a branch\n" });
    try expectGit(dir, &.{ "commit", "-qam", "a on side" });
    try expectGit(dir, &.{ "switch", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "b only" });
    // Carries side's change to a.txt in, without changing it itself.
    try expectGit(dir, &.{ "merge", "-q", "--no-ff", "--no-edit", "side" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    graph_view.showFileHistory("a.txt");
    const h = app.history.?;
    var shown: usize = 0;
    for (h.commits, 0..) |commit, i| {
        if (shownNow(commit, i)) shown += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), shown);

    const want = [_][]const u8{ "base", "a on side" };
    for (want) |summary| {
        const commit = findCommit(summary) orelse return error.CommitNotFound;
        try std.testing.expect(shownNow(commit, h.indexOf(commit.id).?));
    }
    const other = findCommit("b only") orelse return error.CommitNotFound;
    try std.testing.expect(!shownNow(other, h.indexOf(other.id).?));

    // Re-marked when the history is re-read: the flags are by index.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "again\n" });
    github_actions.gitDo(&.{ "commit", "-qam", "a again" });
    const latest = findCommit("a again") orelse return error.CommitNotFound;
    try std.testing.expect(shownNow(latest, app.history.?.indexOf(latest.id).?));

    // And gone when asked.
    graph_view.clearFileHistory();
    try std.testing.expect(shownNow(other, app.history.?.indexOf(other.id).?));
}

test "ignoring a file appends it to .gitignore and it drops out of the changes" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    // A .gitignore without its last newline: the new line must not be glued on.
    try makeTestRepo(&tmp, dir, ".gitignore", "*.log");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "scratch.txt", .data = "x\n" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    try std.testing.expectEqual(@as(usize, 1), app.work.?.unstaged.len);

    commit_view.ignorePath("scratch.txt");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const text = try tmp.dir.readFileAlloc(app.app_io, ".gitignore", app.gpa, .limited(1 << 16));
    defer app.gpa.free(text);
    try std.testing.expectEqualStrings("*.log\n/scratch.txt\n", text);
    // The only change left is the .gitignore itself.
    try std.testing.expectEqual(@as(usize, 1), app.work.?.unstaged.len);
    try std.testing.expectEqualStrings(".gitignore", app.work.?.unstaged[0].path);

    // A name that reads as a glob: escaped, it ignores itself, and not the
    // `a1.txt` the bare pattern would have meant.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a[1].txt", .data = "x\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a1.txt", .data = "x\n" });
    repo_io.reloadWork();
    commit_view.ignorePath("a[1].txt");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 2), app.work.?.unstaged.len);
    for (app.work.?.unstaged) |change| try std.testing.expect(!std.mem.eql(u8, change.path, "a[1].txt"));
}

// All go off-thread, two of them after a confirmation: a path no other test
// takes.
test "branches and tags are pushed, force pushed and deleted on the remote" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);

    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "--no-track", "-B", "feat", "origin/main" });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // The toolbar's push, on a branch with no upstream yet.
    repo_io.requestNetwork("Pushing", &.{ "-c", "push.autoSetupRemote=true", "push" });
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("origin/feat") != null);
    try std.testing.expect(app.history.?.tracking.upstream != null);

    // Rewrite what was pushed, and force it over.
    try expectGit(down, &.{ "commit", "-q", "--amend", "-m", "rewritten" });
    repo_io.reloadHistory();
    github_actions.ask(.force_push, "");
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    // The remote now has the rewritten commit, not the one it had.
    try std.testing.expect(findCommit("rewritten") != null);
    try std.testing.expectEqual(@as(usize, 0), app.history.?.tracking.ahead);
    try std.testing.expectEqual(@as(usize, 0), app.history.?.tracking.behind);

    github_actions.ask(.delete_remote_branch, "origin/feat");
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var gone = try run.git(app.gpa, app.app_io, up, &.{ "rev-parse", "--verify", "-q", "refs/heads/feat" });
        defer gone.deinit(app.gpa);
        try std.testing.expect(!gone.ok);
    }

    try expectGit(down, &.{ "tag", "v1" });
    repo_io.reloadHistory();
    repo_io.requestNetwork("Pushing", &.{ "push", github_actions.defaultRemote().?, "v1" });
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try expectGit(up, &.{ "rev-parse", "--verify", "-q", "refs/tags/v1" });

    github_actions.ask(.delete_remote_tag, "v1");
    try answerConfirm();
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var gone = try run.git(app.gpa, app.app_io, up, &.{ "rev-parse", "--verify", "-q", "refs/tags/v1" });
        defer gone.deinit(app.gpa);
        try std.testing.expect(!gone.ok);
    }
}

/// The subject of `rev` in `dir`, for checking where a pull left things.
fn subjectAt(dir: []const u8, rev: []const u8) ![]u8 {
    const answer = try run.capture(app.gpa, app.app_io, dir, &.{ "git", "log", "-1", "--format=%s", rev });
    if (!answer.ok) {
        app.gpa.free(answer.out);
        return error.NoSuchRevision;
    }
    return answer.out;
}

fn expectSubject(dir: []const u8, rev: []const u8, want: []const u8) !void {
    const got = try subjectAt(dir, rev);
    defer app.gpa.free(got);
    try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, got, "\n"));
}

/// A commit of one new file, made from a terminal behind the app's back.
fn commitFile(tmp: *std.testing.TmpDir, dir: []const u8, sub_path: []const u8, message: []const u8) !void {
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = sub_path, .data = message });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", message });
}

test "fetch, and each pull the menu offers, through the toolbar" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "-B", "main", "--track", "origin/main" });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // The remote moves on; Fetch is what tells the branch it is behind.
    try commitFile(&tmp, up, "up/b.txt", "upstream two");
    try clickAt(try tagCenter("toolbar:Fetch"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.tracking.behind);

    // Fast-forward only, from behind.
    try clickAt(try tagCenter("toolbar:pull_menu"));
    try clickAt(try tagCenter("menu:Pull, fast-forward only"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(down, "HEAD", "upstream two");
    try std.testing.expectEqual(@as(usize, 0), app.history.?.tracking.behind);

    // Both sides move: rebasing puts the local commit back on top.
    try commitFile(&tmp, up, "up/c.txt", "upstream three");
    try commitFile(&tmp, down, "down/d.txt", "local one");
    repo_io.reloadHistory();
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:pull_menu"));
    try clickAt(try tagCenter("menu:Pull, rebasing local commits"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(down, "HEAD", "local one");
    try expectSubject(down, "HEAD~1", "upstream three");

    // And again: merging joins the two in a merge commit, no editor asked for.
    try commitFile(&tmp, up, "up/e.txt", "upstream four");
    try commitFile(&tmp, down, "down/f.txt", "local two");
    repo_io.reloadHistory();
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:pull_menu"));
    try clickAt(try tagCenter("menu:Pull, merging"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(down, "HEAD^1", "local two");
    try expectSubject(down, "HEAD^2", "upstream four");
}

/// Where the graph draws the commit `summary`, for clicking on it.
fn commitCenter(summary: []const u8) !dvui.Point.Physical {
    const c = findCommit(summary) orelse return error.NoSuchCommit;
    var short: [8]u8 = undefined;
    var tag_buf: [32]u8 = undefined;
    return tagCenter(try std.fmt.bufPrint(&tag_buf, "commit:{s}", .{git.oidShort(c.id, &short)}));
}

test "a commit's menu leads with check out, and resets from a submenu" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });
    try commitFile(&tmp, dir, "b.txt", "second");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try rightClickAt(try commitCenter("base"));
    const branch_row = try tagCenter("menu:Check out feat");
    const detach_row = try tagCenter("menu:Check out this commit (detaches HEAD)");
    const reset_row = try tagCenter("menu:Reset branch here");
    try std.testing.expect(branch_row.y < detach_row.y and detach_row.y < reset_row.y);
    // The three resets are not top-level rows.
    try std.testing.expect(dvui.tagGet("menu:Soft — keep changes staged") == null);

    try clickAt(reset_row);
    try clickAt(try tagCenter("menu:Soft — keep changes staged"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "base");
    // Soft: what the second commit added is staged, not lost.
    {
        var staged = try run.git(app.gpa, app.app_io, dir, &.{ "diff", "--cached", "--quiet", "--", "b.txt" });
        defer staged.deinit(app.gpa);
        try std.testing.expect(!staged.ok);
    }

    // Esc leaves the pull requests for the history.
    app.active_view = .pulls;
    try pressFrame(.escape, .none);
    try std.testing.expectEqual(.graph, app.active_view);
}

// A merge is neither picked nor reverted without naming its first parent.
test "cherry-pick and revert from a commit's menu, a merge's too" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-q", "-c", "feat" });
    try commitFile(&tmp, dir, "g.txt", "feat work");
    try expectGit(dir, &.{ "switch", "-q", "main" });
    // Main moves too: picked onto the commit it was made on, in the same
    // second, a cherry-pick is the very same commit, and nothing is left to
    // merge later.
    try commitFile(&tmp, dir, "m.txt", "main moves");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Cherry-picked from feat onto main.
    try rightClickAt(try commitCenter("feat work"));
    try clickAt(try tagCenter("menu:Cherry-pick onto current branch"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "feat work");
    try expectGit(dir, &.{ "rev-parse", "--verify", "-q", "HEAD:g.txt" });

    // Reverted: the file it added is gone again.
    try dvui.testing.settle(frameArrowCursor);
    {
        // Two commits say "feat work" now; the one on main is HEAD's.
        var short: [8]u8 = undefined;
        var tag_buf: [32]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tag_buf, "commit:{s}", .{git.oidShort(app.history.?.head_oid.?, &short)});
        try rightClickAt(try tagCenter(tag));
    }
    try clickAt(try tagCenter("menu:Revert"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "Revert \"feat work\"");
    {
        var gone = try run.git(app.gpa, app.app_io, dir, &.{ "rev-parse", "--verify", "-q", "HEAD:g.txt" });
        defer gone.deinit(app.gpa);
        try std.testing.expect(!gone.ok);
    }

    // A merge of feat, reverted: its change against main goes, the merge stays.
    try expectGit(dir, &.{ "merge", "-q", "--no-ff", "--no-edit", "-m", "merge feat", "feat" });
    repo_io.reloadHistory();
    try dvui.testing.settle(frameArrowCursor);
    try rightClickAt(try commitCenter("merge feat"));
    try clickAt(try tagCenter("menu:Revert"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectSubject(dir, "HEAD", "Revert \"merge feat\"");
    try expectSubject(dir, "HEAD~1", "merge feat");
}

test "stash apply keeps the stash, amend starts from the last message, a tag from a commit's menu" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "commit", "-q", "--amend", "-m", "first\n\nwith a body" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Stashed, then applied from its row: the change back, the stash kept.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "edited\n" });
    repo_io.reloadWork();
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:Stash"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 0), search_view.changeCount());
    {
        var short: [8]u8 = undefined;
        var tag_buf: [32]u8 = undefined;
        // Its buttons show on hover.
        try hoverAt(try tagCenter(try std.fmt.bufPrint(&tag_buf, "stash:{s}", .{git.oidShort(app.history.?.stashes[0].id, &short)})));
        try clickAt(try tagCenter(try std.fmt.bufPrint(&tag_buf, "stash_apply:{s}", .{git.oidShort(app.history.?.stashes[0].id, &short)})));
    }
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), search_view.changeCount());
    try std.testing.expectEqual(@as(usize, 1), app.history.?.stashes.len);

    // Amend ticked: the last message to start from, the button live at once.
    try clickAt(try tagCenter("link:stage_all"));
    try pumpJobFrame();
    try clickAt(try tagCenter("commit:amend"));
    try std.testing.expect(app.amend);
    try std.testing.expectEqualStrings("first", app.commit_summary.items);
    try std.testing.expectEqualStrings("with a body", app.commit_description.items);
    try clickAt(try tagCenter("commit_button"));
    // A commit is a job: waited for, as Stash and Stage all are. The
    // frames of the click alone were sometimes over before git was —
    // the commit not in the history yet, the job left running into the
    // next test.
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.commits.len);
    try expectSubject(dir, "HEAD", "first");
    try expectGit(dir, &.{ "diff", "--quiet", "HEAD", "--", "a.txt" });

    // A tag, from the commit's menu and its dialog.
    try rightClickAt(try commitCenter("first"));
    try clickAt(try tagCenter("menu:Tag this commit"));
    try std.testing.expect(app.prompt != null);
    try typeText("v0.1");
    try clickAt(try tagCenter("prompt:go"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("v0.1") != null);
}

test "the toolbar's branch menu filters and switches branches" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);
    try expectGit(up, &.{ "branch", "remote-only" });
    var origin_buf: [std.fs.max_path_bytes]u8 = undefined;
    try expectGit(down, &.{ "remote", "add", "origin", try absPath(&origin_buf, up) });
    try expectGit(down, &.{ "fetch", "-q", "origin" });
    try expectGit(down, &.{ "checkout", "-q", "-B", "main", "--track", "origin/main" });
    try expectGit(down, &.{ "branch", "feature" });

    app.openRepo(down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Narrowed by what is typed: main goes, feature stays.
    try clickAt(try tagCenter("toolbar:branch"));
    try typeText("feat");
    try std.testing.expect(dvui.tagGet("switch:main") == null);
    try clickAt(try tagCenter("switch:feature"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("feature", app.history.?.head.?);

    // A branch only the remote has: switched to, and tracked.
    try clickAt(try tagCenter("toolbar:branch"));
    try std.testing.expectEqual(@as(usize, 0), window_chrome.switch_filter.items.len);
    try clickAt(try tagCenter("switch:origin/remote-only"));
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("remote-only", app.history.?.head.?);
    try expectGit(down, &.{ "rev-parse", "--verify", "-q", "remote-only@{upstream}" });
}

// The avatar's menu: signing goes to its card in the settings, and signing
// out of GitHub only ever asks first. Never answered here — it would sign the
// machine running the tests out.
test "the avatar's menu opens the signing card, and asks before signing out" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    defer github_actions.clearConfirm();
    // Who the menu says is signed in, without asking GitHub.
    window_chrome.me_loaded = true;
    try window_chrome.me_gh.appendSlice(app.gpa, "tester");

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("toolbar:user"));
    try clickAt(try tagCenter("menu:Commit signature"));
    try std.testing.expect(identity_view.settings_open);
    try std.testing.expectEqual(@as(usize, 6), identity_view.settings_page);
    // Another section from the list, and back.
    try clickAt(try tagCenter("settings:Integrations"));
    try std.testing.expectEqual(@as(usize, 3), identity_view.settings_page);
    try clickAt(try tagCenter("settings:Commit signing"));
    try std.testing.expectEqual(@as(usize, 6), identity_view.settings_page);
    try pressFrame(.escape, .none);
    try std.testing.expect(!identity_view.settings_open);

    try clickAt(try tagCenter("toolbar:user"));
    try clickAt(try tagCenter("menu:Sign out of GitHub (tester)"));
    try std.testing.expect(app.confirm != null);
    try std.testing.expectEqual(app.Confirm.Kind.sign_out, app.confirm.?.kind);
    try std.testing.expectEqualStrings("tester", app.confirm.?.arg);
    try clickAt(try tagCenter("confirm:cancel"));
    try std.testing.expect(app.confirm == null);
}

// One person under two spellings and two addresses is one author once the
// repository's .mailmap says so: one row in the menu, every commit theirs.
test "the authors are read through .mailmap, one person once" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=ann", "-c", "user.email=ann@home.invalid", "commit", "-qm", "from home" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=Ann Lee", "-c", "user.email=ann@work.invalid", "commit", "-qm", "from work" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = ".mailmap", .data = "Ann Lee <ann@work.invalid> <ann@home.invalid>\n" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const ann = graph_view.authorByKey("Ann Lee\nann@work.invalid") orelse return error.AuthorMissing;
    try std.testing.expectEqualStrings("Ann Lee", ann.name);
    try std.testing.expectEqual(@as(usize, 2), ann.count);
    try std.testing.expectEqual(@as(?graph_view.AuthorEntry, null), graph_view.authorByKey("ann\nann@home.invalid"));
    // A team sharing one address stays apart, by name.
    try std.testing.expect(graph_view.sameAuthor("Ann Lee\nANN@work.invalid", ann.key));
    try std.testing.expect(!graph_view.sameAuthor("Bo\nann@work.invalid", ann.key));

    // Theirs alone, from the commit's own menu's words, then Enter in the
    // menu's field taking the first author it shows.
    graph_view.onlyAuthor(ann.key);
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(app.gpa);
    graph_view.shownRows(app.gpa, app.history.?.commits, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);

    graph_view.clearAuthors();
    try clickAt(try tagCenter("header:author"));
    try typeText("test");
    try pressFrame(.enter, .none);
    try std.testing.expectEqual(@as(usize, 1), graph_view.author_only.items.len);
    try std.testing.expectEqualStrings("Zit Test\ntest@zync.invalid", graph_view.author_only.items[0]);
    // The one picked stays at the top of the menu, to be taken off from.
    try clickAt(try tagCenter("header:author"));
    try clickAt(try tagCenter("author:Zit Test"));
    try std.testing.expectEqual(@as(usize, 1), graph_view.author_only.items.len);
}

// Narrowed to one author, the history holds theirs alone, each joined to
// the nearest of theirs before it: a lane from the newest to the oldest,
// through the commits left out, as `git log --author --graph` draws it.
test "an author filter leaves the others' commits out and joins the lanes over them" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=Bo", "-c", "user.email=bo@x.invalid", "commit", "-qm", "by bo" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "mine again" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    try std.testing.expectEqual(@as(usize, 3), app.history.?.commits.len);

    graph_view.onlyAuthor("Zit Test\ntest@zync.invalid");
    const h = app.history.?;
    try std.testing.expectEqual(@as(usize, 2), h.commits.len);
    try std.testing.expectEqualStrings("mine again", h.commits[0].summary);
    try std.testing.expectEqualStrings("base", h.commits[1].summary);
    // Joined over Bo's.
    try std.testing.expectEqual(@as(usize, 1), h.commits[0].parents.len);
    try std.testing.expect(git.oidEql(h.commits[0].parents[0], h.commits[1].id));
    try std.testing.expectEqual(@as(usize, 1), app.lanes.?.lane_count);

    graph_view.clearAuthors();
    try std.testing.expectEqual(@as(usize, 3), app.history.?.commits.len);
}

test "the author column filters the list, and the version opens the features" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "-c", "user.name=Bo Chen", "-c", "user.email=bo@x.invalid", "commit", "-qm", "by bo" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("header:author"));
    try clickAt(try tagCenter("author:Bo Chen"));
    try std.testing.expect(graph_view.listFiltered());
    {
        var rows: std.ArrayList(u32) = .empty;
        defer rows.deinit(app.gpa);
        graph_view.shownRows(app.gpa, app.history.?.commits, &rows);
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
        try std.testing.expectEqualStrings("by bo", app.history.?.commits[rows.items[0]].summary);
    }
    // A click on a name shows theirs alone and closes the menu; the header
    // says whose; All authors, in the menu again, brings everyone back.
    try expectNoTag("author_filter");
    try clickAt(try tagCenter("header:author"));
    try clickAt(try tagCenter("pick:All authors"));
    try std.testing.expect(!graph_view.listFiltered());

    try clickAt(try tagCenter("status:version"));
    try std.testing.expect(home_page.features_open);
    try pressFrame(.escape, .none);
    try std.testing.expect(!home_page.features_open);
}

test "a request's lists, run ids and checks read the way the commands want them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[\"ann\",\"bo\",\"core\"]", github_actions.jsonList(a, " ann, bo ,core,"));
    try std.testing.expectEqualStrings("[]", github_actions.jsonList(a, " , "));

    try std.testing.expectEqualStrings("123", pr_editor.runIdOf("https://github.com/o/r/actions/runs/123/job/456").?);
    try std.testing.expectEqualStrings("9", pr_editor.runIdOf("https://github.com/o/r/actions/runs/9").?);
    try std.testing.expect(pr_editor.runIdOf("https://ci.example.com/build/1") == null);
    try std.testing.expect(pr_editor.runIdOf("https://github.com/o/r/actions/runs/x1/job/2") == null);

    const t = pr_editor.tallyChecks(&.{
        .{ .name = "a", .result = "SUCCESS" },
        .{ .name = "b", .result = "SKIPPED" },
        .{ .name = "c", .result = "FAILURE" },
        .{ .name = "d", .result = "IN_PROGRESS" },
    });
    try std.testing.expectEqual(@as(usize, 2), t.passed);
    try std.testing.expectEqual(@as(usize, 1), t.failed);
    try std.testing.expectEqual(@as(usize, 1), t.running);
}

test "the request list's tabs and search let the right ones through" {
    app.gpa = std.testing.allocator;
    defer resetUiGlobals();
    try window_chrome.me_gh.appendSlice(app.gpa, "me");
    const mine: pr.Request = .{ .number = 7, .title = "Add login", .branch = "PROJ-25", .author = "me", .draft = true };
    const asks: pr.Request = .{ .number = 12, .title = "API module", .branch = "PROJ-39", .author = "ann", .draft = false, .reviewers = &.{ "bo", "Me" } };
    const other: pr.Request = .{ .number = 30, .title = "Docs", .branch = "PROJ-33", .author = "bo", .draft = false };
    const list = [_]pr.Request{ mine, asks, other };
    pr.list = &list;
    defer pr.list = &.{};

    try std.testing.expectEqual(@as(usize, 1), pr_list.requestsToReview());
    pr_list.pr_filter = .review;
    try std.testing.expect(pr_list.requestShown(asks) and !pr_list.requestShown(mine) and !pr_list.requestShown(other));
    pr_list.pr_filter = .mine;
    try std.testing.expect(pr_list.requestShown(mine) and !pr_list.requestShown(asks));
    pr_list.pr_filter = .drafts;
    try std.testing.expect(pr_list.requestShown(mine) and !pr_list.requestShown(other));

    pr_list.pr_filter = .open;
    try pr_list.pr_search.appendSlice(app.gpa, "api");
    try std.testing.expect(pr_list.requestShown(asks) and !pr_list.requestShown(other));
    pr_list.pr_search.clearRetainingCapacity();
    try pr_list.pr_search.appendSlice(app.gpa, "#30");
    try std.testing.expect(pr_list.requestShown(other) and !pr_list.requestShown(asks));
    pr_list.pr_search.clearRetainingCapacity();
    try pr_list.pr_search.appendSlice(app.gpa, "proj-25");
    try std.testing.expect(pr_list.requestShown(mine) and !pr_list.requestShown(other));
}

test "a new request's title comes from its branch's name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("PROJ-81: Front Login", pr_create.humanBranch(a, "PROJ-81-Front-Login"));
    try std.testing.expectEqualStrings("feat: new thing", pr_create.humanBranch(a, "feat/new-thing"));
    try std.testing.expectEqualStrings("cleanup", pr_create.humanBranch(a, "cleanup"));
    try std.testing.expectEqualStrings("PROJ-7", pr_create.ticketOf("PROJ-7").?);
    try std.testing.expect(pr_create.ticketOf("v1-2") == null);
    try std.testing.expect(pr_create.ticketOf("fix-it") == null);
}

test "a comment's inline marks come off, and plain text is left as it is" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("use QUERY here, not the bold", pr_conversation.plainInline(a, "use `QUERY` here, not the **bold**"));
    try std.testing.expectEqualStrings("snake_case stays", pr_conversation.plainInline(a, "snake_case stays"));
    const same = "nothing to strip";
    try std.testing.expect(pr_conversation.plainInline(a, same).ptr == same.ptr);
}

// The request pane draws in full — head, tabs, the conversation's timeline
// with a folded run of reviews, threads, the answer and the merge — and each
// other tab, without a widget left open.
test "a picker's list toggles, and a label with spaces in it stays whole" {
    app.gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(app.gpa);
    pr_create.listToggle(&list, "ann");
    pr_create.listToggle(&list, "good first issue");
    try std.testing.expectEqualStrings("ann, good first issue", list.items);
    try std.testing.expect(pr_create.listHas(list.items, "good first issue"));
    try std.testing.expect(!pr_create.listHas(list.items, "good"));
    pr_create.listToggle(&list, "ann");
    try std.testing.expectEqualStrings("good first issue", list.items);

    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("[\"good first issue\",\"bug\"]", pr_create.jsonCommaList(arena.allocator(), "good first issue, bug,"));
}

// The create dialog as GitHub's page has it: the people and the labels
// picked from lists the host gave, the type from a list of two.
test "a new pull request's reviewers, labels and type are picked from lists" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-qc", "feat/login-form" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    pr.meta = .{
        .people = &.{ .{ .login = "ann", .name = "Ann Lee" }, .{ .login = "bo" } },
        .labels = &.{ .{ .name = "bug", .color = "d73a4a" }, .{ .name = "good first issue", .color = "7057ff" } },
    };
    pr.meta_status = .ready;
    defer {
        pr.meta = .{};
        pr.meta_status = .idle;
    }

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1400, .h = 860 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    pr_create.openPrCreate();
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqualStrings("feat/login-form", pr_create.pr_new_head.items);

    try clickAt(try tagCenter("pr_new:labels"));
    try clickAt(try tagCenter("pick:good first issue"));
    try std.testing.expectEqualStrings("good first issue", pr_create.pr_new_labels.items);
    try pressFrame(.escape, .none);

    try clickAt(try tagCenter("pr_new:reviewers"));
    try clickAt(try tagCenter("pick:bo"));
    try std.testing.expectEqualStrings("bo", pr_create.pr_new_reviewers.items);
    try pressFrame(.escape, .none);

    try clickAt(try tagCenter("pr_new:type"));
    try clickAt(try tagCenter("pick:Draft"));
    try std.testing.expect(pr_create.pr_new_draft);
    try std.testing.expect(pr_create.pr_new_open);
}

// GitHub's sidebar: a section's head drops its list, and a tick there is
// sent at once — refused here, with no one signed in, which is the point:
// it was sent, and the list kept the tick.
test "the request's sidebar picks its labels from a list, sent at once" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    pr.detail = .{
        .number = 42,
        .title = "Login form",
        .author = "damien",
        .state = "OPEN",
        .head = "feat/login-form",
        .base = "main",
        .reviewers = &.{.{ .login = "ann", .state = "APPROVED" }},
        .labels = &.{.{ .name = "enhancement", .color = "a2eeef" }},
    };
    defer pr.detail = null;
    pr.meta = .{ .labels = &.{ .{ .name = "bug", .color = "d73a4a" }, .{ .name = "enhancement", .color = "a2eeef" } } };
    pr.meta_status = .ready;
    defer {
        pr.meta = .{};
        pr.meta_status = .idle;
    }
    pr_list.pr_selected = 42;
    app.active_view = .pulls;
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1600, .h = 800 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("side:Labels"));
    try clickAt(try tagCenter("pick:bug"));
    try std.testing.expect(pr_create.listHas(pr_conversation.side_list.items, "bug"));
    try std.testing.expect(pr_create.listHas(pr_conversation.side_list.items, "enhancement"));
    try std.testing.expect(tab_strip.command_error != null);

    // The edit dialog opens on the request as it is.
    pr_editor.openPrEdit(pr.detail.?);
    defer pr_editor.clearPrEdit();
    try std.testing.expectEqualStrings("main", pr_editor.pr_edit_base.items);
    try std.testing.expect(pr_editor.sameNames(pr_editor.pr_edit_reviewers.items, &.{"ann"}));
    try std.testing.expect(pr_editor.sameNames(pr_editor.pr_edit_labels.items, &.{"enhancement"}));
    try std.testing.expect(!pr_editor.sameNames(pr_editor.pr_edit_labels.items, &.{ "enhancement", "bug" }));
}

// A suggestion as GitHub writes it, and written into the file: over the
// lines it was left on, only while they read as the comment saw them.
test "a suggestion goes over the lines it was left on, while they still read as the comment saw them" {
    app.app_io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // The block, and the words around it.
    const sg = pr_editor.suggestionOf("Use it:\n```suggestion\nif (ok(x)) go();\n```\nThanks.").?;
    try std.testing.expectEqualStrings("Use it:\n", sg.before);
    try std.testing.expectEqualStrings("if (ok(x)) go();", sg.code);
    try std.testing.expectEqualStrings("Thanks.", sg.after);
    try std.testing.expect(pr_editor.suggestionOf("no block here") == null);
    try std.testing.expectEqualStrings("", pr_editor.suggestionOf("```suggestion\n```").?.code);

    // One line, in a file with CRLF ends, which it keeps.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.js", .data = "one\r\nif (x) go();\r\nthree\r\n" });
    const one: pr.Thread = .{ .path = "a.js", .line = 2, .hunk = "@@ -1,2 +1,2 @@\n one\n-if (y) go();\n+if (x) go();" };
    try std.testing.expectEqual(@as(?[]const u8, null), pr_editor.applySuggestionTo(a, dir, one, "if (ok(x)) go();"));
    try std.testing.expectEqualStrings("one\r\nif (ok(x)) go();\r\nthree\r\n", try tmp.dir.readFileAlloc(app.app_io, "a.js", a, .limited(1024)));
    // Twice: the line no longer reads as the comment saw it, and is left be.
    try std.testing.expect(pr_editor.applySuggestionTo(a, dir, one, "if (ok(x)) go();") != null);
    try std.testing.expectEqualStrings("one\r\nif (ok(x)) go();\r\nthree\r\n", try tmp.dir.readFileAlloc(app.app_io, "a.js", a, .limited(1024)));

    // Two lines into one, in a file with no last newline; then an empty
    // suggestion takes a line out.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "a\nb\nc\nd" });
    const two: pr.Thread = .{ .path = "b.txt", .start_line = 2, .line = 3, .hunk = "@@ -1 +1,3 @@\n a\n+b\n+c" };
    try std.testing.expectEqual(@as(?[]const u8, null), pr_editor.applySuggestionTo(a, dir, two, "bc"));
    try std.testing.expectEqualStrings("a\nbc\nd", try tmp.dir.readFileAlloc(app.app_io, "b.txt", a, .limited(1024)));
    const gone: pr.Thread = .{ .path = "b.txt", .line = 1, .hunk = "@@ -0,0 +1 @@\n+a" };
    try std.testing.expectEqual(@as(?[]const u8, null), pr_editor.applySuggestionTo(a, dir, gone, ""));
    try std.testing.expectEqualStrings("bc\nd", try tmp.dir.readFileAlloc(app.app_io, "b.txt", a, .limited(1024)));
    // Past the end of the file: changed since.
    try std.testing.expect(pr_editor.applySuggestionTo(a, dir, .{ .path = "b.txt", .line = 9 }, "x") != null);
}

// Picked, a request is read in full off the window's thread: its head is
// there at once from the list, the rest loading under it — not a blank pane.
test "a request being read shows its head from the list, the rest loading" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var listed = [_]pr.Request{.{ .number = 9, .title = "Faster search", .branch = "feat/search", .author = "ann", .draft = false, .base = "main" }};
    pr.list = &listed;
    defer pr.list = &.{};
    pr.detail = null;
    pr_list.pr_selected = 9;
    app.active_view = .pulls;
    pr.host = .github;
    defer pr.host = .none;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagRect("pr:loading");
    // Not one the list has: the pane loading, with no head to guess at.
    pr_list.pr_selected = 10;
    try dvui.testing.settle(frameArrowCursor);
    try expectNoTag("pr:loading");
}

// A request someone asked changes of, as its author meets it: who asked and
// how much is left, the conversations under the review that opened them —
// a resolved one folded — and a suggestion applied from the click.
test "changes asked for: threads under their review, a suggestion applied from its button" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "login.ts", "const f = el();\nif (email) submit();\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    pr.detail = .{
        .number = 16,
        .id = "PR_1",
        .title = "Login form",
        .author = "me",
        .state = "OPEN",
        // Its branch is the one checked out here.
        .head = "main",
        .base = "dev",
        .mergeable = "MERGEABLE",
        .review = "CHANGES_REQUESTED",
        .reviews = &.{.{ .id = "R1", .author = "ann", .body = "A couple of things.", .when = "2026-10-21T11:00:00Z", .state = "CHANGES_REQUESTED" }},
        .reviewers = &.{.{ .login = "ann", .state = "CHANGES_REQUESTED" }},
        .threads = &.{
            .{ .id = "T1", .review = "R1", .path = "login.ts", .line = 2, .can_reply = true, .can_resolve = true, .hunk = "@@ -1 +1,2 @@\n const f = el();\n+if (email) submit();", .comments = &.{.{ .author = "ann", .body = "Use the validator:\n```suggestion\nif (isEmail(email)) submit();\n```", .when = "2026-10-21T11:00:00Z" }} },
            .{ .id = "T2", .review = "R1", .path = "login.ts", .line = 1, .resolved = true, .can_unresolve = true, .comments = &.{.{ .author = "ann", .body = "fine now", .when = "2026-10-21T11:00:00Z" }} },
        },
    };
    defer pr.detail = null;
    pr_list.pr_selected = 16;
    app.active_view = .pulls;
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    pr_conversation.pr_tab = .conversation;
    try dvui.testing.settle(frameArrowCursor);

    // On its branch already: asking again is what is left to do, and each
    // reviewer who answered can be asked again too.
    _ = try tagRect("pr:rerequest");
    _ = try tagRect("pr:rerequest:ann");
    try expectNoTag("pr:fix");
    // The open one shows its answers; the resolved one is folded to its head.
    _ = try tagRect("pr:resolve:T1");
    try expectNoTag("pr:unresolve:T2");
    try clickAt(try tagCenter("pr:threads_all"));
    _ = try tagRect("pr:unresolve:T2");

    // The suggestion, into the file here; its button then says so, and
    // leads to the change.
    try clickAt(try tagCenter("pr:apply:T1"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectNoTag("pr:apply:T1");
    _ = try tagRect("pr:applied:T1");
    const now = try tmp.dir.readFileAlloc(app.app_io, "login.ts", app.gpa, .limited(1024));
    defer app.gpa.free(now);
    try std.testing.expectEqualStrings("const f = el();\nif (isEmail(email)) submit();\n", now);

    // To the conversations from the readiness line.
    try clickAt(try tagCenter("pr:to_threads"));
    try std.testing.expect(!pr_editor.pr_scroll_thread);

    // To the change it made, in the working copy.
    try clickAt(try tagCenter("pr:applied:T1"));
    try std.testing.expectEqual(app.View.graph, app.active_view);
    try std.testing.expectEqualStrings("login.ts", app.selected_path.items);
}

test "a request's pane draws every tab" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    const review = pr.Note{ .author = "ann", .body = "part of a review", .when = "2026-10-20T10:00:00Z", .state = "COMMENTED" };
    pr.detail = .{
        .number = 7,
        .title = "Login",
        .body = "## Why\n- one\n- [x] done\n> quoted\n```\ncode\n```\nplain **bold**",
        .author = "me",
        .state = "OPEN",
        .head = "feat",
        .base = "main",
        .comments = &.{.{ .author = "bo", .body = "looks fine", .when = "2026-10-21T10:00:00Z" }},
        .reviews = &.{ review, review, review, review, .{ .author = "ann", .when = "2026-10-20T11:00:00Z", .state = "APPROVED" } },
        .checks = &.{ .{ .name = "build", .result = "SUCCESS", .group = "CI", .seconds = 75 }, .{ .name = "lint", .result = "FAILURE", .group = "CI", .url = "https://github.com/o/r/actions/runs/5/job/6" } },
        .reviewers = &.{.{ .login = "ann", .state = "APPROVED" }},
        .labels = &.{.{ .name = "bug", .color = "d73a4a" }},
        .commits = &.{.{ .oid = "0123456789abcdef0123456789abcdef01234567", .headline = "add login", .author = "me", .when = 1 }},
        .file_list = &.{.{ .path = "src/a.zig", .additions = 3, .deletions = 1 }},
        .threads = &.{.{ .id = "T1", .path = "src/a.zig", .line = 2, .comments = &.{.{ .author = "ann", .body = "why?", .when = "2026-10-20T10:30:00Z" }} }},
    };
    defer pr.detail = null;
    pr_list.pr_selected = 7;
    app.active_view = .pulls;
    // The pane is drawn only on a host; nothing is asked of it here.
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    for ([_]pr_conversation.PrTab{ .conversation, .commits, .files, .checks }) |tab| {
        pr_conversation.pr_tab = tab;
        try dvui.testing.settle(frameArrowCursor);
    }
    pr_conversation.pr_tab = .conversation;
    try dvui.testing.settle(frameArrowCursor);
    // The four bare reviews in a row: the middle two folded behind a button.
    try std.testing.expect(pr_conversation.pr_runs_open == 0);

    // Six steps: the description and the last three open, the oldest folded
    // to their head; Expand all opens the lot, a click on a head folds one.
    try std.testing.expect(pr_conversation.cardOpen(0, true));
    try std.testing.expect(!pr_conversation.cardOpen(1, 1 + pr_conversation.CARDS_OPEN_AT_END >= 6));
    try clickAt(try tagCenter("pr:expand_all"));
    try std.testing.expectEqual(@as(?bool, true), pr_conversation.pr_cards_all);
    try std.testing.expect(pr_conversation.cardOpen(1, false));
    try clickAt(try tagCenter("pr:collapse_all"));
    try std.testing.expect(!pr_conversation.cardOpen(0, true));
}

// The requests from the keys: the checked-out branch's own picked to begin
// with, ↑ and ↓ along the list in its order, a number for a tab.
test "the requests are walked from the keys, starting at the checked-out branch's" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var list = [_]pr.Request{
        .{ .number = 1, .title = "newest", .branch = "feat-a", .author = "ann", .draft = false, .updated = 30 },
        .{ .number = 2, .title = "this branch", .branch = "main", .author = "bo", .draft = false, .updated = 20 },
        .{ .number = 3, .title = "oldest", .branch = "x", .author = "carl", .draft = false, .updated = 10 },
    };
    pr.list = &list;
    defer pr.list = &.{};
    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    app.active_view = .pulls;
    defer pr_list.pr_selected = null;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(?u32, 2), pr_list.pr_selected);

    try pressFrame(.down, .none);
    try std.testing.expectEqual(@as(?u32, 3), pr_list.pr_selected);
    try pressFrame(.down, .none);
    try std.testing.expectEqual(@as(?u32, 3), pr_list.pr_selected);
    try pressFrame(.up, .none);
    try pressFrame(.k, .none);
    try std.testing.expectEqual(@as(?u32, 1), pr_list.pr_selected);
    try pressFrame(.four, .none);
    try std.testing.expect(pr_conversation.pr_tab == .checks);

    // A filter clicked switches the list to the merged ones, shorter than the
    // open: drawn from the one list, not the other's indexes. This crashed.
    var past = [_]pr.Request{.{ .number = 9, .title = "merged", .branch = "old", .author = "ann", .draft = false, .updated = 5 }};
    pr.past = &past;
    defer pr.past = &.{};
    try clickAt(try tagCenter("pr:filter"));
    try clickAt(try tagCenter("pick:Merged"));
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(pr_list.pr_filter == .merged);
    try pressFrame(.down, .none);
    try std.testing.expectEqual(@as(?u32, 9), pr_list.pr_selected);
    try clickAt(try tagCenter("pr:filter"));
    try clickAt(try tagCenter("pick:Open"));
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(pr_list.pr_filter == .open);
}

// A clone starts with no repository at all, and opens the one it makes. (A new
// repository is the dialog's other half, tested with its refusals below.)
test "a clone opens in a tab" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    var up_buf: [std.fs.max_path_bytes]u8 = undefined;
    const up = try std.fmt.bufPrint(&up_buf, "{s}/up", .{root});
    var down_buf: [std.fs.max_path_bytes]u8 = undefined;
    const down = try std.fmt.bufPrint(&down_buf, "{s}/down", .{root});

    try git.init();
    defer git.shutdown();
    try makeUpstreamPair(&tmp, root, up, down);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    var root_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    dialog_views.openRepoDialog(.clone);
    try dialog_views.dialog_url.appendSlice(app.gpa, try absPath(&abs_buf, up));
    dialog_views.dialog_parent.clearRetainingCapacity();
    try dialog_views.dialog_parent.appendSlice(app.gpa, try absPath(&root_abs_buf, root));
    try dialog_views.dialog_name.appendSlice(app.gpa, "cloned");
    repo_io.requestAction(.repo_dialog);
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(std.mem.endsWith(u8, app.repo_path.items, "cloned/"));
    try std.testing.expect(findCommit("upstream commit") != null);
    try std.testing.expect(findRef("origin/main") != null);
}

test "a leading tilde means home, and only a leading one" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = github_actions.homeDir() orelse return error.SkipZigTest;
    const got = github_actions.expandHome(&buf, "~/dev/x");
    try std.testing.expect(std.mem.startsWith(u8, got, home));
    try std.testing.expect(std.mem.endsWith(u8, got, "/dev/x"));
    try std.testing.expectEqualStrings("/abs/~/x", github_actions.expandHome(&buf, "/abs/~/x"));
    try std.testing.expectEqualStrings("rel", github_actions.expandHome(&buf, "rel"));
}

test "undo takes back a commit and a checkout, and undoing an undo redoes" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "second" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    github_actions.requestUndo();
    // The commit by its full sha: seven characters can be ambiguous.
    try std.testing.expectEqual(@as(usize, 40), repo_io.action_argv[2].len);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findCommit("second") == null);
    // Nothing lost: what the commit carried is staged again.
    try std.testing.expectEqual(@as(usize, 1), app.work.?.staged.len);

    github_actions.requestUndo();
    try std.testing.expect(repo_io.runAction());
    try std.testing.expect(findCommit("second") != null);
    try std.testing.expectEqual(@as(usize, 0), app.work.?.staged.len);

    // Switched outside Zit, at the same commit: the poll still notices, so
    // Undo takes back the switch and not the redo before it.
    try expectGit(dir, &.{ "switch", "-q", "-c", "elsewhere" });
    repo_io.poll();
    try std.testing.expectEqualStrings("elsewhere", app.history.?.head.?);
    github_actions.requestUndo();
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("main", app.history.?.head.?);

    // A reset outside Zit onto the commit HEAD is already on: same oid, same
    // branch, and still the move Undo has to see.
    try expectGit(dir, &.{ "reset", "-q", "HEAD" });
    repo_io.poll();
    try std.testing.expect(std.mem.startsWith(u8, app.history.?.last_move.?.message, "reset:"));
}

test "redo takes back the last undo, and only while nothing has moved since" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // Nothing undone yet: nothing to redo.
    github_actions.requestRedo();
    try std.testing.expect(tab_strip.command_error != null);
    github_actions.clearCommandError();

    github_actions.requestUndo();
    try std.testing.expect(repo_io.runAction());
    try std.testing.expect(findCommit("second") == null);
    github_actions.requestRedo();
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findCommit("second") != null);
    // Redone once; a second redo has nothing to take back.
    github_actions.requestRedo();
    try std.testing.expect(tab_strip.command_error != null);
    github_actions.clearCommandError();

    // Undone, then something else moves HEAD: the redo is gone with it.
    github_actions.requestUndo();
    try std.testing.expect(repo_io.runAction());
    try expectGit(dir, &.{ "commit", "-qm", "another" });
    repo_io.poll();
    try std.testing.expect(!github_actions.canRedo());
    github_actions.requestRedo();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expect(findCommit("second") == null);
    github_actions.clearCommandError();

    // From the toolbar: Redo beside Undo, deaf until an undo, then taking
    // it back, and deaf again.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:Redo"));
    try std.testing.expect(findCommit("another") != null);
    try clickAt(try tagCenter("toolbar:Undo"));
    try std.testing.expect(findCommit("another") == null);
    try std.testing.expect(github_actions.canRedo());
    try std.testing.expectEqualStrings("commit: another", github_actions.redo_what[0..github_actions.redo_what_len]);
    try clickAt(try tagCenter("toolbar:Redo"));
    try std.testing.expect(findCommit("another") != null);
    try std.testing.expect(!github_actions.canRedo());
}

test "with the integrations off, no pull requests, issues or GitHub account" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    defer tab_strip.integrations = true;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    pr.host = .github;
    defer pr.host = .none;
    window_chrome.me_loaded = true;
    app.active_view = .pulls;

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:user"));
    try std.testing.expect(dvui.tagGet("menu:Sign in with GitHub") != null);
    try pressFrame(.escape, .none);

    tab_strip.setIntegrations(false);
    try std.testing.expectEqual(pr.Host.none, pr.host);
    try std.testing.expectEqual(.graph, app.active_view);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("toolbar:user"));
    try std.testing.expect(dvui.tagGet("menu:Settings — Ctrl+,") != null);
    try std.testing.expect(dvui.tagGet("menu:Sign in with GitHub") == null);
}

test "a chord with Shift, AltGr or the Windows key is not the chord without" {
    const Mod = dvui.enums.Mod;
    const with = struct {
        fn f(mods: []const Mod) Mod {
            var m: u16 = 0;
            for (mods) |x| m |= @backingInt(x);
            return @fromBackingInt(@intCast(m));
        }
    }.f;
    const key = struct {
        fn f(code: dvui.enums.Key, mod: Mod) dvui.Event.Key {
            return .{ .code = code, .action = .down, .mod = mod };
        }
    }.f;
    try std.testing.expect(pr_editor.pressed(key(.z, .lcontrol), .z, true));
    try std.testing.expect(pr_editor.pressed(key(.z, .rcontrol), .z, true));
    // Ctrl+Shift+Z is the redo, not also the undo.
    try std.testing.expect(!pr_editor.pressed(key(.z, with(&.{ .lcontrol, .lshift })), .z, true));
    try std.testing.expect(pr_editor.pressedShift(key(.z, with(&.{ .lcontrol, .lshift })), .z));
    // AltGr, which Windows sends as Ctrl+Alt: neither.
    try std.testing.expect(!pr_editor.pressed(key(.z, with(&.{ .lcontrol, .ralt })), .z, true));
    try std.testing.expect(!pr_editor.pressedShift(key(.z, with(&.{ .lcontrol, .ralt, .lshift })), .z));
    try std.testing.expect(!pr_editor.pressed(key(.z, with(&.{ .lcontrol, .lcommand })), .z, true));
    // Shift+↓ selects text; it does not walk the history.
    try std.testing.expect(!pr_editor.pressed(key(.down, .lshift), .down, false));
}

test "commit messages: ticket, type, wrap and trailers" {
    try std.testing.expectEqualStrings("PROJ-80", commit_view.branchTicket("PROJ-80-Back-Login").?);
    try std.testing.expectEqualStrings("WEB-345", commit_view.branchTicket("feature/WEB-345-v1-login").?);
    try std.testing.expect(commit_view.branchTicket("main") == null);
    try std.testing.expect(commit_view.branchTicket("develop") == null);
    try std.testing.expect(commit_view.branchTicket("fix-X-1") == null);

    try std.testing.expectEqualStrings("api", commit_view.summaryScope("feat(api): add x").?);
    try std.testing.expect(commit_view.summaryScope("Merge (x): y") == null);
    try std.testing.expect(commit_view.summaryScope("fix: plain") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("PROJ-80: add x", try commit_view.composeSummary(a, "add x", null, "", "PROJ-80"));
    try std.testing.expectEqualStrings("feat(api): PROJ-80 add x", try commit_view.composeSummary(a, " add x ", "feat", "api", "PROJ-80"));
    try std.testing.expectEqualStrings("fix: PROJ-80 done", try commit_view.composeSummary(a, "PROJ-80 done", "fix", "", "PROJ-80"));
    try std.testing.expectEqualStrings("add x", try commit_view.composeSummary(a, "add x", null, "", null));

    try std.testing.expectEqualStrings("aaa bbb\nccc", try commit_view.wrapBody(a, "aaa bbb ccc", 7));
    try std.testing.expectEqualStrings("short\n\n- keep", try commit_view.wrapBody(a, "short\n\n- keep", 72));

    const authors = [_][]const u8{"Ann <ann@x.io>"};
    try std.testing.expectEqualStrings(
        "PROJ-1: s\n\nbody\n\nRefs: PROJ-2\nCo-authored-by: Ann <ann@x.io>",
        try commit_view.composeMessage(a, "PROJ-1: s", "body\n", true, "PROJ-2", &authors),
    );
    try std.testing.expectEqualStrings("s", try commit_view.composeMessage(a, "s", "  ", true, null, &.{}));
    // A ticket already in the summary is not repeated as a trailer.
    try std.testing.expectEqualStrings("PROJ-2 s", try commit_view.composeMessage(a, "PROJ-2 s", "", true, "PROJ-2", &.{}));
}

test "the palette finds commands by loose letters, and draws" {
    try std.testing.expect(command_palette.fuzzy("Push", "psh"));
    try std.testing.expect(command_palette.fuzzy("Pull, rebasing local commits", "pull reb"));
    try std.testing.expect(!command_palette.fuzzy("Fetch all remotes", "push"));
    try std.testing.expect(command_palette.fuzzy("anything", ""));

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    try style.applyEmbedded(app.gpa, true);

    command_palette.openPalette();
    try command_palette.palette_text.appendSlice(app.gpa, "theme");
    try dvui.testing.settle(app.appFrame);
    try std.testing.expect(command_palette.palette_open);
}

test "search terms: fields, dates, and path and code through git" {
    var buf: [graph_view.MAX_TERMS]graph_view.Term = undefined;
    const t = graph_view.parseQuery("fix author:\"Ann Lee\" after:2026-10-01 path:src/", &buf);
    try std.testing.expectEqual(@as(usize, 4), t.len);
    try std.testing.expectEqualStrings("Ann Lee", t[1].text);
    try std.testing.expectEqual(@as(i64, 1790812800), t[2].time);
    try std.testing.expect(t[3].kind == .path);
    try std.testing.expectEqual(@as(?i64, 0), graph_view.parseDay("1970-01-01"));
    try std.testing.expectEqual(@as(?i64, null), graph_view.parseDay("2026-02-31"));
    try std.testing.expect(graph_view.parseDay("2024-02-29") != null);
    // A date that is not one yet is left out, for both ends alike.
    try std.testing.expectEqual(@as(usize, 1), graph_view.parseQuery("before:2026- after:x fix", &buf).len);

    var win = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 600 } });
    defer win.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.createDirPath(app.app_io, "src");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "src/b.ts", .data = "const needle = 1;\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "add b" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    const commits = app.history.?.commits;

    try app.commit_filter.appendSlice(app.gpa, "author:zit msg:add");
    try std.testing.expect(matchesNow(commits[0]));
    try std.testing.expect(!matchesNow(commits[1]));

    inline for (.{ "path:b.ts", "code:needle" }) |query| {
        app.commit_filter.clearRetainingCapacity();
        try app.commit_filter.appendSlice(app.gpa, query);
        search_view.updateSearchHits();
        var waited: usize = 0;
        while (!search_view.search_hits.ready and waited < 500) : (waited += 1) {
            try std.Io.sleep(app.app_io, .fromMilliseconds(10), .awake);
            search_view.updateSearchHits();
        }
        try std.testing.expect(matchesNow(commits[0]));
        try std.testing.expect(!matchesNow(commits[1]));
    }

    // A commit made after the search is in it once the history is read again:
    // the hits for "code:needle" have landed, and the query does not change.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "src/b.ts", .data = "const needle = 1;\nconst needle2 = 2;\n" });
    try expectGit(dir, &.{ "commit", "-qam", "more needles" });
    repo_io.reloadHistory();
    var waited: usize = 0;
    search_view.updateSearchHits();
    while ((!search_view.search_hits.ready or search_view.search_hits.seq != graph_view.history_seq or search_view.search_hits.running != null) and waited < 500) : (waited += 1) {
        try std.Io.sleep(app.app_io, .fromMilliseconds(10), .awake);
        search_view.updateSearchHits();
    }
    try std.testing.expect(matchesNow(app.history.?.commits[0]));
    try std.testing.expectEqualStrings("more needles", app.history.?.commits[0].summary);

    // The whole sha finds it, not only its first seven.
    var hex: [41]u8 = undefined;
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.print(app.gpa, "sha:{s}", .{git.oidHex(app.history.?.commits[1].id, &hex)});
    try std.testing.expect(matchesNow(app.history.?.commits[1]));
    try std.testing.expect(!matchesNow(app.history.?.commits[0]));

    // ↓ goes to the next row shown, past the ones the search hides.
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "msg:e");
    app.selectCommit(app.history.?.commits[0].id);
    pr_editor.stepCommit(1);
    try std.testing.expect(git.oidEql(app.selection.commit, app.history.?.commits[2].id));
    app.clearSelection();

    // Let go of mid-search, as a tab switch does: nothing waits for it, and
    // it is freed once it is done.
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "code:needle2");
    search_view.updateSearchHits();
    try std.testing.expect(search_view.search_hits.running != null);
    search_view.clearSearchHits();
    try std.testing.expect(search_view.search_hits.running == null);
    waited = 0;
    while (search_view.search_retired.items.len > 0 and waited < 500) : (waited += 1) {
        try std.Io.sleep(app.app_io, .fromMilliseconds(10), .awake);
        search_view.reapSearchFetches(false);
    }
    try std.testing.expectEqual(@as(usize, 0), search_view.search_retired.items.len);

    // Typed over mid-search: the new one starts now, the old one retired.
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "code:needle2");
    search_view.updateSearchHits();
    try std.testing.expect(search_view.search_hits.running != null);
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "code:needle");
    search_view.updateSearchHits();
    const now = search_view.search_hits.running orelse return error.NoSearch;
    try std.testing.expectEqualStrings(search_view.search_hits.key.items, now.key);
    waited = 0;
    while ((!search_view.search_hits.ready or search_view.search_retired.items.len > 0) and waited < 500) : (waited += 1) {
        try std.Io.sleep(app.app_io, .fromMilliseconds(10), .awake);
        search_view.updateSearchHits();
    }
    try std.testing.expect(matchesNow(app.history.?.commits[0]));

    // Two paths would be git's OR: refused, and said why.
    app.commit_filter.clearRetainingCapacity();
    try app.commit_filter.appendSlice(app.gpa, "path:b.ts path:a.txt");
    search_view.updateSearchHits();
    try std.testing.expect(search_view.search_hits.ready and search_view.search_hits.err.items.len > 0);
    try std.testing.expect(!matchesNow(app.history.?.commits[1]));
}

test "showing one branch alone while scrolled far down does not crash" {
    var win = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 400 } });
    defer win.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for (0..30) |i| {
        var msg: [16]u8 = undefined;
        try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", try std.fmt.bufPrint(&msg, "c{d}", .{i}) });
    }
    try expectGit(dir, &.{ "branch", "short", "HEAD~29" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    // Scrolled to the bottom of 31 commits, then down to 2: the list once
    // asked for rows 25 to 2, a range that runs backwards.
    app.graph_scroll.viewport.y = 25 * style.graph_row;
    graph_view.setSolo("short");
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits.len);
}

test "a branch hidden from the graph stays hidden, and one can be shown alone" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "checkout", "-q", "-b", "side" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "on side" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "on main" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    try std.testing.expectEqual(@as(usize, 3), app.history.?.commits.len);

    graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "side");
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits.len);
    // Kept in the repository: read back as it would be on the next open.
    graph_view.loadGraphPrefs();
    try std.testing.expect(graph_view.isHidden("side"));

    graph_view.setSolo("side");
    try std.testing.expectEqual(@as(usize, 2), app.history.?.commits.len);
    try std.testing.expect(findCommit("on side") != null);
    try std.testing.expect(findCommit("on main") == null);
    graph_view.setSolo(null);

    graph_view.unhideAll();
    try std.testing.expectEqual(@as(usize, 3), app.history.?.commits.len);
    graph_view.loadGraphPrefs();
    try std.testing.expectEqual(@as(usize, 0), graph_view.graph_hidden.items.len);

    graph_view.toggleGraphPref(&graph_view.graph_pinned, "zit.pinned", "side");
    graph_view.loadGraphPrefs();
    try std.testing.expect(graph_view.hasName(graph_view.graph_pinned.items, "side"));

    // Compared with main, side brings b.txt — and not main's own c.txt,
    // which is after where the two parted.
    var side_tip: git.Oid = undefined;
    for (app.history.?.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "side")) side_tip = ref.target;
    }
    app.startCompare(app.history.?.head_oid.?, side_tip, "main", "side");
    app.ensureDiff();
    try std.testing.expectEqual(@as(usize, 1), app.diff.?.files.len);
    try std.testing.expectEqualStrings("b.txt", app.diff.?.files[0].path);
    app.clearSelection();
}

test "a file's history follows it back through a rename" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    // Enough content that git calls the move a rename, not a delete and an add.
    try makeTestRepo(&tmp, dir, "old.txt", TWELVE_LINES);
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "old.txt", .data = TWELVE_EDITED });
    try expectGit(dir, &.{ "commit", "-qam", "edit under the old name" });
    try expectGit(dir, &.{ "mv", "old.txt", "new.txt" });
    try expectGit(dir, &.{ "commit", "-qm", "rename" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "other.txt", .data = "x\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "unrelated" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    graph_view.showFileHistory("new.txt");
    const h = app.history.?;
    for ([_][]const u8{ "rename", "edit under the old name", "base" }) |summary| {
        const commit = findCommit(summary) orelse return error.CommitNotFound;
        try std.testing.expect(shownNow(commit, h.indexOf(commit.id).?));
    }
    const other = findCommit("unrelated") orelse return error.CommitNotFound;
    try std.testing.expect(!shownNow(other, h.indexOf(other.id).?));
}

test "changes picked together are stashed or staged together, and only they" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "b" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "a2\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b2\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "c.txt", .data = "new\n" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    try std.testing.expectEqual(@as(usize, 3), app.work.?.unstaged.len);

    // a and the new c stashed; b stays.
    commit_view.toggleChangePick(.unstaged, "a.txt");
    commit_view.toggleChangePick(.unstaged, "c.txt");
    try std.testing.expectEqual(@as(usize, 2), commit_view.pickedIn(.unstaged, app.work.?.unstaged));
    commit_view.requestPicked(.stash, .unstaged, app.work.?.unstaged);
    try std.testing.expectEqual(@as(usize, 0), commit_view.picked_changes.items.len);
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.work.?.unstaged.len);
    try std.testing.expectEqualStrings("b.txt", app.work.?.unstaged[0].path);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.stashes.len);

    // Back, then two of the three staged.
    rebase_view.requestStash("pop", app.history.?.stashes[0].id);
    try std.testing.expect(repo_io.runAction());
    try pumpJob();
    try std.testing.expectEqual(@as(usize, 3), app.work.?.unstaged.len);
    commit_view.toggleChangePick(.unstaged, "b.txt");
    commit_view.toggleChangePick(.unstaged, "c.txt");
    // Picking on the other side starts over.
    commit_view.toggleChangePick(.staged, "x");
    try std.testing.expectEqual(@as(usize, 0), commit_view.pickedIn(.unstaged, app.work.?.unstaged));
    commit_view.toggleChangePick(.unstaged, "b.txt");
    commit_view.toggleChangePick(.unstaged, "c.txt");
    commit_view.requestPicked(.stage, .unstaged, app.work.?.unstaged);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(usize, 2), app.work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 1), app.work.?.unstaged.len);
    try std.testing.expectEqualStrings("a.txt", app.work.?.unstaged[0].path);
}

test "picked lines of a new file go into the index alone" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "new.txt", .data = "one\ntwo\nthree\n" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    const r = app.repo orelse return error.RepoNotOpen;

    {
        var d = try r.readWorkDiff(app.gpa, .unstaged, "new.txt");
        defer d.deinit();
        const file = d.files[0];
        try std.testing.expectEqual(git.Status.added, file.status);
        for (file.lines, 0..) |l, i| {
            if (l.kind == .addition and !std.mem.eql(u8, l.text, "two")) rebase_view.togglePicked(i, file.lines.len);
        }
        rebase_view.requestLines(file, 0, .unstaged, false);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    const index = try run.capture(app.gpa, app.app_io, dir, &.{ "git", "show", ":new.txt" });
    defer app.gpa.free(index.out);
    try std.testing.expect(index.ok);
    // `capture` trims the last newline.
    try std.testing.expectEqualStrings("one\nthree", index.out);
}

test "picked lines are staged and unstaged alone" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "f.txt", "1\n2\n3\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "one\n2\nthree\n" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    const r = app.repo orelse return error.RepoNotOpen;

    // A pick outlives the poll's re-read of a file nobody touched, and goes
    // once the file does change.
    app.selectChange("f.txt", .unstaged);
    app.ensureDiff();
    rebase_view.togglePicked(1, app.diff.?.files[0].lines.len);
    repo_io.poll();
    app.ensureDiff();
    try std.testing.expect(rebase_view.isPicked(1));
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "one\n2\nthree\nfour\n" });
    repo_io.poll();
    app.ensureDiff();
    try std.testing.expect(!rebase_view.isPicked(1));
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "one\n2\nthree\n" });
    app.clearSelection();

    {
        var d = try r.readWorkDiff(app.gpa, .unstaged, "f.txt");
        defer d.deinit();
        const file = d.files[0];
        try std.testing.expectEqual(@as(u32, 1), file.hunk_count);
        // The first deletion and its addition: "1" -> "one".
        for (file.lines, 0..) |l, i| {
            if ((l.kind == .deletion and std.mem.eql(u8, l.text, "1")) or (l.kind == .addition and std.mem.eql(u8, l.text, "one"))) {
                rebase_view.togglePicked(i, file.lines.len);
            }
        }
        try std.testing.expectEqual(@as(usize, 2), rebase_view.pickedInHunk(file, 0));
        rebase_view.requestLines(file, 0, .unstaged, false);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);

    var staged = try run.git(app.gpa, app.app_io, dir, &.{ "diff", "--cached", "--quiet", "--", "f.txt" });
    staged.deinit(app.gpa);
    try std.testing.expect(!staged.ok);
    {
        var show = try r.readWorkDiff(app.gpa, .staged, "f.txt");
        defer show.deinit();
        var adds: usize = 0;
        for (show.files[0].lines) |l| {
            if (l.kind == .addition) {
                adds += 1;
                try std.testing.expectEqualStrings("one", l.text);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), adds);

        // And back out: the staged side, reversed.
        app.picked_lines.clearRetainingCapacity();
        for (show.files[0].lines, 0..) |l, i| {
            if (l.kind == .addition or l.kind == .deletion) rebase_view.togglePicked(i, show.files[0].lines.len);
        }
        rebase_view.requestLines(show.files[0], 0, .staged, false);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    var none = try r.readWorkDiff(app.gpa, .staged, "f.txt");
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.files.len);

    // A last line with no newline. The marker under it is part of the patch,
    // and picking only the line added after it makes the old last line gain a
    // newline — the marker must not end up in the middle of the hunk.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "1\n2\n3" });
    try expectGit(dir, &.{ "commit", "-qam", "no newline" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "1\n2\n3\n4\n" });
    {
        var d = try r.readWorkDiff(app.gpa, .unstaged, "f.txt");
        defer d.deinit();
        rebase_view.requestHunk(d.files[0], 0, .unstaged);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var d = try r.readWorkDiff(app.gpa, .staged, "f.txt");
        defer d.deinit();
        rebase_view.requestHunk(d.files[0], 0, .staged);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    {
        var d = try r.readWorkDiff(app.gpa, .unstaged, "f.txt");
        defer d.deinit();
        app.picked_lines.clearRetainingCapacity();
        for (d.files[0].lines, 0..) |l, i| {
            if (l.kind == .addition and std.mem.eql(u8, l.text, "4")) rebase_view.togglePicked(i, d.files[0].lines.len);
        }
        rebase_view.requestLines(d.files[0], 0, .unstaged, false);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    var nonl_rest = try r.readWorkDiff(app.gpa, .unstaged, "f.txt");
    defer nonl_rest.deinit();
    try std.testing.expectEqual(@as(usize, 0), nonl_rest.files.len);

    // CRLF: the `\r` stays in the patch, or it does not apply.
    try expectGit(dir, &.{ "reset", "-q" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "a\r\nb\r\n" });
    try expectGit(dir, &.{ "commit", "-qam", "crlf" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "a\r\nc\r\n" });
    {
        var d = try r.readWorkDiff(app.gpa, .unstaged, "f.txt");
        defer d.deinit();
        rebase_view.requestHunk(d.files[0], 0, .unstaged);
        try std.testing.expect(repo_io.runAction());
    }
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    var crlf_rest = try r.readWorkDiff(app.gpa, .unstaged, "f.txt");
    defer crlf_rest.deinit();
    try std.testing.expectEqual(@as(usize, 0), crlf_rest.files.len);

    // A staged rename is two paths, and unstaging takes back both.
    try expectGit(dir, &.{ "commit", "-qm", "c" });
    try expectGit(dir, &.{ "mv", "f.txt", "[g].txt" });
    repo_io.reloadWork();
    const moved = app.work.?.staged[0];
    try std.testing.expectEqualStrings("[g].txt", moved.path);
    try std.testing.expectEqualStrings("f.txt", moved.old_path);
    repo_io.request(&.{ "--literal-pathspecs", "reset", "-q", "--", moved.path, moved.old_path });
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(usize, 0), app.work.?.staged.len);

    // Which leaves it renamed on disk only. Discarding that brings the old
    // name back and takes the new one away — and `[g].txt` is a name, not a
    // glob that would also clean the untracked `g.txt` beside it.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "g.txt", .data = "decoy\n" });
    repo_io.reloadWork();
    const renamed = for (app.work.?.unstaged) |ch| {
        if (std.mem.eql(u8, ch.path, "[g].txt")) break ch;
    } else return error.RenameNotListed;
    try std.testing.expectEqual(git.Status.renamed, renamed.status);
    try std.testing.expectEqualStrings("f.txt", renamed.old_path);
    // Its diff is the rename too, not a new file with the old one lost.
    {
        var d = try app.repo.?.readWorkDiffFrom(app.gpa, .unstaged, renamed.path, renamed.old_path);
        defer d.deinit();
        try std.testing.expectEqual(@as(usize, 1), d.files.len);
        try std.testing.expectEqual(git.Status.renamed, d.files[0].status);
    }
    github_actions.doDiscard("[g].txt");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    const back = try tmp.dir.readFileAlloc(app.app_io, "f.txt", app.gpa, .limited(1 << 16));
    defer app.gpa.free(back);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(app.app_io, "[g].txt", app.gpa, .limited(1 << 16)));
    const decoy = try tmp.dir.readFileAlloc(app.app_io, "g.txt", app.gpa, .limited(1 << 16));
    defer app.gpa.free(decoy);
}

test "discarding everything stops at a restore that failed, and needs none for untracked files" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try tmp.dir.createDirPath(app.app_io, "ro");
    try makeTestRepo(&tmp, dir, "ro/f.txt", "f\n");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // A tracked edit git cannot write back — its folder read-only — beside an
    // untracked file: the error stays up, and the untracked file stays too.
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "ro/f.txt", .data = "edited\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "u.txt", .data = "u\n" });
    var ro_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ro = try std.fmt.bufPrint(&ro_buf, "{s}/ro", .{dir});
    try expectRun(&.{ "chmod", "555", ro });
    defer expectRun(&.{ "chmod", "755", ro }) catch {};
    repo_io.reloadWork();
    github_actions.doDiscard("");
    try std.testing.expect(tab_strip.command_error != null);
    const kept = try tmp.dir.readFileAlloc(app.app_io, "u.txt", app.gpa, .limited(64));
    app.gpa.free(kept);
    github_actions.clearCommandError();

    // Untracked files alone: nothing for `restore` to name, and no error for it.
    try expectRun(&.{ "chmod", "755", ro });
    try expectGit(dir, &.{ "checkout", "--", "ro/f.txt" });
    repo_io.reloadWork();
    github_actions.doDiscard("");
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(app.app_io, "u.txt", app.gpa, .limited(64)));
}

test "a worktree is added, listed, and removed" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/main", .{root});

    try git.init();
    defer git.shutdown();
    try expectGit(root, &.{ "init", "-q", "-b", "main", "main" });
    try expectGit(dir, &.{ "config", "user.email", "test@zync.invalid" });
    try expectGit(dir, &.{ "config", "user.name", "Zit Test" });
    try expectGit(dir, &.{ "config", "commit.gpgsign", "false" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "base" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    var line_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const wt = try absPath(&abs_buf, try std.fmt.bufPrint(&line_buf, "{s}/side", .{root}));
    var answer_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    github_actions.askName(.add_worktree, "");
    try answerPrompt(try std.fmt.bufPrint(&answer_buf, "{s} feature", .{wt}));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 1), app.history.?.worktrees.len);
    try std.testing.expect(findRef("feature") != null);

    github_actions.ask(.remove_worktree, app.history.?.worktrees[0].path);
    try answerConfirm();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqual(@as(usize, 0), app.history.?.worktrees.len);
}

test "the new repository dialog makes the folder, the first commit, and a tab" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = try absPath(&abs_buf, root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();
    tab_strip.loadWorkspace();

    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("https://github.com/me/zync.git"));
    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("git@github.com:me/zync"));
    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("C:\\src\\zync\\"));
    try std.testing.expectEqualStrings("zync", dialog_views.nameFromUrl("D:zync.git"));

    dialog_views.openRepoDialog(.create);
    try std.testing.expect(!dialog_views.dialogReady());
    dialog_views.dialog_parent.clearRetainingCapacity();
    try dialog_views.dialog_parent.appendSlice(app.gpa, abs_root);
    try dialog_views.dialog_name.appendSlice(app.gpa, "fresh");
    try std.testing.expect(dialog_views.dialogReady());

    // The dialog runs git in a folder with no config of its own, so the first
    // commit reads the global one: point that at a file of the test's, with an
    // identity and signing off, rather than at whoever runs the suite.
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/gitconfig", .{abs_root});
    try std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = cfg, .data = "[user]\n\temail = test@zync.invalid\n\tname = Zit Test\n[commit]\n\tgpgsign = false\n" });
    var env = try isolatedEnv(cfg, abs_root);
    defer env.deinit();
    run.env_override = &env;
    defer run.env_override = null;
    try std.testing.expect(dialog_views.dialog_readme);

    repo_io.requestAction(.repo_dialog);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(dialog_views.RepoDialog.none, dialog_views.repo_dialog);
    try std.testing.expect(app.repo != null);
    try std.testing.expect(std.mem.endsWith(u8, app.repo_path.items, "fresh/"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("main", app.history.?.head.?);
    try std.testing.expect(findCommit("Initial commit") != null);

    // The same name again: a folder with things in it is refused, not
    // initialised over, and keeps its single commit.
    dialog_views.openRepoDialog(.create);
    dialog_views.dialog_parent.clearRetainingCapacity();
    try dialog_views.dialog_parent.appendSlice(app.gpa, abs_root);
    try dialog_views.dialog_name.appendSlice(app.gpa, "fresh");
    repo_io.requestAction(.repo_dialog);
    _ = repo_io.runAction();
    try std.testing.expect(tab_strip.command_error != null);
    try std.testing.expectEqual(dialog_views.RepoDialog.create, dialog_views.repo_dialog);
    repo_io.reloadHistory();
    try std.testing.expectEqual(@as(usize, 1), app.history.?.commits.len);
    dialog_views.repo_dialog = .none;
}

test "a branch dropped onto another merges into it, or rebases onto it" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "switch", "-q", "-c", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "f.txt", .data = "f\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "feature work" });
    try expectGit(dir, &.{ "switch", "-q", "-c", "other", "main" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "o.txt", .data = "o\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "other work" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    // Merge feat into main, while other is checked out.
    graph_view.setDrop("feat", "main");
    graph_view.drop_action = .merge;
    repo_io.requestAction(.drop);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expectEqualStrings("main", app.history.?.head.?);
    try std.testing.expect(graph_view.drop == null);
    var feature_hex: [41]u8 = undefined;
    try expectGit(dir, &.{ "merge-base", "--is-ancestor", git.oidHex(findCommit("feature work").?.id, &feature_hex), "main" });

    // Rebase other onto main.
    graph_view.setDrop("other", "main");
    graph_view.drop_action = .rebase;
    repo_io.requestAction(.drop);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectGit(dir, &.{ "merge-base", "--is-ancestor", "main", "other" });

    // A remote branch rebases the local one tracking it, whatever its name,
    // and is refused when none does.
    try expectGit(dir, &.{ "remote", "add", "origin", "/nowhere" });
    try expectGit(dir, &.{ "update-ref", "refs/remotes/origin/up", "feat" });
    try expectGit(dir, &.{ "update-ref", "refs/remotes/origin/lone", "feat" });
    try expectGit(dir, &.{ "config", "branch.feat.remote", "origin" });
    try expectGit(dir, &.{ "config", "branch.feat.merge", "refs/heads/up" });
    repo_io.reloadHistory();
    graph_view.setDrop("origin/up", "other");
    graph_view.drop_action = .rebase;
    repo_io.requestAction(.drop);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try expectGit(dir, &.{ "merge-base", "--is-ancestor", "other", "feat" });
    graph_view.setDrop("origin/lone", "other");
    repo_io.requestAction(.drop);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expect(tab_strip.command_error != null);
}

// The gesture itself: press on one branch row, move across to another, let
// go. Nothing but driving the mouse says the button gave the capture up.
test "dragging a branch row onto another opens the drop menu where it was let go" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    // Folded by default; these rows are what the test works on.
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();

    // The dummy video driver has no system cursors and logs an error for every
    // cursor change, which fails the test; asking for the arrow last in every
    // frame means the cursor never changes.
    const frameArrow = struct {
        fn f() !dvui.App.Result {
            const r = try app.appFrame();
            dvui.currentWindow().cursor_requested = .arrow;
            dvui.currentWindow().dragging.cursor = null;
            return r;
        }
    }.f;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrow);

    const from = (dvui.tagGet("feat") orelse return error.TagNotFound).rect.center();
    const to = (dvui.tagGet("main") orelse return error.TagNotFound).rect.center();
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrow);
    // In steps, past the drag threshold and across the rows between.
    for (1..9) |i| {
        const f = @as(f32, @floatFromInt(i)) / 8;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + (to.x - from.x) * f, .y = from.y + (to.y - from.y) * f } });
        _ = try dvui.testing.step(frameArrow);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrow);

    const d = graph_view.drop orelse return error.NoDrop;
    try std.testing.expectEqualStrings("feat", d.source);
    try std.testing.expectEqualStrings("main", d.target);

    // Its two answers, in a menu by the row it fell on; Esc lets it be.
    {
        const merge = try tagRect("menu:Merge feat into main");
        _ = try tagRect("menu:Rebase feat onto main");
        try std.testing.expect(@abs(merge.y - to.y) < 40);
    }
    try pressFrame(.escape, .none);
    try std.testing.expect(graph_view.drop == null);
    try expectNoTag("menu:Merge feat into main");

    // As does a click outside it.
    graph_view.setDrop("feat", "main");
    graph_view.drop_at = to.toNatural();
    try dvui.testing.settle(frameArrow);
    {
        const menu = try tagRect("menu:Merge feat into main");
        try clickAt(.{ .x = menu.x + menu.w + 200, .y = menu.y + 200 });
    }
    try std.testing.expect(graph_view.drop == null);
    try expectNoTag("menu:Merge feat into main");

    // And one of its rows does what it says.
    graph_view.setDrop("feat", "main");
    graph_view.drop_at = to.toNatural();
    try dvui.testing.settle(frameArrow);
    try clickAt(try tagCenter("menu:Merge feat into main"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(graph_view.drop == null);
    try expectNoTag("menu:Merge feat into main");
}

/// The allocator a test runs Zit on, counting what goes through it.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len) self.allocs += 1;
        return self.child.rawResize(mem, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawRemap(mem, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
    }
};

// Idle is a frame drawn again with nothing changed — the mouse over the
// window, a poll that found nothing. It may use the frame's arena, which dvui
// keeps; it must not go to the heap.
test "a frame drawn again with nothing changed allocates nothing" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    app.gpa = counting.allocator();
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try expectGit(dir, &.{ "branch", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    // A commit picked, its diff open: the busiest screen idle can be.
    try clickAt(try commitCenter("second"));
    try dvui.testing.settle(frameArrowCursor);

    const before = counting.allocs;
    // It does count: opening the repository went through it.
    try std.testing.expect(before > 0);
    for (0..5) |_| _ = try dvui.testing.step(frameArrowCursor);
    try std.testing.expectEqual(before, counting.allocs);
}

// The same, on the screens added since: a filter narrowing the history, a
// dialog waiting for a name, a toast waiting for a yes.
test "a frame drawn again allocates nothing, a filter on, a dialog or a toast up" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    app.gpa = counting.allocator();
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try expectGit(dir, &.{ "-c", "user.name=Ann", "-c", "user.email=ann@x.invalid", "commit", "-q", "--allow-empty", "-m", "by ann" });
    try expectGit(dir, &.{ "branch", "feat" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const Idle = struct {
        /// Heap allocations over five frames once nothing more is asked.
        fn allocs(c: *CountingAllocator) !usize {
            try dvui.testing.settle(frameArrowCursor);
            const before = c.allocs;
            for (0..5) |_| _ = try dvui.testing.step(frameArrowCursor);
            return c.allocs - before;
        }
    };
    var found: [4]usize = undefined;
    // One author's commits alone.
    graph_view.onlyAuthor((graph_view.authorByKey("Ann\nann@x.invalid") orelse return error.AuthorMissing).key);
    found[0] = try Idle.allocs(&counting);
    graph_view.clearAuthors();
    // A search typed into the commit filter.
    app.commit_filter.appendSlice(app.gpa, "second") catch unreachable;
    found[1] = try Idle.allocs(&counting);
    app.commit_filter.clearRetainingCapacity();
    // A dialog asking for a name.
    github_actions.askNameWith(.rename_branch, "feat", "feat");
    found[2] = try Idle.allocs(&counting);
    github_actions.clearPrompt();
    // A toast asking for a yes. Its first frames are its first draw —
    // dvui setting its window up, 2 allocations — so the next five count.
    github_actions.ask(.discard, "a.txt");
    _ = try Idle.allocs(&counting);
    found[3] = try Idle.allocs(&counting);
    github_actions.clearConfirm();

    if (!std.mem.allEqual(usize, &found, 0)) {
        std.debug.print("heap allocations over 5 idle frames: author filter {d}, search {d}, dialog {d}, toast {d}\n", .{ found[0], found[1], found[2], found[3] });
        return error.FramesAllocate;
    }
}

// The mouse swept over every part of the window, then left alone: the frames
// it asked for stop within a few, not 100 later — no hover that keeps
// drawing, no widget whose size goes back and forth.
test "after the mouse has swept the window, frames stop" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);
    repo_io.stillUi();
    defer {
        dvui.reduce_motion = false;
        dvui.hover_fade_secs = 0.12;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try expectGit(dir, &.{ "branch", "feat" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const cw = dvui.currentWindow();
    const size = dvui.windowRectPixels();
    var y: f32 = 5;
    while (y < size.h) : (y += 70) {
        var x: f32 = 5;
        while (x < size.w) : (x += 110) {
            _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
            _ = try dvui.testing.step(frameArrowCursor);
        }
    }
    // Left where it is: a frame or two for what the last move lit.
    var frames: usize = 0;
    while (frames < 100) : (frames += 1) {
        const wait = try dvui.testing.step(frameArrowCursor);
        if (wait == null or wait.? != 0) break;
    }
    try std.testing.expect(frames < 5);
}

test "opening and closing everything, again and again, leaks nothing" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try commitFile(&tmp, dir, "b.txt", "second");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "changed\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "new.txt", .data = "new\n" });

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    for (0..3) |_| {
        app.openRepo(dir);
        try dvui.testing.settle(frameArrowCursor);
        // A commit, its files, one of them whole, all the tree; a change;
        // the search; a pick of changes; a ref hidden and shown.
        const head = app.history.?.commits[0].id;
        app.selectCommit(head);
        commit_view.commit_all_files = true;
        try dvui.testing.settle(frameArrowCursor);
        app.selectCommitFile(head, "a.txt");
        try dvui.testing.settle(frameArrowCursor);
        app.selectChange("a.txt", .unstaged);
        commit_view.toggleChangePick(.unstaged, "new.txt");
        app.commit_filter.appendSlice(app.gpa, "second") catch unreachable;
        try dvui.testing.settle(frameArrowCursor);
        app.commit_filter.clearRetainingCapacity();
        graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "main");
        graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "main");
        try dvui.testing.settle(frameArrowCursor);
        // The views since: one author's commits, a dialog, a toast.
        graph_view.onlyAuthor((graph_view.authorByKey("Zit Test\ntest@zync.invalid") orelse return error.AuthorMissing).key);
        try dvui.testing.settle(frameArrowCursor);
        graph_view.clearAuthors();
        github_actions.askNameWith(.rename_branch, "main", "main");
        try dvui.testing.settle(frameArrowCursor);
        github_actions.clearPrompt();
        github_actions.ask(.discard, "a.txt");
        try dvui.testing.settle(frameArrowCursor);
        github_actions.clearConfirm();
        try dvui.testing.settle(frameArrowCursor);
        dialog_views.closeRepo();
        try dvui.testing.settle(frameArrowCursor);
    }
}

test "a search fades the commits it leaves out, and the arrows go match to match" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for ([_][]const u8{ "one fix", "two", "three fix" }) |msg| {
        try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", msg });
    }
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    app.commit_filter.appendSlice(app.gpa, "fix") catch unreachable;
    try dvui.testing.settle(frameArrowCursor);

    // "two" is still in the graph, in its place.
    const h = app.history.?;
    var short: [8]u8 = undefined;
    const two = h.commits[1];
    try std.testing.expectEqualStrings("two", two.summary);
    var tag_buf: [16]u8 = undefined;
    try std.testing.expect(dvui.tagGet(try std.fmt.bufPrint(&tag_buf, "commit:{s}", .{git.oidShort(two.id, &short)})) != null);
    try std.testing.expectEqual(@as(usize, 2), graph_view.list_matches);

    pr_editor.stepCommit(1);
    try std.testing.expectEqualStrings("three fix", diff_view.commitSummary(app.selection.commit));
    pr_editor.stepCommit(1);
    try std.testing.expectEqualStrings("one fix", diff_view.commitSummary(app.selection.commit));
    // From a commit the search leaves out, the next match that way.
    app.selectCommit(two.id);
    pr_editor.stepCommit(-1);
    try std.testing.expectEqualStrings("three fix", diff_view.commitSummary(app.selection.commit));
}

// A commit picked lists its files without reading their lines — over
// thousands of files, reading them all froze the window for seconds — and
// one file opened is read alone.
test "a commit's files are listed without their lines, and the file open read alone" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "b.txt", .data = "b\nbb\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "c.txt", .data = "c\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "two more" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    const head = app.history.?.commits[0].id;

    var listed = try app.repo.?.readCommitDiffLines(app.gpa, head, .none);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 2), listed.files.len);
    for (listed.files) |f| {
        try std.testing.expectEqual(git.Status.added, f.status);
        try std.testing.expectEqual(@as(usize, 0), f.lines.len);
    }

    // Picked: its two files listed, no line read.
    app.selectCommit(head);
    app.ensureDiff();
    try std.testing.expectEqual(@as(usize, 2), app.diff_all.len);
    for (app.diff_all) |f| try std.testing.expectEqual(@as(usize, 0), f.lines.len);
    // One opened: its hunk header and its two lines, the list still whole.
    app.selectCommitFile(head, "b.txt");
    app.ensureDiff();
    try std.testing.expectEqual(@as(usize, 1), app.diff.?.files.len);
    try std.testing.expectEqualStrings("b.txt", app.diff.?.files[0].path);
    try std.testing.expectEqual(@as(usize, 3), app.diff.?.files[0].lines.len);
    try std.testing.expectEqual(@as(usize, 2), app.diff_all.len);
}

test "a commit's files: all of its tree, and an unchanged one read whole" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "first\nsecond\n");
    try tmp.dir.createDirPath(app.app_io, "sub");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "sub/b.txt", .data = "b\n" });
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "add b" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    const head = app.history.?.commits[0].id;
    app.selectCommit(head);
    app.ensureDiff();
    try std.testing.expectEqual(@as(usize, 1), app.diff_all.len);

    commit_view.loadTreeFiles(head);
    try std.testing.expectEqual(@as(usize, 2), commit_view.tree_files.paths.len);
    try std.testing.expectEqualStrings("a.txt", commit_view.tree_files.paths[0]);
    try std.testing.expectEqualStrings("sub/b.txt", commit_view.tree_files.paths[1]);
    try std.testing.expectEqual(git.Status.unchanged, commit_view.tree_files.status[0]);
    try std.testing.expectEqual(git.Status.added, commit_view.tree_files.status[1]);

    // The one it did not change: the file as it stood, every line context.
    app.selectCommitFile(head, "a.txt");
    app.ensureDiff();
    const f = app.diff.?.files[0];
    try std.testing.expectEqual(git.Status.unchanged, f.status);
    try std.testing.expectEqual(@as(usize, 2), f.lines.len);
    try std.testing.expectEqualStrings("second", f.lines[1].text);
    // The commit's own list is still its changes.
    try std.testing.expectEqual(@as(usize, 1), app.diff_all.len);
}

test "dragging a branch's tag in the graph onto another opens the drop menu" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    defer graph_view.clearDrop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "checkout", "-q", "-b", "feat" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on feat" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const from = try tagCenter("ref:feat");
    const to = try tagCenter("ref:main");
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    for (1..9) |i| {
        const f = @as(f32, @floatFromInt(i)) / 8;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + (to.x - from.x) * f, .y = from.y + (to.y - from.y) * f } });
        _ = try dvui.testing.step(frameArrowCursor);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrowCursor);

    const d = graph_view.drop orelse return error.NoDrop;
    try std.testing.expectEqualStrings("feat", d.source);
    try std.testing.expectEqualStrings("main", d.target);

    // A press on a tag that never moves is a click on its commit.
    graph_view.clearDrop();
    try clickAt(try tagCenter("ref:feat"));
    try std.testing.expect(graph_view.drop == null);
    try std.testing.expectEqualStrings("on feat", diff_view.commitSummary(app.selection.commit));
}

test "a long list of changes is built a screenful at a time, scrolls, and leaves the commit box in sight" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "staged.txt", .data = "s\n" });
    try expectGit(dir, &.{ "add", "staged.txt" });
    try tmp.dir.createDirPath(app.app_io, "src");
    const n = 600;
    for (0..n) |i| {
        var name: [32]u8 = undefined;
        try tmp.dir.writeFile(app.app_io, .{ .sub_path = try std.fmt.bufPrint(&name, "src/f-{d:0>4}.txt", .{i}), .data = "x\n" });
    }
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    repo_io.reloadWork();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, n), app.work.?.unstaged.len);

    // The commit box in the window, under the staged file.
    const button = try tagRect("commit_button");
    try std.testing.expect(button.y + button.h <= dvui.windowRectPixels().h);
    _ = try tagCenter("staged:staged.txt");
    // The first files built, the last not.
    _ = try tagCenter("unstaged:src/f-0000.txt");
    try expectNoTag("unstaged:src/f-0599.txt");

    // Its title folds it, as a sidebar section's does, and opens it again;
    // the staged list stays.
    try clickAt(try tagCenter("fold:unstaged"));
    try expectNoTag("unstaged:src/f-0000.txt");
    _ = try tagCenter("staged:staged.txt");
    try clickAt(try tagCenter("fold:unstaged"));
    _ = try tagCenter("unstaged:src/f-0000.txt");

    // Scrolled to the end: the last file, and the commit box where it was.
    commit_view.changes_scroll[0].viewport.y = commit_view.changes_scroll[0].scrollMax(.vertical);
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagCenter("unstaged:src/f-0599.txt");
    try std.testing.expectEqual(button.y, (try tagRect("commit_button")).y);

    // Most of them staged while it is scrolled to its end: the shorter list
    // draws, still scrolled past its end for a frame.
    try expectGit(dir, &.{ "add", "src/f-00*", "src/f-01*", "src/f-02*", "src/f-03*", "src/f-04*" });
    repo_io.reloadWork();
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, 100), app.work.?.unstaged.len);
    // The file at the top of what is in view is drawn: f-0500 is row 0 now.
    {
        const in_view: usize = @intFromFloat(@ceil(commit_view.changes_scroll[0].viewport.y / style.row_height));
        try std.testing.expect(in_view < 100);
        var name: [40]u8 = undefined;
        _ = try tagCenter(try std.fmt.bufPrint(&name, "unstaged:src/f-{d:0>4}.txt", .{500 + in_view}));
    }

    // The tree: the folder's line first, the files set in under it.
    app.changes_view = .tree;
    defer app.changes_view = .path;
    commit_view.changes_scroll[0].viewport.y = 0;
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqual(@as(usize, 100 + 1), commit_view.changeRows(0, app.work.?.unstaged));
    const folder = try tagRect("unstaged:src/");
    const file = try tagRect("unstaged:src/f-0500.txt");
    try std.testing.expect(file.y > folder.y);

    // Folded by a click: one line, its files gone.
    try clickAt(.{ .x = folder.x + 40, .y = folder.y + folder.h / 2 });
    try std.testing.expectEqual(@as(usize, 1), commit_view.changeRows(0, app.work.?.unstaged));
    try expectNoTag("unstaged:src/f-0500.txt");

    // Its + stages the whole folder.
    try clickAt(.{ .x = folder.x + folder.w - 16, .y = folder.y + folder.h / 2 });
    try pumpJob();
    try std.testing.expectEqual(@as(usize, 0), app.work.?.unstaged.len);
    try std.testing.expectEqual(@as(usize, n + 1), app.work.?.staged.len);
}

test "a tree lists a folder's folders before its files, each by name, with what is in them" {
    app.gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const paths = [_][]const u8{ "b.txt", "a/z.txt", "a/b/c.txt", "A.md", "a/b/d.txt", "c/e.txt", "x/y/z/w.txt", "x/y/z/v.txt" };
    const rows = try commit_view.treeRows(arena.allocator(), &paths);

    const want = [_]struct { u16, []const u8, ?u32, u32, u32 }{
        .{ 0, "a", null, 4, 3 },
        .{ 1, "b", null, 2, 2 },
        .{ 2, "c.txt", 2, 0, 0 },
        .{ 2, "d.txt", 4, 0, 0 },
        .{ 1, "z.txt", 1, 0, 0 },
        .{ 0, "c", null, 1, 1 },
        .{ 1, "e.txt", 5, 0, 0 },
        // Folders holding one folder and nothing else: one line.
        .{ 0, "x/y/z", null, 2, 2 },
        .{ 1, "v.txt", 7, 0, 0 },
        .{ 1, "w.txt", 6, 0, 0 },
        .{ 0, "A.md", 3, 0, 0 },
        .{ 0, "b.txt", 0, 0, 0 },
    };
    try std.testing.expectEqual(want.len, rows.len);
    for (want, rows) |w, r| {
        try std.testing.expectEqual(w[0], r.depth);
        try std.testing.expectEqualStrings(w[1], r.name);
        try std.testing.expectEqual(w[2], r.file);
        try std.testing.expectEqual(w[3], r.inside);
        try std.testing.expectEqual(w[4], r.files);
    }
    try std.testing.expectEqualStrings("a/b", rows[1].path);
    // Folded by the deepest of them.
    try std.testing.expectEqualStrings("x/y/z", rows[7].path);

    // Folding "a" hides its four lines; the next shown is "c".
    var folded: std.StringHashMapUnmanaged(void) = .empty;
    defer folded.deinit(app.gpa);
    try folded.put(app.gpa, "a", {});
    var it: commit_view.TreeShown = .{ .rows = rows, .folded = &folded };
    try std.testing.expectEqualStrings("a", it.next().?.row.name);
    const c = it.next().?;
    try std.testing.expectEqualStrings("c", c.row.name);
    // The files folded away still count toward the next one's place.
    try std.testing.expectEqual(@as(u32, 3), c.pos);
}

test "a branch's name sits in the branch column, and dragging the column's edge shows more of it" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const name = "feature/a-branch-with-a-name-longer-than-its-column";
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "checkout", "-q", "-b", name });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on the branch" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // In the column, from its left, cut to it.
    const head = (dvui.tagGet("header:branches") orelse return error.TagNotFound).rect;
    const before = (dvui.tagGet("ref:" ++ name) orelse return error.TagNotFound).rect;
    try std.testing.expect(before.x >= head.x and before.x - head.x < 8);
    try std.testing.expect(before.x + before.w <= head.x + head.w);

    // The column's right edge, dragged to the right.
    const from: dvui.Point.Physical = .{ .x = head.x + head.w, .y = head.y + head.h / 2 };
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    for (1..9) |i| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + 15 * @as(f32, @floatFromInt(i)), .y = from.y } });
        _ = try dvui.testing.step(frameArrowCursor);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrowCursor);

    try std.testing.expect(search_view.branch_width > search_view.BRANCH_DEFAULT_W + 60);
    const after = (dvui.tagGet("ref:" ++ name) orelse return error.TagNotFound).rect;
    try std.testing.expect(after.w > before.w + 60);
    const wider = (dvui.tagGet("header:branches") orelse return error.TagNotFound).rect;
    try std.testing.expect(after.x + after.w <= wider.x + wider.w);
}

test "a hidden branch leaves the graph with its remote copy, and a hidden tag's name goes" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    // The tag alone on its commit, main moved on past it.
    try expectGit(dir, &.{ "tag", "v1" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "second" });
    try expectGit(dir, &.{ "checkout", "-q", "-b", "feat" });
    try expectGit(dir, &.{ "commit", "-q", "--allow-empty", "-m", "on feat" });
    try expectGit(dir, &.{ "checkout", "-q", "main" });
    // Pushed: its remote copy at the same commit, and tracked.
    try expectGit(dir, &.{ "remote", "add", "origin", "https://example.invalid/zit.git" });
    try expectGit(dir, &.{ "update-ref", "refs/remotes/origin/feat", "feat" });
    try expectGit(dir, &.{ "branch", "-q", "-u", "origin/feat", "feat" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(findCommit("on feat") != null);
    _ = try tagCenter("ref:feat");
    _ = try tagCenter("ref:v1");

    // Its eye: the branch out, its remote copy with it — the commit only
    // they reach gone, and neither name drawn.
    graph_view.toggleHidden(findRef("feat") orelse return error.BranchNotListed);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(graph_view.isHidden("feat") and graph_view.isHidden("origin/feat"));
    try std.testing.expect(findCommit("on feat") == null);
    try expectNoTag("ref:feat");
    try expectNoTag("ref:origin/feat");

    // Back, both.
    graph_view.toggleHidden(findRef("feat") orelse return error.BranchNotListed);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(!graph_view.isHidden("feat") and !graph_view.isHidden("origin/feat"));
    try std.testing.expect(findCommit("on feat") != null);
    _ = try tagCenter("ref:feat");

    // A tag hidden: its commit is main's too and stays, its name does not.
    graph_view.toggleHidden(findRef("v1") orelse return error.TagNotListed);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(findCommit("base") != null);
    try expectNoTag("ref:v1");
}

test "the sidebar's eyes hide one ref or a whole section, and its ⋯ opens the menu" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try expectGit(dir, &.{ "branch", "feat" });
    try expectGit(dir, &.{ "branch", "side" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    try clickAt(try tagCenter("eye:feat"));
    try std.testing.expect(graph_view.isHidden("feat"));
    try clickAt(try tagCenter("eye:feat"));
    try std.testing.expect(!graph_view.isHidden("feat"));

    // The whole section out — the branch checked out stays — then back,
    // from the section's menu.
    try hoverAt(try tagCenter("section:LOCAL"));
    try clickAt(try tagCenter("section-more:LOCAL"));
    try clickAt(try tagCenter("menu:Hide all the branches from the graph"));
    try std.testing.expect(graph_view.isHidden("feat"));
    try std.testing.expect(graph_view.isHidden("side"));
    try std.testing.expect(!graph_view.isHidden("main"));
    try hoverAt(try tagCenter("section:LOCAL"));
    try clickAt(try tagCenter("section-more:LOCAL"));
    try clickAt(try tagCenter("menu:Show all the branches in the graph"));
    try std.testing.expectEqual(@as(usize, 0), graph_view.graph_hidden.items.len);

    try hoverAt(try tagCenter("feat"));
    try clickAt(try tagCenter("more:feat"));
    try std.testing.expect(dvui.tagGet("menu:Check out") != null);
    try pressFrame(.escape, .none);

    // A section header's ⋯ opens its right-click menu too, and the section
    // stays folded or open as it was.
    const open = diff_view.section_collapsed[@backingInt(diff_view.Section.local)];
    try hoverAt(try tagCenter("section:LOCAL"));
    try clickAt(try tagCenter("section-more:LOCAL"));
    _ = try tagCenter("menu:New branch here");
    try std.testing.expectEqual(open, diff_view.section_collapsed[@backingInt(diff_view.Section.local)]);
    try pressFrame(.escape, .none);

    // Signing, flipped beside the commit's title.
    const was = app.commit_prefs.sign;
    try clickAt(try tagCenter("commit:sign"));
    try std.testing.expect(app.commit_prefs.sign != was);
    app.commit_prefs.sign = was;
}

// A section of many branches builds only the lines on screen: scrolled to
// its end, the last branch is there and the first is not — and the hidden
// ones, a set, are still told apart.
test "a long section builds the lines it shows, wherever it is scrolled" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    // b00 … b59: sorted by name, b59 last.
    for (0..60) |i| {
        var name_buf: [8]u8 = undefined;
        try expectGit(dir, &.{ "branch", try std.fmt.bufPrint(&name_buf, "b{d:0>2}", .{i}) });
    }
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    graph_view.toggleGraphPref(&graph_view.graph_hidden, "zit.hidden", "b59");
    try std.testing.expect(graph_view.isHidden("b59") and !graph_view.isHidden("b58"));

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(dvui.tagGet("b00") != null);
    try std.testing.expect(dvui.tagGet("b59") == null);

    const si = &rebase_view.section_scroll[@backingInt(diff_view.Section.local)];
    si.viewport.y = si.virtual_size.h;
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(dvui.tagGet("b59") != null);
    try std.testing.expect(dvui.tagGet("b00") == null);
    // Its eye says hidden, from the set.
    try std.testing.expect(dvui.tagGet("eye:b59") != null);
}

test "dragging a tab onto another moves it there" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();

    tab_strip.loadWorkspace();
    var bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "a", "b", "c" }, 0..) |name, i| {
        try expectGit(root, &.{ "init", "-q", "-b", "main", name });
        tab_strip.openAndRemember(try std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ root, name }));
    }

    // See "dragging a branch row onto another opens the drop menu where it was let go".
    const frameArrow = struct {
        fn f() !dvui.App.Result {
            const r = try app.appFrame();
            dvui.currentWindow().cursor_requested = .arrow;
            dvui.currentWindow().dragging.cursor = null;
            return r;
        }
    }.f;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrow);

    const from = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect.center();
    const to = (dvui.tagGet("tab:2") orelse return error.TagNotFound).rect.center();
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrow);
    for (1..9) |i| {
        const f = @as(f32, @floatFromInt(i)) / 8;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x + (to.x - from.x) * f, .y = from.y } });
        _ = try dvui.testing.step(frameArrow);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrow);

    const tabs = tab_strip.groups.items[0].tabs.items;
    try std.testing.expectEqualStrings("b", git.repoName(tabs[0].path));
    try std.testing.expectEqualStrings("c", git.repoName(tabs[1].path));
    try std.testing.expectEqualStrings("a", git.repoName(tabs[2].path));
    try std.testing.expectEqualStrings("c", app.repo_name);
}

// More tabs than the strip is wide: they scroll in what the strip leaves
// them, the window's own buttons stay in the window, and a tab switched to
// out of sight is scrolled to.
test "more tabs than fit scroll, and leave the window's buttons where they are" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();

    tab_strip.loadWorkspace();
    const names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa" };
    var bufs: [names.len][std.fs.max_path_bytes]u8 = undefined;
    for (names, 0..) |name, i| {
        try expectGit(root, &.{ "init", "-q", "-b", "main", name });
        tab_strip.openAndRemember(try std.fmt.bufPrint(&bufs[i], "{s}/{s}", .{ root, name }));
    }

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 700, .h = 600 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    const close = (dvui.tagGet("window:close") orelse return error.TagNotFound).rect;
    try std.testing.expect(close.x + close.w <= dvui.windowRectPixels().w);
    const controls = (dvui.tagGet("window:minimise") orelse return error.TagNotFound).rect;

    // The last opened is the active one, and in sight: the strip scrolled to it.
    const last = (dvui.tagGet("tab:9") orelse return error.TagNotFound).rect;
    try std.testing.expect(last.x >= 0 and last.x + last.w <= controls.x);
    const first_before = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect;
    try std.testing.expect(first_before.x < 0);

    // Ctrl+Tab goes round to the first, scrolled back into sight.
    try pressFrame(.tab, .lcontrol);
    try std.testing.expectEqualStrings("alpha", app.repo_name);
    const first = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect;
    try std.testing.expect(first.x >= 0 and first.x + first.w <= controls.x);
}

// The seam is only a 1px line and the cursor, no grab handle; it must still
// drag.
test "the sidebar seam still drags" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    // Folded by default; these rows are what the test works on.
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    const frameArrow = struct {
        fn f() !dvui.App.Result {
            const r = try app.appFrame();
            dvui.currentWindow().cursor_requested = .arrow;
            dvui.currentWindow().dragging.cursor = null;
            return r;
        }
    }.f;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrow);

    // The seam is just right of the sidebar: find it from a branch row,
    // which spans the sidebar's width.
    const before = app.sidebar_split;
    const field = (dvui.tagGet("main") orelse return error.TagNotFound).rect;
    const cw = dvui.currentWindow();
    // Right of the field by its margin is the seam.
    var x = field.x + field.w;
    const y = field.y + 200;
    // Sweep right until a press there starts dragging the split.
    var moved = false;
    for (0..40) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
        _ = try cw.addEventMouseButton(.left, .press);
        _ = try dvui.testing.step(frameArrow);
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x + 60, .y = y } });
        _ = try dvui.testing.step(frameArrow);
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x + 120, .y = y } });
        _ = try dvui.testing.step(frameArrow);
        _ = try cw.addEventMouseButton(.left, .release);
        _ = try dvui.testing.step(frameArrow);
        if (app.sidebar_split != before) {
            moved = true;
            break;
        }
        x += 1;
    }
    try std.testing.expect(moved);
    try std.testing.expect(app.sidebar_split > before);
}

// The asynchronous first read, which the app uses and the rest of the suite
// does not: it lands, it is the history that was asked for, and the loading
// screen draws while it is out.
test "a history read off the UI thread lands in place of the loading screen" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    if (app.history) |*h| h.deinit();
    app.history = null;
    if (app.lanes) |*l| l.deinit();
    app.lanes = null;

    // Asked for twice, as a quick tab switch does: the first is not awaited
    // but left to finish, and freed once it has.
    graph_view.startHistoryLoad();
    graph_view.startHistoryLoad();
    defer {
        graph_view.history_retired.deinit(app.gpa);
        graph_view.history_retired = .empty;
    }
    try std.testing.expect(repo_io.historyLoading());
    {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
        defer t.deinit();
        try style.applyEmbedded(app.gpa, true);
        // The loading screen refreshes itself, so this is a frame, not a settle.
        _ = try dvui.testing.step(app.appFrame);
    }

    var waited: usize = 0;
    while ((graph_view.collectHistoryLoad() or graph_view.history_retired.items.len > 0) and waited < 500) : (waited += 1) {
        try std.Io.sleep(app.app_io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(graph_view.history_load == null);
    try std.testing.expectEqual(@as(usize, 0), graph_view.history_retired.items.len);
    try std.testing.expect(findCommit("base") != null);
    try std.testing.expect(app.lanes != null);
}

test "the identity dialog saves a name and email to the global config" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = try absPath(&abs_buf, root);

    // A global config of the test's own, empty: a machine nobody set up.
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/gitconfig", .{abs_root});
    try std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = cfg, .data = "" });
    var env = try isolatedEnv(cfg, abs_root);
    defer env.deinit();
    run.env_override = &env;
    defer run.env_override = null;

    try std.testing.expect(!identity_view.identitySet());
    identity_view.openIdentity();
    try std.testing.expect(identity_view.identity_open);

    // Half of it is refused, and the dialog stays.
    try identity_view.identity_name.appendSlice(app.gpa, "Ada Lovelace");
    identity_view.saveIdentity();
    try std.testing.expect(identity_view.identity_open);

    try identity_view.identity_email.appendSlice(app.gpa, "ada@example.com");
    identity_view.saveIdentity();
    try std.testing.expect(!identity_view.identity_open);
    try std.testing.expect(identity_view.identitySet());

    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(app.gpa);
    var email: std.ArrayList(u8) = .empty;
    defer email.deinit(app.gpa);
    try std.testing.expect(identity_view.readIdentity(&name, &email));
    try std.testing.expectEqualStrings("Ada Lovelace", name.items);
    try std.testing.expectEqualStrings("ada@example.com", email.items);
}

/// An environment for git with nothing of the machine's in it but PATH: its
/// global config is `cfg`, its home is `home`, so neither the identity nor
/// the signing settings of whoever runs the suite leak in.
fn isolatedEnv(cfg: []const u8, home: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(app.gpa);
    errdefer env.deinit();
    try env.put("PATH", std.mem.span(std.c.getenv("PATH") orelse "/usr/bin:/bin"));
    try env.put("HOME", home);
    try env.put("GIT_CONFIG_GLOBAL", cfg);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    return env;
}

// Closing a tab is not forgetting: the repository moves to the recent list,
// survives a restart there, and only the start page's × — after a yes —
// takes it away.
test "a closed tab is remembered, and only forgetting removes it" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();

    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "a" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(a);
    const path = try app.gpa.dupe(u8, app.repo_path.items);
    defer app.gpa.free(path);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);

    tab_strip.closeTab(0);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.recent.items.len);
    try std.testing.expectEqualStrings(path, tab_strip.recent.items[0]);

    // Through a restart.
    forgetTabs();
    tab_strip.loadWorkspace();
    try std.testing.expectEqual(@as(usize, 1), tab_strip.recent.items.len);

    // Opened again: a tab, so not also a recent one.
    tab_strip.openAndRemember(path);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);
    tab_strip.closeTab(0);

    dialog_views.askForget(path);
    repo_io.requestAction(.forget);
    try std.testing.expect(repo_io.runAction());
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);
    try std.testing.expect(dialog_views.forget_path == null);
    // Nothing on disk went with it.
    try expectGit(a, &.{ "rev-parse", "--git-dir" });

    // Opened again while it is a tab of another group: that tab, not a second.
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b", .{root});
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });
    tab_strip.openAndRemember(a);
    tab_strip.openAndRemember(b);
    const b_path = try app.gpa.dupe(u8, app.repo_path.items);
    defer app.gpa.free(b_path);
    tab_strip.groupTab("Side", 0, 1);
    tab_strip.selectTabIn(0, 0);
    tab_strip.openAndRemember(b);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.active_group);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);

    // Forgotten while it is the only tab of the active group and a tab of
    // another one too: the group goes, and what opens is not b again.
    try tab_strip.groups.items[0].tabs.append(app.gpa, .{ .path = try app.gpa.dupe(u8, b_path) });
    tab_strip.forgetRepo(b_path);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items[0].tabs.items.len);
    try std.testing.expectEqualStrings("a", app.repo_name);
    try std.testing.expectEqual(@as(usize, 0), tab_strip.recent.items.len);

    // Forgotten while the only tab of a group that is not the active one: no
    // empty group left behind.
    tab_strip.openAndRemember(b);
    tab_strip.groupTab("Solo", 0, 1);
    tab_strip.selectTabIn(0, 0);
    try std.testing.expectEqual(@as(usize, 2), tab_strip.groups.items.len);
    tab_strip.forgetRepo(b_path);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.groups.items.len);
    try std.testing.expectEqualStrings("a", app.repo_name);
}

/// One frame with the cursor pinned to the arrow: the dummy video driver logs
/// an error for every cursor change, and a logged error fails the test.
fn frameArrowCursor() !dvui.App.Result {
    const r = try app.appFrame();
    dvui.currentWindow().cursor_requested = .arrow;
    dvui.currentWindow().dragging.cursor = null;
    return r;
}

/// A real click — press and release, a frame each — at `p`, then let the
/// action it asked for run.
fn clickAt(p: dvui.Point.Physical) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = p });
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frameArrowCursor);
}

// The buttons inside a file row, clicked the way a person clicks them. A row
// is itself a button, and a button nested in one can lose the press to it —
// which builds, renders and does nothing.
test "the stage and unstage buttons on a file row work when clicked" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a.txt", .data = "changed\n" });

    app.openRepo(dir);
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Stage: the last icon on the unstaged row, at its right edge.
    {
        const row = (dvui.tagGet("unstaged:a.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16, .y = row.y + row.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 1), app.work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 0), app.work.?.unstaged.len);

    // And unstage, from the staged row.
    {
        const row = (dvui.tagGet("staged:a.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16, .y = row.y + row.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 0), app.work.?.staged.len);
    try std.testing.expectEqual(@as(usize, 1), app.work.?.unstaged.len);
}

/// Where `tag` is on screen; says which when it is not.
fn tagRect(tag: []const u8) !dvui.Rect.Physical {
    const data = dvui.tagGet(tag) orelse {
        std.debug.print("tag \"{s}\" not on screen\n", .{tag});
        return error.TagNotFound;
    };
    return data.rect;
}

/// `tag` not drawn this frame; says which when it is.
fn expectNoTag(tag: []const u8) !void {
    if (dvui.tagGet(tag) != null) {
        std.debug.print("tag \"{s}\" on screen, and should not be\n", .{tag});
        return error.TagOnScreen;
    }
}

/// The centre of a tagged widget, failing the test if it is not on screen.
fn tagCenter(tag: []const u8) !dvui.Point.Physical {
    const data = dvui.tagGet(tag) orelse {
        std.debug.print("tag \"{s}\" not on screen\n", .{tag});
        return error.TagNotFound;
    };
    return data.rect.center();
}

/// Two clicks inside the double-click window: a frame is 100ms in the test
/// window, so they go a frame apart rather than through `clickAt`'s settle.
fn doubleClickAt(p: dvui.Point.Physical) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = p });
    _ = try dvui.testing.step(frameArrowCursor);
    for (0..2) |_| {
        _ = try cw.addEventMouseButton(.left, .press);
        _ = try dvui.testing.step(frameArrowCursor);
        _ = try cw.addEventMouseButton(.left, .release);
        _ = try dvui.testing.step(frameArrowCursor);
    }
    try dvui.testing.settle(frameArrowCursor);
}

/// The mouse moved onto `p`, and the frames that follow drawn.
fn hoverAt(p: dvui.Point.Physical) !void {
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = p });
    try dvui.testing.settle(frameArrowCursor);
}

fn rightClickAt(p: dvui.Point.Physical) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = p });
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.right, .press);
    _ = try dvui.testing.step(frameArrowCursor);
    _ = try cw.addEventMouseButton(.right, .release);
    try dvui.testing.settle(frameArrowCursor);
}

fn pressFrame(code: dvui.enums.Key, mod: dvui.enums.Mod) !void {
    try dvui.testing.pressKey(code, mod);
    try dvui.testing.settle(frameArrowCursor);
}

fn typeText(text: []const u8) !void {
    try dvui.testing.writeText(text);
    try dvui.testing.settle(frameArrowCursor);
}

// Every control a day of work goes through, driven by mouse and keyboard and
// checked against git: the function-level tests prove the commands, this
// proves the clicks reach them.
test "audit: the main controls do what they say when clicked" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    // Folded by default; these rows are what the test works on.
    diff_view.section_collapsed = @splat(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try useTestConfig(root);
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/a", .{root});
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/b", .{root});

    try git.init();
    defer git.shutdown();
    defer dialog_views.closeRepo();
    defer github_actions.clearCommandError();

    try tmp.dir.createDirPath(app.app_io, "a");
    try makeTestRepo(&tmp, a, "a/one.txt", "one\n");
    try expectGit(a, &.{ "branch", "feat" });
    try expectGit(root, &.{ "init", "-q", "-b", "main", "b" });

    tab_strip.loadWorkspace();
    tab_strip.openAndRemember(b);
    tab_strip.openAndRemember(a);
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a/one.txt", .data = "one, edited\n" });
    try tmp.dir.writeFile(app.app_io, .{ .sub_path = "a/two.txt", .data = "two\n" });
    repo_io.reloadWork();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Toolbar: Stash takes both changes away, Pop brings them back.
    try clickAt(try tagCenter("toolbar:Stash"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 1), app.history.?.stashes.len);
    try std.testing.expectEqual(@as(usize, 0), search_view.changeCount());
    try clickAt(try tagCenter("toolbar:Pop"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 0), app.history.?.stashes.len);
    try std.testing.expectEqual(@as(usize, 2), app.work.?.unstaged.len);

    // Stage all — a job — and Unstage all.
    try clickAt(try tagCenter("link:stage_all"));
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 2), app.work.?.staged.len);
    try clickAt(try tagCenter("link:unstage_all"));
    try std.testing.expectEqual(@as(usize, 0), app.work.?.staged.len);

    // A file opens its diff in the centre, the graph view staying the view;
    // Split, and back to the graph by the button.
    {
        const row = (dvui.tagGet("unstaged:two.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + 60, .y = row.y + row.h / 2 });
    }
    try std.testing.expect(app.diffOpen());
    try std.testing.expectEqual(app.View.graph, app.active_view);
    try clickAt(try tagCenter("diff:split"));
    try std.testing.expect(diff_view.diff_split);
    try clickAt(try tagCenter("diff:unified"));
    app.closeDiff();
    try std.testing.expect(!app.diffOpen());

    // A commit, then the uncommitted-changes row brings the changes back.
    app.selectCommit(findCommit("base").?.id);
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("wip_row"));
    try std.testing.expectEqual(app.Selection.none, std.meta.activeTag(app.selection));

    // Discard one file through its trash icon and the confirmation: the
    // trash sits left of the stage icon.
    {
        const row = (dvui.tagGet("unstaged:one.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16 - 26, .y = row.y + row.h / 2 });
    }
    try std.testing.expect(app.confirm != null);
    try clickAt(try tagCenter("confirm:yes"));
    try std.testing.expectEqual(@as(usize, 1), app.work.?.unstaged.len);
    try std.testing.expectEqualStrings("two.txt", app.work.?.unstaged[0].path);

    // Stage it, type a summary, commit — by the button.
    {
        const row = (dvui.tagGet("unstaged:two.txt") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = row.x + row.w - 16, .y = row.y + row.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 1), app.work.?.staged.len);
    try clickAt(try tagCenter("commit_summary"));
    try typeText("audit commit");
    try std.testing.expectEqualStrings("audit commit", app.commit_summary.items);
    try clickAt(try tagCenter("commit_button"));
    // A commit is a job: waited for, as Stash and Stage all are. The
    // frames of the click alone were sometimes over before git was —
    // the commit not in the history yet, the job left running into the
    // next test.
    try pumpJobFrame();
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findCommit("audit commit") != null);
    try std.testing.expectEqual(@as(usize, 0), app.commit_summary.items.len);

    // Undo it from the toolbar: gone, its file staged again.
    try clickAt(try tagCenter("toolbar:Undo"));
    try std.testing.expect(findCommit("audit commit") == null);
    try std.testing.expectEqual(@as(usize, 1), app.work.?.staged.len);

    // Right-click a branch, rename it from the menu through its dialog.
    try rightClickAt(try tagCenter("feat"));
    try clickAt(try tagCenter("menu:Rename…"));
    try std.testing.expect(app.prompt != null);
    try std.testing.expectEqualStrings("feat", app.prompt_text.items);
    try typeText("ure");
    try clickAt(try tagCenter("prompt:go"));
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
    try std.testing.expect(findRef("feature") != null);

    // Double-click a branch to check it out.
    try doubleClickAt(try tagCenter("feature"));
    try pumpJobFrame();
    try std.testing.expectEqualStrings("feature", app.history.?.head.?);

    // The palette: Ctrl+P, a few letters, Enter.
    try pressFrame(.p, .lcontrol);
    try std.testing.expect(command_palette.palette_open);
    try typeText("stash ever");
    try pressFrame(.enter, .none);
    try std.testing.expect(!command_palette.palette_open);
    try pumpJobFrame();
    try std.testing.expectEqual(@as(usize, 1), app.history.?.stashes.len);

    // Settings from the menu on the face: switch to the light theme, Esc out.
    try clickAt(try tagCenter("toolbar:user"));
    try clickAt(try tagCenter("menu:Settings — Ctrl+,"));
    try std.testing.expect(identity_view.settings_open);
    try clickAt(try tagCenter("settings:Appearance"));
    try clickAt(try tagCenter("theme:Zit Light"));
    try std.testing.expect(!app.dark_theme);
    try pressFrame(.escape, .none);
    try std.testing.expect(!identity_view.settings_open);

    // The keys, from the footer.
    try clickAt(try tagCenter("status:keys"));
    try std.testing.expect(identity_view.keys_open);
    try pressFrame(.escape, .none);
    try std.testing.expect(!identity_view.keys_open);

    // Tabs: the other one, then its × — closed, and remembered.
    try clickAt(try tagCenter("tab:0"));
    try std.testing.expect(std.mem.endsWith(u8, app.repo_path.items, "/b/"));
    {
        const name = (dvui.tagGet("tab:0") orelse return error.TagNotFound).rect;
        try clickAt(.{ .x = name.x + name.w + 12, .y = name.y + name.h / 2 });
    }
    try std.testing.expectEqual(@as(usize, 1), tab_strip.activeGroup().?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab_strip.recent.items.len);

    // A new tab, and the Clone card on its page opens the dialog.
    try pressFrame(.t, .lcontrol);
    try std.testing.expect(app.new_tab_open);
    try clickAt(try tagCenter("start:Clone"));
    try std.testing.expectEqual(dialog_views.RepoDialog.clone, dialog_views.repo_dialog);
    try clickAt(try tagCenter("dialog:Cancel"));
    try std.testing.expectEqual(dialog_views.RepoDialog.none, dialog_views.repo_dialog);
}

// The code GitHub hands out, big enough to copy by eye, in a dialog that
// keeps its width. Nothing here reaches GitHub: the flow is set, not started.
test "the connect dialog shows the code and keeps its width" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 700 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    try style.applyEmbedded(app.gpa, true);
    defer resetUiGlobals();
    defer {
        github_connect.closeConnect();
        github_connect.connect_code.deinit(app.gpa);
        github_connect.connect_code = .empty;
        github_connect.connect_note.deinit(app.gpa);
        github_connect.connect_note = .empty;
    }

    github_connect.connect_open = true;
    github_connect.connect_rect = .{};
    github_connect.connect_state = .waiting;
    try github_connect.connect_code.appendSlice(app.gpa, "ABCD-1234");
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(github_connect.connect_rect.w <= 440);

    // A failure says why, and Cancel closes.
    github_connect.connectFailed("GitHub did not accept the sign-in.");
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expect(dvui.tagGet("dialog:Try again") != null);
    try clickAt(try tagCenter("dialog:Cancel"));
    try std.testing.expect(!github_connect.connect_open);
}

test "a long message is cut with an ellipsis, a short one left alone" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 200 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    try style.applyEmbedded(app.gpa, true);
    const font = style.graphText();
    var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;

    try std.testing.expectEqualStrings("short", graph_view.fitText(&buf, "short", font, 500));
    const long = "feat(parser): handle every edge case anybody has ever thought of, twice";
    const cut = graph_view.fitText(&buf, long, font, 120);
    try std.testing.expect(std.mem.endsWith(u8, cut, "…"));
    try std.testing.expect(cut.len < long.len);
    try std.testing.expect(font.textSize(cut).w <= 120);
    // Never inside a UTF-8 sequence.
    try std.testing.expect(std.unicode.utf8ValidateSlice(graph_view.fitText(&buf, "éééééééééééééééééééééééé", font, 40)));
}

test "the split view sets each removed line against the line that replaced it" {
    app.gpa = std.testing.allocator;
    defer resetUiGlobals();
    var lines = [_]git.DiffLine{
        .{ .kind = .hunk_header, .text = "@@ -1,4 +1,3 @@", .old_no = 0, .new_no = 0, .hunk = 0 },
        .{ .kind = .context, .text = "a", .old_no = 1, .new_no = 1, .hunk = 0 },
        .{ .kind = .deletion, .text = "b", .old_no = 2, .new_no = 0, .hunk = 0 },
        .{ .kind = .deletion, .text = "c", .old_no = 3, .new_no = 0, .hunk = 0 },
        .{ .kind = .addition, .text = "B", .old_no = 0, .new_no = 2, .hunk = 0 },
        .{ .kind = .context, .text = "d", .old_no = 4, .new_no = 3, .hunk = 0 },
    };
    var files = [_]git.FileDiff{.{ .path = "f", .old_path = "f", .status = .modified, .lines = &lines, .hunk_count = 1, .binary = false }};
    app.diff = .{ .arena = .init(app.gpa), .files = &files };
    defer {
        app.diff.?.arena.deinit();
        app.diff = null;
    }
    diff_view.buildSplitRows();

    const r = diff_view.split_rows.items;
    // file (two rows high), hunk, a|a, b|B, c|-, d|d
    try std.testing.expectEqual(@as(usize, 7), r.len);
    try std.testing.expect(r[1].kind == .pad);
    try std.testing.expectEqual(@as(u32, 2), r[4].left);
    try std.testing.expectEqual(@as(u32, 4), r[4].right);
    try std.testing.expectEqual(@as(u32, 3), r[5].left);
    try std.testing.expectEqual(diff_view.NO_LINE, r[5].right);
    try std.testing.expectEqual(@as(u32, 5), r[6].left);
}

test "a commit date reads as a date, and fits its column" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 200 } });
    defer t.deinit();
    app.gpa = std.testing.allocator;
    try style.applyEmbedded(app.gpa, true);
    var buf: [32]u8 = undefined;
    const text = search_view.absoluteTime(&buf, 1_761_000_000);
    try std.testing.expectEqual(@as(usize, 16), text.len);
    try std.testing.expectEqual(@as(u8, '-'), text[4]);
    try std.testing.expectEqual(@as(u8, ':'), text[13]);
    try std.testing.expect(style.graphMono().textSize("2026-10-21 18:05").w <= style.time_column);
}

test "a commit's files: only the rows in sight are built, however many" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for (0..300) |i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(app.app_io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d:0>3}.txt", .{i}), .data = "x\n" });
    }
    try expectGit(dir, &.{ "add", "-A" });
    try expectGit(dir, &.{ "commit", "-qm", "three hundred" });
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);
    app.selectCommit(app.history.?.commits[0].id);
    try dvui.testing.settle(frameArrowCursor);

    // The first of the 300 built, the last not: the pane shows a few dozen.
    _ = try tagCenter("file:f000.txt");
    try expectNoTag("file:f299.txt");

    // Scrolled to the end of the pane: the other way round.
    commit_view.commit_scroll.viewport.y = commit_view.commit_scroll.scrollMax(.vertical);
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagCenter("file:f299.txt");
    try expectNoTag("file:f000.txt");
}

test "the authors' menu builds the rows in sight, and its search still finds the rest" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    for (0..60) |i| {
        var name: [32]u8 = undefined;
        var mail: [48]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "user.name=A{d:0>2}", .{i});
        const m = try std.fmt.bufPrint(&mail, "user.email=a{d:0>2}@x.invalid", .{i});
        try expectGit(dir, &.{ "-c", n, "-c", m, "commit", "-q", "--allow-empty", "-m", "c" });
    }
    app.openRepo(dir);
    defer dialog_views.closeRepo();

    // Wide: the author column only shows with room left for the messages,
    // whatever widths the tests before this one left.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1900, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    try dvui.testing.settle(frameArrowCursor);

    // Newest first: the last to commit is in sight, the first is not built.
    try clickAt(try tagCenter("header:author"));
    _ = try tagCenter("author:A59");
    try expectNoTag("author:A00");
    // Asked for by name, it is the one row.
    try typeText("A00");
    try dvui.testing.settle(frameArrowCursor);
    _ = try tagCenter("author:A00");
    try expectNoTag("author:A59");
}

test "changes picked: asked by path, taken off again, one side at a time" {
    app.gpa = std.testing.allocator;
    defer resetUiGlobals();
    commit_view.toggleChangePick(.unstaged, "a.txt");
    commit_view.toggleChangePick(.unstaged, "b.txt");
    try std.testing.expect(commit_view.isChangePicked(.unstaged, "a.txt"));
    try std.testing.expect(commit_view.isChangePicked(.unstaged, "b.txt"));
    try std.testing.expect(!commit_view.isChangePicked(.staged, "a.txt"));

    // Picked again: off, in the list and in the set alike.
    commit_view.toggleChangePick(.unstaged, "a.txt");
    try std.testing.expect(!commit_view.isChangePicked(.unstaged, "a.txt"));
    try std.testing.expectEqual(@as(usize, 1), commit_view.picked_changes.items.len);
    const changes = [_]git.Change{
        .{ .path = "a.txt", .old_path = "a.txt", .status = .modified },
        .{ .path = "b.txt", .old_path = "b.txt", .status = .modified },
    };
    try std.testing.expectEqual(@as(usize, 1), commit_view.pickedIn(.unstaged, &changes));

    // The other side's pick starts over.
    commit_view.toggleChangePick(.staged, "c.txt");
    try std.testing.expect(!commit_view.isChangePicked(.unstaged, "b.txt"));
    try std.testing.expect(commit_view.isChangePicked(.staged, "c.txt"));
    commit_view.clearPickedChanges();
    try std.testing.expect(!commit_view.isChangePicked(.staged, "c.txt"));
    try std.testing.expectEqual(@as(u32, 0), commit_view.picked_set.count());
}

test "a repository's own settings are written to its config and read back" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    repo_settings.repo_settings_path.appendSlice(app.gpa, dir) catch unreachable;

    repo_settings.setLocalConfig("user.name", "Work Me");
    repo_settings.setLocalConfig("pull.ff", "only");
    repo_settings.setLocalConfig("commit.gpgsign", "false");
    while (!repo_settings.repo_prefs_loaded) repo_settings.loadRepoPrefs();
    try std.testing.expectEqualStrings("Work Me", repo_settings.repo_name_local.items);
    try std.testing.expect(repo_settings.repo_pull == .ff_only);
    try std.testing.expect(repo_settings.repo_sign == .off);
    try std.testing.expect(repo_settings.repo_prune == .global);

    // Back to as everywhere: unset, and nothing said about it.
    repo_settings.setLocalConfig("pull.ff", "");
    repo_settings.setLocalConfig("pull.ff", "");
    while (!repo_settings.repo_prefs_loaded) repo_settings.loadRepoPrefs();
    try std.testing.expect(repo_settings.repo_pull == .global);
    try std.testing.expectEqual(@as(?[]u8, null), tab_strip.command_error);
}

test "a summary typed past 72 goes on in the description, and says so" {
    app.gpa = std.testing.allocator;
    app.app_io = std.testing.io;
    defer resetUiGlobals();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try git.init();
    defer git.shutdown();
    try makeTestRepo(&tmp, dir, "a.txt", "a\n");
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1320, .h = 840 } });
    defer t.deinit();
    try style.applyEmbedded(app.gpa, true);
    app.openRepo(dir);
    defer dialog_views.closeRepo();
    try dvui.testing.settle(frameArrowCursor);

    // Key by key, as it is typed: the move happens mid-word, and the rest of
    // the word follows it into the description.
    try clickAt(try tagCenter("commit_summary"));
    for ("Settings for this repository, and a file opened in your editor of choice today") |ch| try typeText(&.{ch});
    try dvui.testing.settle(frameArrowCursor);
    try std.testing.expectEqualStrings("Settings for this repository, and a file opened in your editor of choice", app.commit_summary.items);
    try std.testing.expectEqualStrings("today", app.commit_description.items);
    try std.testing.expect(commit_view.summary_moved);
    try std.testing.expect(dvui.tagGet("commit:drop_stop") == null);

    // A full stop is pointed out, and dropped in a click.
    app.commit_summary.clearRetainingCapacity();
    app.commit_description.clearRetainingCapacity();
    try app.commit_summary.appendSlice(app.gpa, "Fix the parser.");
    try dvui.testing.settle(frameArrowCursor);
    try clickAt(try tagCenter("commit:drop_stop"));
    try std.testing.expectEqualStrings("Fix the parser", app.commit_summary.items);
}

// The documentation's screenshots, of a made-up repository: run by
// scripts/screenshots.sh, which makes the repository first and sets
// ZIT_SHOTS; skipped otherwise, so the suite never writes into the tree.
test "docs screenshots" {
    if (std.c.getenv("ZIT_SHOTS") == null) return error.SkipZigTest;
    app.gpa = std.heap.c_allocator;
    app.app_io = std.testing.io;
    try git.init();
    defer git.shutdown();
    diff_view.section_collapsed = @splat(false);
    diff_view.section_collapsed[@backingInt(diff_view.Section.tags)] = true;
    repo_io.stillUi();
    try window_chrome.me_name.appendSlice(app.gpa, "Alice Martin");
    try window_chrome.me_email.appendSlice(app.gpa, "alice@acme.dev");
    window_chrome.me_loaded = true;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1440, .h = 900 }, .allocator = std.heap.c_allocator });
    defer t.deinit();
    const demo = "/tmp/acme-web";
    try tab_strip.recent.append(app.gpa, try app.gpa.dupe(u8, "/home/alice/dev/acme-api/"));
    try tab_strip.recent.append(app.gpa, try app.gpa.dupe(u8, "/home/alice/dev/design-system/"));

    for ([_]bool{ true, false }) |dark| {
        app.dark_theme = dark;
        app.theme_index = if (dark) 0 else 1;
        app.applyTheme();
        const sfx: []const u8 = if (dark) "dark" else "light";
        app.openRepo(demo);
        app.clearSelection();
        try docShot("zit", sfx);
        if (!dark) {
            dialog_views.closeRepo();
            continue;
        }
        const h = app.history.?;
        app.selectCommit(h.commits[3].id);
        try docShot("commit", sfx);
        // The commit that validates the login's email: a diff worth reading.
        for (h.commits) |c| if (std.mem.eql(u8, c.summary, "WEB-12: validate the email field")) {
            app.selectCommit(c.id);
            try docShot("zz", sfx);
            app.selectCommitFile(c.id, "src/components/Login.tsx");
        };
        try docShot("diff", sfx);
        app.selectChange("src/components/Search.tsx", .unstaged);
        try app.commit_summary.appendSlice(app.gpa, "WEB-18: keyboard navigation in the results");
        try docShot("changes", sfx);
        app.commit_summary.clearRetainingCapacity();
        app.clearSelection();
        graph_view.search_open = true;
        try app.commit_filter.appendSlice(app.gpa, "author:chloe");
        try docShot("search", sfx);
        app.commit_filter.clearRetainingCapacity();
        graph_view.search_open = false;
        command_palette.palette_open = true;
        try docShot("palette", sfx);
        command_palette.palette_open = false;
        identity_view.openSettings(0);
        try docShot("settings-appearance", sfx);
        identity_view.settings_open = false;
        try docShot("zz", sfx);
        identity_view.openSettings(identity_view.REPO_PAGE);
        try docShot("settings-repository", sfx);
        identity_view.settings_open = false;
        home_page.features_open = true;
        home_page.features_page = 0;
        try docShot("about", sfx);
        home_page.features_open = false;
        app.new_tab_open = true;
        try docShot("start", sfx);
        app.new_tab_open = false;
        dialog_views.closeRepo();
    }
}

/// One screenshot for the documentation, once the frame has settled:
/// docs/screenshots/{name}-{theme}.png, or {name}.png for the dark one of
/// the home page's pair.
fn docShot(name: []const u8, sfx: []const u8) !void {
    for (0..12) |_| try dvui.testing.settle(frameArrowCursor);
    var out: std.Io.Writer.Allocating = try .initCapacity(app.gpa, 1 << 20);
    defer out.deinit();
    try dvui.testing.capturePng(frameArrowCursor, null, &out.writer);
    var path: [256]u8 = undefined;
    // A shot only to let the frame before settle: not kept.
    if (std.mem.eql(u8, name, "zz")) return;
    const p = try std.fmt.bufPrint(&path, "docs/screenshots/{s}-{s}.png", .{ name, sfx });
    try std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = p, .data = out.written() });
}

test "a column dragged as wide as it may go hides none" {
    defer resetUiGlobals();
    const saved = .{ app.graph_scroll.viewport.w, graph_view.col_author, graph_view.col_sha, graph_view.col_time };
    defer {
        app.graph_scroll.viewport.w = saved[0];
        graph_view.col_author = saved[1];
        graph_view.col_sha = saved[2];
        graph_view.col_time = saved[3];
    }
    app.graph_scroll.viewport.w = 1200;
    graph_view.col_author += graph_view.messageSpare();
    try std.testing.expect(graph_view.columnsShown().author and graph_view.columnsShown().sha);
    try std.testing.expectEqual(@as(f32, 0), graph_view.messageSpare());
    // A pixel past the cap: the sha goes, as it did under the drag.
    graph_view.col_author += 1;
    try std.testing.expect(!graph_view.columnsShown().sha);
}
