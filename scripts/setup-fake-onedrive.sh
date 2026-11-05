#!/usr/bin/env bash
# Point the app at a fake OneDrive: an rclone `alias` remote named `onedrive`
# backed by a local directory, synced with a second local directory. No network
# or credentials are involved. Intended for test machines such as the Amp macOS
# Satellite; see docs/testing-with-fake-onedrive.md.
#
# Usage: scripts/setup-fake-onedrive.sh [--guided] [fake-root]   (default: ~/onedrive-fake)
#
# Without --guided, the script configures everything itself, as a finished setup.
# With --guided, it leaves the app unconfigured and installs a wrapper around
# rclone that stands in for the Microsoft sign-in, so the app's guided setup can
# be run end to end: see "Guided setup" in the doc.
set -euo pipefail

guided=false
if [[ "${1:-}" == "--guided" ]]; then
  guided=true
  shift
fi

fake_root="${1:-$HOME/onedrive-fake}"
remote_dir="$fake_root/remote"
local_dir="$fake_root/local"
config_path="$fake_root/rclone.conf"
wrapper_path="$fake_root/bin/rclone"
settings_dir="$HOME/Library/Application Support/OneDriveRcloneMenubar"
settings_path="$settings_dir/settings.json"

rclone_path="$(command -v rclone || true)"
if [[ "$rclone_path" == "$wrapper_path" ]]; then rclone_path=""; fi
if [[ -z "$rclone_path" ]]; then
  echo "rclone is not installed. Run: brew install rclone" >&2
  exit 1
fi

# Replace only the app's unconfigured template (empty rclone path) or an earlier
# fake setup, never settings that point at a real rclone config.
if [[ -f "$settings_path" ]] \
  && ! grep -q '"rcloneExecutablePath" *: *""' "$settings_path" \
  && ! grep -qF "\"configPath\": \"$config_path\"" "$settings_path"; then
  echo "$settings_path already exists and does not use the fake config; refusing to overwrite it." >&2
  exit 1
fi

mkdir -p "$remote_dir" "$settings_dir"
[[ -f "$remote_dir/hello-from-fake-onedrive.txt" ]] || echo "Seeded by setup-fake-onedrive.sh" > "$remote_dir/hello-from-fake-onedrive.txt"

if $guided; then
  # Guided setup creates the remote, RCLONE_TEST, and the local folder itself.
  rm -f "$config_path" "$fake_root/approve" "$fake_root/deny"
  mkdir -p "$(dirname "$wrapper_path")"
  cat > "$wrapper_path" <<WRAPPER
#!/bin/sh
# Stands in for rclone's Microsoft sign-in: \`config create NAME onedrive\` prints
# what rclone prints, then waits until $fake_root/approve exists (the user signed
# in) or $fake_root/deny exists (Microsoft refused). Approval creates an alias
# remote over $remote_dir. Every other command is passed to the real rclone.
if [ "\$1" = config ] && [ "\$2" = create ] && [ "\$4" = onedrive ]; then
  echo "NOTICE: Make sure your Redirect URL is set to \"http://localhost:53682/\" in your custom config."
  echo "NOTICE: If your browser doesn't open automatically go to the following link: http://127.0.0.1:53682/auth?state=fake-sign-in"
  echo "NOTICE: Log in and authorize rclone for access"
  echo "NOTICE: Waiting for code..."
  while :; do
    if [ -e "$fake_root/approve" ]; then
      rm -f "$fake_root/approve"
      exec "$rclone_path" config create "\$3" alias remote="$remote_dir" --no-output
    fi
    if [ -e "$fake_root/deny" ]; then
      rm -f "$fake_root/deny"
      echo "ERROR: Failed to create onedrive remote: failed to get token: access_denied"
      exit 1
    fi
    sleep 1
  done
fi
exec "$rclone_path" "\$@"
WRAPPER
  chmod +x "$wrapper_path"
  rclone_path="$wrapper_path"
  local_path=""
else
  mkdir -p "$local_dir"
  cat > "$config_path" <<CONF
[onedrive]
type = alias
remote = $remote_dir
CONF
  # The app runs bisync with --check-access, which needs RCLONE_TEST on both sides.
  touch "$remote_dir/RCLONE_TEST" "$local_dir/RCLONE_TEST"
  local_path="$local_dir"
fi

cat > "$settings_path" <<EOF2
{
  "rcloneExecutablePath": "$rclone_path",
  "configPath": "$config_path",
  "remoteName": "onedrive",
  "localPath": "$local_path",
  "intervalSeconds": 600
}
EOF2

echo "Fake remote:   $remote_dir"
echo "rclone config: $config_path"
echo "App settings:  $settings_path"
if $guided; then
  echo "rclone:        $wrapper_path (fake sign-in)"
  echo "Choose Set Up OneDrive… in the app. During sign-in, approve with: touch $fake_root/approve"
  echo "or refuse with: touch $fake_root/deny"
else
  echo "Local mirror:  $local_dir"
fi
