#!/usr/bin/env bash
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'
export LC_NUMERIC=C

FULL=$'\xe2\x96\x88'
LIGHT=$'\xe2\x96\x91'
ESC=$'\033'
SEP=$'\x1f'

make_bar() {
  local filled="$1" empty="$2" a b
  printf -v a '%*s' "$filled" ''
  printf -v b '%*s' "$empty" ''
  printf '%s%s' "${a// /$FULL}" "${b// /$LIGHT}"
}

format_duration() {
  local total_sec="$1" h m s
  h=$((total_sec / 3600))
  m=$(((total_sec % 3600) / 60))
  s=$((total_sec % 60))
  if [ "$h" -gt 0 ]; then
    printf '%dh%02dm' "$h" "$m"
  else
    printf '%dm%02ds' "$m" "$s"
  fi
}

transcript_counts() {
  local path="$1"
  { [ -n "$path" ] && [ -f "$path" ]; } || return 0
  # shellcheck disable=SC2016
  jq -b -Rrn '
    [inputs] as $l
    | [ ($l | map(select(contains("\"subtype\":\"compact_boundary\""))) | length),
        ($l | map(fromjson? | objects
            | select(.type == "user"
                and ((.message | objects | .content) | type) == "string"
                and .isCompactSummary != true)) | length) ]
    | map(tostring) | join("\u001f")' < "$path"
}

render() {
  local input fields model used tokens remaining dur_sec path
  input="$(cat)"
  [ -n "${input//[[:space:]]/}" ] || return 1
  # shellcheck disable=SC2016
  fields="$(jq -b -r '
    [ (.model.display_name // "Unknown" | tostring),
      (.context_window.used_percentage // "" | tostring),
      (.context_window.total_input_tokens // "" | tostring),
      (if .rate_limits.five_hour.used_percentage != null then 100 - .rate_limits.five_hour.used_percentage else "" end | tostring),
      (if .cost.total_duration_ms != null then (.cost.total_duration_ms / 1000 | floor) else "" end | tostring),
      (.transcript_path // "" | tostring) ]
    | join("\u001f")' <<< "$input")"
  IFS="$SEP" read -r model used tokens remaining dur_sec path <<< "$fields"
  if [ -z "$used" ]; then
    printf '%s  [%s] -' "$model" "$(make_bar 0 20)"
    return 0
  fi
  local counts compactions="" rounds="" used_int filled color
  counts="$(transcript_counts "$path")"
  if [ -n "$counts" ]; then
    compactions="${counts%%"$SEP"*}"
    rounds="${counts#*"$SEP"}"
  fi
  printf -v used_int '%.0f' "$used"
  filled=$((used_int / 5))
  [ "$filled" -ge 0 ] || filled=0
  [ "$filled" -le 20 ] || filled=20
  color="${ESC}[0;32m"
  [ "$used_int" -lt 50 ] || color="${ESC}[0;31m"
  printf '%s  %s[%s] %s%%%s[0m' "$model" "$color" "$(make_bar "$filled" $((20 - filled)))" "$used_int" "$ESC"
  if [ -n "$tokens" ]; then printf ' | %.0f tokens' "$tokens"; fi
  if [ -n "$remaining" ]; then printf ' | session: %.0f%% left' "$remaining"; fi
  if [ -n "$dur_sec" ]; then printf ' | %s' "$(format_duration "$dur_sec")"; fi
  if [ -n "$rounds" ]; then printf ' | %s rounds' "$rounds"; fi
  if [ -n "$compactions" ]; then printf ' | %s compact' "$compactions"; fi
}

out="$(render 2>/dev/null)" || out="  [$(make_bar 0 20)] -"
printf '%s' "$out"
exit 0
