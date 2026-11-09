const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const run = @import("../core/run.zig");
const github = @import("../github/github.zig");
const tab_strip = @import("tab_strip.zig");
const graph_view = @import("graph_view.zig");
const app = @import("../main.zig");

// === Chrome ===

/// The bar across the top: what is open, what branch it is on, what you can
/// do to it, and whether it is in sync.
pub fn titlebar() void {
    // Three zones over the three panels below them: the repository over the
    // branches, the buttons centred over the history they act on, and the
    // search over the changes panel — GitKraken's top bar, lined up with
    // what is under it rather than with the window.
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .min_size_content = .{ .h = style.titlebar_height },
        .padding = .{ .x = style.space.lg, .w = style.space.lg },
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
        .margin = dvui.Rect.all(0),
    });
    defer bar.deinit();

    const zones = toolbarZones();
    {
        // Over the sidebar, and wider where a narrow one would cut the
        // branch's name short: the name before the centring.
        var left = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = zones.left },
            .max_size_content = .width(@max(zones.left, branchRoom(zones.left) + BRANCH_CHROME_W)),
            .background = false,
        });
        defer left.deinit();
        // Undo and Redo at the very start, as GitKraken has them: icons alone,
        // so the branch beside them keeps its name, each saying on hover what
        // it would take back; Redo lit only when there is one.
        if (app.toolButton(@src(), "Undo", dvui.entypo.reply, .{ .icon_only = true, .hint = app.undoHint() })) app.requestUndo();
        if (app.toolButton(@src(), "Redo", dvui.entypo.forward, .{ .icon_only = true, .usable = app.canRedo(), .hint = app.redoHint() })) app.requestRedo();
        toolbarDivider(@src(), 0);
        // The branch every button acts on; the repository is the tab's.
        if (app.repo != null) branchSwitcher();
    }
    {
        // Vertical, so the row of buttons in it can be centred across it: a
        // horizontal box lays its children end to end and ignores that.
        var middle = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
        defer middle.deinit();
        // What Pull and Push would move, straight from the upstream comparison.
        const tracking: git.Tracking = if (app.history) |h| h.tracking else .{};

        var tools = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = false,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.sm },
            .padding = dvui.Rect.all(0),
        });
        // Captions while the row fits over the history, as measured the last
        // frame it had them; icons alone when it would not, so no button is
        // cut off at a narrow window.
        if (!toolbar_compact) if (dvui.minSizeGet(tools.data().id)) |m| {
            toolbar_full_w = m.w;
        };
        toolbar_compact = toolbar_full_w + 2 * style.space.sm > middle.data().contentRect().w;

        // A command the bar started, running: its button spins, and the
        // others that write wait for it.
        const running: []const u8 = if (tab_strip.job != null and !tab_strip.job_quiet) tab_strip.job_label else "";
        const idle = tab_strip.job == null or tab_strip.job_quiet;
        const arena = dvui.currentWindow().arena();
        const on_branch = if (app.history) |h| h.head != null else false;

        if (app.toolButton(@src(), "Fetch", dvui.entypo.cw, .{ .busy = std.mem.eql(u8, running, "Fetching"), .usable = idle, .hint = "Fetch every remote, nothing merged" })) {
            app.requestNetwork("Fetching", tab_strip.fetchAllArgs(false));
        }
        // After a rebase the branch and its upstream have parted: a plain
        // push is refused, and Pull would merge the old commits back in.
        // Push says what it has to be, and Pull keeps its count quiet.
        const rebased = rebasedSinceUpstream();
        const pull_hint: []const u8 = if (!on_branch)
            "No branch checked out to pull into"
        else if (tracking.upstream) |u|
            (if (tracking.behind > 0 and !rebased)
                std.fmt.allocPrint(arena, "Pull {d} commit{s} from {s}", .{ tracking.behind, plural(tracking.behind), u }) catch "Pull"
            else
                std.fmt.allocPrint(arena, "Pull from {s}", .{u}) catch "Pull")
        else
            "No upstream to pull from: push this branch first";
        const pullable = idle and on_branch and tracking.upstream != null;
        {
            // Pull and its ways, one split button: each half lit on its own
            // as the other buttons are, a rule between.
            var split = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false });
            defer split.deinit();
            if (app.toolButton(@src(), "Pull", dvui.entypo.download, .{ .badge = if (rebased) 0 else tracking.behind, .busy = std.mem.eql(u8, running, "Pulling"), .usable = pullable, .hint = pull_hint })) {
                app.requestNetwork("Pulling", &.{"pull"});
            }
            pullMenu(pullable);
        }
        const push_hint: []const u8 = if (!on_branch)
            "No branch checked out to push"
        else if (tracking.upstream) |u|
            (if (rebased)
                std.fmt.allocPrint(arena, "Replace {s} with this branch", .{u}) catch "Force push"
            else if (tracking.ahead > 0)
                std.fmt.allocPrint(arena, "Push {d} commit{s} to {s}", .{ tracking.ahead, plural(tracking.ahead), u }) catch "Push"
            else
                std.fmt.allocPrint(arena, "Nothing to push: {s} has every commit", .{u}) catch "Push")
        else
            "Push this branch, and track it on the remote";
        const pushable = idle and on_branch and (tracking.upstream == null or tracking.ahead > 0);
        if (app.toolButton(@src(), if (rebased) "Force push" else "Push", dvui.entypo.upload, .{ .badge = tracking.ahead, .tag = "toolbar:Push", .busy = std.mem.eql(u8, running, "Pushing") or std.mem.eql(u8, running, "Force pushing"), .usable = pushable, .hint = push_hint })) {
            if (rebased) {
                app.ask(.force_push, "");
            } else {
                // A branch with no upstream yet gets one, on the default remote —
                // otherwise the first push of every new branch is an error message.
                app.requestNetwork("Pushing", &.{ "-c", "push.autoSetupRemote=true", "push" });
            }
        }
        toolbarDivider(@src(), 1);
        if (app.toolButton(@src(), "Branch", dvui.entypo.flow_branch, .{ .hint = "A new branch at what is checked out" })) app.askName(.new_branch, "");
        const changes = app.changeCount();
        if (app.toolButton(@src(), "Stash", dvui.entypo.save, .{
            .busy = std.mem.eql(u8, running, "Stashing"),
            .usable = idle and changes > 0,
            .hint = if (changes == 0) "No changes to stash" else std.fmt.allocPrint(arena, "Set {d} change{s} aside, new files too", .{ changes, plural(changes) }) catch "Stash",
        })) app.requestLocal("Stashing", &.{ "stash", "push", "-u" });
        const stashes = if (app.history) |h| h.stashes.len else 0;
        if (app.toolButton(@src(), "Pop", dvui.entypo.archive, .{
            .busy = std.mem.eql(u8, running, "Popping the stash"),
            .usable = idle and stashes > 0,
            .hint = if (stashes == 0) "No stash to pop" else "Bring the last stash back, and drop it",
        })) app.requestLocal("Popping the stash", &.{ "stash", "pop" });

        // Only where there is LFS to pull. `git lfs pull` fetches the real contents
        // for the pointers a checkout left behind, which is the one LFS operation
        // that comes up in ordinary work.
        if (tab_strip.uses_lfs) {
            toolbarDivider(@src(), 2);
            if (app.toolButton(@src(), "LFS", dvui.entypo.cloud, .{ .busy = std.mem.eql(u8, running, "Fetching LFS files"), .usable = idle, .hint = "Fetch the LFS files this checkout points to" })) {
                app.requestNetwork("Fetching LFS files", &.{ "lfs", "pull" });
            }
        }

        tools.deinit();
    }
    {
        var right = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = zones.right },
            .max_size_content = .width(zones.right),
            .background = false,
        });
        defer right.deinit();
        // Kept for the width it holds: the buttons stay centred over the
        // history, not over the window. And where a merge or a rebase under
        // way says so, as GitComet's action bar does.
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        app.operationControls();
        // Finding a commit: not an action on the repository, so apart from
        // them, an icon on this side.
        if (app.toolButton(@src(), "Search", dvui.entypo.magnifying_glass, .{ .icon_only = true, .on = graph_view.search_open, .hint = "Search the commits — Ctrl+F" })) {
            if (graph_view.search_open) graph_view.closeSearch() else {
                graph_view.search_open = true;
                app.active_view = .graph;
            }
        }
        // At the very end: the rest of git — and everything else — is a
        // terminal away.
        if (app.toolButton(@src(), "Terminal", dvui.entypo.code, .{ .hint = "A terminal in this repository's folder — Ctrl+Shift+T" })) app.openTerminal();
    }
}

