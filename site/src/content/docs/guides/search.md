---
title: Search the history
description: Find a commit by its message, author, hash, date, the files it touched or the code it added or removed.
---

`Ctrl+F` opens the search over the graph. Type words, `key:value` parts, or
both: a commit is shown when **every part matches**. Letters match whatever
their case.

## A bare word

A word on its own looks in the three things anybody has in hand when they come
looking for a commit:

- the commit's message (its first line),
- its author's name,
- the start of its hash.

## Keys

| Part | Matches the commits… |
| --- | --- |
| `author:ann` | whose author's name or email contains `ann` |
| `msg:fix` or `message:fix` | whose message contains `fix` |
| `sha:4c45` | whose hash starts with `4c45` |
| `after:2026-10-01` | made on that day or later |
| `before:2026-10-01` | made before that day |
| `path:src/` | that changed something under that path |
| `code:needle` | that added or removed `needle` |

Put a value with spaces in double quotes: `author:"Ann Lee"`.

### Dates

`after:` and `before:` take a day, `2026-10-22`, or a month, `2026-10`, or a
year, `2026`. A date that does not read as one yet — half typed, or
`2026-02-31` — is left out of the search rather than hiding everything.

### Paths and code

`path:` and `code:` are answered by your `git`: `git log` with that pathspec,
or with that string as its pickaxe (`-S`). They run on another thread while you
type, and match nothing until git's answer is back. Git combines several paths
with an *or*, and takes only one pickaxe, so a search holds one `path:` and one
`code:` at most.

## Examples

```text
fix author:"Ann Lee" after:2026-10-01 path:src/
```

Ann Lee's commits since the first of October 2026 that touched `src/` and
have "fix" in their message.

```text
code:parseQuery before:2026
```

The commits made before 2026 that added or removed `parseQuery`.
