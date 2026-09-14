#!/bin/sh
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
five_hour_remaining=$(echo "$input" | jq -r 'if .rate_limits.five_hour.used_percentage != null then (100 - .rate_limits.five_hour.used_percentage) else empty end')
session_duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# Compactions and rounds are derived from the transcript JSONL, not from the
# statusline input payload (which does not carry them).
compactions=""
rounds=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  compactions=$(grep -c '"subtype":"compact_boundary"' "$transcript_path" 2>/dev/null)
  # A real user turn: type=="user", message.content is a string (tool_result
  # payloads are arrays), and it's not the synthetic post-compaction summary.
  rounds=$(jq -c 'select(.type=="user" and (.message.content? | type)=="string" and ((.isCompactSummary // false)==false))' "$transcript_path" 2>/dev/null | wc -l | tr -d ' ')
fi

# ms -> "1h02m" / "12m34s"
format_duration_ms() {
  ms=$1
  total_sec=$(( ms / 1000 ))
  h=$(( total_sec / 3600 ))
  m=$(( (total_sec % 3600) / 60 ))
  s=$(( total_sec % 60 ))
  if [ "$h" -gt 0 ]; then
    printf "%dh%02dm" "$h" "$m"
  else
    printf "%dm%02ds" "$m" "$s"
  fi
}

# ANSI colors
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  filled=$(( used_int / 5 ))
  empty=$(( 20 - filled ))

  bar=""
  i=0
  while [ $i -lt $filled ]; do
    bar="${bar}█"
    i=$(( i + 1 ))
  done
  i=0
  while [ $i -lt $empty ]; do
    bar="${bar}░"
    i=$(( i + 1 ))
  done

  if [ "$used_int" -ge 50 ]; then
    color="$RED"
  else
    color="$GREEN"
  fi

  # Format token count
  if [ -n "$total_tokens" ]; then
    tokens_display=$(printf "%'d" "$total_tokens" 2>/dev/null || printf "%d" "$total_tokens")
    tokens_str=" | ${tokens_display} tokens"
  else
    tokens_str=""
  fi

  # Format 5-hour session remaining
  if [ -n "$five_hour_remaining" ]; then
    five_hour_int=$(printf "%.0f" "$five_hour_remaining")
    session_str=" | session: ${five_hour_int}% left"
  else
    session_str=""
  fi

  # Format session duration
  if [ -n "$session_duration_ms" ]; then
    duration_str=" | $(format_duration_ms "$session_duration_ms")"
  else
    duration_str=""
  fi

  # Format rounds and compactions
  if [ -n "$rounds" ]; then
    rounds_str=" | ${rounds} rounds"
  else
    rounds_str=""
  fi
  if [ -n "$compactions" ]; then
    compactions_str=" | ${compactions} compact"
  else
    compactions_str=""
  fi

  printf "%s  ${color}[%s] %s%%${RESET}%s%s%s%s%s" "$model" "$bar" "$used_int" "$tokens_str" "$session_str" "$duration_str" "$rounds_str" "$compactions_str"
else
  printf "%s  [░░░░░░░░░░░░░░░░░░░░] -" "$model"
fi