/// The branch was rebased since it was last pushed: it and its upstream
/// each have commits the other lacks, and the last thing to move it was a
/// rebase.
pub fn rebasedSinceUpstream() bool {
    const h = app.history orelse return false;
    if (h.state != .none or h.tracking.ahead == 0 or h.tracking.behind == 0) return false;
    const move = h.last_move orelse return false;
    return std.mem.startsWith(u8, move.message, "rebase") or std.mem.startsWith(u8, move.message, "pull --rebase");
}

/// The toolbar's side zones, as wide as the panels under them were last
/// frame — less the bar's own padding — and never narrower than what they
/// hold needs.
fn toolbarZones() struct { left: f32, right: f32 } {
    const left_w: f32 = if (app.leftShown()) app.body_width * app.sidebar_split else 0;
    const content_w = app.body_width - left_w;
    const right_w: f32 = if (app.show_detail and app.active_view == .graph and content_w >= 760) content_w * (1 - app.detail_split) else 0;
    return .{
        .left = @max(left_w - style.space.lg, 230),
        .right = @max(right_w - style.space.lg, 360),
    };
}

/// A toolbar button's least size: GitComet's comfortable action bar, the
/// caption under the icon. Square without it.
const TOOL_W: f32 = 58;
pub const TOOL_H: f32 = 44;

