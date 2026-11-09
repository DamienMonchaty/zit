const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const pr = @import("../github/pr.zig");
const github = @import("../github/github.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const search_view = @import("search_view.zig");
const rebase_view = @import("rebase_view.zig");
const dialog_views = @import("dialog_views.zig");
const identity_view = @import("identity_view.zig");
const repo_io = @import("../core/repo_io.zig");
const github_actions = @import("../github/github_actions.zig");
const pr_list = @import("pr_list.zig");
const pr_editor = @import("pr_editor.zig");
const app = @import("../main.zig");

// === Creating a request ===
//
// Filled in from what is already known, no guessing: the base is where the
// remote's HEAD points, the title the branch's one commit or its name, the
// description the repository's template and the commits it brings.

pub var pr_new_open = false;
var pr_new_rect: dvui.Rect = .{};
var pr_new_title: std.ArrayList(u8) = .empty;
var pr_new_body: std.ArrayList(u8) = .empty;
var pr_new_base: std.ArrayList(u8) = .empty;
pub var pr_new_reviewers: std.ArrayList(u8) = .empty;
pub var pr_new_draft = false;
/// The branch it comes from: the one checked out, unless another is picked.
pub var pr_new_head: std.ArrayList(u8) = .empty;
/// Who it is assigned to, and its labels: comma-separated, as picked.
pub var pr_new_assignees: std.ArrayList(u8) = .empty;
pub var pr_new_labels: std.ArrayList(u8) = .empty;
/// What is typed over the list of the picker open, and which one that is:
/// another opening starts with nothing typed.
pub var pick_filter: std.ArrayList(u8) = .empty;
pub var pick_open: ?usize = null;
/// The request is being made: the dialog waits on it, then gives way to it.
pub var pr_creating = false;
/// The number GitHub gave the one just made, until the calls after it —
/// its reviewers, assignees, labels — are done and it can be opened.
pub var pr_created: u32 = 0;

pub fn openPrCreate() void {
    const h = app.history orelse return;
    const branch = h.head orelse return github_actions.setCommandError("Check out a branch first: a request is made from one.");
    pr_new_open = true;
    pr_new_rect = .{};
    pr_new_draft = false;
    for ([_]*std.ArrayList(u8){ &pr_new_title, &pr_new_body, &pr_new_base, &pr_new_reviewers, &pr_new_head, &pr_new_assignees, &pr_new_labels }) |t| t.clearRetainingCapacity();
    pr_new_head.appendSlice(app.gpa, branch) catch {};
    // Who can be asked, the labels: read while the form is filled in.
    pr.loadMeta(app.repo_path.items);

    // The base: what the remote calls its HEAD, "origin/main" -> "main".
    const remote = github_actions.defaultRemote() orelse "origin";
    var ref_buf: [96]u8 = undefined;
    const head_ref = std.fmt.bufPrint(&ref_buf, "refs/remotes/{s}/HEAD", .{remote}) catch "";
    if (run.capture(app.gpa, app.app_io, app.repo_path.items, &.{ "git", "symbolic-ref", "-q", "--short", head_ref })) |answer| {
        defer app.gpa.free(answer.out);
        const name = std.mem.trim(u8, answer.out, " \r\n");
        if (answer.ok and std.mem.startsWith(u8, name, remote) and name.len > remote.len + 1) pr_new_base.appendSlice(app.gpa, name[remote.len + 1 ..]) catch {};
    } else |_| {}
    if (pr_new_base.items.len == 0) pr_new_base.appendSlice(app.gpa, if (tab_strip.default_branch.items.len > 0) tab_strip.default_branch.items else "main") catch {};

    // The commits it brings, oldest first.
    var range_buf: [256]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buf, "{s}/{s}..HEAD", .{ remote, pr_new_base.items }) catch "";
    var subjects: []const u8 = "";
    const log = run.capture(app.gpa, app.app_io, app.repo_path.items, &.{ "git", "log", "--reverse", "--format=%s", range }) catch null;
    defer if (log) |l| app.gpa.free(l.out);
    if (log) |l| if (l.ok) {
        subjects = std.mem.trim(u8, l.out, "\n");
    };
    const count = if (subjects.len == 0) 0 else std.mem.count(u8, subjects, "\n") + 1;

    // One commit says what it does; several, the branch's name does.
    if (count == 1) pr_new_title.appendSlice(app.gpa, subjects) catch {} else pr_new_title.appendSlice(app.gpa, humanBranch(dvui.currentWindow().arena(), branch)) catch {};

    if (prTemplate()) |template| {
        defer app.gpa.free(template);
        pr_new_body.appendSlice(app.gpa, std.mem.trim(u8, template, " \n")) catch {};
        pr_new_body.appendSlice(app.gpa, "\n\n") catch {};
    }
    if (count > 1) {
        pr_new_body.appendSlice(app.gpa, "## Commits\n\n") catch {};
        var it = std.mem.splitScalar(u8, subjects, '\n');
        while (it.next()) |subject| pr_new_body.print(app.gpa, "- {s}\n", .{subject}) catch {};
    }
}

