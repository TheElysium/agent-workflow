#!/usr/bin/env bash
# Smoke tests for usage-import-claude.sh.
#
# Fixture transcripts are shaped like real Claude Code session JSONLs
# (~/.claude/projects/<slug>/<uuid>.jsonl): one record per line, assistant
# messages carrying message.usage with repeated ids (streaming snapshots).
#
# Usage:  bash test-usage-import-claude.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT="$HERE/usage-import-claude.sh"

DIRS=()
cleanup() { [ "${#DIRS[@]}" -eq 0 ] || rm -rf "${DIRS[@]}"; }
trap cleanup EXIT
newdir() { R="$(mktemp -d /tmp/usage-import-test.XXXXXX)"; DIRS+=("$R"); }

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
newdir
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
if [ "$(cat "$R/.usage/.gitignore" 2>/dev/null)" = '*' ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: .usage/.gitignore with * written when .usage is created"
fi
if grep -q $'\r' "$(sink)" "$R/.usage/usage.meta"; then
  FAIL=$((FAIL + 1)); echo "FAIL: CR found in sink or meta"
else
  PASS=$((PASS + 1))
fi


# --- 5. timestamp normalization + position tiebreak on equal seconds ----------
newdir
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

# --- 6. position tiebreak: same second, last-in-file wins --------------------
newdir
mkfixtures "$R/projects"
printf '%s\n' \
  '{"type":"assistant","message":{"id":"msg_u","model":"m","usage":{"input_tokens":1,"output_tokens":222,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"sess-u","timestamp":"2026-09-12T15:26:30.100Z"}' \
  '{"type":"assistant","message":{"id":"msg_u","model":"m","usage":{"input_tokens":1,"output_tokens":333,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"sessionId":"sess-u","timestamp":"2026-09-12T15:26:30.400Z"}' \
  > "$R/projects/Proj/sess-u.jsonl"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_grep "max ts wins over file order (both fractional)" '"tokens_out":333'

# --- 7. arg validation ---------------------------------------------------------
newdir
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

# --- 8. subagent transcripts: role, parent session fallback, meta key --------
newdir
mkdir -p "$R/projects/Proj/sess-p/subagents/deeper"
sub='{"type":"assistant","message":{"id":"msg_s","model":"m","usage":{"input_tokens":1,"output_tokens":2}},"timestamp":"2026-01-01T00:00:00.000Z","isSidechain":true}'
printf '%s\n' "$sub" > "$R/projects/Proj/sess-p/subagents/agent-abc.jsonl"
printf '%s\n' "$sub" > "$R/projects/Proj/sess-p/subagents/deeper/agent-zzz.jsonl"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_count "subagent file imported once, deeper file ignored" 1
expect_grep "subagent role" '"role":"subagent"'
expect_grep "parent session as fallback session" '"session":"sess-p"'
if cut -f1 "$R/.usage/usage.meta" | grep -qx 'sess-p/subagents/agent-abc'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: meta key sess-p/subagents/agent-abc"
fi

# --- 9. mtime column = .NET ticks; ps1-written and legacy meta lines ----------
newdir
mkfixtures "$R/projects"
mkdir -p "$R/.usage"
touch -d '2026-01-01 00:00:00.5 UTC' "$R/projects/Proj/sess-a.jsonl"
touch -d '2026-01-01 00:00:00.5 UTC' "$R/projects/Proj/sess-b.jsonl"
printf 'sess-a\t2026-01-01T00:00:00.000000\t639028224005000000\nsess-b\t2026-01-01T00:00:00.000000\n' > "$R/.usage/usage.meta"
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
expect_count "unchanged ticks skipped unparsed, legacy line re-imported" 1
expect_grep "legacy session imported" '"msg":"msg_9"'
if grep -qxF "$(printf 'sess-b\t2026-09-12T15:28:00.000000\t639028224005000000')" "$R/.usage/usage.meta" \
  && grep -qxF "$(printf 'sess-a\t2026-01-01T00:00:00.000000\t639028224005000000')" "$R/.usage/usage.meta"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: meta ticks (got: $(cat "$R/.usage/usage.meta"))"
fi

# --- 10. a killed run keeps its progress; the next run converges --------------
newdir
mkdir -p "$R/projects/Proj"
for i in $(seq 1 40); do
  printf '{"type":"assistant","message":{"id":"msg_k%s","model":"m","usage":{"input_tokens":1,"output_tokens":2}},"sessionId":"sess-k%s","timestamp":"2026-01-01T00:00:00.000Z"}\n' "$i" "$i" > "$R/projects/Proj/sess-k$i.jsonl"
done
{ timeout -s KILL 1.5 bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1; } 2>/dev/null
if [ -s "$(sink)" ] && [ -s "$R/.usage/usage.meta" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: killed run kept no progress (sink/meta empty)"
fi
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$R/.usage/usage.jsonl" >/dev/null 2>&1
got=$(grep -o '"msg":"msg_k[0-9]*"' "$(sink)" | sort -u | wc -l)
if [ "$got" -eq 40 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: rerun after kill converges (want 40 distinct msgs, got $got)"
fi

# --- 11. a concurrent appender never splices a record -------------------------
newdir
mkdir -p "$R/projects/Proj" "$R/.usage"
big="$(head -c 2000 /dev/zero | tr '\0' 'x')"
for i in $(seq 1 300); do
  printf '{"type":"assistant","message":{"id":"msg_b%s","model":"%s","usage":{"input_tokens":1,"output_tokens":2}},"sessionId":"sess-b","timestamp":"2026-01-01T00:00:00.000Z"}\n' "$i" "$big"
done > "$R/projects/Proj/sess-b.jsonl"
printf '{"other":"%s"}\n' "$big" > "$R/other.line"
( for _ in $(seq 1 40); do cat "$R/other.line" >> "$(sink)"; done ) &
appender=$!
bash "$IMPORT" --dir "$R/projects" --project Proj --out "$(sink)" >/dev/null 2>&1
wait "$appender"
bad=$(grep -vc '^{.*}$' "$(sink)" || true)
total=$(grep -c . "$(sink)")
if [ "$bad" -eq 0 ] && [ "$total" -eq 340 ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: concurrent append spliced a record (bad=$bad total=$total, want 0/340)"
fi

# --- summary -----------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
