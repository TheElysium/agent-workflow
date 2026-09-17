#!/usr/bin/env bash
# Smoke tests for scripts/session-tools.sh.
#
# Contract:
#   - Default output: one TSV row per tool call (thread, time, tool, summary,
#     status, error text).
#   - With --summary: additionally emits per-thread tool counts and per-thread
#     token totals (machine-readable TSV tables).
#
# Usage:  bash scripts/test-session-tools.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/session-tools.sh"

PASS=0
FAIL=0

R="$(mktemp -d /tmp/session-tools-test.XXXXXX)"
cleanup() { rm -rf "$R"; }
trap cleanup EXIT

run() { # run [args...] — sets OUT and RC
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

expect_rc() { # expect_rc <desc> <want>
  if [ "$RC" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 (want rc=$2, got rc=$RC)  [out: ${OUT:0:140}]"
  fi
}

expect_eq() { # expect_eq <desc> <expected-string> — exact match on OUT
  local desc="$1" expected="$2"
  local diffout
  diffout="$(diff -u <(printf '%s' "$expected") <(printf '%s' "$OUT") 2>&1 || true)"
  if [ -z "$diffout" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "$diffout"
  fi
}

# --- 1. missing transcript arg -> usage error, nonzero ------------------------
run
expect_rc "missing transcript exits nonzero" 1

# --- 2. empty transcript -> empty output, exit 0 ------------------------------
: > "$R/empty.jsonl"
run "$R/empty.jsonl"
expect_rc "empty transcript exits 0" 0
expect_eq "empty transcript produces no output" ""

# --- 3. transcript with no tool calls -> empty output, exit 0 -----------------
{
  echo '{"type":"user","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"user","content":"hello"}}'
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}'
} > "$R/notools.jsonl"
run "$R/notools.jsonl"
expect_rc "no-tool-calls transcript exits 0" 0
expect_eq "no-tool-calls transcript produces no output" ""

# --- 4. ok Bash tool_use + tool_result ----------------------------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_bash","name":"Bash","input":{"command":"echo hello"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_bash","is_error":false,"content":[{"type":"text","text":"hello"}]}]}}'
} > "$R/ok.jsonl"
run "$R/ok.jsonl"
expect_rc "ok Bash exits 0" 0
expect_eq "ok Bash row" $'main\t12:00:00\tBash\techo hello\t\t'

# --- 5. is_error result -> ERROR row ------------------------------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_err","name":"Bash","input":{"command":"badcmd"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_err","is_error":true,"content":[{"type":"text","text":"command not found"}]}]}}'
} > "$R/error.jsonl"
run "$R/error.jsonl"
expect_rc "ERROR row exits 0" 0
expect_eq "ERROR row" $'main\t12:00:00\tBash\tbadcmd\tERROR\tcommand not found'

# --- 6. FLAG via regex hit in non-error output --------------------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_flag","name":"Bash","input":{"command":"exit 1"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_flag","is_error":false,"content":[{"type":"text","text":"Process finished with non-zero exit code 1"}]}]}}'
} > "$R/flag.jsonl"
run "$R/flag.jsonl"
expect_rc "FLAG row exits 0" 0
expect_eq "FLAG row" $'main\t12:00:00\tBash\texit 1\tFLAG\tProcess finished with non-zero exit code 1'

# --- 7. Read with offset/limit bracket formatting -----------------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_read","name":"Read","input":{"file_path":"README.md","offset":10,"limit":5}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_read","is_error":false,"content":[{"type":"text","text":"# Title"}]}]}}'
} > "$R/read.jsonl"
run "$R/read.jsonl"
expect_rc "Read row exits 0" 0
expect_eq "Read row with offset/limit" $'main\t12:00:00\tRead\tREADME.md [offset=10 limit=5]\t\t'

# --- 8. --cut filtering (lexical ISO-8601 Z compare) --------------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_before","name":"Bash","input":{"command":"early"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_before","is_error":false,"content":[{"type":"text","text":"ok"}]}]}}'
  echo '{"type":"assistant","timestamp":"2026-09-16T13:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_after","name":"Bash","input":{"command":"late"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T13:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_after","is_error":false,"content":[{"type":"text","text":"ok"}]}]}}'
} > "$R/cut.jsonl"
run "$R/cut.jsonl" --cut "2026-09-16T12:30:00Z"
expect_rc "--cut exits 0" 0
expect_eq "--cut keeps only rows before cut" $'main\t12:00:00\tBash\tearly\t\t'