/// The toolbar's buttons are icons alone this frame: with their captions the
/// row would not fit over the history.
var toolbar_compact = false;
/// How wide the row was the last frame it had its captions.
var toolbar_full_w: f32 = 0;

/// A thin upright rule between groups of toolbar buttons.
fn toolbarDivider(src: std.builtin.SourceLocation, id: usize) void {
    _ = dvui.separator(src, .{
        .id_extra = id,
        .min_size_content = .{ .w = 1, .h = 28 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.md, .w = style.space.md },
        .color_fill = .{ .color = style.border() },
    });
}

/// A button whose menu drops below it. dvui's dropdown opens over its own
/// button, as a select does, and hides what was just clicked; this is its
/// menu-bar form instead. The face is drawn after `begin`; `open` returns the
/// menu while it is up, and `end` closes the lot.
pub const DropButton = struct {
    bar: *dvui.MenuWidget,
    item: *dvui.MenuItemWidget,
    /// The menu's least width: a picker's is its field's.
    min_w: f32 = 0,

    pub fn begin(src: std.builtin.SourceLocation, opts: dvui.Options) DropButton {
        // Centred on the line, unless told otherwise: in a column, under a
        // caption, a centred one would sit over it.
        const bar = dvui.menu(src, .horizontal, .{ .id_extra = opts.id_extra, .background = false, .gravity_y = opts.gravity_y orelse 0.5, .expand = opts.expand, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
        return .{ .bar = bar, .item = dvui.menuItem(@src(), .{ .submenu = true }, opts) };
    }

    pub fn open(self: DropButton) ?*dvui.FloatingMenuWidget {
        if (self.item.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) dvui.cursorSet(.hand);
        const rect = self.item.activeRect();
        self.item.deinit();
        const r = rect orelse return null;
        return dvui.floatingMenu(@src(), .{ .from = r }, .{
            .background = true,
            .color_fill = .{ .color = style.surfaceRaised() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.popover,
            .padding = dvui.Rect.all(style.space.xs),
            .min_size_content = .{ .w = self.min_w },
        });
    }

    pub fn end(self: DropButton, menu: ?*dvui.FloatingMenuWidget) void {
        if (menu) |m| m.deinit();
        self.bar.deinit();
    }
};

/// The chevron beside Pull: the ways of pulling a plain click does not pick,
/// which is otherwise a right-click on the current branch away.
fn pullMenu(usable: bool) void {
    const enabled = app.repo != null and usable;
    // As tall as Pull beside it, the other half of one split button.
    const button = DropButton.begin(@src(), .{
        .tag = "toolbar:pull_menu",
        .gravity_y = 0.5,
        .background = false,
        .color_fill_hover = .{ .color = style.rowHover() },
        .min_size_content = .{ .w = 16, .h = TOOL_H },
        .margin = .{ .w = 2 },
        .padding = .{ .x = 2, .w = 2 },
        .corners = style.radius.input,
    });
    {
        // The rule that parts it from Pull.
        const rs = button.item.data().borderRectScale();
        (dvui.Rect.Physical{ .x = rs.r.x - rs.s, .y = rs.r.y + (rs.r.h - 20 * rs.s) / 2, .w = rs.s, .h = 20 * rs.s })
            .fill(.{}, .{ .color = .{ .color = style.border() }, .fade = 0 });
    }
    dvui.icon(@src(), "pull_menu", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = if (enabled) style.textMuted() else style.textFaint() } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
    });
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse return;
    if (!enabled) return m.close();
    var args: ?[]const []const u8 = null;
    if (graph_view.menuIcon(@src(), dvui.entypo.merge, "Pull, merging", false)) args = &.{ "pull", "--no-rebase" };
    if (graph_view.menuIcon(@src(), dvui.entypo.flow_line, "Pull, rebasing local commits", false)) args = &.{ "pull", "--rebase" };
    if (graph_view.menuIcon(@src(), dvui.entypo.controller_fast_forward, "Pull, fast-forward only", false)) args = &.{ "pull", "--ff-only" };
    if (args) |a| {
        m.close();
        app.requestNetwork("Pulling", a);
    }
}

/// Undo, Redo and the rule after them, then the switcher's mark, chevron
/// and padding: what the left zone holds besides the branch's name.
const BRANCH_CHROME_W: f32 = 2 * (TOOL_H + 4) + (1 + 2 * style.space.md) + 72;

/// How wide the branch's name may be: what the zone over the sidebar
/// leaves, but never so little that a usual name is cut.
fn branchRoom(zone: f32) f32 {
    return @max(zone - BRANCH_CHROME_W, 220);
}

/// What the branch switcher's list is narrowed to.
pub var switch_filter: std.ArrayList(u8) = .empty;

/// The toolbar's branch, as a menu: the branch checked out, and a click away
/// every other — local first, then the remotes', a filter over them all.
fn branchSwitcher() void {
    const detached = if (app.history) |h| h.head == null else false;
    // Mid-rebase HEAD is detached, but the branch being rebased is still
    // the one being worked on: its name, not "detached HEAD".
    const head: []const u8 = if (app.history) |h| h.head orelse (if (app.op_info.branch.len > 0) app.op_info.branch else "detached HEAD") else "";
    const button = DropButton.begin(@src(), .{
        .tag = "toolbar:branch",
        .gravity_y = 0.5,
        .background = false,
        // Under the face below, which covers it: never the accent, even at
        // its rounded edge, while the menu is open.
        .color_fill_hover = .{ .color = style.rowHover() },
        .corners = style.radius.input,
        .padding = dvui.Rect.all(0),
    });
    {
        // A control, framed as a field is, so what it does reads before it
        // is clicked: the branch's mark, its name, the menu's chevron. Lit
        // under the pointer and while its menu is open.
        const lit = button.item.show_active or button.item.mouse_over;
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .color_fill = .{ .color = if (lit) style.rowHover() else style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .min_size_content = .{ .h = BRANCH_BUTTON_H },
            .padding = .{ .x = style.space.lg, .y = style.space.xs, .w = style.space.md, .h = style.space.xs },
        });
        defer face.deinit();
        dvui.icon(@src(), "branch_mark", if (detached) dvui.entypo.flow_line else dvui.entypo.flow_branch, .{ .fill_color = .{ .color = style.accent() } }, .{
            .min_size_content = .{ .w = 13, .h = 13 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
        });
        var buf: [app.MAX_SHOWN_LINE]u8 = undefined;
        const room = branchRoom(toolbarZones().left);
        // Its name, and under it where Pull and Push go — or that they have
        // nowhere yet.
        var names = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5, .background = false });
        dvui.label(@src(), "{s}", .{graph_view.fitText(&buf, head, style.bodyBold(), room)}, .{
            .font = style.bodyBold(),
            .color_text = .{ .color = style.text() },
            .padding = dvui.Rect.all(0),
        });
        if (app.history) |h| if (h.head != null) {
            var up_buf: [app.MAX_SHOWN_LINE]u8 = undefined;
            const upstream = h.tracking.upstream orelse "no upstream";
            dvui.label(@src(), "{s}", .{graph_view.fitText(&up_buf, upstream, style.tiny(), room)}, .{
                .font = style.tiny(),
                .color_text = .{ .color = if (h.tracking.upstream != null) style.textMuted() else style.textFaint() },
                .padding = dvui.Rect.all(0),
            });
        };
        names.deinit();
        dvui.icon(@src(), "switch_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.sm },
        });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse {
        switch_filter.clearRetainingCapacity();
        return;
    };
    const h = app.history orelse return;

    app.focusOnce(app.searchField(@src(), &switch_filter, "Switch to a branch…", "switch_filter", .{ .x = style.space.xs, .y = style.space.xs, .w = style.space.xs, .h = style.space.sm }));
    const needle = std.mem.trim(u8, switch_filter.items, " ");

    // As tall as its branches, up to a bound — and less where the window is
    // short: a long list scrolls, a short one leaves no empty space under it.
    var list = dvui.scrollArea(@src(), .{}, .{
        .min_size_content = .{ .w = 320 },
        .max_size_content = .size(.{ .w = 320, .h = @min(BRANCH_LIST_MAX_H, dvui.windowRect().h * 0.6) }),
        .background = false,
    });
    defer list.deinit();
    var shown: usize = 0;
    for ([_]git.Ref.Kind{ .local, .remote }, 0..) |kind, k| {
        var header = false;
        for (h.refs, 0..) |ref, i| {
            if (ref.kind != kind) continue;
            // A remote's branch with a local one of the same name is that one.
            if (kind == .remote and app.sameOnRemote(h, ref)) continue;
            if (needle.len > 0 and std.ascii.findIgnoreCase(ref.name, needle) == null) continue;
            if (shown >= app.MAX_BRANCH_CHOICES) break;
            if (!header) {
                app.dropHeading(@src(), k + 10, if (kind == .local) "LOCAL" else "REMOTE");
                header = true;
            }
            shown += 1;
            if (branchChoice(i, ref) and !ref.head) {
                app.checkout(ref);
                m.close();
            }
        }
    }
    if (shown == 0) app.dropHeading(@src(), 20, "NO BRANCH BY THAT NAME");
}

