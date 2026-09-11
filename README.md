# agent-workflow

Configuration versionnée du workflow de développement multi-agent pour **opencode** et **Claude Code**.

## Structure

```
opencode/                    ← ~/.config/opencode/ (symlinks WSL)
├── AGENTS.md                Règles globales : workflow 5 phases + shunt pattern + règles multi-agent
├── opencode.jsonc           Config : modèle principal, plugin télémétrie
├── package.json(+lock)      Déps plugins (npm install dans ~/.config/opencode)
├── agent/                   Agents (fork de build = orchestrator, implementer, reviewer,
│                            gate-keeper, explore, bulk-reader, code-writer)
└── plugins/shunt.ts         Plugin shunt

claude/                      ← /mnt/c/Users/lukas/.claude/ (junction + hardlinks NTFS)
├── CLAUDE.md                Règles globales (miroir d'AGENTS.md, orchestration dans le main loop)
├── settings.json            Permission ask sur git push, plugins activés
└── agents/                  implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer

setup.sh                     crée/répare les liens (une fois par machine)
```

## Pas de sync : les configs live pointent dans le repo

- **opencode** : `~/.config/opencode/{AGENTS.md,opencode.jsonc,package*.json,agent,plugins}` sont des symlinks WSL vers ce repo.
- **Claude Code** : `.claude/CLAUDE.md` et `.claude/settings.json` sont des **hardlinks** NTFS, `.claude/agents` une **junction** — visibles côté Windows et WSL.

Conséquence : **le repo EST la config live**. Éditez ici, l'outil le voit immédiatement (au prochain lancement de session pour les agents).

```bash
./setup.sh --check    # vérifier que tous les liens résolvent
./setup.sh --repair   # recréer les liens claude si un outil a réécrit un fichier hardlinké
```

Caveat connu : un outil qui réécrit un fichier hardlinké via un save temporaire+rename casse le lien (le fichier devient une copie autonome). Si `--check` est vert mais qu'un edit ne se propage pas, comparer avec `git diff`, puis `./setup.sh --repair`.

## Workflow (résumé)

spec → décomposition → explore/bulk-reader (parallèle) → implementer (TDD) → gate-keeper (lint/typecheck/build/tests/SAST) → reviewer (peer review) → commit → push seulement à la demande explicite.

Détails : voir `opencode/AGENTS.md` (source de vérité).

## Setup frais (nouvelle machine)

1. `./setup.sh` (crée les liens)
2. Deps opencode : `cd ~/.config/opencode && npm install` (node_modules n'est pas versionné)
3. Telemetry CLI : installer bun (`~/.local/bin/bun`) + wrapper `~/.local/bin/octm` pointant sur `~/.config/opencode/node_modules/opencode-telemetry/bin/cli.js`
4. Patch pricing : ajouter `opencode/mimo-v2.5-free` (et variantes) à `node_modules/opencode-telemetry/src/pricing.json` (gratuit = 0) — patch éphémère, à refaire après `npm update`
5. Les agents/opencode.jsonc se rechargent à la prochaine session ; Claude Code relit `CLAUDE.md`/`settings.json` au lancement

## Notes de synchronisation entre outils

- `opencode/AGENTS.md` et `claude/CLAUDE.md` sont des copies maintenus en parallèle. Toute édition de l'un doit être portée dans l'autre (le repo les rend visibles côte à côte).
- Divergences assumées : agents `hidden`/`temperature` opencode only ; permissions détaillées (Task, bash patterns) opencode only ; ask `git push` = permission rule côté Claude Code, champ `permission` côté opencode.
- `claude/settings.json` est versionné sans secrets (les credentials sont dans `.credentials.json`, jamais commité).
