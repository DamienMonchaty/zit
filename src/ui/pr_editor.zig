const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const pr = @import("../github/pr.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const search_view = @import("search_view.zig");
const diff_view = @import("diff_view.zig");
const rebase_view = @import("rebase_view.zig");
const commit_view = @import("commit_view.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const command_palette = @import("command_palette.zig");
const repo_io = @import("../core/repo_io.zig");
const github_actions = @import("../github/github_actions.zig");
const github_connect = @import("../github/github_connect.zig");
const pr_list = @import("pr_list.zig");
const pr_conversation = @import("pr_conversation.zig");
const pr_create = @import("pr_create.zig");
const app = @import("../main.zig");

// === Editing a request ===

var pr_edit_open = false;
var pr_edit_rect: dvui.Rect = .{};
var pr_edit_title: std.ArrayList(u8) = .empty;
var pr_edit_body: std.ArrayList(u8) = .empty;
pub var pr_edit_reviewers: std.ArrayList(u8) = .empty;
pub var pr_edit_labels: std.ArrayList(u8) = .empty;
var pr_edit_assignees: std.ArrayList(u8) = .empty;
pub var pr_edit_base: std.ArrayList(u8) = .empty;
var pr_edit_draft = false;

/// The edit dialog, filled in with the request as it is: what it says,
/// where it goes, who reviews, who it is assigned to, its labels, its type.
pub fn openPrEdit(d: pr.Detail) void {
    pr_edit_open = true;
    pr_edit_rect = .{};
    for (prEditLists()) |t| t.clearRetainingCapacity();
    pr_edit_title.appendSlice(app.gpa, d.title) catch {};
    pr_edit_body.appendSlice(app.gpa, d.body) catch {};
    pr_edit_base.appendSlice(app.gpa, d.base) catch {};
    for (d.reviewers) |r| pr_create.listToggle(&pr_edit_reviewers, r.login);
    for (d.assignees) |login| pr_create.listToggle(&pr_edit_assignees, login);
    for (d.labels) |l| pr_create.listToggle(&pr_edit_labels, l.name);
    pr_edit_draft = d.draft;
    pr.loadMeta(app.repo_path.items);
}

fn prEditLists() [6]*std.ArrayList(u8) {
    return .{ &pr_edit_title, &pr_edit_body, &pr_edit_reviewers, &pr_edit_labels, &pr_edit_assignees, &pr_edit_base };
}

pub fn clearPrEdit() void {
    pr_edit_open = false;
    for (prEditLists()) |t| {
        t.deinit(app.gpa);
        t.* = .empty;
    }
}

/// The request's words, and who and what to add to it.
pub fn prEditDialog() void {
    if (!pr_edit_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &pr_edit_rect, &pr_edit_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    var num: [12]u8 = undefined;
    var title_buf: [48]u8 = undefined;
    identity_view.dialogHeader(@src(), dvui.entypo.pencil, std.fmt.bufPrint(&title_buf, "Edit #{s}", .{pr_list.requestNumber(&num)}) catch "Edit", "Saved on the host when you press Save", &pr_edit_open);

    var body = identity_view.dialogBody(@src(), @min(pr_create.PR_CREATE_W, win.w - 80));

    // As the create dialog has it: where it goes — where it comes from is
    // fixed once it is made — its words, who and what, its type.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        pr_create.branchPicker(0, "Into", &pr_edit_base, .remote);
        pr_create.fixedField(1, "From", if (pr.detail) |d| d.head else "");
    }
    var entered = false;
    _ = dialog_views.dialogField(@src(), 0, "Title", &pr_edit_title, "What it does", false, &entered);
    dialog_views.dialogLabel(@src(), "Description");
    {
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_edit_body, .allocator = app.gpa, .limit = 65536 } },
            .multiline = true,
            .break_lines = true,
            .placeholder = "Why, and how to try it",
        }, identity_view.settingsInput().override(.{ .tag = "pr_edit:body", .min_size_content = .{ .h = 160 }, .max_size_content = .size(.{ .w = 0, .h = 260 }), .margin = .{ .h = style.space.lg } }));
        te.deinit();
    }
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        pr_create.peoplePicker(2, "Reviewers", &pr_edit_reviewers, "Ask for reviews", true, "pr_edit:reviewers");
        pr_create.peoplePicker(3, "Assignees", &pr_edit_assignees, "Assign someone", false, "pr_edit:assignees");
        pr_create.labelPicker(4, &pr_edit_labels, "pr_edit:labels");
    }
    body.deinit();
    {
        var line = identity_view.dialogFooter(@src());
        defer line.deinit();
        pr_create.typePicker(5, &pr_edit_draft, "pr_edit:type");
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButton(@src(), "Cancel", false)) pr_edit_open = false;
        if (dialog_views.dialogButton(@src(), "Save", true)) savePrEdit();
    }
    if (dialog_views.escapePressed() and pr_create.pick_open == null) pr_edit_open = false;
}

fn savePrEdit() void {
    const title = std.mem.trim(u8, pr_edit_title.items, " \n\t");
    if (title.len == 0) return github_actions.setCommandError("A request needs a title.");
    const d = pr.detail orelse return;
    const a = dvui.currentWindow().arena();
    const number = d.number;
    var path: [512]u8 = undefined;

    // Its words, and where it goes.
    const base = std.mem.trim(u8, pr_edit_base.items, " ");
    github_actions.requestApi("Saving", "PATCH", github_actions.apiPath(&path, "/pulls/{d}", .{number}), github_actions.jsonFields(a, &.{ .{ "title", title }, .{ "body", pr_edit_body.items }, .{ "base", if (base.len > 0) base else d.base } }), .none);

    // Reviewers newly asked, and those asked no longer — only one who has
    // not answered can be: a review given stays given.
    var added: std.ArrayList(u8) = .empty;
    var removed: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, pr_edit_reviewers.items, ',');
    while (it.next()) |raw| {
        const login = std.mem.trim(u8, raw, " ");
        if (login.len == 0) continue;
        const known = for (d.reviewers) |r| {
            if (std.ascii.eqlIgnoreCase(r.login, login)) break true;
        } else false;
        if (!known) listAppend(a, &added, login);
    }
    for (d.reviewers) |r| {
        if (std.mem.eql(u8, r.state, "REQUESTED") and !pr_create.listHas(pr_edit_reviewers.items, r.login)) listAppend(a, &removed, r.login);
    }
    if (added.items.len > 0) github_actions.requestApi("Asking for reviews", "POST", github_actions.apiPath(&path, "/pulls/{d}/requested_reviewers", .{number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{github_actions.jsonList(a, added.items)}) catch return, .none);
    if (removed.items.len > 0) github_actions.requestApi("Withdrawing reviews", "DELETE", github_actions.apiPath(&path, "/pulls/{d}/requested_reviewers", .{number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{github_actions.jsonList(a, removed.items)}) catch return, .none);

    // Assignees and labels as picked, the whole of each, where they changed.
    if (!sameNames(pr_edit_assignees.items, d.assignees)) {
        github_actions.requestApi("Assigning", "PATCH", github_actions.apiPath(&path, "/issues/{d}", .{number}), std.fmt.allocPrint(a, "{{\"assignees\":{s}}}", .{github_actions.jsonList(a, pr_edit_assignees.items)}) catch return, .none);
    }
    var label_names: std.ArrayList([]const u8) = .empty;
    for (d.labels) |l| label_names.append(a, l.name) catch {};
    if (!sameNames(pr_edit_labels.items, label_names.items)) {
        github_actions.requestApi("Labelling", "PUT", github_actions.apiPath(&path, "/issues/{d}/labels", .{number}), std.fmt.allocPrint(a, "{{\"labels\":{s}}}", .{pr_create.jsonCommaList(a, pr_edit_labels.items)}) catch return, .none);
    }

    // Ready for review, or back to a draft.
    if (pr_edit_draft != d.draft) {
        if (pr_edit_draft) pr_conversation.requestOnRequest("Making a draft", "convertPullRequestToDraft", d.id) else pr_conversation.requestOnRequest("Marking ready", "markPullRequestReadyForReview", d.id);
    }
    pr_edit_open = false;
}

/// `item` after the comma-separated `list`, in `a`.
fn listAppend(a: std.mem.Allocator, list: *std.ArrayList(u8), item: []const u8) void {
    if (list.items.len > 0) list.appendSlice(a, ", ") catch return;
    list.appendSlice(a, item) catch {};
}

/// Whether the comma-separated `list` names exactly `names`, in any order.
pub fn sameNames(list: []const u8, names: []const []const u8) bool {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const x = std.mem.trim(u8, raw, " ");
        if (x.len == 0) continue;
        n += 1;
        const known = for (names) |name| {
            if (std.mem.eql(u8, name, x)) break true;
        } else false;
        if (!known) return false;
    }
    return n == names.len;
}