/// One branch in the switcher: a tick on the one checked out, its distance
/// from its upstream on the right.
fn branchChoice(id: usize, ref: git.Ref) bool {
    var mi = dvui.menuItem(@src(), .{}, .{
        .id_extra = id,
        .tag = app.frameTag("switch", ref.name),
        .expand = .horizontal,
        .corners = style.radius.input,
        .color_fill_hover = .{ .color = style.accentDim() },
        .padding = .{ .x = style.space.md, .y = graph_view.MENU_ROW_PAD_Y, .w = style.space.md, .h = graph_view.MENU_ROW_PAD_Y },
    });
    defer mi.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
    defer row.deinit();
    const ink = if (ref.head) style.accent() else style.textMuted();
    dvui.icon(@src(), "choice_icon", if (ref.head) dvui.entypo.check else if (ref.kind == .remote) dvui.entypo.cloud else dvui.entypo.flow_branch, .{ .fill_color = .{ .color = ink } }, .{
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .w = style.space.md },
    });
    var buf: [app.MAX_SHOWN_LINE]u8 = undefined;
    dvui.label(@src(), "{s}", .{graph_view.fitText(&buf, ref.name, style.small(), 220)}, .{
        .font = if (ref.head) style.smallBold() else style.small(),
        .color_text = .{ .color = if (ref.head) style.accent() else style.text() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .padding = dvui.Rect.all(0),
    });
    app.trackingMarks(ref.tracking, style.textFaint());
    return mi.activeRect() != null;
}

