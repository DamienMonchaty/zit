//! Design tokens for the app.
//!
//! Everything visual goes through here: fonts, the spacing/radius scale, and
//! semantic colours. Call sites ask for a *role* (`textMuted()`, `radius.row`)
//! instead of an ad-hoc `.lighten(-35.0)` or a bare `8`, so the UI stays
//! consistent and is retuned in one place.
//!
//! Colours come from `src/theme/zit_{dark,light}.json`; fonts are
//! compiled in (see `fonts` below).

const std = @import("std");
const dvui = @import("dvui");
const git = @import("git.zig");

// === Fonts ===
//
// Inter for the UI (drawn for screens at small sizes, the face most modern
// desktop tools converged on) and JetBrains Mono for anything monospaced —
// diffs, shas, paths.
//
// dvui addresses at most two weights per family and has no variable-font
// support, so these are static cuts: Regular and Medium. A true Bold smears in
// dense lists, and one step of contrast is enough to mark a heading.
pub const UI_FAMILY = "UI";
pub const MONO_FAMILY = "Mono";

const fonts: []const dvui.Font.Source = &.{
    .{
        .family = dvui.Font.array(UI_FAMILY),
        .bytes = @embedFile("fonts/inter/Inter-Regular.ttf"),
    },
    .{
        .family = dvui.Font.array(UI_FAMILY),
        .weight = .bold,
        .bytes = @embedFile("fonts/inter/Inter-Medium.ttf"),
    },
    .{
        .family = dvui.Font.array(MONO_FAMILY),
        .bytes = @embedFile("fonts/jetbrains-mono/JetBrainsMono-Regular.ttf"),
    },
};

/// Type scale. Kept tight: this is a dense tool, not a document reader.
pub const size = struct {
    // Inter has a tall x-height, so the scale sits half a point small.
    pub const tiny: f32 = 9.5;
    pub const small: f32 = 10.5;
    pub const body: f32 = 12;
    pub const section: f32 = 10;
    pub const title: f32 = 12.5;
    pub const mono: f32 = 11;
    /// Tab names: read from across the window, not scanned in a list.
    pub const tab: f32 = 11;
    /// The commit list: six things a row, thousands of rows. Its own size so
    /// it can be dense without shrinking every other panel with it.
    pub const graph: f32 = 10.75;
    pub const graph_meta: f32 = 10.5;
    /// Sha and date: a mono face reads larger than Inter at the same size.
    pub const graph_mono: f32 = 9.5;
};

pub fn tab() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.tab });
}

pub fn tabBold() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.tab, .weight = .bold });
}

/// A commit's message in the graph.
pub fn graphText() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.graph });
}

/// Author and date in the graph: under the message, never competing with it.
pub fn graphMeta() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.graph_meta });
}

pub fn graphMono() dvui.Font {
    return .find(.{ .family = MONO_FAMILY, .size = size.graph_mono });
}

pub fn body() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.body });
}

pub fn bodyBold() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.body, .weight = .bold });
}

pub fn small() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.small, .line_height_factor = 1.15 });
}

pub fn smallBold() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.small, .weight = .bold, .line_height_factor = 1.15 });
}

pub fn tinyBold() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.tiny, .weight = .bold, .line_height_factor = 1.1 });
}

pub fn tiny() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.tiny, .line_height_factor = 1.1 });
}

/// Panel headers. Small and bold beats large and light for a sidebar.
pub fn section() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.section, .weight = .bold });
}

pub fn title() dvui.Font {
    return .find(.{ .family = UI_FAMILY, .size = size.title, .weight = .bold });
}

pub fn mono() dvui.Font {
    return .find(.{ .family = MONO_FAMILY, .size = size.mono });
}

// === Spacing / geometry ===
//
// One 4px-based scale. Anything that is not on it is a one-off and should be
// justified at the call site.
pub const space = struct {
    pub const xxs: f32 = 2;
    pub const xs: f32 = 4;
    pub const sm: f32 = 6;
    pub const md: f32 = 8;
    pub const lg: f32 = 12;
    pub const xl: f32 = 16;
    pub const xxl: f32 = 24;
};

