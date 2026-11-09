const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const search_view = @import("search_view.zig");
const rebase_view = @import("rebase_view.zig");
const commit_view = @import("commit_view.zig");
const dialog_views = @import("dialog_views.zig");
const repo_settings = @import("repo_settings.zig");
const app = @import("../main.zig");

// === Split diff ===
//
// The same diff as two columns, old on the left and new on the right, with
// each run of removed lines set against the run of added lines that replaced
// it — the layout a change is easiest to read in. Only the row plan is new:
// the lines, the hunk buttons and the line picking are the unified view's.

pub var diff_split: bool = false;

pub const NO_LINE = std.math.maxInt(u32);

/// A file's header in the diff: two lines high, room for its name and its
/// buttons.
pub const FILE_ROWS = 2;

const SplitRow = struct {
    /// `pad`: the header's second line, drawn by the first.
    kind: enum { file, pad, hunk, pair },
    file: u32,
    /// Indices into that file's lines; NO_LINE where the side has nothing.
    left: u32 = NO_LINE,
    right: u32 = NO_LINE,
};

pub var split_rows: std.ArrayList(SplitRow) = .empty;

/// A buffer that grew for one big diff gives the room back once a smaller one
/// replaces it, rather than keeping its peak for the rest of the run.
fn shrinkSpare(comptime T: type, list: *std.ArrayList(T)) void {
    if (list.capacity > 4 * list.items.len + 4096 / @sizeOf(T)) list.shrinkAndFree(app.gpa, list.items.len);
}

pub fn buildSplitRows() void {
    split_rows.clearRetainingCapacity();
    defer shrinkSpare(SplitRow, &split_rows);
    const d = app.diff orelse return;
    for (d.files, 0..) |file, fi_usize| {
        const fi: u32 = @intCast(fi_usize);
        split_rows.append(app.gpa, .{ .kind = .file, .file = fi }) catch return;
        split_rows.append(app.gpa, .{ .kind = .pad, .file = fi }) catch return;
        var dels: std.ArrayList(u32) = .empty;
        defer dels.deinit(app.gpa);
        var adds: std.ArrayList(u32) = .empty;
        defer adds.deinit(app.gpa);

        for (file.lines, 0..) |line, li_usize| {
            const li: u32 = @intCast(li_usize);
            switch (line.kind) {
                .deletion => {
                    // A deletion after additions starts a new run.
                    if (adds.items.len > 0) flushRun(fi, &dels, &adds);
                    dels.append(app.gpa, li) catch return;
                },
                .addition => adds.append(app.gpa, li) catch return,
                .hunk_header => {
                    flushRun(fi, &dels, &adds);
                    split_rows.append(app.gpa, .{ .kind = .hunk, .file = fi, .left = li }) catch return;
                },
                .context, .no_newline => {
                    flushRun(fi, &dels, &adds);
                    split_rows.append(app.gpa, .{ .kind = .pair, .file = fi, .left = li, .right = li }) catch return;
                },
            }
        }
        flushRun(fi, &dels, &adds);
    }
}

/// Set a run of removed lines against the added ones that follow it, line
/// for line; the longer side runs on alone.
fn flushRun(fi: u32, dels: *std.ArrayList(u32), adds: *std.ArrayList(u32)) void {
    const n = @max(dels.items.len, adds.items.len);
    for (0..n) |i| {
        split_rows.append(app.gpa, .{
            .kind = .pair,
            .file = fi,
            .left = if (i < dels.items.len) dels.items[i] else NO_LINE,
            .right = if (i < adds.items.len) adds.items[i] else NO_LINE,
        }) catch return;
    }
    dels.clearRetainingCapacity();
    adds.clearRetainingCapacity();
}

