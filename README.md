# agent-workflow

Versioned, copy-paste kit for the multi-agent development workflow with **opencode** and **Claude Code**.

## Structure

```
AGENTS.md                    ← single source of truth: shunt pattern + task routing (T0/T1/T2)
                               only. Always loaded (~600 tokens). opencode reads this from the
                               project root. T1/T2 work points to the dev-workflow skill below.

CLAUDE.md                    ← one line: @AGENTS.md (Claude Code import syntax)

.claude/                     ← copy into the project root
├── settings.json            ← structural keys only (permissions, hooks, statusLine)
├── settings.local.json      ← created locally, gitignored; not part of the kit copy
├── statusline-command.sh    ← referenced by settings.json
├── hooks/shunt.sh           ← PreToolUse shunt hook + hooks/test-shunt.sh
├── agents/                  ← implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer, spec-critic
└── skills/dev-workflow/     ← 5-phase workflow + multi-agent rules, loaded on demand for T1/T2

.opencode/                   ← copy into the project root
├── agent/                   ← build, implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer, spec-critic
└── plugins/shunt.ts         ← shunt plugin

.gates.yml                   ← lint / typecheck / build / test / sast / format commands
.github/workflows/ci.yml     ← optional CI: runs the gates by executing .gates.yml via scripts/run-gates.sh

githooks/                    ← this repo's self-gate only (pre-commit + tests), not shipped to projects
README.md
LICENSE
```

## Install

Two ways to deploy the kit — pick one per machine, they aren't mutually exclusive with other projects running the other mode.

### Per-project

Isolated, versioned with the project; safe default when different projects need different agent tuning or workflow revisions.

```bash
cp -r AGENTS.md CLAUDE.md .gates.yml .claude .opencode /path/to/project/
cd /path/to/project
```

### Global (one copy, every session, any project)

Symlinks need admin on Windows (tested twice: PowerShell `New-Item -ItemType SymbolicLink` and Git Bash `ln -s` with `MSYS=winsymlinks:nativestrict` both fail without elevation; plain `ln -s` silently falls back to a copy, not a link). Until that trade-off is settled, plain shims — no elevation needed:

```bash
REPO=/path/to/agent-workflow   # this repo, cloned once

# AGENTS.md: one-line native import
mkdir -p ~/.claude
echo "@$REPO/AGENTS.md" > ~/.claude/AGENTS.md

# shunt.sh: one-line exec shim (hooks run as scripts, @import doesn't apply)
mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/shunt.sh <<EOF
#!/usr/bin/env bash
# Shim — source of truth is the agent-workflow repo. Do not edit this copy;
# edit .claude/hooks/shunt.sh in the repo instead, this file just execs it.
exec bash "$REPO/.claude/hooks/shunt.sh" "\$@"
EOF
chmod +x ~/.claude/hooks/shunt.sh

# dev-workflow skill: one-line pointer shim (skills don't support @import either)
mkdir -p ~/.claude/skills/dev-workflow
cat > ~/.claude/skills/dev-workflow/SKILL.md <<EOF
---
name: dev-workflow
description: Multi-phase development workflow (spec, plan, implement, verify gates, git, multi-agent orchestration) for T1/T2 tasks — substantial features, refactors, or anything touching architecture, auth, DB, or a public API surface. Use when a task is routed T1 or T2 per AGENTS.md task-routing criteria, or when the user asks to "follow the workflow" / "orchestrate this".
---

Shim — source of truth is the agent-workflow repo. Do not edit this copy;
edit .claude/skills/dev-workflow/SKILL.md in the repo instead.

Read and follow exactly:
$REPO/.claude/skills/dev-workflow/SKILL.md
EOF

# agent roster: no pointer mechanism available — plain synced copies
mkdir -p ~/.claude/agents
cp "$REPO"/.claude/agents/*.md ~/.claude/agents/
```

Re-run the last `cp` whenever `.claude/agents/*.md` changes in the repo — nothing detects drift automatically:

```bash
diff -rq ~/.claude/agents "$REPO/.claude/agents"
```

Restart any running Claude Code session after first-time setup — it only detects a new `~/.claude/agents/` directory at session start.

This repo itself uses its own kit (auto-dogfooding), in global mode. Beyond the kit it carries `githooks/` and `.gates.yml` for its own self-gate (wired with `git config core.hooksPath githooks` here only); projects may mirror the gate pattern with their own `.gates.yml` + pre-commit, but they are not part of the copy.

## Workflow (summary)

Task routing: T0 direct → T1 lightweight → T2 orchestrated (criteria: files touched, risk, API surface, architectural impact). Routing itself lives in `AGENTS.md`, always loaded. T0 acts directly, no ceremony; T1/T2 invoke the `dev-workflow` skill (`.claude/skills/dev-workflow/SKILL.md`), which is only pulled into context when a task actually needs it — this is what keeps the always-loaded `AGENTS.md` down to ~600 tokens instead of the ~4500 the full phase-by-phase process would cost every session.

T2 flow (inside the skill): spec (→ spec-critic on non-trivial specs) → decomposition → explore/bulk-reader (parallel) → implementer (evidence-first: TDD for behavior changes, suite green + typecheck for mechanical changes) → gate-keeper (lint/typecheck/build/tests/SAST) → reviewer (peer review + intent gate) → commit → push only on explicit request. Two gates: engineering (`.gates.yml`) and intent (spec vs implementation).

