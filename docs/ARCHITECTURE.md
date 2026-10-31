# How Zit is built

The details behind the [README](../README.md): building, testing, and the shape of the code.

## Build

    zig build          # needs zig 0.16.0; libgit2 is built from source
    zig build run -- /path/to/repo
    zig build dist     # release executables in zig-out/dist/

`dist` cross-compiles from any machine with GNU `tar` and `rm` on the PATH —
a Linux one as it comes; macOS and Windows need them installed, since the
Linux archives are packed by shelling out to them: `zit-linux-x86_64.tar.gz` and
`zit-linux-aarch64.tar.gz` (glibc 2.31 and later, nothing else from the
system — SDL loads X11 or Wayland itself) and `zit-windows-x86_64.exe`
(Windows 10 and later; per-monitor DPI aware through `assets/zit.manifest`, so it is not
stretched and blurred on a scaled display). All three are ReleaseSafe and
stripped, about 11 MB (the Linux archives about 5 MB); a plain `zig build` strips too, `-Dstrip=false` keeps the symbols for a stack trace. `-Dsystem-libgit2=true` links the machine's libgit2
instead, for a quicker local build.

A Linux executable carries no icon — the desktop takes it from a `.desktop`
entry and the icon theme — so the Linux archive holds the binary, the icons,
`zit.desktop` and `install.sh`, which puts them in `~/.local` (`--remove`
takes them out). The app id Zit gives SDL is `zit`, which is what lets the
taskbar match the window to that entry. At run time Zit needs `git` on the PATH;
`curl` is optional (author pictures, pull requests).

Memory: on Linux Zit asks SDL for its GPU renderer, then Vulkan, then OpenGL.
SDL's default, OpenGL, maps Mesa's gallium and LLVM into the process; on an
Intel laptop that alone took the RSS from about 49 MB to 117 MB. glibc's
`malloc_trim` runs after every snapshot swapped out, so the heap does
not keep the high-water mark of each one; there is a single malloc arena, so
the thread that reads the history does not leave its scratch pinned in one of
its own; large blocks are always their own mapping, so freeing one gives it
back at once; and libgit2 maps its packfiles in small windows. Release builds
set no per-thread signal stack, 256 KB of thread-local storage glibc would
otherwise zero for every thread. On Wayland, SDL is
told not to load libdecor except under GNOME — its GTK plugin alone pulled
GTK, Pango, GLib and ICU into the process, about 24 MB, for a title bar the
other desktops draw themselves. About 56 MB with a 3,000-commit repository
open — 14 MB of it git's pack files, mapped — and 33 MB with none. The ceilings, how they are measured and what has
been tried: [`PERF.md`](PERF.md) — `tools/measure.sh`, `tools/profile.sh`, `zig build
bench`.

The fonts are Inter and JetBrains Mono cut down to Latin, Greek, Cyrillic and
the symbols the UI uses, without the OpenType layout tables dvui never reads.

Run with no argument and Zit opens the repository containing the current
directory, searching upward like `git` does.

## Testing

    SDL_VIDEODRIVER=dummy zig build test
    SDL_VIDEODRIVER=dummy zig build test -Dtest-filter="renders a frame"

The video driver is what lets the layout tests render a frame without a display.
Most of the suite drives the real `git` binary, so the test repositories turn
`commit.gpgsign` off: without that, a machine that signs its commits asks for a
GPG passphrase once per test. `-Dtest-filter` runs one of them by name.

## Shape of it

Reads go through **libgit2** (`src/git.zig`): a revwalk beats parsing `git log`
output. Writes and anything networked shell out to the **`git` binary** —
credential helpers, the SSH agent, hooks and GPG signing all work for free
there, and each is a callback maze in libgit2.

Local commands run to completion before they return; a command that talks to a
remote goes through `run.Job` and runs somewhere else, so a slow `fetch` no
longer freezes the window. A job copies every argument it is handed, because the
argv it gets routinely points into a snapshot the poll timer is about to throw
away.