/// One half of a split row: a line, or the blank where that side has none.
fn splitHalf(
    src: std.builtin.SourceLocation,
    id: usize,
    file: git.FileDiff,
    line_index: u32,
    x: f32,
    y: f32,
    w: f32,
    rh: f32,
    side: ?git.DiffSide,
    pick: bool,
) void {
    const present = line_index != NO_LINE;
    const line: ?git.DiffLine = if (present) file.lines[line_index] else null;
    const kind: git.DiffLine.Kind = if (line) |l| l.kind else .context;
    const pickable = pick and side != null and present and (kind == .addition or kind == .deletion);
    const picked = pickable and rebase_view.isPicked(line_index);

    const fill: ?dvui.Color = if (!present)
        style.rowHover()
    else if (picked)
        style.accentDim()
    else switch (kind) {
        .addition => style.diffAddedFill(),
        .deletion => style.diffRemovedFill(),
        else => null,
    };

    var box = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id,
        .rect = .{ .x = x, .y = y, .w = w, .h = rh },
        .background = true,
        .color_fill = .{ .color = fill orelse style.background() },
        .padding = .{ .x = style.space.sm, .w = style.space.sm },
    });
    defer box.deinit();

    const l = line orelse return;
    rebase_view.lineNumber(@src(), if (kind == .addition) l.new_no else if (kind == .deletion) l.old_no else if (x > 0) l.new_no else l.old_no);
    rebase_view.codeLine(file, line_index);

    if (pickable and dvui.clicked(box.data(), .{})) rebase_view.togglePicked(line_index, file.lines.len);
}

/// How the diff is read: whitespace counted or not, and how much context
/// around each change. Either one reads it again.
fn diffReadControls() void {
    const o = &git.diff_options;
    if (dialog_views.chipButton(@src(), if (o.ignore_whitespace) dvui.entypo.check else dvui.entypo.erase, "Ignore whitespace", o.ignore_whitespace)) {
        o.ignore_whitespace = !o.ignore_whitespace;
        app.diff_stale = true;
    }
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.sm, .w = style.space.md } });
    defer box.deinit();
    if (dialog_views.iconButton(@src(), "context_less", "Less context", dvui.entypo.minus, style.textMuted()) and o.context > 1) {
        o.context = if (o.context > 10) 10 else if (o.context > 3) 3 else o.context - 1;
        app.diff_stale = true;
    }
    dvui.label(@src(), "{d} lines", .{o.context}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
    if (dialog_views.iconButton(@src(), "context_more", "More context", dvui.entypo.plus, style.textMuted()) and o.context < 25) {
        o.context = if (o.context < 3) o.context + 1 else if (o.context < 10) 10 else 25;
        app.diff_stale = true;
    }
}

/// Unified or split: two halves of one control, as the Path / Tree one.
fn diffModeToggle(src: std.builtin.SourceLocation) void {
    var track = dvui.box(src, .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .padding = dvui.Rect.all(2),
        .margin = .{ .x = style.space.sm, .w = style.space.lg },
    });
    defer track.deinit();
    for ([_]bool{ false, true }, 0..) |split, i| {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .tag = if (split) "diff:split" else "diff:unified",
            .background = false,
            .margin = dvui.Rect.all(0),
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        const selected = diff_split == split;
        {
            var cell = dvui.box(@src(), .{}, .{
                .background = selected or bw.hovered(),
                .color_fill = .{ .color = if (selected) style.accentDim() else style.rowHover() },
                .corners = style.radius.input,
                .padding = .{ .x = style.space.md, .w = style.space.md, .y = style.space.xs, .h = style.space.xs },
            });
            defer cell.deinit();
            dvui.label(@src(), "{s}", .{if (split) "Split" else "Unified"}, .{
                .font = if (selected) style.smallBold() else style.small(),
                .color_text = .{ .color = if (selected) style.accent() else style.textFaint() },
                .padding = dvui.Rect.all(0),
            });
        }
        if (bw.clicked()) {
            diff_split = split;
            app.diff_scroll.viewport.y = 0;
        }
        bw.deinit();
    }
}

/// The sidebar's sections, in the order it shows them: what is on disk
/// first — the branches, the worktrees, the stashes — then the host's pull
/// requests and issues, the tags last.
pub const Section = enum(u8) {
    local,
    /// Each remote with its branches under it, the way GitKraken nests them.
    remotes,
    worktrees,
    stashes,
    pulls,
    issues,
    tags,

    pub fn label(self: Section) []const u8 {
        return switch (self) {
            .local => "LOCAL",
            .remotes => "REMOTES",
            .stashes => "STASHES",
            .tags => "TAGS",
            .worktrees => "WORKTREES",
            .pulls => "PULL REQUESTS",
            .issues => "ISSUES",
        };
    }

    /// The name on its header, as GitComet writes it; `label` stays the
    /// section's tag.
    pub fn title(self: Section) []const u8 {
        return switch (self) {
            .local => "Local",
            .remotes => "Remotes",
            .stashes => "Stashes",
            .tags => "Tags",
            .worktrees => "Worktrees",
            .pulls => "Pull requests",
            .issues => "Issues",
        };
    }

    /// What an open section with nothing in it says, in its place.
    pub fn empty(self: Section) ?[]const u8 {
        return switch (self) {
            .local => "No branches",
            .remotes => "No remotes",
            .stashes => "No stashes",
            .tags => "No tags",
            .worktrees => "No worktrees",
            // Their own notes: loading, failed, none open.
            .pulls, .issues => null,
        };
    }

    /// The kind of ref this section lists, or null for the three that list
    /// something that is not a ref.
    pub fn refKind(self: Section) ?git.Ref.Kind {
        return switch (self) {
            .local => .local,
            .tags => .tag,
            .remotes, .stashes, .worktrees, .pulls, .issues => null,
        };
    }
};

