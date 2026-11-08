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

## One node, one task slot

A node gets **one** slot, not one per task. This is not a convention the skill
imposes — it is what the hub stores:

- `sessions` has a unique index on `(network_id, alias)` (`server/src/db.ts`,
  `idx_sessions_network_alias_unique`), and every `report_status` deletes any
  other session row for the same alias. So one node = one session row.
- That row carries a single `status` and a single `task` preview (the first 200
  characters). **A second `report_status` overwrites the first task's text.**
- Real runtimes behave the same way: the codex bridge FIFO-queues ordinary
  network tasks and runs one turn at a time.

So **a manual node works one task at a time**, and the rest wait their turn. If
you take a second task while one is running, the first disappears from the
session view — it still exists in the task table, but nothing on the node's
status row points at it any more. The script refuses this:

```bash
./anet_manual_node.sh working <second_task_id>   # refused
# this node already holds task <first_task_id> (hub status: running) — one node
# runs one task at a time, because the hub gives a node a single session slot.
# Finish it first: reply <first_task_id>
```

Finish the first task (`reply`) and the slot frees up. `check` shows both
halves separately, because they are different things:

```
slot (one per node — the hub keeps a single task preview here):
  holds     : <task_id>
  hub text  : task one — the node is working on this

queue (2 open task(s), 1 inbox row(s)):
- <task_id_a> status=running  IN THE SLOT
- <task_id_b> status=delivered  waiting for the slot
```

## How a task can leave you

Three things can take a task away from a manual node, and they look different
from the inside. This matters because "the previous task was taken by somebody
else" is otherwise invisible.

| What happened | What you see | What to do |
|---|---|---|
| Another node `ack_inbox`ed it | **Impossible.** A node token can only ack its own inbox rows (`server/src/inbox-caller.ts` binds the alias to the token) | — |
| The planner `reassign_task`ed it to somebody else | The task leaves your inbox and is gone from your queue, with no explanation | `check` names it under **left behind**; run `show <id>` to see who holds it now |
| Somebody called `send_ack` on it | The task is still in your inbox but its status is `acked` — somebody claimed it under you | `check` flags it **ACKED BY SOMEONE ELSE**; `ack`/`working` refuse it |

The `send_ack` case is the sharp one. `send_ack` updates a task row by id
**without checking who owns the task**, so any node in the network can ack a
task that is sitting in your inbox. The symptom is a task that reads as "acked
but not running", which looks exactly like "the body did not match".

The script tells the two apart, using a fact the hub guarantees: **your own
`ack` removes the row from your inbox** (`inbox.acked = 1`). So a task that is
`acked` *and still sitting in your inbox* was acked by somebody else:

```
verdict: task <id> is acked but you never acked it and it is still in your
inbox — another party claimed it: do NOT start it, ask the planner who owns it now
```

and both `ack` and `working` refuse it. Without that check the node would
happily start work somebody else had already claimed — two nodes, one task.

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

### The step that cannot be skipped: `working`

**An automatic node's runtime reports `working` on its own** — agent-node sends
`report_status("working")` when a turn starts and keeps re-sending it on the heartbeat
(`agent-node/src/cli.ts`). **A manual node has no runtime, so nothing sends it for you.**

This is the whole difference between the two node types, and it is easy to miss because
**the hub will not tell you that you skipped it**: `report_completion` matches
`status IN ('delivered', 'acked', 'running')`, so a task can go `delivered → replied` in one
step. The reply lands, the result is stored, nothing errors — and the run was invisible.

| what the planner sees | with `working` | without it |
|---|---|---|
| task row | `running`, `started_at` set | `delivered` for the whole run |
| session row | `working` + the task text | `idle` + empty text |
| hub patrol | quiet | `task.warning.delivered_stale_30s` / `_60s` the whole time |
| queue depth | honest | the node looks free to dispatch to |

The `working` command is also the only thing that writes `tasks.started_at`, and the only
thing that makes the session row show *what* you are working on. Run it **before** you begin,
not after:

```bash
./anet_manual_node.sh working <task_id> 0 --node my-manual-node --project-root /path/to/project
```

`working` acks the task if it is still `delivered`, fetches the body from the hub, reports
it, and then re-reads the task to confirm the hub really says `running` — if it does not, it
fails loudly instead of leaving you busy-but-invisible.

