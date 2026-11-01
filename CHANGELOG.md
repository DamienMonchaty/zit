# Changelog

Every release of Zit, newest first. Downloads are on the
[Releases](https://github.com/DamienMonchaty/zit/releases) page.

## Unreleased

### Added
- A website, [damienmonchaty.github.io/zit](https://damienmonchaty.github.io/zit/):
  installing, connecting GitHub, every feature, the search syntax and the
  keyboard shortcuts.
- A zoom for the whole window, as a browser's: `Ctrl =` and `Ctrl -` (the
  keypad's too) a tenth at a time from 70 to 200 %, `Ctrl 0` back to 100 %,
  also in the command palette. It is remembered, and shown in the status bar
  when it is not 100 % — a click there resets it.

### Changed
- The author filter filters: the history is read again with the other
  authors' commits left out, each one kept joined to the nearest kept one
  before it, so the lanes still say how they follow one another — as
  `git log --author --graph` draws them — and an author's older commits are
  found beyond the last 5,000. The AUTHOR header names who it is narrowed
  to, and a chip over the graph says how many commits are theirs, with
  "show all authors". Its menu lists each author with their picture,
  address and how many commits — you first, those picked kept at the top —
  a click on one shows theirs alone, the box beside it adds or takes them
  off, and Enter in its field takes the first one shown. A commit's menu
  has "Only commits by…" and adds its author to the filter, or takes them
  off. Authors are told apart by name and address together, and read
  through the repository's `.mailmap`, so one person under two spellings
  is one author.
- A merge, rebase, cherry-pick or revert under way is said at the toolbar's
  right end, as GitComet's action bar says it: REBASING, MERGING… in bold,
  how far and how many conflicts under it, and the whole of it on hover —
  "Rebasing feat onto main", the commit it stopped on. Beside it Abort, Skip,
  and the next thing to do as the one filled button: Resolve the conflicts,
  Next file, Continue (also `Ctrl Enter` and the palette), or Skip empty for
  a commit its resolution left empty. Skip now works for cherry-picks and
  reverts too. The sidebar lists the conflicted files, each a click away.
- Nothing pushes the window down under the toolbar any more. A name asked
  for — a new branch or tag, a remote, a stash's message, a rename, a
  worktree — is asked in a dialog: Enter makes it, Esc lets it be. A yes or
  no for what cannot be undone is a toast low on the right, its button named
  for what it does — Discard, Delete, Force push, Abort — with Esc for
  Cancel. A branch dropped onto another opens a menu where it was let go, as
  GitKraken's, with the two things it can mean: merge it in, or rebase onto
  it.
- The conflict view works from the keys, as GitComet's: one region at a time
  is the active one, framed, with `↑` `↓` (or `F2` `F3`) to move, `1` `2` `3`
  to keep the left side, the right one or both, `U` or `Ctrl Z` to take the
  last pick back, `Enter` to stage a file with nothing left in it and open
  the next, `F4` for the next conflicted file. A click on an unresolved line
  of the output goes to its region.
- Each region shows its base — what the file had before either side
  changed it — even when git wrote plain markers, its default: Zit merges
  the file again from the index to find it. Regions that resolve on their
  own are marked — both sides made the same change, only one side changed
  it, or each changed different lines next to each other — and one click
  resolves them all, each line from the side that changed it.
- "All of main" and "All of feature/x" stage the file in the same click and
  open the next one; Undo pick and Start over take a file back. A file
  deleted on one side asks plainly — keep it, or delete it — and a binary
  file offers one side's version or the other's, instead of a page of noise.
- A pull request takes the whole pane, with GitHub's sidebar on its right:
  who reviews and where each stands, who it is assigned to, its labels.
  Each section's head drops the list to change it — the people who can be
  asked, the repository's labels with their colours — and each tick is sent
  at once. The pictures and the icons down its timeline are one size. Its
  list's filters — open, to review, mine, drafts, merged, closed — are a
  select beside the search, each with how many it holds. Its comments and reviews fold like an accordion: a click on one's
  head folds or opens it, a folded one keeps its first line; a long
  conversation opens on the description and the last three, with Expand all
  and Collapse all. Its actions are icons on its title's line — check out,
  open on GitHub, edit, back to draft, read again — and its readiness line
  ends with the one thing to do next: rebase it onto its base here (or merge
  the base in) when it conflicts, Update branch when it is behind, the
  failing checks, Ready for review for a draft, or Merge.
- Checking out a pull request works as `gh pr checkout`: its branch tracks
  the remote's, and a branch already here is brought up to date rather than
  left behind. A fork's request goes on `pr/N`, never onto a branch of yours
  of the same name. Update branch and Merge name the commit they were shown
  at, so GitHub refuses rather than act on a branch that moved; the request
  is read again once GitHub has updated it.
- In the pull requests, `↑` `↓` (or `K` `J`) walk the list in its order, `1`
  to `4` open its tabs, `Ctrl Enter` sends the review box as a comment, and
  the checked-out branch's request is the one open to begin with.
- The create and edit pull request dialogs keep a form's width, however long
  the template and the commits filled into the description are.
- A new pull request is filled in from lists, as on GitHub: the branch it
  goes into and the one it comes from, the reviewers and the assignees from
  the people who can be asked on the repository, its labels with their
  colours, and whether it opens ready for review or as a draft — each list
  with a field to narrow it. Reviewers, assignees and labels are set on it
  as soon as GitHub has made it. A branch not on the remote yet is pushed
  from the dialog. The dialog waits while GitHub makes it, then gives way to
  the new request, open in the list. The edit dialog is the same form,
  filled in with the request as it is.
- A conflict's sides are named: "Keep main", "Keep feature/x", with what each
  is — during a rebase, where git's "ours" is the base and "theirs" your
  own commit, the buttons say so instead of the reverse.
- After a rebase, Push becomes Force push (with lease), which says how many
  commits on the remote it replaces, and Pull stops counting the old
  commits it would merge back in.
- Merging, rebasing, cherry-picking and reverting are not offered while
  another one is under way; Continue and Skip run without freezing the
  window when hooks or signing take a while.
- Zit is roomier, towards GitComet's comfortable density: text a point
  larger throughout, taller rows in the lists, the history and the sidebar,
  wider menus with taller items, larger fields, buttons and tabs, and the
  changed files named in the interface's face rather than a mono one.
- The repository tabs are browser tabs, as GitComet's: the active one raised
  and open onto the bar below, the others flat with a rule between them, each
  with the repository's initials. Menus, dialogs and tooltips have rounder
  corners; a menu's row under the pointer is tinted with the accent rather
  than filled with it; the checked-out commit has an accent bar down its edge.
- The two side panels are one design, roomier: section headers and rows the
  same height on both, and the changes panel headed by **Changed files** as a
  title, over its sections. The graph's nodes — avatars, merges and the
  uncommitted changes' — are all one size, a little larger.
- The toolbar is taller, its buttons larger with readable captions. Its left
  end is the branch alone, on a framed button — the repository is the tab's —
  and the branch menu is as tall as its branches, up to a bound, rather than
  a fixed height. **Pull requests** has left the tab strip: the sidebar's section and the
  palette open them. A window too narrow for the captions shows
  the icons alone, their captions on hover.
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

### Removed
- Focus mode, `Ctrl+Shift+F`, and its button in the status bar.

### Fixed
- In the graph, a line meets a commit at its middle, as GitComet draws
  them: a merge whose parent is the next commit, on its left, comes down its
  own column and turns into it at its height, where it used to cross just
  above it and reach it beside its middle; a merge onto a line already on
  its left leaves across at its own height. The lines are two crisp pixels
  wide on the screen's grid, rather than a blur across three.
- A history read again in the background — after a fetch, say — dropped the
  graph out of First-parent.
- Merges, rebases and conflicts are harder to break by accident:
  - Staging a conflicted file that still has its conflict markers — with +,
    a double-click, Mark resolved, Stage all or the palette — asks first.
  - Abort and Skip ask first, saying what is lost.
  - Undo is refused while a merge, rebase, cherry-pick or revert is under
    way, where it used to reset under it; Amend is hidden then.
  - A pick in a conflicted file no longer writes over the file when it was
    edited elsewhere since it was shown.
  - An operation that stops at a conflict is no longer shown as an error:
    the first conflicted file opens instead.
  - An interactive rebase git refuses to start keeps its plan on screen,
    and its todo file is no longer left in the repository.
  - A merge stopped on a conflict in a terminal now shows in the toolbar.
- In the pull requests: ↑ and ↓ no longer move the hidden history, Ctrl+F
  searches the requests, a review written for one request is not carried to
  the next, Approve and Request changes are not offered on your own request,
  and a request GitHub has not yet checked reads "still working out whether
  it can merge…", asked again every few seconds, rather than "Ready to merge".
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