/// All folded to begin with: the headers and their counts are the overview,
/// and a section is opened for what is in it.
pub var section_collapsed: [@typeInfo(Section).@"enum".field_names.len]bool = @splat(true);

// === Centre: the diff ===

/// The centre pane when something is selected: the diff a commit introduced, or
/// one file of the working tree.
///
/// It takes the graph's place rather than adding a fourth pane, so the file
/// list you stage from stays visible beside it.
pub fn diffPanel() void {
    app.ensureDiff();

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    defer panel.deinit();

    diffHeader();

    // A conflicted file has no diff worth reading — it is a file full of
    // markers — so it gets the regions instead.
    if (rebase_view.isConflictView()) return rebase_view.conflictBody();

    const d = app.diff orelse {
        dialog_views.emptyState(@src(), "Nothing to show.");
        return;
    };
    if (d.files.len == 0) {
        dialog_views.emptyState(@src(), "This commit changed no files.");
        return;
    }
    // A picture is shown, not said to be binary.
    if (d.files.len == 1 and isImagePath(d.files[0].path)) return imagePreview(d.files[0]);

    // Hunk buttons only mean something against the working tree: a commit's
    // diff is history, not something to stage.
    // Nor against a diff read ignoring whitespace: its hunks are not the
    // file's, and a patch built from them would not apply. Nor for a rename:
    // the diff is read under the new name only, so a hunk of it would move
    // half the rename; the whole-file buttons take both names.
    const side: ?git.DiffSide = if (git.diff_options.ignore_whitespace) null else switch (app.selection) {
        .change => |s| if (app.selectedStatus(s) == .renamed) null else s,
        else => null,
    };

    // Taller with a larger editor text, never shorter.
    const rh = style.diff_row * @max(1, style.code_scale);
    const total_rows = if (diff_split) split_rows.items.len else app.diff_rows;
    app.diff_scroll.virtual_size.h = @as(f32, @floatFromInt(total_rows)) * rh;

    // Drawn once the scroll area is done, over its right edge.
    var marker_area: ?dvui.RectScale = null;
    defer if (marker_area) |area| diffMarkers(area, d, total_rows);

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &app.diff_scroll }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer scroll.deinit();
    marker_area = scroll.data().borderRectScale();

    const width = @max(app.diff_scroll.viewport.w, 320);

    // Only the rows on screen are built, exactly as in the graph: a real diff
    // is routinely thousands of lines, and each line is several widgets.
    const top = @max(0, app.diff_scroll.viewport.y);
    const first = @as(usize, @intFromFloat(@floor(top / rh))) -| 1;
    const last = first + @as(usize, @intFromFloat(@ceil(app.diff_scroll.viewport.h / rh))) + 3;

    if (diff_split) {
        const end = @min(last, split_rows.items.len);
        for (@min(first, end)..end) |r| {
            const sr = split_rows.items[r];
            const file = d.files[sr.file];
            const pick = sr.file == 0;
            switch (sr.kind) {
                .file => rebase_view.diffFileRow(@src(), file, r, r, width, rh),
                .pad => {},
                .hunk => rebase_view.diffLineRow(@src(), file, file.lines[sr.left], r, width, rh, side, if (pick) sr.left else null),
                .pair => {
                    const y = @as(f32, @floatFromInt(r)) * rh;
                    splitHalf(@src(), r * 2, file, sr.left, 0, y, width / 2, rh, side, pick);
                    splitHalf(@src(), r * 2 + 1, file, sr.right, width / 2, y, width - width / 2, rh, side, pick);
                },
            }
        }
        return;
    }

    var row: usize = 0;
    for (d.files, 0..) |file, fi| {
        // Its second line too, so a header scrolled half out is still drawn.
        if (row + 1 >= first and row < last) rebase_view.diffFileRow(@src(), file, fi, row, width, rh);
        row += FILE_ROWS;

        for (file.lines, 0..) |line, li| {
            if (row >= first and row < last) {
                // Only one file is on screen when it is a change, which is the
                // only time a line can be picked.
                rebase_view.diffLineRow(@src(), file, line, row, width, rh, side, if (fi == 0) li else null);
            }
            row += 1;
        }
    }
}

