---
title: Branches and remotes
description: Create and switch branches, merge and rebase by dragging, resolve conflicts, stash, and work with remotes.
---

## Branches

- **Create**: **Branch** in the toolbar, or a right-click on any commit.
- **Switch**: double-click a branch in the sidebar, or pick it from the branch
  button in the toolbar.
- **Rename, delete, set the upstream**: a right-click on the branch.

## Merge and rebase

**Drag a branch onto another** in the sidebar: Zit asks whether to merge or
rebase it. The same is in the branch's right-click menu, with every kind of
merge — fast-forward, `--no-ff`, squash — and an interactive rebase, where you
reorder, squash, reword or drop commits.

Cherry-pick, revert and reset are on a commit's right-click menu.

## Conflicts

When a merge, rebase or cherry-pick stops on a conflict, the toolbar says so
and the conflicted files are listed in the changes.

Open one: both sides stand side by side, region by region. For each, keep
**ours**, **theirs**, or **both** — `1`, `2`, `3` on the keyboard. `Enter`
stages the file once nothing is left, and opens the next one.

Then **Continue**, **Skip** or **Abort** from the toolbar — `Ctrl+Enter`
continues.

## Stashes

**Stash** puts everything aside; **Pop** brings the last stash back. Each
stash is in the sidebar: click it to see what it holds, right-click to apply,
pop or drop it.

## Worktrees and tags

Worktrees and tags are in the sidebar too: a click brings their commit up in
the graph. Tags are made from a commit's right-click menu.

## Remotes

- **Fetch** gets what is new on every remote. Zit can do it on its own every
  few minutes — **Settings › General › Fetch in the background**.
- **Pull** joins it to your branch: merge, rebase or fast-forward only, from the
  arrow next to it — or once and for all, per repository, in
  [its settings](/guides/settings/#repositories).
- **Push** sends your commits, and sets the upstream the first time. A force
  push is always made with a lease, so it never overwrites work you have not
  seen.

Everything that talks to a remote runs off the window's thread: a slow fetch
never freezes Zit. Git LFS works as it does on the command line.
