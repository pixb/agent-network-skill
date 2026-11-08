# agent-network-skill

The unified skill for the CommHub MCP two-agent collaboration protocol. Planner (control room) and
worker (executor) share one set of rules instead of scattering separate notes across working
directories. It also ships the operating manual for **manual nodes** — nodes with no agent runtime
behind them, driven through the same protocol by hand.

**Project-independent**: mount it in any project and it works.

## Install

### As a git submodule (recommended for a project)

```bash
git submodule add git@github.com:pixb/agent-network-skill.git .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill .gitmodules
git commit -m "add agent-network-skill submodule"
```

SKILL.md sits at the repository root (there is no extra `skills/` container directory and no
symlink), so mounting it at `.agents/skills/<name>` is enough for project-level scanners in pi /
opencode and friends to find it. To update:

```bash
git submodule update --remote .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill && git commit -m "bump agent-network-skill"
```

### As a standalone skill (user-level)

```bash
git clone git@github.com:pixb/agent-network-skill.git
cd agent-network-skill && ./install.sh
```

Clone it into a directory named `agent-network-skill`: the Agent Skills spec requires the skill's
`name` to match its parent directory, and the spec validators reject a mismatch.

`install.sh` detects your platform and installs to its native path (Claude Code, Copilot, Cursor,
Codex, Gemini, Kiro, OpenCode, Goose, Cline, Roo, Kilo, Factory, Junie, Antigravity, and the
universal `~/.agents/skills/`). Use `--platform <name>`, `--project`, `--path <dir>`, `--all`, or
`--dry-run` to control it. Claude Code users can also add the repository as a plugin marketplace:

```
/plugin marketplace add git@github.com:pixb/agent-network-skill.git
/plugin install agent-network-skill
```

## Discovery paths

| Tool | Project-level discovery |
|---|---|
| pi | `.agents/skills/` (from cwd up to the repo root); `/skill:agent-network-skill` loads it manually |
| opencode | `.opencode/skill(s)/`, an ancestor `.agents/skills/`; surfaced as available_skills in the system prompt |

## Usage

- Planner: `/agent-network-skill split the work and dispatch it to <worker-alias>`
- Worker: `/skill:agent-network-skill`, then say "take a task"
- Manual node: `/agent-network-skill the manual node got a task but nothing started, check it`
- Short parameters: `/agent-network-skill the task body is too long, move it into a payload file`
- Prerequisites, token tiers and the CLI/MCP split are in [SKILL.md](SKILL.md) §0

Two rules shape every call (SKILL.md §1.1, §1.2): **one commhub call per round** (one script command
that performs a single transition may read the hub around it — that is still one round), and **short
parameters** — the long text lives in a payload file and the parameter carries only
`file:` + `seg:` + `sha12:`:

```bash
./scripts/anet_payload.sh compose --file commhub_tasks/r07/spec.md --seg seg-01 \
    --summary "第7轮 seg-01：给导出函数补单元测试，3 个用例全绿" --branch main   # planner
./scripts/anet_payload.sh verify  --file commhub_tasks/r07/spec.md --seg seg-01 \
    --sha12 3f7c64c57fb6 --print-body                                        # worker
./scripts/anet_payload.sh guard   --body "$TASK_BODY"                        # audit any body
./scripts/anet_manual_node.sh files <task_id>                                # manual node: what the task carries
./scripts/anet_manual_node.sh fetch <file_id> --out spec.md --sha12 <12 hex> # pull it through the hub
```

## Contents

| File | Purpose |
|---|---|
| [SKILL.md](SKILL.md) | The full protocol: connection and tokens, both role flows, state machine, parameter hard rules, the manual-node section, Gotchas |
| [references/manual-node.md](references/manual-node.md) | Manual nodes in depth: one node one slot, the four transitions, how a task can leave you, token rules, the online-vs-working diagnosis, failure modes |
| [references/payload-files.md](references/payload-files.md) | Short parameters in depth: the budgets, the `## seg-NN` segment format, the sha12, `compose` guards, the two handoff routes (git / hub attachment, with the 12 MiB · 20-file · 60-per-hour · 404-is-not-403 limits), failure modes |
| [references/token-operations.md](references/token-operations.md) | Token operations: what idle-expires, how to identify a token, revocation, environment contamination, the 401 |
| [scripts/anet_manual_node.sh](scripts/anet_manual_node.sh) | The manual-node operator: register, heartbeat, inbox, ack, working, reply, check, files, fetch |
| [scripts/anet_payload.sh](scripts/anet_payload.sh) | Short-parameter discipline made mechanical: `compose` a pointer body (`file:` + `seg:` + `sha12:`), `verify` it on the worker side, `guard` an existing body, `list` the segments |
| [scripts/run_evals.py](scripts/run_evals.py) | Eval runner — `python3 scripts/run_evals.py` |
| [evals/](evals/) | Eval spec and golden cases; they boot throwaway hubs and drive real tasks |
| [AGENTS.md](AGENTS.md) | Directory-level notes: purpose, triggers, contents, Gotchas |
| [discovery.json](discovery.json) | Decision contract and routing tests used for skill discovery |

## Verifying the skill

```bash
python3 scripts/run_evals.py --validate   # spec shape only
python3 scripts/run_evals.py               # run the behavioural checks
bash tests/manual_node_e2e.sh              # the same scenarios, narrated end to end
```

The scenarios need a commhub-server source tree to boot a throwaway hub from. Point
`ANET_E2E_HUB_SRC` at it (the `server/` directory, or the repo root containing it); when this skill
sits at `<repo>/.agents/skills/agent-network-skill` the tree is found relative to the skill
directory, so the golden inputs carry no paths. Nothing touches a real hub.

## Verification

[VERIFICATION.md](VERIFICATION.md) records the latest generation-time gate and eval evidence.