/// A file whose bytes dvui can draw.
fn isImagePath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tga" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// The two versions of a picture the diff is about, read once per file
/// shown: before — the parent's, or HEAD's for a change — and after — the
/// commit's, or the working tree's. Owned.
var image_pair: struct {
    key: u64 = 0,
    before: ?[]u8 = null,
    after: ?[]u8 = null,
} = .{};

pub fn clearImagePair() void {
    if (image_pair.before) |b| app.gpa.free(b);
    if (image_pair.after) |b| app.gpa.free(b);
    image_pair = .{};
}

fn loadImagePair(file: git.FileDiff) void {
    const r = app.repo orelse return;
    var key = std.hash.Wyhash.init(0);
    key.update(std.mem.asBytes(&app.selection));
    key.update(file.path);
    if (key.final() == image_pair.key) return;
    clearImagePair();
    image_pair.key = key.final();
    switch (app.selection) {
        .commit => |id| {
            if (file.status != .deleted) image_pair.after = r.blobAt(app.gpa, id, file.path);
            if (file.status != .added) if (commitAt(id)) |c| if (c.parents.len > 0) {
                image_pair.before = r.blobAt(app.gpa, c.parents[0], file.old_path);
            };
        },
        .change => {
            const full = std.fs.path.join(app.gpa, &.{ app.repo_path.items, file.path }) catch return;
            defer app.gpa.free(full);
            image_pair.after = std.Io.Dir.cwd().readFileAlloc(app.app_io, full, app.gpa, .limited(64 << 20)) catch null;
            if (app.history) |h| if (h.head_oid) |head| {
                image_pair.before = r.blobAt(app.gpa, head, file.path);
            };
        },
        else => {},
    }
}

/// The picture, before and after side by side — or the one there is — each
/// at most its half of the pane, on a framed ground.
fn imagePreview(file: git.FileDiff) void {
    loadImagePair(file);
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .color_fill = .{ .color = style.background() } });
    defer scroll.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(style.space.xl) });
    defer row.deinit();
    const sides = [_]struct { []const u8, ?[]u8, dvui.Color }{
        .{ "Before", image_pair.before, style.danger() },
        .{ "After", image_pair.after, style.success() },
    };
    var shown: usize = 0;
    for (sides, 0..) |side, i| {
        const bytes = side[1] orelse continue;
        shown += 1;
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .expand = .horizontal, .background = false, .margin = .{ .x = style.space.sm, .w = style.space.sm } });
        defer col.deinit();
        // Only one side: no word needed over it.
        if (image_pair.before != null and image_pair.after != null) dvui.label(@src(), "{s}", .{side[0]}, .{ .font = style.smallBold(), .color_text = .{ .color = side[2] }, .padding = dvui.Rect.all(0), .margin = .{ .h = style.space.sm } });
        var frame = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surfaceInput() },
            .border = dvui.Rect.all(1),
            .color_border = .{ .color = style.border() },
            .corners = style.radius.input,
            .padding = dvui.Rect.all(style.space.md),
        });
        defer frame.deinit();
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = bytes, .name = if (i == 0) "before" else "after" } },
            .shrink = .ratio,
        }, .{
            .gravity_x = 0.5,
            .max_size_content = .size(.{ .w = 900, .h = 600 }),
            .label = .{ .text = file.path },
        });
    }
    if (shown == 0) dialog_views.emptyState(@src(), "This picture could not be read.");
}

