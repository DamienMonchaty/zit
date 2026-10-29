# Changelog

Every release of Zit, newest first. Downloads are on the
[Releases](https://github.com/DamienMonchaty/zit/releases) page.

## Unreleased

### Fixed
- The text of a one-line field is centred in it, instead of sitting near its top.
- In the sidebar, a branch's name is centred on its row, level with the eye and
  the ⋯.
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

[0.1.1]: https://github.com/DamienMonchaty/zit/releases/tag/v0.1.1
[0.1.0]: https://github.com/DamienMonchaty/zit/releases/tag/v0.1.0
