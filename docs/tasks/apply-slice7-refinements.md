# Apply slice-7 refinements

Status: archived 2026-09-16. Commits: A e3e9a17, B 76ed44e, C 411ffa2 (branch `chore/apply-slice7-refinements`, not pushed). Source: opencycling `docs/tasks/slice-7-workflow-report.md` §6.

## Outcome

- A — dev-workflow SKILL.md + agents: visual target, UI design checkpoint before review, design-iteration routing by size, re-gate after review fixes, gate-keeper never-narrow, reviewer no gate re-runs, delta-scoped re-review, orchestrator Edit/Write only, batched log writes, no blocking TaskOutput, report sections (orchestrator cost, per-thread tool usage).
- B — shunt (sh + ts): Read passes only with offset AND limit; bounded single reads (`sed -n 'A,Bp'`, `head -n/-c N`, `tail -n N`) pass before the size check; `$`-ranges, `tail -n +N`, plain head/tail denied; compound exemption + uncovered verbs (python/jq/git show) documented as contract.
- C — `scripts/session-tools.sh <session.jsonl> [--thread] [--cut] [--subagents dir] [--summary]`: TSV log per tool call with ERROR/FLAG, per-thread tool counts + token totals; gated in `.gates.yml`.

## Decisions

- `--cut` filters assistant records (calls + usage) at ingestion, second precision; user records kept so tool_results resolve.
- `jq -b` everywhere (native Windows jq emits CRLF).
- Subagent thread label = `agentType` from `agent-*.meta.json`, else file stem.
- Fixtures synthetic: the spec's source subagent transcript no longer existed; smoke-run on the real 3.5 MB opencycling transcript instead.

## Report (batch C session only — A/B sessions unlogged)

Subagents:

- reviewer | 46576 | 8 | 205s | 0 | 1 | 0 | APPROVE (minor/nits deferred)
- gate-keeper (Git Bash) | 21451 | 22 | 571s | 0 | 0 | 1 | RED — env, tools absent
- gate-keeper (WSL) | 13576 | 5 | 85s | 0 | 0 | 0 | GREEN

Orchestrator cost (`session-tools.sh --summary`): 60 turns, 49.8k output, 3.28M cache reads, 3.48M billed volume.

Per-thread tool usage:

| thread | calls | errors | flags | tools |
|---|---|---|---|---|
| main | 28 | 0 | 10 | Bash 15, Edit 5, Read 3, Agent 3, Write 1, Skill 1 |
| gate-keeper (×2) | 27 | 4 | 11 | Bash 22, Read 3 |
| reviewer | 8 | 0 | 6 | Read 4, Grep 2, Bash 1 |

Blocks: 1 pre-commit (Git Bash lacks shellcheck/gitleaks) → re-committed from WSL, no bypass.

## Lessons

- Gate tool prerequisites were undocumented; Git Bash lacked shellcheck/bun/gitleaks. First gate-keeper run cost 571s for a RED — now listed in `.gates.yml` header.
- gate-keeper (Git Bash run) ran lint/test verbatim first, then spent ~2 min on `find /c` for shellcheck and re-ran the `test` chain per component with `| tail -50` (sast with `| head -50`). Verdict stayed RED, but pipes break the never-narrow letter and cost ~5 min.
- FLAG regex is noise-dominated: 22/27 flags are Read/Grep content or passing test summaries (`FAIL=0`, "shunt" in file text).

## Post-closure

- 8f76a64 — FLAG limited to Bash/PowerShell + regex ignores `FAIL=0` / `0 failed` / bare `shunt` (27 → 11 flags on the batch C session); gate-keeper.md run-once rule (exit 127 → FAIL at once, no per-component re-runs).
- Follow-ups closed: `summ()` per-tool tests, `-h`, unknown option, multi-line `0 failed`; `.opencode/agent/gate-keeper.md` synced (never-narrow, run-once); `FAIL (tool missing)` label. Test 18 caught a crash: AskUserQuestion without `questions` aborted the whole log (rc 5) → guarded.

Subagents:

- gate-keeper (WSL, FLAG fix) | 13894 | 5 | 90s | 0 | 0 | 0 | GREEN
- reviewer (FLAG fix) | 43694 | 9 | 189s | 0 | 1 | 0 | APPROVE (minor/nits deferred)
- gate-keeper (WSL, follow-ups) | 13440 | 5 | 80s | 0 | 0 | 0 | GREEN
- reviewer (follow-ups) | 34673 | 7 | 104s | 0 | 1 | 0 | APPROVE (minor: test 19 reuses test 4 fixture, as test 16 does)
- gate-keeper (md trim) | 13791 | 5 | 82s | 0 | 0 | 0 | GREEN
- reviewer (md trim) | 32329 | 8 | 97s | 0 | 1 | 0 | REQUEST_CHANGES (shunt rule dropped)
- gate-keeper (md trim fix) | 13842 | 5 | 81s | 0 | 0 | 0 | GREEN
- reviewer (md trim, delta) | 17789 | 3 | 18s | 0 | 2 | 0 | APPROVE

Token trim: agents + SKILL.md −1.9 KB vs 6714f2d (justifications, triple "review fixes TDD" rule).