/// The toolbar's branch button: a control's height.
const BRANCH_BUTTON_H: f32 = 30;
/// The branch menu's list, at most.
const BRANCH_LIST_MAX_H: f32 = 360;

/// The "s" a count past one takes: "1 file", "2 files".
pub fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

// === The window's own frame ===
//
// Zit draws its own: the system's title bar is off, the tab strip takes its
// place. A press on the strip's empty part moves the window and its edges
// resize it, both answered by SDL's hit test before the press reaches us;
// minimise, maximise and close are buttons at the strip's end.

/// The strip's empty part, in SDL's window coordinates, as last drawn.
var window_drag: dvui.Rect = .{};
/// Asked for by the close button; the next frame closes, as a close from
/// the window manager does.
pub var close_requested = false;
const RESIZE_EDGE: f32 = 6;

fn sdlWindow() *dvui.backend.c.SDL_Window {
    return dvui.currentWindow().backend.impl.window;
}

fn windowMaximized() bool {
    const sdl = dvui.backend.c;
    return sdl.SDL_GetWindowFlags(sdlWindow()) & sdl.SDL_WINDOW_MAXIMIZED != 0;
}

/// Where a press lands, for the system: an edge to resize by, the empty
/// strip to move by, or ordinary content. Runs inside SDL's event pump, on
/// the UI thread.
pub fn hitTest(win: ?*dvui.backend.c.SDL_Window, area: [*c]const dvui.backend.c.SDL_Point, _: ?*anyopaque) callconv(.c) dvui.backend.c.SDL_HitTestResult {
    const sdl = dvui.backend.c;
    const x: f32 = @floatFromInt(area.*.x);
    const y: f32 = @floatFromInt(area.*.y);
    if (sdl.SDL_GetWindowFlags(win) & (sdl.SDL_WINDOW_MAXIMIZED | sdl.SDL_WINDOW_FULLSCREEN) == 0) {
        var wi: c_int = 0;
        var hi: c_int = 0;
        _ = sdl.SDL_GetWindowSize(win, &wi, &hi);
        const w: f32 = @floatFromInt(wi);
        const h: f32 = @floatFromInt(hi);
        const left = x < RESIZE_EDGE;
        const right = x >= w - RESIZE_EDGE;
        const top = y < RESIZE_EDGE;
        const bottom = y >= h - RESIZE_EDGE;
        if (top and left) return sdl.SDL_HITTEST_RESIZE_TOPLEFT;
        if (top and right) return sdl.SDL_HITTEST_RESIZE_TOPRIGHT;
        if (bottom and left) return sdl.SDL_HITTEST_RESIZE_BOTTOMLEFT;
        if (bottom and right) return sdl.SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        if (top) return sdl.SDL_HITTEST_RESIZE_TOP;
        if (bottom) return sdl.SDL_HITTEST_RESIZE_BOTTOM;
        if (left) return sdl.SDL_HITTEST_RESIZE_LEFT;
        if (right) return sdl.SDL_HITTEST_RESIZE_RIGHT;
    }
    const d = window_drag;
    if (x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h) return sdl.SDL_HITTEST_DRAGGABLE;
    return sdl.SDL_HITTEST_NORMAL;
}