/// A request's state, on a pill of its colour.
pub fn statePill(word: []const u8, hue: dvui.Color) void {
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = .{ .color = hue },
        .corners = .all(100),
        .gravity_y = 0.5,
        .padding = .{ .x = style.space.md, .y = 2, .w = style.space.md, .h = 2 },
    });
    defer pill.deinit();
    dvui.icon(@src(), "state_icon", dvui.entypo.merge, .{ .fill_color = .{ .color = style.textOnAccent() }, .stroke_color = null }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
    dvui.label(@src(), "{s}", .{word}, .{ .font = style.smallBold(), .color_text = .{ .color = style.textOnAccent() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
}

/// A branch's name on a chip, in the mono face it is typed in.
pub fn branchChip(id: usize, name: []const u8) void {
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.accentDim() },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer chip.deinit();
    var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
    dvui.label(@src(), "{s}", .{graph_view.fitText(&buf, name, style.mono(), 260)}, .{ .font = style.mono(), .color_text = .{ .color = style.accent() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
}

/// Someone on the request, their picture and name, and a word on their part.
pub fn personChip(id: usize, login: []const u8, what: []const u8) void {
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = .all(100),
        .margin = .{ .w = style.space.sm, .y = 2, .h = 2 },
        .padding = .{ .x = 2, .y = 2, .w = style.space.md, .h = 2 },
    });
    defer chip.deinit();
    search_view.avatarSized(@src(), 0, pr_list.requestAuthor(login), null, null, 18);
    dvui.label(@src(), "{s}", .{login}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{what}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.xs }, .padding = dvui.Rect.all(0) });
}

/// A reviewer, with where they stand as an icon of its colour.
pub fn reviewerChip(id: usize, r: pr.Reviewer) void {
    const icon: []const u8, const hue: dvui.Color, const word: []const u8 = if (std.mem.eql(u8, r.state, "APPROVED"))
        .{ dvui.entypo.check, style.success(), "approved" }
    else if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED"))
        .{ dvui.entypo.cross, style.danger(), "asks for changes" }
    else if (std.mem.eql(u8, r.state, "COMMENTED"))
        .{ dvui.entypo.chat, style.textMuted(), "commented" }
    else
        .{ dvui.entypo.clock, style.get().orange, "asked to review" };
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = hue.opacity(0.5) },
        .corners = .all(100),
        .margin = .{ .w = style.space.sm, .y = 2, .h = 2 },
        .padding = .{ .x = 2, .y = 2, .w = style.space.md, .h = 2 },
    });
    defer chip.deinit();
    search_view.avatarSized(@src(), 0, pr_list.requestAuthor(r.login), null, null, 18);
    dvui.label(@src(), "{s}", .{r.login}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    dvui.icon(@src(), "review_state", icon, .{ .fill_color = .{ .color = hue } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm } });
    dvui.label(@src(), "{s}", .{word}, .{ .font = style.tiny(), .color_text = .{ .color = hue }, .gravity_y = 0.5, .margin = .{ .x = 2 }, .padding = dvui.Rect.all(0) });
}

/// What a request's checks came to: failed, running, passed.
const CheckTally = struct { failed: usize = 0, running: usize = 0, passed: usize = 0 };

fn checkOk(result: []const u8) bool {
    return std.mem.eql(u8, result, "SUCCESS") or std.mem.eql(u8, result, "NEUTRAL") or std.mem.eql(u8, result, "SKIPPED");
}

fn checkBad(result: []const u8) bool {
    return std.mem.eql(u8, result, "FAILURE") or std.mem.eql(u8, result, "ERROR") or std.mem.eql(u8, result, "CANCELLED") or std.mem.eql(u8, result, "TIMED_OUT") or std.mem.eql(u8, result, "ACTION_REQUIRED");
}

pub fn tallyChecks(checks: []const pr.Check) CheckTally {
    var t: CheckTally = .{};
    for (checks) |c| {
        if (checkOk(c.result)) t.passed += 1 else if (checkBad(c.result)) t.failed += 1 else t.running += 1;
    }
    return t;
}

/// The one line on whether it can be merged, and if not what is in the way —
/// worst first: conflicts, failing checks, changes asked for, the base moved
/// on, a review still wanted, checks still running, a draft.
pub fn mergeReadiness(d: pr.Detail) void {
    const t = tallyChecks(d.checks);
    var buf: [160]u8 = undefined;
    const icon: []const u8, const hue: dvui.Color, const text: []const u8 = blk: {
        // Done with: what became of it, not whether it could merge.
        if (std.ascii.eqlIgnoreCase(d.state, "MERGED")) break :blk .{ dvui.entypo.merge, style.get().purple, std.fmt.bufPrint(&buf, "Merged into {s}", .{d.base}) catch "Merged" };
        if (std.ascii.eqlIgnoreCase(d.state, "CLOSED")) break :blk .{ dvui.entypo.block, style.danger(), "Closed without merging" };
        if (std.mem.eql(u8, d.mergeable, "CONFLICTING")) break :blk .{ dvui.entypo.warning, style.danger(), std.fmt.bufPrint(&buf, "Conflicts with {s}: resolve them before it can merge", .{d.base}) catch "" };
        if (t.failed > 0) break :blk .{ dvui.entypo.cross, style.danger(), std.fmt.bufPrint(&buf, "{d} check{s} failing", .{ t.failed, window_chrome.plural(t.failed) }) catch "" };
        if (std.mem.eql(u8, d.review, "CHANGES_REQUESTED")) break :blk .{ dvui.entypo.cross, style.danger(), changesText(d) };
        if (std.mem.eql(u8, d.merge_state, "BEHIND")) break :blk .{ dvui.entypo.arrow_down, style.get().orange, std.fmt.bufPrint(&buf, "Behind {s}: update the branch first", .{d.base}) catch "" };
        if (std.mem.eql(u8, d.review, "REVIEW_REQUIRED")) break :blk .{ dvui.entypo.eye, style.get().orange, "A review is still needed" };
        if (t.running > 0) break :blk .{ dvui.entypo.clock, style.get().orange, std.fmt.bufPrint(&buf, "{d} check{s} still running", .{ t.running, window_chrome.plural(t.running) }) catch "" };
        if (d.draft) break :blk .{ dvui.entypo.pencil, style.textMuted(), "A draft: mark it ready for review to merge it" };
        if (std.mem.eql(u8, d.merge_state, "BLOCKED")) break :blk .{ dvui.entypo.lock, style.get().orange, "Blocked by the branch's protection rules" };
        // GitHub works mergeability out after a push, a while later: until
        // then it says UNKNOWN, which is not a yes.
        if (mergeUnknown(d)) break :blk .{ dvui.entypo.clock, style.textMuted(), "GitHub is still working out whether it can merge…" };
        break :blk .{ dvui.entypo.check, style.success(), if (t.passed > 0) std.fmt.bufPrint(&buf, "Ready to merge: {d} check{s} passed", .{ t.passed, window_chrome.plural(t.passed) }) catch "" else "Ready to merge" };
    };
    var bar = dialog_views.alertBox(@src(), 0, hue, icon, .{ .y = style.space.md, .h = style.space.xs });
    defer bar.deinit();
    dialog_views.alertText(@src(), text, hue);
    if (d.auto_merge) tinyBadge(@src(), 0, "auto-merge on", style.accent());
    readinessAction(d, t, hue);

    // Asked again every few seconds while GitHub has no answer yet — about
    // one still open: a merged one's stays unknown for good.
    if (pr_conversation.requestOpen(d) and mergeUnknown(d)) {
        if (app.frame_now_s - pr_recheck_s >= PR_RECHECK_S) {
            pr_recheck_s = app.frame_now_s;
            pr.loadDetail(app.repo_path.items, d.number);
        }
        dvui.timer(bar.data().id, PR_RECHECK_S * std.time.us_per_s);
    }
}

/// "ann asked for changes · 2 open conversations": who, and what is left.
fn changesText(d: pr.Detail) []const u8 {
    const a = dvui.currentWindow().arena();
    var who: []const u8 = "";
    var n: usize = 0;
    for (d.reviewers) |r| if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED")) {
        if (n == 0) who = r.login;
        n += 1;
    };
    const head = (switch (n) {
        0 => "Changes were asked for",
        1 => std.fmt.allocPrint(a, "{s} asked for changes", .{who}),
        else => std.fmt.allocPrint(a, "{s} and {d} more asked for changes", .{ who, n - 1 }),
    }) catch "Changes were asked for";
    const open = openThreads(d);
    if (open == 0) return head;
    return std.fmt.allocPrint(a, "{s} · {d} open conversation{s}", .{ head, open, window_chrome.plural(open) }) catch head;
}

/// Ask again those who asked for changes, once they are made.
fn rerequestReview(d: pr.Detail) void {
    const a = dvui.currentWindow().arena();
    var who: std.ArrayList(u8) = .empty;
    for (d.reviewers) |r| if (std.mem.eql(u8, r.state, "CHANGES_REQUESTED")) listAppend(a, &who, r.login);
    if (who.items.len == 0) return;
    var path: [512]u8 = undefined;
    github_actions.requestApi("Asking for a review", "POST", github_actions.apiPath(&path, "/pulls/{d}/requested_reviewers", .{d.number}), std.fmt.allocPrint(a, "{{\"reviewers\":{s}}}", .{github_actions.jsonList(a, who.items)}) catch return, .none);
}

