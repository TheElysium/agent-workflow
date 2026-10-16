# agent-workflow repo rules

The shipped kit lives in `plugin/`; routing and phases are in `plugin/skills/dev-workflow/SKILL.md`.

## Release

- Every merge to `main` touching `plugin/` bumps `version` in `plugin/.claude-plugin/plugin.json` (semver). Installed copies only update on a new version.

## Writing rules

One rule = imperative + minimal example. No origin stories, no justifying narratives — the why lives in the retrospective, not here.
