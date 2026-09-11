#!/usr/bin/env bash
# Links the live tool configs INTO this repo, so there is no sync step:
# edit a repo file, the tool reads it live. Run once per machine, or to
# repair a link (re-running is idempotent; existing correct links are kept).
#
#   ./setup.sh                    # link everything
#   ./setup.sh opencode           # opencode links only
#   ./setup.sh claude             # claude links only (also repairs them)
#   ./setup.sh all                # same as no argument
#   ./setup.sh [--check] [opencode|claude]
#
# Live files that are not already linked to the repo are backed up as
# <name>.bak.<timestamp> instead of being overwritten.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC="$HOME/.config/opencode"
OC_REPO="$REPO/opencode"
CL="${CLAUDE_CONFIG_DIR:-/mnt/c/Users/lukas/.claude}"   # live Claude Code config (NTFS)
CMD="${CMD:-/mnt/c/Windows/System32/cmd.exe}"

# Remove this run's temp links on exit (success leaves none; failures must not leak).
cleanup_tmp() { rm -f "$CL"/.tmp.*."$$" 2>/dev/null || true; }
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 130' INT TERM

die() { echo "setup.sh: $*" >&2; exit 1; }
win() { wslpath -w "$1"; }

# mklink commands are passed unquoted to cmd.exe (WSL interop mangles
# embedded quotes), so NTFS paths with spaces or cmd metacharacters fail.
nofunny() {
  if printf %s "$1" | grep -q '[[:space:]&%^(),;=]'; then
    die "NTFS path contains characters unsupported by mklink interop: $1"
  fi
}

# ---------- opencode (WSL symlinks) ----------

link_opencode() {
  mkdir -p "$OC"
  for f in AGENTS.md opencode.jsonc package.json package-lock.json; do
    [ -f "$OC_REPO/$f" ] || die "missing repo file: opencode/$f"
    if [ -e "$OC/$f" ] && [ ! -L "$OC/$f" ]; then
      local bak
      bak="$OC/$f.bak.$(date +%s)"
      if ! mv "$OC/$f" "$bak"; then die "backup failed for opencode/$f (live file untouched)"; fi
      echo "backed up: opencode/$f -> $(basename "$bak") (was a real file)"
    fi
    ln -sfn "$OC_REPO/$f" "$OC/$f"
  done
  for d in agent plugins; do
    [ -d "$OC_REPO/$d" ] || die "missing repo dir: opencode/$d"
    if [ -L "$OC/$d" ]; then
      rm "$OC/$d"                    # unlink the symlink itself only
    elif [ -e "$OC/$d" ]; then
      local bak
      bak="$OC/$d.bak.$(date +%s)"
      if ! mv "$OC/$d" "$bak"; then die "backup failed for opencode/$d (live dir untouched)"; fi
      echo "backed up: opencode/$d -> $(basename "$bak") (was a real dir)"
    fi
    ln -sfn "$OC_REPO/$d" "$OC/$d"
  done
  echo "opencode: $OC/* -> $OC_REPO (WSL symlinks)"
}

check_opencode() {
  for n in AGENTS.md opencode.jsonc package.json package-lock.json agent plugins; do
    if [ "$(readlink "$OC/$n" 2>/dev/null)" != "$OC_REPO/$n" ]; then
      echo "BROKEN: $OC/$n (missing or does not point into the repo)"; exit 1
    fi
  done
  echo "opencode: links resolve"
}

# ---------- claude (NTFS junction + hardlinks, no admin needed) ----------

preflight_claude() {
  [ -d "$CL" ] || die "live claude dir not found: $CL (tune CLAUDE_CONFIG_DIR)"
  [ -x "$CMD" ] || die "cmd.exe not found at $CMD (is WSL interop enabled?)"
  command -v wslpath >/dev/null || die "wslpath not available"
  [ -d "$REPO/claude/agents" ] || die "missing repo dir: claude/agents"
  for f in CLAUDE.md settings.json statusline-command.sh; do
    [ -f "$REPO/claude/$f" ] || die "missing repo file: claude/$f"
  done
}

