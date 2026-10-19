# agent-network-skill

The unified skill for the CommHub MCP two-agent collaboration protocol. Planner (control room) and
worker (executor) share one set of rules instead of scattering separate notes across working
directories. **Project-independent**: mount it in any project and it works.

## Install (git submodule)

From the project's working directory:

```bash
git submodule add git@github.com:pixb/agent-network-skill.git .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill .gitmodules
git commit -m "add agent-network-skill submodule"
```

SKILL.md sits at the repository root, so mounting it at `.agents/skills/<name>` is all that
discovery needs — no container directory and no symlink.

Update:

```bash
git submodule update --remote .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill && git commit -m "bump agent-network-skill"
```

## Discovery paths

| Tool | Project-level discovery |
|---|---|
| pi | `.agents/skills/` (from cwd up to the repo root); `/skill:agent-network-skill` loads it manually |
| opencode | `.opencode/skill(s)/`, an ancestor `.agents/skills/`; surfaced as available_skills in the system prompt |

## Usage

- Planner: `/agent-network-skill split the work and dispatch it to <worker-alias>`
- Worker: `/skill:agent-network-skill`, then say "take a task"
- Prerequisites, token tiers and the CLI/MCP split are in [SKILL.md](SKILL.md) §0

## Contents

| File | Purpose |
|---|---|
| [SKILL.md](SKILL.md) | The full protocol: connection and tokens, both role flows, state machine, parameter hard rules, cross-machine conventions, requirement pool, Gotchas |
| [AGENTS.md](AGENTS.md) | Directory-level notes (which agents should read it, trigger conditions) |
| [discovery.json](discovery.json) | Skill discovery metadata (triggers, evidence, routing tests) |
