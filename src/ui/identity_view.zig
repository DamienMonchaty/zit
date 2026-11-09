const std = @import("std");
const dvui = @import("dvui");
const style = @import("style.zig");
const git = @import("../git/git.zig");
const graph = @import("../git/graph.zig");
const run = @import("../core/run.zig");
const github = @import("../github/github.zig");
const tab_strip = @import("tab_strip.zig");
const window_chrome = @import("window_chrome.zig");
const graph_view = @import("graph_view.zig");
const search_view = @import("search_view.zig");
const rebase_view = @import("rebase_view.zig");
const dialog_views = @import("dialog_views.zig");
const repo_settings = @import("repo_settings.zig");
const github_actions = @import("../github/github_actions.zig");
const github_connect = @import("../github/github_connect.zig");
const app = @import("../main.zig");

// === Git identity ===
//
// The name and email every commit is signed with, which git refuses to commit
// without. Typed in, or taken from the GitHub account Zit is connected as —
// connecting it on the way if need be.

pub var identity_open: bool = false;
var identity_rect: dvui.Rect = .{};
pub var identity_name: std.ArrayList(u8) = .empty;
pub var identity_email: std.ArrayList(u8) = .empty;
pub var identity_note: []const u8 = "";

/// git's global `user.name` and `user.email`, into `name` and `email`, by one
/// `git` rather than one each: on Windows starting it is most of the wait.
/// Through `git`, not libgit2, which would not see the global config a test
/// hands over in `run.env_override`. True when both are set.
pub fn readIdentity(name: *std.ArrayList(u8), email: *std.ArrayList(u8)) bool {
    name.clearRetainingCapacity();
    email.clearRetainingCapacity();
    const answer = run.capture(app.gpa, app.app_io, ".", &.{ "git", "config", "--global", "--get-regexp", "^user\\.(name|email)$" }) catch return false;
    defer app.gpa.free(answer.out);
    if (!answer.ok) return false;
    var lines = std.mem.splitScalar(u8, answer.out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const out = if (std.mem.eql(u8, line[0..space], "user.name")) name else if (std.mem.eql(u8, line[0..space], "user.email")) email else continue;
        // Said twice, the last one holds.
        out.clearRetainingCapacity();
        out.appendSlice(app.gpa, std.mem.trim(u8, line[space + 1 ..], " ")) catch return false;
    }
    return name.items.len > 0 and email.items.len > 0;
}

pub fn identitySet() bool {
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(app.gpa);
    var email: std.ArrayList(u8) = .empty;
    defer email.deinit(app.gpa);
    return readIdentity(&name, &email);
}

pub fn openIdentity() void {
    identity_open = true;
    identity_rect = .{};
    identity_note = "";
    _ = readIdentity(&identity_name, &identity_email);
}

/// Fill the fields from the signed-in GitHub account. The noreply address
/// where the account keeps its email private: commits still link to it.
/// A request to GitHub, on this thread: a click's worth of wait.
pub fn fillFromGithub() bool {
    if (!github.signedIn()) return false;
    const got = github.call("GET", "/user", null) catch return false;
    defer got.deinit();
    const answer = got.answer();
    if (!answer.ok()) return false;
    var a: std.heap.ArenaAllocator = .init(app.gpa);
    defer a.deinit();
    const user = std.json.parseFromSliceLeaky(struct {
        login: []const u8 = "",
        id: u64 = 0,
        name: ?[]const u8 = null,
        email: ?[]const u8 = null,
    }, a.allocator(), answer.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return false;
    if (user.login.len == 0) return false;

    identity_name.clearRetainingCapacity();
    identity_name.appendSlice(app.gpa, user.name orelse user.login) catch {};
    identity_email.clearRetainingCapacity();
    if (user.email) |email| {
        identity_email.appendSlice(app.gpa, email) catch {};
    } else {
        identity_email.print(app.gpa, "{d}+{s}@users.noreply.github.com", .{ user.id, user.login }) catch {};
    }
    return true;
}

pub fn signInWithGithub() void {
    if (fillFromGithub()) {
        identity_note = "Filled in from your GitHub account.";
        return;
    }
    // Not signed in: Zit's own sign-in, and the fields filled once it lands.
    github_connect.connect_fills_identity = true;
    github_connect.openConnect();
}

pub fn saveIdentity() void {
    const name = std.mem.trim(u8, identity_name.items, " ");
    const email = std.mem.trim(u8, identity_email.items, " ");
    if (name.len == 0 or email.len == 0) {
        identity_note = "Both a name and an email are needed.";
        return;
    }
    for ([_][2][]const u8{ .{ "user.name", name }, .{ "user.email", email } }) |kv| {
        var outcome = run.git(app.gpa, app.app_io, ".", &.{ "config", "--global", kv[0], kv[1] }) catch {
            identity_note = "Could not run git. Is it installed?";
            return;
        };
        defer outcome.deinit(app.gpa);
        if (!outcome.ok) {
            identity_note = "git would not save it.";
            return;
        }
    }
    identity_open = false;
    window_chrome.me_loaded = false;
}

pub fn identityDialog() void {
    if (!identity_open) return;

    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &identity_rect, &identity_open, style.surface(), 480, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);

    dialogHeader(@src(), dvui.entypo.user, "Who are you, to git?", "Every commit carries a name and an email. Set once, for every repository", &identity_open);

    var body = dialogBody(@src(), null);

    {
        var gh_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.lg } });
        defer gh_row.deinit();
        const busy = github_connect.connect_open;
        if (dialog_views.dialogButton(@src(), if (busy) "Waiting for GitHub…" else "Sign in with GitHub", true) and !busy) signInWithGithub();
        dvui.label(@src(), "or type them in", .{}, .{
            .font = style.small(),
            .color_text = .{ .color = style.textFaint() },
            .gravity_y = 0.5,
            .margin = .{ .x = style.space.md },
            .padding = dvui.Rect.all(0),
        });
    }

    var entered = false;
    _ = dialog_views.dialogField(@src(), 10, "Name", &identity_name, "Ada Lovelace", identity_name.items.len == 0, &entered);
    _ = dialog_views.dialogField(@src(), 11, "Email", &identity_email, "ada@example.com", false, &entered);

    if (identity_note.len > 0) {
        dvui.label(@src(), "{s}", .{identity_note}, .{
            .font = style.small(),
            .color_text = .{ .color = style.accent() },
            .margin = .{ .h = style.space.lg },
            .padding = dvui.Rect.all(0),
        });
    }

    body.deinit();
    {
        var foot = dialogFooter(@src());
        defer foot.deinit();
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (dialog_views.dialogButton(@src(), "Later", false)) identity_open = false;
        if (dialog_views.dialogButton(@src(), "Save", true) or entered) saveIdentity();
    }

    if (dialog_views.escapePressed()) identity_open = false;
}

