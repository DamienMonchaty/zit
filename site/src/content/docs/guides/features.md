---
title: Features
description: What Zit does — history, staging, branches, remotes, GitHub, conflicts and the workspace.
---

## History

- A graph where every commit shows its author's picture.
- [Search](/guides/search/) by message, `author:`, `path:`, `code:`, `after:`.
- One branch, several, or all — hide any of them from the sidebar.
- A click on a branch, tag, worktree or stash in the sidebar brings its commit
  up in the graph; a double-click checks it out.
- A file's history through its renames, and blame.
- Compare any two commits.

## Changes and commits

- Stage files, hunks or single lines — new files too.
- Discard a hunk, a file, or everything.
- The ticket taken from the branch's name, conventional commits, templates.
- Co-authors, sign-off, GPG or SSH signing, amend.
- Undo and redo the last operation — a commit, a checkout, a merge — with
  `Ctrl+Z` and `Ctrl+Shift+Z`.

## Branches

- Create, rename, delete, switch.
- Merge (fast-forward, no-ff, squash), rebase, interactive rebase.
- Drag a branch onto another to merge or rebase it.
- Cherry-pick, revert, reset, tags.

## Remotes

- Fetch by hand, or every few minutes on its own.
- Pull by merge, rebase or fast-forward only.
- Push and set the upstream; a force push is always made with a lease.
- Stashes, worktrees, Git LFS.

Everything that talks to a remote runs off the window's thread, so a slow fetch
never freezes it.

## GitHub

- Pull requests in full: files, commits, checks, reviews, threads.
- Create, check out, review, comment, approve, merge, auto-merge.
- Re-run failed checks; browse issues.
- Sign in with a code on github.com — see [Connect GitHub](/start/github/).

## Conflicts

- Both sides side by side, region by region: take ours, theirs, or both.
- Continue, skip or abort from the toolbar.

## Workspace

- Tabs and tab groups, restored at start. Right-click a tab to group it; a
  click on a group's label folds it.
- The command palette, `Ctrl+P`: any action, branch or repository.
- Dark and light themes.
- A terminal in the repository's folder, `Ctrl+Shift+T`.

Every shortcut is on the [keyboard page](/guides/keyboard/), and in the app
under the keyboard button in the status bar.