pub const radius = struct {
    /// Text inputs, small buttons.
    pub const input = dvui.CornerRect.all(6);
    /// List rows, tag headers, menu items.
    pub const row = dvui.CornerRect.all(6);
    /// Ref tags and file flags: tighter, because they are small and square-ish.
    pub const tag = dvui.CornerRect.all(3);
};

/// Height of a row in a list — the sidebar, the file lists. Tracks `size.body`
/// plus the mockup's 6px of padding either side.
pub const row_height: f32 = 28;
/// A row in the sidebar's lists: tighter than a list row, many to a screen.
pub const side_row: f32 = 23;

/// Height of a commit row. Taller than a list row: it carries a lane drawing,
/// an avatar, a tag, a message, an author, a sha and a date — and those are
/// what you scan, so it is dense rather than roomy. Fixed, because the commit
/// list is virtualised.
pub const graph_row: f32 = 26;

/// Diameter of the author's initials disc in a commit row.
pub const avatar: f32 = 21;

/// Height of one line of a diff. A mono line at 1.65, which is the density the
/// mockup reads at. Fixed, for the same reason.
pub const diff_row: f32 = 21;

/// Geometry of the commit graph, which is drawn rather than laid out: every
/// number a lane or a curve is positioned by lives here. The column's width
/// is not one of them — it follows the history's lanes (`graphColumn`).
pub const graph = struct {
    /// Wider than a line needs: every node is an avatar, and two on
    /// neighbouring lanes must not touch. Closer together only when there are
    /// more lanes than room.
    pub const lane_w: f32 = 25;
    /// Between the deepest node and the text, so a ring never touches a tag.
    pub const gap: f32 = 14;
    /// Thickness of a lane line.
    pub const line_w: f32 = 2;
    /// Left inset before the first lane.
    pub const inset: f32 = 14;
};

/// The mockup's grid: a 42px title bar over the sidebar and the content,
/// closed by a 24px status bar.
pub const titlebar_height: f32 = 42;
/// The tab strip above it: one line of small text and a close button.
pub const tab_height: f32 = 30;
pub const statusbar_height: f32 = 24;
/// Height of a pane's own header strip (diff path, detail title).
pub const toolbar_cell: f32 = 30;
/// The three fixed right-hand columns of a commit row. Fixed, not
/// content-sized: a ragged "who" column makes every column after it jump from
/// row to row, and a header can only name a column that stays put.
pub const author_column: f32 = 130;
pub const sha_column: f32 = 80;
pub const time_column: f32 = 150;

// === Palette ===

pub const ColorValue = struct { value: [4]f32 };

/// The JSON colour file. Optional fields fall back to something derived, so a
/// partial theme file still renders correctly.
pub const ThemeFile = struct {
    background: ColorValue,
    foreground: ColorValue,
    text: ColorValue,

    text_secondary: ?ColorValue = null,
    text_background: ?ColorValue = null,

    text_blue: ?ColorValue = null,
    text_orange: ?ColorValue = null,
    text_yellow: ?ColorValue = null,
    text_red: ?ColorValue = null,
    text_green: ?ColorValue = null,
    text_purple: ?ColorValue = null,

    highlight_primary: ?ColorValue = null,
    hover_primary: ?ColorValue = null,
    highlight_secondary: ?ColorValue = null,
    hover_secondary: ?ColorValue = null,
};

/// Resolved palette, kept around because `dvui.Theme` has nowhere to store the
/// app's own roles (secondary text, the git hues, ...).
pub const Palette = struct {
    dark: bool = true,

    background: dvui.Color = .black,
    surface: dvui.Color = .black,
    surface_input: dvui.Color = .black,
    border: dvui.Color = .gray,

    text: dvui.Color = .white,
    text_secondary: dvui.Color = .silver,

    accent: dvui.Color = .teal,
    accent_hover: dvui.Color = .aqua,
    press: dvui.Color = .gray,
    hover: dvui.Color = .gray,

    blue: dvui.Color = .blue,
    green: dvui.Color = .green,
    orange: dvui.Color = .olive,
    yellow: dvui.Color = .yellow,
    red: dvui.Color = .red,
    purple: dvui.Color = .purple,
};

