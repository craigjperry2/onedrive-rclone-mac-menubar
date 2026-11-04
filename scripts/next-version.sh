#!/usr/bin/env bash
# Prints the version (X.Y.Z, without "v") that the next release of HEAD gets.
#
# The major number comes from MAJOR_VERSION, which only a person edits; to start
# a new major, merge a change that raises it by exactly one. Automation picks the
# minor or patch number from the commit subjects since the latest vX.Y.Z tag
# reachable from HEAD: a conventional-commit "feat" subject, or any subject with
# a breaking-change "!", bumps minor; anything else bumps patch. Breaking changes
# never bump major on their own.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
major="$(tr -d '[:space:]' < "$repo_root/MAJOR_VERSION")"
if [[ ! "$major" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "MAJOR_VERSION must be a non-negative integer, got '$major'." >&2
  exit 1
fi

semver_tag='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
latest="$(git tag --list --merged HEAD --sort=-v:refname 'v*' | grep -E "$semver_tag" | sed -n 1p)" || latest=""

if [[ -z "$latest" ]]; then
  if (( major == 0 )); then echo "0.1.0"; else echo "$major.0.0"; fi
  exit 0
fi

IFS=. read -r latest_major latest_minor latest_patch <<< "${latest#v}"

if (( major < latest_major )); then
  echo "MAJOR_VERSION ($major) is lower than the latest release $latest." >&2
  exit 1
fi
if (( major > latest_major + 1 )); then
  echo "MAJOR_VERSION ($major) may only be one higher than the latest release $latest." >&2
  exit 1
fi
if (( major == latest_major + 1 )); then
  echo "$major.0.0"
  exit 0
fi

subjects="$(git log --format=%s "$latest..HEAD")"
if [[ -z "$subjects" ]]; then
  echo "HEAD is already released as $latest." >&2
  exit 1
fi

scope='(\([^)]*\))?'
if grep -qE "^[a-z]+$scope!:" <<< "$subjects"; then
  echo "::notice::Commits since $latest are marked as breaking. Automation only bumps the minor version; raise MAJOR_VERSION to release a new major." >&2
fi
if grep -qE "^(feat$scope!?|[a-z]+$scope!):" <<< "$subjects"; then
  echo "$latest_major.$((latest_minor + 1)).0"
else
  echo "$latest_major.$latest_minor.$((latest_patch + 1))"
fi
