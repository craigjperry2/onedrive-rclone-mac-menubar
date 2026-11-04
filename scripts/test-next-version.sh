#!/usr/bin/env bash
# Tests scripts/next-version.sh against throwaway git repositories.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/next-version.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# new_repo MAJOR: starts a repository in $work/<n> with MAJOR_VERSION and one commit.
new_repo() {
  repo="$work/$RANDOM$RANDOM"
  git init -q -b main "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config tag.gpgsign false
  echo "$1" > "$repo/MAJOR_VERSION"
  git -C "$repo" add MAJOR_VERSION
  git -C "$repo" commit -q -m "chore: initial commit"
}

commit() { git -C "$repo" commit -q --allow-empty -m "$1"; }
tag() { git -C "$repo" tag "$1"; }
set_major() { echo "$1" > "$repo/MAJOR_VERSION"; git -C "$repo" commit -q -am "chore: release major $1"; }

expect_version() {
  local name="$1" expected="$2" actual
  if actual="$(cd "$repo" && "$script" 2>/dev/null)" && [[ "$actual" == "$expected" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected $expected, got '${actual:-<error>}'"
    failures=$((failures + 1))
  fi
}

expect_failure() {
  local name="$1" actual
  if actual="$(cd "$repo" && "$script" 2>/dev/null)"; then
    echo "FAIL $name: expected an error, got '$actual'"
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

new_repo 0
expect_version "first release on major 0" 0.1.0

new_repo 1
expect_version "first release on major 1" 1.0.0

new_repo 0; tag v0.1.0; commit "fix: handle missing volume (#3)"; commit "docs: explain resync"
expect_version "fixes and docs bump patch" 0.1.1

new_repo 0; tag v0.1.3; commit "fix: retry"; commit "feat(menu): show version (#7)"; commit "test: cover it"
expect_version "a feat among fixes bumps minor" 0.2.0

new_repo 0; tag v0.2.5; commit "feature: not a conventional feat"; commit "chore: mention feat: in the body"
expect_version "subjects that only resemble feat bump patch" 0.2.6

new_repo 0; tag v0.2.5; commit "fix(sync)!: change the settings format"
expect_version "a breaking fix bumps minor, not major" 0.3.0
notice="$(cd "$repo" && "$script" 2>&1 >/dev/null)"
if [[ "$notice" == *"::notice::"*"MAJOR_VERSION"* ]]; then echo "ok   breaking change prints a notice"; else echo "FAIL breaking change notice: '$notice'"; failures=$((failures + 1)); fi

new_repo 0; tag v0.9.0; commit "fix: a"; tag v0.10.0; commit "fix: b"
expect_version "latest tag uses version order, not text order" 0.10.1

new_repo 0; tag v0.3.0; tag v0.4.0-rc1; tag vnext; tag v2; commit "fix: a"
expect_version "tags that are not vX.Y.Z are ignored" 0.3.1

new_repo 0; tag v0.3.0; git -C "$repo" switch -q -c side; commit "feat: elsewhere"; tag v0.5.0
git -C "$repo" switch -q main; commit "fix: a"
expect_version "tags not reachable from HEAD are ignored" 0.3.1

new_repo 0; tag v0.4.2; commit "feat: a"; set_major 1
expect_version "raising MAJOR_VERSION by one starts the major" 1.0.0

new_repo 1; tag v1.0.0; commit "fix: a"
expect_version "patch after a major release" 1.0.1

new_repo 0; tag v0.4.2; set_major 2
expect_failure "raising MAJOR_VERSION by two fails"

new_repo 1; tag v1.2.0; set_major 0
expect_failure "lowering MAJOR_VERSION fails"

new_repo 0; tag v0.1.0
expect_failure "an already released HEAD fails"

new_repo "one"
expect_failure "a non-numeric MAJOR_VERSION fails"

if (( failures > 0 )); then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All next-version tests passed."
