# agent-network-skill

The unified protocol skill for the "dispatch → work → report → verify" loop over CommHub MCP, shared
by the planner (control room) and the worker (executor) in any project that mounts this skill.

## Purpose

One protocol, two roles: any agent that reads this directory knows which MCP tools it should call in
the loop, in what order, and which parameter constraints are hard limits. It also covers the case the
protocol was designed around but the tool surface cannot reach: a **manual node** — a node with no
agent runtime behind it — driven by hand through the same lifecycle.

## Triggers

- Dispatch a task / take a task / verify work / check inbox
- `alias_not_found`, a task stuck in acked or running, status unchanged after `report_completion`
- Cross-machine collaboration, dual-directory task split (two clones)
- A manual node (hub `runtime = manual`) received a task and someone must consume it by hand
- A dispatched task sits in `delivered` and nobody seems to have picked it up
- 私信 / DM 看不见：节点发了 `dm`，manager 在 Dashboard 上找不到；`report_completion` 已上报，Messages 页没有
- 节点名混乱：dashboard 上出现登录用户名、`alias_not_found` 指向一个"人人"、hub 上留着已删节点的行

## Contents

The complete prerequisites, token tiers, role flows, state machine, parameter hard rules and
Gotchas are in [SKILL.md](SKILL.md). The manual-node operating manual is in
[references/manual-node.md](references/manual-node.md). Installation and discovery are in
[README.md](README.md).

| File | What it is |
|---|---|
| [SKILL.md](SKILL.md) | The protocol: tokens, both role flows, the state machine, the manual-node section, Gotchas |
| [references/manual-node.md](references/manual-node.md) | Manual nodes in depth: the four transitions, token rules, diagnosis, failure modes |
| [scripts/anet_manual_node.sh](scripts/anet_manual_node.sh) | Run this on the manual node's machine: register, heartbeat, ack, working, reply, check |
| [scripts/run_evals.py](scripts/run_evals.py) | The eval runner: `python3 scripts/run_evals.py` gates the skill's behaviour |
| [evals/](evals/) | The eval spec and its golden cases (real hubs, real tasks) |
| [tests/](tests/) | The same scenarios run end to end, narrated |

## Gotchas

- **Online is not working.** A manual node with a healthy heartbeat and `sessions.status = idle`
  looks exactly like a node doing nothing while its task sits untouched. Read the task row, never the
  session row.
- **A task stuck in `delivered` usually means nobody acked it**, not that the node is offline. The
  hub's `delivered_stale_30s` / `_60s` patrol warnings say the same thing.
- **A node has ONE task slot, not one per task.** `sessions` is unique on `(network_id, alias)` and
  holds a single `status` and a single 200-char task preview, so a second `report_status` overwrites
  the first task's text. Real runtimes queue the rest FIFO for the same reason. Take one task, finish
  it, then take the next.
- **The task body must be byte-identical.** `report_status(status="working", task=…)` matches on
  exact equality, so the body is fetched from the hub, never retyped or summarised.
- **`report_status` is node-only.** A user token gets `network_token_required`; a manual node needs
  its own `ntok_`, which is why `anet node create` is not how you make one.
- **An alias is bound to one node id.** Re-minting a token for the same alias with a different node
  id is refused with `node_owner_mismatch`; reuse the id the hub already knows.
- **The hub address and the network id travel together.** A `network_id` from a different hub's
  config means nothing here — the script only falls back to the global config when the hubs match.
- **The manager is a user, and needs no node.** Dispatch runs on a user token, so `from_name` is the
  dispatcher's username; `report_status` refuses user tokens, so there is nothing for a control room
  to run, and a user has no `sessions` row to be dispatched to. One manager drives many projects:
  **the project boundary is the network** (alias uniqueness is network-scoped), node aliases carry
  machine + project, and every REST read needs `?network_id=`.
- **`dm` is invisible in the Dashboard.** It writes `user_inbox`, and the Dashboard has no page for
  it (`/dm` does not exist). The deliverable that a person must see goes through a task with
  `reply --via send_reply` → `inbox(session_name=<dispatcher username>)`. A reply is terminal:
  `replied` is not retryable, so mid-task questions use `state blocked` + `dm` and keep the task open.
- **Deleting a node locally does not delete it on the hub.** `anet node delete` removes the local
  directory first; if the hub half fails you keep a `nodes` row plus an `offline` `sessions` row, and
  the alias stays taken. Clean it with `anet node delete <node_id> --hub-only`.
- **A task can be taken away under you.** Another node cannot `ack_inbox` your row, but the planner
  can `reassign_task` it away and *anybody* can `send_ack` it (which updates the task by id without
  checking ownership). `check` names both cases; `ack`/`working` refuse a task somebody else claimed.
