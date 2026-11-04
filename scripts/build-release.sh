#!/usr/bin/env bash
# Builds the universal Release app for VERSION, ad-hoc signed, and writes
# dist/OneDriveRcloneMenubar-VERSION.zip and dist/SHA256SUMS. Prints the zip's
# Nix SRI hash on the last line of stdout.
#
# Usage: scripts/build-release.sh VERSION [BUILD_NUMBER]
# BUILD_NUMBER becomes CFBundleVersion and defaults to VERSION.
set -euo pipefail

version="${1:?usage: scripts/build-release.sh VERSION [BUILD_NUMBER]}"
build_number="${2:-$version}"
cd "$(git rev-parse --show-toplevel)"

app=.build/release/Build/Products/Release/OneDriveRcloneMenubar.app
zip="OneDriveRcloneMenubar-$version.zip"

xcodebuild -project OneDriveRcloneMenubar.xcodeproj -scheme OneDriveRcloneMenubar \
  -configuration Release -derivedDataPath .build/release \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  clean build >&2

codesign --verify --deep --strict "$app" >&2
built_version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
if [[ "$built_version" != "$version" ]]; then
  echo "Built app reports version $built_version, expected $version." >&2
  exit 1
fi

rm -rf dist
mkdir dist
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$app" "dist/$zip"
(cd dist && shasum -a 256 "$zip" > SHA256SUMS)
echo "sha256-$(openssl dgst -sha256 -binary "dist/$zip" | base64)"