/// The one thing to do next about a request, at the end of its readiness
/// line: resolve its conflicts here, bring it up to date on GitHub, look at
/// the failing checks, put a draft up for review, or merge it.
fn readinessAction(d: pr.Detail, t: anytype, hue: dvui.Color) void {
    if (!pr_conversation.requestOpen(d)) return;
    if (std.mem.eql(u8, d.mergeable, "CONFLICTING")) {
        // Rebased onto its base, here: the conflicts come up one by one.
        if (!d.fork and dialog_views.alertButton(@src(), "Rebase onto it here", hue, "pr:resolve")) github_actions.resolveRequestLocally(d, true);
        if (!d.fork and dialog_views.linkButtonTagged(@src(), "or merge it in", hue, "pr:resolve_merge")) github_actions.resolveRequestLocally(d, false);
        return;
    }
    // In the order the line above says what is in the way.
    if (t.failed > 0) {
        if (dialog_views.alertButton(@src(), "See the checks", hue, "pr:see_checks")) pr_conversation.pr_tab = .checks;
        return;
    }
    // Changes asked for: to the conversations left, then onto its branch to
    // make them, then the reviewers asked again.
    if (std.mem.eql(u8, d.review, "CHANGES_REQUESTED")) {
        if (openThreads(d) > 0 and dialog_views.linkButtonTagged(@src(), "Show them", hue, "pr:to_threads")) {
            pr_conversation.pr_tab = .conversation;
            pr_scroll_thread = true;
        }
        if (!onRequestBranch(d)) {
            if (dialog_views.alertButton(@src(), "Check out to fix", hue, "pr:fix")) github_actions.checkoutRequest(d.number, d.head, d.fork);
        } else if (dialog_views.alertButton(@src(), "Re-request review", hue, "pr:rerequest")) rerequestReview(d);
        return;
    }
    if (std.mem.eql(u8, d.merge_state, "BEHIND")) {
        if (dialog_views.alertButton(@src(), "Update branch", hue, "pr:update")) updateRequestBranch(d);
        return;
    }
    if (d.draft) {
        if (dialog_views.alertButton(@src(), "Ready for review", hue, "pr:ready")) pr_conversation.requestOnRequest("Marking ready", "markPullRequestReadyForReview", d.id);
        return;
    }
    if (mergeUnknown(d) or t.running > 0) return;
    var num: [12]u8 = undefined;
    if (dialog_views.alertButton(@src(), "Merge…", hue, "pr:merge")) github_actions.ask(.merge_request, std.fmt.bufPrint(&num, "{d}", .{d.number}) catch return);
}

/// The base merged into the request's branch, on GitHub — refused there if
/// the branch moved since it was shown — then the request read again once
/// GitHub has had the time.
fn updateRequestBranch(d: pr.Detail) void {
    var path: [512]u8 = undefined;
    const body = if (d.head_sha.len > 0)
        std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"expected_head_sha\":\"{s}\"}}", .{d.head_sha}) catch "{}"
    else
        "{}";
    github_actions.requestApi("Updating the branch", "PUT", github_actions.apiPath(&path, "/pulls/{d}/update-branch", .{d.number}), body, .none);
    github_actions.api_fetch_after = true;
    pr_reread_at = app.frame_now_s + PR_REREAD_S;
}

/// When to read the open request again: GitHub answers "update branch"
/// before it has done it. 0 for never.
pub var pr_reread_at: i64 = 0;
pub const PR_REREAD_S = 4;

/// Whether GitHub has yet to say if the request can merge.
fn mergeUnknown(d: pr.Detail) bool {
    return std.mem.eql(u8, d.mergeable, "UNKNOWN") or std.mem.eql(u8, d.merge_state, "UNKNOWN");
}

/// When the open request's mergeability was last asked for again.
var pr_recheck_s: i64 = 0;
const PR_RECHECK_S = 3;

/// The tabs under the head: the conversation, the commits, the files, the
/// checks, each with how many.
pub fn requestTabs(d: pr.Detail, inset: f32) void {
    // Sideways when the pane is narrower than the four of them.
    var scroll = dvui.scrollArea(@src(), .{ .vertical = .none, .horizontal = .auto, .horizontal_bar = .auto_overlay }, .{
        .expand = .horizontal,
        .background = false,
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
    });
    defer scroll.deinit();
    // The first tab's icon under the head's first word.
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = false,
        .padding = .{ .x = @max(0, inset - style.space.md) },
    });
    defer bar.deinit();
    const tabs = [_]struct { pr_conversation.PrTab, []const u8, []const u8, usize }{
        .{ .conversation, dvui.entypo.chat, "Conversation", d.comments.len + d.reviews.len },
        .{ .commits, dvui.entypo.flow_line, "Commits", d.commits.len },
        .{ .files, dvui.entypo.text_document, "Files changed", @max(d.files, d.file_list.len) },
        .{ .checks, dvui.entypo.check, "Checks", d.checks.len },
    };
    for (tabs, 0..) |tab, i| {
        const on = pr_conversation.pr_tab == tab[0];
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .tag = dialog_views.frameTag("prtab", tab[2]),
            // Words on the page's ground; the one shown underlined in the
            // accent, on the bar's rule.
            .background = false,
            .margin = .{ .w = style.space.md },
            .padding = .{ .x = style.space.md, .y = style.space.md, .w = style.space.md, .h = style.space.md },
        });
        bw.processEvents();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
            defer row.deinit();
            const ink = if (on) style.accent() else if (bw.hovered()) style.text() else style.textMuted();
            dvui.label(@src(), "{s}", .{tab[2]}, .{ .font = style.body(), .color_text = .{ .color = ink }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            if (tab[3] > 0) dvui.label(@src(), "{d}", .{tab[3]}, .{
                .font = style.tinyBold(),
                .color_text = .{ .color = style.textMuted() },
                .background = true,
                .color_fill = .{ .color = style.surfaceRaised() },
                .corners = style.radius.tag,
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.sm },
                .padding = .{ .x = 5, .w = 5 },
            });
        }
        if (on) {
            const rs = bw.data().borderRectScale();
            (dvui.Rect.Physical{ .x = rs.r.x, .y = rs.r.y + rs.r.h - 2 * rs.s, .w = rs.r.w, .h = 2 * rs.s })
                .fill(.{}, .{ .color = .{ .color = style.accent() }, .fade = 0 });
        }
        if (bw.clicked()) pr_conversation.pr_tab = tab[0];
        bw.deinit();
    }
}

/// The commits of the request, newest last as the host lists them; a click
/// shows one in the graph, where it is there.
pub fn requestCommits(d: pr.Detail) void {
    if (d.commits.len == 0) return emptyNote("No commits.");
    var card = listCard(@src());
    defer card.deinit();
    for (d.commits, 0..) |c, i| {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .color_fill_hover = .{ .color = style.rowHover() },
            .border = .{ .h = if (i + 1 < d.commits.len) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        bw.processEvents();
        bw.drawBackground();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer row.deinit();
            search_view.avatarSized(@src(), 0, pr_list.requestAuthor(c.author), null, null, 20);
            var fit: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
            dvui.label(@src(), "{s}", .{graph_view.fitText(&fit, c.headline, style.small(), 420)}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
            dvui.label(@src(), "{s}", .{c.oid[0..@min(c.oid.len, 7)]}, .{ .font = style.mono(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.md }, .padding = dvui.Rect.all(0) });
            if (c.when > 0) {
                var when: [32]u8 = undefined;
                dvui.label(@src(), "{s}", .{search_view.relativeTime(&when, c.when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            }
        }
        if (bw.hovered()) dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r, .position = .vertical, .delay = 400_000 }, "Show it in the graph", .{}, .{ .font = style.small() });
        const clicked = bw.clicked();
        bw.deinit();
        if (clicked) showInGraph(c.oid);
    }
}

/// The graph, with the commit `hex` picked, if the history has it.
fn showInGraph(hex: []const u8) void {
    const h = app.history orelse return;
    for (h.commits) |commit| {
        var buf: [41]u8 = undefined;
        if (!std.mem.startsWith(u8, git.oidHex(commit.id, &buf), hex)) continue;
        revealInGraph(commit.id);
        return;
    }
    github_actions.setCommandError("That commit is not in the history here yet: fetch, then try again.");
}

/// The graph, with commit `id` picked and scrolled into view — what a click
/// on a branch, tag, stash or worktree in the sidebar does.
pub fn revealInGraph(id: git.Oid) void {
    const h = app.history orelse return;
    const index = h.indexOf(id) orelse
        return github_actions.setCommandError("That commit is not in the graph: its branch is hidden, or not walked.");
    app.new_tab_open = false;
    app.active_view = .graph;
    app.selectCommit(id);

    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(app.gpa);
    graph_view.shownRows(app.gpa, h.commits, &rows);
    const row = graph_view.listRow(@intCast(index), rows.items) orelse
        return github_actions.setCommandError("That commit is not in this file's history: close it to see the commit.");
    revealCommit(row);
}

/// The files the request changes, each with its size and the review threads
/// left on it; a button opens the whole change in the diff pane.
pub fn requestFiles(d: pr.Detail) void {
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.md } });
        defer line.deinit();
        dvui.label(@src(), "{d} file{s} changed", .{ d.file_list.len, window_chrome.plural(d.file_list.len) }, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        if (dialog_views.dialogButton(@src(), "Open the changes", true)) openRequestChanges(d);
    }
    if (d.file_list.len == 0) return emptyNote("The host did not list the files.");
    var card = listCard(@src());
    defer card.deinit();
    for (d.file_list, 0..) |f, i| {
        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .expand = .horizontal,
            // The card's own: dvui fills a box ruled on one side anyway.
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .border = .{ .h = if (i + 1 < d.file_list.len) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        defer row.deinit();
        {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer line.deinit();
            const base = std.fs.path.basename(f.path);
            dvui.label(@src(), "{s}", .{base}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            dvui.label(@src(), "{s}", .{std.fs.path.dirname(f.path) orelse ""}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .expand = .horizontal, .max_size_content = .width(0), .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
            pr_list.sizeMarks(f.additions, f.deletions);
        }
        // The threads on this file, under it, where they belong.
        var n: usize = 0;
        for (d.threads, 0..) |t, ti| if (std.mem.eql(u8, t.path, f.path)) {
            threadCard(i * 100 + n, ti, t, d, true);
            n += 1;
        };
    }
}

/// The whole change of a request in the diff pane: from where its branch
/// left the base to its head, as the compare view shows any two commits.
fn openRequestChanges(d: pr.Detail) void {
    const r = app.repo orelse return;
    const h = app.history orelse return;
    const remote = github_actions.defaultRemote() orelse "origin";
    const head = remoteTip(h, remote, d.head) orelse {
        github_actions.setCommandError("Its branch is not here: fetch, then try again.");
        return;
    };
    const base = remoteTip(h, remote, d.base) orelse {
        github_actions.setCommandError("Its base is not here: fetch, then try again.");
        return;
    };
    const from = r.mergeBase(base, head) orelse base;
    app.active_view = .graph;
    app.startCompare(from, head, d.base, d.head);
}

/// Where `remote`'s `branch` points, as the history last read it.
fn remoteTip(h: git.History, remote: []const u8, branch: []const u8) ?git.Oid {
    for (h.refs) |ref| {
        if (ref.kind != .remote) continue;
        const parts = github_actions.splitRemoteRef(ref.name);
        if (std.mem.eql(u8, parts.remote, remote) and std.mem.eql(u8, parts.branch, branch)) return ref.target;
    }
    return null;
}

/// The checks, by workflow: each with its result, how long it took, and its
/// log; the failed ones run again with one button.
pub fn requestChecks(d: pr.Detail) void {
    const t = tallyChecks(d.checks);
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.md } });
        defer line.deinit();
        dvui.label(@src(), "{d} passed · {d} failed · {d} running", .{ t.passed, t.failed, t.running }, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        if (t.failed > 0 and pr.host == .github and dialog_views.dialogButton(@src(), "Re-run the failed", true)) rerunFailed(d);
    }
    if (d.checks.len == 0) return emptyNote("No checks ran on it.");
    var card = listCard(@src());
    defer card.deinit();
    var last_group: []const u8 = "\x00";
    for (d.checks, 0..) |c, i| {
        if (!std.mem.eql(u8, c.group, last_group)) {
            last_group = c.group;
            dialog_views.dropHeading(@src(), i, if (c.group.len > 0) c.group else "STATUSES");
        }
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = false,
            .padding = .{ .x = style.space.md, .y = 4, .w = style.space.md, .h = 4 },
        });
        defer row.deinit();
        const ok = checkOk(c.result);
        const bad = checkBad(c.result);
        dvui.icon(@src(), "check_icon", if (ok) dvui.entypo.check else if (bad) dvui.entypo.cross else dvui.entypo.clock, .{
            .fill_color = .{ .color = if (ok) style.success() else if (bad) style.danger() else style.get().orange },
        }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .w = style.space.md } });
        dvui.label(@src(), "{s}", .{c.name}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
        if (c.seconds > 0) {
            var buf: [24]u8 = undefined;
            const took = if (c.seconds >= 60) std.fmt.bufPrint(&buf, "{d}m {d}s", .{ @divFloor(c.seconds, 60), @mod(c.seconds, 60) }) catch "" else std.fmt.bufPrint(&buf, "{d}s", .{c.seconds}) catch "";
            dvui.label(@src(), "{s}", .{took}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .w = style.space.md }, .padding = dvui.Rect.all(0) });
        }
        if (c.url.len > 0 and dialog_views.linkButtonTagged(@src(), "Log", style.accent(), null)) run.open(app.app_io, ".", c.url) catch {};
    }
}