/// Where the diff changes, along the right edge of its scroll area: a red
/// mark for removed lines, a green one for added, each at its place in the
/// whole — the overview VS Code keeps in its scrollbar. Runs of the same kind
/// are one mark.
fn diffMarkers(area: dvui.RectScale, d: git.Diff, total_rows: usize) void {
    if (total_rows == 0) return;
    const s = area.s;
    const strip_w = 4 * s;
    const x = area.r.x + area.r.w - strip_w - 1 * s;
    const scale = area.r.h / @as(f32, @floatFromInt(total_rows));
    const min_h = 2 * s;

    const Kind = enum { none, add, del, both };
    var run_kind: Kind = .none;
    var run_start: usize = 0;

    const flush = struct {
        fn f(kind: Kind, from: usize, to: usize, a: dvui.RectScale, xx: f32, w: f32, sc: f32, mh: f32) void {
            if (kind == .none) return;
            const color = switch (kind) {
                .add => style.success(),
                .del => style.danger(),
                else => style.get().yellow,
            };
            const top = a.r.y + @as(f32, @floatFromInt(from)) * sc;
            const h = @max(mh, @as(f32, @floatFromInt(to - from)) * sc);
            (dvui.Rect.Physical{ .x = xx, .y = top, .w = w, .h = h }).fill(.{}, .{ .color = .{ .color = color.opacity(0.85) }, .fade = 0 });
        }
    }.f;

    var row: usize = 0;
    if (diff_split) {
        for (split_rows.items, 0..) |sr, r| {
            var kind: Kind = .none;
            if (sr.kind == .pair) {
                const file = d.files[sr.file];
                const left_del = sr.left != NO_LINE and file.lines[sr.left].kind == .deletion;
                const right_add = sr.right != NO_LINE and file.lines[sr.right].kind == .addition;
                kind = if (left_del and right_add) .both else if (left_del) .del else if (right_add) .add else .none;
            }
            if (kind != run_kind) {
                flush(run_kind, run_start, r, area, x, strip_w, scale, min_h);
                run_kind = kind;
                run_start = r;
            }
        }
        row = split_rows.items.len;
    } else {
        for (d.files) |file| {
            // The file's own header row.
            if (run_kind != .none) {
                flush(run_kind, run_start, row, area, x, strip_w, scale, min_h);
                run_kind = .none;
            }
            row += FILE_ROWS;
            for (file.lines) |line| {
                const kind: Kind = switch (line.kind) {
                    .addition => .add,
                    .deletion => .del,
                    else => .none,
                };
                if (kind != run_kind) {
                    flush(run_kind, run_start, row, area, x, strip_w, scale, min_h);
                    run_kind = kind;
                    run_start = row;
                }
                row += 1;
            }
        }
    }
    flush(run_kind, run_start, row, area, x, strip_w, scale, min_h);
}

/// The diff's own bar: its controls with room around them.
const DIFF_HEAD_H: f32 = 52;

/// "← Graph": the way back from a diff to the commit list, said in words.
fn backButton(src: std.builtin.SourceLocation) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, .{
        .tag = "diff:back",
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = style.surfaceRaised() },
        .color_fill_hover = .{ .color = style.rowHover() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .margin = .{ .x = style.space.xs, .w = style.space.md },
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.lg, .h = style.space.sm },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
        defer row.deinit();
        const color = if (bw.hovered()) style.accent() else style.text();
        dvui.icon(@src(), "back_icon", dvui.entypo.chevron_small_left, .{ .fill_color = .{ .color = color } }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
        });
        dvui.label(@src(), "Graph", .{}, .{
            .font = style.smallBold(),
            .color_text = .{ .color = color },
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(0),
        });
    }
    if (bw.hovered()) {
        dvui.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r, .position = .vertical, .delay = 400_000 }, "Back to the commits — Esc", .{}, .{ .font = style.small() });
    }
    return bw.clicked();
}

