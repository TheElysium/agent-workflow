#!/usr/bin/env bash
# Deterministic review checklist generator (OpenCodeReview concept, no LLM).
#
# Emits one line per reviewable changed file, plain stdout so the output can
# be pasted verbatim into a reviewer delegation prompt:
#
#   [STATUS] +adds -dels type path
#
# Covers staged, unstaged (tracked), renamed (both sides listed), deleted,
# and untracked files. Lockfiles and minified/generated artifacts are
# excluded: they are never review targets.
#
# Usage:  scripts/review-checklist.sh
# Exit:   0 on success (an empty checklist is valid), 1 outside a git repo.

set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "review-checklist.sh: not inside a git repository" >&2
  exit 1
fi

# numstat counts for one changed path pair: sum of unstaged + staged diffs.
# This also works in a repo with no commits yet (no HEAD). Binary files ("-
# -" in numstat) report "?" rather than a line count. :(literal) pathspecs
# prevent glob characters in filenames (e.g. "f[1].txt") from matching
# unrelated siblings.
numstat_for() {
  {
    git -c core.quotepath=false diff -M --numstat -- ":(literal)$1" ":(literal)$2" 2>/dev/null || true
    git -c core.quotepath=false diff --cached -M --numstat -- ":(literal)$1" ":(literal)$2" 2>/dev/null || true
  } | awk '
    NR > 0 { if ($1 == "-" && $2 == "-") { add += 0; del += 0; bin = "?" } else { add += $1; del += $2 } }
    END {
      # no numstat lines: either a transient git failure or a stat-cache
      # mismatch — "?" is the honest count, never a fake "+0 -0"
      if (NR == 0) { print "?", "?"; exit }
      add = (add == 0 && bin == "?") ? "?" : add
      del = (del == 0 && bin == "?") ? "?" : del
      print add, del
    }'
}

line_count() { # line count for untracked files, "?" when unreadable
  if [ -r "$1" ]; then wc -l < "$1" | tr -d ' '; else echo "?"; fi
}

is_excluded() { # lockfiles and minified bundles are not review targets
  case "$(basename "$1")" in
    package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lockb|go.sum|Cargo.lock|\
poetry.lock|Pipfile.lock|composer.lock) return 0;;
    *.min.js|*.min.css) return 0;;
  esac
  return 1
}

filetype() {
  case "${1##*.}" in
    sh|bash)          echo shell;;
    ts)               echo typescript;;
    js|mjs|cjs)       echo javascript;;
    go)               echo go;;
    py)               echo python;;
    rb)               echo ruby;;
    rs)               echo rust;;
    java)             echo java;;
    c|h)              echo c;;
    cpp|hpp|cc)       echo cpp;;
    cs)               echo csharp;;
    sql)              echo sql;;
    yml|yaml)         echo yaml;;
    toml)             echo toml;;
    json)             echo json;;
    md|mdx)           echo markdown;;
    html|htm)         echo html;;
    css|scss)         echo css;;
    *)                echo other;;
  esac
}

emit() { # emit <status> <adds> <dels> <path>
  if is_excluded "$4"; then return 0; fi
  printf '[%s] %s %s %s %s\n' "$1" "$2" "$3" "$(filetype "$4")" "$4"
}

# Porcelain is consumed NUL-separated (-z): quoted or escaped paths are never
# mangled, and -uall expands untracked directories to their files. Each
# record is "XY <path>\0"; renamed entries append the source path as a
# second NUL record.
while IFS= read -r -d '' rec; do
  xy="${rec:0:2}"
  path="${rec:3}"
  if [[ "$xy" == R* || "$xy" == C* ]]; then
    IFS= read -r -d '' src || continue
    counts="$(numstat_for "$src" "$path")"
    add="${counts% *}"
    del="${counts#* }"
    emit "$xy" "+$add" "-$del" "$src"
    emit "$xy" "+$add" "-$del" "$path"
  elif [[ "$xy" == "??"* ]]; then
    emit "$xy" "+$(line_count "$path")" "-0" "$path"
  else
    counts="$(numstat_for "$path" "$path")"
    add="${counts% *}"
    del="${counts#* }"
    emit "$xy" "+$add" "-$del" "$path"
  fi
done < <(git -c core.quotepath=false status --porcelain -z -uall)
