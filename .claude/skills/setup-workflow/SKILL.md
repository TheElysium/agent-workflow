---
name: setup-workflow
description: Install the agent-workflow kit into a project (or into the global Claude Code config) - interviews the user for harness, stack and mode, then runs scripts/setup-workflow.sh and verifies the result. Use when the user asks to set up, install, deploy or wire the workflow kit into a repository, or invokes /setup-workflow.
---

The script does the work. This skill gathers its inputs and reports the result.

## 1 - Locate the kit

`<kit>/scripts/setup-workflow.sh`. First hit wins: the current repo; the path
`~/.claude/AGENTS.md` imports (`@<kit>/AGENTS.md`); else ask. Never guess.

## 2 - Interview

One AskUserQuestion call, every question with a recommended answer. Skip what the
user already stated.

| Question | Options | Recommended |
|---|---|---|
| Project or global? | `project` / `global` | `project` |
| Harness? | `claude` / `opencode` / `both` | `claude` |
| Stack, for the `.gates.yml` skeleton? | `shell` `node` `bun` `python` `rust` `other` | the detected one |

Detect the stack, do not ask blind: `Cargo.toml` -> rust, `package.json` -> node or
bun, `pyproject.toml` -> python, only `*.sh` -> shell.

Global mode is Claude Code only. Say so instead of letting `--harness opencode|both`
fail in the script.

## 3 - Dry run, then install

```
bash <kit>/scripts/setup-workflow.sh --mode project --target <dir> \
  --harness claude --stack rust --dry-run
```

Show the planned actions. A `SKIP` line means local drift: report it, pass `--force`
only if the user asks (it writes a `.bak` first). Then re-run without `--dry-run`.

## 4 - Verify

```
bash <kit>/scripts/setup-workflow.sh --verify --target <dir>
```

Exit 2 = at least one red check. Report every red verbatim; never reinstall hoping it clears.

## 5 - Report

Created/updated/skipped counts, the verify verdict, then what is left to the user:
fill the `.gates.yml` skeleton (unconfigured gates are hard reds on purpose), run
`bun install` in `.opencode/` for the opencode harness, and note that committed hooks
make every collaborator execute kit shell code on every Read and Bash.

Editing installed agents, skills or gates afterwards is normal work: route it through
`dev-workflow`.
