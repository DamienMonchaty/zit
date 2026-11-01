# Performance

Measured, never supposed: the three "obvious" causes under *Wrong, measured*
below were all wrong.

## Ceilings

Checked before every delivery, on a repository of a few thousand commits
opened in a fresh window and left alone.

| What | Ceiling | Last measured |
|---|---|---|
| RSS, settled | 64 MB | 56 MB |
| Peak RSS (VmHWM), start-up included | 96 MB | 71 MB |
| Private_Dirty — Zit's own memory | 40 MB | 16 MB |
| CPU while idle, window focused | 0.5 % — the goal is 0 | 0.07–0.10 % |

`tools/measure.sh` checks them and fails when one is over. Last run:
2026-10-29, ReleaseSafe, a clone of a ~3,000-commit repository **on disk**,
warm picture cache, read 70 s after opening, two runs.

Private_Dirty moves with the moment it is read: 16.8 MB at 45 s, 8 MB at
70 s in the same run, once the first fetch, the pull requests' list and a
trim have gone by. Compare builds read at the same moment.

Idle is now the watcher (`src/watch.zig`): nothing is read until inotify
says something changed, and a 30 s poll is the net under it. What is left,
0.8 wake-ups a second, is not Zit's: 0.6 on the main thread inside SDL's
event wait — the only timer Zit sets is that 30 s one — and 0.2 on a pool
thread, about one tick in 30 s. 361 watches on that repository (its 354
folders that git does not ignore, and `.git`'s few), against a limit of
524,288 here; past `fs.inotify.max_user_watches`, and on Windows and macOS,
it is the old 0.7 s poll, still without frames for a status that did not
change.

## Method

1. **Measure.** `tools/measure.sh [binary] [repository] [idle s]` runs Zit
   with a throwaway config and cache and reads `/proc`: RSS and VmHWM in
   `status`, Private_Dirty in `smaps_rollup` (RSS counts shared pages —
   the GPU driver's, the fonts — that are not Zit's to save), and the
   process's ticks in `stat` over the idle window. `CACHE=dir` keeps the
   picture cache between runs, `SETTLE=s` waits longer before measuring.
2. **Where the time goes.** `tools/profile.sh [repository] [samples]`
   samples every thread's stack with `eu-stack` on an unstripped build and
   counts the frames: who is busy, and inside what. No perf on this machine;
   no root needed.
3. **Compare variants.** `zig build bench -- [repository] --save before.txt`,
   change something, `zig build bench -- [repository] --vs before.txt`.
   Times the history read, the graph layout, the status read, 50 commits'
   diffs and the lexer over their lines, with no window; median of up to 200
   runs after one warm-up, Zig-side allocations counted (libgit2's mallocs
   are not). `-Doptimize=ReleaseFast` compares release modes the same way.
   **Two runs of the same build differ by up to 15 %** on this machine (a
   desktop session running beside it): run three times, and a change that
   does not beat that has not been shown to do anything.
4. **Release without safety.** `SDL_VIDEODRIVER=dummy zig build test
   -Doptimize=ReleaseFast` — undefined behaviour ReleaseSafe traps on runs
   on there. Then a **Debug build run for a minute on a real repository**
   (`-Doptimize=Debug`): it has the stack traces, the leak check and dvui's
   warnings the tests do not reach (see the crash below).
5. **In this order:** simpler architecture, then a better algorithm, data
   structure, fewer allocations, fewer copies — profiling and benchmarking
   to choose — then the hot path, SIMD last.
6. **Write down what failed, with its numbers**, below.

Measure on a copy of a repository: Zit fetches in the background, and a run
on a real one fetched into it (4,385 → 4,836 commits during one measurement).
And keep the copy on disk, not in `/tmp`: on tmpfs a mapped file's pages are
counted as the process's own dirty memory — 12 MB of git's pack index and
packs showed up as Zit's until the clone moved (`.zig-cache/measure/`).

## Bench, 2026-10-29: git/git

A clone of git/git (85,906 commits, 324 MB of `.git`), ReleaseSafe, Intel
Core Ultra 7 155H.

| Case | git/git | 3,866 commits |
|---|---|---|
| history | 993 ms | 103 ms |
| graph layout | 7.4 ms | 0.9 ms |
| status | 16 ms | 5 ms |
| 50 commits' diffs | 322 ms | 79 ms |

`tools/measure.sh` on git/git, the picture cache kept from a first run: 79 MB
RSS (96 MB peak), 43 MB Private_Dirty, 0 % idle CPU, 0.3 wake-ups/s. With an
empty cache the first minute is not idle — 24 % CPU — while hundreds of
authors' pictures are fetched.

The history is 10× slower for 1.3× the commits shown because the revwalk
sorts `TOPOLOGICAL | TIME`: libgit2 walks all 85,906 commits before it hands
back the first one. Sorting by time alone would stream, but a commit dated
before its parent (clock skew) would then come out first and break the
lanes. Open: a topological order bounded to the commits shown.

## Bench, 2026-10-28

A clone of a 3,171-commit repository, clean working tree.

| Case | ReleaseSafe | ReleaseFast |
|---|---|---|
| history (revwalk, refs, stashes…) | 45 ms | 35 ms |
| graph layout | 0.8 ms | 0.3 ms |
| status | 4 ms | 3.4 ms |
| 50 commits' diffs | 57 ms | 49 ms |
| lexer over those diffs | 7 ms | 4 ms |

The safety checks cost 15–60 % on these, most on the Zig-side code (the graph,
the lexer), least where libgit2 does the work. Zit ships ReleaseSafe; that is
the price of a crash being a message instead of corrupted memory.

## The poll, taken apart (2026-10-28)

Three builds, three runs each, idle CPU 40–70 s after opening, lowest run:

| Build | Idle CPU |
|---|---|
| Status every 0.7 s, a frame for every read (as it was) | 7.0 % |
| … no frame when the status did not change | 2.2 % |
| … and the poll every 60 s | 0.4 % |
| inotify watcher, 30 s net (shipped) | 0.03 % |

The frames cost more than the reads: one `git status` is ~4 ms (bench), but
each read that landed started a frame, and a second for the widgets whose
size moved. Both changes are kept: the watcher's own signals also land on
reads that find nothing.

The first runs of this set disagreed wildly — 15 %, then 7 % for the same
build — and two died at start-up: builds were compiling beside them, and the
window opens on a desktop someone is using. Hence the lowest of several runs,
and `measure.sh` printing wake-ups a second as well, which moves less.

An earlier series measured 1.0 % for the first build, 15 s after opening:
inside the window where the first fetch runs. Measure after it — 40 s.

## A crash the suite did not catch (2026-10-29)

`integer overflow` two seconds after start, every time, on one repository —
not in 140 tests, not in ReleaseFast. `askCi` counted the commits and the
requests' heads it asks CI about into `var n = @min(len, CI_COMMITS)`, and
against a comptime constant `@min` narrows: `n` was a `u6`, and 40 commits
plus the requests went past 63 on a repository with enough of them open,
once their list arrived. The tests never list requests; the release build
only showed `stack tracing is disabled`, and the unstripped one, timed
differently, did not crash at all.

What found it: a **Debug build run on the real setup** (`-Doptimize=Debug`
— symbols and a stack trace), which pointed at the line in one go, and also
flagged a tag dvui saw twice and a map never freed at exit. Add to step 4:
before a delivery, a Debug run of a minute on a real repository, not only
the tests.

## Memory, taken apart (2026-10-29)

Where it goes, `/proc/<pid>/smaps` by mapping, 45 s after opening:

| | RSS | Zit's own (dirty) |
|---|---|---|
| Floor — no repository open | 33 MB | 16 MB |
| of which the Vulkan driver, the binary | 9 + 8 MB | 0 |
| A ~3,000-commit repository open | 61 MB | 30 MB |
| of which git's pack index and packs, mapped | 14 MB | 0 — page cache, shared |

Renderers, same repository, same moment: SDL's GPU renderer 61 MB / 30 MB
dirty (peak 77), Vulkan 71 / 37 (86), OpenGL 123 / 44 (140) — 40 MB of it
Mesa's gallium and 14 MB LLVM, its shader JIT — software 142 / 64 (156). The
order stands: GPU, then Vulkan, then OpenGL.

What changed, each measured at 45 s:

- **The history's arena: 8.1 MB → 1.15 MB** for 2,998 commits whose live
  content is about 1.1 MB. Each `Commit` carried a fixed eight-slot array of
  parents, 160 of its 256 bytes, when almost every commit has one: now a
  slice in the arena, 112 bytes a commit. The list grew in the arena, so
  every buffer it outgrew stayed there: it grows on the heap now and is
  copied in once, at its size. An author's name and address are stored once
  however many commits (106 KB on that history). Bench: the same time,
  62–66 ms both ways.
- **256 KB of thread-local storage per thread, gone.** `std.options.
  signal_stack_size` — the stack a segfault's trace prints on — is a
  `threadlocal` array, and glibc reserves and zeroes static TLS for every
  thread in the process, SDL's and the GPU driver's too, at the top of each
  thread's stack: about 280 KB of each thread's RSS. Kept in Debug; release
  builds are stripped and could not print the trace.
- **A fixed `mmap` threshold** (`M_MMAP_THRESHOLD`, 128 KB): glibc's moves up
  to the last large block freed, and the next large blocks then come from
  the heap, where a free returns nothing until a trim.
- Diff lines, blame lines and a whole file's lines are allocated at their
  count — libgit2 knows each hunk's — instead of grown in an arena.
- The split diff's row buffer gives its room back once a smaller diff
  replaces a big one.

Together: RSS 61 → 55–56 MB, Zit's own memory 30 → 24 MB, peak 77 → 69–70 MB.

Checked, and nothing to do:

- dvui already gives its frame arenas back above their use (it resets each
  to 90 % of its capacity every frame), so a peak does not stay.
- What programs print is capped — 1 MB of output, 8 KB of errors — and so
  are the history (5,000 commits), the requests listed (100) and the recent
  repositories. New caps: a diff of a file over 16 MB is shown as binary
  rather than read (libgit2's default is 512 MB); a picture download stops at
  1 MB, the size it is read back at.
- Undo is git's reflog, on disk: nothing to compress.
- The heap's small stack-sized buffers are on the stack, not the heap; no
  preallocation found that a smaller need would not fill.
- Frames: **a frame drawn again with nothing changed makes no heap
  allocation** — a test, with a commit and its diff open, counts them. And
  a test opens everything a repository holds and closes it, three times, on
  `std.testing.allocator`, which fails on a byte left behind.

## Idle, taken apart again (2026-10-29)

Nothing draws without a reason now, and every reason is an event:

- **Workers wake the window when they finish** — a command, a status or
  history read, a picture, a GitHub call (`run.wake`). Before, each kept the
  window drawing while it was out: a picture download, up to 10 s, was
  frames at the display's rate for 10 s; a running command too. And since
  the watcher, a status read it set off was drawn only at the next frame
  something else asked for — a mouse move, or the 30 s net. One wake per
  frame however many threads ask (`wakeUi`, an atomic flag).
- **No continuous animation.** dvui's spinner turned every frame and the
  loading screen breathed every frame: both step on a timer now, five and
  twelve times a second. dvui's own motion is off (`reduce_motion`, no
  0.12 s hover fade), so a button under the mouse is one frame, not eight.
- **No vsync.** Zit draws on a change, not every refresh of the display:
  waiting for the next one only added up to 16 ms between a key and its
  effect.
- **Settings are written once things are quiet** — 400 ms after the last
  change, instead of at every one (a column dragged was a write a frame) —
  and a write that fails is tried again 0.4, 0.8, 1.6 s… later, up to a
  minute. At exit, at once.
- A test sweeps the mouse over the whole window, then counts the frames
  until it stops asking: fewer than five. dvui's `settle`, which every
  interface test goes through, already fails at 100 in a row.

Measured, lowest of runs: idle **0.07–0.10 %**, 0.7–0.9 wake-ups a second.
The first 30 s with an empty picture cache — pictures downloading, the
fetch, the pull requests — **2.5 %**, where the first measurements of this
file saw 17.8 and 49.5 % (on the real repository, with its fetch over the
network: not the same run, so not a strict comparison). The same window
measured 9.5 and 20 % in other runs: start-up on a live desktop is the
noisiest number here.

## Algorithms (2026-10-29)

Looked for, then measured on the shapes Zit meets: the repositories here have
30–150 refs, 1,700–4,600 commits, a handful of changes and up to ~1,000
files — and, for what a team's repository can have, one made with 3,000
branches.

| Frame, Zit's own code (`appFrame`, not the drawing) | Before | After |
|---|---|---|
| ~4,600-commit repository, sidebar open | 4.0 ms | — |
| 3,000 branches, sidebar open | 45 ms | **6.7 ms** |
| 3,000 branches, all hidden | 68 ms | **7.0 ms** |

- **The sidebar built every line of a section**, 3,000 for 3,000 branches,
  when a dozen show: folded, the same frame took 6.5 ms. It builds the
  lines on screen now, as the graph always has — every line is
  `style.side_row` high, so where each sits is arithmetic and two spacers
  stand for the rest (`sideRows`). A test scrolls a section of 60 to its
  end and finds the last branch built and the first not.
- **"Is it hidden?" was a walk through the hidden list**, asked for every
  ref drawn and every ref walked: 23 ms a frame with 3,000 hidden. A set now,
  beside the list (`hidden_set`), and the history read builds one for itself.
- The graph's layout is O(commits × lanes), lanes at most 64: 0.3 ms.
  `path:`/`code:` hits were a hash set already. Filtering 4,600 commits for
  a search, every frame while one is typed: 0.1–1.4 ms — under budget, not
  cached.
- The profile of the 4 ms frame (`eu-stack` on the test binary) has no
  hot spot: it is spread over the forty-odd lines drawn, text above all.
- One-byte needles: `std.mem.count` already turns them into the vectorised
  `countScalar`; no multi-byte search runs in a loop over anything large.
- **No SIMD:** nothing measured spends its time where it would help. The
  lexer is 7 ms over 50 whole diffs and runs only on the forty lines on
  screen.
- The fixed `mmap` threshold, measured where it could cost — the history
  read's arena, 50 diffs: 95–101 ms and 28–31 ms with it or without, the
  same within the noise.

The test backend draws in software: 51 ms of each of its frames is that,
not Zit, and is left out of the numbers above.

## Lists built whole (2026-11-01)

Three lists still built a widget for every row, every frame, the menu
open or the commit picked: a commit's files (capped at 2,000 rows for it),
two commits compared (no cap) and the authors' menu, where each row also
asked for its picture. They build the rows in sight now: `rowsInSight`
reads where the list's box sits against the clip — the scroll area it is in,
however deep — so a list in the middle of the commit pane, whose own scroll
it is not, does it too; spacers stand for the rest, as in `sideRows`.

`appFrame` alone, median of 30 frames in the test backend, Windows
(i7-1185G7):

| | Before | After |
|---|---|---|
| A commit of 2,000 files picked | 20.4 ms | 2.1 ms |
| The authors' menu open, 300 authors | 12.3 ms | 4.3 ms |

Two commits compared go through the same rows and `rowsInSight`, and were
not timed apart. The 2,000-row cap is gone: a commit of 20,000 files lists
them all at the same cost.

## Wrong, measured

- **"Zit burns 20–50 % CPU when idle."** 17.8 % then 49.5 % in the first two
  runs — measured 8 and 15 s after start, on the real repository: the
  background fetch, GitHub calls, and the author pictures still arriving. Settled,
  on a copy: 1.0 %.
- **"The main thread renders all the time."** Sampled: 149 of 150 stacks in
  `ppoll`, inside `SDL_WaitEventTimeout`. dvui's refresh log: about five
  frames a second, started by the status poll landing or a picture arriving,
  and a second one each time for the widgets whose size moved.
- **"The lexer is what makes a diff slow."** The first lexer case took 63 ms
  for 50 commits; 57 of them were libgit2 reading the diffs. The lexer
  alone: 7 ms.

## Measured before (ARCHITECTURE.md's numbers)

Not to be tried again without a reason the numbers did not have:

- Renderer on Linux: OpenGL 117 MB RSS, Vulkan 58 MB, SDL's GPU renderer
  49 MB, same CPU — GPU first, then Vulkan, then OpenGL.
- libdecor on Wayland: its GTK plugin is 24 MB of RSS for a title bar; off
  except under GNOME (and the window draws its own frame now anyway).
- One malloc arena instead of one per thread: 6 MB the history thread's
  arena kept pinned.
- `malloc_trim` after every snapshot swapped out: the heap does not keep
  each refresh's high-water mark.