pub fn openSettings(section: usize) void {
    settings_open = true;
    settings_rect = .{};
    signing_loaded = false;
    repo_settings.repo_prefs_loaded = false;
    repo_settings.editors_loaded = false;
    // The repository whose settings show: the one open, to start with.
    if (app.repo != null) {
        repo_settings.repo_settings_path.clearRetainingCapacity();
        repo_settings.repo_settings_path.appendSlice(app.gpa, app.repo_path.items) catch {};
    }
    settings_page = section;
}

/// The settings, in one dialog: the sections down the left, grouped by what
/// they are about — Zit itself, then the commits made from it — and the one
/// picked on the right. Everything is saved as it is changed.
pub var settings_open = false;
var settings_rect: dvui.Rect = .{};
/// The section shown, by id.
pub var settings_page: usize = 5;

const SettingsPage = struct { id: usize, icon: []const u8, title: []const u8, hint: []const u8 };
/// In the order the list shows them; a null is the next group's caption.
const settings_pages = [_]?SettingsPage{
    null,
    .{ .id = 5, .icon = dvui.entypo.cog, .title = "General", .hint = "Tabs, new repositories, fetching" },
    .{ .id = 3, .icon = dvui.entypo.merge, .title = "Integrations", .hint = "GitHub: pull requests, issues, checks and the account" },
    .{ .id = 0, .icon = dvui.entypo.palette, .title = "Appearance", .hint = "The theme, the size of the text, the pictures" },
    null,
    .{ .id = 1, .icon = dvui.entypo.user, .title = "Git identity", .hint = "The name and email your commits carry" },
    .{ .id = 2, .icon = dvui.entypo.pencil, .title = "Commit messages", .hint = "Ticket, conventional commits, template" },
    .{ .id = 6, .icon = dvui.entypo.lock, .title = "Commit signing", .hint = "GPG or SSH, for commits and tags" },
    null,
    .{ .id = REPO_PAGE, .icon = dvui.entypo.folder, .title = "Repositories", .hint = "Its own identity, pull and signing — in its .git/config" },
};
const settings_groups = [_][]const u8{ "Zit", "Commits", "Repositories" };
/// The page of one repository's settings, which it the nav lists by name.
pub const REPO_PAGE = 7;