/// "PROJ-81-Front-Login" -> "PROJ-81: Front Login"; "feat/new-thing"
/// -> "feat: new thing". The ticket or the prefix kept as it is written.
pub fn humanBranch(a: std.mem.Allocator, branch: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = branch;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        out.print(a, "{s}: ", .{rest[0..slash]}) catch return branch;
        rest = rest[slash + 1 ..];
    } else if (ticketOf(rest)) |ticket| {
        out.print(a, "{s}: ", .{ticket}) catch return branch;
        rest = std.mem.trimStart(u8, rest[ticket.len..], "-_");
    }
    for (rest) |ch| out.append(a, if (ch == '-' or ch == '_') ' ' else ch) catch return branch;
    return out.items;
}

/// "PROJ-81-…" -> "PROJ-81": letters, a dash, digits, at the start.
pub fn ticketOf(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < name.len and std.ascii.isAlphabetic(name[i])) i += 1;
    if (i == 0 or i >= name.len or name[i] != '-') return null;
    var j = i + 1;
    while (j < name.len and std.ascii.isDigit(name[j])) j += 1;
    if (j == i + 1) return null;
    return name[0..j];
}

/// The repository's pull request template, where GitHub looks for one.
fn prTemplate() ?[]u8 {
    const places = [_][]const u8{ ".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", "docs/pull_request_template.md", "pull_request_template.md", ".gitlab/merge_request_templates/Default.md" };
    const dir = std.Io.Dir.cwd();
    for (places) |place| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ std.mem.trimEnd(u8, app.repo_path.items, "/"), place }) catch continue;
        return dir.readFileAlloc(app.app_io, path, app.gpa, .limited(64 * 1024)) catch continue;
    }
    return null;
}

pub fn clearPrCreate() void {
    pr_new_open = false;
    for ([_]*std.ArrayList(u8){ &pr_new_title, &pr_new_body, &pr_new_base, &pr_new_reviewers }) |t| {
        t.deinit(app.gpa);
        t.* = .empty;
    }
}

pub fn prCreateDialog() void {
    if (!pr_new_open) return;
    const h = app.history orelse return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &pr_new_rect, &pr_new_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);
    identity_view.dialogHeader(@src(), dvui.entypo.merge, "New pull request", h.head orelse "", &pr_new_open);

    // A fixed width: the description comes filled in with the template and
    // the commits, and its longest line would otherwise set the dialog's.
    var body = identity_view.dialogBody(@src(), @min(PR_CREATE_W, win.w - 80));

    // The two branches, as GitHub's compare bar has them: into, from.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        branchPicker(0, "Into", &pr_new_base, .remote);
        branchPicker(1, "From", &pr_new_head, .local);
    }

    // Pushed first: the host can only open one on a branch it has.
    const head = std.mem.trim(u8, pr_new_head.items, " ");
    const on_head = if (h.head) |name| std.mem.eql(u8, name, head) else false;
    const pushed = if (on_head)
        h.tracking.upstream != null and h.tracking.ahead == 0
    else
        remoteHas(head);
    if (!pushed and head.len > 0) {
        const orange = style.get().orange;
        var note = dialog_views.alertBox(@src(), 0, orange, dvui.entypo.upload, .{ .h = style.space.lg });
        defer note.deinit();
        const missing = !on_head or h.tracking.upstream == null;
        dialog_views.alertText(@src(), if (missing) "The branch is not on the remote yet: push it first." else "Some commits are not pushed yet: push them first.", orange);
        if (dialog_views.alertButton(@src(), "Push", orange, "pr_new:push")) {
            if (on_head) {
                repo_io.requestNetwork("Pushing", &.{ "-c", "push.autoSetupRemote=true", "push" });
            } else if (github_actions.defaultRemote()) |remote| repo_io.requestNetwork("Pushing", &.{ "push", "-u", remote, head });
        }
    }

    var entered = false;
    _ = dialog_views.dialogField(@src(), 0, "Title", &pr_new_title, "What it does", true, &entered);
    dialog_views.dialogLabel(@src(), "Description");
    {
        const te = dialog_views.textField(@src(), .{
            .text = .{ .array_list = .{ .backing = &pr_new_body, .allocator = app.gpa, .limit = 65536 } },
            .multiline = true,
            .break_lines = true,
            .placeholder = "Why, and how to try it",
        }, identity_view.settingsInput().override(.{ .tag = "pr_new:body", .min_size_content = .{ .h = 160 }, .max_size_content = .size(.{ .w = 0, .h = 260 }), .margin = .{ .h = style.space.lg } }));
        te.deinit();
    }

    // Who, and what it is about: GitHub's sidebar, as three pickers.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer line.deinit();
        peoplePicker(2, "Reviewers", &pr_new_reviewers, "Ask for reviews", true, "pr_new:reviewers");
        peoplePicker(3, "Assignees", &pr_new_assignees, "Assign someone", false, "pr_new:assignees");
        labelPicker(4, &pr_new_labels, "pr_new:labels");
    }
    // What GitHub refused, where it was asked.
    if (!pr_creating) if (tab_strip.command_error) |why| {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .background = false, .padding = dvui.Rect.all(0) });
        tl.addText(dialog_views.firstLine(why), .{ .font = style.small(), .color_text = .{ .color = style.danger() } });
        tl.deinit();
    };
    body.deinit();

    {
        var line = identity_view.dialogFooter(@src());
        defer line.deinit();
        typePicker(5, &pr_new_draft, "pr_new:type");
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (pr_creating) {
            // Waiting on GitHub: what for, and nothing to click twice.
            rebase_view.loadingSpinner(@src());
            dvui.label(@src(), "Creating the pull request…", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        } else {
            if (dialog_views.dialogButton(@src(), "Cancel", false)) pr_new_open = false;
            if (pushed and dialog_views.dialogButton(@src(), if (pr_new_draft) "Create draft" else "Create pull request", true)) createRequest();
        }
    }
    if (dialog_views.escapePressed() and pick_open == null and !pr_creating) pr_new_open = false;
}

