const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    // ReleaseSafe by default, not Debug: a revwalk over a large history is the
    // first thing the app does, and in Debug that is a visible stall. All
    // safety checks are kept. `-Doptimize=Debug` still gives a debug build.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // Stripped unless debugging: the symbols are three quarters of the
    // binary (46 MB against 11). A stripped build says "Unable to dump stack
    // trace" on a panic, so `-Dstrip=false` — or a Debug build — keeps them
    // for chasing one.
    const strip = b.option(bool, "strip", "Drop debug symbols (default: yes, except in Debug)") orelse
        (optimize != .Debug);
    const system_libgit2 = b.option(bool, "system-libgit2", "Link the system's libgit2 instead of building it") orelse false;

    const exe = addZit(b, target, optimize, strip, system_libgit2);
    b.installArtifact(exe);

    const install_desktop = b.addInstallFile(b.path("assets/zit.desktop"), "share/applications/zit.desktop");
    b.getInstallStep().dependOn(&install_desktop.step);
    for (icon_sizes) |size| {
        const icon = b.addInstallFile(
            b.path(b.fmt("assets/icons/{s}/zit.png", .{size})),
            b.fmt("share/icons/hicolor/{s}/apps/zit.png", .{size}),
        );
        b.getInstallStep().dependOn(&icon.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Most of the suite drives the real `git` binary, which means real commits
    // — and on a machine where commits are signed, a GPG prompt per test. A
    // filter is what lets you run the ones that do not.
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose name contains this");
    const tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The hot paths timed on a real repository, no window: `zig build bench
    // -- [repository] [--save FILE] [--vs FILE]`. See src/bench.zig.
    const bench = b.addExecutable(.{
        .name = "zit-bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/bench.zig"),
            .link_libc = true,
        }),
    });
    linkLibgit2(b, bench, target, optimize, system_libgit2);
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Time the hot paths on a repository").dependOn(&bench_run.step);

    // Every release executable at once, from any machine with GNU tar and rm
    // (the Linux archives are packed by them): `zig build dist`
    // puts them in zig-out/dist/. ReleaseSafe and stripped — the safety
    // checks stay, the debug symbols are most of the size.
    //
    // glibc 2.31 for Linux — Ubuntu 20.04, Debian 11 and everything since —
    // so the one binary runs on all of them; SDL3 needs 2.29 for
    // `posix_spawn_file_actions_addchdir_np`. SDL loads X11 or
    // Wayland itself at runtime, and libgit2 is static, so nothing else from
    // the machine is needed. Windows needs nothing beyond what Windows 10
    // ships.
    const dist_step = b.step("dist", "Build release executables for Linux and Windows");
    // A Linux executable carries no icon — the desktop finds one through a
    // `.desktop` entry and the icon theme — so Linux ships as a folder and a
    // .tar.gz of it: the binary, its icons, its menu entry and an
    // `install.sh` that puts them in ~/.local. Windows reads the icon out of
    // the .exe, so that stays a single file.
    const dists = [_]struct { query: []const u8, name: []const u8 }{
        .{ .query = "x86_64-linux-gnu.2.31", .name = "zit-linux-x86_64" },
        .{ .query = "aarch64-linux-gnu.2.31", .name = "zit-linux-aarch64" },
        .{ .query = "x86_64-windows-gnu", .name = "zit-windows-x86_64.exe" },
    };
    for (dists) |d| {
        const query = try std.Target.Query.parse(.{ .arch_os_abi = d.query });
        const resolved = b.resolveTargetQuery(query);
        const dist_exe = addZit(b, resolved, .ReleaseSafe, true, false);

        if (resolved.result.os.tag == .windows) {
            const install = b.addInstallArtifact(dist_exe, .{
                .dest_dir = .{ .override = .{ .custom = "dist" } },
                .dest_sub_path = d.name,
            });
            dist_step.dependOn(&install.step);
            continue;
        }

        const folder = b.fmt("dist/{s}", .{d.name});
        var parts: std.ArrayList(*std.Build.Step) = .empty;
        const install = b.addInstallArtifact(dist_exe, .{
            .dest_dir = .{ .override = .{ .custom = folder } },
            .dest_sub_path = "zit",
        });
        try parts.append(b.allocator, &install.step);
        try parts.append(b.allocator, &b.addInstallFileWithDir(b.path("assets/zit.desktop"), .{ .custom = folder }, "zit.desktop").step);
        try parts.append(b.allocator, &b.addInstallFileWithDir(b.path("assets/install.sh"), .{ .custom = folder }, "install.sh").step);
        for (icon_sizes) |size| {
            try parts.append(b.allocator, &b.addInstallFileWithDir(
                b.path(b.fmt("assets/icons/{s}/zit.png", .{size})),
                .{ .custom = folder },
                b.fmt("icons/{s}/zit.png", .{size}),
            ).step);
        }

        // install.sh keeps its execute bit through the install step only if
        // the source has it; set it in the archive regardless.
        const tar = b.addSystemCommand(&.{ "tar", "--mode=u+rwX,go+rX", "-czf" });
        tar.addArg(b.getInstallPath(.{ .custom = "dist" }, b.fmt("{s}.tar.gz", .{d.name})));
        tar.addArgs(&.{ "-C", b.getInstallPath(.{ .custom = "dist" }, "") });
        tar.addArg(d.name);
        for (parts.items) |part| tar.step.dependOn(part);

        // The folder was only the archive's staging: shipping both doubles
        // what dist/ weighs for nothing.
        const tidy = b.addSystemCommand(&.{ "rm", "-rf" });
        tidy.addArg(b.getInstallPath(.{ .custom = "dist" }, d.name));
        tidy.step.dependOn(&tar.step);
        dist_step.dependOn(&tidy.step);
    }
}

