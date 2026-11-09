# Testing strategy

The tests exist to show that what users rely on keeps working, including after `darwin-rebuild switch` installs a new release over an existing setup. They test behaviour that a user or rclone can observe rather than how the code is arranged, so refactoring should not require changing them.

## What the tests protect

- **What the menu says.** The status, its reason, the fix offered under Needs attention, whether Sync Now and Resync are available, Recent Activity, and the version row.
- **When the app notifies.** Only scheduled syncs notify, and only once per problem. A notification names the problem, offers only buttons that cannot lose files, and the first success after a notified problem says syncing works again.
- **Failures.** A sync fails; rclone is missing, removed, or replaced by another install; the external drive is unmounted; settings.json or a state file cannot be read or saved; no sync has worked for 25 minutes. Each failure is followed through to recovery.
- **Safety.** Nothing changes on disk or in OneDrive until setup's first sync is confirmed. Only one rclone runs at a time. Scheduled syncs never resync and always check access. Folders that would sync too much are refused.
- **Fiddly details.** Folder paths with trailing slashes, `..`, spaces, `%`, and non-ASCII names. Paths under `/Volumes`. Finding rclone through Nix profile symlinks and `PATH`. Reading rclone's output: only the end is kept, the reason names the problem (from real rclone output in `RcloneOutput`) or falls back to the first ERROR line, colour codes are turned off, errors are listed first, a success is summarised from rclone's stats, and the sign-in link is extracted. The JSON files in Application Support.
- **Deployment.** The nix-darwin module, the release zip installed by the Nix package, and the installed app running from the read-only Nix store with a login item's environment.

## Layers

| Layer | Tests | What it checks | Runs |
| --- | --- | --- | --- |
| Rules | `SyncDomainTests`, `PathHandlingTests`, `MenuTests` | Pure functions, usually as tables with `@Test(arguments:)`: health, activity, paths, menu text, SF Symbol names | `swift test` |
| rclone contract | `RcloneProcessRunnerTests`, runner tests in `SyncDomainTests` | Real processes, with shell scripts standing in for rclone: arguments, `RCLONE_CONFIG`, exit codes, signals, timeouts, cancellation, output limits, launch failures | `swift test` |
| Scenarios | `FailureScenarioTests`, `SyncCoordinatorTests`, `SetupModelTests` | `SyncCoordinator` and `SetupModel` with fakes for rclone, timers, clock, network, notifications, and the login item; each test is one situation from cause to recovery | `swift test` |
| Upgrades | `PersistedFormatTests` | JSON written by released versions still decodes, and so does `docs/settings.example.json` | `swift test` |
| Nix module | `nix/tests/flake.nix` | `darwinModules.default` evaluates inside real nix-darwin, installs the configured release from the URL CI publishes, and installs nothing when disabled | CI on Linux: `nix eval ./nix/tests#moduleChecks` |
| Packaged app | `scripts/smoke-test-app.sh` | The release build, zipped and installed by `nix/package.nix`, launched from `/nix/store` through Launch Services with a throwaway home, rclone from nixpkgs in `~/.nix-profile`, and a fake OneDrive. Checks: settings created on first launch, skipped syncs without rclone, a failing first sync that asks for a resync, syncing both ways, and rclone removed while running | CI on macOS for every pull request, and again on the exact zip before each release |
| Manual | [testing-with-fake-onedrive.md](testing-with-fake-onedrive.md) | How the menu and setup window look, and how notifications appear. On a real Mac only: Microsoft sign-in, and the login item across a Nix upgrade | Before releases that change them |

The SwiftUI views are not unit tested. Logic in a view that decides what the user sees moves into a function that can be tested, as `MenuBarView.fix(for:transcriptLines:)` does.

## Writing tests

| Change | Where to test it |
| --- | --- |
| New or changed menu text or logic | `MenuTests`, or a scenario test when it depends on state over time |
| New failure mode or recovery | `FailureScenarioTests`: one test from cause to recovery, asserting the status, Recent Activity, notifications, and files |
| New rclone argument, or parsing of its output | `RcloneProcessRunnerTests`. If the argument affects bisync's state, also update the resync in `scripts/smoke-test-app.sh` |
| New or changed field in a persisted file | Add a new fixture to `PersistedFormatTests`; never edit an existing one |
| Module or package change | `nix/tests/flake.nix` |

- Write expected values as literals that you worked out yourself, not values computed by the code under test.
- Choose inputs where a plausible mistake gives a different answer, such as `onedrive-work:` next to `onedrive:`, or `~/LibraryBackup` next to `~/Library`.
- Layers above the rclone contract never sleep or wait for real time. Use `ManualScheduler`, `TestClock`, and `FakeRcloneRunner`.
- Record a known bug with `withKnownIssue("what is wrong")` around the expectations it breaks. The suite passes and lists the issue. Once the bug is fixed, the test fails until the wrapper is removed.

## Commands

```sh
swift test                                   # layers 1 to 4, on a Mac
nix eval --json ./nix/tests#moduleChecks     # the Nix module, on any system with Nix

# The packaged app, on a Mac with Nix (CI, or the Amp macOS Satellite):
hash="$(scripts/build-release.sh 0.0.0 | tail -n 1)"
app="$(scripts/check-nix-package.sh 0.0.0 "$hash" | tail -n 1)"
CI=true RCLONE="$(nix build --no-link --print-out-paths 'nixpkgs#rclone^out')/bin/rclone" scripts/smoke-test-app.sh "$app"
```

The smoke test registers the app as a login item, so it refuses to run unless `CI=true`. Do not run it on a Mac you use.

To find untested code, generate a coverage report. Use it to look for gaps, not as a target:

```sh
swift test --enable-code-coverage
xcrun llvm-cov report .build/out/Products/Debug/OneDriveRcloneMenubarTests.xctest/Contents/MacOS/OneDriveRcloneMenubarTests \
  -instr-profile .build/debug/codecov/default.profdata -ignore-filename-regex='Tests/|\.build/'
```
