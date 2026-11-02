# Contributing to Zit

Thank you for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or suggesting an idea

Open an [issue](https://github.com/DamienMonchaty/zit/issues/new/choose) and
pick **Bug** or **Idea**. For a security problem, follow [SECURITY.md](SECURITY.md)
instead.

## Building

You need [Zig 0.16](https://ziglang.org/download/) and `git`. libgit2 and SDL
are built along with Zit.

```sh
zig build                              # zig-out/bin/zit
zig build run -- /path/to/a/repository
```

More options (release builds, cross-compiling, a system libgit2) are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Testing

```sh
SDL_VIDEODRIVER=dummy zig build test
SDL_VIDEODRIVER=dummy zig build test -Dtest-filter="part of a test name"
```

The dummy video driver lets the interface tests run without a display. Please
add a test with every fix and feature: the smallest one that fails without
your change.

If your change touches memory or speed, measure it as described in
[docs/PERF.md](docs/PERF.md).

## The website

The site at [damienmonchaty.github.io/zit](https://damienmonchaty.github.io/zit/)
is in `site/`, built with Astro Starlight; it needs Node 22.23 or later.

```sh
cd site && npm install
npm run dev   # http://localhost:4321/zit/
```

Its pages are in `site/src/content/docs/`. The changelog, this guide and the
privacy and security policies are shown there as they are written here, so
they are edited in one place. The site is published from `main`, with each
release.

## Branches and pull requests

- `develop` is where work happens. Branch from it, and open your pull request
  **against `develop`**.
- `main` holds what is released. It only changes through a pull request from
  `develop`, and each merge into `main` becomes a release.

Keep a pull request to one change, describe what it does and how you tested
it, and match the style of the code around it.

## Releasing

1. On `develop`, check the ceilings in [docs/PERF.md](docs/PERF.md) the way
   its *Method* measures them, and write down what moved:
   - `tools/measure.sh` on a copy of a repository of a few thousand
     commits: RSS, peak RSS, Private_Dirty and idle CPU, each under its
     ceiling — the script fails when one is over;
   - `zig build bench` against the last release's numbers, `--vs`;
   - a Debug build (`-Doptimize=Debug`) used for a minute on a real
     repository: its stack traces and its leak report at exit reach what
     the tests do not.
2. Set the new version in `build.zig.zon` (the app reads it from there)
   and in `assets/zit.manifest` (as `0.1.2.0`), and add its section to
   `CHANGELOG.md`.
3. Merge `develop` into `main` through a pull request.
4. Tag the merge and push the tag:
   ```sh
   git switch main && git pull
   git tag v0.1.2 && git push origin v0.1.2
   ```
   The **Release** workflow builds Windows and Linux, writes `SHA256SUMS`
   and publishes the release with that version's changelog.

Every push and pull request runs the **CI** workflow: the Linux build and
the whole test suite; the suite again built ReleaseFast, without the
safety checks — undefined behaviour ReleaseSafe traps on runs on there and
shows as a wrong answer or a crash; and the Windows build. `main` only
accepts a pull request once they pass.

## License

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE).