/// Each workflow run with a failed check started again, its failed jobs
/// alone, by the run id in its link.
fn rerunFailed(d: pr.Detail) void {
    var ids: [8][]const u8 = undefined;
    var n: usize = 0;
    for (d.checks) |c| {
        if (!checkBad(c.result)) continue;
        const id = runIdOf(c.url) orelse continue;
        for (ids[0..n]) |seen| {
            if (std.mem.eql(u8, seen, id)) break;
        } else if (n < ids.len) {
            ids[n] = id;
            n += 1;
        }
    }
    if (n == 0) return github_actions.setCommandError("No workflow run to start again: the failing checks are not GitHub Actions.");
    var path: [512]u8 = undefined;
    for (ids[0..n]) |id| github_actions.requestApi("Re-running", "POST", github_actions.apiPath(&path, "/actions/runs/{s}/rerun-failed-jobs", .{id}), null, .none);
}

/// ".../actions/runs/123/job/456" -> "123".
pub fn runIdOf(url: []const u8) ?[]const u8 {
    const key = "/actions/runs/";
    const at = std.mem.indexOf(u8, url, key) orelse return null;
    const rest = url[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (end == 0) return null;
    for (rest[0..end]) |ch| if (!std.ascii.isDigit(ch)) return null;
    return rest[0..end];
}

/// The card a tab's list sits on.
fn listCard(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
    });
}

/// A line of faint text where a tab has nothing to show.
fn emptyNote(text: []const u8) void {
    dvui.label(@src(), "{s}", .{text}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0) });
}

/// How many conversations on lines of the diff are still open.
pub fn openThreads(d: pr.Detail) usize {
    var n: usize = 0;
    for (d.threads) |t| n += @intFromBool(!t.resolved);
    return n;
}

pub fn reviewHasThreads(d: pr.Detail, review: []const u8) bool {
    if (review.len == 0) return false;
    for (d.threads) |t| if (std.mem.eql(u8, t.review, review)) return true;
    return false;
}

pub fn reviewHasOpenThreads(d: pr.Detail, review: []const u8) bool {
    if (review.len == 0) return false;
    for (d.threads) |t| if (!t.resolved and std.mem.eql(u8, t.review, review)) return true;
    return false;
}

/// A conversation on a line, on the timeline: under the review that
/// opened it, set in a little under its card; or on its own mark.
pub fn threadRow(ti: usize, t: pr.Thread, d: pr.Detail, under_review: bool) void {
    var row = pr_conversation.TimelineRow.begin(60_000 + ti);
    if (under_review)
        row.rail(railNone, {})
    else
        row.rail(pr_conversation.railIcon, pr_conversation.RailIcon{ .icon = if (t.resolved) dvui.entypo.check else dvui.entypo.chat, .hue = if (t.resolved) style.success() else style.get().yellow });
    defer row.end();
    var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .x = if (under_review) style.space.xl else 0 } });
    defer inner.deinit();
    threadCard(ti, ti, t, d, false);
}

/// The rail going on past a step that has no mark of its own.
fn railNone(_: void) void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = pr_conversation.RAIL_DOT, .h = 0 } });
}

/// Scroll to the first open conversation on the next frame it is drawn.
pub var pr_scroll_thread = false;