/// The create dialog's width: two branches side by side, three pickers.
pub const PR_CREATE_W: f32 = 620;

/// Whether the default remote has a branch of that name, as last fetched.
fn remoteHas(branch: []const u8) bool {
    const h = app.history orelse return false;
    const remote = github_actions.defaultRemote() orelse return false;
    for (h.refs) |ref| {
        if (ref.kind != .remote) continue;
        const split = github_actions.splitRemoteRef(ref.name);
        if (std.mem.eql(u8, split.remote, remote) and std.mem.eql(u8, split.branch, branch)) return true;
    }
    return false;
}

/// A field that drops a list to pick from: what is picked on its face, or
/// what to do when nothing is. `end` closes it.
pub const Picker = struct {
    button: window_chrome.DropButton,
    menu: ?*dvui.FloatingMenuWidget,
    id: usize,

    pub fn end(self: Picker) void {
        self.button.end(self.menu);
    }
};

pub fn picker(id: usize, face: []const u8, placeholder: []const u8, tag: []const u8) Picker {
    var button = window_chrome.DropButton.begin(@src(), .{
        .id_extra = id,
        .tag = tag,
        .expand = .horizontal,
        .gravity_y = 0,
        .background = false,
        .color_fill_hover = .{ .color = style.rowHover() },
        .corners = style.radius.input,
        .padding = dvui.Rect.all(0),
    });
    const field_w = button.item.data().rect.w;
    button.min_w = @max(field_w, 240);
    {
        const lit = button.item.show_active or button.item.mouse_over;
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (lit) style.rowHover() else style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
        });
        defer box.deinit();
        var buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
        const text = if (face.len > 0) face else placeholder;
        dvui.label(@src(), "{s}", .{graph_view.fitText(&buf, text, style.small(), @max(40, field_w - 48))}, .{
            .font = style.small(),
            .color_text = .{ .color = if (face.len > 0) style.text() else style.textFaint() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
        dvui.icon(@src(), "pick_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs },
        });
    }
    const menu = button.open();
    // Opened afresh: nothing typed over its list yet.
    if (menu != null and pick_open != id) {
        pick_open = id;
        pick_filter.clearRetainingCapacity();
    } else if (menu == null and pick_open == id) pick_open = null;
    return .{ .button = button, .menu = menu, .id = id };
}

/// The field typed over a picker's list, and whether `text` gets through it.
fn pickSearch(placeholder: []const u8) void {
    dialog_views.focusOnce(dialog_views.searchField(@src(), &pick_filter, placeholder, "pick_filter", .{ .x = style.space.xs, .y = style.space.xs, .w = style.space.xs, .h = style.space.sm }));
}

fn pickShown(text: []const u8, also: []const u8) bool {
    const needle = std.mem.trim(u8, pick_filter.items, " ");
    if (needle.len == 0) return true;
    return std.ascii.findIgnoreCase(text, needle) != null or std.ascii.findIgnoreCase(also, needle) != null;
}

/// The scrolling list under a picker's search: as tall as it needs, up to
/// a bound.
pub fn pickList() *dvui.ScrollAreaWidget {
    return dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .max_size_content = .height(@min(300, dvui.windowRect().h * 0.5)),
        .background = false,
    });
}

