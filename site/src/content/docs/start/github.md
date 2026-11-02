---
title: Connect GitHub
description: Sign Zit in to GitHub with a code, see pull requests, checks and issues next to the graph — or switch GitHub off entirely.
---

GitHub is built into Zit, and optional. Once connected, pull requests, reviews,
checks and issues sit next to the graph. Switched off, Zit never talks to
GitHub.

## Connect

1. Open **Settings › GitHub** (`Ctrl+,`).
2. Choose **Connect GitHub**. Zit shows a code and opens github.com.
3. Type the code there and approve Zit.

Nothing else to install, and no token to paste.

## What you get

- **Pull requests in full:** files, commits, checks, reviews and threads.
- **Act on them:** create, check out, review, comment, approve, merge and
  auto-merge.
- **Checks:** re-run the failed ones.
- **Issues:** browse them beside the code.

## Your token

Zit asks GitHub for the `repo` and `read:org` scopes, so it can read and act on
the repositories you can see. The token GitHub gives back is stored in Zit's
config folder, readable by you alone, and is only ever sent to
`api.github.com`.

- **Disconnect** in Settings › GitHub deletes it from your computer.
- You can revoke Zit's access at any time on
  [github.com/settings/applications](https://github.com/settings/applications).

## Switch GitHub off

Turn **Use GitHub** off in Settings › GitHub. Pull requests, issues and checks
go away everywhere, author pictures come from Gravatar alone, and Zit sends
nothing to GitHub. Your remotes are untouched: fetch, pull and push go through
your own `git` either way.

See the [privacy policy](/project/privacy/) for everything Zit stores and who
it talks to.
