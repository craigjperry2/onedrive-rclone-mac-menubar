#!/usr/bin/env bash
# Point the app at a fake OneDrive: an rclone `alias` remote named `onedrive`
# backed by a local directory, synced with a second local directory. No network
# or credentials are involved. Intended for test machines such as the Amp macOS
# Satellite; see docs/testing-with-fake-onedrive.md.
#
# Usage: scripts/setup-fake-onedrive.sh [fake-root]   (default: ~/onedrive-fake)
set -euo pipefail

fake_root="${1:-$HOME/onedrive-fake}"
remote_dir="$fake_root/remote"
local_dir="$fake_root/local"
config_path="$fake_root/rclone.conf"
settings_dir="$HOME/Library/Application Support/OneDriveRcloneMenubar"
settings_path="$settings_dir/settings.json"

rclone_path="$(command -v rclone || true)"
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

mkdir -p "$remote_dir" "$local_dir" "$settings_dir"

cat > "$config_path" <<EOF
[onedrive]
type = alias
remote = $remote_dir
EOF

# The app runs bisync with --check-access, which needs RCLONE_TEST on both sides.
touch "$remote_dir/RCLONE_TEST" "$local_dir/RCLONE_TEST"
[[ -f "$remote_dir/hello-from-fake-onedrive.txt" ]] || echo "Seeded by setup-fake-onedrive.sh" > "$remote_dir/hello-from-fake-onedrive.txt"

cat > "$settings_path" <<EOF
{
  "rcloneExecutablePath": "$rclone_path",
  "configPath": "$config_path",
  "remoteName": "onedrive",
  "localPath": "$local_dir",
  "intervalSeconds": 600
}
EOF

echo "Fake remote:  $remote_dir"
echo "Local mirror: $local_dir"
echo "rclone config: $config_path"
echo "App settings: $settings_path"