# --- 9. --cut boundary at exact second (millisecond timestamps) ---------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T10:00:00.500Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_boundary","name":"Bash","input":{"command":"edge"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T10:00:01.500Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_boundary","is_error":false,"content":[{"type":"text","text":"ok"}]}]}}'
} > "$R/boundary.jsonl"
run "$R/boundary.jsonl" --cut "2026-09-16T10:00:00Z"
expect_rc "--cut boundary exits 0" 0
expect_eq "--cut excludes boundary second with ms timestamp" ""

# --- 10. --thread labeling ----------------------------------------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_t","name":"Bash","input":{"command":"echo"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_t","is_error":false,"content":[{"type":"text","text":""}]}]}}'
} > "$R/thread.jsonl"
run "$R/thread.jsonl" --thread alpha
expect_rc "--thread exits 0" 0
expect_eq "--thread labels rows" $'alpha\t12:00:00\tBash\techo\t\t'

# --- 11. tool_result MISSING for a tool_use -> no ERROR false-positive --------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_orphan","name":"Bash","input":{"command":"orphan"}}]}}'
} > "$R/missing-result.jsonl"
run "$R/missing-result.jsonl"
expect_rc "missing tool_result exits 0" 0
expect_eq "missing tool_result leaves status empty" $'main\t12:00:00\tBash\torphan\t\t'

# --- 12. DUPLICATE tool_use id -> deduped, one row ----------------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_dup","name":"Bash","input":{"command":"first"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_dup","is_error":false,"content":[{"type":"text","text":"ok"}]}]}}'
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:02.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_dup","name":"Bash","input":{"command":"second"}}]}}'
} > "$R/duplicate.jsonl"
run "$R/duplicate.jsonl"
expect_rc "duplicate tool_use id exits 0" 0
expect_eq "duplicate tool_use id is deduped" $'main\t12:00:00\tBash\tfirst\t\t'

# --- 13. --subagents with labels, interleaving, token sums --------------------
mkdir -p "$R/subagents"
# main at 12:00
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_main","name":"Bash","input":{"command":"main-cmd"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_main","is_error":false,"content":[{"type":"text","text":"main-out"}]}]}}'
} > "$R/subagents/main.jsonl"
# agent-a: label from meta.json = gate-keeper, at 11:30, has token usage
{
  echo '{"type":"assistant","timestamp":"2026-09-16T11:30:00.000Z","message":{"role":"assistant","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":7},"content":[{"type":"tool_use","id":"tu_a","name":"Bash","input":{"command":"agent-a-cmd"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T11:30:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_a","is_error":false,"content":[{"type":"text","text":"agent-a-out"}]}]}}'
} > "$R/subagents/agent-a.jsonl"
echo '{"agentType":"gate-keeper"}' > "$R/subagents/agent-a.meta.json"
# agent-b: no meta -> label is file stem, at 11:45, has token usage
{
  echo '{"type":"assistant","timestamp":"2026-09-16T11:45:00.000Z","message":{"role":"assistant","usage":{"input_tokens":20,"output_tokens":0,"cache_creation_input_tokens":50,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"tu_b","name":"Bash","input":{"command":"agent-b-cmd"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T11:45:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_b","is_error":false,"content":[{"type":"text","text":"agent-b-out"}]}]}}'
} > "$R/subagents/agent-b.jsonl"

run "$R/subagents/main.jsonl" --subagents "$R/subagents" --summary
expect_rc "--subagents exits 0" 0
EXPECT=$'gate-keeper\t11:30:00\tBash\tagent-a-cmd\t\t\nagent-b\t11:45:00\tBash\tagent-b-cmd\t\t\nmain\t12:00:00\tBash\tmain-cmd\t\t\n\nthread\ttool\tcount\nagent-b\tBash\t1\ngate-keeper\tBash\t1\nmain\tBash\t1\n\nthread\tcalls\terrors\tflags\tassistant_turns\tinput_tokens\toutput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\tbilled_volume\nagent-b\t1\t0\t0\t1\t20\t0\t50\t0\t70\ngate-keeper\t1\t0\t0\t1\t10\t5\t100\t7\t122\nmain\t1\t0\t0\t1\t0\t0\t0\t0\t0'
expect_eq "--subagents interleaving and summary" "$EXPECT"

