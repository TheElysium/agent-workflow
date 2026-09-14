#!/usr/bin/env bash
# Smoke tests for .claude/hooks/session-end.sh.
#
# Contract: run with cwd = project worktree; stdin carries the Claude Code
# SessionEnd JSON (unused). The hook derives the Claude Code project slug
# from the current directory (Windows-drive transform or POSIX transform),
# auto-detects the Claude projects storage, and calls the import script
# (overridable via USAGE_IMPORT_CMD for stubbing) with:
#   --dir <projects-dir> --project <slug> --out <worktree>/.usage/usage.jsonl
#
# The stub logs ONE ARG PER LINE (printf '%s\n' "$@") so that word-splitting
# of paths containing spaces becomes visible to the assertions.
#
# Usage:  bash .claude/hooks/test-session-end.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/session-end.sh"

PASS=0
FAIL=0

# Globals shared with run_hook: R = test base dir, S = stub dir.
R=""
S=""
rmstub() { rm -rf "${R:-}" "${S:-}"; }
trap 'rmstub' EXIT

run_hook() { # run_hook — cwd is the fixture worktree; R/S globals already set
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> %s/calls.log\n' "$R" > "$S/import.sh"
  chmod +x "$S/import.sh"
  USAGE_IMPORT_CMD="$S/import.sh" \
    CLAUDE_PROJECTS_DIR="$R/projects" \
    bash "$HOOK" >/dev/null 2>&1
}
mkstub() { # mkstub — stub dir WITH a space: an unquoted $IMPORT_CMD word-splits
  R="$(mktemp -d /tmp/session-end-test.XXXXXX)"
  S="$(mktemp -d '/tmp/session-end stub.XXXXXX')"
}

expect() { # expect <desc> <fixed-string>
  if grep -qF -- "$2" "$R/calls.log" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)  [calls: $(cat "$R/calls.log" 2>/dev/null)]"
  fi
}

expect_line() { # expect_line <desc> <exact-arg-line>
  if grep -qxF -- "$2" "$R/calls.log" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing exact line: $2)  [calls: $(cat "$R/calls.log" 2>/dev/null)]"
  fi
}

expect_nocall() { # expect_nocall <desc> <rc>
  if [ "$2" = 0 ] && [ ! -s "$R/calls.log" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (rc=$2, calls: $(cat "$R/calls.log" 2>/dev/null))"
  fi
}

# --- 1. Windows-drive workdir: wslpath transform ------------------------------
# The fixture workdir lives next to this repo (same drive as the script), so
# the wslpath transform matches the repo's real C--Users-... slug scheme.
if [[ "$HERE" == /mnt/[a-z]/* ]]; then
  mkstub
  WIN_BASE="$(cd "$HERE/../.." && pwd)"
  PROJ_DIR="session-end-hook-test-$$"
  SLUG="$(wslpath -w "$WIN_BASE/$PROJ_DIR" | sed 's/:/-/; s/\\/-/g')"
  mkdir -p "$WIN_BASE/$PROJ_DIR" "$R/projects/$SLUG"
  ( cd "$WIN_BASE/$PROJ_DIR" && run_hook )
  expect "windows slug derived" "$SLUG"
  expect_line "out path intact as ONE arg" "$WIN_BASE/$PROJ_DIR/.usage/usage.jsonl"
  rmdir "$WIN_BASE/$PROJ_DIR"
  rmstub
else
  echo "SKIP: windows-drive case (not on a mounted drive)"
fi

# --- 2. POSIX workdir with a space in the path: no word-splitting -------------
mkstub
mkdir -p "$R/projects"
POSIX_PROJ="/tmp/session-end hook-test-posix"   # space in path
POSIX_SLUG="$(printf '%s' "$POSIX_PROJ" | tr '/' '-')"
mkdir -p "$POSIX_PROJ" "$R/projects/$POSIX_SLUG"
( cd "$POSIX_PROJ" && run_hook )
expect "posix slug derived (slashes to dashes)" "$POSIX_SLUG"
expect_line "dir arg intact" "$R/projects"
expect_line "out path intact despite space" "$POSIX_PROJ/.usage/usage.jsonl"
rmdir "$POSIX_PROJ"
rmstub

# --- 3. no matching project dir -> no import call, rc 0 -----------------------
mkstub
mkdir -p "$R/projects"
POSIX_PROJ="/tmp/session-end-hook-test-empty"
mkdir -p "$POSIX_PROJ"
( cd "$POSIX_PROJ" && run_hook )
expect_nocall "no match -> no import call, rc 0" $?
rmdir "$POSIX_PROJ"
rmstub

# --- summary -----------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
