#!/usr/bin/env bash
set -Eeuo pipefail
trap 'exit 0' ERR
export MSYS2_ARG_CONV_EXCL='*'

IFS= read -r -d '' input || true

IS_WINDOWS=0
case "${OSTYPE:-}" in msys*|cygwin*|win32*) IS_WINDOWS=1 ;; esac

set_threshold() {
  local name=$1 value=$2 default=$3
  case "$value" in ''|*[!0-9]*) printf -v "$name" '%s' "$default"; return 0 ;; esac
  if [ "$value" -gt 0 ] 2>/dev/null; then
    printf -v "$name" '%s' "$((10#$value))"
  else
    printf -v "$name" '%s' "$default"
  fi
}

set_threshold MIN_LINES "${SHUNT_MIN_LINES:-}" 350
set_threshold MAX_BYTES "${SHUNT_MAX_BYTES:-}" 65536

MAX_LOGGED_CHARS=1000
LAST_REASON=""
LAST_BYTES=""
LAST_LINES=""
LAST_MSG=""
RESOLVED=""
UNQUOTED=""
BS=$'\\'

resolve_path() {
  local p=$1 drive
  RESOLVED=""
  [ -n "$p" ] || return 0
  if [ "$IS_WINDOWS" -eq 0 ]; then RESOLVED=$p; return 0; fi
  if [[ $p == "$BS$BS?$BS"[A-Za-z]:[\\/]* ]]; then p=${p:4}; fi
  if [[ $p =~ ^[A-Za-z]:[\\/] ]]; then
    p=${p//\\//}
    drive=${p:0:1}
    RESOLVED="/${drive,,}${p:2}"
  elif [[ $p =~ ^/[A-Za-z](/.*)?$ ]]; then
    RESOLVED=$p
  elif [[ $p == "$BS$BS"* ]]; then
    RESOLVED=${p//\\//}
  elif [[ $p =~ ^[\\/~] ]]; then
    RESOLVED=""
  else
    RESOLVED=${p//\\//}
  fi
}

redirect_reason() {
  local dash=$'\xe2\x80\x94'
  printf -v LAST_MSG '%s\n' \
    "BLOCKED by shunt: \"$1\" has $2." \
    "Do NOT read this file directly $dash delegate I/O instead:" \
    '  - For analysis/questions across files (incl. minified JSON): use the task tool with subagent "shunt:bulk-reader" (pass file paths + your question; you only consume the summary).' \
    '  - For boilerplate generation: use the task tool with subagent "shunt:code-writer" (pass spec + reference file + target path).' \
    "  - If you must edit a specific section of this file, do a targeted read with BOTH offset and limit (an offset alone reads the unbounded rest of the file) $dash that is allowed."
  LAST_MSG=${LAST_MSG%$'\n'}
}

deny() {
  jq -b -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

ensure_sink_dir() {
  if [ ! -e .usage ]; then
    mkdir -p .usage
    printf '*\n' > .usage/.gitignore
  fi
}

log_event() {
  local tool=$1 decision=$2 reason=$3 p=$4 bytes=$5 lines=$6
  {
    ensure_sink_dir
    jq -b -c \
      --arg tool "$tool" \
      --arg decision "$decision" \
      --arg reason "$reason" \
      --arg path "$p" \
      --argjson bytes "${bytes:-null}" \
      --argjson lines "${lines:-null}" \
      --argjson threshold_bytes "$MAX_BYTES" \
      --argjson threshold_lines "$MIN_LINES" \
      --argjson cap "$MAX_LOGGED_CHARS" \
      '(if (.tool_input | type) == "object" then .tool_input else {} end) as $t
      | {
        ts: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        harness: "claude",
        session: (.session_id // null),
        tool: $tool,
        decision: $decision,
        reason: $reason,
        path: (if $path == "" then null else $path[:$cap] end),
        bytes: $bytes,
        lines: $lines,
        threshold_bytes: $threshold_bytes,
        threshold_lines: $threshold_lines
      } + (
        if $tool == "bash"
        then {command: (($t.command // "")[:$cap])}
        else {offset: ($t.offset // null), limit: ($t.limit // null)}
        end
      )' <<<"$input" | cat >> .usage/shunt.jsonl
  } 2>/dev/null || true
}

check_file() {
  local up bytes lines
  resolve_path "$1"
  up=$RESOLVED
  if [ -z "$up" ] || [ -d "$up" ] || ! bytes=$(stat -c %s -- "$up" 2>/dev/null); then
    LAST_REASON=missing; LAST_BYTES=""; LAST_LINES=""
    return 0
  fi
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    LAST_REASON=bytes; LAST_BYTES=$bytes; LAST_LINES=""
    redirect_reason "$1" "$((bytes / 1024)) KB (threshold: $((MAX_BYTES / 1024)) KB)"
    return 1
  fi
  if [ "$bytes" -eq 0 ]; then
    LAST_REASON=under_threshold; LAST_BYTES=0; LAST_LINES=""
    return 0
  fi
  lines=$(wc -l < "$up" 2>/dev/null) || lines=0
  lines=$((10#${lines//[[:space:]]/}))
  if [ "$lines" -gt "$MIN_LINES" ]; then
    LAST_REASON=lines; LAST_BYTES=$bytes; LAST_LINES=$lines
    redirect_reason "$1" "$lines lines (threshold: $MIN_LINES)"
    return 1
  fi
  LAST_REASON=under_threshold; LAST_BYTES=$bytes; LAST_LINES=$lines
  return 0
}

unquote() {
  local a=$1 first last
  UNQUOTED=$a
  [ "${#a}" -ge 2 ] || return 0
  first=${a:0:1}
  last=${a: -1}
  if { [ "$first" = '"' ] || [ "$first" = "'" ]; } && [ "$first" = "$last" ]; then
    UNQUOTED=${a:1:${#a}-2}
  fi
}

is_bounded_sed() {
  local has_n=0 arg
  for arg in "$@"; do
    case "$arg" in -n|--quiet|--silent) has_n=1 ;; esac
    unquote "$arg"
    case "$UNQUOTED" in *'$'*) return 1 ;; esac
  done
  [ "$has_n" -eq 1 ] || return 1
  for arg in "$@"; do
    unquote "$arg"
    [[ $UNQUOTED =~ ^[0-9]+(,[0-9]+)?p$ ]] && return 0
  done
  return 1
}

is_bounded_head_tail() {
  local arg next=0
  for arg in "$@"; do
    if [ "$next" -eq 1 ]; then
      [[ $arg =~ ^[0-9]+$ ]] && return 0
      return 1
    fi
    case "$arg" in
      -n|-c) next=1 ;;
      -[nc][0-9]*)
        [[ ${arg:2} =~ ^[0-9]+$ ]] && return 0
        return 1
        ;;
    esac
  done
  return 1
}

handle_bash() {
  local cmd=$1 verb f file_count=0 ws=$' \t\r\f\v'
  local -a tokens
  if [ -z "$cmd" ]; then
    log_event bash allow no_input "" "" ""
    return 0
  fi
  if [[ $cmd == *[\|\>\;\`\&]* || $cmd == *$'\n'* ]]; then
    log_event bash allow compound "" "" ""
    return 0
  fi
  if ! [[ $cmd =~ ^[$ws]*(cat|head|tail|less|more|bat|grep|sed|awk|rg|xxd|base64|strings)([$ws]|$) ]]; then
    log_event bash allow verb "" "" ""
    return 0
  fi
  set -f
  IFS=$' \t' read -r -a tokens <<<"$cmd"
  set +f
  verb=${tokens[0]}
  tokens=("${tokens[@]:1}")
  case "$verb" in
    sed)
      if is_bounded_sed ${tokens[@]+"${tokens[@]}"}; then
        log_event bash allow bounded "" "" ""
        return 0
      fi ;;
    head|tail)
      if is_bounded_head_tail ${tokens[@]+"${tokens[@]}"}; then
        log_event bash allow bounded "" "" ""
        return 0
      fi ;;
  esac
  for f in ${tokens[@]+"${tokens[@]}"}; do
    case "$f" in -*) continue ;; esac
    file_count=$((file_count + 1))
    if check_file "$f"; then
      log_event bash allow "$LAST_REASON" "$f" "$LAST_BYTES" "$LAST_LINES"
    else
      log_event bash deny "$LAST_REASON" "$f" "$LAST_BYTES" "$LAST_LINES"
      deny "$LAST_MSG"
    fi
  done
  if [ "$file_count" -eq 0 ]; then log_event bash allow no_input "" "" ""; fi
  return 0
}

handle_read() {
  local file=$1 offset=$2 limit=$3
  if [ -z "$file" ]; then
    log_event read allow no_input "" "" ""
    return 0
  fi
  if [ -n "$offset" ] && [ -n "$limit" ]; then
    log_event read allow targeted "$file" "" ""
    return 0
  fi
  if check_file "$file"; then
    log_event read allow "$LAST_REASON" "$file" "$LAST_BYTES" "$LAST_LINES"
    return 0
  fi
  log_event read deny "$LAST_REASON" "$file" "$LAST_BYTES" "$LAST_LINES"
  deny "$LAST_MSG"
}

main() {
  local -a F
  local agent tool file offset limit cmd
  mapfile -d '' F < <(
    printf '%s' "$input" | jq -b -j '
      (if (.tool_input | type) == "object" then .tool_input else {} end) as $t
      | [(.agent_id // ""), (.tool_name // ""), ($t.file_path // ""),
         (($t.offset // "") | tostring), (($t.limit // "") | tostring),
         ($t.command // "")] | join("\u0000")' 2>/dev/null || true
  )
  agent=${F[0]-}; tool=${F[1]-}; file=${F[2]-}; offset=${F[3]-}; limit=${F[4]-}; cmd=${F[5]-}
  if [ -n "$agent" ]; then
    case "$tool" in
      Read) log_event read allow subagent "$file" "" "" ;;
      Bash) log_event bash allow subagent "" "" "" ;;
    esac
    return 0
  fi
  while [[ $cmd == *$'\n' ]]; do cmd=${cmd%$'\n'}; done
  case "$tool" in
    Read) handle_read "$file" "$offset" "$limit" ;;
    Bash) handle_bash "$cmd" ;;
  esac
  return 0
}

main
exit 0
