# Changelog

Every release of Zit, newest first. Downloads are on the
[Releases](https://github.com/DamienMonchaty/zit/releases) page.

## Unreleased

### Added
- A website, [damienmonchaty.github.io/zit](https://damienmonchaty.github.io/zit/):
  installing, connecting GitHub, every feature, the search syntax and the
  keyboard shortcuts.

### Changed
- The history's branch names have a column of their own, **BRANCH / TAG**,
  before the graph, as in GitKraken: read from its left, joined to their commit
  by a line of the branch's colour, and cut only where the column ends. Drag
  its edge to widen it; the width is kept.
- The Tree view of changed files is a file explorer's tree: folders nested in
  folders, set in under the one they are in, folders before files, each with
  how many files it holds; a folder holding only one folder shares its line,
  `src/components`. A click folds a folder; its + or − stages or unstages all
  of it. A commit's files show the same tree.
- Stage all runs off the window's thread, with its pill in the status bar:
  adding 11,000 new files is 13 s of `git` on Windows, which the window used
  to wait out frozen.

### Changed
- The right-hand panel is headed as the sidebar is: Changed files, Unstaged,
  Staged, Commit and a commit's sections in title case and semi-bold, with
  the sidebar's icons and hairlines, a count on a pill that reads at a
  glance. Unstaged and Staged fold under their title, as a sidebar section
  does.
- The toolbar's buttons are drawn as GitComet's action bar's: the icon and
  its caption side by side on a frame that lights under the pointer, what
  Pull or Push would move on a pill, Pull and its ways of pulling one split
  button, and the groups apart by a gap rather than a rule.

### Removed
- Focus mode, `Ctrl+Shift+F`, and its button in the status bar.

### Fixed
- In the Connect GitHub dialog, the loading dots no longer sit beside the
  buttons as if part of the last one: they say what is being waited on, on a
  line of their own — "Waiting for your approval on github.com" — and come
  with "Asking GitHub for a code…" too.
- With thousands of changed files, staging no longer stops the window: the
  status is read again off its thread after every command, as it already was
  on the timer. With 11,000 files a file's + froze it for half a second and
  the end of Stage all for 385 ms; now neither for more than 45 ms. While a
  command changes them, the lists of changes wait under a veil that says so —
  the three dots and "Staging…", "Committing…" — beside the status bar's pill.
- The uncommitted changes' node sits on the line of HEAD's commit, in its
  colour, with a dotted line down to it, rather than ten pixels left of the
  first line whatever HEAD was on.
- Hiding a branch from the graph takes it out: its name leaves the branch
  column, and so do the commits only it reaches — the remote branch it tracks
  is hidden with it, which kept them up before. A hidden tag's name goes too.
- The sidebar's sections are headed as GitComet heads them: their name in the
  text's own colour and case, a line between them, and no count — whose eye,
  on hover, used to take its place further right. An open section with
  nothing in it says so: "No stashes". Hiding a whole section from the graph
  is in its menu, opened by a right click or the ⋯ that shows on hover; a
  section hidden is faded, a crossed eye after its name.
- A branch's "Last commit" tooltip in the sidebar opens past the sidebar's
  edge, rather than over the ⋯ the hover brings up.
- With thousands of changed files, the lists of unstaged and staged files
  scroll, and the commit box stays in sight under them. Only the rows on
  screen are drawn: with 11,000 files the window answers in under a
  millisecond while scrolling, against 170 ms before.

## [0.1.2] — 2026-10-29

### Fixed
- The text of a one-line field is centred in it, instead of sitting near its top.
- The first tab starts at the window's edge, and the active tab is joined to the
  bar below it, with no line between.
- In the sidebar, a branch's name is centred on its row, level with the eye and
  the ⋯.
- On Windows, Settings › Commit signing opens at once, and switching branch
  no longer freezes the window: both wait for `git` on another thread, with
  the status bar's progress pill while the switch runs.
- A click refused because a command is still running — a branch switched to
  during a fetch — says so beside that command's pill, instead of behind it.
- On Windows, console windows no longer flash open each time Zit runs `git` or
  `curl`.
- With more tabs than the window is wide, the tabs scroll and the pull
  requests button, the account menu and the window's own buttons stay in
  sight; the tab switched to is scrolled into view.

## [0.1.1] — 2026-10-29

### Changed
- Connecting to GitHub uses Zit's new OAuth App: choose **Connect GitHub** and
  type the code shown on github.com. Pasting a personal access token is no
  longer offered.

### Fixed
- With **Use GitHub** off, author pictures no longer come from GitHub: only
  Gravatar is asked, so Zit sends nothing to GitHub at all.

### Added
- A [privacy policy](PRIVACY.md).

## [0.1.0] — 2026-10-29

First public release: history graph, staging by line, branches, rebase,
conflicts, stashes, worktrees, and GitHub pull requests, checks and issues.
Its downloads were withdrawn: its GitHub sign-in no longer works.

[0.1.2]: https://github.com/DamienMonchaty/zit/releases/tag/v0.1.2
[0.1.1]: https://github.com/DamienMonchaty/zit/releases/tag/v0.1.1
[0.1.0]: https://github.com/DamienMonchaty/zit/releases/tag/v0.1.0
