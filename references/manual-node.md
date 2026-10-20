# Manual nodes — running the protocol by hand

A **manual node** is a CommHub node that has no agent runtime behind it. It has no MCP
tool surface, so no model ever calls `get_inbox` or `report_status` for it. The node
still exists on the hub, still receives dispatched tasks, and still has to move through
the same lifecycle — a human (or a script acting for one) performs each transition
explicitly.

`scripts/anet_manual_node.sh` is that operator. It is a single self-contained file: copy
it to the machine that owns the node and run it there. It needs `node` (or `bun`) on
`PATH` and nothing else.

## When to use this

Use the script for a node whose `runtime` on the hub is `manual` — a node that exists to
receive work but has no agent process to consume it. A node with a real runtime
(`claude-agent-sdk`, `codex-sdk`, `opencode-cli`, …) is driven by its runtime and by the
MCP tools in [SKILL.md](../SKILL.md); do not drive it with this script.

## The four transitions that matter

The hub stores three independent facts. A manual node is "done" only when all three line
up.

| Hub fact | Where it lives | Moved by |
|---|---|---|
| task status `delivered → acked → running → replied` | `tasks.status` | `ack_inbox`, `report_status(working)`, `report_completion` |
| inbox row acked or not | `inbox.acked` | `ack_inbox` |
| session status / task preview | `sessions.status`, `sessions.task` | `report_status` |

A heartbeat alone moves **none** of them. `report_status(idle)` every 30 seconds keeps the
node visible and dispatchable, and nothing more.

### The full sequence

```bash
# 1. register (once): mint a node token, write the config, create the session row
./anet_manual_node.sh init --node my-manual-node --project-root /path/to/project

# 2. stay visible: the heartbeat re-reports the last state you set
./anet_manual_node.sh start --node my-manual-node --project-root /path/to/project

# 3. see what arrived
./anet_manual_node.sh inbox --node my-manual-node --project-root /path/to/project

# 4. take it: acks if needed, then reports working with the body fetched from the hub
./anet_manual_node.sh working <task_id> 10 --node my-manual-node --project-root /path/to/project

# 5. finish it
./anet_manual_node.sh reply <task_id> "done: 301 images generated, report committed as abc1234" \
  --node my-manual-node --project-root /path/to/project
```

`working` and `reply` both verify their own effect against the hub and fail loudly
rather than pretending: `working` re-reads the task and refuses to continue unless the hub
now says `running`; `reply` re-reads the task and prints the resulting status.

## Why the body is fetched, never retyped

`report_status(status="working", task=X)` only moves the task to `running` when
`to_name = <alias> AND content = X` matches **byte for byte**. A retyped or lightly
reformatted body matches nothing, the task stays `acked`, and the node looks busy while
the hub shows nothing running.

So `working` reads the stored body with `get_task` and sends that text back unchanged.
Never build the body yourself, never paste it from a chat window, never summarise it.
If you must change the body, the task has to be cancelled and re-dispatched.

## Diagnosing: "the node is online but the task never started"

This is the failure this node type produces most often, and it is invisible from the
session row: a healthy heartbeat plus `sessions.status = idle` looks exactly like a
node that is doing nothing while a task sits untouched.

```bash
./anet_manual_node.sh check --node my-manual-node --project-root /path/to/project
```

`check` reports the session row, the pending inbox count, every open task with its age,
and a verdict per task:

- **still `delivered`** — nobody acked it. The node is reachable; the work never began.
  The hub's own patrol logs `task.warning.delivered_stale_30s` / `_60s` for the same
  condition.
- **`acked` but not `running`** — the body was never reported verbatim. Re-run `working`.
- **`running`** — the work is genuinely in progress.

Read the verdict from the task rows, not from the session status. A session that says
`idle` while a task is `delivered` means the same thing as one that says `working`.

## Tokens

- `report_status` is a **node-only** tool: a user token is rejected with
  `network_token_required`. The manual node therefore needs its own node token, which
  `init` mints from your human session and writes to
  `<project-root>/.anet/nodes/<alias>/config.json` (mode 0600).
- The node token is bound to one alias. `report_status` refuses an alias that does not
  match the token's binding (`alias_identity_mismatch`) — so `--node` and the config's
  `alias` must be the same string.
- A revoked or expired node token fails with HTTP 401. Re-mint it with `init`; do not
  edit the config by hand.
- `anet node create` is not the way to create a manual node: its runtime whitelist has
  seven entries and `manual` is not one of them. `init` mints the token and registers
  the node with `report_status(agent="manual")`, which is what puts `runtime = manual`
  on the hub row.

## The two ways to close a task

| Command | Tool | Effect |
|---|---|---|
| `reply <id> "<text>"` (default) | `report_completion` | task → `replied`, session → `idle`, a row in `completions` |
| `reply <id> "<text>" --via send_reply` | `send_reply` | task → `replied`, a reply message lands in the sender's inbox |

Use the default unless the sender is waiting for an inbox message. `--via send_reply`
also needs the original task id in `in_reply_to` and the hub derives the target from it;
the script never passes an alias of its own.

`reply` also accepts `failed` or `cancelled` as the outcome, and uses `send_reply` for
those automatically, because `report_completion` can only record success.

## Reporting progress without closing

`state` sets the session state and the heartbeat keeps re-reporting it:

```bash
./anet_manual_node.sh state working 40 --node my-manual-node --project-root /path/to/project
./anet_manual_node.sh state blocked --node my-manual-node --project-root /path/to/project
```

`working` re-reports the task body it was given, so the session keeps the task attached
while you work. `blocked` / `error` / `waiting_input` / `offline` clear it — the hub then
shows the node as not working on anything, which is what you want when the work is
genuinely stuck. `idle` clears the task text as well.

## Chat that does not touch the task

`say <alias> "<text>"` sends a message and leaves the task open. Use it for questions
or status pings; never use it to close work, because it moves nothing on the task row.

## Where the state lives

Everything is per node, next to its config, so several manual nodes can share a project
directory without colliding:

```
<project-root>/.anet/nodes/<alias>/config.json          # node id, network, token, hub
<project-root>/.anet/nodes/<alias>/manual-status.json   # last state the heartbeat re-reports
<project-root>/.anet/nodes/<alias>/manual-heartbeat.pid
<project-root>/.anet/nodes/<alias>/manual-heartbeat.log
```

`config.json` holds a credential. Keep the directory at 0700 and out of version control
(the `anet` CLI writes the same `.anet/` layout and adds it to `.gitignore` for you).

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `network_token_required` on `report_status` | a user token is in the config | re-mint with `init` |
| `alias_identity_mismatch` | `--node` and the token's bound alias differ | use the config's alias |
| HTTP 401 | token revoked, expired, or from another hub | re-mint with `init` |
| task stays `acked` after `working` | the body did not match byte for byte | let the script fetch it; never retype it |
| `message not found or already acknowledged` | the inbox row is gone (already acked, or the task was retried) | `check` for the real task state |
| `reply_task_terminal` | someone else closed the task | `check` to see who |
| heartbeat log says `hub unreachable` | wrong `--hub`, or the hub is down | fix the address in the config |
| `node_owner_mismatch` on `init` | that alias belongs to another node id or owner | reuse the existing config, or pick another alias |
