#!/usr/bin/env bash
# Import token usage from Claude Code transcripts into the harness-neutral
# sink read by usage-report.sh. Idempotent: .meta keeps, per transcript, a
# high-water sort key and the file mtime in .NET ticks.
#
# Usage: usage-import-claude.sh --project <slug> [--dir ~/.claude/projects] [--out .usage/usage.jsonl]
# Exit:  0 on success (empty import is valid), 1 on bad usage / no source.

set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'

DIR="$HOME/.claude/projects"
PROJECT=""
OUT=".usage/usage.jsonl"

need_value() {
  [ "$2" -ge 2 ] || { echo "usage-import-claude.sh: missing value for '$1'" >&2; exit 1; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) need_value "$1" $#; DIR="$2"; shift 2;;
    --project) need_value "$1" $#; PROJECT="$2"; shift 2;;
    --out) need_value "$1" $#; OUT="$2"; shift 2;;
    *) echo "usage-import-claude.sh: unknown arg '$1'" >&2; exit 1;;
  esac
done

[ -n "$PROJECT" ] || { echo "usage-import-claude.sh: --project is required" >&2; exit 1; }
SRC="$DIR/$PROJECT"
[ -d "$SRC" ] || { echo "usage-import-claude.sh: no transcript dir: $SRC" >&2; exit 1; }

case "$OUT" in
  */*)
    out_parent="${OUT%/*}"
    [ -n "$out_parent" ] || out_parent="/"
    parent_is_new=""
    [ -e "$out_parent" ] || parent_is_new=1
    mkdir -p "$out_parent"
    if [ -n "$parent_is_new" ] && [ "${out_parent##*/}" = ".usage" ]; then
      printf '*\n' > "$out_parent/.gitignore" 2>/dev/null || true
    fi;;
esac

case "$OUT" in
  *.jsonl) META="${OUT%.jsonl}.meta";;
  *) META="$OUT.meta";;
esac
[ -e "$OUT" ] || : > "$OUT"
[ -e "$META" ] || : > "$META"

# shellcheck disable=SC2016
EXTRACT='
def sortkey:
  if test("[.][0-9]+Z$") then
    capture("(?<base>[^.]+)[.](?<frac>[0-9]+)Z$") as $c
    | "\($c.base).\(($c.frac + "000000")[0:6])"
  else sub("Z$"; "") + ".000000" end;