/// One row of a picker's list: a tick when picked, a colour where it has
/// one, its name, what more there is to say of it.
pub fn pickRow(id: usize, text: []const u8, sub: []const u8, picked: bool, hue: ?dvui.Color) bool {
    var mi = dvui.menuItem(@src(), .{}, .{
        .id_extra = id,
        .tag = dialog_views.frameTag("pick", text),
        .expand = .horizontal,
        .corners = style.radius.input,
        .color_fill_hover = .{ .color = style.accentDim() },
        .padding = .{ .x = style.space.md, .y = graph_view.MENU_ROW_PAD_Y, .w = style.space.md, .h = graph_view.MENU_ROW_PAD_Y },
    });
    defer mi.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer row.deinit();
    dvui.icon(@src(), "pick_tick", dvui.entypo.check, .{ .fill_color = .{ .color = if (picked) style.accent() else dvui.Color.transparent } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
    });
    if (hue) |c| {
        var dot = dvui.box(@src(), .{}, .{
            .background = true,
            .color_fill = .{ .color = c },
            .corners = .all(5),
            .min_size_content = .{ .w = 10, .h = 10 },
            .max_size_content = .size(.{ .w = 10, .h = 10 }),
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
        });
        dot.deinit();
    }
    dvui.label(@src(), "{s}", .{text}, .{
        .font = if (picked) style.smallBold() else style.small(),
        .color_text = .{ .color = style.text() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    if (sub.len > 0) dvui.label(@src(), "{s}", .{sub}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    return mi.activeRect() != null;
}

const BranchSide = enum { remote, local };

/// A branch to pick: the remote's for where it goes, yours for where it
/// comes from.
pub fn branchPicker(id: usize, caption: []const u8, value: *std.ArrayList(u8), side: BranchSide) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false, .margin = .{ .w = if (side == .remote) style.space.md else 0 } });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), caption);
    const p = picker(id, value.items, "Pick a branch", if (side == .remote) "pr_new:base" else "pr_new:head");
    defer p.end();
    const m = p.menu orelse return;
    const h = app.history orelse return;
    pickSearch("Find a branch…");
    var list = pickList();
    defer list.deinit();
    const remote = github_actions.defaultRemote() orelse "origin";
    var shown: usize = 0;
    for (h.refs, 0..) |ref, i| {
        const name = switch (side) {
            .remote => blk: {
                if (ref.kind != .remote) continue;
                const split = github_actions.splitRemoteRef(ref.name);
                if (!std.mem.eql(u8, split.remote, remote) or std.mem.eql(u8, split.branch, "HEAD")) continue;
                break :blk split.branch;
            },
            .local => if (ref.kind == .local) ref.name else continue,
        };
        if (!pickShown(name, "")) continue;
        if (shown >= dialog_views.MAX_BRANCH_CHOICES) break;
        shown += 1;
        if (pickRow(i, name, if (side == .local and !remoteHas(name)) "not pushed" else "", std.mem.eql(u8, value.items, name), null)) {
            value.clearRetainingCapacity();
            value.appendSlice(app.gpa, name) catch {};
            m.close();
        }
    }
    if (shown == 0) dialog_views.dropHeading(@src(), 20, "NO BRANCH BY THAT NAME");
}

/// People to pick, from those who can be asked on the host: reviewers or
/// assignees.
pub fn peoplePicker(id: usize, caption: []const u8, list: *std.ArrayList(u8), placeholder: []const u8, reviewers: bool, tag: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false, .margin = .{ .w = style.space.md } });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), caption);
    const p = picker(id, list.items, placeholder, tag);
    defer p.end();
    _ = p.menu orelse return;
    _ = peopleRows(list, reviewers);
}

/// A people picker's list: a field to narrow it, then everyone who can be
/// asked, ticked where they are in `list` — you are not among the
/// reviewers of your own request. The login a click toggled, if one did.
pub fn peopleRows(list: *std.ArrayList(u8), reviewers: bool) ?[]const u8 {
    switch (pr.meta_status) {
        .idle, .loading => {
            dialog_views.dropHeading(@src(), 0, "LOADING…");
            return null;
        },
        .failed => {
            dialog_views.dropHeading(@src(), 0, "COULD NOT READ WHO CAN BE ASKED");
            return null;
        },
        .ready => {},
    }
    pickSearch("Find someone…");
    var rows = pickList();
    defer rows.deinit();
    var shown: usize = 0;
    var toggled: ?[]const u8 = null;
    for (pr.meta.people, 0..) |person, i| {
        if (reviewers and window_chrome.me_gh.items.len > 0 and std.ascii.eqlIgnoreCase(person.login, window_chrome.me_gh.items)) continue;
        if (!pickShown(person.login, person.name)) continue;
        shown += 1;
        if (pickRow(i, person.login, person.name, listHas(list.items, person.login), null)) {
            listToggle(list, person.login);
            toggled = person.login;
        }
    }
    if (shown == 0) dialog_views.dropHeading(@src(), 1, "NOBODY BY THAT NAME");
    return toggled;
}

/// The repository's labels, each with its colour and what it is for.
pub fn labelPicker(id: usize, list: *std.ArrayList(u8), tag: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), "Labels");
    const p = picker(id, list.items, "Add labels", tag);
    defer p.end();
    _ = p.menu orelse return;
    _ = labelRows(list);
}

