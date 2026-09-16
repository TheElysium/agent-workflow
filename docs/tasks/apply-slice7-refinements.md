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

- Gates and commits on this host run in WSL; Git Bash lacks shellcheck/bun/gitleaks. First gate-keeper run without that constraint cost 571s for a RED.
- gate-keeper (Git Bash run) split the `test` chain and appended `| tail -50` despite the never-narrow rule.
- FLAG regex is noise-dominated: 22/27 flags are Read/Grep content or passing test summaries (`FAIL=0`, "shunt" in file text).

## Follow-ups

- Tests for `summ()` tool branches beyond Bash/Read, `-h`, unknown option.
- FLAG only on Bash/PowerShell results, or tighten regex (`FAIL=0` false positive).
- WSL constraint recorded where gate-keeper reads it (`.gates.yml` header).