/// The icon sizes the desktop's icon theme looks for, as hicolor names them.
const icon_sizes = [_][]const u8{ "16x16", "32x32", "48x48", "64x64", "128x128", "256x256", "512x512" };

/// The app for one target. Everything a build of it needs, so `dist` can ask
/// for several side by side.
fn addZit(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    system_libgit2: bool,
) *std.Build.Step.Compile {
    // dvui's SDL3 backend builds in tree-sitter and tinyfiledialogs unless
    // told not to: dead weight, since Zit highlights code with its own lexer
    // and picks folders through SDL's dialog. FreeType stays: stb_truetype in
    // its place saves 0.8 MB but draws the text wider and softer — a line
    // of the history shows three fewer letters.
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        .@"tree-sitter" = false,
        .@"tiny-file-dialogs" = false,
    });

    const exe = b.addExecutable(.{
        .name = "zit",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .strip = strip,
        }),
    });

    slimDvui(b, dvui_dep);
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));

    // The version the app shows is the one in build.zig.zon, read here: the
    // release workflow already checks that against the tag, so the two cannot
    // drift apart.
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addOptions("build_options", version_options);

    // Zig 0.16's translate-c chokes on MinGW's fortified string functions —
    // the `wcscat_s` wrappers `_FORTIFY_SOURCE` switches on in optimised
    // builds come out as Zig that does not compile. They are never called
    // from Zig, so turn the fortification off for dvui's C headers alone.
    if (target.result.os.tag == .windows) unfortify(b, dvui_dep.module("dvui_sdl3"));

    // Reads go through libgit2; writes and anything networked shell out to the
    // `git` binary, so this is the only native git dependency.
    //
    // Built from source and linked statically by default: the same build then
    // makes a Windows executable from Linux, and a Linux one that does not
    // care which libgit2 — or libssl, libssh2, pcre — the machine has. The
    // system's copy is still there for a quicker local build.
    exe.root_module.link_libc = true;
    linkLibgit2(b, exe, target, optimize, system_libgit2);

    // The icon Explorer shows, and the manifest that declares the app
    // DPI-aware: without it Windows renders the window small and stretches
    // it on any scaled display, which is the blur that makes the same UI look
    // different there.
    if (target.result.os.tag == .windows) {
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/zit.rc") });
    }

    // No console window behind a release build. A PE header field: nothing
    // to set on the other systems.
    if (optimize != .Debug and target.result.os.tag == .windows) exe.subsystem = .Windows;

    // Each function and each constant of the C libraries in a section of
    // its own, so that the linker, which already drops the sections nothing
    // refers to, drops them one by one instead of whole files at a time.
    // Nothing changes in the code that stays.
    if (optimize != .Debug) {
        const linked = Linked.of(b, exe);
        for (linked.libs.items) |lib| {
            lib.link_function_sections = true;
            lib.link_data_sections = true;
        }
        exe.link_function_sections = true;
        exe.link_data_sections = true;
    }

    // SDL as Zit uses it: video and events, nothing else. Its dynamic API
    // — a table of every SDL function, so that `SDL3_DYNAMIC_API` can swap a
    // newer SDL in at run time — keeps all of them linked, used or not;
    // `SDL_THREAD_SAFETY_ANALYSIS` is the switch SDL_dynapi.h leaves for
    // turning it off (on clang its only other effect is attributes). And
    // audio, joysticks (and with them HID), haptics, sensors, cameras and
    // power are compiled out: dvui starts SDL with `SDL_INIT_VIDEO |
    // SDL_INIT_EVENTS`.
    if (Linked.of(b, exe).named("SDL3")) |sdl| leanSdl(sdl);

    return exe;
}

