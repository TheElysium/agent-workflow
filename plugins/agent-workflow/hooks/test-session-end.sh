#!/usr/bin/env bash
# Smoke tests for session-end.sh.
#
# Contract: run with cwd = project worktree. The hook derives the Claude Code
# project slug from the working directory (Windows path under Git Bash, every
# non-alphanumeric character becomes a dash), finds the projects storage
# (CLAUDE_PROJECTS_DIR) and calls the import script (USAGE_IMPORT_CMD, default
# ../scripts/usage-import-claude.sh) with:
#   --dir <projects-dir> --project <slug> --out <worktree>/.usage/usage.jsonl
#
# The stub logs ONE ARG PER LINE so word-splitting of paths with spaces shows.
#
# Usage:  bash test-session-end.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/session-end.sh"

PASS=0
FAIL=0

R=""
S=""
rmstub() { rm -rf "${R:-}" "${S:-}"; }
trap 'rmstub' EXIT

native_pwd() {
  case "$(uname -s)" in
    MINGW*|MSYS*) pwd -W;;
    *) pwd;;
  esac
}

run_hook() {
  printf '#!/bin/sh\nprintf "%%s\n" "$@" >> %s/calls.log\n' "$R" > "$S/import.sh"
  USAGE_IMPORT_CMD="$S/import.sh" \
    CLAUDE_PROJECTS_DIR="$R/projects" \
    bash "$HOOK" >/dev/null 2>&1
}
mkstub() {
  R="$(mktemp -d /tmp/session-end-test.XXXXXX)"
  S="$(mktemp -d '/tmp/session-end stub.XXXXXX')"
}

expect() {
  if grep -qF -- "$2" "$R/calls.log" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)  [calls: $(cat "$R/calls.log" 2>/dev/null)]"
  fi
}

expect_line() {
  if grep -qxF -- "$2" "$R/calls.log" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing exact line: $2)  [calls: $(cat "$R/calls.log" 2>/dev/null)]"
  fi
}

expect_nocall() {
  if [ "$2" = 0 ] && [ ! -s "$R/calls.log" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (rc=$2, calls: $(cat "$R/calls.log" 2>/dev/null))"
  fi
}

# --- 1. slug from the native path, non-alphanumerics to dashes, no splitting --
mkstub
mkdir -p "$R/projects"
WORK="$(mktemp -d '/tmp/session-end hook.XXXXXX')"
NATIVE="$(cd "$WORK" && native_pwd)"
SLUG="$(printf '%s' "$NATIVE" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$R/projects/$SLUG"
( cd "$WORK" && run_hook )
expect_line "slug derived from native path" "$SLUG"
expect_line "dir arg intact" "$R/projects"
expect_line "out path intact despite space" "$(cd "$WORK" && pwd)/.usage/usage.jsonl"
rm -rf "$WORK"
rmstub

# --- 1b. a non-ASCII character becomes exactly one dash ------------------------
mkstub
mkdir -p "$R/projects"
PARENT="$(mktemp -d /tmp/session-end-utf.XXXXXX)"
WORK="$PARENT/caf"$'\xc3\xa9'
mkdir -p "$WORK"
PARENT_SLUG="$(printf '%s' "$(cd "$PARENT" && native_pwd)" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$R/projects/$PARENT_SLUG-caf-"
( cd "$WORK" && run_hook )
expect_line "one dash per non-ASCII character" "$PARENT_SLUG-caf-"
rm -rf "$PARENT"
rmstub

# --- 2. no matching project dir -> no import call, rc 0 ----------------------
mkstub
mkdir -p "$R/projects"
WORK="$(mktemp -d /tmp/session-end-hook-empty.XXXXXX)"
( cd "$WORK" && run_hook )
expect_nocall "no match -> no import call, rc 0" $?
rm -rf "$WORK"
rmstub

# --- 3. default import script (next to the hook dir) imports transcripts -----
R="$(mktemp -d /tmp/session-end-test.XXXXXX)"
S=""
WORK="$(mktemp -d /tmp/session-end-hook-real.XXXXXX)"
NATIVE="$(cd "$WORK" && native_pwd)"
SLUG="$(printf '%s' "$NATIVE" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$R/projects/$SLUG"
printf '%s\n' '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s1","message":{"id":"m1","model":"claude-test","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$R/projects/$SLUG/s1.jsonl"
RC=0
( cd "$WORK" && env -u USAGE_IMPORT_CMD CLAUDE_PROJECTS_DIR="$R/projects" bash "$HOOK" </dev/null >"$R/stdout.log" 2>&1 ) || RC=$?
if [ "$RC" = 0 ] && grep -q '"msg":"m1"' "$WORK/.usage/usage.jsonl" 2>/dev/null \
  && [ "$(cat "$WORK/.usage/.gitignore" 2>/dev/null)" = '*' ] \
  && [ ! -s "$R/stdout.log" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: default import (rc=$RC, out: $(cat "$R/stdout.log" 2>/dev/null))"
fi
rm -rf "$WORK"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
