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
- One commhub call per round, short task/message parameters, the long text in a payload file
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
| [references/payload-files.md](references/payload-files.md) | Short parameters in depth: budgets, `## seg-NN` segment format, the sha12, `compose` guards, handoff routes (git / hub attachment, with its measured limits), failure modes |
| [references/token-operations.md](references/token-operations.md) | Token operations: what expires, how to identify a token, revocation, the 401 |
| [scripts/anet_manual_node.sh](scripts/anet_manual_node.sh) | Run this on the manual node's machine: register, heartbeat, inbox, ack, working, reply, check, files, fetch |
| [scripts/anet_payload.sh](scripts/anet_payload.sh) | Compose a short pointer body (`file:` + `sha12:`, one task per file; `seg:` for a segment pointer) and prove it: `compose`, `verify`, `guard`, `list`, `upload` (bytes through the hub) |
| [scripts/run_evals.py](scripts/run_evals.py) | The eval runner: `python3 scripts/run_evals.py` gates the skill's behaviour |
| [evals/](evals/) | The eval spec and its golden cases (real hubs, real tasks) |
| [tests/](tests/) | The same scenarios run end to end, narrated |

## Gotchas

- **One commhub call per round.** A turn that fires `get_inbox` + `ack` + `working`, or three
  `send_task`s at once, is not "efficient": it overwrites the node's single session slot, it burns
  the dedupe window, and it leaves you with three responses and no idea which transition the hub
  took. Read one response, then act (§1.1). A script command that performs **one transition** is one
  round even when it reads the hub before and after it (`anet_manual_node.sh working` fetches the
  stored body so the echo is byte-exact, then proves the task reached `running`) — the rule counts
  transitions, not shell characters.
- **A long task is a pointer, never a paste.** The body is ≤300 characters; the spec lives in a
  payload file, **one file per task** (a worker reads the file it is pointed at — a file holding six
  tasks makes it pay for six), and the parameter names `file:` + `sha12:`; add `seg:` only when the
  task really is one section of a document you must not split. Build it
  with `scripts/anet_payload.sh compose`, verify it on the worker side with `verify`, audit an
  existing body with `guard` (§1.2). The budgets are counted in characters by python, never bytes by
  the shell — a C locale must not silently triple a CJK body.
- **The budgets are discipline, not limits.** The hub accepts 10 000 characters for `task`, stores the
  first 4000 of `result`, accepts 10 000 for `send_reply`; the protocol spends 300 / 1200 / 1500, with
  line 1 ≤80. A longer dispatch body buys no display (a node card shows a blind 200-character slice)
  and makes the byte-exact echo in `report_status(working)` more likely to drift.
- **A brief body is allowed, and it is formatted, not pasted.** A read-only or one-shot task that fits in
  ≤1200 characters goes in the body with an `accept:` block, `- ` bullets and blank-line blocks
  (`guard --kind brief`). Long specs stay in a payload file behind a pointer. Measured on a live hub:
  117 / 277 / 484-character bodies all reached `running` and `replied` (the node echoes the stored body,
  so the byte-exact `working` match survives length); the cost of length is the 200-character preview and
  the worker's context.
  A **resend body** (it quotes an expired `task_id`) is budgeted at 340 — quoting a hub task id costs
  36 characters — and must carry an `accept:` line, because that body is what acceptance quotes.
- **Write for the surface that renders plain text.** The node's task pane renders markdown; the node
  card, node list rows, the Tasks detail and the Messages page do not. Use line 1 as a self-sufficient
  summary, blank lines between blocks, `- ` bullets, `key: value` fields; never tables, `#` headings,
  `**bold**` or backticks — there they appear as their own characters. `guard --kind result` refuses
  markup and enforces the 1200-character delivery budget.
- **A big file goes through the hub, not across disks.** `bash scripts/anet_payload.sh upload
  --file <relpath> --hub <url> --network <id>` → `file_id` + sha12 + the pointer line, and the same
  command's `meta.attachments` entry to dispatch with. Measured limits that bite: 12 MiB per file
  (refused by the script before the wire), 20 attachments per task, 60 uploads per hour per caller,
  `type` must be `"file"` (a malformed entry is refused with `bad_attachments`, never dropped),
  download rights are network-scoped and a denied read answers **404 not 403**. A manual node pulls
  them with `files` + `fetch --sha12` (§7). The access string is read from `ANET_TOKEN` in the
  environment and is never an option value: argv is readable in `ps` and in shell history.
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
- **`dm` is readable in the Dashboard — `report_completion` is the invisible one.** `dm` writes
  `user_inbox`, and `/messages/inbox` reads it (`?scope=user`, measured as `case-9`). A deliverable a
  person must read goes through a task with `reply --via send_reply` →
  `inbox(session_name=<dispatcher username>)`, which the Messages page reads. That reply is terminal:
  `replied` is not retryable (`retry_task` accepts `failed` / `expired` / `cancelled`), so mid-task
  questions use `state blocked` + `dm` and keep the task open. `report_completion` is the channel with
  no message row at all — the Tasks page is the only place it shows.
- **Deleting a node locally does not delete it on the hub.** `anet node delete` removes the local
  directory first; if the hub half fails you keep a `nodes` row plus an `offline` `sessions` row, and
  the alias stays taken. Clean it with `anet node delete <node_id> --hub-only`.
- **A task can be taken away under you.** Another node cannot `ack_inbox` your row, but the planner
  can `reassign_task` it away and *anybody* can `send_ack` it (which updates the task by id without
  checking ownership). `check` names both cases; `ack`/`working` refuse a task somebody else claimed.