/// dvui built from a copy of its sources with the changes below: code and
/// data it compiles in that Zit has no use for, and no option of its turns
/// off. Each change finds its place by the text around it, and fails the
/// build, saying where, when a new dvui has moved it.
fn slimDvui(b: *std.Build, dvui_dep: *std.Build.Dependency) void {
    const io = b.graph.io;
    const copy = b.addWriteFiles();
    var left_out: std.ArrayList([]const u8) = .empty;

    // The window starts on dvui's Adwaita theme, before Zit's replaces it,
    // and that theme embeds ten Bitstream Vera faces: 578 KB of fonts Zit
    // never draws with. Kept: Vera Sans, dvui's fallback face.
    {
        const text = std.Io.Dir.cwd().readFileAlloc(io, dvui_dep.path("src/themes/Adwaita.zig").getPath(b), b.allocator, .limited(1 << 20)) catch
            @panic("dvui: cannot read src/themes/Adwaita.zig");
        const from = std.mem.indexOf(u8, text, "const fonts: []const Font.Source = &.{") orelse
            @panic("dvui: Adwaita's font list has moved, see slimDvui");
        const to = std.mem.indexOfPos(u8, text, from, "\npub const light") orelse
            @panic("dvui: Adwaita's light theme has moved, see slimDvui");
        _ = copy.add("src/themes/Adwaita.zig", b.fmt(
            "{s}const fonts: []const Font.Source = &.{{.{{ .family = Font.array(\"Vera Sans\"), .bytes = Font.Source.fallback.bytes }}}};\n{s}",
            .{ text[0..from], text[to..] },
        ));
        _ = copy.addCopyFile(dvui_dep.path("src/fonts/bitstream-vera/Vera.ttf"), "src/fonts/bitstream-vera/Vera.ttf");
        left_out.appendSlice(b.allocator, &.{ "Adwaita.zig", ".ttf", ".otf" }) catch @panic("OOM");
    }

    // dvui's debug window — an inspector, a colour picker, nineteen copies
    // of a slider — draws only once `dvui.toggleDebugWindow` has opened it,
    // which Zit never calls; but every frame's end asks for it, so all of it
    // is linked.
    {
        const text = std.Io.Dir.cwd().readFileAlloc(io, dvui_dep.path("src/Debug.zig").getPath(b), b.allocator, .limited(1 << 22)) catch
            @panic("dvui: cannot read src/Debug.zig");
        const show = "pub fn show(self: *Debug) void {";
        const at = (std.mem.indexOf(u8, text, show) orelse @panic("dvui: Debug.show has moved, see slimDvui")) + show.len;
        _ = copy.add("src/Debug.zig", b.fmt("{s}\n    if (true) return;{s}", .{ text[0..at], text[at..] }));
        left_out.append(b.allocator, "Debug.zig") catch @panic("OOM");
    }

    // `exclude_extensions` matches the end of each path, so a file name works.
    _ = copy.addCopyDirectory(dvui_dep.path("src"), "src", .{ .exclude_extensions = left_out.items });
    dvui_dep.module("dvui_sdl3").root_source_file = copy.getDirectory().path(b, "src/dvui.zig");
}