# --- 14. --subagents nonexistent dir -> warning on stderr, main still works ----
{
  echo '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_warn","name":"Bash","input":{"command":"warn-cmd"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_warn","is_error":false,"content":[{"type":"text","text":"ok"}]}]}}'
} > "$R/warn-main.jsonl"
OUT="$(bash "$SCRIPT" "$R/warn-main.jsonl" --subagents "$R/no-such-dir" 2>"$R/warn.err")"
RC=$?
expect_rc "nonexistent subagents dir exits 0" 0
expect_eq "nonexistent subagents dir processes main only" $'main\t12:00:00\tBash\twarn-cmd\t\t'
if grep -qF "no-such-dir" "$R/warn.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: nonexistent subagents dir warning on stderr mentions path  [err: $(head -c 200 "$R/warn.err")]"
fi

# --- 15. --cut filters summary totals (tool counts + tokens) ------------------
{
  echo '{"type":"assistant","timestamp":"2026-09-16T11:00:00.000Z","message":{"role":"assistant","usage":{"input_tokens":5,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"tu_in","name":"Bash","input":{"command":"in-cut"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T11:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_in","is_error":false,"content":[{"type":"text","text":"ok"}]}]}}'
  echo '{"type":"assistant","timestamp":"2026-09-16T13:00:00.000Z","message":{"role":"assistant","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"tu_out","name":"Bash","input":{"command":"out-of-cut"}}]}}'
  echo '{"type":"user","timestamp":"2026-09-16T13:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_out","is_error":false,"content":[{"type":"text","text":"ok"}]}]}}'
} > "$R/cut-summary.jsonl"
run "$R/cut-summary.jsonl" --cut "2026-09-16T12:00:00Z" --summary
expect_rc "--cut with summary exits 0" 0
EXPECT=$'main\t11:00:00\tBash\tin-cut\t\t\n\nthread\ttool\tcount\nmain\tBash\t1\n\nthread\tcalls\terrors\tflags\tassistant_turns\tinput_tokens\toutput_tokens\tcache_creation_input_tokens\tcache_read_input_tokens\tbilled_volume\nmain\t1\t0\t0\t1\t5\t3\t0\t0\t8'
expect_eq "--cut excludes post-cut rows from summary" "$EXPECT"

# --- 16. option missing value -> friendly usage error -------------------------
run "$R/ok.jsonl" --cut
expect_rc "missing --cut value exits nonzero" 1
if grep -qF -- "--cut requires a value" <<< "$OUT"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: missing --cut value names the option  [out: ${OUT:0:200}]"
fi