/// `r`, in dvui's pixels, as the part of the window a press moves it by.
/// SDL's window coordinates are pixels on some systems and points on
/// others: the ratio of the two window sizes says which.
fn setWindowDrag(r: dvui.Rect.Physical) void {
    var wi: c_int = 0;
    var hi: c_int = 0;
    _ = dvui.backend.c.SDL_GetWindowSize(sdlWindow(), &wi, &hi);
    const px = dvui.windowRectPixels();
    if (px.w <= 0) return;
    const k = @as(f32, @floatFromInt(wi)) / px.w;
    window_drag = .{ .x = r.x * k, .y = r.y * k, .w = @max(0, r.w * k), .h = r.h * k };
}

/// Minimise, maximise or restore, close — at the strip's far end, where
/// every desktop puts them.
pub fn windowControls() void {
    _ = dvui.separator(@src(), .{
        .min_size_content = .{ .w = 1, .h = 16 },
        .gravity_y = 0.5,
        .margin = .{ .x = style.space.sm },
        .color_fill = .{ .color = style.border() },
    });
    if (app.iconButtonTagged(@src(), "window_min", "Minimise", dvui.entypo.minus, style.textMuted(), "window:minimise")) {
        _ = dvui.backend.c.SDL_MinimizeWindow(sdlWindow());
    }
    const maxed = windowMaximized();
    if (app.iconButtonTagged(@src(), "window_max", if (maxed) "Restore" else "Maximise", if (maxed) dvui.entypo.resize_100 else dvui.entypo.resize_full_screen, style.textMuted(), "window:maximise")) {
        _ = if (maxed) dvui.backend.c.SDL_RestoreWindow(sdlWindow()) else dvui.backend.c.SDL_MaximizeWindow(sdlWindow());
    }
    if (app.iconButtonTagged(@src(), "window_close", "Close", dvui.entypo.cross, style.textMuted(), "window:close")) {
        close_requested = true;
        dvui.refresh(null, @src(), null);
    }
}

