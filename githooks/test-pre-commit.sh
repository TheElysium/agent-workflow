#!/usr/bin/env bash
# Smoke tests for githooks/pre-commit.
#
# Builds a throwaway git repo, stages good/bad fixtures, and asserts the
# hook's exit code and behavior. gitleaks is stubbed on PATH to exercise
# every branch (absent, ok, leak, broken).
#
# Usage:  bash githooks/test-pre-commit.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-commit"

# Fake secret built by concatenation so this file's own source never matches
# the fallback pattern (otherwise the repo's commit would be blocked by the
# hook scanning this harness).
TOK="ghp_0123456789abcdefghij01234""56789"

PASS=0
FAIL=0

mkrepo() { # sets R (repo), S (stub bin dir); needs stub gitleaks preinstalled
  R="$(mktemp -d /tmp/githook-test.XXXXXX)"
  S="$(mktemp -d /tmp/githook-stubs.XXXXXX)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.local
  git -C "$R" config user.name t
  (cd "$R" && echo data > file.txt && git add file.txt && git commit -qm init)
}

# Clean up the last throwaway repo/stub dir even on interruption.
trap 'rm -rf "${R:-}" "${S:-}"' EXIT

rmrepo() { rm -rf "$R" "$S"; }

stub_gitleaks() { # $1 = exit code to mimic
  printf '#!/bin/sh\nexit %s\n' "$1" > "$S/gitleaks"
  chmod +x "$S/gitleaks"
}

expect() { # expect <desc> <want-rc> — repo and stubs already prepared by caller
  local desc="$1" want="$2" rc
  (cd "$R" && PATH="$S:$PATH" bash "$HOOK" >/dev/null 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $desc (want rc=$want, got rc=$rc)"
  fi
  rmrepo
}

skip() { echo "SKIP: $1"; }

# NOTE: cases 1-4 say "no gitleaks"; on a gitleaks-equipped host the real
# gitleaks runs instead — the assertions still hold (clean -> 0, leak -> 1).

# --- 1. clean commit passes (no gitleaks on PATH: pattern fallback) --------
mkrepo
echo "a clean english line" > "$R/good.txt" && git -C "$R" add good.txt
expect "clean staged file passes" 0

# --- 2. accented staged file blocks ----------------------------------------
mkrepo
printf 'caf\xc3\xa9 naif \xc3\x89lise\n' > "$R/accented.md" && git -C "$R" add accented.md
expect "accented staged file blocks" 1

# --- 3. the hook itself can be staged (accent class uses hex escapes) ------
# The .sh suffix makes the accents check actually scan the hook's own bytes:
# without it the extension filter skips the file and the test guards nothing.
mkrepo
cp "$HOOK" "$R/copied-hook.sh" && git -C "$R" add copied-hook.sh
expect "staging the hook itself does not self-block" 0

# --- 4. secret-like pattern in staged diff blocks (fallback) ----------------
mkrepo
echo "token: $TOK" > "$R/leak.txt" && git -C "$R" add leak.txt
expect "secret pattern blocks (fallback)" 1

# --- 5. same leak caught by a real-behaving gitleaks stub (exit 1) ----------
mkrepo
echo "token: $TOK" > "$R/leak.txt" && git -C "$R" add leak.txt
stub_gitleaks 1
expect "secret blocks with gitleaks present (rc=1)" 1

# --- 6. clean file passes with gitleaks present (exit 0) --------------------
mkrepo
echo "clean" > "$R/clean.txt" && git -C "$R" add clean.txt
stub_gitleaks 0
expect "clean passes with gitleaks present (rc=0)" 0

# --- 7. broken gitleaks falls back, clean content passes -------------------
mkrepo
echo "clean" > "$R/clean.txt" && git -C "$R" add clean.txt
stub_gitleaks 126
expect "broken gitleaks falls back (clean passes)" 0

# --- 8. broken gitleaks falls back, leak still caught -----------------------
mkrepo
echo "token: $TOK" > "$R/leak.txt" && git -C "$R" add leak.txt
stub_gitleaks 126
expect "broken gitleaks falls back (leak blocked)" 1

# --- 9. staged content, not worktree (minor-5 regression) ------------------
mkrepo
echo "token: $TOK" > "$R/leak.txt"
git -C "$R" add leak.txt
echo "now clean in worktree" > "$R/leak.txt"   # worktree differs from index
stub_gitleaks 126
expect "leak staged but worktree clean still blocks" 1

# --- 12. upstream gitleaks:allow marker exempts the line (fallback) --------
mkrepo
echo "token: $TOK gitleaks:allow" > "$R/leak.txt" && git -C "$R" add leak.txt
expect "tagged leak (gitleaks:allow) passes fallback" 0

# --- 10. invalid JSON blocks, valid passes ---------------------------------
mkrepo
printf '{"bad": }' > "$R/bad.json" && git -C "$R" add bad.json
expect "invalid JSON blocks" 1
mkrepo
printf '{"good": true}' > "$R/ok.json" && git -C "$R" add ok.json
expect "valid JSON passes" 0

# --- 11. failing shell script blocks (real shellcheck if available) --------
mkrepo
cat > "$R/bad.sh" <<'EOF'
#!/bin/sh
if [ $foo = bar ]; then
EOF
git -C "$R" add bad.sh
if command -v shellcheck >/dev/null 2>&1; then
  expect "shellcheck-failing script blocks" 1
else
  rmrepo
  skip "case 11 (shellcheck not installed — hook WARN-skips by design)"
fi

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
