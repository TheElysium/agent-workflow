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

# Pre-commit gate lives in githooks/ (see check_hooks/install_hooks).
install_hooks() {
  if [ -d "$REPO/.git" ]; then
    git -C "$REPO" config core.hooksPath githooks
  fi
}

check_hooks() {
  if [ ! -d "$REPO/.git" ]; then
    echo "hooks: no .git dir — pre-commit gate not applicable"
    return
  fi
  if [ "$(git -C "$REPO" config core.hooksPath 2>/dev/null || true)" = githooks ]; then
    echo "hooks: core.hooksPath = githooks"
  else
    echo "BROKEN: core.hooksPath not set to githooks — pre-commit gate inactive"; exit 1
  fi
}
OC="$HOME/.config/opencode"
OC_REPO="$REPO/opencode"
CMD="${CMD:-/mnt/c/Windows/System32/cmd.exe}"

# Live Claude Code config: auto-detect the Windows user via cmd.exe, or set
# CLAUDE_CONFIG_DIR to take control (empty when detection fails; the claude
# preflight/check will ask for CLAUDE_CONFIG_DIR).
CL="${CLAUDE_CONFIG_DIR:-}"
if [ -z "$CL" ]; then
  winuser=$("$CMD" /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n')
  [ -n "$winuser" ] && CL="/mnt/c/Users/$winuser/.claude"
fi

# Remove this run's temp links on exit (success leaves none; failures must not leak).
cleanup_tmp() { if [ -n "$CL" ]; then rm -f "$CL"/.tmp.*."$$" 2>/dev/null || true; fi; }
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
  [ -n "$CL" ] || die "cannot detect the Windows user dir (interop off?) — set CLAUDE_CONFIG_DIR"
  [ -d "$CL" ] || die "live claude dir not found: $CL (tune CLAUDE_CONFIG_DIR)"
  [ -x "$CMD" ] || die "cmd.exe not found at $CMD (is WSL interop enabled?)"
  command -v wslpath >/dev/null || die "wslpath not available"
  [ -d "$REPO/claude/agents" ] || die "missing repo dir: claude/agents"
  for f in CLAUDE.md AGENTS.md settings.json statusline-command.sh hooks/shunt.sh; do
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
  mkdir -p "$CL/hooks"               # live home for the shunt hook
  for f in CLAUDE.md AGENTS.md settings.json statusline-command.sh; do
    link_claude_file "$CL/$f" "$REPO/claude/$f"
  done
  link_claude_file "$CL/hooks/shunt.sh" "$REPO/claude/hooks/shunt.sh"
  echo "claude: $CL/{CLAUDE.md,AGENTS.md,settings.json,statusline-command.sh,agents,hooks/shunt.sh} -> $REPO/claude (junction + hardlinks)"
}

check_claude() {
  local bad=0
  [ -n "$CL" ] || { echo "BROKEN: cannot detect the Windows user dir — set CLAUDE_CONFIG_DIR"; exit 1; }
  for f in CLAUDE.md AGENTS.md settings.json statusline-command.sh hooks/shunt.sh; do
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
  if [ "$1" = check ]; then
    if [ "$2" = opencode ]; then check_opencode; else check_claude; fi
  else
    if [ "$2" = opencode ]; then link_opencode; else link_claude; fi
  fi
}

if [ "$ACTION" = check ]; then check_hooks; else install_hooks; fi

for t in opencode claude; do
  if [ "$TOOL" = all ] || [ "$TOOL" = "$t" ]; then run "$ACTION" "$t"; fi
done
