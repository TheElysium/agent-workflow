# agent-workflow

Versioned kit for a multi-agent development workflow with **Claude Code** (opencode
optional): task routing, agent roster, token-shunt hook, enforceable gates, installer.

```bash
bash /path/to/agent-workflow/scripts/setup-workflow.sh --mode project --target . --dry-run
```

## Why

- **Route before working.** A typo must not pay for a spec, a critic and two gate runs.
- **Load rules on demand.** `AGENTS.md` ~600 tokens, always on. The five phases ~4500,
  only when routed T1/T2.
- **Cheap models read, the expensive one decides.** The shunt hook redirects large reads
  to subagents; reasoning stays on the primary model.
- **Two gates.** `.gates.yml` proves the code runs; the reviewer proves it does what was
  asked. Green tests on the wrong feature is a failed task.
- **Evidence before code.** Every brief names its proof form (TDD, suite green, manual QA).
- **Gates are data, not prompts.** `.gates.yml` runs verbatim in CI and under an agent
  that never interprets results.

## Workflow

```mermaid
flowchart TD
    Task([Task]) --> Route{"Route:<br/>files? risk? API? architecture?"}

    Route -->|"T0 - one file, low risk"| Direct["Act directly"]
    Route -->|"T1 - 2-3 files, tests exist"| Load
    Route -->|"T2 - architecture, auth, DB,<br/>API, security, or 3+ files"| Load

    Load[["dev-workflow skill<br/>(loaded on demand)"]] --> Spec

    Spec["Phase 1 - restate the spec"] --> Critic{{"spec-critic"}}
    Critic -->|NEEDS_CLARIFICATION| Interview["Interview the user"]
    Interview --> Spec
    Critic -->|STRUCTURED| Discover{{"explore / bulk-reader"}}

    Discover --> Plan["Phase 2 - vertical slices, HITL or AFK"]
    Plan --> Impl{{"implementer<br/>(evidence-first, parallel)"}}

    Impl --> Eng{{"gate-keeper<br/>.gates.yml verbatim"}}
    Impl --> Intent{{"reviewer<br/>intent gate"}}

    Eng -->|RED| Impl
    Intent -->|REQUEST_CHANGES| Impl
    Eng -->|green| Commit
    Intent -->|APPROVE| Commit

    Commit["Phase 5 - commit on the task branch<br/>(push only when asked)"] --> Done([Done])
    Direct --> Done
```

| Level | Trigger | Process |
|---|---|---|
| **T0** | 1 file, low risk, no API surface | act directly |
| **T1** | 2-3 files, existing tests prove it | `dev-workflow` skill |
| **T2** | architecture, auth, DB, API, security, or 3+ files with new behavior | `dev-workflow` skill |

In doubt, route one level up. Routing lives in `AGENTS.md`, phases in
`.claude/skills/dev-workflow/SKILL.md`.

## Install

| You use | Flag | Installed |
|---|---|---|
| Claude Code only | `--harness claude` (default) | `.claude/` |
| opencode only | `--harness opencode` | `.opencode/` |
| Both | `--harness both` | both |

### Project mode

```bash
KIT=/path/to/agent-workflow
bash "$KIT/scripts/setup-workflow.sh" --mode project --target DIR --stack rust --dry-run
bash "$KIT/scripts/setup-workflow.sh" --mode project --target DIR --stack rust
bash "$KIT/scripts/setup-workflow.sh" --verify --target DIR
```

`--stack`: `shell` `node` `bun` `python` `rust` `other` - picks the `.gates.yml`
skeleton. An existing `.gates.yml` is never overwritten.

### Global mode

Claude Code only; opencode reads `~/.config/opencode/`, unsupported.

```bash
bash "$KIT/scripts/setup-workflow.sh" --mode global      # override root with --global-dir
```

Writes `~/.claude/` shims: `@import` for `AGENTS.md`, `exec` shims for hooks and
statusline, pointer shims for skills, plain copies of the agents (no pointer mechanism -
re-run when `.claude/agents/*.md` changes). `settings.json` is merged key-wise with `jq`.
Restart running sessions after a first install: `~/.claude/agents/` is detected at start.

Symlinks would be cleaner but need admin on Windows (`New-Item -ItemType SymbolicLink`
and `ln -s` with `MSYS=winsymlinks:nativestrict` both fail unelevated; plain `ln -s`
silently copies). Shims need no elevation.

`/setup-workflow` runs the same script after interviewing for harness, mode and stack.

### Re-runs

Manifest `.claude/agent-workflow.install.json` (kit commit + sha256 per file):

- hash matches -> updated silently; you edited it -> `SKIP (local changes)`
- `--force` overwrites after a `<file>.bak.<epoch>`
- `--uninstall` removes only unmodified kit files; a `settings.json` that predates the
  install is unmerged (kit hooks and `statusLine` stripped, your keys kept), not deleted
