#!/usr/bin/env bash
# Smoke tests for githooks/pre-commit.
#
# Builds a throwaway git repo, stages good/bad fixtures, and asserts the
# hook's exit code and behavior. gitleaks is stubbed on PATH to exercise
# every branch (absent, ok, leak, broken). Missing gate tools are now a
# hard failure, never a warn-and-continue.
#
# Usage:  bash githooks/test-pre-commit.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-commit"

# Fake secret built by concatenation so this file's own source never matches
# the deleted weak-scan fallback pattern.
TOK="ghp_0123456789abcdefghij01234""56789"

# Build a temp dir that shadows /usr/bin and /bin with symlinks to every
# executable found there, excluding the named tool(s). This lets tests
# simulate a genuinely absent gate tool regardless of where it is installed.
FARM=""
make_farm() { # make_farm tool1 [tool2 ...]
  FARM=$(mktemp -d /tmp/githook-farm.XXXXXX)
  local dir exe base
  for dir in /usr/bin /bin; do
    [ -d "$dir" ] || continue
    for exe in "$dir"/*; do
      [ -e "$exe" ] || continue
      [ -x "$exe" ] || continue
      [ -d "$exe" ] && continue
      base=$(basename "$exe")
      case " $* " in *" $base "*) continue;; esac
      ln -s "$exe" "$FARM/$base" 2>/dev/null || true
    done
  done
}

PASS=0
FAIL=0

mkrepo() { # sets R (repo), S (stub bin dir)
  R="$(mktemp -d /tmp/githook-test.XXXXXX)"
  S="$(mktemp -d /tmp/githook-stubs.XXXXXX)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.local
  git -C "$R" config user.name t
  (cd "$R" && echo data > file.txt && git add file.txt && git commit -qm init)
}

# Clean up the last throwaway repo/stub dir even on interruption.
trap 'rm -rf "${R:-}" "${S:-}" "${FARM:-}"' EXIT

rmrepo() { rm -rf "$R" "$S"; }

stub_gitleaks() { # $1 = exit code to mimic
  printf '#!/bin/sh\nexit %s\n' "$1" > "$S/gitleaks"
  chmod +x "$S/gitleaks"
}

expect() { # expect <desc> <want-rc> [path]
  local desc="$1" want="$2" path="${3:-$S:$PATH}" rc
  (cd "$R" && PATH="$path" bash "$HOOK" >/dev/null 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $desc (want rc=$want, got rc=$rc)"
  fi
  rmrepo
}

expect_output() { # expect_output <desc> <want-rc> <path> <must-contain> [must-not-contain]
  local desc="$1" want="$2" path="$3" must="$4" mustnot="${5:-}" rc
  local out
  out=$(cd "$R" && PATH="$path" bash "$HOOK" 2>&1); rc=$?
  local ok=1
  if [ "$rc" != "$want" ]; then
    echo "FAIL: $desc (want rc=$want, got rc=$rc)"; ok=""
  elif ! printf '%s' "$out" | grep -qF "$must"; then
    echo "FAIL: $desc (output missing '$must')"; ok=""
  elif [ -n "$mustnot" ] && printf '%s' "$out" | grep -qF "$mustnot"; then
    echo "FAIL: $desc (output unexpectedly contains '$mustnot')"; ok=""
  fi
  if [ -n "$ok" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  rmrepo
}

skip() { echo "SKIP: $1"; }

# --- 1. clean commit without gitleaks is blocked (SAST is non-skippable) -----
mkrepo
make_farm gitleaks
echo "a clean english line" > "$R/clean.txt" && git -C "$R" add clean.txt
expect "clean staged file without gitleaks is blocked" 1 "$FARM"
rm -rf "$FARM"

# --- 2. accented staged file blocks ------------------------------------------
mkrepo
printf 'caf\xc3\xa9 naif \xc3\x89lise\n' > "$R/accented.md" && git -C "$R" add accented.md
expect "accented staged file blocks" 1

# --- 3. the hook itself can be staged (accent class uses hex escapes) --------
mkrepo
cp "$HOOK" "$R/copied-hook.sh" && git -C "$R" add copied-hook.sh
expect "staging the hook itself does not self-block" 0

# --- 4. secret-like pattern without gitleaks is blocked (no fallback) --------
mkrepo
make_farm gitleaks
echo "token: $TOK" > "$R/leak.txt" && git -C "$R" add leak.txt
expect_output "secret pattern without gitleaks is blocked (no fallback)" 1 "$FARM" "gitleaks not installed" "pattern fallback"
rm -rf "$FARM"

# --- 5. gitleaks stub finds a leak (exit 1) ----------------------------------
mkrepo
echo "token: $TOK" > "$R/leak.txt" && git -C "$R" add leak.txt
stub_gitleaks 1
expect "secret blocks with gitleaks present (rc=1)" 1

# --- 6. clean file passes with gitleaks present (exit 0) ---------------------
mkrepo
echo "clean" > "$R/clean.txt" && git -C "$R" add clean.txt
stub_gitleaks 0
expect "clean passes with gitleaks present (rc=0)" 0

# --- 7. broken gitleaks fails closed (rc=126) --------------------------------
mkrepo
echo "clean" > "$R/clean.txt" && git -C "$R" add clean.txt
stub_gitleaks 126
expect "broken gitleaks fails closed (rc=126)" 1

# --- 8. broken gitleaks fails closed even when content looks like a leak -----
mkrepo
echo "token: $TOK" > "$R/leak.txt" && git -C "$R" add leak.txt
stub_gitleaks 126
expect "broken gitleaks fails closed even with leak (rc=126)" 1

# --- 9. staged content, not worktree (gitleaks rc=1) -------------------------
mkrepo
echo "token: $TOK" > "$R/leak.txt"
git -C "$R" add leak.txt
echo "now clean in worktree" > "$R/leak.txt"   # worktree differs from index
stub_gitleaks 1
expect "leak staged but worktree clean still blocks" 1

# --- 10. invalid JSON blocks, valid passes -----------------------------------
mkrepo
printf '{"bad": }' > "$R/bad.json" && git -C "$R" add bad.json
expect "invalid JSON blocks" 1
mkrepo
printf '{"good": true}' > "$R/ok.json" && git -C "$R" add ok.json
expect "valid JSON passes" 0

# --- 11. failing shell script blocks (or missing shellcheck) -----------------
mkrepo
cat > "$R/bad.sh" <<'EOF'
#!/bin/sh
if [ $foo = bar ]; then
EOF
git -C "$R" add bad.sh
expect "shellcheck failure or missing shellcheck blocks" 1

# --- 12. shellcheck absent is a hard failure ---------------------------------
mkrepo
make_farm shellcheck
cat > "$R/ok.sh" <<'EOF'
#!/bin/sh
echo "ok"
EOF
git -C "$R" add ok.sh
expect_output "shellcheck absent is a hard failure" 1 "$FARM" "shellcheck not installed"
rm -rf "$FARM"

# --- 13. jq absent is a hard failure -----------------------------------------
mkrepo
make_farm jq
printf '{"good": true}' > "$R/ok.json" && git -C "$R" add ok.json
expect_output "jq absent is a hard failure" 1 "$FARM" "jq not installed" "JSON validation skipped"
rm -rf "$FARM"

# --- 14. gitleaks exiting 2 fails closed -------------------------------------
mkrepo
echo "clean" > "$R/clean.txt" && git -C "$R" add clean.txt
stub_gitleaks 2
expect_output "gitleaks rc=2 fails closed" 1 "$S:$PATH" "gitleaks exited 2"

# --- 15. CLAUDE.md importing root AGENTS.md passes ---------------------------
mkrepo
printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf 'workflow text\n' > "$R/AGENTS.md"
git -C "$R" add CLAUDE.md AGENTS.md
expect "CLAUDE.md == @AGENTS.md passes" 0

# --- 16. CLAUDE.md with inline content or other import blocks ---------------
mkrepo
printf '# inline workflow\n' > "$R/CLAUDE.md"
git -C "$R" add CLAUDE.md
expect "CLAUDE.md with inline content blocks" 1

mkrepo
printf '@OTHER.md\n' > "$R/CLAUDE.md"
git -C "$R" add CLAUDE.md
expect "CLAUDE.md pointing to @OTHER.md blocks" 1

# --- 17. CLAUDE.md with @AGENTS.md followed by a blank line blocks ----------
mkrepo
printf '@AGENTS.md\n\n' > "$R/CLAUDE.md"
printf 'workflow text\n' > "$R/AGENTS.md"
git -C "$R" add CLAUDE.md AGENTS.md
expect "CLAUDE.md @AGENTS.md with extra blank line blocks" 1

# --- 18. staged deletion of CLAUDE.md blocks --------------------------------
mkrepo
printf '@AGENTS.md\n' > "$R/CLAUDE.md"
printf 'workflow text\n' > "$R/AGENTS.md"
git -C "$R" add CLAUDE.md AGENTS.md
git -C "$R" commit -qm baseline
git -C "$R" rm -q CLAUDE.md
expect "staged deletion of CLAUDE.md blocks" 1

# --- 19. CLAUDE.md without trailing newline passes --------------------------
mkrepo
printf '@AGENTS.md' > "$R/CLAUDE.md"
printf 'workflow text\n' > "$R/AGENTS.md"
git -C "$R" add CLAUDE.md AGENTS.md
expect "CLAUDE.md @AGENTS.md without trailing newline passes" 0

# --- 20. non-empty junk that strips to the same string still blocks ----------
mkrepo
printf '@AGENTS.md\n\nx' > "$R/CLAUDE.md"
git -C "$R" add CLAUDE.md
expect "CLAUDE.md with junk after newline blocks" 1

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
