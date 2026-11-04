#!/usr/bin/env bash
set -u

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-commit"

PASS=0
FAIL=0
R=""
trap 'rm -rf "${R:-}"' EXIT
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false

mkrepo() {
  R="$(mktemp -d /tmp/githook-test.XXXXXX)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.local
  git -C "$R" config user.name t
  (cd "$R" && echo data > file.txt && git add file.txt && git commit -qm init)
}

expect() { # expect <desc> <want-rc> [must-contain]
  local desc="$1" want="$2" must="${3:-}" out rc
  out=$(cd "$R" && bash "$HOOK" 2>&1); rc=$?
  if [ "$rc" != "$want" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $desc (want rc=$want, got rc=$rc)"
  elif [ -n "$must" ] && ! printf '%s' "$out" | grep -qF -- "$must"; then
    FAIL=$((FAIL + 1)); echo "FAIL: $desc (output missing '$must')"
  else
    PASS=$((PASS + 1))
  fi
  rm -rf "$R"
}

mkrepo
printf 'caf\xc3\xa9 naif \xc3\x89lise\n' > "$R/accented.md" && git -C "$R" add accented.md
expect "accented staged file blocks" 1

mkrepo
printf '# caf\xc3\xa9\n' > "$R/a.ps1" && git -C "$R" add a.ps1
expect "accent in .ps1 blocks" 1 "accented characters"

mkrepo
printf 'caf\xc3\xa9\n' > "$R/my file.md" && git -C "$R" add "my file.md"
expect "staged name with a space is checked" 1 "my file.md"

mkrepo
cp "$HOOK" "$R/copied-hook.sh" && git -C "$R" add copied-hook.sh
expect "staging the hook itself does not self-block" 0

mkrepo
printf '{"bad": }' > "$R/bad.json" && git -C "$R" add bad.json
expect "invalid JSON blocks" 1 "invalid JSON"

mkrepo
printf '{"a":1} x' > "$R/trail.json" && git -C "$R" add trail.json
expect "JSON with trailing garbage blocks" 1 "invalid JSON"

mkrepo
printf '{"a":NaN}' > "$R/nan.json" && git -C "$R" add nan.json
expect "JSON with NaN blocks" 1 "invalid JSON"

mkrepo
printf '{"good": true}' > "$R/ok.json" && git -C "$R" add ok.json
expect "valid JSON passes" 0

mkrepo
printf '%s\n' '#!/bin/sh' 'if [ -z ]; then' > "$R/bad.sh" && git -C "$R" add bad.sh
expect "failing shell script blocks" 1 "shellcheck bad.sh"

mkrepo
printf '@AGENTS.md\n' > "$R/CLAUDE.md"
git -C "$R" add CLAUDE.md
expect "CLAUDE.md == @AGENTS.md passes" 0

mkrepo
printf '# inline workflow\n' > "$R/CLAUDE.md"
git -C "$R" add CLAUDE.md
expect "CLAUDE.md with inline content blocks" 1 "CLAUDE.md must be exactly"

mkrepo
echo clean > "$R/clean.txt" && git -C "$R" add clean.txt
out=$(cd "$R" && PRECOMMIT_FORCE_ERROR=boom bash "$HOOK" 2>&1); rc=$?
if [ "$rc" = 1 ] && grep -qF "commit blocked" <<< "$out"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: unexpected error fails closed (rc=$rc)"; fi
rm -rf "$R"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
