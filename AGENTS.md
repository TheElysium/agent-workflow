# agent-workflow repo rules

The shipped plugins live in `plugins/`; routing and phases are in `plugins/agent-workflow/skills/dev-workflow/SKILL.md`.

## Release

- Every merge to `main` touching a plugin bumps `version` in that plugin's `.claude-plugin/plugin.json` (semver). Installed copies only update on a new version.

## Writing rules

One rule = imperative + minimal example. No origin stories, no justifying narratives — the why lives in the retrospective, not here.