- `--verify` exits 2 on any broken path

### Not done by the installer

`bun install` (network-free by design: generates `.opencode/package.json` with a pinned
`@opencode-ai/plugin`, prints the command), CI (`ci.yml` here is shell-stack only),
pre-commit (`githooks/` enforces this repo's own policy), rewriting your `AGENTS.md`
(kit rules go to `.claude/agent-workflow/AGENTS.md`, one `@` import line is appended).

**Trust boundary**: committed hooks mean every collaborator runs kit shell code on every
`Read`/`Bash`. `.usage/shunt.jsonl` records full commands and paths - it is gitignored
for that reason. Do not commit it.

## Layout

```
AGENTS.md                  routing + shunt rules, always loaded. CLAUDE.md = one line @AGENTS.md
.claude/settings.json      permissions, hooks, statusLine       settings.local.json  never installed
.claude/hooks/             shunt.sh (PreToolUse), session-end.sh (usage import)
.claude/agents/            implementer reviewer gate-keeper explore bulk-reader code-writer spec-critic
.claude/skills/            dev-workflow, setup-workflow
.opencode/agent/           same roster, opencode format (+ build)
.opencode/plugins/         shunt.ts (parity with shunt.sh), usage-log.ts
scripts/setup-workflow.sh  the installer
scripts/run-gates.sh       executes .gates.yml (gate-keeper + CI)
scripts/review-checklist.sh   per-file checklist fed to the reviewer
scripts/{usage-report,usage-import-claude,session-tools,shunt-report}.sh   cost + telemetry
scripts/test-*.sh          kit-only, never installed
.gates.yml                 lint / typecheck / build / test / sast / format
.github/ githooks/         this repo's own CI and self-gate, not installed
```

## Gates

- `.gates.yml` at every project root is the single source of gate commands; `gate-keeper`
  runs it verbatim. Missing file -> built with the user, never guessed.
- A generated skeleton emits unfillable gates as hard reds
  (`echo "gate not configured" >&2 && exit 1`). A green run proving nothing is worse than none.
- SAST is non-skippable. A run without it is a red gate. Missing tool = FAIL, never skip.
- Local-only by default; CI optional. Long tasks persist state in `docs/tasks/<slug>.md`.
- This repo self-gates: `git config core.hooksPath githooks` (shellcheck, secrets, ASCII,
  JSON, `CLAUDE.md == @AGENTS.md`).

## Per-project overrides

Same-name file in the project: `.claude/agents/<name>.md` or `.opencode/agent/<id>.md`
(opencode merges: scalars replaced, permission rules appended). Kit definition is the
base; the project file adds stack specifics. The installer detects these by hash and
skips them on re-run.

## Dependencies

| Tool | Needed by | Notes |
|---|---|---|
| Git Bash | Claude Code hooks | `bash.exe` in `C:\Windows\system32` is WSL bash, not Git Bash |
| `jq` | shunt hook, settings merges, reports | `winget install jqlang.jq`. Missing -> shunt fails open silently |
| `shellcheck`, `gitleaks` | gates, self-gate | missing gate tool = hard red |
| `bun` | opencode plugins only | `bun install` in `.opencode/` |

Paths in `settings.json` are relative to the project root. Only machine-specific knob:
`SHUNT_TEST_TMP` (fixture temp dir in `test-shunt.sh`, dev only).

## Cross-tool parity

- **Shunt**: `shunt.ts` (opencode) and `shunt.sh` (Claude), same thresholds - 350 lines /
  65536 bytes, tunable with `SHUNT_MIN_LINES` / `SHUNT_MAX_BYTES`. Divergences: exactly
  350 lines passes on the Claude side (`wc -l`), blocked on the opencode side (counts the
  trailing newline); `verb/foo.txt` with no trailing space is blocked opencode-side only.
  Claude flags subagent calls with a top-level `agent_id`. Test: `bash .claude/hooks/test-shunt.sh`.
- **Skills**: no opencode copy needed - it discovers `.claude/skills/*/SKILL.md` natively.
- **Telemetry**: every shunt decision (allow and deny) appends one JSONL line to
  `.usage/shunt.jsonl`. Schema: `ts` `harness` `session` `tool` `decision` `reason` `path`
  `bytes` `lines` `threshold_bytes` `threshold_lines`, plus `command` (bash) or
  `offset`/`limit` (read); records with no `decision` are legacy denies. One record per
  file arg. Best-effort: a write failure never blocks the redirect. Aggregate with
  `scripts/shunt-report.sh`. Never rotated - purge with `rm .usage/shunt.jsonl`.
- **Accepted divergences**: `hidden`/`temperature` opencode-only; `effort` Claude-only, so
  model tiers are set independently; detailed permissions opencode-only; `git push` ask is
  a permission rule (Claude) vs a `permission` field (opencode).

This repo runs its own kit in global mode.

## License

MIT - see `LICENSE`.
