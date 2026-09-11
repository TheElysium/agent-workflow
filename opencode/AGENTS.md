# Token routing (shunt pattern)

The primary model is expensive. Delegate I/O-heavy work to cheap subagents instead of reading or writing large amounts of content yourself.

## When to delegate

- **@bulk-reader** — whenever answering a question requires reading more than one large file (>350 lines or >64 KB, e.g. minified JSON), mapping a module's structure, or tracing call flows. Delegate instead of reading the files yourself; you only consume the summary.
- **@bulk-reader for structured data** — Grafana dashboard JSON, exports, big config files: do NOT write Python/bash scripts to parse them, and do NOT read them yourself. Delegate to @bulk-reader with a targeted question ("list all panel queries, datasources and variables in these dashboards") — the worker parses the JSON and returns structured bullets.
- **@code-writer** — for test files, config scaffolding, type stubs, and anything predictable from existing patterns. Give it a spec, a reference file to match style against, and a target path. It writes directly to disk; you never see the generated code.

## When NOT to delegate

- Targeted reads where you already know the exact section (offset/limit) — just read it.
- Editing existing code based on analysis — delegate for understanding, then make the targeted read and edit yourself.
- Debugging, architectural decisions, subtle bugs (concurrency, safety) — reasoning stays on the primary model.
- Small reads/writes where delegation round-trip overhead exceeds the savings.

# Development workflow

Multi-phase workflow applied to every project. The `build` agent is the default orchestrator: use it interactively as usual for small tasks, and orchestrate through subagents when a task is substantial enough to benefit (parallelizable work, peer review, heavy I/O). Never add ceremony for micro-tasks.

## Phase 1 — Understand & Spec

- Locate the spec: user message, `docs/`, `*.md` files, or issues.
- Extract: requirements, acceptance criteria, edge cases, explicit out-of-scope.
- Restate the spec in the plan before writing any code.
- If the spec is ambiguous, incomplete, or missing → ask the user. Never guess requirements.
- Delegate heavy codebase exploration to `@explore` / `@bulk-reader`; do not read large files yourself.

## Phase 2 — Plan

- Any task with 3+ steps → todo list (todowrite), kept up to date in real time.
- Decompose into delegatable, parallelizable units.
- For non-trivial or architectural changes, propose the approach and get agreement before coding.

## Phase 3 — Implement

- TDD is mandatory: red-green-refactor. Write the failing test first, minimal implementation, then refactor. No production code without a test that demands it.
- Lint: follow the project's configured linter. If none is configured, apply a strict default for the stack (e.g. `clippy -D warnings`, `ruff --strict`, `eslint` strict) and tell the user.
- Cyclomatic complexity: target ≤ 10 per function (lizard, radon, gocyclo, clippy cognitive complexity). Above the threshold → refactor or explicitly justify.
- Apply the stack's formatter.
- Run SAST tooling when available (cargo clippy/audit, npm audit, semgrep, gitleaks, gosec...). If the tool is not installed, propose installing it — never skip silently.

## Phase 4 — Verify (mandatory gate)

- Gate: lint + typecheck + build + tests + SAST must pass before a task is done.
- Discover commands from the repo (package.json, Cargo.toml, Makefile, CI configs). Never invent them; ask the user if unknown.
- A task with a failing gate is never "done".

## Phase 5 — Git

- One branch per task: `feat/<scope>`, `fix/<scope>`, `chore/<scope>`.
- Conventional Commits (feat, fix, chore, docs, refactor, test) — short, present tense.
- Committing without asking is allowed (on the task branch).
- Push only when the user explicitly asks for it (a permission prompt will confirm). No force-push, no hook bypass, no secrets in commits.

## Multi-agent rules

- Subagents start with a fresh context: every delegation prompt must be self-contained (extracted spec, exact task, `file:line` anchors, stack conventions, acceptance criteria). Never rely on session context.
- Subagent outputs: structured bullets only, no file dumps.
- Launch independent Task calls in the same message to parallelize.
- Keep agent system prompts stable (favors prompt caching).

### Agent roster

- `@implementer` — writes code in strict TDD for a given task. Use for substantial coding work, in parallel when tasks are independent.
- `@gate-keeper` — runs verification commands only (lint/typecheck/build/tests/SAST), reports structured pass/fail. Use after implementation.
- `@reviewer` — read-only peer review of the diff (correctness, security, complexity, style, TDD compliance). Commit only after APPROVE + green gates.
- `@explore`, `@bulk-reader` — phase 1 exploration.
- `@code-writer` — test scaffolding and repetitive code matching existing patterns.

Flow for a substantial task: spec → decompose → explore (parallel) → implementer (TDD, parallel) → gate-keeper → reviewer → commit (no push) → next todo.

## Per-project overrides

To adapt an agent to a stack (e.g. Rust for a Tauri project), place a same-ID file in the repo (`.opencode/agent/<id>.md`). The global definition is the base; the project file only adds stack specifics (definitions merge: scalar fields replaced, permission rules appended).
