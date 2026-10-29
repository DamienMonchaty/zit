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

## Branches and pull requests

- `develop` is where work happens. Branch from it, and open your pull request
  **against `develop`**.
- `main` holds what is released. It only changes through a pull request from
  `develop`, and each merge into `main` becomes a release.

Keep a pull request to one change, describe what it does and how you tested
it, and match the style of the code around it.

## Releasing

1. On `develop`, set the new version in `build.zig.zon` and `APP_VERSION` in
   `src/main.zig`, and add its section to `CHANGELOG.md`.
2. Merge `develop` into `main` through a pull request.
3. Tag the merge and push the tag:
   ```sh
   git switch main && git pull
   git tag v0.1.2 && git push origin v0.1.2
   ```
   The **Release** workflow builds Windows and Linux, writes `SHA256SUMS`
   and publishes the release with that version's changelog.

Every push and pull request runs the **CI** workflow: the Linux build and
the whole test suite, and the Windows build. `main` only accepts a pull
request once both pass.

## License

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE).
