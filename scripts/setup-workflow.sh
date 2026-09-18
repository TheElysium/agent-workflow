#!/usr/bin/env bash
# Installer for the agent-workflow kit: deploys AGENTS.md/CLAUDE.md, the
# .claude/ and .opencode/ harnesses, scripts/ and a .gates.yml skeleton into
# a target project (or Claude Code shims into a global config dir), verifies
# an existing install, or uninstalls one via its manifest.
#
# Usage:
#   bash scripts/setup-workflow.sh --mode project --target <dir> [options]
#   bash scripts/setup-workflow.sh --mode global [options]
#   bash scripts/setup-workflow.sh --verify (--target <dir> | --mode global)
#   bash scripts/setup-workflow.sh --uninstall (--target <dir> | --mode global)
#
# Options:
#   --harness claude|opencode|both  default: claude
#   --stack shell|node|bun|python|rust|other   default: other
#   --global-dir <dir>              default: $HOME/.claude
#   --force                         overwrite drifted files (writes a .bak.<epoch> first)
#   --dry-run                       print planned actions, change nothing
#   -h, --help                      usage
#
# Output: one line per action -- "CREATE|UPDATE|SKIP|BACKUP|REMOVE <path> [(reason)]",
# "DRY " prefixed under --dry-run, final "created=N updated=N skipped=N removed=N".
# --verify prints "OK <check>" / "RED <check>" plus "verify: N ok, N red".
#
# Exit codes: 0 success, 1 usage/precondition error, 2 --verify found a red check.

set -euo pipefail

# --- small helpers ----------------------------------------------------------

die() { # die <message>
  echo "error: $*" >&2
  exit 1
}

sha256_of() { # sha256_of <path> -- prints "" for a missing/unreadable file
  if [ -f "$1" ]; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || true
  fi
}

CREATED=0
UPDATED=0
SKIPPED=0
REMOVED=0

emit() { # emit <VERB> <relpath> [reason]
  local verb="$1" rel="$2" reason="${3:-}" line
  line="$verb $rel"
  [ -n "$reason" ] && line="$line ($reason)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY $line"
  else
    echo "$line"
  fi
  case "$verb" in
    CREATE) CREATED=$((CREATED + 1)) ;;
    UPDATE) UPDATED=$((UPDATED + 1)) ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    REMOVE) REMOVED=$((REMOVED + 1)) ;;
  esac
}

print_summary() {
  echo "created=$CREATED updated=$UPDATED skipped=$SKIPPED removed=$REMOVED"
}

print_help() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- manifest (drift tracking) ----------------------------------------------

declare -A MANIFEST_SHA256=()
# "create" means the installer made the file and may delete it again; "merge"
# means it only folded its own keys into a file the user already owned.
declare -A MANIFEST_KIND=()
NEW_FILES=()

load_manifest() { # load_manifest <manifest-json-path>
  MANIFEST_SHA256=()
  MANIFEST_KIND=()
  [ -f "$1" ] || return 0
  local path sha kind
  while IFS=$'\t' read -r path sha kind; do
    [ -n "$path" ] || continue
    MANIFEST_SHA256["$path"]="$sha"
    MANIFEST_KIND["$path"]="$kind"
  done < <(jq -r '.files[]? | [.path, .sha256, (.kind // "create")] | @tsv' "$1" 2>/dev/null)
}

record_new_file() { # record_new_file <relpath> <sha256> [create|merge]
  [ "$DRY_RUN" = "1" ] && return 0
  NEW_FILES+=("$1"$'\t'"$2"$'\t'"${3:-create}")
}

