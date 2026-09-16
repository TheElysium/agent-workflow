# Token routing (shunt pattern)

The primary model is expensive. Delegate I/O-heavy work to cheap subagents instead of reading or writing large amounts of content yourself.

## When to delegate

- **bulk-reader** — whenever answering a question requires reading more than one large file (>350 lines or >64 KB, e.g. minified JSON, Grafana dashboard JSON, big config files), mapping a module's structure, or tracing call flows. Delegate with a targeted question; you only consume the summary. Never write Python/bash scripts to parse structured data.
- **code-writer** — test files, config scaffolding, type stubs, anything predictable from existing patterns. Give it a spec, a reference file to match style against, and a target path. It writes directly to disk.

## When NOT to delegate

- Targeted reads where you already know the exact section (offset/limit) — just read it.
- Editing existing code based on analysis — delegate for understanding, then make the targeted read and edit yourself.
- Debugging, architectural decisions, subtle bugs (concurrency, safety) — reasoning stays on the primary model.
- Small reads/writes where delegation round-trip overhead exceeds the savings.

# Task routing

Route every task to one of three levels, based on objective criteria — never on gut feeling:

- **T0 direct**: 1 file, low risk, no API surface touched (typo, comment, quick fix) — act directly, no delegation ceremony.
- **T1 lightweight**: 2–3 files, existing tests can serve as proof (small feature on an existing surface, targeted refactor) — invoke the `dev-workflow` skill.
- **T2 orchestrated**: architecture, auth, DB, public API surface, or security touched; or 3+ files with new behavior — invoke the `dev-workflow` skill.

Routing criteria: number of files touched, risk (security/auth/DB/data loss), API surface changed, architectural impact. When in doubt, route one level up.

For T1/T2 work, invoke the `dev-workflow` skill first — it carries the full multi-phase process (spec, plan, implement, verify gates, git, multi-agent rules, agent roster). Skip it for T0.

## Project init hygiene

- At the start of any new project (before the first commit), add to the project's `.gitignore`: `.claude/settings.local.json`, `.opencode/settings.local.json` — these are machine-local and must never be committed.

## Writing rules

One rule = imperative + minimal example. No origin stories, no justifying narratives — the why lives in the retrospective, not here.