var palette: Palette = .{};

pub fn get() Palette {
    return palette;
}

// === Semantic colours ===
//
// Three text levels only. More than that and nothing reads as emphasised.

pub fn text() dvui.Color {
    return palette.text;
}

/// Secondary information: units, counts, hints, inactive labels.
pub fn textMuted() dvui.Color {
    return palette.text_secondary;
}

/// Barely-there text: placeholders, disabled rows, empty states.
pub fn textFaint() dvui.Color {
    return palette.text_secondary.lerp(palette.background, 0.45);
}

/// Text drawn on top of an accent or status fill.
pub fn textOnAccent() dvui.Color {
    return if (palette.dark) palette.background else dvui.Color.white;
}

pub fn accent() dvui.Color {
    return palette.accent;
}

pub fn accentHover() dvui.Color {
    return palette.accent_hover;
}

/// App background, behind everything.
pub fn background() dvui.Color {
    return palette.background;
}

/// Raised container: side panel, cards.
pub fn surface() dvui.Color {
    return palette.surface;
}

/// Recessed container: text inputs.
/// Not `surface_input`, which is also what a raised card is: a field on a
/// card would vanish into it. The app's ground either way: white on light,
/// the darker step on dark.
pub fn surfaceInput() dvui.Color {
    return palette.background;
}

/// Background for a hovered row.
pub fn rowHover() dvui.Color {
    return palette.hover;
}

/// Background for a selected row.
pub fn rowSelected() dvui.Color {
    return palette.accent.lerp(palette.background, if (palette.dark) 0.86 else 0.88);
}

/// The accent at a tenth of its strength: the ground under a tag, a pill or a
/// selected tab. `--accent-dim` in the mockup.
pub fn accentDim() dvui.Color {
    return palette.accent.lerp(palette.surface, if (palette.dark) 0.86 else 0.88);
}

/// Any hue at the same strength, for the tags that are not the accent.
pub fn tint(hue: dvui.Color) dvui.Color {
    return hue.lerp(palette.surface, if (palette.dark) 0.86 else 0.88);
}

/// One step above the panel: the raised ground the mockup puts under the
/// compose box, a badge or a segmented control.
pub fn surfaceRaised() dvui.Color {
    return palette.surface_input;
}

pub fn border() dvui.Color {
    return palette.border;
}

/// Hairline used between structural regions, quieter than `border`.
pub fn borderSubtle() dvui.Color {
    return palette.border.lerp(palette.background, 0.45);
}

pub fn danger() dvui.Color {
    return palette.red;
}

pub fn success() dvui.Color {
    return palette.green;
}

// === Git-specific colours ===

/// The miniature of a theme on its card in the settings: fixed, not read from
/// the palette, because both cards show at once and only one theme is loaded.
pub fn themePreview(dark: bool) struct { background: dvui.Color, panel: dvui.Color, line: dvui.Color } {
    return if (dark) .{
        .background = .{ .r = 0x1c, .g = 0x1b, .b = 0x24 },
        .panel = .{ .r = 0x24, .g = 0x23, .b = 0x2e },
        .line = .{ .r = 0x3c, .g = 0x3a, .b = 0x4a },
    } else .{
        .background = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .panel = .{ .r = 0xf3, .g = 0xf2, .b = 0xf8 },
        .line = .{ .r = 0xd6, .g = 0xd2, .b = 0xe2 },
    };
}

