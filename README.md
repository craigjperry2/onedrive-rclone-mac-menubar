# OneDrive Rclone Menubar

A macOS 26 SwiftUI menu-bar app for a locally configured OneDrive `rclone bisync` mirror.

It runs a normal sync every ten minutes, shows whether the latest run is healthy, and keeps the final 30 lines of the latest run available from the menu. It does not create OneDrive credentials or edit `rclone.conf`.

## Setup

1. Install rclone and complete OneDrive setup outside this app.
2. Open `OneDriveRcloneMenubar.xcodeproj` in Xcode and run the `OneDriveRcloneMenubar` scheme. The app bundle is an agent application, so it lives in the menu bar rather than the Dock and can register itself as a login item. `swift run` remains useful for quick development checks, but does not provide the app-bundle behavior.
3. Edit the generated Application Support `settings.json` file with the absolute rclone executable path, rclone config path, OneDrive remote name, and local mirror path. The current Nix-installed rclone binary is the value to use for `rcloneExecutablePath` on this host.
4. Let macOS approve launch at login if prompted.

The app remains disabled and explains why until the executable, configuration file, and remote are valid.

## Migration from the Nix launch agent

Disable `homeNetwork.onedriveRclone` before relying on this app's automatic schedule. Running both schedulers can start competing `rclone bisync` processes against the same mirror.

## Recovery

Use **Sync Now** for an ordinary immediate run. Use **Resync** only for initialization or recovery after rclone requires it. The app asks for confirmation because `rclone bisync --resync` can overwrite files according to rclone's recovery mode.

## Development

Run `swift test` to execute the state, storage, and transcript tests.