pub fn settingsDialog() void {
    if (!settings_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &settings_rect, &settings_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);

    dialogHeader(@src(), dvui.entypo.cog, "Settings", "Zit " ++ app.APP_VERSION ++ " · everything is saved as you change it", &settings_open);

    // One size whichever section shows, so the dialog does not jump.
    const w: f32 = @min(860, win.w - 80);
    const h: f32 = @max(240, @min(520, win.h - 240));
    {
        var split = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = w, .h = h },
            .max_size_content = .size(.{ .w = w, .h = h }),
            .background = false,
        });
        defer split.deinit();
        settingsNav();
        // Its ground the dialog's: dvui's scroll container paints its own,
        // the window's darker one, under whatever it holds.
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .color_fill = .{ .color = style.surface() } });
        defer scroll.deinit();
        // On the dialog's ground, over the scroll container's darker one.
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.xl, .h = style.space.xl },
        });
        defer body.deinit();

        if (SettingsCard.begin(5)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();

            var changed = repo_settings.settingsSwitch(0, &tab_strip.remember_tabs, "Reopen your tabs", "Start where you left off, rather than on the start page");

            settingsField(@src(), "Default branch", "The first branch of a repository made here");
            const branch = dialog_views.textField(@src(), .{
                .text = .{ .array_list = .{ .backing = &tab_strip.default_branch, .allocator = app.gpa, .limit = 128 } },
                .placeholder = "main",
            }, settingsInput().override(.{
                .tag = "default_branch",
            }));
            if (branch.text_changed) changed = true;
            branch.deinit();

            settingsField(@src(), "External editor", "What a file from a diff opens with");
            if (repo_settings.editorChoice()) changed = true;

            settingsField(@src(), "Terminal", "What Terminal opens, in the repository's folder");
            if (repo_settings.terminalChoice()) changed = true;

            settingsField(@src(), "Fetch in the background", "Every remote, quietly — the counts on Pull and Push stay true");
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
                defer row.deinit();
                for ([_]u32{ 0, 5, 10, 30 }, 0..) |minutes, i| {
                    var buf: [16]u8 = undefined;
                    const caption = if (minutes == 0) "Never" else std.fmt.bufPrint(&buf, "every {d} min", .{minutes}) catch "?";
                    var chip = dvui.box(@src(), .{}, .{ .id_extra = i, .background = false });
                    defer chip.deinit();
                    if (dialog_views.chipButton(@src(), if (tab_strip.auto_fetch_minutes == minutes) dvui.entypo.check else dvui.entypo.clock, caption, tab_strip.auto_fetch_minutes == minutes)) {
                        tab_strip.auto_fetch_minutes = minutes;
                        changed = true;
                    }
                }
            }
            changed = repo_settings.settingsSwitch(1, &tab_strip.prune_on_fetch, "Prune when fetching", "Drop the remote branches deleted on the remote") or changed;

            if (changed) tab_strip.saveWorkspace();
        }
        if (SettingsCard.begin(3)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();
            var on = tab_strip.integrations;
            if (repo_settings.settingsSwitch(0, &on, "Use GitHub", "Pull requests, issues, checks and the account. Off: none of it, and nothing asked of GitHub")) tab_strip.setIntegrations(on);
            // Who Zit is connected as, and the way in or out.
            if (tab_strip.integrations) {
                window_chrome.loadMe();
                settingsField(@src(), "Account", "A code typed on github.com — the token it gives is kept readable by you alone");
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = style.surface() },
                    .border = dvui.Rect.all(1),
                    .color_border = .{ .color = style.border() },
                    .corners = style.radius.row,
                    .padding = dvui.Rect.all(style.space.md),
                });
                defer row.deinit();
                dvui.icon(@src(), "gh_state", if (window_chrome.me_gh.items.len > 0) dvui.entypo.check else dvui.entypo.login, .{ .fill_color = .{ .color = if (window_chrome.me_gh.items.len > 0) style.success() else style.textFaint() } }, .{
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = style.space.md },
                });
                if (window_chrome.me_gh.items.len > 0)
                    dvui.label(@src(), "Connected as {s}", .{window_chrome.me_gh.items}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) })
                else
                    dvui.label(@src(), "Not connected", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textMuted() }, .gravity_y = 0.5, .expand = .horizontal, .padding = dvui.Rect.all(0) });
                if (window_chrome.me_gh.items.len > 0) {
                    if (dialog_views.dialogButton(@src(), "Disconnect", false)) github_actions.ask(.sign_out, window_chrome.me_gh.items);
                } else if (dialog_views.dialogButton(@src(), "Connect GitHub", true)) github_connect.openConnect();
            }
        }
        if (SettingsCard.begin(0)) |card| {
            defer card.end();
            // Three a row: Zit's own, then Catppuccin's.
            for (0..(style.themes.len + 2) / 3) |r| {
                var cards = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                    .id_extra = r,
                    .expand = .horizontal,
                    .background = false,
                    .padding = settings_body_pad,
                });
                defer cards.deinit();
                for (r * 3..@min(r * 3 + 3, style.themes.len)) |i| {
                    if (repo_settings.themeCard(@src(), i) and i != app.theme_index) pickTheme(i);
                }
            }
            {
                var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = settings_body_pad });
                defer section.deinit();
                settingsField(@src(), "Text size", "The app's words, apart from the zoom");
                const ui_steps = [_]f32{ 0.9, 1, 1.08, 1.16 };
                if (repo_settings.choiceChips(10, &.{ "Small", "Default", "Large", "Larger" }, repo_settings.nearestStep(&ui_steps, style.ui_scale))) |i| {
                    style.ui_scale = ui_steps[i];
                    tab_strip.saveWorkspace();
                }
                settingsField(@src(), "Editor text size", "The code of a diff or a blame");
                const code_steps = [_]f32{ 10.0 / 11.0, 1, 12.0 / 11.0, 13.0 / 11.0, 14.0 / 11.0 };
                if (repo_settings.choiceChips(11, &.{ "10", "11", "12", "13", "14" }, repo_settings.nearestStep(&code_steps, style.code_scale))) |i| {
                    style.code_scale = code_steps[i];
                    tab_strip.saveWorkspace();
                }
            }
            {
                var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .padding = settings_body_pad });
                defer section.deinit();
                if (repo_settings.settingsSwitch(0, &tab_strip.show_avatars, "Pictures in the graph", "Each commit its author's picture. Off: a dot")) tab_strip.saveWorkspace();
            }
        }
        if (SettingsCard.begin(REPO_PAGE)) |card| {
            defer card.end();
            repo_settings.repoSettings();
        }
        if (SettingsCard.begin(1)) |card| {
            defer card.end();
            window_chrome.loadMe();
            const me = window_chrome.meAsCommit();
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer row.deinit();
            search_view.avatarSized(@src(), 0, me, null, null, 32);
            {
                var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.xs } });
                defer col.deinit();
                const set = window_chrome.me_name.items.len > 0 and window_chrome.me_email.items.len > 0;
                dvui.label(@src(), "{s}", .{if (set) me.author else "Not set yet"}, .{ .font = style.smallBold(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
                dvui.label(@src(), "{s}", .{if (set) me.email else "Commits need a name and an email"}, .{ .font = style.tiny(), .color_text = .{ .color = style.textMuted() }, .padding = dvui.Rect.all(0) });
                dvui.label(@src(), "For every repository, in git's global config", .{}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2 } });
            }
            if (dialog_views.dialogButton(@src(), "Edit…", false)) openIdentity();
        }
        if (SettingsCard.begin(2)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();

            var changed = false;
            changed = repo_settings.settingsSwitch(0, &app.commit_prefs.ticket, "Ticket from the branch", "PROJ-80-Back-Login puts PROJ-80 in the message") or changed;
            if (app.commit_prefs.ticket) {
                changed = repo_settings.settingsSwitch(1, &app.commit_prefs.ticket_footer, "Ticket as a trailer", "Refs: PROJ-80 at the end, rather than at the head of the summary") or changed;
            }
            changed = repo_settings.settingsSwitch(2, &app.commit_prefs.conventional, "Conventional commits", "A type and a scope before the summary: feat(api): …") or changed;
            changed = repo_settings.settingsSwitch(3, &app.commit_prefs.wrap_body, "Wrap the description", "Long lines broken at 72 columns, as git log expects") or changed;
            changed = repo_settings.settingsSwitch(4, &app.commit_prefs.signoff, "Sign off", "A Signed-off-by line on every commit") or changed;

            dvui.label(@src(), "Template", .{}, .{
                .font = style.small(),
                .color_text = .{ .color = style.text() },
                .margin = .{ .y = style.space.md },
                .padding = dvui.Rect.all(0),
            });
            dvui.label(@src(), "Used when git's commit.template names none. The first line is the summary.", .{}, .{
                .font = style.tiny(),
                .color_text = .{ .color = style.textFaint() },
                .margin = .{ .h = style.space.sm },
                .padding = dvui.Rect.all(0),
            });
            const te = dialog_views.textField(@src(), .{
                .text = .{ .array_list = .{ .backing = &app.commit_template, .allocator = app.gpa, .limit = 4096 } },
                .multiline = true,
                .break_lines = true,
                .placeholder = "e.g. a summary line, then the sections every description should have",
            }, settingsInput().override(.{
                .tag = "commit_template",
                .min_size_content = .{ .h = 72 },
            }));
            if (te.text_changed) changed = true;
            te.deinit();

            if (changed) tab_strip.saveWorkspace();
        }
        if (SettingsCard.begin(6)) |card| {
            defer card.end();
            var section = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .padding = settings_body_pad,
            });
            defer section.deinit();
            loadSigning();

            // Whether anything can sign at all, before the switches that ask it to.
            {
                const loading = !signing_loaded;
                const ready = signing_key.items.len > 0;
                var note = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = if (loading) style.surfaceRaised() else if (ready) style.success().lerp(style.background(), 0.88) else style.get().orange.lerp(style.background(), 0.86) },
                    .corners = style.radius.input,
                    .padding = dvui.Rect.all(style.space.md),
                    .margin = .{ .h = style.space.md },
                });
                defer note.deinit();
                dvui.icon(@src(), "sign_state", if (loading) dvui.entypo.cycle else if (ready) dvui.entypo.check else dvui.entypo.warning, .{ .fill_color = .{ .color = if (loading) style.textMuted() else if (ready) style.success() else style.get().orange } }, .{
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = style.space.md },
                });
                dvui.label(@src(), "{s}", .{if (loading) "Reading git's configuration…" else if (ready) "A signing key is set: commits and tags can be signed." else "No signing key set yet: git cannot sign until one is."}, .{
                    .font = style.small(),
                    .color_text = .{ .color = style.text() },
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                });
            }

            var changed = repo_settings.settingsSwitch(0, &app.commit_prefs.sign, "Sign every commit", "-S on each commit made here; git's own commit.gpgsign signs the rest");
            changed = repo_settings.settingsSwitch(1, &app.commit_prefs.sign_tags, "Sign tags", "The tags made here are annotated and signed") or changed;
            if (changed) tab_strip.saveWorkspace();

            settingsField(@src(), "Format", "Saved in git's global config, gpg.format");
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .background = false });
                defer row.deinit();
                for ([_]struct { []const u8, []const u8 }{ .{ "GPG", "openpgp" }, .{ "SSH", "ssh" } }, 0..) |format, i| {
                    var chip = dvui.box(@src(), .{}, .{ .id_extra = i, .background = false });
                    defer chip.deinit();
                    const on = std.mem.eql(u8, signing_format, format[1]);
                    if (dialog_views.chipButton(@src(), if (on) dvui.entypo.check else dvui.entypo.lock, format[0], on)) repo_settings.setGlobalConfig("gpg.format", format[1]);
                }
            }

            settingsField(@src(), "Signing key", "A GPG key id, or the path to an SSH public key — user.signingkey");
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
                defer row.deinit();
                const key = dialog_views.textField(@src(), .{
                    .text = .{ .array_list = .{ .backing = &signing_key, .allocator = app.gpa, .limit = 512 } },
                    .placeholder = if (std.mem.eql(u8, signing_format, "ssh")) "~/.ssh/id_ed25519.pub" else "e.g. 3AA5C34371567BD2",
                }, settingsInput().override(.{
                    .tag = "signing_key",
                    .margin = .{ .w = style.space.sm },
                }));
                key.deinit();
                if (dialog_views.dialogButton(@src(), "Save", true)) repo_settings.setGlobalConfig("user.signingkey", std.mem.trim(u8, signing_key.items, " "));
            }
        }
    }

    if (dialog_views.escapePressed()) settings_open = false;
}