/// A conversation on a line of the diff, folded to its head once resolved:
/// where, the diff it was left on, what was said — a suggestion as the
/// change it suggests, to apply here — and the answer: reply, resolve.
/// `ti` is its place in the request's threads, what its fold is kept by;
/// `under_file` when it is shown under its file's name, which it then
/// leaves out: "Line 3", not "login.ts:3" twice over.
fn threadCard(id: usize, ti: usize, t: pr.Thread, d: pr.Detail, under_file: bool) void {
    const fold_key = 70_000 + ti;
    const open = pr_conversation.cardOpen(fold_key, !t.resolved or pr_list.pr_threads_all);
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = if (t.resolved) style.borderSubtle() else style.get().yellow.opacity(0.45) },
        .corners = style.radius.row,
        .margin = .{ .h = style.space.md },
    });
    defer card.deinit();
    // Asked from the readiness line: the first one still open, in sight.
    if (pr_scroll_thread and !t.resolved) {
        pr_scroll_thread = false;
        dvui.scrollTo(.{ .screen_rect = card.data().borderRectScale().r });
    }

    // Where, on a head that folds it.
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = .{ .h = if (open) 1 else 0 },
            .color_border = .{ .color = style.borderSubtle() },
            .corners = if (open) .{ .tl = style.radius.row.tl, .tr = style.radius.row.tr } else style.radius.row,
            .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        });
        defer head.deinit();
        dvui.icon(@src(), "thread_fold", if (open) dvui.entypo.chevron_small_down else dvui.entypo.chevron_small_right, .{ .fill_color = .{ .color = style.textMuted() } }, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
        if (!under_file) dvui.icon(@src(), "thread_file", dvui.entypo.text_document, .{ .fill_color = .{ .color = style.textFaint() } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
        var where_buf: [512]u8 = undefined;
        const ranged = t.start_line > 0 and t.start_line < t.line;
        const where = if (under_file) (if (t.line == 0)
            "The file"
        else if (ranged)
            std.fmt.bufPrint(&where_buf, "Lines {d}–{d}", .{ t.start_line, t.line }) catch ""
        else
            std.fmt.bufPrint(&where_buf, "Line {d}", .{t.line}) catch "") else if (t.line == 0)
            t.path
        else if (ranged)
            std.fmt.bufPrint(&where_buf, "{s}:{d}–{d}", .{ t.path, t.start_line, t.line }) catch t.path
        else
            std.fmt.bufPrint(&where_buf, "{s}:{d}", .{ t.path, t.line }) catch t.path;
        dvui.label(@src(), "{s}", .{where}, .{ .font = if (under_file) style.small() else style.graphMono(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        if (t.outdated) tinyBadge(@src(), 0, "Outdated", style.get().yellow);
        if (t.resolved) tinyBadge(@src(), 1, "Resolved", style.success());
        // Folded, who started it and its first words.
        if (!open and t.comments.len > 0) {
            dvui.label(@src(), "{s}: {s}", .{ t.comments[0].author, pr_conversation.previewLine(t.comments[0].body) }, .{
                .font = style.small(),
                .color_text = .{ .color = style.textFaint() },
                .gravity_y = 0.5,
                .expand = .horizontal,
                .max_size_content = .width(0),
                .margin = .{ .x = style.space.sm },
                .padding = dvui.Rect.all(0),
            });
        } else _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (t.comments.len > 1) dvui.label(@src(), "{d} comments", .{t.comments.len}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        if (head.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) dvui.cursorSet(.hand);
        if (dvui.clicked(head.data(), .{})) pr_conversation.pr_cards.put(app.gpa, fold_key, !open) catch {};
    }
    if (!open) return;

    var inside = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(style.space.md) });
    defer inside.deinit();

    // The diff it was left on: the hunk's last lines, which end at the line —
    // unless a comment suggests a change, whose box shows those lines and
    // what they would become: the same code twice otherwise.
    const suggests = for (t.comments) |c| {
        if (suggestionOf(c.body) != null) break true;
    } else false;
    if (t.hunk.len > 0 and !suggests) {
        var code = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceInput() },
            .corners = style.radius.tag,
            .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.sm, .h = style.space.xs },
            .margin = .{ .h = style.space.sm },
        });
        defer code.deinit();
        const TAIL = 4;
        const count = std.mem.count(u8, t.hunk, "\n") + 1;
        var it = std.mem.splitScalar(u8, t.hunk, '\n');
        var n: usize = 0;
        while (it.next()) |raw| : (n += 1) {
            if (n + TAIL < count) continue;
            const text = std.mem.trimEnd(u8, raw, "\r");
            const hue = if (std.mem.startsWith(u8, text, "+")) style.success() else if (std.mem.startsWith(u8, text, "-")) style.danger() else style.textFaint();
            dvui.label(@src(), "{s}", .{text}, .{ .id_extra = n, .font = style.graphMono(), .color_text = .{ .color = hue }, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
        }
    }

    for (t.comments, 0..) |c, ci| threadComment(ci, c, t, d);

    const replying = pr_list.pr_reply_id.items.len > 0 and std.mem.eql(u8, pr_list.pr_reply_id.items, t.id);
    if (replying) {
        var field = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .min_size_content = .{ .h = 56 },
            .margin = .{ .y = style.space.sm, .h = style.space.sm },
        });
        defer field.deinit();
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_list.pr_reply, .allocator = app.gpa, .limit = 16384 } },
            .placeholder = "Reply — Ctrl+Enter sends it",
            .multiline = true,
            .break_lines = true,
        }, .{
            .tag = "pr:reply",
            .expand = .both,
            .background = false,
            .border = dvui.Rect.all(0),
            .corners = style.radius.input,
            .font = style.small(),
            .padding = dvui.Rect.all(style.space.sm),
        });
        const field_id = te.data().id;
        te.deinit();
        dialog_views.focusOnce(field_id);
    }

    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.xs } });
        defer line.deinit();
        if (replying) {
            if (dialog_views.dialogButtonTagged(@src(), "Reply", true, "pr:reply_send")) replyToThread();
            if (!t.resolved and t.can_resolve) {
                if (dialog_views.dialogButtonTagged(@src(), "Reply and resolve", false, "pr:reply_resolve")) {
                    replyToThread();
                    setThreadResolved(t.id, true);
                }
            }
            if (dialog_views.dialogButton(@src(), "Cancel", false)) {
                pr_list.pr_reply_id.clearRetainingCapacity();
                pr_list.pr_reply.clearRetainingCapacity();
            }
        } else if (t.can_reply) {
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.reply, "Reply", false, dialog_views.frameTag("pr:reply_to", t.id))) {
                pr_list.pr_reply_id.clearRetainingCapacity();
                pr_list.pr_reply_id.appendSlice(app.gpa, t.id) catch {};
                pr_list.pr_reply.clearRetainingCapacity();
            }
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (!t.resolved and t.can_resolve) {
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.check, "Resolve conversation", true, dialog_views.frameTag("pr:resolve", t.id))) setThreadResolved(t.id, true);
        } else if (t.resolved and t.can_unresolve) {
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.ccw, "Unresolve", false, dialog_views.frameTag("pr:unresolve", t.id))) setThreadResolved(t.id, false);
        }
    }
}

/// One reply in a thread: who and when on a line, the words under it,
/// indented under the picture.
fn threadComment(id: usize, c: pr.Note, t: pr.Thread, d: pr.Detail) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        // The card's own: dvui fills a box ruled on one side anyway, in the
        // theme's colour unless told — the dark band behind a reply.
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .y = if (id > 0) 1 else 0 },
        .color_border = .{ .color = style.borderSubtle() },
        .padding = .{ .y = style.space.sm, .h = style.space.xs },
    });
    defer box.deinit();
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.xs } });
        defer line.deinit();
        search_view.avatarSized(@src(), 0, pr_list.requestAuthor(c.author), null, null, 20);
        dvui.label(@src(), "{s}", .{c.author}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        const when = pr.isoSeconds(c.when);
        if (when > 0) {
            var buf: [32]u8 = undefined;
            dvui.label(@src(), "· {s}", .{search_view.relativeTime(&buf, when)}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .margin = .{ .x = style.space.sm }, .padding = dvui.Rect.all(0) });
        }
    }
    var text = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .x = 20 + style.space.sm } });
    defer text.deinit();
    // A suggestion is shown as the change it is — the lines it replaces and
    // what with — and can be applied to the file here.
    if (suggestionOf(c.body)) |sg| {
        if (std.mem.trim(u8, sg.before, " \t\r\n").len > 0) pr_conversation.markdownBody(sg.before);
        suggestionBox(id, t, d, sg.code);
        if (std.mem.trim(u8, sg.after, " \t\r\n").len > 0) pr_conversation.markdownBody(sg.after);
    } else pr_conversation.markdownBody(c.body);
}

/// A comment's first ```suggestion block: the words before it, the lines
/// it suggests, the words after.
const Suggestion = struct { before: []const u8, code: []const u8, after: []const u8 };

pub fn suggestionOf(body: []const u8) ?Suggestion {
    const fence = std.mem.indexOf(u8, body, "```suggestion") orelse return null;
    const code_start = (std.mem.indexOfScalarPos(u8, body, fence, '\n') orelse return null) + 1;
    var pos = code_start;
    while (pos <= body.len) {
        const eol = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        if (std.mem.startsWith(u8, std.mem.trim(u8, body[pos..eol], " \t\r"), "```")) {
            // The newline before the closing fence is not part of the code.
            const code_end = if (pos > code_start) pos - 1 else code_start;
            return .{ .before = body[0..fence], .code = body[code_start..code_end], .after = if (eol < body.len) body[eol + 1 ..] else "" };
        }
        if (eol == body.len) return null;
        pos = eol + 1;
    }
    return null;
}

/// The last `n` lines of the new side of a diff hunk — what a comment on
/// them saw — their `+` or space taken off. In `a`.
fn hunkTail(a: std.mem.Allocator, hunk: []const u8, n: usize) []const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, hunk, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '+' or line[0] == ' ') lines.append(a, line[1..]) catch return &.{};
    }
    return lines.items[lines.items.len -| n..];
}

/// The lines a thread is on: from its first through its last.
fn threadSpan(t: pr.Thread) usize {
    if (t.start_line > 0 and t.start_line < t.line) return t.line - t.start_line + 1;
    return 1;
}

