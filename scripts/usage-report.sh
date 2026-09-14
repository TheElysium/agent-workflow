#!/usr/bin/env bash
# Aggregate the harness-neutral JSONL sink written by the adapters
# (.opencode/plugins/usage-log.ts and scripts/usage-import-claude.sh).
#
# Duplicate records (same harness+session+msg — repeated message.updated
# events or CC snapshot imports) collapse to the last record per key.
#
# Usage: scripts/usage-report.sh [--file .usage/usage.jsonl]
#                                [--since <ts>] [--session <id>]
# Exit:  0 on success, 1 on bad usage / missing sink.

set -euo pipefail

FILE=".usage/usage.jsonl"
SINCE=""
SESSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --session) SESSION="$2"; shift 2;;
    *) echo "usage-report.sh: unknown arg '$1'" >&2; exit 1;;
  esac
done

[ -f "$FILE" ] || { echo "usage-report.sh: no sink: $FILE" >&2; exit 1; }

raw="$(wc -l < "$FILE" | tr -d ' ')"

jq -s -r --arg since "$SINCE" --arg sess "$SESSION" --argjson raw "$raw" '
  def tot(a): ([a[].tokens_in] | add // 0) as $i
    | ([a[].tokens_out] | add // 0) as $o
    | "\($i) in / \($o) out";
  def mod(a): a
    | group_by(.model)
    | map("  \(.[0].model): \([.[] | .tokens_in] | add // 0) in / \([.[] | .tokens_out] | add // 0) out")
    | .[];
  map(select(.ts > $since and ($sess == "" or .session == $sess)))
  | to_entries
  | group_by(.value.harness + "\u0001" + .value.session + "\u0001" + .value.msg)
  | map(max_by(.key) | .value) as $recs
  | ($recs | map(select(.role == "primary"))) as $pri
  | ($recs | map(select(.role == "subagent"))) as $sub
  | ($recs | map(select(.role != "primary" and .role != "subagent"))) as $unk
  | "records: \($recs | length) (deduped from \($raw))",
    "primary: \(tot($pri))   (cache_read \([$pri[].cache_read] | add // 0), cache_write \([$pri[].cache_write] | add // 0))",
    "subagent: \(tot($sub))",
    "unknown: \(tot($unk))",
    "by model:",
    (mod($pri + $sub + $unk))
' "$FILE"
