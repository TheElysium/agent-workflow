#!/usr/bin/env bash
# Import token usage from Claude Code session transcripts into the
# harness-neutral sink consumed by scripts/usage-report.sh.
#
# Source: ~/.claude/projects/<project>/<session>.jsonl — one record per
# message; assistant messages carry message.usage, and message ids repeat
# (streaming snapshots) so the LAST occurrence per id wins.
#
# Idempotent: a high-water mark per session (.usage/usage.meta) skips
# records whose timestamp is <= the last import. Run it as often as needed.
#
# Usage: scripts/usage-import-claude.sh --dir ~/.claude/projects \
#          --project <slug> [--out .usage/usage.jsonl]
# Exit:  0 on success (empty import is valid), 1 on bad usage / no source.

set -euo pipefail

DIR="$HOME/.claude/projects"
PROJECT=""
OUT=".usage/usage.jsonl"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;;
    --project) PROJECT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    *) echo "usage-import-claude.sh: unknown arg '$1'" >&2; exit 1;;
  esac
done

[ -n "$PROJECT" ] || { echo "usage-import-claude.sh: --project is required" >&2; exit 1; }
SRC="$DIR/$PROJECT"
[ -d "$SRC" ] || { echo "usage-import-claude.sh: no transcript dir: $SRC" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
META="${OUT%.jsonl}.meta"
touch "$OUT" "$META"

for f in "$SRC"/*.jsonl; do
  [ -f "$f" ] || exit 0
  session="$(basename "$f" .jsonl)"
  since="$(awk -F'\t' -v s="$session" '$1 == s { print $2 }' "$META")"

  tmp="$(mktemp /tmp/usage-import.XXXXXX)"
  parsed="$(mktemp /tmp/usage-import.XXXXXX)"
  keep_tmp=""
  if [ -n "${USAGE_IMPORT_DEBUG:-}" ]; then
    tmp="$PWD/.usage-import-debug-$session.jsonl"
    keep_tmp=1
  fi
  # 1) parse each raw line (invalid lines yield nothing via fromjson?)
  # 2) keep assistant messages with usage; map to the neutral schema; ts is
  #    emitted canonical (whole seconds) but _sort keeps full precision:
  #    the fraction is padded to 6 digits (missing fraction = .000000) so
  #    any precision mix orders correctly
  # 3) drop already-imported records, dedup per message id: max sort key
  #    wins, ties broken by later position in the file (the last CC
  #    snapshot holds the final usage)
  jq -R -c --arg session "$session" '
    (fromjson?)
    | select(.type == "assistant")
    | .message as $m
    | select($m.id != null and $m.usage != null)
    | {
        ts: (.timestamp | sub("\\.[0-9]+Z$"; "Z")),
        _sort: (
          .timestamp
          | if test("\\.[0-9]+Z$") then
              capture("(?<base>[^\\.]+)\\.(?<frac>[0-9]+)Z$") as $c
              | "\($c.base).\(($c.frac + "000000")[0:6])"
            else sub("Z$"; "") + ".000000" end
        ),
        harness: "claude",
        session: (.sessionId // $session),
        msg: $m.id,
        role: (if .isSidechain == true then "subagent"
               elif .isSidechain == false then "primary"
               else "unknown" end),
        model: ($m.model // "unknown"),
        tokens_in: ($m.usage.input_tokens // 0),
        tokens_out: ($m.usage.output_tokens // 0),
        cache_read: ($m.usage.cache_read_input_tokens // 0),
        cache_write: ($m.usage.cache_creation_input_tokens // 0)
      }
  ' "$f" > "$parsed"
  jq -s -c --arg since "$since" '
      to_entries
      | map(select(.value._sort > $since))
      | group_by(.value.msg)
      | map(max_by([.value._sort, .key]) | .value | del(._sort))
      | .[]
    ' "$parsed" \
  > "$tmp"

  # high-water mark stores the full-precision sort key so mid-stream
  # imports (fractional snapshots inside an already-imported second)
  # are never skipped
  max_ts="$(jq -s -r --arg since "$since" 'map(select(._sort > $since) | ._sort) | max // ""' "$parsed")"

  if [ -s "$tmp" ]; then
    cat "$tmp" >> "$OUT"
  fi

  if [ -n "$max_ts" ]; then
    # rewrite the session's high-water mark if it advanced
    awk -F'\t' -v s="$session" '$1 != s' "$META" > "$META.tmp"
    printf '%s\t%s\n' "$session" "$max_ts" >> "$META.tmp"
    mv "$META.tmp" "$META"
  fi
  if [ -n "$keep_tmp" ]; then
    rm -f "$parsed"   # keep only the final dedup file for inspection
  else
    rm -f "$tmp" "$parsed"
  fi
done
