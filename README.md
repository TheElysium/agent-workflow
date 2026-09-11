# agent-workflow

Configuration versionnée du workflow de développement multi-agent pour **opencode** et **Claude Code**.

## Structure

```
opencode/                    → ~/.config/opencode/
├── AGENTS.md                Règles globales : workflow 5 phases + shunt pattern + règles multi-agent
├── opencode.jsonc           Config : modèle principal, plugin télémétrie
├── package.json             Déps plugins (npm install dans ~/.config/opencode)
├── agent/                   Agents (fork de build = orchestrator, implementer, reviewer,
│                            gate-keeper, explore, bulk-reader, code-writer)
└── plugins/shunt.ts         Plugin shunt

claude/                      → /mnt/c/Users/lukas/.claude/
├── CLAUDE.md                Règles globales (miroir d'AGENTS.md, orchestration dans le main loop)
├── settings.json            Permission ask sur git push, plugins activés
└── agents/                  implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer

sync.sh                      deploy (repo → live) / --pull (live → repo)
```

## Workflow (résumé)

spec → décomposition → explore/bulk-reader (parallèle) → implementer (TDD) → gate-keeper (lint/typecheck/build/tests/SAST) → reviewer (peer review) → commit → push seulement à la demande explicite.

Détails : voir `opencode/AGENTS.md` (source de vérité).

## Usage du sync

```bash
./sync.sh          # appliquer le repo vers les configs live
./sync.sh --pull   # récolter les éditions faites à chaud côté live (puis commit)
```

Règle de travail : éditer **dans le repo**, déployer, committer. Ne jamais éditer en direct sans faire un `--pull` ensuite.

## Setup frais (nouvelle machine)

1. Déployer : `./sync.sh`
2. Deps opencode : `cd ~/.config/opencode && npm install`
3. Telemetry CLI : installer bun (`~/.local/bin/bun`) + wrapper `~/.local/bin/octm` pointant sur `~/.config/opencode/node_modules/opencode-telemetry/bin/cli.js`
4. Patch pricing : ajouter `opencode/mimo-v2.5-free` (et variantes) à `node_modules/opencode-telemetry/src/pricing.json` (gratuit = 0) — patch éphémère, à refaire après `npm update`
5. Les agents/opencode.jsonc se rechargent à la prochaine session ; Claude Code relit `CLAUDE.md`/`settings.json` au lancement

## Notes de sync entre outils

- `opencode/AGENTS.md` et `claude/CLAUDE.md` sont des copies maintenus en parallèle (pas de symlink WSL↔NTFS fiable). Toute édition de l'un doit être portée dans l'autre.
- Divergences assumées : agents `hidden`/`temperature` opencode only ; permissions détaillées (Task, bash patterns) opencode only ; hook ask `git push` = permission rule côté Claude Code, champ `permission` côté opencode.
- `claude/settings.json` est versionné sans secrets (les credentials sont dans `.credentials.json`, jamais commité).
