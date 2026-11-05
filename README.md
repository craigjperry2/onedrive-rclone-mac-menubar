# OneDrive Rclone Menubar

A macOS 26 SwiftUI menu-bar app for a locally configured OneDrive `rclone bisync` mirror.

It runs a normal sync every ten minutes, shows whether the latest run is healthy, and keeps the final 30 lines of the latest run available from the menu. It does not create OneDrive credentials or edit `rclone.conf`.

## Setup

1. Install rclone, for example with `brew install rclone` or from Nix, and complete OneDrive setup in rclone outside this app.
2. Install the app with nix-darwin (below), or open `OneDriveRcloneMenubar.xcodeproj` in Xcode and run the `OneDriveRcloneMenubar` scheme. The app bundle is an agent application, so it lives in the menu bar rather than the Dock and registers itself as a login item. `swift run` remains useful for quick development checks, but does not provide the app-bundle behavior.
3. Edit the generated Application Support `settings.json` file with the rclone config path, OneDrive remote name, and local mirror path (see [docs/settings.example.json](docs/settings.example.json)). Leave `rcloneExecutablePath` empty: the app finds rclone in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.nix-profile/bin`, `/etc/profiles/per-user/$USER/bin`, `/run/current-system/sw/bin`, and its `PATH`. Set it only to use a different rclone; if that path stops working, for example after a Nix garbage collection, the app falls back to the locations above.
4. If macOS asks you to approve launch at login, or you turn it off later, the menu says the app will not start at login. Choose **Open Login Items Settings…** to allow it.

Until rclone, its configuration file, and the remote are usable, the app stays disabled and its menu explains why: that rclone needs installing, or that the Mac is ready but OneDrive is not configured yet. Changes to `settings.json` or `rclone.conf` take effect within a minute, or as soon as you open the menu.

## Installing with nix-darwin

Each [release](https://github.com/craigjperry2/onedrive-rclone-mac-menubar/releases) is an immutable GitHub release whose notes give its version and the hash of its zip. Add this repository's flake to your nix-darwin configuration, import its module, and pin a release:

```nix
{
  inputs.onedrive-menubar.url = "github:craigjperry2/onedrive-rclone-mac-menubar";

  outputs = { nix-darwin, onedrive-menubar, ... }: {
    darwinConfigurations.my-mac = nix-darwin.lib.darwinSystem {
      modules = [
        onedrive-menubar.darwinModules.default
        {
          programs.onedrive-rclone-menubar = {
            enable = true;
            version = "0.1.0";
            hash = "sha256-…"; # from the release notes
          };
        }
      ];
    };
  };
}
```

`darwin-rebuild switch` installs the app in `/Applications/Nix Apps`. To upgrade, copy the new `version` and `hash` from the release notes, switch, then quit and relaunch the app; the running copy stays on the old version until then. The menu shows the running version.

Release builds are ad-hoc signed rather than notarized. Nix downloads carry no quarantine attribute, so Gatekeeper doesn't block them, but macOS may ask again for permissions such as removable-volume access after an upgrade, because each build has a new code identity.

## Migration from the Nix launch agent

Disable `homeNetwork.onedriveRclone` before relying on this app's automatic schedule. Running both schedulers can start competing `rclone bisync` processes against the same mirror.

## Recovery

Use **Sync Now** for an ordinary immediate run. Use **Resync** only for initialization or recovery after rclone requires it. The app asks for confirmation because `rclone bisync --resync` can overwrite files according to rclone's recovery mode.

## Development

Run `swift test` to execute the tests. `SyncCoordinator` takes its rclone runner, schedulers, wake notifications, login-item registration, and clock as parameters, so its tests use fakes and never launch rclone or wait for real time.

To exercise real syncs without OneDrive, run `scripts/setup-fake-onedrive.sh` on a test machine. It configures the app against a fake OneDrive made of local directories; see [docs/testing-with-fake-onedrive.md](docs/testing-with-fake-onedrive.md).

### Releases

Every merge to `main` that passes CI publishes a release, except merges that only touch `docs/` or Markdown files. Pull request titles must be conventional commits, because the squash commit subject picks the version: `feat` or a breaking `!` bumps the minor number, and anything else bumps the patch number. Automation never changes the major number; it comes from `MAJOR_VERSION`, so merge a change that raises it by one to start the next major at `N.0.0`. Run `scripts/test-next-version.sh` after changing the version logic.