[ inputs
  | fromjson?
  | select(type == "object" and .type == "assistant")
  | (.timestamp // "" | tostring) as $t
  | .message as $m
  | select(($m | type) == "object" and $m.id != null and $m.usage != null)
  | {
      ts: ($t | sub("[.][0-9]+Z$"; "Z")),
      _sort: ($t | sortkey),
      harness: "claude",
      session: (.sessionId // $session),
      msg: ($m.id | tostring),
      role: (if .isSidechain == true then "subagent"
             elif .isSidechain == false then "primary"
             else "unknown" end),
      model: ($m.model // "unknown"),
      tokens_in: ($m.usage.input_tokens // 0),
      tokens_out: ($m.usage.output_tokens // 0),
      cache_read: ($m.usage.cache_read_input_tokens // 0),
      cache_write: ($m.usage.cache_creation_input_tokens // 0)
    }
] | to_entries
  | map(select(.value._sort > $since)) as $kept
| ($kept | group_by(.value.msg)
    | map(max_by([.value._sort, .key]) | .value | del(._sort) | tojson) | .[]),
  "M:" + ($kept | map(.value._sort) | max // "")
'

declare -A PATH_OF=() SESSION_OF=() META_TS=() META_TICKS=() TICKS_OF=()
META_KEYS=()

while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  key="${line%%$'\t'*}"
  max_ts=""
  ticks=""
  if [[ "$line" == *$'\t'* ]]; then
    rest="${line#*$'\t'}"
    max_ts="${rest%%$'\t'*}"
    if [[ "$rest" == *$'\t'* ]]; then
      ticks="${rest#*$'\t'}"
      ticks="${ticks%%$'\t'*}"
    fi
  fi
  [ -n "${META_TS[$key]+x}" ] || META_KEYS+=("$key")
  META_TS[$key]="$max_ts"
  META_TICKS[$key]="$ticks"
done < "$META"

stat -c %.9Y -- "$SRC" >/dev/null 2>&1 || { echo "usage-import-claude.sh: GNU coreutils stat (stat -c) is required" >&2; exit 1; }

SRC_PREFIX="${SRC%/}/"
while IFS= read -r -d '' rec; do
  stamp="${rec%% *}"
  rel="${rec#* }"
  rel="${rel#"$SRC_PREFIX"}"
  secs="${stamp%.*}"
  frac="${stamp#*.}"
  case "$rel" in
    */*/*)
      [[ "$rel" == */subagents/agent-*.jsonl && "$rel" != */*/*/* ]] || continue
      key="${rel%.jsonl}"
      session="${rel%%/*}";;
    */*) continue;;
    *) key="${rel%.jsonl}"; session="$key";;
  esac
  PATH_OF[$key]="$SRC_PREFIX$rel"
  SESSION_OF[$key]="$session"
  TICKS_OF[$key]=$(( (secs + 62135596800) * 10000000 + 10#$frac / 100 ))
done < <(find "$SRC" -mindepth 1 -maxdepth 3 -type f -name '*.jsonl' -exec stat -c '%.9Y %n' -- {} + 2>/dev/null | tr '\n' '\0' || true)

[ "${#PATH_OF[@]}" -gt 0 ] || exit 0

write_meta() {
  local k
  {
    for k in "${META_KEYS[@]}"; do
      printf '%s\t%s\t%s\n' "$k" "${META_TS[$k]}" "${META_TICKS[$k]}"
    done
  } > "$META.tmp.$$"
  mv -f "$META.tmp.$$" "$META"
}

GROUP_MAX=60000
FLUSH_FILES=8
FLUSH_SECONDS=3

append_pending() {
  local LC_ALL=C group rest="${pending%$'\n'}"
  while [ -n "$rest" ]; do
    if [ "${#rest}" -le "$GROUP_MAX" ]; then
      group="$rest"
      rest=""
    else
      group="${rest:0:GROUP_MAX}"
      if [[ "$group" == *$'\n'* ]]; then
        group="${group%$'\n'*}"
      else
        group="${rest%%$'\n'*}"
      fi
      rest="${rest:${#group}}"
      rest="${rest#$'\n'}"
    fi
    cat <<< "$group" >> "$OUT"
  done
}

flush() {
  [ -z "$pending" ] || append_pending
  [ -z "$changed" ] || write_meta
  pending=""
  changed=""
  since_flush=0
  last_flush=$SECONDS
}

mapfile -t SORTED_KEYS < <(printf '%s\n' "${!PATH_OF[@]}" | LC_ALL=C sort)

pending=""
changed=""
since_flush=0
last_flush=$SECONDS
for key in "${SORTED_KEYS[@]}"; do
  ticks="${TICKS_OF[$key]}"
  [ "${META_TICKS[$key]:-}" != "$ticks" ] || continue
  since="${META_TS[$key]:-}"
  result="$(jq -b -n -R -r --arg session "${SESSION_OF[$key]}" --arg since "$since" "$EXTRACT" 2>/dev/null < "${PATH_OF[$key]}")" || continue
  new_max="${result##*$'\n'}"
  [[ "$new_max" == M:* ]] || continue
  new_max="${new_max#M:}"
  lines=""
  case "$result" in
    *$'\n'*) lines="${result%$'\n'*}";;
  esac
  if [ -n "$lines" ]; then
    pending+="$lines"$'\n'
  fi
  if [ -n "${USAGE_IMPORT_DEBUG:-}" ]; then
    debug_path="$PWD/.usage-import-debug-${key//\//-}.jsonl"
    : > "$debug_path"
    [ -z "$lines" ] || printf '%s\n' "$lines" > "$debug_path"
  fi
  [ -n "${META_TS[$key]+x}" ] || META_KEYS+=("$key")
  META_TS[$key]="${new_max:-$since}"
  META_TICKS[$key]="$ticks"
  changed=1
  since_flush=$((since_flush + 1))
  if [ "$since_flush" -ge "$FLUSH_FILES" ] || [ $((SECONDS - last_flush)) -ge "$FLUSH_SECONDS" ]; then
    flush
  fi
done

flush
