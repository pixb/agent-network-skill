# agent-network-skill

The unified protocol skill for the "dispatch → work → report → verify" loop over CommHub MCP, shared
by the planner (control room) and the worker (executor) in any project that mounts this skill.

## Purpose

One protocol, two roles: any agent that reads this directory knows which MCP tools it should call in
the loop, in what order, and which parameter constraints are hard limits.

## Triggers

- Dispatch a task / take a task / verify work / check inbox
- `alias_not_found`, a task stuck in acked or running, status unchanged after `report_completion`
- Cross-machine collaboration, dual-directory task split (two clones)

## Contents

The complete prerequisites, token tiers, role flows, state machine, parameter hard rules and
Gotchas are in [SKILL.md](SKILL.md). Installation and discovery are in [README.md](README.md).
