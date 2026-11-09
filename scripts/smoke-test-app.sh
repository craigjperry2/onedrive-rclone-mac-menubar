#!/usr/bin/env bash
# Launches an installed app bundle, such as the Nix package's read-only
# /nix/store/...-onedrive-rclone-menubar-VERSION/Applications/OneDriveRcloneMenubar.app,
# through Launch Services as a login item would be, and checks what the user
# would see through the files the app keeps in Application Support.
#
# Each scenario gets a throwaway home folder (CFFIXED_USER_HOME, which the app's
# Application Support and home lookups follow), a fake OneDrive made of local
# directories, and the rclone named by $RCLONE (default: rclone on PATH) linked
# into the throwaway ~/.nix-profile/bin, as a Nix profile install would. Settings
# leave rcloneExecutablePath empty, so the app must find rclone by itself.
#
# Launching the app registers it as a login item, so this refuses to run outside
# CI. On a test machine such as the Amp macOS Satellite, set CI=true.
#
# Usage: [RCLONE=/path/to/rclone] scripts/smoke-test-app.sh APP
set -euo pipefail

app="${1:?usage: scripts/smoke-test-app.sh APP}"
app="$(cd "$app" && pwd -P)"
executable="$app/Contents/MacOS/OneDriveRcloneMenubar"
rclone="${RCLONE:-$(command -v rclone || true)}"
[[ "${CI:-}" == "true" ]] || { echo "Refusing to launch the app outside CI; it registers a login item. Set CI=true on a test machine." >&2; exit 1; }
[[ -x "$executable" ]] || { echo "$app is not an app bundle." >&2; exit 1; }
[[ -x "$rclone" ]] || { echo "rclone not found; set RCLONE." >&2; exit 1; }
pgrep -qf "$executable" && { echo "The app is already running from $app." >&2; exit 1; }

home=""
cleanup() {
  pkill -f "$executable" 2>/dev/null || true
  if [[ -n "$home" ]]; then rm -rf "$home"; fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  for file in settings.json run-state.json activity.json latest-run.log; do
    if [[ -f "$support/$file" ]]; then echo "--- $file" >&2; cat "$support/$file" >&2; echo >&2; fi
  done
  exit 1
}

# Waits up to 60 seconds for a shell condition.
wait_for() {
  local description="$1" condition="$2"
  for _ in $(seq 120); do
    eval "$condition" && return 0
    sleep 0.5
  done
  fail "timed out waiting until $description"
}

json() { plutil -extract "$2" raw -o - "$support/$1" 2>/dev/null; }

new_home() {
  cleanup
  home="$(mktemp -d /private/tmp/onedrive-smoke.XXXXXX)"
  support="$home/Library/Application Support/OneDriveRcloneMenubar"
  fake="$home/onedrive-fake"
  mkdir -p "$support" "$fake/remote" "$fake/local"
  printf '[onedrive]\ntype = alias\nremote = %s\n' "$fake/remote" > "$fake/rclone.conf"
  touch "$fake/remote/RCLONE_TEST" "$fake/local/RCLONE_TEST"
  echo "from OneDrive" > "$fake/remote/from-remote.txt"
}

install_nix_profile_rclone() {
  mkdir -p "$home/.nix-profile/bin"
  ln -sf "$rclone" "$home/.nix-profile/bin/rclone"
}

write_settings() {
  cat > "$support/settings.json" <<EOF
{"rcloneExecutablePath": "", "configPath": "$fake/rclone.conf", "remoteName": "onedrive", "localPath": "$fake/local", "intervalSeconds": 2}
EOF
}

launch() {
  open -n -g --env "CFFIXED_USER_HOME=$home" --env "HOME=$home" "$app"
  wait_for "the app is running" 'pgrep -qf "$executable"'
}

quit() {
  pkill -f "$executable" || true
  wait_for "the app has quit" '! pgrep -qf "$executable"'
  # rclone outlives the app; let it finish so it releases bisync's lock.
  wait_for "rclone has finished" '! pgrep -qf "$fake/local"'
}

# Where the app looks for rclone outside the home folder. Scenarios about a
# missing rclone only mean something when none of these has one.
system_rclone=""
for dir in /opt/homebrew/bin /usr/local/bin "/etc/profiles/per-user/$USER/bin" /run/current-system/sw/bin \
  /nix/var/nix/profiles/default/bin /usr/bin /bin /usr/sbin /sbin; do
  if [[ -x "$dir/rclone" ]]; then system_rclone="$dir/rclone"; fi
done

echo "== First launch creates settings from the template"
new_home
rm -rf "$support"
launch
wait_for "settings.json exists" '[[ -f "$support/settings.json" ]]'
[[ "$(json settings.json rcloneExecutablePath)" == "" ]] || fail "the template names an rclone path"
[[ "$(json settings.json localPath)" == "" ]] || fail "the template names a local folder"
quit

if [[ -n "$system_rclone" ]]; then
  echo "== Skipping the missing-rclone scenario: $system_rclone exists"
else
  echo "== Without rclone, scheduled syncs are skipped and say why"
  new_home
  write_settings
  launch
  wait_for "a skipped sync is recorded" '[[ "$(json activity.json entries.0.outcome.skipped._0)" == setupRequired ]]'
  [[ ! -f "$support/run-state.json" ]] || fail "a sync ran without rclone"
  quit
fi

echo "== A first sync before any resync fails and says a resync is needed"
new_home
install_nix_profile_rclone
write_settings
launch
wait_for "a failed run is recorded" '[[ "$(json run-state.json outcome)" == failure ]]'
[[ -n "$(json run-state.json failureReason)" ]] || fail "the failed run has no reason"
grep -qiE 'must run --resync|cannot find prior Path1 or Path2 listings' "$support/latest-run.log" \
  || fail "latest-run.log does not say a resync is needed"
[[ "$(json activity.json entries.0.outcome.failed.reason)" != "" ]] || fail "Recent Activity does not record the failure"
quit

echo "== After a resync, scheduled syncs copy changes both ways"
# The resync guided setup runs, with the flags of RcloneProcessRunner.run.
HOME="$home" "$rclone" --config "$fake/rclone.conf" bisync onedrive: "$fake/local" \
  --check-access --create-empty-src-dirs "--exclude=/Personal Vault/**" \
  --modify-window 2s --resilient --fast-list --onedrive-delta --resync >"$home/resync.log" 2>&1 \
  || fail "rclone bisync --resync failed: $(cat "$home/resync.log")"
rm -f "$support/run-state.json"
echo "from this Mac" > "$fake/local/from-mac.txt"
echo "changed in OneDrive" > "$fake/remote/from-remote.txt"
launch
wait_for "a successful run is recorded" '[[ "$(json run-state.json outcome)" == success ]]'
wait_for "the local file reaches OneDrive" '[[ -f "$fake/remote/from-mac.txt" ]]'
[[ "$(cat "$fake/local/from-remote.txt")" == "changed in OneDrive" ]] || fail "the OneDrive change did not reach the local folder"

if [[ -n "$system_rclone" ]]; then
  echo "== Skipping the removed-rclone scenario: $system_rclone exists"
else
  echo "== When rclone disappears, scheduled syncs stop and say why"
  rm "$home/.nix-profile/bin/rclone"
  wait_for "a skipped sync is recorded" 'grep -q configurationUnusable "$support/activity.json"'
fi
pgrep -qf "$executable" || fail "the app quit unexpectedly"
quit

echo "Smoke test passed for $app"
