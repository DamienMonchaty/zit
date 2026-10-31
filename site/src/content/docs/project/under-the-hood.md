---
title: Under the hood
description: How Zit is built — libgit2 for reads, your git for writes, dvui on SDL3 — and how to build and test it.
---

## Reads and writes

Reads go through **libgit2**: a revwalk beats parsing `git log`. Writes, and
anything that talks to a remote, go through the **`git` binary**, so they
behave exactly as on the command line — credential helpers, the SSH agent,
hooks and GPG signing all work as they already do.

A command that talks to a remote runs on another thread, so a slow fetch never
freezes the window.

## The interface

The UI is [dvui](https://github.com/david-vanderson/dvui) on SDL3, set in Inter
and JetBrains Mono. Zit draws its own window frame: the tab strip takes the
title bar's place. On Linux it asks SDL for its GPU renderer, then Vulkan, then
OpenGL. The dark and light palettes are authored in `src/theme/` and compiled
in.

## Build

```sh
zig build                          # needs Zig 0.16.0; libgit2 is built from source
zig build run -- /path/to/repo
zig build dist                     # release executables in zig-out/dist/
```

| Option | Does |
| --- | --- |
| `-Doptimize=Debug` | A debug build: stack traces, leak checks |
| `-Dstrip=false` | Keep the symbols, for a readable stack trace |
| `-Dsystem-libgit2=true` | Link the machine's libgit2, for a quicker local build |

`zig build dist` cross-compiles from any machine with GNU `tar` and `rm` on the
`PATH`.

## Test

```sh
SDL_VIDEODRIVER=dummy zig build test
SDL_VIDEODRIVER=dummy zig build test -Dtest-filter="part of a test name"
```

The dummy video driver lets the interface tests render a frame without a
display. Most of the suite drives the real `git` binary in throwaway
repositories.

The whole story — memory, the watcher, the tab strip, the graph — is in
[docs/ARCHITECTURE.md](https://github.com/DamienMonchaty/zit/blob/main/docs/ARCHITECTURE.md).
