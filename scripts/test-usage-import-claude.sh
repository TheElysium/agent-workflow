#!/usr/bin/env bash
# Smoke tests for scripts/usage-import-claude.sh.
#
# Fixture transcripts are shaped like real Claude Code session JSONLs
# (~/.claude/projects/<slug>/<uuid>.jsonl): one record per line, assistant
# messages carrying message.usage with repeated ids (streaming snapshots).
#
# Usage:  bash scripts/test-usage-import-claude.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT="$HERE/usage-import-claude.sh"

PASS=0
FAIL=0

mkfixtures() { # $1 = projects dir
  mkdir -p "$1/Proj"
  cat > "$1/Proj/sess-a.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"},"sessionId":"sess-a","timestamp":"2026-09-12T15:26:10.000Z"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":33764,"cache_creation_input_tokens":15753}},"sessionId":"sess-a","timestamp":"2026-09-12T15:26:19.131Z","isSidechain":false}
{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":2,"output_tokens":503,"cache_read_input_tokens":33764,"cache_creation_input_tokens":15753}},"sessionId":"sess-a","timestamp":"2026-09-12T15:26:30.000Z","isSidechain":false}
{"type":"assistant","message":{"id":"msg_2","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"sess-a","timestamp":"2026-09-12T15:27:00.000Z","isSidechain":true}
{"type":"assistant","message":{"id":"msg_3","model":"claude-sonnet-5"},"sessionId":"sess-a","timestamp":"2026-09-12T15:27:10.000Z"}
not valid json at all
EOF
  cat > "$1/Proj/sess-b.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"msg_9","model":"claude-haiku-4","usage":{"input_tokens":7,"output_tokens":8,"cache_read_input_tokens":9,"cache_creation_input_tokens":10}},"sessionId":"sess-b","timestamp":"2026-09-12T15:28:00.000Z"}
EOF
}

sink() { echo "$R/.usage/usage.jsonl"; }

expect_rc() { # expect_rc <desc> <want>
  if [ "$RC_GOT" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (want rc=$2, got $RC_GOT)"
  fi
}

expect_count() { # expect_count <desc> <want-lines>
  local got
  got=$(grep -c . "$(sink)" 2>/dev/null || true)
  if [ "$got" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (want $2 lines, got $got)"
  fi
}

expect_grep() { # expect_grep <desc> <fixed-string>
  if grep -qF -- "$2" "$(sink)" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)"
  fi
}

expect_lacks() {
  if grep -qF -- "$2" "$(sink)" 2>/dev/null; then
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (must not contain: $2)"
  else
    PASS=$((PASS + 1))
  fi
}

# --- 1. basic import: dedup last-wins, user/no-usage/garbage skipped ---------
R="$(mktemp -d /tmp/usage-import-test.XXXXXX)"
mkfixtures "$R/projects"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_count "three records imported (msg_1 deduped, msg_3 no-usage skipped, sess-b msg_9)" 3
expect_grep "last snapshot wins for msg_1" '"tokens_out":503'
expect_lacks "first snapshot gone" '"tokens_out":100'
expect_lacks "msg_3 (no usage) skipped" '"msg":"msg_3"'
expect_grep "sidechain marked subagent" '"role":"subagent"'
expect_grep "non-sidechain primary" '"role":"primary"'
expect_grep "harness tag" '"harness":"claude"'
expect_grep "model passthrough" '"model":"claude-haiku-4"'

# --- 2. idempotence: rerun imports nothing new -------------------------------
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_count "rerun appends nothing" 3

# --- 3. new transcript content is picked up ----------------------------------
printf '%s\n' \
  '{"type":"assistant","message":{"id":"msg_4","model":"claude-sonnet-5","usage":{"input_tokens":11,"output_tokens":12,"cache_read_input_tokens":13,"cache_creation_input_tokens":14}},"sessionId":"sess-a","timestamp":"2026-09-12T15:29:00.000Z","isSidechain":false}' \
  >> "$R/projects/Proj/sess-a.jsonl"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_count "only the new message appended" 4
expect_grep "new message imported" '"msg":"msg_4"'

# --- 4. empty sink dir missing -> created ------------------------------------
rm -rf "$R/.usage"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
if [ -f "$(sink)" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: sink dir auto-created (no sink file)"
fi

rm -rf "$R"

# --- 5. timestamp normalization + position tiebreak on equal seconds ----------
R="$(mktemp -d /tmp/usage-import-test.XXXXXX)"
mkfixtures "$R/projects"
# same msg, same second: snapshot A has fractional ts, snapshot B (later in
# file) has no fraction. Raw string compare would pick B (Z > digits); the
# contract is max normalized ts, ties -> later in file. Here A wins by ts.
printf '%s\n' \
  '{"type":"assistant","message":{"id":"msg_t","model":"m","usage":{"input_tokens":1,"output_tokens":900,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"sess-t","timestamp":"2026-09-12T15:26:30.900Z"}' \
  '{"type":"assistant","message":{"id":"msg_t","model":"m","usage":{"input_tokens":1,"output_tokens":111,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"sess-t","timestamp":"2026-09-12T15:26:30Z"}' \
  > "$R/projects/Proj/sess-t.jsonl"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_grep "fractional-ts snapshot wins over bare-second one" '"tokens_out":900'
rm -rf "$R"

# --- 6. position tiebreak: same second, last-in-file wins --------------------
R="$(mktemp -d /tmp/usage-import-test.XXXXXX)"
mkfixtures "$R/projects"
printf '%s\n' \
  '{"type":"assistant","message":{"id":"msg_u","model":"m","usage":{"input_tokens":1,"output_tokens":222,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"sess-u","timestamp":"2026-09-12T15:26:30.100Z"}' \
  '{"type":"assistant","message":{"id":"msg_u","model":"m","usage":{"input_tokens":1,"output_tokens":333,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"sess-u","timestamp":"2026-09-12T15:26:30.400Z"}' \
  > "$R/projects/Proj/sess-u.jsonl"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_grep "max ts wins over file order (both fractional)" '"tokens_out":333'
rm -rf "$R"

# --- 7. arg validation ---------------------------------------------------------
R="$(mktemp -d /tmp/usage-import-test.XXXXXX)"
mkfixtures "$R/projects"
RC_GOT=0
bash "$IMPORT" --dir "$R/projects" --out "$R/.usage/usage.jsonl" >/dev/null 2>&1 || RC_GOT=$?
expect_rc "missing --project exits 1" 1
RC_GOT=0
bash "$IMPORT" --bogus >/dev/null 2>&1 || RC_GOT=$?
expect_rc "unknown arg exits 1" 1
RC_GOT=0
bash "$IMPORT" --dir "$R/nonexistent" --project Proj >/dev/null 2>&1 || RC_GOT=$?
expect_rc "missing transcript dir exits 1" 1
rm -rf "$R"

# --- summary -----------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