/// The tabs themselves, and the + after them.
pub fn tabList() void {
    // More tabs than width: they scroll sideways rather than squeeze.
    var scroll = dvui.scrollArea(@src(), .{ .vertical = .none, .horizontal = .auto, .horizontal_bar = .auto_overlay }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .h = style.tab_height },
        // Only the width the rest of the strip leaves: dvui asks for all of
        // its content, which pushed the buttons after it out of the window.
        .max_size_content = .width(0),
    });
    defer scroll.deinit();
    // What the tabs leave of the strip moves the window. Before the scroll
    // area closes, on what it held last frame.
    defer {
        const rs = scroll.data().contentRectScale();
        const used = (scroll.si.virtual_size.w - scroll.si.viewport.x) * rs.s;
        var r = rs.r;
        r.x += used;
        r.w -= used;
        setWindowDrag(r);
        // A tab let go there leaves its group for the end of the strip.
        if (dvui.dragName(app.TAB_DRAG_NAME)) for (dvui.events()) |*e| {
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.action != .release or !me.button.pointer() or !r.contains(me.p)) continue;
            e.handle(@src(), scroll.data());
            dvui.dragEnd(me.button);
            app.requestTab(.{ .tab_end = app.tab_drag });
        };
    }
    // The active tab's foot only where the strip shows the tab: scrolled
    // part out of sight, the rest of it is under the buttons after the tabs.
    defer if (app.active_tab_foot) |*foot| {
        const view = scroll.data().contentRectScale().r;
        const left = @max(foot.x, view.x);
        foot.w = @max(0, @min(foot.x + foot.w, view.x + view.w) - left);
        foot.x = left;
    };
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .vertical, .background = false });
    defer row.deinit();
    const width = app.TAB_W;
    // No rule before the first tab.
    app.tab_prev_active = true;

    // Only recorded here, run after the frame: selecting or closing one
    // rebuilds the snapshots the rest of this frame is drawn from.
    var flat: usize = 0;
    for (tab_strip.groups.items, 0..) |group, g| {
        if (group.ws != tab_strip.active_ws) continue;
        const named = group.name.len > 0;
        const hue = tab_strip.groupColor(group.color);
        // A group is one run, as Chrome has it: a line in its colour from the
        // label to its last tab, which goes up and over the active one —
        // outlined in that colour — rather than under it.
        var span = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = g,
            .expand = .vertical,
            .background = false,
            .margin = .{ .w = if (named) style.space.sm else 0 },
        });
        defer span.deinit();
        if (named) {
            const chip = app.groupChip(g, group, hue);
            if (group.collapsed) {
                flat += group.tabs.items.len;
                continue;
            }
            group_line = .{ .from = chip.x, .to = chip.x + chip.w };
        }
        defer if (named) groupUnderline(span.data().contentRectScale(), hue);
        for (group.tabs.items, 0..) |tab, t| {
            const current = app.repo != null and g == tab_strip.active_group and t == tab_strip.active_tab;
            const active = !app.new_tab_open and current;
            var rect: dvui.Rect.Physical = .{};
            switch (app.tabButton(@src(), flat, git.repoName(tab.path), tab.path, active, width, &rect, .{ .slot = .{ g, t }, .hue = if (named) hue else null })) {
                .none => {},
                // Back from its pull requests' tab: the repository is open
                // already, only the view changes.
                .select => if (current) {
                    app.new_tab_open = false;
                    app.active_view = .graph;
                } else app.requestTab(.{ .select_in = .{ g, t } }),
                .close => app.requestTab(.{ .close_in = .{ g, t } }),
            }
            if (active) revealTab(flat, rect);
            if (named) {
                group_line.to = rect.x + rect.w;
                if (active) group_line.gap = rect;
            }
            app.tabMenu(g, t, flat, rect);
            flat += 1;
        }
    }

    // The page a new tab opens on, as a tab of its own while it is up.
    if (app.new_tab_open) {
        var rect: dvui.Rect.Physical = .{};
        switch (app.tabButton(@src(), flat, "New tab", "Open, clone or create a repository", true, width, &rect, .{ .icon = dvui.entypo.plus })) {
            .none, .select => {},
            .close => app.new_tab_open = false,
        }
        revealTab(flat, rect);
    }

    if (app.iconButton(@src(), "tab_add", "New tab — Ctrl+T", dvui.entypo.plus, style.textMuted())) {
        app.new_tab_open = true;
    }

    // What a drag was over this frame is lit on the next.
    if (!std.meta.eql(app.tab_drop_over, app.tab_drop_seen)) dvui.refresh(null, @src(), null);
    app.tab_drop_over = app.tab_drop_seen;
    app.tab_drop_seen = null;
}

/// The run a group's underline covers, in physical pixels, and the active
/// tab it leaves a gap for.
var group_line: struct { from: f32 = 0, to: f32 = 0, gap: ?dvui.Rect.Physical = null } = .{};

fn groupUnderline(rs: dvui.RectScale, hue: dvui.Color) void {
    defer group_line = .{};
    const s = rs.s;
    const y = rs.r.y + rs.r.h - 2 * s;
    const ends: [2][2]f32 = if (group_line.gap) |a|
        .{ .{ group_line.from, a.x }, .{ a.x + a.w, group_line.to } }
    else
        .{ .{ group_line.from, group_line.to }, .{ 0, 0 } };
    for (ends) |e| {
        if (e[1] - e[0] < 2 * s) continue;
        (dvui.Rect.Physical{ .x = e[0], .y = y, .w = e[1] - e[0], .h = 2 * s })
            .fill(dvui.CornerRect.Physical.all(s), .{ .color = .{ .color = hue }, .fade = 0 });
    }
}

/// Where in the strip the active tab was last scrolled into sight.
pub var tab_revealed: ?usize = null;

/// Scroll the strip to the active tab when it changes: one switched to out
/// of sight — Ctrl+Tab, the palette, a repository opened — comes into view.
/// Only then, so the strip scrolled by hand stays where it was put.
fn revealTab(at: usize, rect: dvui.Rect.Physical) void {
    if (tab_revealed == at or rect.w <= 0) return;
    tab_revealed = at;
    dvui.scrollTo(.{ .screen_rect = rect });
}

/// Who commits from this machine, as git's global config says: read once,
/// and again after the identity is saved.
pub var me_name: std.ArrayList(u8) = .empty;
pub var me_email: std.ArrayList(u8) = .empty;
/// The GitHub login Zit is connected as; empty when it is not.
pub var me_gh: std.ArrayList(u8) = .empty;
pub var me_loaded = false;

