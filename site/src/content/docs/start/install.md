---
title: Install Zit
description: Download Zit for Windows or Linux, or build it from source with Zig 0.16.
---

## Download

Get the latest build from
[**Releases**](https://github.com/DamienMonchaty/zit/releases/latest):

| Platform | File |
| --- | --- |
| Windows 10 and later (x86_64) | `zit-windows-x86_64.exe` — run it, nothing to install |
| Linux (x86_64, glibc 2.31+) | `zit-linux-x86_64.tar.gz` — unpack, then `./install.sh` |

Each release comes with a `SHA256SUMS` file. Check a download against it with:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

### Linux

The archive holds Zit, its icons, its menu entry and `install.sh`, which puts
them in `~/.local`:

```sh
tar xf zit-linux-x86_64.tar.gz
./install.sh            # Zit, its icons and its menu entry, in ~/.local
./install.sh --remove   # takes them out again
```

Nothing else comes from the system: Zit loads X11 or Wayland itself.

### Windows

`zit-windows-x86_64.exe` is the whole application. Put it where you like and
run it.

## What Zit needs

- **`git` on the `PATH`.** Zit runs it for everything that writes — commits,
  checkouts, merges, fetches, pushes — so your hooks, credential helpers, SSH
  agent and signing keep working as they do on the command line.
- **`curl`, optionally.** It brings the author pictures and the
  [GitHub integration](/start/github/). Without it everything else works, and
  each commit shows its author's initials.

## Open a repository

Run Zit with a folder to open it:

```sh
zit /path/to/a/repository
```

With no argument, Zit opens the repository containing the current folder,
searching upward like `git` does. From inside Zit, `Ctrl+T` opens a new tab
where you can open, clone or create a repository, and every one a tab has held
is one click away. Open tabs come back the next time Zit starts.

## Build from source

Zit builds with [Zig 0.16](https://ziglang.org/download/). libgit2 and SDL are
built along with it, so nothing else needs installing.

```sh
git clone https://github.com/DamienMonchaty/zit.git
cd zit
zig build                       # ReleaseSafe by default
./zig-out/bin/zit /path/to/a/repository
```

To make the release files for every platform from one machine:

```sh
zig build dist   # zig-out/dist: Linux (.tar.gz) and Windows (.exe)
```

More build options — a system libgit2, keeping the symbols, running the tests —
are in [Under the hood](/project/under-the-hood/).