/// Every key Zit answers to, from the footer's keyboard button.
pub var keys_open = false;
pub var keys_rect: dvui.Rect = .{};

pub fn keysDialog() void {
    if (!keys_open) return;
    const win = dvui.windowRect();
    var fw = dialog_views.modalWindow(@src(), &keys_rect, &keys_open, style.surface(), 0, dvui.Rect.all(0));
    defer fw.deinit();
    dialog_views.centerModal(fw.data(), win, null);

    dialogHeader(@src(), dvui.entypo.keyboard, "Keyboard shortcuts", "Everything here is a key away", &keys_open);
    // No taller than most of the window: the list scrolls under its head.
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .min_size_content = .{ .w = 520 + 2 * style.space.xl, .h = @min(560, win.h * 0.7) },
        .max_size_content = .height(@min(560, win.h * 0.7)),
        .background = false,
        .color_fill = .{ .color = style.surface() },
    });
    defer scroll.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 520 },
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .padding = .{ .x = style.space.xl, .y = style.space.xs, .w = style.space.xl, .h = style.space.xl },
    });
    defer body.deinit();
    settingsGroup(@src(), 0, "Anywhere");
    {
        var card = shortcutCard(@src(), 0);
        defer card.deinit();
        repo_settings.shortcutRow(@src(), "Ctrl+P", "Command palette: any action, branch or repo");
        repo_settings.shortcutRow(@src(), "Ctrl+T", "New tab: open, clone or create");
        repo_settings.shortcutRow(@src(), "Ctrl+O", "Open a folder");
        repo_settings.shortcutRow(@src(), "Ctrl+W", "Close this tab");
        repo_settings.shortcutRow(@src(), "Ctrl+Tab, Ctrl+PgDn", "Next tab (Shift+Tab, PgUp: previous)");
        repo_settings.shortcutRow(@src(), "Ctrl+,", "Settings");
        repo_settings.shortcutRow(@src(), "Ctrl+Shift+T", "A terminal in this repository's folder");
        repo_settings.shortcutRow(@src(), "F5", "Refresh");
    }
    settingsGroup(@src(), 0, "History");
    {
        var card = shortcutCard(@src(), 1);
        defer card.deinit();
        repo_settings.shortcutRow(@src(), "↑ ↓", "Previous / next commit");
        repo_settings.shortcutRow(@src(), "Ctrl+F", "Search the commits");
        repo_settings.shortcutRow(@src(), "Ctrl+Z", "Undo the last commit, checkout, merge…");
        repo_settings.shortcutRow(@src(), "Ctrl+Shift+Z, Ctrl+Y", "Redo what was just undone");
        repo_settings.shortcutRow(@src(), "Esc", "Back to the graph, or cancel the bar");
    }
    settingsGroup(@src(), 0, "Changes");
    {
        var card = shortcutCard(@src(), 2);
        defer card.deinit();
        repo_settings.shortcutRow(@src(), "Ctrl+Enter", "Commit what is staged");
        repo_settings.shortcutRow(@src(), "Ctrl+Enter", "Continue a merge or rebase, its conflicts resolved");
    }
    settingsGroup(@src(), 0, "Conflicts");
    {
        var card = shortcutCard(@src(), 5);
        defer card.deinit();
        repo_settings.shortcutRow(@src(), "↑ ↓, F2 F3", "Previous / next conflict in the file");
        repo_settings.shortcutRow(@src(), "1, 2, 3", "Keep the left side, the right one, or both");
        repo_settings.shortcutRow(@src(), "U, Ctrl+Z", "Take the last pick back");
        repo_settings.shortcutRow(@src(), "Enter", "Stage a resolved file and open the next");
        repo_settings.shortcutRow(@src(), "F4", "Next conflicted file");
    }
    settingsGroup(@src(), 0, "Pull requests");
    {
        var card = shortcutCard(@src(), 6);
        defer card.deinit();
        repo_settings.shortcutRow(@src(), "↑ ↓, K J", "Previous / next request in the list");
        repo_settings.shortcutRow(@src(), "1, 2, 3, 4", "Conversation, commits, files, checks");
        repo_settings.shortcutRow(@src(), "Ctrl+F", "Search the requests");
        repo_settings.shortcutRow(@src(), "Ctrl+Enter", "Send what is in the review box, as a comment");
    }
    settingsGroup(@src(), 0, "Panels");
    {
        var card = shortcutCard(@src(), 3);
        defer card.deinit();
        repo_settings.shortcutRow(@src(), "Ctrl+B", "Show or hide the branches panel");
        repo_settings.shortcutRow(@src(), "Ctrl+J", "Show or hide the changes panel");
        repo_settings.shortcutRow(@src(), "Ctrl+Shift+PgUp/PgDn", "Move this tab left / right");
        repo_settings.shortcutRow(@src(), "Ctrl+Plus, Ctrl+Minus", "Zoom in / out, from 70 to 200 %");
        repo_settings.shortcutRow(@src(), "Ctrl+0", "Back to 100 %");
    }

    if (dialog_views.escapePressed()) keys_open = false;
}

