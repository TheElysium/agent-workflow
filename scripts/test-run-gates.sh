#!/usr/bin/env bash
# Smoke tests for scripts/run-gates.sh.
#
# Usage:  bash scripts/test-run-gates.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/run-gates.sh"

PASS=0
FAIL=0

R=""
DIRS=()
cleanup() {
    for d in "${DIRS[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

mkrepo() {
    R="$(mktemp -d /tmp/run-gates-test.XXXXXX)"
    DIRS+=("$R")
    mkdir -p "$R/scripts"
    cp "$RUNNER" "$R/scripts/run-gates.sh"
}

run() { # sets OUT/RC
    OUT="$(bash "$R/scripts/run-gates.sh" 2>&1)"
    RC=$?
}

expect_rc() { # expect_rc <desc> <want>
    if [ "$RC" = "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (want rc=$2, got $RC)  [out: ${OUT:0:140}]"; fi
}

expect_has() {
    if grep -qF -- "$2" <<< "$OUT"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)  [out: ${OUT:0:200}]"; fi
}

expect_lacks() {
    if grep -qF -- "$2" <<< "$OUT"; then FAIL=$((FAIL + 1)); echo "FAIL: $1 (must not contain: $2)  [out: ${OUT:0:200}]"; else PASS=$((PASS + 1)); fi
}

# --- 1. all commands pass ------------------------------------------------------
mkrepo
cat > "$R/.gates.yml" <<'EOF'
stack: shell
lint: true
test: /bin/true
sast: echo ok
EOF
run
expect_rc "all pass exits 0" 0
expect_has "lint reports PASS" "lint: PASS"
expect_has "test reports PASS" "test: PASS"
expect_has "sast reports PASS" "sast: PASS"
expect_lacks "stack key is not executed" "shell"

# --- 2. failing command continues to later keys --------------------------------
mkrepo
cat > "$R/.gates.yml" <<'EOF'
stack: shell
lint: false
test: echo later
EOF
run
expect_rc "failing command exits 1" 1
expect_has "failing key reports FAIL" "lint: FAIL (exit 1)"
expect_has "later key still runs" "test: PASS"

# --- 3. comments and blank lines are ignored -----------------------------------
mkrepo
cat > "$R/.gates.yml" <<'EOF'
stack: shell
# a comment
lint: true

# another
test: true
EOF
run
expect_rc "comments and blanks exits 0" 0
expect_has "lint runs after comment" "lint: PASS"
expect_has "test runs after blank line" "test: PASS"

# --- 4. unknown key with empty value fails -------------------------------------
mkrepo
cat > "$R/.gates.yml" <<'EOF'
stack: shell
lint:
EOF
run
expect_rc "empty command exits 1" 1
expect_has "empty command reports FAIL" "lint: FAIL (empty command)"

# --- 5. missing .gates.yml -----------------------------------------------------
mkrepo
run
expect_rc "missing .gates.yml exits 1" 1
expect_has "missing file message" ".gates.yml not found"

# --- summary -------------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