fn diffHeader() void {
    var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .min_size_content = .{ .h = DIFF_HEAD_H },
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.md, .w = style.space.lg },
    });
    defer head.deinit();

    if (backButton(@src())) {
        app.closeDiff();
        app.active_view = .graph;
    }
    if (!rebase_view.isConflictView() and app.selection != .blame) {
        diffModeToggle(@src());
        diffReadControls();
    }

    switch (app.selection) {
        .none, .rebase, .blame => {},
        .compare => {
            dvui.icon(@src(), "compare_icon", dvui.entypo.swap, .{ .fill_color = .{ .color = style.accent() } }, .{
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .margin = .{ .w = style.space.sm },
            });
            dvui.label(@src(), "{s}", .{app.compare_label}, .{
                .font = style.small(),
                .color_text = .{ .color = style.text() },
                .gravity_y = 0.5,
                .expand = .horizontal,
                .max_size_content = .width(0),
                .padding = dvui.Rect.all(0),
            });
        },
        .commit => |id| {
            var buf: [8]u8 = undefined;
            dvui.label(@src(), "{s}", .{git.oidShort(id, &buf)}, .{
                .font = style.mono(),
                .color_text = .{ .color = style.accent() },
                .background = true,
                .color_fill = .{ .color = style.accentDim() },
                .corners = style.radius.tag,
                .gravity_y = 0.5,
                .margin = .{ .x = style.space.sm, .w = style.space.md },
                .padding = .{ .x = style.space.sm, .y = 2, .w = style.space.sm, .h = 2 },
            });
            dvui.label(@src(), "{s}", .{commitSummary(id)}, .{
                .font = style.small(),
                .color_text = .{ .color = style.text() },
                .gravity_y = 0.5,
                .expand = .horizontal,
                .max_size_content = .width(0),
                .padding = dvui.Rect.all(0),
            });
        },
        .change => |side| {
            dvui.label(@src(), "{s}", .{app.selected_path.items}, .{
                .font = style.small(),
                .color_text = .{ .color = style.text() },
                .gravity_y = 0.5,
                .expand = .horizontal,
                .max_size_content = .width(0),
                .margin = .{ .x = style.space.xs },
                .padding = dvui.Rect.all(0),
            });

            if (app.selectedStatus(side) == .conflicted) {
                // The answers for a conflict nobody needs to read. `checkout`
                // rewrites the file; the index stays conflicted until it is
                // staged, which is what "resolved" means to git.
                // Taking back a pick, and starting the file over, while there
                // is something to take back.
                if (app.resolve_undo.items.len > 0) {
                    if (dialog_views.linkButtonTagged(@src(), "Undo pick", style.textMuted(), "conflict:undo")) app.requestAction(.undo_resolve);
                    if (dialog_views.linkButtonTagged(@src(), "Start over", style.textMuted(), "conflict:restart")) app.ask(.restart_file, app.selected_path.items);
                }
                // The whole file as one side has it, staged in the same click.
                // Not for one deleted on a side: its panel asks that plainly.
                if (!app.wholeFileConflict()) {
                    const names = rebase_view.sideNames();
                    var ours_buf: [96]u8 = undefined;
                    var theirs_buf: [96]u8 = undefined;
                    if (dialog_views.linkButtonTagged(@src(), rebase_view.allCaption(&ours_buf, names.ours), style.success(), "conflict:all_ours")) rebase_view.takeFile(.ours);
                    if (dialog_views.linkButtonTagged(@src(), rebase_view.allCaption(&theirs_buf, names.theirs), style.get().blue, "conflict:all_theirs")) rebase_view.takeFile(.theirs);
                }
                if (dialog_views.linkButtonTagged(@src(), "Mark resolved", style.accent(), "conflict:resolved")) app.requestAction(.stage_next);
                return;
            }

            if (dialog_views.linkButton(@src(), "Open in editor", style.textMuted())) repo_settings.openInEditor(app.selected_path.items);
            if (dialog_views.linkButton(@src(), "Blame", style.textMuted())) app.selectBlame(app.selected_path.items);

            // The whole-file counterpart of the per-hunk buttons below, and the
            // only thing on offer for a binary file or a mode change.
            if (side == .unstaged) {
                if (dialog_views.linkButton(@src(), "Stage file", style.accent())) {
                    commit_view.requestStage(app.selected_path.items, app.oldPathOf(side, app.selected_path.items), true);
                }
            } else {
                if (dialog_views.linkButton(@src(), "Unstage file", style.accent())) {
                    commit_view.requestStage(app.selected_path.items, app.oldPathOf(side, app.selected_path.items), false);
                }
            }
        },
    }
}

/// The commit itself, while it is still in the history snapshot.
pub fn commitAt(id: git.Oid) ?git.Commit {
    const h = app.history orelse return null;
    const at = h.indexOf(id) orelse return null;
    return h.commits[at];
}

/// Summary of a commit still in the history snapshot; empty for one that is
/// not.
pub fn commitSummary(id: git.Oid) []const u8 {
    return if (commitAt(id)) |c| c.summary else "";
}