# Hardlink one file. Already-linked files are left untouched; anything else
# is backed up first. The new link is created under a temp name BEFORE the
# live path is touched, so a mklink failure never destroys live state.
link_claude_file() { # $1 = live path, $2 = repo file
  local live="$1" repo="$2" out tmp bak
  if [ ! -L "$live" ] && [ "$(stat -c %i "$live" 2>/dev/null)" = "$(stat -c %i "$repo")" ]; then
    return 0                        # already the same file (stat follows symlinks, so exclude them)
  fi
  tmp="$CL/.tmp.$(basename "$live").$$"
  nofunny "$(win "$tmp")"; nofunny "$(win "$repo")"
  if ! out=$("$CMD" /c "mklink /H $(win "$tmp") $(win "$repo")" 2>&1); then
    die "mklink /H failed for $(basename "$live") (live file untouched): $out"
  fi
  if [ -e "$live" ] || [ -L "$live" ]; then
    bak="$live.bak.$(date +%s)"
    if ! mv "$live" "$bak"; then die "backup failed for $(basename "$live") (temp link removed)"; fi
    echo "backed up: .claude/$(basename "$live") -> $(basename "$bak") (was not a hardlink)"
  fi
  if ! mv "$tmp" "$live" 2>/dev/null; then
    if [ -n "$bak" ] && [ -e "$bak" ]; then
      if ! mv "$bak" "$live"; then die "restore failed for $(basename "$live"): backup at $(basename "$bak")"; fi
      die "swap failed for $(basename "$live") (backup restored)"
    fi
    die "swap failed for $(basename "$live")"
  fi
}

link_claude() {
  preflight_claude
  # agents/ : junction (appears as a symlink under drvfs)
  local agents="$CL/agents" bak tmp out
  if [ "$(readlink "$agents" 2>/dev/null)" = "$REPO/claude/agents" ]; then
    echo "claude: agents junction already correct"
  else
    tmp="$CL/.tmp.agents.$$"
    nofunny "$(win "$tmp")"; nofunny "$(win "$REPO")\\claude\\agents"
    if ! out=$("$CMD" /c "mklink /J $(win "$tmp") $(win "$REPO")\\claude\\agents" 2>&1); then
      die "mklink /J failed for agents (live dir untouched): $out"
    fi
    if [ -L "$agents" ]; then
      rm "$agents"
    elif [ -d "$agents" ]; then
      bak="$agents.bak.$(date +%s)"
      if ! mv "$agents" "$bak"; then die "backup failed for agents (temp junction removed)"; fi
      echo "backed up: .claude/agents -> $(basename "$bak") (was a real dir)"
    elif [ -e "$agents" ]; then
      rm "$tmp"
      die "unexpected file at .claude/agents (not a dir) — remove it manually"
    fi
    if ! mv "$tmp" "$agents" 2>/dev/null; then
      if [ -n "$bak" ] && [ -e "$bak" ]; then
        if ! mv "$bak" "$agents"; then die "restore failed for agents: backup at $(basename "$bak")"; fi
        echo "restored .claude/agents"
        die "swap failed for agents (backup restored)"
      fi
      die "swap failed for agents"
    fi
  fi
  for f in CLAUDE.md settings.json statusline-command.sh; do
    link_claude_file "$CL/$f" "$REPO/claude/$f"
  done
  echo "claude: $CL/{CLAUDE.md,settings.json,statusline-command.sh,agents} -> $REPO/claude (junction + hardlinks)"
}

check_claude() {
  local bad=0
  for f in CLAUDE.md settings.json statusline-command.sh; do
    if [ ! -f "$REPO/claude/$f" ]; then
      echo "BROKEN: repo file missing: claude/$f"; bad=1; continue
    fi
    if [ -L "$CL/$f" ] || [ ! -f "$CL/$f" ] || [ "$(stat -c %i "$CL/$f")" != "$(stat -c %i "$REPO/claude/$f")" ]; then
      echo "BROKEN: .claude/$f (missing, a symlink, or not hardlinked to the repo anymore)"; bad=1
    fi
  done
  if [ "$(readlink "$CL/agents" 2>/dev/null)" != "$REPO/claude/agents" ]; then
    echo "BROKEN: .claude/agents (missing or junction does not target the repo)"; bad=1
  fi
  if [ "$bad" = 0 ]; then
    echo "claude: links resolve"
  else
    exit 1
  fi
}

# ---------- dispatch ----------

TOOL="all"
ACTION="link"
for arg in "$@"; do
  case "$arg" in
    opencode | claude) TOOL="$arg" ;;
    all)               TOOL="all" ;;
    --check)           ACTION="check" ;;
    *) echo "usage: setup.sh [--check] [opencode|claude]"; exit 1 ;;
  esac
done

run() { # run <action> <tool>
  if [ "$2" = opencode ]; then
    if [ "$1" = check ]; then check_opencode; else link_opencode; fi
  else
    if [ "$1" = check ]; then check_claude; else link_claude; fi
  fi
}

for t in opencode claude; do
  if [ "$TOOL" = all ] || [ "$TOOL" = "$t" ]; then run "$ACTION" "$t"; fi
done