/// A lane's colour faint enough to lie under text: the band that joins a
/// commit's node to its message, and — stronger — the selected row, so the
/// selection says which branch it is on.
pub fn laneWash(hue: dvui.Color, selected: bool) dvui.Color {
    const keep: f32 = if (selected)
        (if (palette.dark) 0.72 else 0.80)
    else
        (if (palette.dark) 0.88 else 0.92);
    return hue.lerp(palette.background, keep);
}

/// Colour of a graph lane, by lane index.
///
/// Lanes are identified by hue alone, so the ramp is picked for separability at
/// 2px stroke width rather than for prettiness, and it wraps: past `len` two
/// lanes share a colour, which is fine because they are never adjacent in
/// practice on a real history.
pub fn laneColor(index: usize) dvui.Color {
    const p = palette;
    const ramp = [_]dvui.Color{ p.green, p.blue, p.purple, p.orange, p.red, p.yellow };
    const c = ramp[index % ramp.len];
    // Lanes are thin lines on a dark ground: nudge toward text so a saturated
    // hue does not disappear the way raw blue does.
    return c.lerp(p.text, if (p.dark) 0.10 else 0.20);
}

pub fn fileStatusColor(status: git.Status) dvui.Color {
    const p = palette;
    return switch (status) {
        .added => p.green,
        .modified => p.orange,
        .deleted => p.red,
        .renamed => p.blue,
        .conflicted => p.purple,
        .unchanged => textFaint(),
    };
}

/// Diff line colouring: a tint for the row fill, the palette hue for the text.
pub fn diffAddedFill() dvui.Color {
    return palette.green.lerp(palette.background, 0.86);
}

pub fn diffRemovedFill() dvui.Color {
    return palette.red.lerp(palette.background, 0.86);
}

// === Applying a theme ===

fn toColor(rgba: [4]f32) dvui.Color {
    return .{
        .r = floatToByte(rgba[0]),
        .g = floatToByte(rgba[1]),
        .b = floatToByte(rgba[2]),
        .a = floatToByte(rgba[3]),
    };
}

fn floatToByte(x: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0.0, 1.0) * 255.0));
}

fn pick(v: ?ColorValue, fallback: dvui.Color) dvui.Color {
    const c = v orelse return fallback;
    return toColor(c.value);
}

/// The palette, compiled in.
///
/// `src/theme/*.json` stays the one place colours are authored; embedding
/// only removes the runtime read, and with it every "theme file not found next
/// to the executable" failure mode. The day Zit grows user themes, this is
/// where a file path comes back — as an override on top of these, not instead
/// of them, so a broken user theme cannot leave the app unstyled.
const theme_dark = @embedFile("theme/zit_dark.json");
const theme_light = @embedFile("theme/zit_light.json");