# --- 17. FLAG scope + regex precision -----------------------------------------
# tool_case <desc> <field> <tool> <input-json> <result-text> <want>
#   one tool call + its result; compares TSV column <field> of the single row.
tool_case() {
  local desc="$1" field="$2" tool="$3" input="$4" text="$5" want="$6"
  {
    jq -b -nc --arg n "$tool" --argjson i "$input" \
      '{type:"assistant",timestamp:"2026-09-16T12:00:00.000Z",message:{role:"assistant",content:[{type:"tool_use",id:"tu_f",name:$n,input:$i}]}}'
    jq -b -nc --arg t "$text" \
      '{type:"user",timestamp:"2026-09-16T12:00:01.000Z",message:{role:"user",content:[{type:"tool_result",tool_use_id:"tu_f",is_error:false,content:[{type:"text",text:$t}]}]}}'
  } > "$R/tool-case.jsonl"
  run "$R/tool-case.jsonl"
  local got
  got="$(printf '%s' "$OUT" | cut -f"$field")"
  if [ "$RC" = 0 ] && [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (want '$want', got '$got', rc=$RC)  [out: ${OUT:0:200}]"
  fi
}

# flag_case <desc> <tool> <input-json> <result-text> <want-status>
flag_case() { tool_case "$1" 5 "$2" "$3" "$4" "$5"; }

# Content tools never FLAG, whatever the text says.
flag_case "Read content with failure words is not flagged" Read '{"file_path":"a.md"}' "BLOCKED by shunt: Error: FAIL failed" ""
flag_case "Grep content with failure words is not flagged" Grep '{"pattern":"x"}' "a.sh:3: echo FAIL: Error:" ""
flag_case "Glob result is not flagged" Glob '{"pattern":"*"}' "failed.log" ""
# Command tools: passing summaries are not failures.
flag_case "Bash FAIL=0 summary is not flagged" Bash '{"command":"t"}' "PASS=17 FAIL=0" ""
flag_case "Bash '0 failed' summary is not flagged" Bash '{"command":"t"}' "results: 32 passed, 0 failed" ""
flag_case "Bash word shunt alone is not flagged" Bash '{"command":"t"}' "shunt.sh updated" ""
# Command tools: real failures still flag.
flag_case "Bash FAIL=2 is flagged" Bash '{"command":"t"}' "PASS=3 FAIL=2" "FLAG"
flag_case "Bash '10 failed' is flagged" Bash '{"command":"t"}' "results: 5 passed, 10 failed" "FLAG"
flag_case "Bash 'FAIL:' line is flagged" Bash '{"command":"t"}' "FAIL: case one" "FLAG"
flag_case "Bash cargo FAILED is flagged" Bash '{"command":"t"}' "test result: FAILED. 1 passed" "FLAG"
flag_case "Bash 'command failed' is flagged" Bash '{"command":"t"}' "npm ERR! command failed" "FLAG"
flag_case "Bash BLOCKED is flagged" Bash '{"command":"t"}' "BLOCKED by shunt: file too large" "FLAG"
flag_case "Bash exit code is flagged" Bash '{"command":"t"}' "Exit code 2" "FLAG"
flag_case "PowerShell Error: is flagged" PowerShell '{"command":"t"}' "Error: access denied" "FLAG"
# Multi-line output: '0 failed' at line start is a pass, '10 failed' is not.
flag_case "Bash '0 failed' at line start is not flagged" Bash '{"command":"t"}' $'32 passed\n0 failed' ""
flag_case "Bash '10 failed' at line start is flagged" Bash '{"command":"t"}' $'5 passed\n10 failed' "FLAG"

# --- 18. summary column per tool ----------------------------------------------
# summ_case <desc> <tool> <input-json> <want-summary>
summ_case() { tool_case "$1" 4 "$2" "$3" "ok" "$4"; }

summ_case "Read without offset/limit" Read '{"file_path":"a.md"}' "a.md"
summ_case "Read with limit only" Read '{"file_path":"a.md","limit":5}' "a.md [offset=- limit=5]"
summ_case "Edit shows file path" Edit '{"file_path":"a.sh","old_string":"x","new_string":"y"}' "a.sh"
summ_case "Write shows file path" Write '{"file_path":"b.md","content":"z"}' "b.md"
summ_case "Grep shows pattern/path/glob" Grep '{"pattern":"foo","path":"src","glob":"*.sh"}' "pattern=foo path=src glob=*.sh"
summ_case "Grep with pattern only" Grep '{"pattern":"foo"}' "pattern=foo path= glob="
summ_case "Glob shows pattern/path" Glob '{"pattern":"**/*.md","path":"docs"}' "pattern=**/*.md path=docs"
summ_case "Agent shows type and description" Agent '{"subagent_type":"reviewer","description":"review diff","prompt":"p"}' "reviewer | review diff"
summ_case "AskUserQuestion joins headers" AskUserQuestion '{"questions":[{"header":"Scope","question":"a?"},{"header":"Push","question":"b?"}]}' "Scope, Push"
summ_case "AskUserQuestion without questions" AskUserQuestion '{}' ""
summ_case "ToolSearch shows query" ToolSearch '{"query":"select:Monitor","max_results":1}' "select:Monitor"
summ_case "Unknown tool falls back to input JSON" TodoWrite '{"todos":[]}' '{"todos":[]}'
summ_case "Bash multi-line command is flattened" Bash '{"command":"echo a\necho b"}' "echo a echo b"
summ_case "Summary truncated to 240 chars" Bash "{\"command\":\"$(printf 'x%.0s' $(seq 300))\"}" "$(printf 'x%.0s' $(seq 240))"

# --- 19. help and unknown option ----------------------------------------------
run -h
expect_rc "-h exits 0" 0
expect_eq "-h prints usage" "usage: session-tools.sh <session.jsonl> [--thread <label>] [--cut <ISO-8601-Z>] [--subagents <dir>] [--summary]"
run "$R/ok.jsonl" --bogus
expect_rc "unknown option exits nonzero" 1
if grep -qF -- "unknown option '--bogus'" <<< "$OUT"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: unknown option is named  [out: ${OUT:0:200}]"
fi

# --- summary -----------------------------------------------------------------
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
