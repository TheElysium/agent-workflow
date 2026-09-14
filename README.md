# agent-workflow

Versioned, copy-paste kit for the multi-agent development workflow with **opencode** and **Claude Code**.

## Structure

```
AGENTS.md                    ← single source of truth: 5-phase workflow + shunt pattern +
                               multi-agent rules. opencode reads this from the project root.

CLAUDE.md                    ← one line: @AGENTS.md (Claude Code import syntax)

.claude/                     ← copy into the project root
├── settings.json            ← structural keys only (permissions, hooks, statusLine)
├── settings.local.json      ← created locally, gitignored; not part of the kit copy
├── statusline-command.sh    ← referenced by settings.json
├── hooks/shunt.sh           ← PreToolUse shunt hook + hooks/test-shunt.sh
└── agents/                  ← implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer, spec-critic

.opencode/                   ← copy into the project root
├── agent/                   ← build, implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer, spec-critic
└── plugins/shunt.ts         ← shunt plugin

.gates.yml                   ← lint / typecheck / build / test / sast / format commands
.github/workflows/ci.yml     ← optional CI mirror of .gates.yml

githooks/                    ← this repo's self-gate only (pre-commit + tests), not shipped to projects
README.md
LICENSE
```

## Install

Copy the kit into a new or existing project root:

```bash
cp -r AGENTS.md CLAUDE.md .claude .opencode /path/to/project/
cd /path/to/project
```

This repo itself uses its own kit (auto-dogfooding). Beyond the kit it carries `githooks/` and `.gates.yml` for its own self-gate (wired with `git config core.hooksPath githooks` here only); projects may mirror the gate pattern with their own `.gates.yml` + pre-commit, but they are not part of the copy.

## Workflow (summary)

Task routing: T0 direct → T1 lightweight → T2 orchestrated (criteria: files touched, risk, API surface, architectural impact).

T2 flow: spec (→ spec-critic on non-trivial specs) → decomposition → explore/bulk-reader (parallel) → implementer (evidence-first: TDD for behavior changes, suite green + typecheck for mechanical changes) → gate-keeper (lint/typecheck/build/tests/SAST) → reviewer (peer review + intent gate) → commit → push only on explicit request. Two gates: engineering (`.gates.yml`) and intent (spec vs implementation).

Details: see `AGENTS.md`.

### Enforceable gates

- Every project carries a `.gates.yml` at its root (format documented in `AGENTS.md`, Phase 4): the single source of lint/typecheck/build/test/sast commands. `gate-keeper` runs it verbatim; a missing file is built with the user, never discovered by guesswork.
- SAST is non-skippable (gitleaks + the stack's audit tool). A gate run without SAST is a red gate.
- Enforcement is local-only by default: `@gate-keeper` blocks a task before it is done and before commit. The CI layer (`.github/workflows/ci.yml` mirroring `.gates.yml`) is optional — only for projects whose CI you control.
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
| `jq` (Windows) | `.claude/hooks/shunt.sh` | `winget install jqlang.jq` — Git Bash inherits the Windows PATH. Without it the hook fails open silently (no blocking) |
| `jq` + `shellcheck` (Linux, `~/.local/bin`) | dev only: test harness, linting | Optional; harness uses the WSL path fallback |
| `gitleaks` (Linux, `~/.local/bin`) | `githooks/pre-commit` secrets gate | Without it the gate falls back to a weak pattern scan |

### Machine-specific paths

`settings.json` uses relative paths that resolve from the project root. Override points:

- `SHUNT_TEST_TMP` env var — replaces the fixture temp dir in `.claude/hooks/test-shunt.sh` (dev only)

Everything else (agents, rules, hook logic, thresholds) is machine-agnostic.

## Cross-tool sync notes

- `AGENTS.md` (root) is the single canonical copy of the workflow rules. `CLAUDE.md` imports it via `@AGENTS.md`. The pre-commit hook blocks any commit where `CLAUDE.md` is not exactly one line `@AGENTS.md`.
- **Shunt parity**: opencode enforces it via the `shunt.ts` plugin, Claude Code via the `shunt.sh` hook (same thresholds, 350 lines / 65536 bytes; tuned on either side with `SHUNT_MIN_LINES` / `SHUNT_MAX_BYTES`). Boundary detail: a file with exactly 350 lines passes on the Claude side (`wc -l`), while shunt.ts counts the trailing newline as a line and blocks it. Claude Code flags subagent calls with a top-level `agent_id`, which replaces the plugin's delegated-session tracking. Test the hook with `bash .claude/hooks/test-shunt.sh` (exercises the WSL path fallback; the Git Bash/cygpath branch is exercised in production).
- Accepted divergences: `hidden`/`temperature` agent fields are opencode only; detailed permissions (Task, bash patterns) opencode only; `git push` ask = permission rule on the Claude Code side, `permission` field on the opencode side.
- `.claude/settings.json` is versioned without secrets (credentials live in `.claude/settings.local.json`, never committed).
- `.opencode/settings.local.json` is also machine-local and never committed.
