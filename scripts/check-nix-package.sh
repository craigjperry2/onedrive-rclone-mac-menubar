#!/usr/bin/env bash
# Proves, before publishing, that nix/package.nix installs
# dist/OneDriveRcloneMenubar-VERSION.zip under HASH. The zip goes into the Nix
# store with the name and hash fetchurl would download it under, so the build
# uses it without fetching the not-yet-published release URL.
#
# Usage: scripts/check-nix-package.sh VERSION HASH
set -euo pipefail

version="${1:?usage: scripts/check-nix-package.sh VERSION HASH}"
hash="${2:?usage: scripts/check-nix-package.sh VERSION HASH}"
cd "$(git rev-parse --show-toplevel)"

nix-store --add-fixed sha256 "dist/OneDriveRcloneMenubar-$version.zip" >/dev/null
out="$(nix build --no-link --print-out-paths --impure -I nixpkgs=channel:nixpkgs-unstable \
  --expr "(import <nixpkgs> { }).callPackage ./nix/package.nix { version = \"$version\"; hash = \"$hash\"; }")"

app="$out/Applications/OneDriveRcloneMenubar.app"
codesign --verify --deep --strict "$app"
installed_version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
if [[ "$installed_version" != "$version" ]]; then
  echo "Nix package installs version $installed_version, expected $version." >&2
  exit 1
fi
echo "Nix package installs $app"