/// The card a run of shortcuts sits on.
fn shortcutCard(src: std.builtin.SourceLocation, id: usize) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.row,
        .padding = .{ .x = style.space.md, .y = style.space.xs, .w = style.space.md, .h = style.space.xs },
    });
}

/// Light or dark, from a key or a menu: Zit's own of either.
pub fn setTheme(dark: bool) void {
    pickTheme(if (dark) 0 else 1);
}

fn pickTheme(index: usize) void {
    app.theme_index = index;
    app.applyTheme();
    tab_strip.saveWorkspace();
}

pub const settings_body_pad: dvui.Rect = .{ .x = 0, .y = style.space.xs, .w = 0, .h = style.space.sm };

/// A dialog's head: its icon on a tile, its title and a line under it, and
/// the × that closes it.
pub fn dialogHeader(src: std.builtin.SourceLocation, icon: []const u8, title: []const u8, hint: []const u8, open: *bool) void {
    // The dialog's own ground, said outright: dvui fills a box with a border
    // on one side in the theme's darker colour unless told.
    var head = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .h = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.lg, .h = style.space.lg },
    });
    defer head.deinit();
    iconTile(@src(), icon, 40, 18);
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.md } });
        defer col.deinit();
        dvui.label(@src(), "{s}", .{title}, .{ .font = style.title(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
        dvui.label(@src(), "{s}", .{hint}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2 } });
    }
    if (dialog_views.iconButton(@src(), "dialog_close", "Close — Esc", dvui.entypo.cross, style.textMuted())) open.* = false;
}

