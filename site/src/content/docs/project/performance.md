---
title: Performance
description: How fast Zit opens a repository, how much memory it keeps, and how every number is measured again.
---

Measured on Linux with the build that is released (ReleaseSafe), on an Intel
Core Ultra 7 155H laptop. Zit shows the 5,000 most recent commits of a
repository.

| | A 3,866-commit project | [git/git](https://github.com/git/git) — 85,906 commits |
| --- | --- | --- |
| Read the history (open a repository) | 0.10 s | 0.99 s |
| Lay out the graph | 0.9 ms | 7 ms |
| Read the working tree's status | 5 ms | 16 ms |
| Memory, once settled | 58 MB | 79 MB |
| CPU while idle | 0.2 % | 0 % |

| Download | Size |
| --- | --- |
| Linux x86_64 (`.tar.gz`) | 3.2 MB |
| Windows x86_64 (`.exe`) | 7.3 MB |

## Why it stays light

- **Frames only when something changes.** An idle window draws nothing, so it
  costs nothing.
- **Watching, not polling.** On Linux, nothing is read again until the system
  says a file changed; a 30-second poll is the net under it.
- **Reads through libgit2.** A revwalk beats parsing `git log`. Writes go
  through your `git`, so they behave exactly as on the command line.
- **No runtime.** One executable, drawn on the GPU, its fonts cut down to the
  scripts and symbols the interface uses.

## Ceilings

Checked before every delivery, on a repository of a few thousand commits opened
in a fresh window and left alone. `tools/measure.sh` fails when one is over.

| What | Ceiling |
| --- | --- |
| Memory (RSS), settled | 64 MB |
| Peak memory, start-up included | 96 MB |
| Zit's own memory (Private_Dirty) | 40 MB |
| CPU while idle, window focused | 0.5 % — the goal is 0 |

## Measure it yourself

```sh
zig build bench -- /path/to/a/repository     # history, graph, status, diffs
tools/measure.sh zig-out/bin/zit /path/to/a/repository   # memory and idle CPU, on Linux
```

`zig build bench` times each step with no window — the median of up to 200
runs — and compares two builds with `--save` and `--vs`. The method, every
benchmark and what was tried and did not work are in
[docs/PERF.md](https://github.com/DamienMonchaty/zit/blob/main/docs/PERF.md).