/// A label picker's list; the label a click toggled, if one did.
pub fn labelRows(list: *std.ArrayList(u8)) ?[]const u8 {
    switch (pr.meta_status) {
        .idle, .loading => {
            dialog_views.dropHeading(@src(), 0, "LOADING…");
            return null;
        },
        .failed => {
            dialog_views.dropHeading(@src(), 0, "COULD NOT READ THE LABELS");
            return null;
        },
        .ready => {},
    }
    pickSearch("Find a label…");
    var rows = pickList();
    defer rows.deinit();
    var shown: usize = 0;
    var toggled: ?[]const u8 = null;
    for (pr.meta.labels, 0..) |label, i| {
        if (!pickShown(label.name, label.description)) continue;
        shown += 1;
        if (pickRow(i, label.name, label.description, listHas(list.items, label.name), pr_list.labelColor(label.color))) {
            listToggle(list, label.name);
            toggled = label.name;
        }
    }
    if (shown == 0) dialog_views.dropHeading(@src(), 1, if (pr.meta.labels.len == 0) "THE REPOSITORY HAS NO LABELS" else "NO LABEL BY THAT NAME");
    return toggled;
}

/// Ready for review, or a draft.
pub fn typePicker(id: usize, draft: *bool, tag: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .min_size_content = .{ .w = 200 }, .background = false, .gravity_y = 0.5 });
    defer cell.deinit();
    const p = picker(id, if (draft.*) "Draft" else "Ready for review", "", tag);
    defer p.end();
    const m = p.menu orelse return;
    if (pickRow(0, "Ready for review", "reviewers are told", !draft.*, null)) {
        draft.* = false;
        m.close();
    }
    if (pickRow(1, "Draft", "nobody is asked yet", draft.*, null)) {
        draft.* = true;
        m.close();
    }
}

/// A field that shows what cannot be picked here: the branch a request
/// comes from, once it is made.
pub fn fixedField(id: usize, caption: []const u8, value: []const u8) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .background = false });
    defer cell.deinit();
    dialog_views.dialogLabel(@src(), caption);
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
    });
    defer box.deinit();
    dvui.label(@src(), "{s}", .{value}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0) });
}

/// Whether `item` is in the comma-separated `list`.
pub fn listHas(list: []const u8, item: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " "), item)) return true;
    return false;
}

/// `item` added to the comma-separated `list`, or taken out of it.
pub fn listToggle(list: *std.ArrayList(u8), item: []const u8) void {
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(app.gpa);
    var found = false;
    var it = std.mem.splitScalar(u8, list.items, ',');
    while (it.next()) |raw| {
        const x = std.mem.trim(u8, raw, " ");
        if (x.len == 0) continue;
        if (std.mem.eql(u8, x, item)) {
            found = true;
            continue;
        }
        if (next.items.len > 0) next.appendSlice(app.gpa, ", ") catch return;
        next.appendSlice(app.gpa, x) catch return;
    }
    if (!found) {
        if (next.items.len > 0) next.appendSlice(app.gpa, ", ") catch return;
        next.appendSlice(app.gpa, item) catch return;
    }
    list.clearRetainingCapacity();
    list.appendSlice(app.gpa, next.items) catch {};
}

/// The comma-separated `text` as a JSON list of strings, in `a`: names
/// with spaces in them — a label's — kept whole.
pub fn jsonCommaList(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return "[]";
    var it = std.mem.splitScalar(u8, text, ',');
    var first = true;
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " \t\n");
        if (word.len == 0) continue;
        if (!first) out.append(a, ',') catch return "[]";
        first = false;
        github.jsonString(a, &out, word) catch return "[]";
    }
    out.append(a, ']') catch return "[]";
    return out.items;
}

fn createRequest() void {
    const title = std.mem.trim(u8, pr_new_title.items, " \n\t");
    const base = std.mem.trim(u8, pr_new_base.items, " ");
    if (title.len == 0 or base.len == 0) return github_actions.setCommandError("A title and a branch to merge into are needed.");
    const head = std.mem.trim(u8, pr_new_head.items, " ");
    if (head.len == 0) return github_actions.setCommandError("Pick the branch it comes from.");
    const a = dvui.currentWindow().arena();
    var body: std.ArrayList(u8) = .empty;
    body.appendSlice(a, github_actions.jsonFields(a, &.{ .{ "title", title }, .{ "body", pr_new_body.items }, .{ "head", head }, .{ "base", base } })) catch return;
    // The draft flag is a JSON boolean, after the strings.
    if (pr_new_draft) {
        _ = body.pop();
        body.appendSlice(a, ",\"draft\":true}") catch return;
    }
    // Asked for, assigned and labelled once GitHub has given it a number.
    github_actions.api_reviewers.clearRetainingCapacity();
    const reviewers = github_actions.jsonList(a, pr_new_reviewers.items);
    if (reviewers.len > 2) github_actions.api_reviewers.appendSlice(app.gpa, reviewers) catch {};
    github_actions.api_assignees.clearRetainingCapacity();
    const assignees = github_actions.jsonList(a, pr_new_assignees.items);
    if (assignees.len > 2) github_actions.api_assignees.appendSlice(app.gpa, assignees) catch {};
    github_actions.api_labels.clearRetainingCapacity();
    const labels = jsonCommaList(a, pr_new_labels.items);
    if (labels.len > 2) github_actions.api_labels.appendSlice(app.gpa, labels) catch {};
    var path: [512]u8 = undefined;
    github_actions.requestApi("Creating", "POST", github_actions.apiPath(&path, "/pulls", .{}), body.items, .ask_reviewers);
    // Open until it is made: then it closes, and the request opens.
    pr_creating = github_actions.api_job != null or github_actions.api_queue.items.len > 0;
    if (!pr_creating) pr_new_open = false;
}