pub fn applyEmbedded(allocator: std.mem.Allocator, dark: bool) !void {
    const bytes = if (dark) theme_dark else theme_light;

    var parsed = try std.json.parseFromSlice(ThemeFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    apply(parsed.value, if (dark) "Zit Dark" else "Zit Light", dark);
}

pub fn apply(file: ThemeFile, theme_name: []const u8, dark: bool) void {
    const background_c = toColor(file.background.value);
    const foreground_c = toColor(file.foreground.value);
    const text_c = toColor(file.text.value);

    palette = .{
        .dark = dark,
        .background = background_c,
        .surface = foreground_c,
        .surface_input = pick(file.text_background, foreground_c),
        .border = pick(file.highlight_secondary, foreground_c),
        .text = text_c,
        .text_secondary = pick(file.text_secondary, text_c.lerp(background_c, 0.42)),
        .accent = pick(file.highlight_primary, foreground_c),
        .accent_hover = pick(file.hover_primary, pick(file.highlight_primary, foreground_c)),
        .press = pick(file.highlight_secondary, foreground_c),
        .hover = pick(file.hover_secondary, foreground_c),
        .blue = pick(file.text_blue, .blue),
        .green = pick(file.text_green, .green),
        .orange = pick(file.text_orange, .olive),
        .yellow = pick(file.text_yellow, .yellow),
        .red = pick(file.text_red, .red),
        .purple = pick(file.text_purple, .purple),
    };

    var theme = dvui.themeGet();

    theme.name = theme_name;
    theme.dark = dark;

    theme.font_body = body();
    theme.font_heading = bodyBold();
    theme.font_title = title();
    theme.font_mono = mono();
    theme.embedded_fonts = fonts;

    theme.fill = background_c;
    theme.border = palette.border;
    theme.text = text_c;
    theme.fill_hover = palette.hover;
    theme.fill_press = palette.press;
    theme.text_select = palette.accent.opacity(0.35);
    // No focus ring: a field shows it has the keyboard by its caret, and a
    // ring around every focused control read as a frame drawn by mistake.
    theme.focus = .transparent;

    theme.window.fill = background_c;
    theme.window.fill_hover = palette.hover;
    theme.window.fill_press = palette.press;
    theme.window.text = text_c;
    theme.window.border = palette.border;

    theme.control.fill = surfaceInput();
    theme.control.fill_hover = palette.hover;
    theme.control.fill_press = palette.press;
    theme.control.text = text_c;
    theme.control.text_press = text_c;
    theme.control.border = palette.border;

    theme.highlight.fill = palette.accent;
    theme.highlight.fill_hover = palette.accent_hover;
    theme.highlight.fill_press = palette.accent;
    theme.highlight.border = palette.accent;
    theme.highlight.text = textOnAccent();

    theme.err.fill = palette.red;
    theme.err.fill_hover = palette.red.lighten(if (dark) 10 else -10);
    theme.err.fill_press = palette.red.lighten(if (dark) 20 else -20);
    theme.err.border = palette.red;
    theme.err.text = textOnAccent();

    dvui.themeSet(theme);
}

test "palette resolves optional keys instead of dropping them" {
    const file: ThemeFile = .{
        .background = .{ .value = .{ 0, 0, 0, 1 } },
        .foreground = .{ .value = .{ 0.2, 0.2, 0.2, 1 } },
        .text = .{ .value = .{ 1, 1, 1, 1 } },
        .text_secondary = .{ .value = .{ 0.6, 0.6, 0.6, 1 } },
        .text_red = .{ .value = .{ 1, 0, 0, 1 } },
    };

    // `apply` talks to the dvui window, so exercise only the palette half.
    const background_c = toColor(file.background.value);
    const text_c = toColor(file.text.value);
    const secondary = pick(file.text_secondary, text_c.lerp(background_c, 0.42));

    try std.testing.expectEqual(@as(u8, 153), secondary.r);
    try std.testing.expectEqual(@as(u8, 255), pick(file.text_red, .black).r);

    // A missing key derives from text/background rather than reading as black.
    const no_secondary = pick(null, text_c.lerp(background_c, 0.42));
    try std.testing.expect(no_secondary.r > 100 and no_secondary.r < 200);
}

test "lanes and file statuses stay distinguishable" {
    palette = .{
        .dark = true,
        .text = .white,
        .background = .black,
        .green = .{ .r = 46, .g = 204, .b = 113 },
        .orange = .{ .r = 243, .g = 156, .b = 18 },
        .blue = .{ .r = 52, .g = 152, .b = 219 },
        .purple = .{ .r = 155, .g = 89, .b = 182 },
        .red = .{ .r = 231, .g = 76, .b = 60 },
        .yellow = .{ .r = 241, .g = 196, .b = 15 },
        .text_secondary = .silver,
    };

    // Adjacent lanes must not collide, and the ramp wraps rather than panicking
    // on a deep history.
    try std.testing.expect(laneColor(0).g != laneColor(1).g);
    try std.testing.expectEqual(laneColor(0).r, laneColor(6).r);
    try std.testing.expectEqual(laneColor(1).b, laneColor(13).b);

    try std.testing.expect(fileStatusColor(.added).g != fileStatusColor(.deleted).g);
    try std.testing.expectEqualStrings("+", git.Status.added.glyph());
}