/// A suggestion as a change: the lines it replaces, in red, what with, in
/// green; and the button that writes it into the file here — once the
/// request's branch is the one checked out.
fn suggestionBox(id: usize, t: pr.Thread, d: pr.Detail, code: []const u8) void {
    const a = dvui.currentWindow().arena();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.borderSubtle() },
        .corners = style.radius.input,
        .margin = .{ .y = style.space.xs, .h = style.space.xs },
    });
    defer box.deinit();
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.borderSubtle() },
            .corners = .{ .tl = style.radius.input.tl, .tr = style.radius.input.tr },
            .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.xs, .h = style.space.xs },
        });
        defer head.deinit();
        dvui.label(@src(), "Suggested change", .{}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (suggestionApplied(d.number, t.id)) {
            // Done here: said so, with the way to the change it made.
            dvui.icon(@src(), "applied", dvui.entypo.check, .{ .fill_color = .{ .color = style.success() } }, .{ .min_size_content = .{ .w = 11, .h = 11 }, .gravity_y = 0.5, .margin = .{ .w = style.space.xs } });
            dvui.label(@src(), "Applied here", .{}, .{ .font = style.small(), .color_text = .{ .color = style.success() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            if (dialog_views.chipButtonTagged(@src(), dvui.entypo.text_document, "See the change", false, dialog_views.frameTag("pr:applied", t.id))) {
                app.active_view = .graph;
                app.selectChange(t.path, .unstaged);
            }
        } else if (t.outdated) {
            dvui.label(@src(), "its lines have moved since", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        } else if (pr_conversation.requestOpen(d)) {
            if (!onRequestBranch(d)) {
                if (dialog_views.chipButtonTagged(@src(), dvui.entypo.download, "Check out to apply", false, dialog_views.frameTag("pr:apply_checkout", t.id))) github_actions.checkoutRequest(d.number, d.head, d.fork);
            } else if (dialog_views.chipButtonTagged(@src(), dvui.entypo.check, "Apply suggestion", true, dialog_views.frameTag("pr:apply", t.id))) applySuggestion(d.number, t, code);
        }
    }
    var lines = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = .{ .y = style.space.xs, .h = style.space.xs } });
    defer lines.deinit();
    // The lines before it in grey, for where it is; those it replaces in
    // red; what with in green.
    const span = threadSpan(t);
    const seen = hunkTail(a, t.hunk, span + SUGGESTION_CONTEXT);
    const before = seen.len -| span;
    for (seen, 0..) |old, n| diffLine(n, if (n < before) ' ' else '-', old);
    var it = std.mem.splitScalar(u8, code, '\n');
    var n: usize = 0;
    while (it.next()) |raw| : (n += 1) diffLine(1000 + n, '+', std.mem.trimEnd(u8, raw, "\r"));
}

/// One line of a suggestion's change, on a tint of what it does.
/// How many lines before a suggestion's show where it is.
const SUGGESTION_CONTEXT = 2;

/// One line of a suggestion's change, on a tint of what it does; a line
/// around it, `mark` a space, plain and faint.
fn diffLine(id: usize, mark: u8, text: []const u8) void {
    const context = mark == ' ';
    const hue = if (mark == '+') style.success() else if (context) style.textFaint() else style.danger();
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = !context,
        .color_fill = .{ .color = style.tint(hue) },
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer line.deinit();
    dvui.label(@src(), "{c}", .{mark}, .{ .font = style.graphMono(), .color_text = .{ .color = hue }, .min_size_content = .{ .w = 12 }, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{text}, .{ .font = style.graphMono(), .color_text = .{ .color = if (context) style.textFaint() else style.text() }, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
}

/// The branch a request is checked out as here: its own name, or
/// `pr/N` for one from a fork.
fn onRequestBranch(d: pr.Detail) bool {
    const h = app.history orelse return false;
    const head = h.head orelse return false;
    var buf: [32]u8 = undefined;
    const local = if (d.fork) std.fmt.bufPrint(&buf, "pr/{d}", .{d.number}) catch return false else d.head;
    return std.mem.eql(u8, head, local);
}

/// A suggestion written into the file here, over the lines it was left on —
/// once they still read as the comment saw them; otherwise the file moved
/// on since, and it would land on the wrong lines. The change is then the
/// working copy's, to look over, commit and push.
fn applySuggestion(number: u32, t: pr.Thread, code: []const u8) void {
    if (applySuggestionTo(dvui.currentWindow().arena(), app.repo_path.items, t, code)) |message| return github_actions.setCommandError(message);
    markApplied(number, t.id);
    repo_io.workChanged("Applying");
}

/// The suggestions applied here, by their thread's id, for request
/// `pr_applied_for`: their button says so rather than offer them again.
/// Fixed room, nothing to free: a review holds a handful.
var pr_applied: [16][64]u8 = undefined;
var pr_applied_len: [16]u8 = @splat(0);
pub var pr_applied_n: usize = 0;
pub var pr_applied_for: u32 = 0;

fn markApplied(number: u32, id: []const u8) void {
    if (pr_applied_for != number) {
        pr_applied_for = number;
        pr_applied_n = 0;
    }
    if (id.len > 64 or suggestionApplied(number, id)) return;
    const slot = pr_applied_n % pr_applied.len;
    @memcpy(pr_applied[slot][0..id.len], id);
    pr_applied_len[slot] = @intCast(id.len);
    pr_applied_n += 1;
}

fn suggestionApplied(number: u32, id: []const u8) bool {
    if (pr_applied_for != number) return false;
    for (0..@min(pr_applied_n, pr_applied.len)) |i| {
        if (std.mem.eql(u8, pr_applied[i][0..pr_applied_len[i]], id)) return true;
    }
    return false;
}

/// What went wrong, or null once it is written. In `a`, an arena.
pub fn applySuggestionTo(a: std.mem.Allocator, root: []const u8, t: pr.Thread, code: []const u8) ?[]const u8 {
    if (t.line == 0) return "GitHub did not say which lines that suggestion is for.";
    const abs = std.fs.path.join(a, &.{ root, t.path }) catch return "Out of memory.";
    const text = std.Io.Dir.cwd().readFileAlloc(app.app_io, abs, a, .limited(64 << 20)) catch return "Could not read that file here.";
    const crlf = std.mem.indexOf(u8, text, "\r\n") != null;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| lines.append(a, std.mem.trimEnd(u8, l, "\r")) catch return "Out of memory.";
    // A last newline leaves an empty piece after it, which is no line.
    const ends_nl = text.len > 0 and text[text.len - 1] == '\n';
    if (ends_nl) _ = lines.pop();

    const span = threadSpan(t);
    const first = t.line + 1 - span;
    const moved = std.fmt.allocPrint(a, "{s} has changed since that comment: apply it by hand.", .{t.path}) catch "The file has changed since that comment.";
    if (t.line > lines.items.len) return moved;
    const seen = hunkTail(a, t.hunk, span);
    if (seen.len == span) for (seen, 0..) |want, i| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, want, "\r"), lines.items[first - 1 + i])) return moved;
    };

    var out: std.ArrayList(u8) = .empty;
    const eol: []const u8 = if (crlf) "\r\n" else "\n";
    var wrote: usize = 0;
    const put = struct {
        fn f(o: *std.ArrayList(u8), al: std.mem.Allocator, n: *usize, line: []const u8, sep: []const u8) void {
            if (n.* > 0) o.appendSlice(al, sep) catch {};
            o.appendSlice(al, line) catch {};
            n.* += 1;
        }
    }.f;
    for (lines.items[0 .. first - 1]) |l| put(&out, a, &wrote, l, eol);
    // An empty suggestion takes the lines out.
    if (code.len > 0) {
        var ct = std.mem.splitScalar(u8, code, '\n');
        while (ct.next()) |l| put(&out, a, &wrote, std.mem.trimEnd(u8, l, "\r"), eol);
    }
    for (lines.items[t.line..]) |l| put(&out, a, &wrote, l, eol);
    if (ends_nl and wrote > 0) out.appendSlice(a, eol) catch {};
    std.Io.Dir.cwd().writeFile(app.app_io, .{ .sub_path = abs, .data = out.items }) catch return "Could not write that file.";
    return null;
}

/// A word on a tint of its colour: Resolved, Outdated.
pub fn tinyBadge(src: std.builtin.SourceLocation, id: usize, text: []const u8, hue: dvui.Color) void {
    var b = dvui.box(src, .{}, .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = style.tint(hue) },
        .corners = style.radius.tag,
        .gravity_y = 0.5,
        .padding = .{ .x = style.space.xs, .w = style.space.xs },
        .margin = .{ .x = style.space.xs },
    });
    defer b.deinit();
    dvui.label(@src(), "{s}", .{text}, .{ .font = style.tiny(), .color_text = .{ .color = hue }, .padding = dvui.Rect.all(0) });
}

/// A GitHub node id as it goes into a query: letters, digits, `_` and `-`,
/// nothing that could close the string around it.
pub fn safeNodeId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn setThreadResolved(id: []const u8, resolved: bool) void {
    if (!safeNodeId(id)) return;
    const v = std.fmt.allocPrint(dvui.currentWindow().arena(), "{{\"id\":\"{s}\"}}", .{id}) catch return;
    if (resolved)
        github_actions.requestGraphql("Resolving", "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id}}}", v, .none)
    else
        github_actions.requestGraphql("Reopening", "mutation($id:ID!){unresolveReviewThread(input:{threadId:$id}){thread{id}}}", v, .none);
}

/// The reply goes in as a variable, never spliced into the query; the box
/// empties once GitHub has it.
fn replyToThread() void {
    const text = std.mem.trim(u8, pr_list.pr_reply.items, " \n\t");
    if (text.len == 0 or !safeNodeId(pr_list.pr_reply_id.items)) return;
    const a = dvui.currentWindow().arena();
    github_actions.requestGraphql("Replying", "mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){comment{id}}}", github_actions.jsonFields(a, &.{ .{ "id", pr_list.pr_reply_id.items }, .{ "body", text } }), .clear_reply);
}

const PrAnswer = enum { comment, approve, request_changes };

/// The review box's three buttons: a comment on the conversation, or a
/// review with its verdict. The box empties once GitHub has it.
pub fn prAnswer(kind: PrAnswer) void {
    const text = std.mem.trim(u8, pr_list.pr_comment.items, " \n\t");
    const number = pr_list.pr_selected orelse return;
    const a = dvui.currentWindow().arena();
    var path: [512]u8 = undefined;
    switch (kind) {
        .comment => github_actions.requestApi("Commenting", "POST", github_actions.apiPath(&path, "/issues/{d}/comments", .{number}), github_actions.jsonFields(a, &.{.{ "body", text }}), .clear_comment),
        .approve => github_actions.requestApi("Approving", "POST", github_actions.apiPath(&path, "/pulls/{d}/reviews", .{number}), github_actions.jsonFields(a, &.{ .{ "event", "APPROVE" }, .{ "body", text } }), .clear_comment),
        .request_changes => github_actions.requestApi("Requesting changes", "POST", github_actions.apiPath(&path, "/pulls/{d}/reviews", .{number}), github_actions.jsonFields(a, &.{ .{ "event", "REQUEST_CHANGES" }, .{ "body", text } }), .clear_comment),
    }
}