/// One open request: its number and title, and the two things to do with one
/// from here — check it out, or read it on the host.
pub fn requestRow(src: std.builtin.SourceLocation, entry: pr.Request, id: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();

    dvui.label(@src(), "#{d}", .{entry.number}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = if (entry.draft) style.textFaint() else style.accent() },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    dvui.label(@src(), "{s}", .{entry.title}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = dvui.Rect.all(0),
    });

    // The row itself opens the request in the pull-request tab.
    if (dvui.clicked(row.data(), .{})) {
        app.openPulls();
        pr_list.selectRequest(entry.number);
    }

    if (dialog_views.iconButton(@src(), "request_checkout", "Check it out", dvui.entypo.download, style.textMuted())) github_actions.checkoutRequest(entry.number, entry.branch, false);
    if (dialog_views.iconButton(@src(), "request_web", "Open it on the web", dvui.entypo.popup, style.textFaint())) github_actions.openOnGithub("/pull/{d}", .{entry.number});
}

/// One open issue: its number and title, a label or two, and the page it
/// is on, where it is read and answered.
pub fn issueRow(src: std.builtin.SourceLocation, entry: pr.Issue, id: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();

    dvui.label(@src(), "#{d}", .{entry.number}, .{
        .font = style.smallBold(),
        .color_text = .{ .color = style.get().green },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
    dvui.label(@src(), "{s}", .{entry.title}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = dvui.Rect.all(0),
    });
    for (entry.labels[0..@min(entry.labels.len, 2)], 0..) |name, i| {
        dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = i,
            .font = style.tiny(),
            .color_text = .{ .color = style.textMuted() },
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .corners = style.radius.tag,
            .gravity_y = 0.5,
            .max_size_content = .width(80),
            .margin = .{ .x = style.space.xs },
            .padding = .{ .x = style.space.xs, .w = style.space.xs },
        });
    }

    const clicked = dvui.clicked(row.data(), .{});
    if (dialog_views.iconButton(@src(), "issue_web", "Open it on the web", dvui.entypo.popup, style.textFaint()) or clicked) github_actions.openOnGithub("/issues/{d}", .{entry.number});
}

/// One worktree: where it is, and the two things to do with one — open it in
/// a tab of its own, or remove it.
pub fn worktreeRow(src: std.builtin.SourceLocation, entry: git.Worktree, id: usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();
    const row_rect = row.data().borderRectScale().r;
    const hover = row_rect.contains(dvui.currentWindow().mouse_pt);
    if (hover) row_rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });

    dvui.label(@src(), "{s}", .{entry.name}, .{
        .font = style.small(),
        .color_text = .{ .color = style.text() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    dvui.label(@src(), "{s}", .{entry.path}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });

    if (hover) {
        if (dialog_views.iconButton(@src(), "worktree_open", "Open in a tab", dvui.entypo.popup, style.textMuted())) {
            github_actions.requestOpenKnown(entry.path);
        }
        if (dialog_views.iconButton(@src(), "worktree_remove", "Remove this worktree", dvui.entypo.cross, style.textFaint())) {
            github_actions.ask(.remove_worktree, entry.path);
        }
    }
    const more = if (hover) moreButton(dialog_views.frameTag("more", entry.name)) else null;
    // After the buttons, so the row does not take their presses.
    if (dvui.clicked(row.data(), .{})) pr_editor.revealInGraph(entry.head);
    worktreeMenu(entry, id, row_rect, more);
}

fn worktreeMenu(entry: git.Worktree, id: usize, rect: dvui.Rect.Physical, open_at: ?dvui.Point.Physical) void {
    const ctx = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();
    openContextAt(ctx, open_at);
    const cp = ctx.activePoint() orelse return;
    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();
    graph_view.menuTitle(entry.name, "worktree");
    if (graph_view.menuIcon(@src(), dvui.entypo.popup, "Open in a tab", false)) {
        fw.close();
        github_actions.requestOpenKnown(entry.path);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.flow_branch, "Show in the graph", false)) {
        fw.close();
        pr_editor.revealInGraph(entry.head);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.clipboard, "Copy the path", false)) {
        fw.close();
        dvui.clipboardTextSet(entry.path);
    }
    graph_view.menuSeparator(1);
    if (graph_view.menuIcon(@src(), dvui.entypo.cross, "Remove this worktree…", true)) {
        fw.close();
        github_actions.ask(.remove_worktree, entry.path);
    }
}

