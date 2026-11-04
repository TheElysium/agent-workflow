#!/usr/bin/env bash
# Aggregate the harness-neutral JSONL sink written by the adapters
# (.opencode/plugins/usage-log.ts and usage-import-claude.sh).
#
# Duplicate records (same harness+session+msg) collapse to the last record
# per key.
#
# Usage: usage-report.sh [--file .usage/usage.jsonl] [--since <ts>] [--session <id>]
# Exit:  0 on success, 1 on bad usage / missing sink, 5 on invalid JSON.

set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'

FILE=".usage/usage.jsonl"
SINCE=""
SESSION=""

need_value() {
  [ "$2" -ge 2 ] || { echo "usage-report.sh: $1 requires a value" >&2; exit 1; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file) need_value "$1" $#; FILE="$2"; shift 2;;
    --since) need_value "$1" $#; SINCE="$2"; shift 2;;
    --session) need_value "$1" $#; SESSION="$2"; shift 2;;
    *) echo "usage-report.sh: unknown arg '$1'" >&2; exit 1;;
  esac
done

[ -f "$FILE" ] || { echo "usage-report.sh: no sink: $FILE" >&2; exit 1; }

raw="$(wc -l < "$FILE")"
raw="${raw//[[:space:]]/}"

# shellcheck disable=SC2016
REPORT='
def n(f): [.[] | f // 0] | add // 0;
def tot: "\(n(.tokens_in)) in / \(n(.tokens_out)) out";
def cache: "(cache_read \(n(.cache_read)), cache_write \(n(.cache_write)))";
[ inputs | select(test("[^[:space:]]")) | try fromjson catch {__invalid: true} ] as $all
| if any($all[]; type == "object" and has("__invalid")) then "INVALID" else
  ($all
    | map(select(type == "object"))
    | map(select((.ts // "" | tostring) > $since
                 and ($sess == "" or (.session // "" | tostring) == $sess)))
    | to_entries
    | group_by("\(.value.harness)\u0001\(.value.session)\u0001\(.value.msg)")
    | map(max_by(.key) | .value)) as $recs
  | ($recs | map(select(.role == "primary"))) as $pri
  | ($recs | map(select(.role == "subagent"))) as $sub
  | ($recs | map(select(.role != "primary" and .role != "subagent"))) as $unk
  | "records: \($recs | length) (deduped from \($raw))",
    "primary: \($pri | tot)   \($pri | cache)",
    "subagent: \($sub | tot)   \($sub | cache)",
    "unknown: \($unk | tot)",
    "by model:",
    ($pri + $sub + $unk
      | map(. + {m: (if .model == null then null else .model | tostring end)})
      | group_by(.m)
      | .[]
      | "  \(.[0].m // "null"): \(tot)")
  end
'

out="$(jq -b -n -R -r --arg since "$SINCE" --arg sess "$SESSION" --argjson raw "$raw" "$REPORT" < "$FILE" 2>/dev/null)" || out="INVALID"
if [ -z "$out" ] || [ "$out" = "INVALID" ]; then
  echo "usage-report.sh: invalid json in $FILE" >&2
  exit 5
fi
printf '%s\n' "$out"