/// After a new history: a commit picked before a rebase or an amend rewrote
/// it is not in it any more, and its pane would show a commit with no
/// message. The working tree comes back instead, as after Esc.
pub fn dropStaleSelection() void {
    switch (app.selection) {
        .commit => |id| if (commitAt(id) == null) app.clearSelection(),
        else => {},
    }
}

// === Centre: blame ===

/// Every line of a file with the commit that last touched it.
///
/// Repeats are blank rather than restated: a file is mostly runs of lines from
/// one commit, and printing the same sha forty times buries the four places it
/// actually changes.
pub fn blamePanel() void {
    app.ensureDiff();

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = style.background() },
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    defer panel.deinit();

    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .min_size_content = .{ .h = style.toolbar_cell },
            .border = .{ .h = 1 },
            .color_border = .{ .color = style.borderSubtle() },
            .padding = .{ .x = style.space.xs, .w = style.space.md },
        });
        defer head.deinit();

        if (dialog_views.iconButton(@src(), "blame_close", "Back to the graph — Esc", dvui.entypo.chevron_small_left, style.textMuted())) {
            app.clearSelection();
        }

        dvui.label(@src(), "Blame", .{}, .{
            .font = style.smallBold(),
            .color_text = .{ .color = style.accent() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.xs, .w = style.space.sm },
            .padding = dvui.Rect.all(0),
        });

        dvui.label(@src(), "{s}", .{app.selected_path.items}, .{
            .font = style.small(),
            .color_text = .{ .color = style.text() },
            .gravity_y = 0.5,
            .expand = .horizontal,
            .max_size_content = .width(0),
            .padding = dvui.Rect.all(0),
        });
    }

    const b = app.blame_view orelse {
        dialog_views.emptyState(@src(), "Nothing to blame.");
        return;
    };

    const rh = style.diff_row * @max(1, style.code_scale);
    app.blame_scroll.virtual_size.h = @as(f32, @floatFromInt(b.lines.len)) * rh;

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &app.blame_scroll }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(0),
    });
    defer scroll.deinit();

    const width = @max(app.blame_scroll.viewport.w, 320);
    const top = @max(0, app.blame_scroll.viewport.y);
    const first = @as(usize, @intFromFloat(@floor(top / rh))) -| 1;
    const last = @min(b.lines.len, first + @as(usize, @intFromFloat(@ceil(app.blame_scroll.viewport.h / rh))) + 3);

    for (first..last) |i| {
        // The first visible row always shows its commit, even mid-run: it has
        // no predecessor on screen to have shown it.
        const starts_run = i == 0 or i == first or !git.oidEql(b.lines[i].id, b.lines[i - 1].id);
        blameRow(@src(), b.lines[i], i, starts_run, width, rh);
    }
}

fn blameRow(
    src: std.builtin.SourceLocation,
    line: git.BlameLine,
    index: usize,
    starts_run: bool,
    width: f32,
    rh: f32,
) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = index,
        .rect = .{ .x = 0, .y = @as(f32, @floatFromInt(index)) * rh, .w = width, .h = rh },
        .background = starts_run,
        .color_fill = .{ .color = style.rowHover() },
        .padding = .{ .x = style.space.md, .w = style.space.md },
    });
    defer row.deinit();

    var sha_buf: [8]u8 = undefined;
    dvui.label(@src(), "{s}", .{if (starts_run) git.oidShort(line.id, &sha_buf) else ""}, .{
        .font = style.mono(),
        .color_text = .{ .color = style.accent() },
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 58 },
        .padding = dvui.Rect.all(0),
    });

    dvui.label(@src(), "{s}", .{if (starts_run) line.author else ""}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textMuted() },
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 110 },
        .max_size_content = .width(110),
        .padding = dvui.Rect.all(0),
    });

    var time_buf: [32]u8 = undefined;
    dvui.label(@src(), "{s}", .{if (starts_run and line.time > 0) search_view.relativeTime(&time_buf, line.time) else ""}, .{
        .font = style.tiny(),
        .color_text = .{ .color = style.textFaint() },
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 78 },
        .padding = dvui.Rect.all(0),
    });

    rebase_view.lineNumber(@src(), @intCast(index + 1));
    var tab_buf: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;

    dvui.label(@src(), "{s}", .{rebase_view.detab(&tab_buf, line.text)}, .{
        .font = style.mono(),
        .color_text = .{ .color = style.text() },
        .gravity_y = 0.5,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .margin = .{ .x = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
}