fn leanSdl(sdl: *std.Build.Step.Compile) void {
    sdl.root_module.addCMacro("SDL_THREAD_SAFETY_ANALYSIS", "1");
    for (sdl.root_module.include_dirs.items) |dir| switch (dir) {
        .config_header_step => |config| if (std.mem.eql(u8, config.include_path, "SDL_build_config.h")) {
            const unused = [_][]const u8{ "SDL_AUDIO", "SDL_JOYSTICK", "SDL_HAPTIC", "SDL_SENSOR", "SDL_CAMERA", "SDL_POWER" };
            var it = config.values.iterator();
            while (it.next()) |entry| for (unused) |prefix| {
                if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
                if (std.mem.endsWith(u8, entry.key_ptr.*, "_DISABLED")) {
                    entry.value_ptr.* = .{ .boolean = true };
                } else if (entry.value_ptr.* == .boolean) {
                    entry.value_ptr.* = .{ .boolean = false };
                }
            };
        },
        else => {},
    };
    // With joysticks and sensors compiled out SDL falls back on its dummy
    // drivers, which its build leaves out on Windows (both) and Linux (the
    // joystick's).
    const sdl_src = sdl.step.owner.path("src");
    sdl.root_module.addCSourceFiles(.{ .root = sdl_src, .files = &.{"joystick/dummy/SDL_sysjoystick.c"} });
    if (sdl.rootModuleTarget().os.tag == .windows) {
        sdl.root_module.addCSourceFiles(.{ .root = sdl_src, .files = &.{"sensor/dummy/SDL_dummysensor.c"} });
    }
}

/// The static libraries `exe` links, at any depth — dvui's SDL, libgit2's
/// zlib and mbedtls — and every module it is built from: what a setting has
/// to reach to apply to the C dependencies as well as to Zit.
const Linked = struct {
    libs: std.ArrayList(*std.Build.Step.Compile) = .empty,
    modules: std.ArrayList(*std.Build.Module) = .empty,

    fn of(b: *std.Build, exe: *std.Build.Step.Compile) Linked {
        var self: Linked = .{};
        self.walk(b, exe.root_module);
        return self;
    }

    fn walk(self: *Linked, b: *std.Build, module: *std.Build.Module) void {
        for (self.modules.items) |seen| if (seen == module) return;
        self.modules.append(b.allocator, module) catch @panic("OOM");
        for (module.link_objects.items) |object| switch (object) {
            .other_step => |linked| {
                for (self.libs.items) |seen| {
                    if (seen == linked) break;
                } else {
                    self.libs.append(b.allocator, linked) catch @panic("OOM");
                    self.walk(b, linked.root_module);
                }
            },
            else => {},
        };
        for (module.import_table.values()) |imported| self.walk(b, imported);
    }

    fn named(self: Linked, name: []const u8) ?*std.Build.Step.Compile {
        for (self.libs.items) |l| if (std.mem.eql(u8, l.name, name)) return l;
        return null;
    }
};

fn linkLibgit2(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, system_libgit2: bool) void {
    if (system_libgit2) {
        exe.root_module.linkSystemLibrary("git2", .{});
    } else {
        const libgit2 = b.dependency("libgit2", .{ .target = target, .optimize = optimize });
        exe.root_module.linkLibrary(libgit2.artifact("git2"));
    }
}

/// Every translate-c step reachable from `module`'s imports, told not to
/// fortify. Walks the import graph rather than naming the steps, which dvui
/// does not export; the graph has cycles, hence `seen`.
fn unfortify(b: *std.Build, module: *std.Build.Module) void {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    unfortifyFrom(b, module, &seen);
}

fn unfortifyFrom(b: *std.Build, module: *std.Build.Module, seen: *std.AutoHashMapUnmanaged(*std.Build.Module, void)) void {
    if ((seen.getOrPut(b.allocator, module) catch @panic("OOM")).found_existing) return;
    for (module.import_table.values()) |imported| {
        if (imported.root_source_file) |root| switch (root) {
            .generated => |g| if (g.file.step.cast(std.Build.Step.TranslateC)) |tc| {
                tc.defineCMacro("_FORTIFY_SOURCE", "0");
            },
            else => {},
        };
        unfortifyFrom(b, imported, seen);
    }
}
