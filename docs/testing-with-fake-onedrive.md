# Testing with a fake OneDrive

To test the app without OneDrive credentials, point it at an rclone `alias` remote named `onedrive` that wraps a local directory. The app then runs `rclone bisync` between two local directories, using its normal bisync arguments; the OneDrive-only flags such as `--onedrive-delta` have no effect.

Use this only on a test machine, such as the Amp macOS Satellite. The setup script refuses to replace a `settings.json` that points at a real rclone config.

## Set up

```sh
brew install rclone
scripts/setup-fake-onedrive.sh            # default root: ~/onedrive-fake
```

The script creates:

| Path | Purpose |
| --- | --- |
| `~/onedrive-fake/remote/` | The fake OneDrive, seeded with `hello-from-fake-onedrive.txt` |
| `~/onedrive-fake/local/` | The local mirror |
| `~/onedrive-fake/rclone.conf` | `[onedrive]` with `type = alias` and `remote = ~/onedrive-fake/remote` |
| `~/Library/Application Support/OneDriveRcloneMenubar/settings.json` | App settings pointing at the paths above |

It also writes `RCLONE_TEST` to both sides, which the app's `--check-access` requires. Rerunning the script is safe.

## Run a sync

1. Build and launch the app (see the README). After validation, the menu bar icon is the clock (Waiting for first sync).
2. Choose **Resync…** and confirm. bisync needs one resync before ordinary runs; until then, **Sync Now** fails with "Bisync aborted" and the icon becomes a warning triangle. After the resync, `hello-from-fake-onedrive.txt` appears in `local/` and the icon becomes a check mark (Healthy).
3. Change a file on either side, choose **Sync Now**, and check that it appears on the other side.

The app writes its state to `~/Library/Application Support/OneDriveRcloneMenubar/`: `run-state.json` records each run's `outcome`, and `latest-run.log` holds rclone's output, which is empty after a successful run because rclone logs nothing at its default level. To start again from nothing, quit the app, delete `~/onedrive-fake`, `run-state.json`, `latest-run.log`, and `~/Library/Caches/rclone/bisync`, then rerun the script.

## Guided setup

`scripts/setup-fake-onedrive.sh --guided` prepares the fake OneDrive but leaves the app unconfigured, so you can run **Set Up OneDrive…** end to end. It writes `settings.json` with an empty `localPath`, points `configPath` at `~/onedrive-fake/rclone.conf` (not created yet), and sets `rcloneExecutablePath` to a wrapper, `~/onedrive-fake/bin/rclone`, that stands in for the Microsoft sign-in:

- `rclone config create onedrive onedrive` prints what rclone prints, including the sign-in link, and waits.
- `touch ~/onedrive-fake/approve` acts as a completed sign-in: the wrapper creates the `onedrive` alias remote and exits.
- `touch ~/onedrive-fake/deny` acts as a refused sign-in: the wrapper exits with an error.
- Every other command goes to the real rclone.

To start from nothing, quit the app and delete `~/onedrive-fake`, the folder you chose in setup, the files in `~/Library/Application Support/OneDriveRcloneMenubar/`, and `~/Library/Caches/rclone/bisync`. In the folder picker, **Cmd-Shift-G** opens a path field; a synthetic Return does not confirm it, but double-clicking the suggested path does.

Only the browser step needs a real Microsoft account. On a real Mac, check that **Sign In with Microsoft…** opens the browser, that signing in creates a `onedrive` remote of type `onedrive` in `~/.config/rclone/rclone.conf`, and that the first sync succeeds against it.

## Driving the menu from a shell (Amp macOS Satellite)

Synthetic clicks open the status item's menu and select its items. Install `cliclick` with `brew install cliclick`.

- `cliclick` takes points. The display is 1280×800 points (2560×1600 pixels). Full-screen screenshots are shown to agents downscaled, so do not read coordinates from them. Capture a region with `screencapture -x -R 680,0,600,400 out.png` instead: each image pixel is half a point, so a point is `680 + px/2, py/2`.
- When it is the only extra status item, the app's icon is at about `1038,13`. Menu rows move with the app's state (the reason and last-success rows come and go), so take a screenshot of the open menu before clicking a row.
- Click the icon again to close the menu; a synthetic Esc does not close it. Do not click the wallpaper: macOS hides all windows to show the desktop. `defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false; killall WindowManager` turns that off.
- The Resync confirmation is an ordinary window, so you can click its **Resync** button. Cancel is the default button.
- Do not use `osascript` with System Events UI scripting: its accessibility queries hang on the Satellite.
- `mac_read_file` and `mac_download` sometimes report "No such file or directory" for a file that was just written; retry once. Use a new file name for each screenshot and pass paths under `/private/tmp` rather than `/tmp`, because reusing a path can return an earlier image.