`dev-workflow` and the agent roster (`.claude/agents/`, `.opencode/agent/`) can be deployed per-project or globally — see Install for the concrete steps and trade-offs of each.

Details: see `AGENTS.md` (routing) and `.claude/skills/dev-workflow/SKILL.md` (phases).

### Enforceable gates

- Every project carries a `.gates.yml` at its root (format documented in the dev-workflow skill, Phase 4: `.claude/skills/dev-workflow/SKILL.md`): the single source of lint/typecheck/build/test/sast commands. `gate-keeper` runs it verbatim; a missing file is built with the user, never discovered by guesswork.
- SAST is non-skippable (gitleaks + the stack's audit tool). A gate run without SAST is a red gate; in `githooks/pre-commit` a missing gate tool (shellcheck, gitleaks, jq) is itself a hard red — the commit is blocked until the tool is installed.
- Enforcement is local-only by default: `@gate-keeper` blocks a task before it is done and before commit. The CI layer (`.github/workflows/ci.yml` running `.gates.yml` via `scripts/run-gates.sh`) is optional — only for projects whose CI you control.
- Task state: long tasks persist their spec, decisions, todo and gate status in `docs/tasks/<slug>.md` (updated by the orchestrator; sessions read it before resuming).
- This repo self-enforces: `githooks/pre-commit` (activate with `git config core.hooksPath githooks`) runs shellcheck, a secrets scan, an English/no-accents check, JSON validation, and the `CLAUDE.md == @AGENTS.md` check on every commit.

## Per-project overrides

To adapt an agent to a stack (e.g. Rust for a Tauri project), place a same-name/id file in the project:
- Claude Code: `.claude/agents/<name>.md`
- opencode: `.opencode/agent/<id>.md` (definitions merge: scalar fields replaced, permission rules appended)

The kit definition is the base; the project file only adds stack specifics.

## Dependencies

| Tool | Needed by | Notes |
|------|-----------|-------|
| Git for Windows (Git Bash) | Claude Code hooks | Hooks run via Git Bash; `bash.exe` at `C:\Windows\system32` is WSL bash, not Git Bash |
| `jq` (Windows) | `.claude/hooks/shunt.sh` | `winget install jqlang.jq` — Git Bash inherits the Windows PATH. Without it the shunt hook fails open silently (no blocking), and the pre-commit JSON check blocks the commit (hard red) |
| `jq` + `shellcheck` + `gitleaks` (Linux, `~/.local/bin`) | dev: gates + test harness | A missing gate tool blocks the pre-commit (hard red) — install all three before committing |

### Machine-specific paths

`settings.json` uses relative paths that resolve from the project root. Override points:

- `SHUNT_TEST_TMP` env var — replaces the fixture temp dir in `.claude/hooks/test-shunt.sh` (dev only)

Everything else (agents, rules, hook logic, thresholds) is machine-agnostic.

## Cross-tool sync notes

- `AGENTS.md` (root) is the single canonical copy of the workflow rules. `CLAUDE.md` imports it via `@AGENTS.md`. The pre-commit hook blocks any commit where `CLAUDE.md` is not exactly one line `@AGENTS.md`.
- **Shunt parity**: opencode enforces it via the `shunt.ts` plugin, Claude Code via the `shunt.sh` hook (same thresholds, 350 lines / 65536 bytes; tuned on either side with `SHUNT_MIN_LINES` / `SHUNT_MAX_BYTES`). Boundary detail: a file with exactly 350 lines passes on the Claude side (`wc -l`), while shunt.ts counts the trailing newline as a line and blocks it. Claude Code flags subagent calls with a top-level `agent_id`, which replaces the plugin's delegated-session tracking. Word-boundary detail: `verb/foo.txt` (no space after the verb) is blocked on the opencode side (`\b`) and passes on the Claude side (`([[:space:]]|$)`); both trigger on a following space or end-of-command. Test the hook with `bash .claude/hooks/test-shunt.sh` (exercises the WSL path fallback; the Git Bash/cygpath branch is exercised in production).
- **Skill parity**: `.claude/skills/dev-workflow/SKILL.md` needs no opencode-specific copy — opencode natively discovers `.claude/skills/*/SKILL.md` in the project (and `~/.claude/skills/*/SKILL.md` globally), same frontmatter format as Claude Code.
- **Shunt telemetry**: every denied Read/Bash call appends one JSONL line to `.usage/shunt.jsonl` (harness-neutral schema: `ts`/`harness`/`session`/`tool`/`path`/`reason` (`bytes`|`lines`)/`bytes`/`lines`/`threshold_bytes`/`threshold_lines`, plus `command` for `tool: "bash"` only). Logging is best-effort on both sides — a write failure never blocks the redirect. Aggregate with `scripts/shunt-report.sh` (`--file`/`--since`/`--session`, same conventions as `scripts/usage-report.sh`): total blocks, breakdown by harness/tool/reason, top blocked files.
- Accepted divergences: `hidden`/`temperature` agent fields are opencode only; detailed permissions (Task, bash patterns) opencode only; `git push` ask = permission rule on the Claude Code side, `permission` field on the opencode side.
- `.claude/settings.json` is versioned without secrets (credentials live in `.claude/settings.local.json`, never committed).
- `.opencode/settings.local.json` is also machine-local and never committed.