/// A dialog's body, under its header: every dialog's padding, `width` wide
/// when it is not null.
pub fn dialogBody(src: std.builtin.SourceLocation, width: ?f32) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .min_size_content = if (width) |w| .{ .w = w } else null,
        .max_size_content = if (width) |w| .width(w) else null,
        .background = false,
        .padding = dvui.Rect.all(style.space.xl),
    });
}

/// A dialog's foot: across the whole dialog under a rule. What goes on the
/// left first, then a spacer, then Cancel and the button that answers it.
pub fn dialogFooter(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .y = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.xl, .y = style.space.lg, .w = style.space.xl, .h = style.space.lg },
    });
}

/// The eye that shows or hides a ref in the graph: drawn here, an outline
/// with its pupil, and struck through for hidden — entypo's are a filled
/// blot at this size. Turned into TinyVG once, on first use.
pub fn eyeIcon(hidden: bool) []const u8 {
    const slot = if (hidden) &eye_tvg[1] else &eye_tvg[0];
    if (slot.*) |bytes| return bytes;
    // Kept for the whole run, so not from `gpa`: two small icons, never freed.
    const bytes = dvui.svgToTvg(std.heap.page_allocator, if (hidden) EYE_OFF_SVG else EYE_SVG) catch
        return if (hidden) dvui.entypo.eye_with_line else dvui.entypo.eye;
    slot.* = bytes;
    return bytes;
}
var eye_tvg: [2]?[]const u8 = .{ null, null };

