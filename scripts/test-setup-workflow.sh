#!/usr/bin/env bash
# Smoke tests for scripts/setup-workflow.sh.
#
# Contract summary (see scripts/setup-workflow.sh header for the full CLI):
#   --mode project --target <dir>   install the kit into <dir>
#   --mode global                   install Claude Code shims into a global dir
#   --verify                        check an install (--target <dir> or --mode global)
#   --uninstall                     remove unmodified kit-owned files per the manifest
#   --harness claude|opencode|both, --stack ..., --global-dir <dir>, --force, --dry-run
#
# Output: one line per action (CREATE/UPDATE/SKIP/BACKUP/REMOVE <path> [(reason)]),
# "DRY " prefix under --dry-run, final "created=N updated=N skipped=N removed=N".
# --verify prints "OK <check>" / "RED <check>" plus "verify: N ok, N red".
#
# Hermetic: every fixture lives under mktemp -d; --global-dir always points at a
# temp dir; nothing here ever touches the real $HOME/.claude.
#
# Usage:  bash scripts/test-setup-workflow.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
INSTALLER="$KIT/scripts/setup-workflow.sh"

PASS=0
FAIL=0

DIRS=()
cleanup() {
  for d in "${DIRS[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

mkrepo() { # mkrepo -> sets TDIR to a fresh temp git work tree
  TDIR="$(mktemp -d /tmp/setup-workflow-test.XXXXXX)"
  DIRS+=("$TDIR")
  git -C "$TDIR" init -q
}

mkglobal() { # mkglobal -> sets GDIR to a fresh temp dir (never $HOME)
  GDIR="$(mktemp -d /tmp/setup-workflow-global.XXXXXX)"
  DIRS+=("$GDIR")
}

run() { # run [args...] -- sets OUT/RC
  OUT="$(bash "$INSTALLER" "$@" 2>&1)"
  RC=$?
}

expect_rc() { # expect_rc <desc> <want>
  if [ "$RC" = "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (want rc=$2, got $RC)  [out: ${OUT:0:200}]"; fi
}

expect_has() { # expect_has <desc> <substring>  (checked against $OUT)
  if grep -qF -- "$2" <<< "$OUT"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)  [out: ${OUT:0:300}]"; fi
}

expect_lacks() { # expect_lacks <desc> <substring>  (checked against $OUT)
  if grep -qF -- "$2" <<< "$OUT"; then FAIL=$((FAIL + 1)); echo "FAIL: $1 (must not contain: $2)  [out: ${OUT:0:300}]"; else PASS=$((PASS + 1)); fi
}

expect_exists() { # expect_exists <desc> <path>
  if [ -e "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)"; fi
}

expect_absent() { # expect_absent <desc> <path>
  if [ -e "$2" ]; then FAIL=$((FAIL + 1)); echo "FAIL: $1 (must not exist: $2)"; else PASS=$((PASS + 1)); fi
}

expect_nonempty() { # expect_nonempty <desc> <path>
  if [ -s "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing or empty: $2)"; fi
}

expect_json_eq() { # expect_json_eq <desc> <file> <jq-filter> <expected>
  local got
  got="$(jq -r "$3" "$2" 2>/dev/null)"
  if [ "$got" = "$4" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (want '$4', got '$got')"; fi
}

count_glob() { # count_glob <glob...> -- echoes number of matches
  local n=0 f
  for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s\n' "$n"
}

expect_file_has() { # expect_file_has <desc> <path> <substring>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing '$3' in $2)"
  fi
}

# =====================================================================
# 1. Project install into a bare git repo (--harness both): files present,
#    settings.local.json absent, no test-*.sh / *.test.ts copied.
# =====================================================================
mkrepo
run --mode project --target "$TDIR" --harness both
expect_rc "fresh install (both) exits 0" 0

expect_exists "root AGENTS.md created" "$TDIR/AGENTS.md"
expect_exists "root CLAUDE.md created" "$TDIR/CLAUDE.md"
expect_file_has "root CLAUDE.md contains import line" "$TDIR/CLAUDE.md" "@AGENTS.md"
expect_exists "kit AGENTS.md copy" "$TDIR/.claude/agent-workflow/AGENTS.md"

for f in bulk-reader.md code-writer.md explore.md gate-keeper.md implementer.md reviewer.md spec-critic.md; do
  expect_exists "claude agent copied: $f" "$TDIR/.claude/agents/$f"
done
expect_exists "dev-workflow skill copied" "$TDIR/.claude/skills/dev-workflow/SKILL.md"
expect_exists "setup-workflow skill copied" "$TDIR/.claude/skills/setup-workflow/SKILL.md"
expect_exists "shunt hook copied" "$TDIR/.claude/hooks/shunt.sh"
expect_exists "session-end hook copied" "$TDIR/.claude/hooks/session-end.sh"
expect_exists "statusline script copied" "$TDIR/.claude/statusline-command.sh"
expect_exists "claude settings.json created" "$TDIR/.claude/settings.json"
expect_json_eq "claude settings.json has PreToolUse hook" "$TDIR/.claude/settings.json" '.hooks.PreToolUse | length' "1"

for f in bulk-reader.md build.md code-writer.md explore.md gate-keeper.md implementer.md reviewer.md spec-critic.md; do
  expect_exists "opencode agent copied: $f" "$TDIR/.opencode/agent/$f"
done
expect_exists "opencode shunt plugin copied" "$TDIR/.opencode/plugins/shunt.ts"
expect_exists "opencode usage-log plugin copied" "$TDIR/.opencode/plugins/usage-log.ts"
expect_exists "opencode package.json generated" "$TDIR/.opencode/package.json"
expect_json_eq "opencode package.json pins plugin version" "$TDIR/.opencode/package.json" '.dependencies."@opencode-ai/plugin"' "1.18.30"
expect_exists "opencode .gitignore generated" "$TDIR/.opencode/.gitignore"
expect_file_has "opencode .gitignore ignores node_modules" "$TDIR/.opencode/.gitignore" "node_modules"
expect_absent "opencode node_modules never installed" "$TDIR/.opencode/node_modules"

for f in run-gates.sh review-checklist.sh usage-report.sh usage-import-claude.sh session-tools.sh shunt-report.sh; do
  expect_exists "runtime script copied: $f" "$TDIR/scripts/$f"
done

expect_exists ".gates.yml created" "$TDIR/.gates.yml"
expect_file_has ".gates.yml has sast line" "$TDIR/.gates.yml" "sast: gitleaks detect --no-banner --redact"
expect_file_has ".gates.yml default stack is a hard red for lint" "$TDIR/.gates.yml" "gate not configured"

expect_exists "root .gitignore created" "$TDIR/.gitignore"
for line in ".claude/settings.local.json" ".opencode/settings.local.json" ".usage/" ".opencode/node_modules/"; do
  expect_file_has ".gitignore contains $line" "$TDIR/.gitignore" "$line"
done

expect_exists "manifest written" "$TDIR/.claude/agent-workflow.install.json"
expect_json_eq "manifest mode is project" "$TDIR/.claude/agent-workflow.install.json" '.mode' "project"

expect_absent "settings.local.json never copied" "$TDIR/.claude/settings.local.json"
expect_absent "test-run-gates.sh never copied" "$TDIR/scripts/test-run-gates.sh"
expect_absent "usage-log.test.ts never copied" "$TDIR/scripts/usage-log.test.ts"
expect_absent "shunt.test.ts never copied" "$TDIR/.opencode/plugins/shunt.test.ts"

expect_has "summary line printed" "created="

# =====================================================================
# 2. Re-run is idempotent: 0 created, tree byte-identical (manifest excluded,
#    since it carries a fresh installed_at timestamp on every run).
# =====================================================================
find "$TDIR" -not -path "*/.git/*" -type f -exec sha256sum {} + | sort > "$TDIR/../before.sha" 2>/dev/null || true
BEFORE_SNAPSHOT="$(find "$TDIR" -not -path "*/.git/*" -not -name 'agent-workflow.install.json' -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null)"
run --mode project --target "$TDIR" --harness both
expect_rc "re-run exits 0" 0
expect_has "re-run reports 0 created" "created=0"
AFTER_SNAPSHOT="$(find "$TDIR" -not -path "*/.git/*" -not -name 'agent-workflow.install.json' -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null)"
if [ "$BEFORE_SNAPSHOT" = "$AFTER_SNAPSHOT" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: re-run tree stays byte-identical (excl. manifest)"; fi

# =====================================================================
# 3. Pre-existing AGENTS.md with user content is preserved; import line
#    appended once; second run appends nothing more.
# =====================================================================
mkrepo
printf 'My own project rules.\nDo not touch this.\n' > "$TDIR/AGENTS.md"
run --mode project --target "$TDIR" --harness claude
expect_rc "install over existing AGENTS.md exits 0" 0
expect_file_has "user content preserved" "$TDIR/AGENTS.md" "Do not touch this."
COUNT1="$(grep -c '@\.claude/agent-workflow/AGENTS\.md' "$TDIR/AGENTS.md")"
if [ "$COUNT1" = "1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: import line appended exactly once (got $COUNT1)"; fi
run --mode project --target "$TDIR" --harness claude
COUNT2="$(grep -c '@\.claude/agent-workflow/AGENTS\.md' "$TDIR/AGENTS.md")"
if [ "$COUNT2" = "1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: second run appends nothing more (got $COUNT2)"; fi

# =====================================================================
# 4. Pre-existing .claude/settings.json with a custom key: key survives,
#    hooks added, re-run does not duplicate the hook entry.
# =====================================================================
mkrepo
mkdir -p "$TDIR/.claude"
printf '{"customKey":"value"}\n' > "$TDIR/.claude/settings.json"
run --mode project --target "$TDIR" --harness claude
expect_rc "install merging custom settings.json exits 0" 0
expect_json_eq "custom key survives" "$TDIR/.claude/settings.json" '.customKey' "value"
expect_json_eq "PreToolUse hook added" "$TDIR/.claude/settings.json" '.hooks.PreToolUse | length' "1"
expect_json_eq "SessionEnd hook added" "$TDIR/.claude/settings.json" '.hooks.SessionEnd | length' "1"
expect_json_eq "statusLine added" "$TDIR/.claude/settings.json" '.statusLine.command' "bash .claude/statusline-command.sh"
run --mode project --target "$TDIR" --harness claude
expect_json_eq "PreToolUse hook not duplicated" "$TDIR/.claude/settings.json" '.hooks.PreToolUse | length' "1"
expect_json_eq "SessionEnd hook not duplicated" "$TDIR/.claude/settings.json" '.hooks.SessionEnd | length' "1"
expect_json_eq "custom key still survives" "$TDIR/.claude/settings.json" '.customKey' "value"

# =====================================================================
# 5. Pre-existing .gates.yml is skipped, never overwritten.
# =====================================================================
mkrepo
printf 'stack: custom\nlint: my-custom-lint\n' > "$TDIR/.gates.yml"
BEFORE_GATES="$(cat "$TDIR/.gates.yml")"
run --mode project --target "$TDIR" --harness claude
expect_rc "install with pre-existing .gates.yml exits 0" 0
expect_has "output reports SKIP .gates.yml" "SKIP .gates.yml"
AFTER_GATES="$(cat "$TDIR/.gates.yml")"
if [ "$BEFORE_GATES" = "$AFTER_GATES" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: .gates.yml left untouched"; fi

# =====================================================================
# 6. Drift: modifying a copied agent file blocks a plain re-run; --force
#    backs it up and restores the kit's version.
# =====================================================================
mkrepo
run --mode project --target "$TDIR" --harness claude
printf '\n# local tweak\n' >> "$TDIR/.claude/agents/implementer.md"
MODIFIED_CONTENT="$(cat "$TDIR/.claude/agents/implementer.md")"
run --mode project --target "$TDIR" --harness claude
expect_rc "re-run with drift still exits 0" 0
expect_has "drifted agent file is skipped" "SKIP .claude/agents/implementer.md"
CURRENT_CONTENT="$(cat "$TDIR/.claude/agents/implementer.md")"
if [ "$CURRENT_CONTENT" = "$MODIFIED_CONTENT" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: skipped file keeps local changes"; fi

run --mode project --target "$TDIR" --harness claude --force
expect_rc "forced re-run exits 0" 0
expect_has "forced overwrite reports BACKUP" "BACKUP .claude/agents/implementer.md"
BACKUPS="$(count_glob "$TDIR"/.claude/agents/implementer.md.bak.*)"
if [ "$BACKUPS" -ge 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: a .bak.<epoch> file was written"; fi
if diff -q "$TDIR/.claude/agents/implementer.md" "$KIT/.claude/agents/implementer.md" > /dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: --force restores the kit's version"
fi

# =====================================================================
# 7. Harness isolation + pinned opencode dependency version.
# =====================================================================
mkrepo
run --mode project --target "$TDIR" --harness claude
expect_rc "claude-only install exits 0" 0
expect_absent "claude-only install writes no .opencode/" "$TDIR/.opencode"

mkrepo
run --mode project --target "$TDIR" --harness opencode
expect_rc "opencode-only install exits 0" 0
expect_absent "opencode-only install writes no .claude/agents/" "$TDIR/.claude/agents"
expect_json_eq "opencode-only package.json still pins version" "$TDIR/.opencode/package.json" '.dependencies."@opencode-ai/plugin"' "1.18.30"

# =====================================================================
# 8. --dry-run changes nothing on disk and exits 0.
# =====================================================================
mkrepo
run --mode project --target "$TDIR" --harness both --dry-run
expect_rc "dry-run exits 0" 0
expect_has "dry-run output is prefixed" "DRY CREATE"
expect_absent "dry-run creates no AGENTS.md" "$TDIR/AGENTS.md"
expect_absent "dry-run creates no .claude dir" "$TDIR/.claude"
expect_absent "dry-run creates no .opencode dir" "$TDIR/.opencode"
expect_absent "dry-run creates no .gates.yml" "$TDIR/.gates.yml"
expect_absent "dry-run creates no .gitignore" "$TDIR/.gitignore"

# =====================================================================
# 9. Precondition failures each exit 1.
# =====================================================================
run --mode project
expect_rc "missing --target exits 1" 1

TFILE="$(mktemp /tmp/setup-workflow-file.XXXXXX)"
DIRS+=("$TFILE")
run --mode project --target "$TFILE"
expect_rc "non-directory target exits 1" 1

NONGIT="$(mktemp -d /tmp/setup-workflow-nongit.XXXXXX)"
DIRS+=("$NONGIT")
run --mode project --target "$NONGIT"
expect_rc "non-git target exits 1" 1

KIT_STATUS_BEFORE="$(git -C "$KIT" status --porcelain)"
run --mode project --target "$KIT"
expect_rc "self-install refused, exits 1" 1
KIT_STATUS_AFTER="$(git -C "$KIT" status --porcelain)"
if [ "$KIT_STATUS_BEFORE" = "$KIT_STATUS_AFTER" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: self-install refusal left the kit untouched"; fi

# =====================================================================
# 10. --mode global --harness opencode/both is rejected.
# =====================================================================
mkglobal
run --mode global --global-dir "$GDIR" --harness both
expect_rc "global + both harness exits 1" 1
mkglobal
run --mode global --global-dir "$GDIR" --harness opencode
expect_rc "global + opencode harness exits 1" 1

# =====================================================================
# 11. Global mode into a temp --global-dir.
# =====================================================================
mkglobal
printf '{"customKey":"globalvalue"}\n' > "$GDIR/settings.json"
run --mode global --global-dir "$GDIR"
expect_rc "global install exits 0" 0
expect_exists "global AGENTS.md shim" "$GDIR/AGENTS.md"
expect_file_has "global AGENTS.md points at the kit" "$GDIR/AGENTS.md" "$KIT/AGENTS.md"
expect_exists "global shunt hook shim" "$GDIR/hooks/shunt.sh"
expect_file_has "global shunt shim execs the kit's hook" "$GDIR/hooks/shunt.sh" "$KIT/.claude/hooks/shunt.sh"
expect_exists "global session-end shim" "$GDIR/hooks/session-end.sh"
expect_file_has "global session-end shim exports USAGE_IMPORT_CMD" "$GDIR/hooks/session-end.sh" "USAGE_IMPORT_CMD"
expect_file_has "global session-end shim points at usage-import-claude.sh" "$GDIR/hooks/session-end.sh" "usage-import-claude.sh"
expect_exists "global statusline shim" "$GDIR/statusline-command.sh"
expect_exists "global dev-workflow skill shim" "$GDIR/skills/dev-workflow/SKILL.md"
expect_file_has "global dev-workflow shim keeps frontmatter" "$GDIR/skills/dev-workflow/SKILL.md" "$(head -1 "$KIT/.claude/skills/dev-workflow/SKILL.md")"
expect_file_has "global dev-workflow shim points at the kit" "$GDIR/skills/dev-workflow/SKILL.md" "$KIT/.claude/skills/dev-workflow/SKILL.md"
expect_exists "global setup-workflow skill shim" "$GDIR/skills/setup-workflow/SKILL.md"
expect_exists "global agents copy" "$GDIR/agents/implementer.md"
expect_json_eq "global settings.json custom key survives" "$GDIR/settings.json" '.customKey' "globalvalue"
expect_json_eq "global settings.json PreToolUse hook added" "$GDIR/settings.json" '.hooks.PreToolUse | length' "1"
expect_json_eq "global settings.json SessionEnd hook added" "$GDIR/settings.json" '.hooks.SessionEnd | length' "1"
expect_exists "global manifest written" "$GDIR/agent-workflow.install.json"
expect_json_eq "global manifest mode is global" "$GDIR/agent-workflow.install.json" '.mode' "global"

run --mode global --global-dir "$GDIR"
expect_rc "global re-run exits 0" 0
expect_json_eq "global re-run does not duplicate PreToolUse hook" "$GDIR/settings.json" '.hooks.PreToolUse | length' "1"
expect_json_eq "global re-run does not duplicate SessionEnd hook" "$GDIR/settings.json" '.hooks.SessionEnd | length' "1"

# =====================================================================
# 12. --verify: green on a fresh install, red (exit 2) once a file breaks.
# =====================================================================
mkrepo
run --mode project --target "$TDIR" --harness claude
run --verify --target "$TDIR"
expect_rc "verify on a fresh install exits 0" 0
expect_has "verify prints a summary" "verify:"
expect_has "verify reports 0 red" "0 red"

printf 'not valid json' > "$TDIR/.claude/settings.json"
run --verify --target "$TDIR"
expect_rc "verify after breaking settings.json exits 2" 2
expect_has "verify reports the broken check" "RED"

# =====================================================================
# 13. --uninstall removes unmodified files, keeps a drifted one, exits 0.
# =====================================================================
mkrepo
run --mode project --target "$TDIR" --harness claude
printf '\n# local tweak\n' >> "$TDIR/.claude/agents/reviewer.md"
run --uninstall --target "$TDIR"
expect_rc "uninstall exits 0" 0
expect_absent "unmodified file removed" "$TDIR/.claude/agents/implementer.md"
expect_exists "drifted file kept" "$TDIR/.claude/agents/reviewer.md"
expect_has "uninstall reports the kept file" "SKIP .claude/agents/reviewer.md"
expect_absent "manifest removed" "$TDIR/.claude/agent-workflow.install.json"
expect_exists "root AGENTS.md untouched by uninstall" "$TDIR/AGENTS.md"
expect_has "uninstall reminds about AGENTS.md/CLAUDE.md/.gitignore" "by hand"

NOMANIFEST="$(mktemp -d /tmp/setup-workflow-nomanifest.XXXXXX)"
DIRS+=("$NOMANIFEST")
git -C "$NOMANIFEST" init -q
run --uninstall --target "$NOMANIFEST"
expect_rc "uninstall without a manifest exits 1" 1

# =====================================================================
# 14. Hook command strings must resolve inside the install root.
#     A project-relative command in a global settings.json resolves against
#     the project cwd, pointing at hooks a global install never created.
# =====================================================================
mkglobal
GDIRP="$(cd "$GDIR" && pwd -P)"
printf '{"model":"opus","theme":"dark"}\n' > "$GDIR/settings.json"
run --mode global --global-dir "$GDIR"
expect_rc "global install over an existing settings.json exits 0" 0
expect_json_eq "global shunt hook resolves inside the global dir" \
  "$GDIR/settings.json" '.hooks.PreToolUse[0].hooks[0].command' "bash $GDIRP/hooks/shunt.sh"
expect_json_eq "global session-end hook resolves inside the global dir" \
  "$GDIR/settings.json" '.hooks.SessionEnd[0].hooks[0].command' "bash $GDIRP/hooks/session-end.sh"
expect_json_eq "global statusline resolves inside the global dir" \
  "$GDIR/settings.json" '.statusLine.command' "bash $GDIRP/statusline-command.sh"
expect_json_eq "pre-existing personal key survives the merge" \
  "$GDIR/settings.json" '.model' "opus"

run --mode global --global-dir "$GDIR"
expect_json_eq "re-run adds no duplicate PreToolUse entry" \
  "$GDIR/settings.json" '.hooks.PreToolUse | length' "1"
expect_json_eq "re-run adds no duplicate SessionEnd entry" \
  "$GDIR/settings.json" '.hooks.SessionEnd | length' "1"

mkglobal
GDIRP="$(cd "$GDIR" && pwd -P)"
run --mode global --global-dir "$GDIR"
expect_rc "global install into a fresh dir exits 0" 0
expect_json_eq "fresh global shunt hook resolves inside the global dir" \
  "$GDIR/settings.json" '.hooks.PreToolUse[0].hooks[0].command' "bash $GDIRP/hooks/shunt.sh"
if grep -qF 'bash .claude/hooks/shunt.sh' "$GDIR/settings.json"; then
  FAIL=$((FAIL + 1)); echo "FAIL: fresh global settings.json carries a project-relative hook path"
else
  PASS=$((PASS + 1))
fi

mkrepo
run --mode project --target "$TDIR" --harness claude
expect_json_eq "project shunt hook stays project-relative" \
  "$TDIR/.claude/settings.json" '.hooks.PreToolUse[0].hooks[0].command' "bash .claude/hooks/shunt.sh"

# The default global dir must emit the tilde form Claude Code already writes,
# so a re-run over a hand-made global install converges instead of duplicating.
FAKEHOME="$(mktemp -d /tmp/setup-workflow-home.XXXXXX)"
DIRS+=("$FAKEHOME")
mkdir -p "$FAKEHOME/.claude"
printf '{"hooks":{"PreToolUse":[{"matcher":"Read|Bash","hooks":[{"type":"command","command":"bash ~/.claude/hooks/shunt.sh","timeout":10}]}]}}\n' \
  > "$FAKEHOME/.claude/settings.json"
OUT="$(HOME="$FAKEHOME" bash "$INSTALLER" --mode global --global-dir "$FAKEHOME/.claude" 2>&1)"; RC=$?
expect_rc "global install into the default home dir exits 0" 0
expect_json_eq "default global dir uses the tilde form" \
  "$FAKEHOME/.claude/settings.json" '.hooks.PreToolUse[0].hooks[0].command' 'bash ~/.claude/hooks/shunt.sh'
expect_json_eq "hand-made tilde hook is not duplicated" \
  "$FAKEHOME/.claude/settings.json" '.hooks.PreToolUse | length' "1"

# =====================================================================
# 15. --uninstall must unmerge settings.json, not delete it: a file that
#     pre-existed carries personal keys the kit never owned.
# =====================================================================
mkrepo
mkdir -p "$TDIR/.claude"
printf '{"model":"opus","customKey":"important-value"}\n' > "$TDIR/.claude/settings.json"
run --mode project --target "$TDIR" --harness claude
run --uninstall --target "$TDIR"
expect_rc "uninstall over a merged settings.json exits 0" 0
expect_exists "pre-existing settings.json survives uninstall" "$TDIR/.claude/settings.json"
expect_json_eq "personal key survives uninstall" \
  "$TDIR/.claude/settings.json" '.model' "opus"
expect_json_eq "arbitrary key survives uninstall" \
  "$TDIR/.claude/settings.json" '.customKey' "important-value"
expect_json_eq "kit PreToolUse hook is unmerged" \
  "$TDIR/.claude/settings.json" '.hooks.PreToolUse // [] | length' "0"
expect_json_eq "kit SessionEnd hook is unmerged" \
  "$TDIR/.claude/settings.json" '.hooks.SessionEnd // [] | length' "0"
expect_json_eq "kit statusLine is unmerged" \
  "$TDIR/.claude/settings.json" '.statusLine.command // "none"' "none"

# A settings.json the kit created holds nothing else, so it goes away entirely.
mkrepo
run --mode project --target "$TDIR" --harness claude
run --uninstall --target "$TDIR"
expect_absent "kit-created settings.json is removed" "$TDIR/.claude/settings.json"

# A user-edited hook command no longer matches the kit's, so it stays.
mkrepo
run --mode project --target "$TDIR" --harness claude
tmpjson="$(mktemp)"
jq '.hooks.PreToolUse[0].hooks[0].command = "bash my-own-hook.sh"' \
  "$TDIR/.claude/settings.json" > "$tmpjson" && mv "$tmpjson" "$TDIR/.claude/settings.json"
run --uninstall --target "$TDIR"
expect_json_eq "a user-rewritten hook command is left alone" \
  "$TDIR/.claude/settings.json" '.hooks.PreToolUse | length' "1"

# =====================================================================
# 16. A .gitignore with no trailing newline must not get its last line
#     concatenated with the first appended one.
# =====================================================================
mkrepo
printf 'node_modules' > "$TDIR/.gitignore"
run --mode project --target "$TDIR" --harness claude
expect_rc "install over a newline-less .gitignore exits 0" 0
if grep -qxF 'node_modules' "$TDIR/.gitignore"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: pre-existing .gitignore line survives intact"
fi
expect_file_has "appended ignore line is on its own line" \
  "$TDIR/.gitignore" ".claude/settings.local.json"
if grep -qF 'node_modules.claude' "$TDIR/.gitignore"; then
  FAIL=$((FAIL + 1)); echo "FAIL: .gitignore lines were concatenated"
else
  PASS=$((PASS + 1))
fi

# =====================================================================
# summary
# =====================================================================
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
