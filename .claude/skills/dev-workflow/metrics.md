# Subagent metrics

- One line in `docs/tasks/<slug>.md` per subagent completion: every subagent, every round, gate-keeper and re-review included. One write per update (one Edit or one Bash append).
- Format: `subagent | tokens | tool_uses | duration | retries | review_iterations | gate_failures | outcome`.
- Tokens come from the usage sink, never estimates: `pwsh -NoProfile -File scripts/usage-report.ps1 --since <task-start-ts>` aggregates `.usage/usage.jsonl`. Log before compaction erases them; the plan file is the only durable record.
- Lines aggregate into cost per successful task (tokens per mergeable change), not cost per agent.
- Every workflow report adds orchestrator cost (turns, output, cache reads, billed volume) and per-thread tool usage: `pwsh -NoProfile -File scripts/session-tools.ps1 <session.jsonl> --subagents <dir> --summary`.
