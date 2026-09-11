#!/bin/sh
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
five_hour_remaining=$(echo "$input" | jq -r 'if .rate_limits.five_hour.used_percentage != null then (100 - .rate_limits.five_hour.used_percentage) else empty end')

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

  printf "%s  ${color}[%s] %s%%${RESET}%s%s" "$model" "$bar" "$used_int" "$tokens_str" "$session_str"
else
  printf "%s  [░░░░░░░░░░░░░░░░░░░░] -" "$model"
fi