# OneDrive Rclone Menubar

A macOS 26 SwiftUI menu-bar app that keeps a folder on your Mac in sync with OneDrive, using `rclone bisync`.

It runs a normal sync every ten minutes, shows whether the latest run is healthy, and shows rclone's output from the latest run in the menu: errors first, a summary of what a successful run changed, **Open Full Log** to open `latest-run.log` in Console, and **Copy Error Details** to copy a failure, rclone's errors, and the rclone version. Only one rclone process runs at a time. Scheduled syncs are skipped while the Mac is on a Low Data Mode or metered network, such as a phone hotspot, and resume on a normal network; **Sync Now** always runs. Each run and each skipped scheduled sync is recorded with its reason in Application Support `activity.json`, and **Recent Activity** in the menu lists the latest 20, newest first; hover over a sync that needed attention to see what rclone reported. When a scheduled sync fails, stops because its configuration can no longer be used, or has been skipped three times in a row on a low-data network, the app posts one macOS notification, which you can turn off in System Settings > Notifications. A failed sync's notification names the problem and the fix the menu offers; its buttons are **Sync Now**, only when trying again can help, and **Show Log**, which opens rclone's latest output. Clicking the notification opens the menu. Resync and recreating a check file stay in the menu, behind their confirmations. The app does not notify again until the problem clears, and Sync Now and Resync never post problem notifications. After a problem you were notified about, the first sync that succeeds posts one "OneDrive sync is working again" notification.

## Setup

1. Install rclone, for example with `brew install rclone` or from Nix. The app finds it in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.nix-profile/bin`, `/etc/profiles/per-user/$USER/bin`, `/run/current-system/sw/bin`, and its `PATH`.
2. Install the app with nix-darwin (below), or open `OneDriveRcloneMenubar.xcodeproj` in Xcode and run the `OneDriveRcloneMenubar` scheme. The app bundle is an agent application, so it lives in the menu bar rather than the Dock and registers itself as a login item. `swift run` remains useful for quick development checks, but does not provide the app-bundle behavior.
3. Choose **Set Up OneDrive…** from the menu-bar icon and follow the steps:
   - **Sign in with Microsoft.** rclone opens the Microsoft sign-in page in your browser and saves the access it is given as a remote named `onedrive` in rclone's configuration file (`~/.config/rclone/rclone.conf` unless `settings.json` says otherwise). If that remote already exists, setup offers to use it.
   - **Choose a folder** on this Mac for the copy of your OneDrive.
   - **Start the first sync.** Setup explains what the first sync copies before anything changes. It then adds the `RCLONE_TEST` check file to both sides, saves the folder in `settings.json`, and runs `rclone bisync --resync`, so later syncs work without a manual **Resync…**.
4. If macOS asks you to approve launch at login, or you turn it off later, the menu says the app will not start at login. Choose **Open Login Items Settings…** to allow it.

Until setup is finished, or when the configuration stops working, the app is disabled and its menu explains why and what to do. The menu also explains every other state in plain language.

### Configuring by hand

Setup only writes `localPath` in the Application Support `settings.json`. To use an rclone remote you already have, either run setup and continue with the existing remote, or edit `settings.json` yourself (see [docs/settings.example.json](docs/settings.example.json)): `configPath`, `remoteName`, `localPath`, and `intervalSeconds`. Leave `rcloneExecutablePath` empty to use the rclone the app finds; if you set it and that path stops working, for example after a Nix garbage collection, the app falls back to the locations above. A hand-made configuration needs `RCLONE_TEST` on both sides and one **Resync…** before ordinary syncs work. Changes to `settings.json` or `rclone.conf` take effect within a minute, or as soon as you open the menu.

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

When a sync needs attention, the menu names the problem and, when there is one, puts its fix directly below: **Resync…** when rclone lost track of the last sync, or **Recreate Check File…** when `RCLONE_TEST` is missing from OneDrive or your folder. A missing check file can mean rclone is connected to the wrong account or folder, or that files were deleted, so check that side before recreating it; the app asks first and then syncs.

Use **Sync Now** for an ordinary immediate run. Use **Resync** only for initialization or recovery after rclone requires it. The app asks for confirmation because `rclone bisync --resync` can overwrite files according to rclone's recovery mode.

## Development

Run `swift test` to execute the tests. `SyncCoordinator` takes its rclone runner, schedulers, wake notifications, login-item registration, notifier, and clock as parameters, so its tests use fakes and never launch rclone or wait for real time. CI also evaluates the nix-darwin module and smoke tests the app as the Nix package installs it; [docs/testing-strategy.md](docs/testing-strategy.md) describes each kind of test and where a new one belongs.

To exercise real syncs without OneDrive, run `scripts/setup-fake-onedrive.sh` on a test machine. It configures the app against a fake OneDrive made of local directories. With `--guided`, it leaves the app unconfigured and stands in for the Microsoft sign-in, so the whole guided setup can be run except the browser step; see [docs/testing-with-fake-onedrive.md](docs/testing-with-fake-onedrive.md).

### Releases

Every merge to `main` that passes CI publishes a release, except merges that only touch `docs/` or Markdown files. Pull request titles must be conventional commits, because the squash commit subject picks the version: `feat` or a breaking `!` bumps the minor number, and anything else bumps the patch number. Automation never changes the major number; it comes from `MAJOR_VERSION`, so merge a change that raises it by one to start the next major at `N.0.0`. Run `scripts/test-next-version.sh` after changing the version logic.