const EYE_PATHS =
    \\<path fill-rule="evenodd" d="M12 5C6.5 5 2.7 8.6 1 12c1.7 3.4 5.5 7 11 7s9.3-3.6 11-7c-1.7-3.4-5.5-7-11-7zM12 7c-4.2 0-7.3 2.6-8.8 5 1.5 2.4 4.6 5 8.8 5s7.3-2.6 8.8-5c-1.5-2.4-4.6-5-8.8-5zM15 12C15 13.66 13.66 15 12 15C10.34 15 9 13.66 9 12C9 10.34 10.34 9 12 9C13.66 9 15 10.34 15 12z"/>
;
const EYE_SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\">" ++ EYE_PATHS ++ "</svg>";
const EYE_OFF_SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\">" ++ EYE_PATHS ++
    "<path d=\"M3.7 2.3L21.7 20.3L20.3 21.7L2.3 3.7Z\"/></svg>";

/// An icon on a rounded tile of the accent's tint.
pub fn iconTile(src: std.builtin.SourceLocation, icon: []const u8, side: f32, glyph: f32) void {
    var tile = dvui.box(src, .{}, .{
        .background = true,
        .color_fill = .{ .color = style.accentDim() },
        .corners = style.radius.row,
        .min_size_content = .{ .w = side, .h = side },
        .max_size_content = .size(.{ .w = side, .h = side }),
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
    defer tile.deinit();
    dvui.icon(@src(), "tile_icon", icon, .{ .fill_color = .{ .color = style.accent() } }, .{
        .min_size_content = .{ .w = glyph, .h = glyph },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
}

/// A settings text field: flush with the text over it, framed, roomy.
pub fn settingsInput() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = style.surfaceInput() },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = style.border() },
        .corners = style.radius.input,
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = style.space.md, .y = style.space.sm, .w = style.space.md, .h = style.space.sm },
        .font = style.small(),
    };
}

/// The small caps over a run of settings cards.
fn settingsGroup(src: std.builtin.SourceLocation, id: usize, title: []const u8) void {
    var buf: [32]u8 = undefined;
    const caps = std.ascii.upperString(&buf, title[0..@min(title.len, buf.len)]);
    dvui.label(src, "{s}", .{caps}, .{
        .id_extra = id,
        .font = style.section(),
        .color_text = .{ .color = style.textFaint() },
        .margin = .{ .x = style.space.xs, .y = style.space.lg, .h = style.space.sm },
        .padding = dvui.Rect.all(0),
    });
}

/// The sections, down the left: a group's caption, then its sections, the
/// one shown lit.
fn settingsNav() void {
    var nav = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 200 },
        .expand = .vertical,
        .background = true,
        .color_fill = .{ .color = style.surface() },
        .border = .{ .w = 1 },
        .color_border = .{ .color = style.border() },
        .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.sm, .h = style.space.sm },
    });
    defer nav.deinit();
    var group: usize = 0;
    for (settings_pages, 0..) |entry, i| {
        const page = entry orelse {
            settingsGroup(@src(), group, settings_groups[group]);
            group += 1;
            continue;
        };
        // The repositories' group: an entry for each, its badge for an icon.
        if (page.id == REPO_PAGE) {
            const known = repo_settings.knownRepos();
            if (known.len == 0) dvui.label(@src(), "None yet", .{}, .{ .font = style.small(), .color_text = .{ .color = style.textFaint() }, .padding = .{ .x = style.space.sm, .y = style.space.sm } });
            for (known, 0..) |path, r| {
                const on = settings_page == REPO_PAGE and std.mem.eql(u8, path, repo_settings.repo_settings_path.items);
                var rb: dvui.ButtonWidget = undefined;
                rb.init(@src(), .{ .draw_focus = false }, .{
                    .id_extra = 1000 + r,
                    .tag = dialog_views.frameTag("settings_repo", git.repoName(path)),
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = .{ .color = if (on) style.accentDim() else style.surface() },
                    .color_fill_hover = .{ .color = if (on) style.accentDim() else style.rowHover() },
                    .corners = style.radius.input,
                    .margin = .{ .h = 2 },
                    .padding = .{ .x = style.space.sm, .y = style.space.xs, .w = style.space.sm, .h = style.space.xs },
                });
                rb.processEvents();
                rb.drawBackground();
                {
                    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
                    defer row.deinit();
                    github_connect.tabBadge(git.repoName(path), on);
                    var fit: [rebase_view.MAX_SHOWN_LINE]u8 = undefined;
                    dvui.label(@src(), "{s}", .{graph_view.fitText(&fit, git.repoName(path), style.small(), 130)}, .{ .font = if (on) style.smallBold() else style.small(), .color_text = .{ .color = if (on) style.text() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
                }
                if (rb.hovered()) dvui.tooltip(@src(), .{ .active_rect = rb.data().borderRectScale().r, .position = .horizontal, .delay = 400_000 }, "{s}", .{path}, .{ .font = style.small() });
                if (rb.clicked()) {
                    settings_page = REPO_PAGE;
                    repo_settings.repo_settings_path.clearRetainingCapacity();
                    repo_settings.repo_settings_path.appendSlice(app.gpa, path) catch {};
                    repo_settings.repo_prefs_loaded = false;
                }
                rb.deinit();
            }
            continue;
        }
        const shown = settings_page == page.id;
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{ .draw_focus = false }, .{
            .id_extra = i,
            .tag = dialog_views.frameTag("settings", page.title),
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = if (shown) style.accentDim() else style.surface() },
            .color_fill_hover = .{ .color = if (shown) style.accentDim() else style.rowHover() },
            .corners = style.radius.input,
            .margin = .{ .h = 2 },
            .padding = .{ .x = style.space.sm, .y = style.space.sm, .w = style.space.sm, .h = style.space.sm },
        });
        bw.processEvents();
        bw.drawBackground();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false });
            defer row.deinit();
            dvui.icon(@src(), "page_icon", page.icon, .{ .fill_color = .{ .color = if (shown) style.accent() else style.textMuted() } }, .{
                .min_size_content = .{ .w = 14, .h = 14 },
                .gravity_y = 0.5,
                .margin = .{ .w = style.space.md },
            });
            dvui.label(@src(), "{s}", .{page.title}, .{ .font = if (shown) style.smallBold() else style.small(), .color_text = .{ .color = if (shown) style.text() else style.textMuted() }, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
        }
        if (bw.clicked()) {
            settings_page = page.id;
            signing_loaded = false;
            repo_settings.repo_prefs_loaded = false;
        }
        bw.deinit();
    }
}