/// The branches panel, unless hidden by hand or squeezed out by the
/// changes panel being dragged wide.
pub fn leftShown() bool {
    return app.show_sidebar and app.active_view == .graph and !left_squeezed;
}

/// Set while the panel on the right is wide enough to push the branches out:
/// the mirror of the branches pushing it out, which the content split does
/// by collapsing under its own minimum.
pub var left_squeezed: bool = false;
/// The width of the window's body, last frame.
pub var body_width: f32 = 0;
/// Narrower than this, the commit list gives up the branches panel.
const GRAPH_MIN = 380;

/// History: the commit list, and what the selected commit — or the working
/// tree — holds, beside it.
pub fn graphView() void {
    var split = dvui.paned(@src(), .{
        .direction = .horizontal,
        // Under this there is no room for both, and the list is the view.
        .collapsed_size = 760,
        .split_ratio = if (app.show_detail) &app.detail_split else &app.all_split,
        .handle_size = 1,
        .draw_in_deinit = false,
    }, .{ .expand = .both, .background = false });
    defer split.deinit();
    if (app.show_detail and app.show_sidebar and app.active_view != .pulls and !split.collapsed()) {
        const graph_w = split.data().contentRect().w * app.detail_split;
        const left_w = body_width * app.sidebar_split;
        // Back only once there is room for it again, so the seam does not
        // flicker between the two.
        const squeeze = if (left_squeezed) graph_w - left_w < GRAPH_MIN + 40 else graph_w < GRAPH_MIN;
        if (squeeze != left_squeezed) {
            left_squeezed = squeeze;
            dvui.refresh(null, @src(), null);
        }
    } else if (left_squeezed) {
        // Nothing on the right to push it out any more — the changes panel
        // hidden, or the list alone under the collapse width.
        left_squeezed = false;
        dvui.refresh(null, @src(), null);
    }

    // A file's diff takes the graph's place, and the panel on the right —
    // where it was picked — stays put for the next one.
    if (split.showFirst()) {
        if (app.diffOpen()) diff_view.diffPanel() else graph_view.graphPanel();
    }
    if (app.show_detail and split.showSecond()) commit_view.detailPanel();
}

/// True when this key event is exactly `code`, with Ctrl held or not as
/// asked, and nothing else: no Shift — a chord with it is `pressedShift`'s,
/// so Ctrl+Shift+Z is never also Ctrl+Z — no Alt, which keeps out AltGr
/// (Windows sends it as Ctrl+Alt, so AltGr+Z on a layout that types with
/// it would otherwise undo), and no Windows or Command key, the system's.
///
/// dvui has a named-keybind table for this, with fallback chains and user
/// overrides; this many shortcuts do not need one.
pub fn pressed(ke: dvui.Event.Key, code: dvui.enums.Key, ctrl: bool) bool {
    return ke.code == code and ke.mod.control() == ctrl and !ke.mod.shift() and !ke.mod.alt() and !ke.mod.command();
}

/// As `pressed`, for Ctrl+Shift+`code`.
pub fn pressedShift(ke: dvui.Event.Key, code: dvui.enums.Key) bool {
    return ke.code == code and ke.mod.control() and ke.mod.shift() and !ke.mod.alt() and !ke.mod.command();
}

/// Everything that can be done without the mouse.
///
/// Runs after the whole frame is built, over the events no widget claimed:
/// that is what keeps Esc from closing the diff while someone is typing a
/// commit message, without this having to know where the focus is.
///
/// None of them is Ctrl+Space, Ctrl+Shift alone or Alt-anything: Windows
/// gives those to the input method, the keyboard layout and AltGr.
pub fn shortcuts() void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        // Whatever a shortcut changed is drawn now, not at the next mouse
        // move: most of them only flip state — the palette, a panel, a tab —
        // and nothing else asks for a frame.
        defer if (e.handled) dvui.refresh(null, @src(), null);

        const ke = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (ke.action == .up) continue;

        // In a conflicted file the keys answer it — before the history's
        // arrows below, which would otherwise take ↑ and ↓. Only where it
        // is on screen: not from the requests' view over it.
        if (app.active_view == .graph and rebase_view.isConflictView() and !typing() and conflictKey(ke)) {
            e.handled = true;
            continue;
        }
        // Over the requests: ↑ ↓ (or k j) along the list, 1 to 4 for its tabs.
        if (app.active_view == .pulls and !app.new_tab_open and !typing() and pullsKey(ke)) {
            e.handled = true;
            continue;
        }

        // Up and down walk the history the way they walk a mail list: the pane
        // on the right follows, which is the whole point of reading a diff.
        // The only keys held down to repeat. Not over the pull requests,
        // which hide the history: there they would move it out of sight.
        if (app.active_view == .graph and (pressed(ke, .up, false) or pressed(ke, .down, false))) {
            e.handled = true;
            stepCommit(if (ke.code == .up) -1 else 1);
            continue;
        }
        // Everything else once per press: a held Ctrl+Z must not undo the
        // history away one repeat at a time.
        if (ke.action != .down) continue;

        // Esc backs out of one thing at a time, innermost first: the bar you
        // are answering, then the pane you are reading.
        if (pressed(ke, .escape, false)) {
            e.handled = true;
            if (app.prompt != null) {
                github_actions.clearPrompt();
            } else if (app.confirm != null) {
                github_actions.clearConfirm();
            } else if (commit_view.picked_changes.items.len > 0) {
                commit_view.clearPickedChanges();
            } else if (searchFocused()) {
                // Esc in the search empties it, and a second one puts it
                // away. Only there: everywhere else it means the pane, and
                // closing the diff you were reading because the cursor
                // happened to be in a field is a surprise.
                if (app.commit_filter.items.len > 0) app.commit_filter.clearRetainingCapacity() else graph_view.closeSearch();
            } else if (app.new_tab_open and app.repo != null) {
                app.new_tab_open = false;
            } else if (app.active_view == .pulls) {
                // Out of the requests, back to the history, as the tab's
                // second click does.
                app.closePulls();
            } else if (app.diffOpen()) {
                app.closeDiff();
            } else if (app.selection != .none) {
                app.clearSelection();
            } else if (graph_view.file_history.items.len > 0) {
                graph_view.clearFileHistory();
            }
            continue;
        }

        const Run = *const fn () void;
        const chord: ?Run = blk: {
            if ((pressed(ke, .enter, true) or pressed(ke, .kp_enter, true)) and app.active_view == .pulls) break :blk struct {
                fn f() void {
                    // A reply being written goes to its thread; otherwise
                    // the review box's text, as a comment: the button that
                    // needs nothing more.
                    if (pr_list.pr_reply_id.items.len > 0 and std.mem.trim(u8, pr_list.pr_reply.items, " \n\t").len > 0) return replyToThread();
                    if (std.mem.trim(u8, pr_list.pr_comment.items, " \n\t").len > 0) prAnswer(.comment);
                }
            }.f;
            if ((pressed(ke, .enter, true) or pressed(ke, .kp_enter, true)) and canCommit()) break :blk struct {
                fn f() void {
                    repo_io.requestAction(.commit);
                }
            }.f;
            // With nothing to commit, the same keys go on with what is under
            // way once its conflicts are answered.
            if ((pressed(ke, .enter, true) or pressed(ke, .kp_enter, true)) and github_connect.canContinue()) break :blk github_connect.requestContinue;
            if (pressed(ke, .f5, false) or pressed(ke, .r, true)) break :blk struct {
                fn f() void {
                    repo_io.requestAction(.refresh);
                }
            }.f;
            if (pressed(ke, .o, true)) break :blk struct {
                fn f() void {
                    repo_io.requestAction(.open_repo);
                }
            }.f;
            if (pressed(ke, .t, true)) break :blk struct {
                fn f() void {
                    app.new_tab_open = true;
                }
            }.f;
            if (pressedShift(ke, .t)) break :blk repo_io.openTerminal;
            if (pressed(ke, .p, true)) break :blk command_palette.openPalette;
            if (pressed(ke, .comma, true)) break :blk struct {
                fn f() void {
                    identity_view.openSettings(5);
                }
            }.f;
            if (pressed(ke, .b, true)) break :blk struct {
                fn f() void {
                    app.show_sidebar = !app.show_sidebar;
                }
            }.f;
            if (pressed(ke, .j, true)) break :blk struct {
                fn f() void {
                    app.show_detail = !app.show_detail;
                }
            }.f;
            // Ctrl+F: the commit search, where the graph is up.
            if (pressed(ke, .f, true)) break :blk struct {
                fn f() void {
                    // The search of what is on screen: the requests' in their
                    // view, not the hidden graph's.
                    if (app.active_view == .pulls) {
                        if (dvui.tagGet("pr_search")) |field| dvui.focusWidget(field.id, null, null);
                        return;
                    }
                    graph_view.search_open = true;
                    if (dvui.tagGet("commit_filter")) |field| dvui.focusWidget(field.id, null, null);
                }
            }.f;
            // Tab to tab, as a browser goes: Ctrl+Tab and Ctrl+PgDn on, the
            // Shift or PgUp back; Ctrl+Shift+PgUp/PgDn carries the tab along.
            if (pressed(ke, .tab, true) or pressed(ke, .page_down, true)) break :blk struct {
                fn f() void {
                    cycleTab(1);
                }
            }.f;
            if (pressedShift(ke, .tab) or pressed(ke, .page_up, true)) break :blk struct {
                fn f() void {
                    cycleTab(-1);
                }
            }.f;
            if (pressedShift(ke, .page_up)) break :blk struct {
                fn f() void {
                    shiftTab(-1);
                }
            }.f;
            if (pressedShift(ke, .page_down)) break :blk struct {
                fn f() void {
                    shiftTab(1);
                }
            }.f;
            // Not while typing: in a text field these are the field's own
            // close, undo and redo, and taking back a commit from inside the
            // message box is not what anybody pressed them for.
            if (typing()) break :blk null;
            if (pressed(ke, .w, true)) break :blk github_actions.closeShownTab;
            if (pressed(ke, .z, true)) break :blk github_actions.requestUndo;
            if (pressedShift(ke, .z) or pressed(ke, .y, true)) break :blk github_actions.requestRedo;
            break :blk null;
        };
        if (chord) |run_it| {
            e.handled = true;
            run_it();
        }
    }
}