`reply` warns when it finds the task still `delivered` or `acked`, because that means
`working` was skipped. It does not block: the work really is finished, and refusing to close
a finished task would strand it. The warning is the only signal that the run was invisible.

### The full sequence

```bash
# 1. register (once): mint a node token, write the config, create the session row
./anet_manual_node.sh init --node my-manual-node --project-root /path/to/project

# 2. stay visible: the heartbeat re-reports the last state you set
./anet_manual_node.sh start --node my-manual-node --project-root /path/to/project

# 3. see what arrived
./anet_manual_node.sh inbox --node my-manual-node --project-root /path/to/project

# 4. take it: acks if needed, then reports working with the body fetched from the hub
#    (do this BEFORE the work — it is the only "I started" signal you get)
./anet_manual_node.sh working <task_id> 10 --node my-manual-node --project-root /path/to/project

# 5. finish it
./anet_manual_node.sh reply <task_id> "done: 3 unit tests green, report committed as abc1234" \
  --node my-manual-node --project-root /path/to/project
```

If the dispatch carried attachments, insert between 3 and 4:

```bash
# 3a. what does this task carry?
./anet_manual_node.sh files <task_id> --node my-manual-node --project-root /path/to/project

# 3b. pull the bytes through the hub and prove the revision (exit 3 = conflict)
./anet_manual_node.sh fetch <file_id> --out spec.md --sha12 <12 hex> \
  --node my-manual-node --project-root /path/to/project
```

`working` and `reply` both verify their own effect against the hub and fail loudly
rather than pretending: `working` re-reads the task and refuses to continue unless the hub
now says `running`; `reply` re-reads the task and prints the resulting status.

## Attachments: the hub carries the bytes, the node pulls them

A runtime node downloads attachments by itself (`agent-node/src/runtime/fetch-attachment.ts`).
A manual node has no runtime, so `files` and `fetch` are that step, done by hand:

```bash
./anet_manual_node.sh files <task_id>              # names them: file_id, name, mime, size
./anet_manual_node.sh fetch <file_id> --out spec.md --sha12 54b3cd5aa536
```

What the hub enforces (measured, `server/src/uploads.ts` + `server/src/server.ts`):

- `meta.attachments[]` (MCP `send_task`) or top-level `attachments` (REST `/api/task`): `type` must
  be `"file"`, `file_id` is server-generated, **max 20 per task**, `size ≤ 12 MiB`. A malformed entry
  is refused at dispatch with `bad_attachments` — it is never silently dropped.
- Upload: `POST /api/upload` (multipart field `file`, authenticated as yourself with the access
  string §0.2 describes) returns `{file_id, url, size, mime}`; the 12 MiB cap is checked twice
  (Content-Length pre-check, then the parsed file); rate limit **60 uploads per hour per caller**
  (429 `rate_limited`).
- When a `file_id` is present the hub **strips any `path`** from the attachment — cross-machine
  safety, the same rule that forbids absolute paths in a task body.
- Download rights are **network-scoped**: the node's `ntok_` must be bound to the network the
  file was uploaded in. A denied read answers **404, never 403** — so `fetch`'s "no such file for
  this node" means unknown id, gone, or another network, not a bad secret.
- `fetch` caps its own download at 50 MiB (`--max-bytes`), checks `Content-Length` before reading,
  writes the file `0600`, prints `sha12`, and **refuses to write anything** when `--sha12` does not
  match (exit 3 — the same signal `anet_payload.sh verify` gives: report the conflict).

Attachments are for the bytes a git branch cannot carry (generated images, a dataset, a PDF, a
screenshot). The task's acceptance text stays in the body's pointer and the payload segment; the hub
never injects attachment content into the task text.

## Why "the dashboard says offline" is a presence-stream question, not a heartbeat one

The dashboard's node card decides online/offline from **one** thing: whether the hub's
`/health` reports an SSE session for `"<network_id>:<alias>"`
(`app/lib/presence.ts`, `isOnline()` → `sseCountFor(...) > 0`). Heartbeat state is used for
the *status text* (`working` / `idle`), never for the online dot. A node that heartbeats
without an SSE session shows as **offline** while the hub's own `/api/status` counts it as
`working` — the two views genuinely disagree, and both are correct by their own definition.