pub fn loadMe() void {
    if (me_loaded) return;
    me_loaded = true;
    _ = app.readIdentity(&me_name, &me_email);
    // The login Zit's own sign-in saved, from the disk: no request per frame.
    me_gh.clearRetainingCapacity();
    if (!tab_strip.integrations) return;
    github.login(&me_gh);
}

pub fn forgetMe() void {
    me_name.deinit(app.gpa);
    me_name = .empty;
    me_email.deinit(app.gpa);
    me_email = .empty;
    me_gh.deinit(app.gpa);
    me_gh = .empty;
    me_loaded = false;
}

/// The person committing, as a commit the avatar can be drawn for.
pub fn meAsCommit() git.Commit {
    const name = std.mem.trim(u8, me_name.items, " \r\n");
    return .{
        .id = std.mem.zeroes(git.Oid),
        .summary = "",
        .author = if (name.len > 0) name else "?",
        .email = std.mem.trim(u8, me_email.items, " \r\n"),
        .time = 0,
    };
}

/// At the strip's very end, the face of whoever commits here: one button for
/// them and for Zit. A click drops who that is, then the settings, the keys,
/// the theme, signing — and the GitHub account, with the integrations on.
pub fn userMenu() void {
    loadMe();
    const me = meAsCommit();
    const button = DropButton.begin(@src(), .{
        .tag = "toolbar:user",
        .expand = .vertical,
        .background = false,
        .padding = .{ .x = style.space.sm, .w = style.space.xs },
    });
    {
        // The face, and the chevron that says it opens.
        var face = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false });
        defer face.deinit();
        app.avatarSized(@src(), 0, me, null, null, 22);
        dvui.icon(@src(), "user_chevron", dvui.entypo.chevron_small_down, .{ .fill_color = .{ .color = style.textMuted() } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
        });
    }
    const menu = button.open();
    defer button.end(menu);
    const m = menu orelse return;

    // Who: the avatar, the name, the address.
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
            .min_size_content = .{ .w = graph_view.MENU_MIN_W },
            .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.lg, .h = style.space.sm },
        });
        defer head.deinit();
        app.avatarSized(@src(), 1, me, null, null, 36);
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.xs } });
        defer col.deinit();
        const set = me_name.items.len > 0 and me_email.items.len > 0;
        dvui.label(@src(), "{s}", .{if (set) me.author else "No Git identity"}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "{s}", .{if (set) me.email else "Commits need a name and an email"}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0) });
    }
    graph_view.menuSeparator(0);
    var pick: enum { none, settings, keys, signing, docs, about, sign_in, sign_out } = .none;
    if (graph_view.menuIcon(@src(), dvui.entypo.cog, "Settings — Ctrl+,", false)) pick = .settings;
    if (graph_view.menuIcon(@src(), dvui.entypo.keyboard, "Keyboard shortcuts", false)) pick = .keys;
    if (graph_view.menuIcon(@src(), dvui.entypo.lock, "Commit signature", false)) pick = .signing;
    graph_view.menuSeparator(2);
    if (graph_view.menuIcon(@src(), dvui.entypo.book, "Documentation", false)) pick = .docs;
    if (graph_view.menuIcon(@src(), dvui.entypo.info_with_circle, "About Zit", false)) pick = .about;
    // GitHub's account, only while Zit talks to GitHub at all.
    if (tab_strip.integrations) {
        graph_view.menuSeparator(1);
        if (me_gh.items.len > 0) {
            var buf: [96]u8 = undefined;
            const caption = std.fmt.bufPrint(&buf, "Sign out of GitHub ({s})", .{me_gh.items}) catch "Sign out of GitHub";
            if (graph_view.menuIcon(@src(), dvui.entypo.log_out, caption, true)) pick = .sign_out;
        } else {
            if (graph_view.menuIcon(@src(), dvui.entypo.login, "Sign in with GitHub", false)) pick = .sign_in;
        }
    }
    if (pick == .none) return;
    m.close();
    switch (pick) {
        .none => {},
        .settings => app.openSettings(5),
        .keys => {
            app.keys_open = true;
            app.keys_rect = .{};
        },
        .signing => app.openSettings(6),
        .docs => app.openUrl(app.SITE_URL),
        .about => {
            app.features_open = true;
            app.features_rect = .{};
        },
        .sign_in => {
            app.openIdentity();
            app.signInWithGithub();
        },
        .sign_out => app.ask(.sign_out, me_gh.items),
    }
}

/// Zit's token gone from this machine: the pull requests, issues and
/// pictures that came through it stop until a sign-in. GitHub keeps the
/// authorisation itself until it is revoked in its settings.
pub fn signOutGithub(login: []const u8) void {
    _ = login;
    github.signOut();
    me_loaded = false;
    app.refreshRequests();
}