/// The requests' keys: ↑ ↓ or k j along the list, held to repeat; 1 2 3 4
/// for the conversation, the commits, the files and the checks.
fn pullsKey(ke: dvui.Event.Key) bool {
    if (pressed(ke, .down, false) or pressed(ke, .j, false)) {
        pr_list.stepRequest(1);
        return true;
    }
    if (pressed(ke, .up, false) or pressed(ke, .k, false)) {
        pr_list.stepRequest(-1);
        return true;
    }
    if (ke.action != .down) return false;
    const tabs = [_]struct { dvui.enums.Key, pr_conversation.PrTab }{ .{ .one, .conversation }, .{ .two, .commits }, .{ .three, .files }, .{ .four, .checks } };
    for (tabs) |tab| if (pressed(ke, tab[0], false)) {
        pr_conversation.pr_tab = tab[1];
        return true;
    };
    return false;
}

/// The conflict view's keys, GitComet's way: ↑ ↓ or F2 F3 from region to
/// region, 1 2 3 keep the left side, the right one or both, U or Ctrl+Z take
/// the last pick back, Enter stages a file with nothing left in it and goes
/// to the next, F4 goes to the next conflicted file. True when one was it.
fn conflictKey(ke: dvui.Event.Key) bool {
    const step: i2 = if (pressed(ke, .down, false) or pressed(ke, .f3, false) or pressed(ke, .j, false))
        1
    else if (pressed(ke, .up, false) or pressed(ke, .f2, false) or pressed(ke, .k, false))
        -1
    else
        0;
    if (step != 0) {
        moveConflictFocus(step);
        return true;
    }
    // Picks and stages once per press: a held key is not five picks.
    if (ke.action != .down) return false;
    if (pressed(ke, .one, false) or pressed(ke, .kp_1, false)) return pickFocused(.ours);
    if (pressed(ke, .two, false) or pressed(ke, .kp_2, false)) return pickFocused(.theirs);
    if (pressed(ke, .three, false) or pressed(ke, .kp_3, false)) return pickFocused(.both);
    if (pressed(ke, .u, false) or pressed(ke, .z, true)) {
        // Ctrl+Z here never reaches the reflog's undo: mid-merge it would
        // reset under it.
        if (app.resolve_undo.items.len > 0) repo_io.requestAction(.undo_resolve);
        return true;
    }
    if ((pressed(ke, .enter, false) or pressed(ke, .kp_enter, false)) and app.conflicts.len == 0 and !app.conflict_binary and
        app.conflict_kind != .deleted_by_us and app.conflict_kind != .deleted_by_them)
    {
        repo_io.requestAction(.stage_next);
        return true;
    }
    if (pressed(ke, .f4, false)) {
        github_connect.openNextConflict();
        return true;
    }
    return false;
}

fn moveConflictFocus(step: i2) void {
    if (app.conflicts.len == 0) return;
    if (step > 0) {
        app.conflict_focus = @min(app.conflict_focus + 1, app.conflicts.len - 1);
    } else {
        app.conflict_focus -|= 1;
    }
    app.conflict_reveal = true;
}

fn pickFocused(side: git.ConflictSide) bool {
    if (app.conflict_focus >= app.conflicts.len) return false;
    github_actions.requestResolve(app.conflict_focus, side);
    return true;
}

/// The tab `delta` along from the one shown, across groups, round the ends.
fn cycleTab(delta: i2) void {
    if (app.repo == null) return;
    var total: usize = 0;
    var at: usize = 0;
    for (tab_strip.groups.items, 0..) |group, g| {
        if (group.ws != tab_strip.active_ws) continue;
        if (g == tab_strip.active_group) at = total + tab_strip.active_tab;
        total += group.tabs.items.len;
    }
    if (total < 2) return;
    const next = (at + total + @as(usize, if (delta > 0) 1 else total - 1)) % total;
    var base: usize = 0;
    for (tab_strip.groups.items, 0..) |group, g| {
        if (group.ws != tab_strip.active_ws) continue;
        if (next < base + group.tabs.items.len) return github_actions.requestTab(.{ .select_in = .{ g, next - base } });
        base += group.tabs.items.len;
    }
}

/// The tab shown, one place left or right in its group.
fn shiftTab(delta: i2) void {
    if (app.repo == null or app.new_tab_open) return;
    if (delta < 0 and tab_strip.active_tab == 0) return;
    const to = if (delta < 0) tab_strip.active_tab - 1 else tab_strip.active_tab + 1;
    github_actions.requestTab(.{ .tab_at = .{ tab_strip.active_group, tab_strip.active_tab, tab_strip.active_group, to } });
}

/// Whether a text field has the keyboard — the one a focused text entry asks
/// the backend to put an input method over.
pub fn typing() bool {
    return dvui.currentWindow().textInputRequested() != null;
}

/// True when the commit search box is what has the keyboard.
fn searchFocused() bool {
    const field = dvui.tagGet("commit_filter") orelse return false;
    const focused = dvui.focusedWidgetId() orelse return false;
    return focused == field.id;
}

/// Whether the commit button — and Ctrl+Enter — would do anything.
///
/// Amending rewrites the last commit, so it is legitimate with nothing staged:
/// that is how you fix a message.
pub fn canCommit() bool {
    if (app.commit_summary.items.len == 0) return false;
    if (app.amend) return true;
    const w = app.work orelse return false;
    return w.staged.len > 0;
}

/// Select the commit `delta` rows from the one selected now.
///
/// Only from the graph or another commit: in a file diff, a blame or the rebase
/// composer, an arrow key means what that pane says it means.
pub fn stepCommit(delta: i2) void {
    const h = app.history orelse return;

    // The commits the search lets through — every one without a search —
    // in the list's order: while searching, ↑ and ↓ go match to match.
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(app.gpa);
    graph_view.shownRows(app.gpa, h.commits, &rows);
    if (rows.items.len == 0) return;

    const row: usize = switch (app.selection) {
        .none => if (delta > 0) 0 else rows.items.len - 1,
        .commit => |id| blk: {
            const index = h.indexOf(id) orelse break :blk 0;
            const at = std.mem.indexOfScalar(u32, rows.items, @intCast(index)) orelse {
                // A commit the search leaves out: the next match that way.
                const after = for (rows.items, 0..) |r, k| {
                    if (r > index) break k;
                } else rows.items.len;
                if (delta > 0) break :blk if (after < rows.items.len) after else return;
                break :blk if (after > 0) after - 1 else return;
            };
            const next = @as(i64, @intCast(at)) + delta;
            // Stop at the ends rather than wrapping: a list that wraps loses
            // you the moment you lean on the key.
            if (next < 0 or next >= rows.items.len) return;
            break :blk @intCast(next);
        },
        else => return,
    };

    app.selectCommit(h.commits[rows.items[row]].id);
    if (graph_view.listRow(rows.items[row], rows.items)) |at| revealCommit(at);
}

/// Scroll the graph so list row `row` is on screen, for whenever it comes back.
pub fn revealCommit(row: usize) void {
    const rh = style.graph_row;
    const y = @as(f32, @floatFromInt(row)) * rh;
    const view = app.graph_scroll.viewport;
    // Viewport height is last frame's, which is this frame's on every frame
    // but the first.
    if (view.h <= 0) return;

    if (y < view.y) {
        app.graph_scroll.viewport.y = y;
    } else if (y + rh > view.y + view.h) {
        app.graph_scroll.viewport.y = y + rh - view.h;
    }
}

/// Name the window after what it is showing.
///
/// Compared against what is already up rather than set every frame: this is a
/// call into the window manager, and the answer changes about once a minute.
var window_title: [256]u8 = undefined;
var window_title_len: usize = 0;

pub fn updateWindowTitle() void {
    var buf: [256]u8 = undefined;

    const text = blk: {
        if (app.repo == null) break :blk "Zit";
        const branch = if (app.history) |h| (h.head orelse "detached") else "";
        if (branch.len == 0) break :blk std.fmt.bufPrint(&buf, "{s} — Zit", .{app.repo_name}) catch "Zit";
        break :blk std.fmt.bufPrint(&buf, "{s} · {s} — Zit", .{ app.repo_name, branch }) catch "Zit";
    };

    if (std.mem.eql(u8, text, window_title[0..window_title_len])) return;
    if (text.len > window_title.len) return;

    @memcpy(window_title[0..text.len], text);
    window_title_len = text.len;

    const cw = dvui.currentWindow();
    cw.backend.title(cw, text);
}
