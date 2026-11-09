const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const diff_view = @import("diff_view.zig");
const app = @import("../main.zig");

// === Left: refs ===

/// The left panel. Each view brings its own: the branches for the history,
/// the changed files for a diff, the conflicts for a merge.
pub fn sidebarPane() void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .w = 1 },
        .color_border = .{ .color = style.border() },
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    defer panel.deinit();

    // A merge or rebase under way: what is left of it first, the branches
    // after — it is the one thing to finish before anything else.
    if (app.active_view == .graph and app.history != null and app.history.?.state != .none) mergeSidebar();
    refsSidebar();
}

/// One line of small capitals over a list.
fn sidebarLabel(src: std.builtin.SourceLocation, caption: []const u8, count: ?usize) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .{
            .x = style.space.lg,
            .y = style.space.sm,
            .w = style.space.lg,
            .h = style.space.xs,
        },
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{caption}, .{
        .font = style.section(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });

    const n = count orelse return;

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });

    dvui.label(@src(), "{d}", .{n}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// History view: branches, remotes, stashes, tags.
fn refsSidebar() void {
    // A filter over the branches and tags: in a repository with a hundred of
    // them it is how anything is found, as in the "Branches:" menu.
    _ = app.searchField(@src(), &app.sidebar_filter, "Filter branches and tags…", "sidebar_filter", .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm });

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(0),
        // Only the height the window leaves: dvui asks for all of its
        // content, and every section open pushed the status bar out of it.
        .max_size_content = .height(0),
    });
    defer scroll.deinit();

    // Collected outside the loop: checking a branch out rebuilds the history
    // these refs point into.
    var chosen: ?git.Ref = null;

    for (std.enums.values(diff_view.Section), 0..) |section, i| {
        if (app.sidebarSection(@src(), section, i)) |ref| chosen = ref;
    }

    if (chosen) |ref| app.checkout(ref);
}

/// A merge or rebase under way, over the branches: what it is, how much is
/// left, and the way on — continue, skip, or abort.
fn mergeSidebar() void {
    const w = app.work orelse return;
    const pending = app.conflictCount();

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surfaceRaised() },
        .corners = style.radius.input,
        .padding = dvui.Rect.all(style.space.md),
        .margin = .{ .x = style.space.md, .y = style.space.md, .w = style.space.md, .h = style.space.sm },
    });
    defer card.deinit();

    if (pending > 0) {
        dvui.label(@src(), "{d} conflicted file{s}", .{ pending, window_chrome.plural(pending) }, .{
            .font = style.bodyBold(),
            .color_text = .{ .color = style.text() },
            .padding = dvui.Rect.all(0),
            .margin = .{ .h = style.space.xs },
        });
    } else {
        dvui.label(@src(), "Every conflict is resolved", .{}, .{
            .font = style.bodyBold(),
            .color_text = .{ .color = style.success() },
            .padding = dvui.Rect.all(0),
        });
        if (app.canContinue()) dvui.label(@src(), "Continue from the bar above — Ctrl+Enter", .{}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textMuted() },
            .margin = .{ .y = style.space.xs },
            .padding = dvui.Rect.all(0),
        });
    }

    // Each one a click away: the list the resolving goes down.
    for (w.unstaged, 0..) |change, i| {
        if (change.status != .conflicted) continue;
        conflictFileRow(i, change.path);
    }
}

/// A conflicted file in the sidebar's card: lit while it is the one open.
fn conflictFileRow(id: usize, path: []const u8) void {
    const open = app.viewingConflict() and std.mem.eql(u8, app.selected_path.items, path);
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .id_extra = id,
        .tag = app.frameTag("conflict_file", path),
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = if (open) style.accentDim() else style.surfaceRaised() },
        .color_fill_hover = .{ .color = if (open) style.accentDim() else style.rowHover() },
        .corners = style.radius.input,
        .margin = .{ .y = 2 },
        .padding = .{ .x = style.space.sm, .y = 5, .w = style.space.sm, .h = 5 },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
        defer row.deinit();
        dvui.icon(@src(), "conflict_icon", dvui.entypo.warning, .{ .fill_color = .{ .color = style.get().yellow } }, .{
            .min_size_content = .{ .w = 11, .h = 11 },
            .gravity_y = 0.5,
            .margin = .{ .w = style.space.sm },
        });
        var buf: [app.MAX_SHOWN_LINE]u8 = undefined;
        dvui.label(@src(), "{s}", .{graph_view.fitText(&buf, path, style.small(), 170)}, .{
            .font = style.small(),
            .color_text = .{ .color = if (open) style.accent() else style.text() },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }
    if (bw.clicked()) app.selectChange(path, .unstaged);
}