/// One stash, with the two things you do to one.
///
/// Drop goes through the confirmation toast: it is the one of the three that
/// nothing gets back.
pub fn stashRow(src: std.builtin.SourceLocation, entry: git.Stash, id: usize) void {
    var short_tag: [8]u8 = undefined;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        // By its sha, for a test to hover it.
        .tag = dialog_views.frameTag("stash", git.oidShort(entry.id, &short_tag)),
        .expand = .horizontal,
        .min_size_content = .{ .h = style.side_row },
        .background = false,
        .padding = .{ .x = rebase_view.SIDE_TEXT_X, .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer row.deinit();
    const row_rect = row.data().borderRectScale().r;
    const hover = row_rect.contains(dvui.currentWindow().mouse_pt);
    if (hover) row_rect.fill(.{}, .{ .color = .{ .color = style.rowHover() }, .fade = 0 });

    dvui.label(@src(), "{s}", .{entry.message}, .{
        .font = style.small(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = dvui.Rect.all(0),
    });

    // Apply keeps the stash, pop takes it off the stack — the distinction every
    // git GUI shows, because getting it wrong the other way loses the entry.
    var short: [8]u8 = undefined;
    if (hover) {
        if (dialog_views.iconButtonTagged(@src(), "stash_apply", "Apply, and keep the stash", dvui.entypo.download, style.textFaint(), dialog_views.frameTag("stash_apply", git.oidShort(entry.id, &short)))) {
            rebase_view.requestStash("apply", entry.id);
        }
        if (dialog_views.iconButton(@src(), "stash_pop", "Apply, and drop the stash", dvui.entypo.@"export", style.textMuted())) {
            rebase_view.requestStash("pop", entry.id);
        }
        if (dialog_views.iconButton(@src(), "stash_drop", "Delete this stash", dvui.entypo.trash, style.textFaint())) {
            var hex: [41]u8 = undefined;
            github_actions.ask(.stash_drop, git.oidHex(entry.id, &hex));
        }
    }
    const more = if (hover) moreButton(dialog_views.frameTag("more", git.oidShort(entry.id, &short))) else null;
    // The commit it was made on: the stash commit itself is not in the graph.
    if (dvui.clicked(row.data(), .{})) pr_editor.revealInGraph(entry.base);
    stashMenu(entry, id, row_rect, more);
}

pub fn stashMenu(entry: git.Stash, id: usize, rect: dvui.Rect.Physical, open_at: ?dvui.Point.Physical) void {
    const ctx = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id });
    defer ctx.deinit();
    openContextAt(ctx, open_at);
    const cp = ctx.activePoint() orelse return;
    var fw = graph_view.contextMenu(cp);
    defer fw.deinit();
    graph_view.menuTitle(entry.message, "stash");
    if (graph_view.menuIcon(@src(), dvui.entypo.download, "Apply, and keep the stash", false)) {
        fw.close();
        rebase_view.requestStash("apply", entry.id);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.@"export", "Pop: apply, and drop the stash", false)) {
        fw.close();
        rebase_view.requestStash("pop", entry.id);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.flow_branch, "Show where it was made", false)) {
        fw.close();
        pr_editor.revealInGraph(entry.base);
    }
    if (graph_view.menuIcon(@src(), dvui.entypo.text_document, "Show its changes", false)) {
        fw.close();
        app.selectCommit(entry.id);
    }
    graph_view.menuSeparator(1);
    if (graph_view.menuIcon(@src(), dvui.entypo.trash, "Delete this stash…", true)) {
        fw.close();
        var hex: [41]u8 = undefined;
        github_actions.ask(.stash_drop, git.oidHex(entry.id, &hex));
    }
}

/// A branch last committed to longer ago than this reads as done with.
const STALE_AFTER_S: i64 = 30 * 86400;