write_manifest() { # write_manifest <manifest-relpath-under-ROOT> <mode> <harness> <stack>
  [ "$DRY_RUN" = "1" ] && return 0
  local rel="$1" mode="$2" harness="$3" stack="$4" dst kit_commit files_json
  dst="$ROOT/$rel"
  kit_commit="$(git -C "$KIT" rev-parse HEAD 2>/dev/null)" || kit_commit="unknown"
  files_json="[]"
  if [ "${#NEW_FILES[@]}" -gt 0 ]; then
    files_json="$(printf '%s\n' "${NEW_FILES[@]}" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t")
                      | {path: .[0], sha256: .[1], kind: (.[2] // "create")})
      | group_by(.path) | map(last)')"
  fi
  mkdir -p "$(dirname "$dst")"
  jq -n \
    --arg kit_commit "$kit_commit" \
    --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg mode "$mode" \
    --arg harness "$harness" \
    --arg stack "$stack" \
    --argjson files "$files_json" \
    '{kit_commit: $kit_commit, installed_at: $installed_at, mode: $mode, harness: $harness, stack: $stack, files: $files}' \
    > "$dst.tmp"
  mv "$dst.tmp" "$dst"
}

# --- generic drift-aware file install ---------------------------------------

do_create() { # do_create <src> <dst> <rel>
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$(dirname "$2")"
    cp "$1" "$2"
  fi
  emit CREATE "$3"
  record_new_file "$3" "$(sha256_of "$1")"
}

do_overwrite_silent() { # do_overwrite_silent <src> <dst> <rel>
  if [ "$DRY_RUN" != "1" ]; then
    cp "$1" "$2"
  fi
  emit UPDATE "$3"
  record_new_file "$3" "$(sha256_of "$1")"
}

do_backup_and_overwrite() { # do_backup_and_overwrite <src> <dst> <rel>
  if [ "$DRY_RUN" != "1" ]; then
    cp "$2" "$2.bak.$(date +%s)"
  fi
  emit BACKUP "$3"
  if [ "$DRY_RUN" != "1" ]; then
    cp "$1" "$2"
  fi
  emit UPDATE "$3"
  record_new_file "$3" "$(sha256_of "$1")"
}

install_file() { # install_file <src-abs-path> <rel-dst-path-under-ROOT>
  local src="$1" rel="$2" dst cur_sha manifest_sha
  dst="$ROOT/$rel"
  if [ ! -e "$dst" ]; then
    do_create "$src" "$dst" "$rel"
    return 0
  fi
  cur_sha="$(sha256_of "$dst")"
  manifest_sha="${MANIFEST_SHA256[$rel]:-}"
  if [ -z "$manifest_sha" ]; then
    if [ "$FORCE" = "1" ]; then
      do_backup_and_overwrite "$src" "$dst" "$rel"
    else
      emit SKIP "$rel" "exists, not kit-owned"
    fi
    return 0
  fi
  if [ "$manifest_sha" = "$cur_sha" ]; then
    do_overwrite_silent "$src" "$dst" "$rel"
  elif [ "$FORCE" = "1" ]; then
    do_backup_and_overwrite "$src" "$dst" "$rel"
  else
    emit SKIP "$rel" "local changes"
    record_new_file "$rel" "$manifest_sha"
  fi
}

install_generated() { # install_generated <rel-dst-path> -- content read from stdin
  local rel="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  install_file "$tmp" "$rel"
  rm -f "$tmp"
}

# --- import-line merge (AGENTS.md / CLAUDE.md / global AGENTS.md) -----------

ensure_import_line() { # ensure_import_line <rel-path-under-ROOT> <exact-line>
  local rel="$1" line="$2" path="$ROOT/$1"
  if [ ! -f "$path" ]; then
    if [ "$DRY_RUN" != "1" ]; then
      mkdir -p "$(dirname "$path")"
      printf '%s\n' "$line" > "$path"
    fi
    emit CREATE "$rel"
    return 0
  fi
  if grep -qxF -- "$line" "$path"; then
    emit SKIP "$rel" "import line present"
    return 0
  fi
  if [ "$DRY_RUN" != "1" ]; then
    printf '\n%s\n' "$line" >> "$path"
  fi
  emit UPDATE "$rel"
}

# --- .gitignore merge (append-only, never tracked in the manifest) ---------

ensure_gitignore_lines() { # ensure_gitignore_lines <rel-path-under-ROOT> <line...>
  local rel="$1"
  shift
  local path="$ROOT/$rel" existed=0 line pending=()
  [ -f "$path" ] && existed=1
  for line in "$@"; do
    if [ "$existed" = "1" ] && grep -qxF -- "$line" "$path"; then
      continue
    fi
    pending+=("$line")
  done
  if [ "${#pending[@]}" -eq 0 ]; then
    emit SKIP "$rel" "up to date"
    return 0
  fi
  if [ "$DRY_RUN" != "1" ]; then
    # A last line with no trailing newline would swallow the first appended one.
    if [ -s "$path" ] && [ -n "$(tail -c 1 "$path")" ]; then
      printf '\n' >> "$path"
    fi
    printf '%s\n' "${pending[@]}" >> "$path"
  fi
  if [ "$existed" = "1" ]; then emit UPDATE "$rel"; else emit CREATE "$rel"; fi
}

# --- settings.json (key-wise jq merge, never drift-skipped) -----------------

# shellcheck disable=SC2016  # jq program: single-quoted on purpose, no shell expansion
SETTINGS_MERGE_JQ='
def add_pretooluse:
  (.hooks.PreToolUse // []) as $arr
  | if any($arr[]; (.hooks[]?.command // "") == $shuntcmd) then $arr
    else $arr + [{matcher: $matcher, hooks: [{type: "command", command: $shuntcmd, timeout: $timeout}]}]
    end;
def add_sessionend:
  (.hooks.SessionEnd // []) as $arr
  | if any($arr[]; (.hooks[]?.command // "") == $sessioncmd) then $arr
    else $arr + [{hooks: [{type: "command", command: $sessioncmd, timeout: $timeout}]}]
    end;
.hooks = (.hooks // {})
| .hooks.PreToolUse = add_pretooluse
| .hooks.SessionEnd = add_sessionend
| .statusLine = (if has("statusLine") then .statusLine else {type: "command", command: $statuslinecmd} end)
'

# Hook commands are stored as strings and resolve against the harness cwd, not
# against the file that holds them: a project install needs a project-relative
# path, a global one an absolute path. The default global dir keeps the tilde
# form Claude Code writes itself, so a re-run over a hand-made install matches
# the existing entry instead of appending a duplicate.
settings_cmd_base() {
  local home_claude
  if [ "$SCOPE" = "project" ]; then
    printf '.claude'
    return 0
  fi
  home_claude=""
  if [ -d "$HOME/.claude" ]; then
    home_claude="$(cd "$HOME/.claude" && pwd -P)"
  fi
  if [ -n "$home_claude" ] && [ "$ROOT" = "$home_claude" ]; then
    # Literal tilde on purpose: Claude Code expands it when it runs the hook.
    # shellcheck disable=SC2088
    printf '~/.claude'
  else
    printf '%s' "$ROOT"
  fi
}

render_settings_json() { # render_settings_json <existing-settings-path>
  local base
  base="$(settings_cmd_base)"
  jq \
    --arg matcher 'Read|Bash' \
    --arg shuntcmd "bash $base/hooks/shunt.sh" \
    --arg sessioncmd "bash $base/hooks/session-end.sh" \
    --arg statuslinecmd "bash $base/statusline-command.sh" \
    --argjson timeout 10 \
    "$SETTINGS_MERGE_JQ" "$1"
}

install_settings_json() { # install_settings_json <rel-dst-path> <kit-settings-src>
  local rel="$1" kitsrc="$2" dst tmp new cur kind
  dst="$ROOT/$rel"
  tmp="$(mktemp)"
  # Sticky: a file the kit created stays "create" across re-runs, even though
  # the destination now exists.
  if [ -n "${MANIFEST_KIND[$rel]:-}" ]; then
    kind="${MANIFEST_KIND[$rel]}"
  elif [ -f "$dst" ]; then
    kind="merge"
  else
    kind="create"
  fi
  if [ -f "$dst" ]; then
    render_settings_json "$dst" > "$tmp"
  else
    # The kit ships a project-shaped settings.json; a global install must not
    # inherit its relative paths, so it starts from an empty object instead.
    if [ "$SCOPE" = "project" ]; then
      cp "$kitsrc" "$tmp.seed"
    else
      printf '{}\n' > "$tmp.seed"
    fi
    render_settings_json "$tmp.seed" > "$tmp"
    rm -f "$tmp.seed"
  fi
  new="$(sha256_of "$tmp")"
  if [ ! -f "$dst" ]; then
    if [ "$DRY_RUN" != "1" ]; then
      mkdir -p "$(dirname "$dst")"
      cp "$tmp" "$dst"
    fi
    emit CREATE "$rel"
  else
    cur="$(sha256_of "$dst")"
    if [ "$cur" = "$new" ]; then
      emit SKIP "$rel" "already up to date"
    else
      if [ "$DRY_RUN" != "1" ]; then
        cp "$tmp" "$dst"
      fi
      emit UPDATE "$rel"
    fi
  fi
  record_new_file "$rel" "$new" "$kind"
  rm -f "$tmp"
}

# shellcheck disable=SC2016  # jq program: single-quoted on purpose, no shell expansion
SETTINGS_UNMERGE_JQ='
  (if (.hooks.PreToolUse | type) == "array"
   then .hooks.PreToolUse |= map(select([.hooks[]?.command] | index($shuntcmd) | not))
   else . end)
| (if (.hooks.SessionEnd | type) == "array"
   then .hooks.SessionEnd |= map(select([.hooks[]?.command] | index($sessioncmd) | not))
   else . end)
| (if (.hooks.PreToolUse // [] | length) == 0 then del(.hooks.PreToolUse) else . end)
| (if (.hooks.SessionEnd // [] | length) == 0 then del(.hooks.SessionEnd) else . end)
| (if (.hooks // {} | length) == 0 then del(.hooks) else . end)
| (if (.statusLine.command? // "") == $statuslinecmd then del(.statusLine) else . end)
'

# A settings.json the kit merged into belongs to the user, not to the kit: strip
# the entries the kit added and put the rest back. Only a file left empty by
# that surgery is deleted.
unmerge_settings_json() { # unmerge_settings_json <rel>
  local rel="$1" dst tmp base
  dst="$ROOT/$rel"
  if [ ! -f "$dst" ]; then
    emit SKIP "$rel" "already gone"
    return 0
  fi
  base="$(settings_cmd_base)"
  tmp="$(mktemp)"
  if ! jq \
    --arg shuntcmd "bash $base/hooks/shunt.sh" \
    --arg sessioncmd "bash $base/hooks/session-end.sh" \
    --arg statuslinecmd "bash $base/statusline-command.sh" \
    "$SETTINGS_UNMERGE_JQ" "$dst" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    emit SKIP "$rel" "not valid json"
    return 0
  fi
  if [ "$(jq -r 'length' "$tmp")" = "0" ]; then
    [ "$DRY_RUN" != "1" ] && rm -f "$dst"
    emit REMOVE "$rel"
  else
    [ "$DRY_RUN" != "1" ] && cp "$tmp" "$dst"
    emit UPDATE "$rel"
  fi
  rm -f "$tmp"
}

# --- .gates.yml skeleton -----------------------------------------------------

HARD_RED='echo "gate not configured" >&2 && exit 1'

gate_cmds_for_stack() { # gate_cmds_for_stack <stack> -- sets GLINT GTYPECHECK GTEST GBUILD
  local stack="$1"
  GLINT="$HARD_RED"; GTYPECHECK="$HARD_RED"; GTEST="$HARD_RED"; GBUILD="$HARD_RED"
  case "$stack" in
    shell)
      GLINT="shellcheck \$(git ls-files '*.sh')"
      ;;
    node)
      GLINT="npm run lint"; GTYPECHECK="npm run typecheck"; GTEST="npm test"; GBUILD="npm run build"
      ;;
    bun)
      GLINT="bun run lint"; GTYPECHECK="bun run typecheck"; GTEST="bun test"; GBUILD="bun run build"
      ;;
    python)
      GLINT="ruff check ."; GTYPECHECK="mypy ."; GTEST="pytest"
      ;;
    rust)
      GLINT="cargo clippy -- -D warnings"; GTYPECHECK="cargo check"; GTEST="cargo test"; GBUILD="cargo build --release"
      ;;
    *) ;;
  esac
}

render_gates_yml() { # render_gates_yml <stack>
  gate_cmds_for_stack "$1"
  cat <<EOF
# Gate contract:
#   - Each non-ignored line is \`key: single-line command\`.
#   - Multi-line YAML values are NOT supported by the CI runner.
#   - \`stack\` is metadata and is not executed.
#   - Missing tool = FAIL, never a skip.
stack: $1
lint: $GLINT
typecheck: $GTYPECHECK
test: $GTEST
build: $GBUILD
sast: gitleaks detect --no-banner --redact
EOF
}

install_gates_yml() { # install_gates_yml <stack>
  local path="$ROOT/.gates.yml"
  if [ -f "$path" ]; then
    emit SKIP ".gates.yml" "exists"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  render_gates_yml "$1" > "$tmp"
  if [ "$DRY_RUN" != "1" ]; then
    cp "$tmp" "$path"
  fi
  emit CREATE ".gates.yml"
  record_new_file ".gates.yml" "$(sha256_of "$tmp")"
  rm -f "$tmp"
}

# --- opencode-generated files ------------------------------------------------

render_opencode_package_json() {
  jq -n '{"dependencies": {"@opencode-ai/plugin": "1.18.30"}}'
}

render_opencode_gitignore() {
  printf '%s\n' node_modules package.json package-lock.json bun.lock .gitignore
}

# --- global-mode shim rendering ----------------------------------------------

render_exec_shim() { # render_exec_shim <abs-target-script>
  printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$1"
}

render_session_end_shim() { # render_session_end_shim <kit-root>
  printf '#!/usr/bin/env bash\nexport USAGE_IMPORT_CMD="%s/scripts/usage-import-claude.sh"\nexec bash "%s/.claude/hooks/session-end.sh" "$@"\n' "$1" "$1"
}

extract_frontmatter() { # extract_frontmatter <skill-md-path>
  awk '
    NR == 1 && $0 == "---" { print; infm = 1; next }
    infm && $0 == "---" { print; exit }
    infm { print }
  ' "$1"
}

render_skill_shim() { # render_skill_shim <skill-name> <source-skill-md-path> <kit-root>
  local name="$1" src="$2" kit="$3" fm
  fm="$(extract_frontmatter "$src")"
  printf '%s\n\nShim -- source of truth is the agent-workflow repo. Do not edit this copy;\nedit .claude/skills/%s/SKILL.md in the repo instead.\n\nRead and follow exactly:\n%s/.claude/skills/%s/SKILL.md\n' "$fm" "$name" "$kit" "$name"
}

# --- harness installers (project mode) --------------------------------------

install_claude_harness_project() { # install_claude_harness_project <kit-root>
  local kit="$1" f
  for f in "$kit"/.claude/agents/*.md; do
    install_file "$f" ".claude/agents/$(basename "$f")"
  done
  install_file "$kit/.claude/skills/dev-workflow/SKILL.md" ".claude/skills/dev-workflow/SKILL.md"
  install_file "$kit/.claude/skills/setup-workflow/SKILL.md" ".claude/skills/setup-workflow/SKILL.md"
  install_file "$kit/.claude/hooks/shunt.sh" ".claude/hooks/shunt.sh"
  install_file "$kit/.claude/hooks/session-end.sh" ".claude/hooks/session-end.sh"
  install_file "$kit/.claude/statusline-command.sh" ".claude/statusline-command.sh"
  install_settings_json ".claude/settings.json" "$kit/.claude/settings.json"
}

install_opencode_harness_project() { # install_opencode_harness_project <kit-root>
  local kit="$1" f
  for f in "$kit"/.opencode/agent/*.md; do
    install_file "$f" ".opencode/agent/$(basename "$f")"
  done
  install_file "$kit/.opencode/plugins/shunt.ts" ".opencode/plugins/shunt.ts"
  install_file "$kit/.opencode/plugins/usage-log.ts" ".opencode/plugins/usage-log.ts"
  render_opencode_package_json | install_generated ".opencode/package.json"
  render_opencode_gitignore | install_generated ".opencode/.gitignore"
  echo "hint: run 'bun install' in .opencode/ to fetch @opencode-ai/plugin" >&2
}

KIT_SCRIPTS=(run-gates.sh review-checklist.sh usage-report.sh usage-import-claude.sh session-tools.sh shunt-report.sh)

install_scripts_project() { # install_scripts_project <kit-root>
  local kit="$1" name
  for name in "${KIT_SCRIPTS[@]}"; do
    install_file "$kit/scripts/$name" "scripts/$name"
  done
}

# --- preconditions (project mode) -------------------------------------------

resolve_target_dir() { # resolve_target_dir <raw-path> -- prints the physical path
  local raw="$1"
  [ -n "$raw" ] || die "--target requires a directory"
  [ -d "$raw" ] || die "--target must be an existing directory: $raw"
  (cd "$raw" && pwd -P)
}

check_git_worktree() { # check_git_worktree <resolved-target>
  git -C "$1" rev-parse --show-toplevel > /dev/null 2>&1 || die "--target is not inside a git work tree: $1"
}

check_not_root_or_home() { # check_not_root_or_home <resolved-target>
  local home_phys
  home_phys="$(cd "$HOME" 2> /dev/null && pwd -P)" || home_phys="$HOME"
  [ "$1" != "/" ] || die "refusing to install into /"
  [ "$1" != "$home_phys" ] || die "refusing to install into \$HOME"
}

check_not_self_install() { # check_not_self_install <resolved-target> <resolved-kit>
  [ "$1" != "$2" ] || die "refusing to install the kit into itself"
}

# --- project / global install flows -----------------------------------------

do_install_project() {
  [ -n "$TARGET" ] || die "--mode project requires --target <dir>"
  ROOT="$(resolve_target_dir "$TARGET")"
  check_git_worktree "$ROOT"
  check_not_root_or_home "$ROOT"
  check_not_self_install "$ROOT" "$KIT"

  load_manifest "$ROOT/.claude/agent-workflow.install.json"
  NEW_FILES=()

  install_file "$KIT/AGENTS.md" ".claude/agent-workflow/AGENTS.md"
  ensure_import_line "AGENTS.md" "@.claude/agent-workflow/AGENTS.md"
  ensure_import_line "CLAUDE.md" "@AGENTS.md"

  case "$HARNESS" in claude | both) install_claude_harness_project "$KIT" ;; esac
  case "$HARNESS" in opencode | both) install_opencode_harness_project "$KIT" ;; esac

  install_scripts_project "$KIT"
  install_gates_yml "$STACK"
  ensure_gitignore_lines ".gitignore" \
    ".claude/settings.local.json" ".opencode/settings.local.json" ".usage/" ".opencode/node_modules/"

  write_manifest ".claude/agent-workflow.install.json" "project" "$HARNESS" "$STACK"
  print_summary
}

do_install_global() {
  case "$HARNESS" in
    opencode | both)
      die "--mode global supports --harness claude only; opencode global install is unimplemented (use ~/.config/opencode/ by hand)"
      ;;
  esac
  [ "$DRY_RUN" = "1" ] || mkdir -p "$GLOBAL_DIR"
  ROOT="$(cd "$GLOBAL_DIR" 2> /dev/null && pwd -P)" || ROOT="$GLOBAL_DIR"

  load_manifest "$ROOT/agent-workflow.install.json"
  NEW_FILES=()

  ensure_import_line "AGENTS.md" "@$KIT/AGENTS.md"
  render_exec_shim "$KIT/.claude/hooks/shunt.sh" | install_generated "hooks/shunt.sh"
  render_session_end_shim "$KIT" | install_generated "hooks/session-end.sh"
  render_exec_shim "$KIT/.claude/statusline-command.sh" | install_generated "statusline-command.sh"
  render_skill_shim "dev-workflow" "$KIT/.claude/skills/dev-workflow/SKILL.md" "$KIT" \
    | install_generated "skills/dev-workflow/SKILL.md"
  render_skill_shim "setup-workflow" "$KIT/.claude/skills/setup-workflow/SKILL.md" "$KIT" \
    | install_generated "skills/setup-workflow/SKILL.md"

  local f
  for f in "$KIT"/.claude/agents/*.md; do
    install_file "$f" "agents/$(basename "$f")"
  done

  install_settings_json "settings.json" "$KIT/.claude/settings.json"

  write_manifest "agent-workflow.install.json" "global" "claude" "-"
  print_summary
}

do_install() {
  case "$MODE" in
    project) SCOPE="project"; do_install_project ;;
    global) SCOPE="global"; do_install_global ;;
    "") die "install requires --mode project or --mode global" ;;
    *) die "invalid --mode: $MODE" ;;
  esac
}

# --- scope resolution for --verify / --uninstall ----------------------------

resolve_scope_for_check() { # sets ROOT and MANIFEST_PATH
  if [ "$MODE" = "global" ]; then
    ROOT="$GLOBAL_DIR"
    [ -d "$ROOT" ] || die "--mode global: global dir does not exist: $ROOT"
    ROOT="$(cd "$ROOT" && pwd -P)"
    MANIFEST_PATH="$ROOT/agent-workflow.install.json"
    SCOPE="global"
    return 0
  fi
  [ -n "$TARGET" ] || die "need --target <dir> or --mode global"
  ROOT="$(resolve_target_dir "$TARGET")"
  MANIFEST_PATH="$ROOT/.claude/agent-workflow.install.json"
  SCOPE="project"
}

# --- --verify -----------------------------------------------------------------

OK=0
RED=0

vok() { echo "OK $1"; OK=$((OK + 1)); }
vred() { echo "RED $1${2:+ ($2)}"; RED=$((RED + 1)); }

verify_manifest_files() { # verify_manifest_files <manifest-path>
  if [ ! -f "$1" ]; then
    vred "manifest exists" "no manifest at $1"
    return 0
  fi
  vok "manifest exists"
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -s "$ROOT/$path" ]; then
      vok "manifest file present: $path"
    else
      vred "manifest file present: $path" "missing or empty"
    fi
  done < <(jq -r '.files[]?.path' "$1" 2> /dev/null)
}

verify_referenced_scripts() {
  local name
  for name in "${KIT_SCRIPTS[@]}"; do
    if [ -s "$ROOT/scripts/$name" ]; then
      vok "referenced script: scripts/$name"
    else
      vred "referenced script: scripts/$name" "missing"
    fi
  done
}

verify_settings_json() {
  local path
  if [ "$SCOPE" = "project" ]; then path="$ROOT/.claude/settings.json"; else path="$ROOT/settings.json"; fi
  if [ -f "$path" ] && jq empty "$path" > /dev/null 2>&1; then
    vok "settings.json parses"
  else
    vred "settings.json parses" "missing or invalid JSON at $path"
  fi
}

verify_gates_yml() {
  if grep -q '^sast:' "$ROOT/.gates.yml" 2> /dev/null; then
    vok ".gates.yml has sast:"
  else
    vred ".gates.yml has sast:" "missing sast: line"
  fi
}

sample_pretooluse_payload() {
  jq -nc '{session_id: "verify", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "echo hi"}}'
}

verify_shunt_hook() {
  local hook
  if [ "$SCOPE" = "project" ]; then hook="$ROOT/.claude/hooks/shunt.sh"; else hook="$ROOT/hooks/shunt.sh"; fi
  if [ ! -f "$hook" ]; then
    vred "shunt hook exits 0" "missing $hook"
    return 0
  fi
  if sample_pretooluse_payload | bash "$hook" > /dev/null 2>&1; then
    vok "shunt hook exits 0"
  else
    vred "shunt hook exits 0" "nonzero exit"
  fi
}

do_verify() {
  resolve_scope_for_check
  verify_manifest_files "$MANIFEST_PATH"
  [ "$SCOPE" = "project" ] && verify_referenced_scripts
  verify_settings_json
  [ "$SCOPE" = "project" ] && verify_gates_yml
  verify_shunt_hook
  echo "verify: $OK ok, $RED red"
  [ "$RED" -eq 0 ] || exit 2
}

# --- --uninstall ----------------------------------------------------------

prune_empty_dirs() {
  [ "$DRY_RUN" = "1" ] && return 0
  find "$1" -mindepth 1 -type d -empty \
    -not -path "$1/.git" -not -path "$1/.git/*" \
    -delete 2> /dev/null || true
}

do_uninstall() {
  resolve_scope_for_check
  [ -f "$MANIFEST_PATH" ] || die "no manifest found at $MANIFEST_PATH"
  local path sha kind cur
  while IFS=$'\t' read -r path sha kind; do
    [ -n "$path" ] || continue
    if [ "$kind" = "merge" ]; then
      unmerge_settings_json "$path"
      continue
    fi
    cur=""
    [ -f "$ROOT/$path" ] && cur="$(sha256_of "$ROOT/$path")"
    if [ -f "$ROOT/$path" ] && [ "$cur" = "$sha" ]; then
      [ "$DRY_RUN" != "1" ] && rm -f "$ROOT/$path"
      emit REMOVE "$path"
    else
      emit SKIP "$path" "local changes"
    fi
  done < <(jq -r '.files[]? | [.path, .sha256, (.kind // "create")] | @tsv' "$MANIFEST_PATH")

  prune_empty_dirs "$ROOT"

  local manifest_rel="${MANIFEST_PATH#"$ROOT"/}"
  [ "$DRY_RUN" != "1" ] && rm -f "$MANIFEST_PATH"
  emit REMOVE "$manifest_rel"

  echo "note: AGENTS.md, CLAUDE.md and .gitignore import lines were not removed; remove them by hand."
  print_summary
}

# --- argument parsing ---------------------------------------------------------

MODE=""
SCOPE=""
TARGET=""
ACTION="install"
HARNESS="claude"
STACK="other"
GLOBAL_DIR="$HOME/.claude"
FORCE=0
DRY_RUN=0

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)
        [ $# -ge 2 ] || die "--mode requires a value"
        MODE="$2"; shift 2 ;;
      --target)
        [ $# -ge 2 ] || die "--target requires a value"
        TARGET="$2"; shift 2 ;;
      --verify) ACTION="verify"; shift ;;
      --uninstall) ACTION="uninstall"; shift ;;
      --harness)
        [ $# -ge 2 ] || die "--harness requires a value"
        HARNESS="$2"; shift 2 ;;
      --stack)
        [ $# -ge 2 ] || die "--stack requires a value"
        STACK="$2"; shift 2 ;;
      --global-dir)
        [ $# -ge 2 ] || die "--global-dir requires a value"
        GLOBAL_DIR="$2"; shift 2 ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h | --help) print_help; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$HARNESS" in claude | opencode | both) ;; *) die "invalid --harness: $HARNESS" ;; esac
  case "$STACK" in shell | node | bun | python | rust | other) ;; *) die "invalid --stack: $STACK" ;; esac
  case "$MODE" in "" | project | global) ;; *) die "invalid --mode: $MODE" ;; esac
  [ -n "$GLOBAL_DIR" ] || die "--global-dir requires a non-empty path"
}

main() {
  parse_args "$@"
  KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  case "$ACTION" in
    install) do_install ;;
    verify) do_verify ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"