Open repositories sit in a **tab strip** across the top, and come back after a
restart — the list lives in `~/.config/zit/workspace.json` and is rewritten
after every change, once 400 ms have gone by without another (a failed write
is tried again, further apart each time, up to a minute), and at exit. `+` (or `Ctrl+T`) opens GitKraken's kind of
new-tab page rather than a folder picker: open, clone or start a repository,
and every one a tab has held, one click away. Tabs can be grouped the way a browser groups them: right-click a tab
to put it in a new group or another one, and the group shows as a coloured
label before its tabs, underlined in its colour; a click on the label folds
the group to it, a right-click renames, recolours, ungroups or closes it.
A tab dragged onto another takes its place, in its group or another one;
`Ctrl+Shift+PgUp`/`PgDn` moves the one shown without the mouse.
`Ctrl+W` closes a tab, and `Ctrl+B`
and `Ctrl+J` hide the branches and changes panels. A click on a branch,
remote branch, tag, worktree or stash in the sidebar brings its commit up in
the graph (a stash's: the one it was made on); a double-click still checks
out. The commit's summary and the lines of a diff are text you can select
and copy, except a changed line in a working-tree diff, where the click picks
the line for staging. Each graph node is the
author's picture, ringed in the lane's colour, from **Gravatar** (`src/avatar.zig`: fetched by `curl`, one at a time, off the
UI thread, cached in `~/.cache/zit/avatars`, a miss remembered as a `.miss`
file), and a disc of initials until it lands or where there is none. Every
lookup tells GitHub or Gravatar which author it is about.

UI is **dvui** (SDL3 backend), set in **Inter** and **JetBrains Mono**. Every visual value — fonts, spacing, colours,
graph geometry — lives in `src/style.zig`; the palette itself is authored in
`src/theme/zit_{dark,light}.json` and compiled in. The menu on your face at the
end of the tab strip — one button for you and for Zit: settings, keys, theme,
signing, the GitHub account — switches between the two and remembers which, in
the same file as the tabs.

Zit draws its own window frame: the system title bar is turned off and the tab
strip takes its place. Its empty part moves the window, the window's edges
resize it — both through SDL's hit test, so the system does the moving — and
minimise, maximise and close sit at the strip's end. `Esc` leaves the pull
requests for the history, as their tab's second click does.

The mouse is never the only way: `Ctrl+Enter` commits, `Esc` backs out of a
pane or answers away a bar, `↑`/`↓` walk the history with the diff pane
following, `F5` refreshes, `Ctrl+F` jumps to the commit search and `Ctrl+O`
opens a folder. They are handled *after* the frame is built, over the events no
widget claimed — which is what keeps `Esc` from closing the diff while someone
is typing a commit message. `Ctrl+Shift+Z` (or `Ctrl+Y`) redoes the undo just
made, `Ctrl+Tab`/`Ctrl+PgDn` go to the next tab, `Ctrl+,` opens the settings.
A shortcut is that chord exactly: Ctrl+Shift+Z is never also Ctrl+Z, and Alt,
AltGr — which Windows sends as Ctrl+Alt — and the Windows key keep a chord from
matching, so typing with AltGr never fires one; none uses Ctrl+Space or Ctrl+Shift alone,
which Windows gives to the input method and the keyboard layout, and only
`↑`/`↓` act on a held key's repeats. The keyboard menu lists them all,
because a shortcut nobody can find is a shortcut nobody has.

`src/graph.zig` turns the flat commit list into lanes and curves — the one
genuinely custom algorithm here.

Selecting a commit, or a changed file, opens a **diff pane under the graph**
rather than in place of it: the history you picked from stays on screen, so the
next commit is a click — or an arrow key — away. The box above the graph
searches it by message, author or sha. A search — or an author picked in the
column's header — leaves the graph as it is, every branch and lane in place,
and fades the commits it leaves out; the first match comes into view, and `↑`/`↓`
go from match to match. Only a file's history narrows the list, to a plain one
without lanes: a subset of them would describe a history that never happened.

The commit pane reads top to bottom: the commit — sha, refs, title and
description, all selectable — then its authors, date and parents, then its
files, as paths or folder by folder (a folder's line folds it). "All files"
lists the whole tree at that commit; a file it did not change opens as it
stood then. A branch's tag in the graph drags like its row in the sidebar,
onto another branch's tag or row, for the same merge-or-rebase bar.

A hunk is staged by rebuilding the patch out of what libgit2 handed back and
feeding it to `git apply --cached` on stdin, which is the only place Zit writes
anything to git other than a command line. A changed file answers a right-click
with the rest of what it can do — stage, open, blame, copy the path, discard. Merge, rebase, cherry-pick, revert
and reset are ordinary commands behind the right-click menus on branches and
commits; when one of them stops on a conflict, the banner under the toolbar is
what offers `--continue` and `--abort`. A commit's menu leads with checking
out — the branches on it, then the commit itself — and keeps the three resets
in one submenu.

A conflicted file gets a **resolution pane** rather than a diff, because a diff
against a file full of markers says nothing you can act on. Zit parses the
`<<<<<<<` regions out of the file on disk, offers ours/theirs/both for each one
and writes the file back. Staging it stays the separate, deliberate click it is
in a terminal — that is what "resolved" means to git.

An **interactive rebase** is composed as a list and handed to git whole:
`sequence.editor` is pointed at `cp <the todo Zit wrote>`, so git opens no
editor and reads exactly the list that was composed, and `core.editor=true`
covers the message editor a squash would otherwise stop on.

Everything that cannot be undone — discard, `reset --hard`, dropping a stash —
goes through one confirmation bar under the toolbar; everything that needs a
name first — a branch, a tag, a remote — through one prompt bar in the same
place. **Blame** and the **remotes** list are read through
libgit2 like the rest.

The branch you are on answers a right-click with what the toolbar has no
room for: pull with `--rebase` or `--ff-only`, a force push (always
`--force-with-lease`, behind the confirmation bar), rename. Other branches
add a no-ff merge, a squash merge, push-and-track, and `-D` behind the bar;
remote branches and tags can be deleted on the remote, tags pushed. Push
sets up the upstream itself on a branch that has none. A hunk can be
discarded as well as staged, a file in a commit's diff restored to that
version or shown as a **file history** — the graph narrowed to the commits
that changed it, worked out from tree ids in libgit2. Clone and a new
repository live in the repo menu, rename and re-pointing in the remotes list,
a named stash in the stashes section.

**Undo** (`Ctrl+Z`, and the toolbar) reads HEAD's reflog and takes back the
last move: a commit with `reset --soft`, so what it held stays staged; a merge,
pull or rebase with `reset --keep ORIG_HEAD`; a checkout by switching back.
Undoing an undo is the redo, and `Ctrl+Shift+Z` is exactly that while nothing
else has moved HEAD since. **`Ctrl+P`** is a command palette over every
action, branch and known repository. Lines of a hunk are
picked by clicking them and staged, unstaged or discarded on their own
(`git.patchForLines`) — a new file's too, which goes into the index holding
the picked lines alone. In the changes panel, Ctrl+click and Shift+click pick
several files, which are then staged, unstaged or stashed together (`git stash
push` with their paths on standard input). The commit box keeps everything that
shapes the commit beside its title: the ticket, recent messages, co-authors,
signing, sign-off and Amend. File history follows renames. **Worktrees** and
**pull requests** — listed, checked out, reviewed, merged and created
straight against GitHub's API — each have a
corner of the sidebar. A conflict shows its two sides side by side over the
OUTPUT they make. A branch dragged onto another asks whether to merge or
rebase. Clone and new repository are dialogs of their own, with a folder
picker and the path they add up to. Zit signs in to GitHub on its own, as
GitKraken does: "Connect GitHub" shows a code to type on github.com (OAuth's
device flow), and the token is kept, readable by the user alone, in Zit's
config folder — nothing to install. Settings › GitHub turns it off: no
pull requests or issues in the sidebar or the strip, no checks, no account,
and no request goes to GitHub.

Diffs are coloured by a small per-line lexer (`src/syntax.zig`: keywords,
strings, numbers, comments, type names; no grammar per language), and a
changed line set against the one it replaced marks the part that actually
changed. Whitespace can be ignored and the context widened; a diff read ignoring
whitespace is read-only, its hunks are not the file's. Branches can be hidden from the
graph, shown alone, or pinned to the top of their section; hidden and pinned
live in the repository's own config (`zit.hidden`, `zit.pinned`). A sidebar
row shows on hover an eye at its left, which takes the ref out of the graph or
back, and a ⋯ at its right, which opens its right-click menu; a section's
header has, in its count's place while hovered, an eye for all its refs at
once, so the few wanted can be shown again one by one. Every line's name
starts on its section title's column, a remote's branches one step in. Stashes and worktrees have the ⋯ and a menu too. Every
remote is fetched quietly every few minutes (Settings › Fetching). The search
box takes `author:`, `msg:`, `sha:`, `after:`/`before:` dates, and `path:` and
`code:`, which are `git log`'s pathspec and pickaxe run in the background. Any
branch or commit compares with the current one, from where they parted.
`Ctrl+Shift+T` opens the desktop's terminal in the repository.

The graph column is resized from its header; narrower than about 70 px it
turns into GitKraken's compact graph — each commit its author's picture, a bar
of its branch's colour beside it — and the graph icon in the header switches
between the two. "Branches:" over the graph shows every branch or one alone,
with or without the remote ones.

Author pictures come from GitHub first — for the person at the machine, the
account Zit is connected as; a `noreply` address names its
account, and for a repository on GitHub the API says whose a commit is — then
Gravatar.

Reads are *snapshots*: `History` (refs, commits) and `Work` (staged/unstaged)
each own an arena, and refreshing throws it away and builds a new one. On
Linux the repository is watched (`src/watch.zig`, inotify): every folder of
the working tree git does not ignore, and HEAD, the index, the refs and the
reflog in `.git`. A file you save in your editor shows up without asking and
without Zit asking either — idle, it does nothing; a 30-second poll stays as
the net under the watcher. Nothing is drawn without an event: a thread that
finishes — a command, a read, a picture — wakes the window itself, one wake a
frame however many ask; loading animations step a few times a second on a
timer, dvui's hover fades are off, and there is no vsync to wait for. Elsewhere, or past `fs.inotify.max_user_watches`,
the working tree is read every 0.7 s instead (3 s in the background). A read
that finds nothing changed draws nothing. The history is re-read when HEAD
moves, or after any command Zit itself runs.