Since 2026-11-04 the script opens that stream itself (`GET /events/<alias>` with the node's
own `ntok_` token, plus the `X-Anet-Instance-Id` header the hub uses for supersede), so a
running manual node appears online in the dashboard. It behaves like the daemon on purpose:
reconnect with exponential backoff (2s → 30s cap), and on a `node_connection_superseded`
frame (hub keeps exactly one stream per identity, #2299) it backs off 30s → 600s instead of
fighting the winner every second. So starting a daemon under the same alias, or starting a
second manual node, does not produce a reconnect loop.

```bash
# in the `start` log, and in `status`:
[manual-node] 2026-01-01T00:00:00Z sse connected — dashboard will count this node as online
presence stream: connected (3 connects, 0 dropped)

# to turn it off (the dashboard will then show this node offline, by design):
ANET_MANUAL_SSE=0 ./anet_manual_node.sh start --node my-manual-node --project-root /path
```

Check it against the hub, not against the dashboard UI:

```bash
curl -s -H "Authorization: Bearer $ANET_TOKEN" http://<hub>/health | jq '.sse_sessions["<network_id>:<alias>"]'
```

`0` / absent means the dashboard will call that node offline no matter what the heartbeat
says. `>= 1` means the card shows online.

## One command per round; the body you receive is a pointer

Each command above moves **one transition**, so it is **one round** (SKILL.md §1.1). What is banned
is chaining transitions: `inbox && working && reply` on a single shell line is three transitions in
one round — the node has one session slot, so the middle one overwrites the preview of the first, and
if one of the three fails you are left with three responses and no way to tell which transition the
hub took. The reads `working` and `reply` do around their own transition (fetch the stored body, re-read
the task to prove it moved) belong to that round and are not extra calls. Run one command, read its
verdict, run the next one in the next round.

The task a manual node receives is normally a 4-line pointer (SKILL.md §1.2):

```text
第7轮 seg-01：给导出函数补单元测试，3 个用例全绿
file: commhub_tasks/r07/spec.md  seg: seg-01  sha12: 3f7c64c57fb6
branch main (git pull first); work it in your own working directory; accept: every item on the segment acceptance list
report_completion once, result <= 400 chars
```

So the human side of the job is: `git pull`, then prove the pointer with the sibling script:

```bash
scripts/anet_payload.sh verify --file commhub_tasks/r07/spec.md --seg seg-01 \
    --sha12 3f7c64c57fb6 --print-body
```

- a mismatch (or a missing segment) is a **conflict**: run `working`, then say so in `reply` — never
  work on the revision you happen to have;
- work the printed **segment**, not the task text;
- `reply` carries a ≤400-character result (conclusion, what you ran to verify it, the path of the
  long report); the long report goes into the segment's 产出 section and gets committed.

Short bodies matter *more* for a manual node than for a runtime one: the script sends the stored body
back verbatim, and a short body is the only version a human can also reproduce without drifting — and
a drifted body is exactly what leaves a task stuck in `acked`.
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
- **`acked` but not `running`** — either the body was never reported verbatim (re-run
  `working`), or **somebody else acked it** (the row is still in your inbox, so you
  never acked it — see "How a task can leave you"). The script tells them apart and
  refuses the second one.
- **`running`** — the work is genuinely in progress.
- **left behind** — the task disappeared from your inbox (reassigned away, expired,
  or retried). `check` names it so it does not vanish silently.

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

**Both ways are terminal, and the target is derived, never typed.** The reply's recipient is
the original task's `from_name` — when a person dispatched the task from the dashboard, that is
**their username**, and the hub writes the row without requiring the recipient to have a session
row (`assertNodeActive` looks at the `nodes` table and lets an unknown alias pass). And
`replied` is not in the set `retry_task` accepts (`failed` / `expired` / `cancelled`), so a
closed task never comes back: the next round is a new task id.

## Where a message becomes visible

"Visible" means *visible in the Dashboard*. Three pages read three different tables: Tasks reads
`tasks` (with a `completions` fallback), Messages reads `inbox` via `?alias=<alias>`, and
`/messages/inbox` reads `user_inbox` via `?scope=user`. The inbox page is the reading surface that
was missing: `user_inbox` already held every `dm` a node sent the control room (production
`net_b91c0d535346`: 42 rows for `admin`, all unacked) and no page read it.

| channel | tool | lands in | Dashboard |
|---|---|---|---|
| `reply --via send_reply` | `send_reply` | `inbox(session_name=<派单人用户名>, type='reply')` + `tasks.result` | **Messages 页**（`case-11`） |
| `reply` (default) | `report_completion` | `completions` + `tasks.result` | **只有 Tasks 页** — Messages 页与收件箱都没有，人也没有未读（`case-10`） |
| `dm <username>` | `send_desktop_message` | `user_inbox(kind='agent_message')` | **`/messages/inbox`**（`case-9`） |
| `say <alias>` | `send_message` | `inbox(session_name=<node alias>)` | Messages |

实测过的三条路均来自一次性 hub（`tests/manual_node_scenario.sh` 的 `case-9/10/11`）：
`report_completion` 不写任何人能读到的行，`send_reply` 写「派单人别名」的 inbox 行，
`dm` 写 user_inbox —— 所以「发出去了但 Dash 上看不见」从来不是丢消息，是落对了表、
而那一屏没人读。

So the deliverable and the question take different channels on purpose:

- **the answer is the work** → `reply --via send_reply`, and the dispatcher reads it in the
  message stream (the round ends here);
- **you need an answer to keep working** → `state blocked` + `dm`, and the task stays `running`;
  the question shows up in the manager's inbox page as an unread row;
- **pure close-out** (nobody needs to read the text) → `reply` without `--via send_reply`;
  it is the only shape that leaves the control room with no visible message at all;
- **node-to-node chatter** → `say`.

Read the reply side as the user you dispatched as: `GET /api/messages?alias=<username>&network_id=<id>`
(production, 2026-11-04: 5 reply rows addressed to `admin` in that network, 354 unacked rows in the
same channel), and the `dm` side with `GET /api/messages?scope=user&network_id=<id>` (41 rows: 24
`task_expired`, 9 `task_orphan_suspected`, 8 `agent_message`, 0 `human_dm`).

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

`say <alias> "<text>"` sends a message to a **node** and leaves every task open. Use it for
questions or status pings; never use it to close work, because it moves nothing on the task row.

`dm <username> "<text>"` sends a message to a **human** (it lands in that user's inbox as an
agent message). It also leaves every task open.

## Two kinds of inbox row: tasks and chat

`get_inbox` returns inbox **rows**, and the two kinds are answered by different tools. The
script labels each row so the difference is never guesswork.

| row | what it is | how you answer it |
|---|---|---|
| `type: "task"` | dispatched work, has a `task_id` | `working <task_id>` → work → `reply <task_id>` |
| `type: "message"` | chat, **no task id** | `dm <username> "<text>"` |

**A chat row cannot be answered with `reply` or `send_reply`.** Both resolve the id against
the `tasks` table, so a message id comes back as `task not found` (`reply_task_not_found` on
the hub side). A chat row has no lifecycle: nothing to ack, nothing to close, no status.

### Why `say` cannot reach a human

`say` is `send_message`, and `send_message` needs a `sessions` row — sessions are **nodes**.
A human user has no session row, so `say admin` answers `alias_not_found`. That is the hub
working as designed, not a broken target. The tool that addresses a *user* is
`send_desktop_message` (`to_username` / `to_user_id`), which is what `dm` calls. It works
from a node token, and the message lands in the user's inbox.

`dm` reports `persisted, not delivered live: no live subscriber` when nobody is watching the
dashboard — that is normal, and it means the message is **waiting in the user's inbox**, not
lost. It shows up on the Dashboard as an unread row at `/messages/inbox`: see
"Where a message becomes visible".

### Finished tasks keep their inbox row

The hub does not delete a closed task's inbox row; it stays until it is acked. So a task you
already replied to keeps showing up in `inbox` next to real work. `inbox` looks each task row
up and marks it `FINISHED — nothing to do`, and `check` counts it separately from the open
tasks, so the queue and the inbox never get confused.

## Where the state lives

Everything is per node, next to its config, so several manual nodes can share a project
directory without colliding:

```
<project-root>/.anet/nodes/<alias>/config.json          # node id, network, token, hub
<project-root>/.anet/nodes/<alias>/manual-status.json   # last state the heartbeat re-reports
<project-root>/.anet/nodes/<alias>/manual-seen.json     # tasks this node has seen, and which it acked
<project-root>/.anet/nodes/<alias>/manual-heartbeat.pid
<project-root>/.anet/nodes/<alias>/manual-heartbeat.log
```

`manual-status.json` also records **which task id holds the slot**, so the script can
refuse a second concurrent task. `manual-seen.json` records the tasks this node has
seen and which of them *it* acked — that is how the script tells "I acked it" apart
from "somebody else acked it", and how it can name a task that disappeared.

`config.json` holds a credential. Keep the directory at 0700 and out of version control
(the `anet` CLI writes the same `.anet/` layout and adds it to `.gitignore` for you).

## Cleaning a node that was deleted locally only

`anet node delete <ref> --force` removes the **local** directory first and the **hub** row
afterwards (`bin/cli.ts`: `stopResolvedNode` → `rmSync(nodeDir)` → `removeNodeFromHub`, matched by
`node_id` only). If the hub half fails, the CLI warns and exits 1 with the retry command — the
local files are already gone, so the ref you need is the **node_id in that warning**:

```bash
anet node delete <node_id> --hub-only --hub <hub-url>
```

Telling residue apart, with read-only calls (note that `anet node list` reads the local directory
only — it proves nothing about the hub):

- `GET /api/nodes?network_id=<id>` still lists the node, and its `config_path` points at a
  `.anet/nodes/<alias>/config.json` that no longer exists on that machine;
- the `sessions` row is `offline`, and keeps a `lifecycle_state` of `active` that no process backs;
- the alias stays taken, so re-creating a node under the same name is refused
  (`alias_taken` / `node_owner_mismatch`).

What `DELETE /api/nodes/:id` touches: the `nodes` row, that alias's `sessions` rows, the node's
membership in agent teams (#764) and its references in requirement cards (#3277). It deletes
**no tasks, no inbox rows and no completions** — history survives, including tasks addressed to a
name that no longer exists.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `network_token_required` on `report_status` | a user token is in the config | re-mint with `init` |
| `alias_identity_mismatch` | `--node` and the token's bound alias differ | use the config's alias |
| HTTP 401 | token revoked, expired, or from another hub | re-mint with `init` |
| task stays `acked` after `working` | the body did not match byte for byte | let the script fetch it; never retype it |
| `message not found or already acknowledged` | the inbox row is gone (already acked, or the task was retried) | `check` for the real task state |
| `reply_task_terminal` | someone else closed the task | `check` to see who |
| `this node already holds task <id>` | a second task was started while one was running | finish the first (`reply <id>`); a node has one slot |
| `was acked by somebody else` | another node `send_ack`ed the task while it sat in your inbox | do not start it; ask the planner who owns it now |
| `alias_not_found` on `say` | the target is not a node (a human user has no session row) | use `dm <username> "<text>"` for a human |
| `task <id> not found` on `reply`, but the id is in your inbox | it is a **chat message**, not a task | `dm <from_session> "<text>"` |
| heartbeat log says `hub unreachable` | wrong `--hub`, or the hub is down | fix the address in the config |
| `node_owner_mismatch` on `init` | that alias belongs to another node id or owner | reuse the existing config, or pick another alias |
| `no such file for this node` on `fetch` | the id is unknown, deleted, or was uploaded in **another network** (the hub answers 404, never 403) | `files <task_id>` to read the ids the task really carries; dispatch from the network the node belongs to |
| `sha12 mismatch` on `fetch` (exit 3) | the file changed after dispatch | `reply` with the conflict; do not work on the bytes you happen to have |
| 私信在 Dashboard 看不到 | `dm` 落 `user_inbox`，Dashboard 没有读它的页面 | 交付走 `reply --via send_reply`（落 `inbox`，Messages 页可见）；私信只作提醒 |
| dashboard 上手动节点显示成登录名（如 `admin`） | 前端在 `nodes.owner_user_id` 为 null 时的回退标签，不是 hub 身份 | 派活只认节点真实 alias；`GET /api/status?alias=admin` 实测 0 行 |
| 节点在 dashboard 永久离线、名字还被占用 | 本地删了、hub 行没删（残留） | `anet node delete <node_id> --hub-only --hub <url>` |
