# Privacy policy

*Last updated: 29 October 2026*

Zit is a desktop application. It runs entirely on your computer: there is no
Zit server, no account with us, and no analytics, telemetry or crash reports.
We never receive your code, your repositories or anything about you.

## What Zit keeps on your computer

| What | Where |
| --- | --- |
| Open tabs and settings | `~/.config/zit/workspace.json` (Linux), `%APPDATA%\zit\workspace.json` (Windows) |
| Your GitHub token and login, once you connect | `github-auth` and `github-user` in the same folder. On Linux the files are readable by your user alone |
| Author pictures | `~/.cache/zit/avatars` (Linux), `%LOCALAPPDATA%\zit\avatars` (Windows) |

Deleting these folders removes everything Zit has stored.

## Who Zit talks to

Zit only makes the network requests needed for what you see on screen:

- **Your Git remotes**, through your own `git`, when you fetch, pull or push.
  Your existing Git credentials are used; Zit does not see them.
- **GitHub** (`github.com`, `api.github.com`, `avatars.githubusercontent.com`),
  only while **Settings › GitHub › Use GitHub** is on: to sign in, to show and
  act on pull requests, issues and checks, and to find the GitHub account
  behind a commit for its author picture. Requests go straight from your
  computer to GitHub with your token, and are covered by the
  [GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
- **Gravatar** (`www.gravatar.com`), for author pictures: Zit asks for the
  picture of the MD5 hash of each commit author's email address, as Gravatar
  requires. Covered by [Automattic's privacy policy](https://automattic.com/privacy/).

With **Use GitHub** off, Zit sends nothing to GitHub.

## Your GitHub token

Zit asks GitHub for the `repo` and `read:org` scopes, so it can read and act
on the repositories you can see. The token is only ever sent to GitHub. Choose
**Disconnect** in Settings › GitHub to delete it from your computer, and revoke
Zit's access at any time on
[github.com/settings/applications](https://github.com/settings/applications).

## Contact

Questions about this policy: [open an issue](https://github.com/DamienMonchaty/zit/issues).
