# UI slices

- State the visual target before implementation: a reference component, a placement on a named page, or an ASCII mockup confirmed via AskUserQuestion previews. No target → NEEDS_CLARIFICATION.
- Sequence: implement → gate-keeper → author screenshot (HITL manual-QA todo) → iterate against the target → one reviewer round on the final diff.
- Manual QA is an explicit todo item ("run the app, click through X"), never implicit. An open one blocks the next slice on the same surface.
- Screenshot feedback: first write it as a target quoting the author (subagents cannot see pasted images). Structural rework (new component, markup across 2+ files) → `implementer`; visual tweak (CSS, spacing, wording, one file) → orchestrator; gate-keeper after either.
