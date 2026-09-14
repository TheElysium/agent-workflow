#!/usr/bin/env bash
# Smoke tests for scripts/review-checklist.
#
# Builds a throwaway git repo, creates added/modified/deleted/renamed and
# untracked fixtures, and asserts the generated checklist lines.
#
# Usage:  bash scripts/test-review-checklist.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-checklist.sh"

PASS=0
FAIL=0

mkrepo() { # sets R (repo)
  R="$(mktemp -d /tmp/review-checklist-test.XXXXXX)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.local
  git -C "$R" config user.name t
}

trap 'rm -rf "${R:-}"' EXIT

rmrepo() { rm -rf "$R"; }

run() { # run — sets OUT and RC (executed inside the fixture repo)
  OUT="$(cd "$R" && bash "$SCRIPT" 2>&1)"
  RC=$?
}

expect_rc() { # expect_rc <desc> <want-rc> — needs RC set by run
  if [ "$RC" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (want rc=$2, got rc=$RC)  [out: ${OUT:0:120}]"
  fi
}

expect_has() { # expect_has <desc> <fixed-string> — substring match on OUT (literal)
  if grep -qF -- "$2" <<< "$OUT"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)  [out: ${OUT:0:200}]"
  fi
}

expect_lacks() { # expect_lacks <desc> <fixed-string> — substring must be absent (literal)
  if grep -qF -- "$2" <<< "$OUT"; then
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (must not contain: $2)  [out: ${OUT:0:200}]"
  else
    PASS=$((PASS + 1))
  fi
}

expect_lines() { # expect_lines <desc> <n> — OUT must have exactly n checklist lines
  local got
  got="$(printf '%s\n' "$OUT" | grep -c . || true)"
  if [ "$got" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (want $2 lines, got $got)  [out: ${OUT:0:200}]"
  fi
}

# --- 1. empty repo (no diff) -> empty checklist, rc 0 -----------------------
mkrepo
(cd "$R" && echo base > base.txt && git add base.txt && git commit -qm init)
run
expect_rc "empty diff exits 0" 0
expect_lacks "empty diff prints no file lines" "base.txt"
rmrepo

# --- 2. modified file with numstat counts -----------------------------------
mkrepo
(cd "$R" && printf 'one\ntwo\n' > f.txt && git add f.txt && git commit -qm init)
(cd "$R" && printf 'one\nTWO\nthree\nfour\n' > f.txt)
run
expect_rc "modified file exits 0" 0
expect_has "modified line shows status" "[ M]"
expect_has "modified line shows path" "f.txt"
expect_has "modified line shows numstat counts" "+3 -1"
rmrepo

# --- 3. added (staged) and untracked files ----------------------------------
mkrepo
(cd "$R" && echo base > base.txt && git add base.txt && git commit -qm init)
(cd "$R" && echo new > staged.txt && git add staged.txt)
(cd "$R" && echo stray > untracked.txt)
run
expect_rc "added+untracked exit 0" 0
expect_has "staged added file listed" "staged.txt"
expect_has "untracked file listed" "untracked.txt"
rmrepo

# --- 4. deleted file listed -------------------------------------------------
mkrepo
(cd "$R" && echo gone > gone.txt && git add gone.txt && git commit -qm init)
(cd "$R" && rm gone.txt)
run
expect_rc "deleted file exits 0" 0
expect_has "deleted file listed" "gone.txt"
expect_has "deleted file marked D" "[ D]"
rmrepo

# --- 5. rename detected (R status) ------------------------------------------
mkrepo
(cd "$R" && echo moved > old.txt && git add old.txt && git commit -qm init)
(cd "$R" && git mv old.txt new.txt)
run
expect_rc "rename exits 0" 0
expect_has "renamed path listed" "old.txt"
expect_has "renamed destination listed" "new.txt"
rmrepo

# --- 6. lockfile excluded ----------------------------------------------------
mkrepo
(cd "$R" && echo base > base.txt && git add base.txt && git commit -qm init)
(cd "$R" && echo '{"x":1}' > package-lock.json && git add package-lock.json)
run
expect_rc "lockfile case exits 0" 0
expect_lacks "lockfile excluded" "package-lock.json"
rmrepo

# --- 7. type column maps extension -------------------------------------------
mkrepo
(cd "$R" && printf '#!/usr/bin/env bash\ntrue\n' > hook.sh && git add hook.sh)
run
expect_rc "type case exits 0" 0
expect_has "shell type detected" "shell"
rmrepo

# --- 8. outside a git repo -> error ------------------------------------------
T="$(mktemp -d /tmp/review-checklist-nogit.XXXXXX)"
OUT="$(cd "$T" && bash "$SCRIPT" 2>&1)"; RC=$?
expect_rc "non-repo exits nonzero" 1
rm -rf "$T"

# --- 9. untracked directory expanded to files (no wc-on-directory error) -----
mkrepo
(cd "$R" && echo base > base.txt && git add base.txt && git commit -qm init)
(cd "$R" && mkdir -p sub && echo x > sub/new.sh)
run
expect_rc "untracked dir exits 0" 0
expect_has "untracked dir file listed" "sub/new.sh"
expect_lines "one untracked file, directory not listed" 1
rmrepo

# --- 10. glob characters in a tracked filename are counted (literal pathspecs)
# The trap: with glob pathspecs, "f[1].txt" also matches the modified sibling
# "f1.txt", so counts merge across files. Both files are modified with
# distinct counts; each checklist line must keep its own.
mkrepo
(cd "$R" && printf 'a\nb\n' > f1.txt && printf 'x\n' > 'f[1].txt' && git add -- ':(literal)f[1].txt' f1.txt && git commit -qm init)
(cd "$R" && printf 'a\nb\nc\n' > f1.txt && printf 'x\ny\nz\n' > 'f[1].txt')
run
expect_rc "glob-char path exits 0" 0
expect_has "sibling counts kept separate" "[ M] +1 -0 other f1.txt"
expect_has "glob-char path counted exactly" "[ M] +2 -0 other f[1].txt"
rmrepo

# --- 11. minified bundle excluded --------------------------------------------
mkrepo
(cd "$R" && echo base > base.txt && git add base.txt && git commit -qm init)
(cd "$R" && echo 'x=1;' > bundle.min.js)
run
expect_rc "minified case exits 0" 0
expect_lacks "minified bundle excluded" "bundle.min.js"
rmrepo

# --- 12. binary file reports ? line counts -----------------------------------
mkrepo
(cd "$R" && printf 'base\n' > base.txt && git add base.txt && git commit -qm init)
(cd "$R" && printf 'bin\000data\n' > blob.bin && git add blob.bin)
(cd "$R" && printf 'bin\000other\n' > blob.bin)
run
expect_rc "binary case exits 0" 0
expect_has "binary path listed" "blob.bin"
expect_has "binary counts are ?" "+? -?"
rmrepo

# --- 13. filename containing a quote is not C-mangled -------------------------
mkrepo
(cd "$R" && echo base > base.txt && git add base.txt && git commit -qm init)
(cd "$R" && echo data > 'we"ird.txt')
run
expect_rc "quoted-name case exits 0" 0
expect_has "quoted-name path listed unescaped" 'we"ird.txt'
rmrepo

# --- summary -----------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