/// One section of the settings, drawn only while it is the one picked: its
/// head — icon, title, what is in it — then whatever the caller fills in
/// before `end`.
const SettingsCard = struct {
    inner: *dvui.BoxWidget,

    fn begin(id: usize) ?SettingsCard {
        if (settings_page != id) return null;
        const page = for (settings_pages) |entry| {
            if (entry) |p| if (p.id == id) break p;
        } else return null;
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .margin = .{ .h = style.space.md } });
            defer row.deinit();
            iconTile(@src(), page.icon, 32, 16);
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .margin = .{ .x = style.space.md } });
            defer col.deinit();
            // A repository's page goes by its name, its folder under it.
            const one = id == REPO_PAGE and repo_settings.repo_settings_path.items.len > 0;
            dvui.label(@src(), "{s}", .{if (one) git.repoName(repo_settings.repo_settings_path.items) else page.title}, .{ .font = style.bodyBold(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
            dvui.label(@src(), "{s}", .{if (one) repo_settings.repo_settings_path.items else page.hint}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 1 } });
        }
        return .{ .inner = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = .{ .color = style.surface() },
            .border = .{ .y = 1 },
            .color_border = .{ .color = style.border() },
            .padding = .{ .y = style.space.sm },
        }) };
    }

    fn end(self: SettingsCard) void {
        self.inner.deinit();
    }
};

/// A setting's name and what it does, over the control the caller draws.
pub fn settingsField(src: std.builtin.SourceLocation, title: []const u8, hint: []const u8) void {
    var col = dvui.box(src, .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .margin = .{ .y = style.space.md, .h = style.space.sm } });
    defer col.deinit();
    dvui.label(@src(), "{s}", .{title}, .{ .font = style.small(), .color_text = .{ .color = style.text() }, .padding = dvui.Rect.all(0) });
    dvui.label(@src(), "{s}", .{hint}, .{ .font = style.tiny(), .color_text = .{ .color = style.textFaint() }, .padding = dvui.Rect.all(0), .margin = .{ .y = 2 } });
}

/// What git's global config says about signing, read when the section is
/// opened rather than every frame.
pub var signing_loaded = false;
var signing_format: []const u8 = "openpgp";
pub var signing_key: std.ArrayList(u8) = .empty;

/// The signing settings come from one `git` process on another thread: on
/// Windows, starting git takes long enough that waiting for it here froze the
/// window. Until it answers `signing_loaded` is false, and the page says so.
pub var signing_job: ?*run.Capture = null;

fn loadSigning() void {
    if (signing_loaded) return;
    const job_now = signing_job orelse blk: {
        const started = run.Capture.start(app.gpa, app.app_io, ".", &.{ "git", "config", "--global", "--get-regexp", "^(user\\.signingkey|gpg\\.format)$" }) catch {
            // Nothing to show, and no use asking again every frame.
            signing_loaded = true;
            return;
        };
        signing_job = started;
        break :blk started;
    };
    if (!job_now.finished()) return;
    signing_job = null;
    defer job_now.deinit(app.app_io);

    signing_loaded = true;
    signing_key.clearRetainingCapacity();
    signing_format = "openpgp";
    if (!job_now.ok) return;
    var lines = std.mem.splitScalar(u8, job_now.out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const value = std.mem.trim(u8, line[space + 1 ..], " ");
        if (std.mem.eql(u8, line[0..space], "user.signingkey")) {
            signing_key.clearRetainingCapacity();
            signing_key.appendSlice(app.gpa, value) catch {};
        } else if (std.mem.eql(u8, line[0..space], "gpg.format")) {
            signing_format = if (std.mem.eql(u8, value, "ssh")) "ssh" else "openpgp";
        }
    }
}