/// One ref. Double-click is what checks out, like every other git GUI: a single
/// click on a branch list should never move the working tree.
pub fn refRow(src: std.builtin.SourceLocation, ref: git.Ref, id: usize) bool {
    // Three siblings on one line — the eye, the button that is the ref, the
    // ⋯ — rather than icons inside the button: nested in it, they never saw
    // their clicks.
    var line = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        // Exactly a line high: `sideRows` places lines by arithmetic.
        .min_size_content = .{ .h = style.side_row },
        .max_size_content = .height(style.side_row),
        .background = false,
        // The name lands on the section title's column, past the gutter.
        .padding = .{ .x = rebase_view.SIDE_TEXT_X - rebase_view.SIDE_GUTTER - rebase_view.SIDE_REF_PAD + (if (ref.kind == .remote) rebase_view.SIDE_NEST else 0), .w = rebase_view.SIDE_RIGHT - style.space.xs },
    });
    defer line.deinit();
    const line_rect = line.data().borderRectScale().r;
    const hover = line_rect.contains(dvui.currentWindow().mouse_pt);
    const hidden = graph_view.isHidden(ref.name);
    // Drawn by hand, before anything on it: the box picked its background
    // before it knew where the mouse was. The drop's tint goes on below,
    // once the button has said whether one is over it.
    if (ref.head or hover) line_rect.fill(.{}, .{ .color = .{ .color = if (ref.head) style.rowSelected() else style.rowHover() }, .fade = 0 });

    // Far left, in the gutter, the eye: in the graph or out of it, a click
    // either way. The branch checked out is always in: its gutter holds the
    // tick that says it is the current one, so its name lines up with the
    // others'.
    if (ref.head) {
        dvui.icon(@src(), "head_check", dvui.entypo.check, .{ .fill_color = .{ .color = style.accent() } }, .{
            .min_size_content = .{ .w = 11, .h = 11 },
            .gravity_y = 0.5,
            .margin = .{ .x = (rebase_view.SIDE_GUTTER - 11) / 2, .w = (rebase_view.SIDE_GUTTER - 11) / 2 },
        });
    } else if (dialog_views.iconButtonTagged(@src(), "ref_eye", if (hidden) "Show in the graph" else "Hide from the graph", identity_view.eyeIcon(hidden), if (hidden) style.textMuted() else if (hover) style.textFaint() else dvui.Color.transparent, dialog_views.frameTag("eye", ref.name))) {
        graph_view.toggleHidden(ref);
    }

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        // Local branches by name, so a test can find the row to drag.
        .tag = if (ref.kind == .local) ref.name else null,
        // The whole line, so the name is centred on it like the eye and the ⋯
        // beside it, not on a button as high as its text sitting at the top.
        .expand = .both,
        .background = false,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    // Before the button sees them: a press may be the start of a drag, and a
    // release over this row may be the end of one.
    const drop_target = graph_view.branchDrop(bw.data(), ref);
    bw.processEvents();
    graph_view.branchDragStart(bw.data(), ref);
    if (drop_target) bw.data().borderRectScale().r.fill(.{}, .{ .color = .{ .color = style.accentDim() }, .fade = 0 });

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = false,
            .padding = .{ .x = rebase_view.SIDE_REF_PAD },
        });
        defer row.deinit();
        // Out of the graph, whatever put it out — hidden, another shown
        // alone, the remote branches off: said by fading it.
        const out_of_graph = !graph_view.graphFilter().walks(ref);

        // A branch nobody has committed to in a month, faded like one out of
        // the graph: still there, probably done with.
        const stale = ref.kind != .tag and !ref.head and ref.time > 0 and app.frame_now_s - ref.time > STALE_AFTER_S;

        // Listed under its remote, so the remote's name would only repeat it.
        const shown = if (ref.kind == .remote) github_actions.splitRemoteRef(ref.name).branch else ref.name;
        dvui.label(@src(), "{s}", .{shown}, .{
            .font = if (ref.head) style.smallBold() else style.small(),
            .color_text = .{ .color = if (out_of_graph or stale) style.textFaint() else if (ref.head) style.text() else style.textMuted() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
        // Pinned: said at the end of the line, with what the branch owes its
        // upstream, so the names keep one left edge.
        if (graph_view.hasName(graph_view.graph_pinned.items, ref.name)) {
            dvui.icon(@src(), "pinned", dvui.entypo.pin, .{ .fill_color = .{ .color = style.accent() } }, .{
                .min_size_content = .{ .w = 10, .h = 10 },
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.xs },
            });
        }
        search_view.trackingMarks(ref.tracking, style.textMuted());
        search_view.requestBadge(ref, style.textMuted());
    }

    // Tags name a commit, not a branch to work on; checking one out detaches
    // HEAD, which is not what a click in a list should do.
    // One click brings its commit up in the graph; the second of a double
    // checks it out.
    const clicked = bw.clicked();
    if (clicked) pr_editor.revealInGraph(ref.target);
    const activated = ref.kind != .tag and clicked and rebase_view.isDoubleClick(bw.data().id);
    if (bw.hovered() and ref.time > 0) {
        var when: [32]u8 = undefined;
        // Right of the whole line, past the sidebar's edge: right of the name
        // alone it sat on the ⋯ the hover had just brought up.
        dvui.tooltip(@src(), .{ .active_rect = line_rect, .position = .horizontal, .delay = 500_000 }, "Last commit {s}", .{search_view.relativeTime(&when, ref.time)}, .{
            .font = style.small(),
            .id_extra = id,
        });
    }
    bw.deinit();

    // Far right on hover, the ⋯: the right-click menu, for a mouse that
    // does not think of right-clicking.
    const more = if (hover) moreButton(dialog_views.frameTag("more", ref.name)) else null;
    graph_view.refMenu(@src(), ref, id, line_rect, more);
    return activated;
}

/// The ⋯ at a hovered row's end. Where it was clicked, to open the row's
/// menu at; null otherwise. Only on the hovered row: kept on every row,
/// invisible, it took its width from every name in the sidebar.
fn moreButton(tag: ?[]const u8) ?dvui.Point.Physical {
    if (!dialog_views.iconButtonTagged(@src(), "row_more", "More…", dvui.entypo.dots_three_horizontal, style.textMuted(), tag)) return null;
    return dvui.currentWindow().mouse_pt;
}

/// Open a row's right-click menu as a right-click at `at` would: what the
/// ⋯ does.
pub fn openContextAt(ctx: *dvui.ContextWidget, at: ?dvui.Point.Physical) void {
    const p = at orelse return;
    dvui.focusWidget(ctx.data().id, null, null);
    ctx.focused = true;
    ctx.activePt = p.toNatural();
}
