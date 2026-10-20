---
name: agent-network-skill
description: >-
  CommHub MCP task protocol for planners (send_task / get_task / list_tasks) and workers (get_inbox /
  ack_inbox / report_status / report_completion): token tiers (utok/atok/ntok), the task lifecycle
  state machine, the exact-match parameter rules, cross-machine path-independent conventions,
  requirement-pool mode (tasks with no named worker, requirements_*, claiming), and manual nodes
  (no MCP runtime) driven by scripts/anet_manual_node.sh. Triggers: dispatch a task, take a task,
  verify work, check inbox, task stuck in acked or delivered, alias_not_found, report_completion has
  no effect, commhub, agent-network, MCP worker, control room, requirement pool, manual node
  heartbeat, dashboard node card shows truncated task text. Chinese triggers (keep matching these):
  派任务、收任务、验收、查 inbox、任务卡在 acked 或 delivered、alias_not_found、report_completion 不生效、
  commhub、agent-network、MCP 工人、指挥室、需求池、手动节点、手动节点心跳、任务没被 ack、
  dashboard 节点卡片任务文本被截断。
license: MIT
activation: /agent-network-skill
compatibility: >-
  Needs a CommHub hub reachable over HTTP. The bundled manual-node script needs bash plus node (or
  bun) on PATH; every other part of this skill is plain MCP tool calls.
metadata:
  author: pixb
  version: 0.5.0
  created: 2026-10-07
  last_reviewed: 2026-10-20
  review_interval_days: 60
provenance:
  maintainer: pixb
  version: 0.5.0
  created: 2026-10-07
---

# /agent-network-skill

The unified protocol for the "dispatch → work → report → verify" loop over CommHub MCP. The rules
for both roles — planner (control room) and worker (executor) — live in this file. **The operator's
wording picks the role**: "plan a dev task onto agent-network" means follow §1, "take a task" means
follow §2. The skill is project-independent: drop it into any project's `.agents/skills/` and it
works, with no project-level documentation file required.

## When this skill triggers

**Look at the tools, not the words.** If the visible tool names are the `mcp__*__send_task` /
`mcp__*__get_inbox` / `mcp__*__report_completion` family (with or without the prefix), assume
"dispatch a task over commhub" — it means the operator is logged into this CommHub on this MCP
client, usually in the control room or an MCP-client dev container. Typical triggers: "dispatch a
task onto agent-network", "plan dev tasks and hand them to <worker-alias>", "build X and dispatch
it", "take a task", "verify", "check inbox", "task stuck in acked", "alias_not_found",
"report_completion has no effect".

Invocation examples:

- `/agent-network-skill check the commhub connection and my token`
- `/agent-network-skill split this round's work and dispatch it to <worker-alias>, ttl 86400`
- `/agent-network-skill take a task and report per protocol`
- `/agent-network-skill verify every task for <worker-alias>`

## 0. Prerequisites: connection, tokens, tool surface

**Endpoint**: `POST <hub>/mcp` (Streamable HTTP; local default `http://127.0.0.1:9200/mcp`, hub port
defaults to 9200). Headers must carry `Content-Type: application/json` and
`Accept: application/json, text/event-stream`; the response is SSE — read the `data:` lines.

### 0.1 The three token tiers (values live in env vars or local config, **never in a repo**)

| Token | Who uses it | What it can do |
|---|---|---|
| `utok_` | A person (issued at login) | Human tools (manage projects, browse node files/logs) + every collaboration tool; not bound to a network — scoped by the networks that user can see |
| `atok_` | Scripts / clients that need a credential that never expires | Exactly the same permission surface as `utok_` (it is `scope=full` in the hub); the only benefit is that it **never expires**. A planner using the `utok_` it already logged in with is enough — don't mint extra |
| `ntok_` | A node (worker) | The only token that can call **node-only** tools (`report_status`, `org_whoami`, `schedule_*`, …); bound to a network + node identity |

**A token is not optional.** The hub ships with V3 auth on: the very first step of `/mcp` is auth,
and a missing token gives a flat `401 unauthorized`; `anet node create` is blocked locally
(`❌ Not logged in. Run: anet login`, `exit 1`). The hub side only relents when it was started with
`--dev-open` (and `COMMHUB_AUTH_TOKEN` is unset) — but the CLI's local gate **still stands**. So
"I never configured a token" does not mean "there is no token".

**Where tokens come from (three steps from zero)**:

1. `anet register` (create the account on the hub) or `anet login --hub <url> --username <user>`
   (account + password; a self-hosted hub's admin password is the random string `anet hub start`
   printed once, not a fixed `anethub`). Both write the token into `~/.anet/config.json`, so you
   never copy it by hand.
2. `anet token create --name <planner>` — mints an `atok_` for a planner agent (plaintext shown
   once).
3. `anet node create <name> --runtime <runtime>` — requests an `ntok_` for that node and writes it
   into `.anet/nodes/<name>/config.json`; at startup the node injects `COMMHUB_URL` /
   `COMMHUB_TOKEN` into its MCP subprocess, so **the worker side never pastes a token by hand**.

CLI token lookup order: `--token` → env var `COMMHUB_TOKEN` → `~/.anet/config.json`.

### 0.1.1 Token operations and troubleshooting (revocation is irreversible — look before you act)

- **Every login adds a token; the old ones stay valid**: `anet login` (CLI / dashboard / a second
  machine) each issues its own utok and **does not rotate or kick out the previous ones**. So a long
  list of `user-login` rows in `anet token ls` is normal; the practical rule is **one token per
  machine**, revoked when that machine is retired.
- **What actually idle-expires**: a utok (`scope='user'`, not network-bound) expires after
  `COMMHUB_SESSION_IDLE_DAYS` days of disuse (default 30, 0 = off); **`atok_` and `ntok_` never
  expire** (long-lived credentials — only manual revocation ends them).
- **`last_used_at` has hour granularity** (written at most once an hour) — never use it as
  second-by-second proof of presence.
- **The hub stores only sha256 and records no IP**: the plaintext cannot be reversed, and "which
  machine is using this" is unanswerable. The only way to claim a token is login metadata: a CLI
  login is `kind=cli` + `client_label` "`anet <version> · <host> · <subcommand>`"; **a dashboard /
  browser / app login is `kind=login` with no label**.
- **Confirm which token this machine is using**: `anet token ls` gives IDs only; to identify an ID,
  read the metadata — when you can read the hub DB, compare
  `printf %s '<plaintext>' | sha256sum` against `api_tokens.token_hash` (`hashToken()` = bare sha256
  hex), with the plaintext taken from local config (`token` in `~/.anet/config.json`).
- **`anet token revoke <token-id>` is a hard delete with no undo**, and it accepts user tokens only
  (node tokens are refused). Revoking a node's ntok = that node gets a **401 on its next start** and
  must be re-created with `anet node create`. **Back up the hub database (including `-wal` / `-shm`)
  before touching anything.**
- **`Session expired. Run: anet login`** = this login token was revoked or idle-expired; log in
  again — **other machines are unaffected** (logging in does not rotate anyone else's token).
- **`anet token ls` is not enough**: it shows only ID / NAME / CREATED / LAST USED, **no label or
  kind**, and its times are **UTC** (8 hours behind local — don't read a token you just created as
  "yesterday's"). For device / current-session detail use `GET /api/auth/sessions` (includes
  `is_current`; needs a user token).

### 0.2 Client setup

- opencode (planner, example):
  `opencode mcp add commhub --url http://127.0.0.1:9200/mcp --header "Authorization=Bearer $COMMHUB_TOKEN"`
- Other MCP clients are the same idea: put a valid token in the `Authorization: Bearer <token>`
  header, configured through the client's own header / env-var mechanism (the variable name is the
  client's choice — it need not be `COMMHUB_TOKEN`).
- pi (example):
  `pi mcp add commhub --url http://127.0.0.1:9200/mcp --bearer-token-env-var COMMHUB_TOKEN`
- Call shape follows the tool names your MCP client actually exposes (codemode-style clients look
  like `tools.mcp__<server>__<tool>`, e.g. `tools.mcp__commhub__send_task`).
- Generic JSON-RPC self-check (curl):

```bash
curl -s http://127.0.0.1:9200/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $COMMHUB_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}'
```

The tool set is whatever the running hub returns from `tools/list`.

### 0.3 CLI vs MCP: who does what (don't use `anet` as a protocol client)

| Job | Interface |
|---|---|
| Install/start the hub, log in, issue tokens, create/stop nodes, read config | `anet` CLI |
| **Prove your identity / audit tokens** (who is using which token) | `anet whoami` (who am I + current hub/network), `anet token ls` (every token under this account; details in §0.1.1) |
| **Look at** tasks (read-only) | `anet tasks [status]`, `anet status`, `anet logs <name>` |
| Dispatch work, inbox, ack, report working, report completion | **MCP tools** (`anet` has no such commands) |
| Dispatch / ack from a human's script | REST: `POST /api/task` (dispatch), `POST /api/messages/ack` (ack); `GET /api/tasks`, `GET /api/completions`. `report_status` / `report_completion` have **no** REST equivalent and are MCP-only |

`anet run` is an SSE echo demo (it prints each incoming task and replies
`[<alias>] 收到: <first 200 chars>` — a literal echo, not a protocol worker).

## 1. Role A: planner (control room)

Tools: `send_task` `get_task` `list_tasks` `cancel_task` `retry_task` `reassign_task`
`get_all_status` `broadcast` `send_message` (the pool path is in §6).

1. **Confirm connection and token**: MCP is connected (`tools/list` shows the commhub tools); run
   `anet whoami` when in doubt.
2. **Split the work**: every task must be self-contained (background + what to do + completion
   criteria) and must state "**do this in your own working directory**", with relative paths only
   (forbidden forms in §4). The operator names the `alias` — **never assume a default**.
3. **Dispatch**:
   - One call per task: `send_task(alias=<worker-alias>, task=<body>, context=<background/references>,
     priority=<high|normal|low>, ttl_seconds=<default 3600, 86400 for long jobs>)`.
   - Use `parent_task_id` to chain only changes that affect each other.
   - **Stop after dispatching**: don't also dispatch the next batch in the same turn and don't poll —
     the recipient is an asynchronous AI; wait for its own completion signal (`report_completion` /
     a terminal `get_task`).
4. **Verify**:
   - `get_task(task_id)` / `list_tasks(alias=<worker-alias>)` to check status and result.
   - `get_all_status` for global busy/idle.
   - `get_completions(alias=<worker-alias>)` for the actual output and the self-score (0-10).
   - Verification is read-only: don't touch the other side's directories or state; whether tasks
     from this round are left for you to dispose of is the operator's call.
5. **Ask when unsure**: vague scope, or anything touching interfaces / deleting data / production —
   ask the operator first; don't decide for them.

**Hard rules for the task body** (get these wrong and the worker will build the wrong thing):

- **Self-contained**: state the goal, the paths (relative to your working directory) and the
  acceptance criteria inside the body; never reference your own previous turn's context (the other
  side cannot see it).
- **One task, one deliverable**: don't stuff several deliverables into one body — both the state
  machine and the reporting turn to mush.
- **TTL**: default 3600s for anything verified within the round; give 86400s explicitly for work
  that runs across hours or overnight.
- **First line is a one-line summary** (this is what the dashboard node card shows): put a one-line
  summary on **line 1**, ≤80 characters, and make sure **the first 200 characters stand as a complete
  sentence**; leave a blank line after it, then write the background / steps / acceptance markdown.
  Why: `sessions.task` keeps only the **first 200 characters** of the body, cut **blindly** — no
  sentence and no newline awareness; the dashboard node card, `get_all_status` and `/api/status` all
  read that column. The full body (≤10000 characters) is intact in `get_inbox` / `get_task`, so never
  put a long paragraph, a code block or a big paste at the front. The worker side is unaffected:
  `report_status(status="working", task=…)` must still pass **the complete original text** (only an
  exact match moves the task to `running`); the first-line summary is a dispatcher-side convention.
- **No absolute paths** (§4).

## 2. Role B: worker (executor)

Tools: `get_inbox` `ack_inbox` `report_status` `report_completion`.

1. **Register**: if the hub's sessions table has no row for your alias, the planner's dispatch
   returns `alias_not_found`. Call `report_status(alias=<self>, status="idle", resume_id=<session id>)`
   first to create the row (worker nodes usually get this from `anet node create` + the runtime).
2. **Receive**: `get_inbox(alias=<self>)` for pending work; a task message's handle is the
   `message_id` in the response (which is the `task_id`).
3. **Acknowledge**: `ack_inbox(alias=<self>, message_id=<task_id>)` per task, optionally with
   `response` ("received, starting"). This step alone drives `delivered → acked`.
4. **Start**: `report_status(alias=<self>, status="working", task=<the task body>)` — `task` **must
   be character-for-character identical** to the body (matching is exact-equality on the body only,
   **there is no task_id branch**), otherwise the task stays in acked.
5. **Report**: **exactly once** per task,
   `report_completion(alias=<self>, task=<task_id is safest; the raw body must match character-for-character if used>,
   result=<summary: conclusion / changes / how you verified — the task row keeps only the first 4000
   characters>, artifacts=[<URL or file path>])`. You may also pass `score` (self-assessed 0-10).
   Merging several tasks into one report = none of them take effect.
6. **Finish**: `report_status(alias=<self>, status="idle", task=null)` (a completion also sets the
   session to idle).
7. **Stuck? Fix it**: see §3 and Gotchas — **don't re-send** (the dedupe layer rejects it), and don't
   change status without reporting.

**Worker discipline**:

- Report after the work is done, not before; every verification you claim in `result` must have
  actually been run.
- One completion per task; never merge several tasks into one report.
- When the task contradicts the repository (say, the file to delete does not exist), **state the
  conflict in `result`** — don't unilaterally widen the change.

## 3. Task lifecycle (state machine)

```
created ──send_task──▶ delivered ──ack_inbox──▶ acked ──report_status(working)──▶ running ──report_completion──▶ replied
   │                       │                       │                                │
   │                       └───────────────────────┴────────cancel_task─────────────┴──▶ cancelled
   └──(TTL timeout)──▶ expired        failed ◀── send_reply(status="failed") / node died abnormally
```

| Transition | Call that drives it | Notes |
|---|---|---|
| created → delivered | `send_task` | Delivered immediately when online; offline returns 202 (queued) and is delivered on reconnect |
| delivered → acked | `ack_inbox(message_id=task_id)` | Only fires from delivered |
| delivered/acked → running | `report_status(status="working", task=<body>)` | **`task` must match the body character-for-character**; exact-equality on the body only, **no task_id branch** |
| any non-terminal → replied | `report_completion(task=<body>)` | Tries `task_id` first; on a miss, exact-equality on `to_name=alias AND content=<body>` |
| any → cancelled | `cancel_task` | Planner/operator |
| timeout → expired | hub timer | TTL default 3600s, max 86400s |
| failed / expired / cancelled → retryable | `retry_task` | Always adds +1h TTL; `task_id` is unchanged, the inbox gets a new message id |

**Parameter hard rules**

- `report_completion(task=…)` matching: **`task_id` first; on a miss, `to_name=alias AND
  content=<body>`**, taking the most recent match.
- `report_status(task=…, status="working")` flips a task to running **only** on
  `to_name=alias AND content=<body>` exact-equality, **with no task_id branch** — passing a
  `task_id` silently does nothing and the task stays in acked forever.
- Therefore: rewriting, summarizing, translating, or merging several tasks into one report all break
  the match → the state stalls.
- To repair: if stuck in acked, add one **character-exact** completion (when the work is already
  done) or working call; if it is thoroughly wrong, `cancel_task` + `retry_task` and start over.
- Dedupe: the same `(from, to, content)` re-sent within 5 minutes is rejected (`duplicate_send`).

## 4. Cross-machine / dual-directory conventions

The planner and the worker are usually on two machines with their own working copies, under different
paths:

| Role | Working directory | Git |
|---|---|---|
| Planner (control room) | any directory on machine A, e.g. `~/dev/<repo>` | the same remote branch |
| Worker (executor) | any directory on machine B, e.g. `/srv/<repo>` | the same remote branch |

- **The hub never needs to know any project path**: dispatch is by `alias` only; the worker's runtime
  works in **its own working directory** (the cwd at node creation). Paths are each machine's local
  fact.
- **No absolute paths**: task bodies and delivery notes must not contain `/home/...`, `C:\...` or
  `~/...`; don't copy them out of `get_all_status`'s `project_dir` either (that is a stale reported
  value that dies the moment the machine changes). Point at locations as "in your working directory"
  plus a relative path (e.g. `src/game.js`).
- **No cross-directory assumptions**: never read files in "the other side's directory" to judge their
  progress or result.
- **Delivery has exactly two routes**: git push/pull, or a hub attachment — `POST /api/upload` to get
  a `file_id`, then put it in `report_completion` / `send_task` as
  `meta.attachments: [{type:"file", file_id}]` (when a `file_id` is present the hub strips `path`,
  precisely for cross-machine safety).
- **Trust only the hub for state**: planners use `get_task` / `list_tasks` / `get_all_status`; workers
  use `get_inbox`.

## 5. Wiring up a new project

```bash
git submodule add git@github.com:pixb/agent-network-skill.git .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill .gitmodules
git commit -m "add agent-network-skill submodule"
```

SKILL.md sits at the repository root (there is no extra `skills/` container directory and no
symlink), so mounting it at `.agents/skills/<name>` is enough for project-level scanners in pi /
opencode and friends to find it. To update: `git submodule update --remote
.agents/skills/agent-network-skill` and commit.

## 6. Requirement pool mode (hub ≥ 0.9.0-preview.67)

"Public" tasks that name no worker use the requirement-pool tools (`requirements_*`) and need hub
version **≥ 0.9.0-preview.67** (on 0.9.0-preview.64/65/66 node tokens could not use this tool set):

- Publish: `requirements_create(name=..., description=..., column="pool")` (omit `agent_owner` to make
  it public).
- Claim: a worker calls `requirements_update(id=..., column="doing",
  agent_owner={kind:"node", alias=<self>})`.
- Collaborate: `requirements_comment` for progress; `requirements_checklist_toggle` to tick one item
  (it writes only that item and never overwrites anyone else's edit).
- Query: `requirements_list(q=..., tag=..., status=...)`, `requirements_get(id or "#N")`.

**Upgrade note**: `anet hub start --version <v>` only affects a **fresh start** (an already-running
hub will not switch versions because of it) — to change version, `anet hub stop` first, or change the
pm2 start arguments.

## 7. Manual nodes (no MCP runtime behind them)

A **manual node** is a hub node with no agent runtime: no agent-node process, no MCP tool surface,
so no model ever calls `get_inbox` or `report_status` for it. It still receives dispatched tasks and
still has to move through the same lifecycle — a human, or a script acting for one, performs each
transition explicitly. A node whose hub `runtime` is `manual` is one of these; a node with a real
runtime is driven by its runtime and by the MCP tools in §2, **not** by the script below.

Run `scripts/anet_manual_node.sh` (a single self-contained file; needs bash plus node or bun) on the
machine that owns the node. It is the whole protocol, made explicit:

```bash
./anet_manual_node.sh init --node <alias> --project-root <dir>   # mint node token + register
./anet_manual_node.sh start --node <alias> --project-root <dir>  # heartbeat: keeps it visible
./anet_manual_node.sh inbox --node <alias> --project-root <dir>  # what arrived
./anet_manual_node.sh working <task_id> 10 --node <alias> --project-root <dir>
./anet_manual_node.sh reply <task_id> "done: ..." --node <alias> --project-root <dir>
```

Read `references/manual-node.md` for the full command set, the token rules, the failure modes, and
why the task body is fetched from the hub instead of retyped.

### 7.1 The one step you must not skip: `working`

**An automatic node's runtime sends `report_status("working")` by itself** — the agent-node
process does it when a turn starts, and keeps re-sending it on the heartbeat
(`agent-node/src/cli.ts`). **A manual node has no runtime, so nothing sends it for you.** The
`working` command is your only "I have started this" signal, and the only thing that writes
`tasks.started_at`.

Skipping it does **not** fail. The hub lets a task go `delivered → replied` directly
(`report_completion` matches `status IN ('delivered','acked','running')`), so the reply still
lands and nobody is told anything went wrong. The cost is invisible to you and expensive to
the planner:

| what the planner sees | with `working` | without it |
|---|---|---|
| task row | `running`, `started_at` set | `delivered` the whole time |
| session row | `working` + the task text | `idle` + empty text |
| hub patrol | quiet | `task.warning.delivered_stale_30s` / `_60s` all run long |
| queue depth | honest | the node looks free to dispatch to |

So a manual node that reads the inbox and then works without `working` spends the whole job
**invisible** — the planner sees an idle node and a task nobody started.

> **Rule: no `working`, no start.** Run `working <task_id> 0` *before* you begin the work, not
> after. `working` acks the task if it is still `delivered`, fetches the body from the hub
> (never retype it), reports it, and then verifies the hub really says `running` — if it does
> not, it fails loudly instead of leaving you busy-but-invisible.

`reply` warns when a task is closed while it was still `delivered` or `acked`, because that
means `working` was skipped. The warning does not block the reply — the work really is done —
but it is the only signal you get that the run was invisible.

### 7.2 What the hub should look like once you start

Three independent facts have to line up; a heartbeat moves **none** of them.

| hub fact | while you work | who writes it |
|---|---|---|
| `tasks.status` | `running`, with `started_at` set | `working` |
| `inbox.acked` | `1` | `working` (it acks first) |
| `sessions.status` / `sessions.task` | `working` + the body | `working` / the heartbeat |

`check` prints the slot (the one task this node holds) separately from the queue (the open
task rows), because they are different things — read the **verdict per task**, not the session
status.

**Two facts that decide how a manual node behaves** (both are hub storage
semantics, not conventions):

1. **A node has one task slot, not one per task.** `sessions` is unique on
   `(network_id, alias)` and that row holds a single `status` and a single 200-char
   task preview — a second `report_status` overwrites the first task's text. Real
   runtimes queue the rest FIFO for the same reason. So a manual node works **one
   task at a time**; the script refuses a second concurrent task rather than
   letting the first vanish from the session view.
2. **"Online" is not "working", and a task can leave you silently.** A heartbeat
   plus `sessions.status = idle` looks exactly like a node doing nothing while its
   task sits untouched — read the task row, never the session row. And three
   things can take a task away: another node cannot `ack_inbox` it (a node token
   only acks its own rows), but the planner can `reassign_task` it away, and
   *anybody* can `send_ack` it — which updates the task by id **without checking
   ownership**, so a task can be `acked` under a manual node that never acked it.
   `check` names all three cases ("left behind", "ACKED BY SOMEONE ELSE"), and
   `ack`/`working` refuse a task somebody else claimed, so two nodes never work
   one task.

When a task looks stuck, run `check` and read the verdict per task, not the
session status:

- **still `delivered`** — nobody acked it; the work never began (the hub's patrol
  logs `task.warning.delivered_stale_30s` / `_60s` for the same condition)
- **`acked` but not `running`** — the body was never reported byte-for-byte, *or*
  somebody else acked it (the row is still in your inbox, so you never acked it)
- **`running`** — genuinely in progress
- **left behind** — it disappeared from your inbox (reassigned away, expired, or
  retried)

## Gotchas

- **Planner**: stop after dispatching — no waiting, no polling; ask first when a task is vague.
- **Worker**: `get_inbox` → `ack` → `working` → `completion`, once per task; make `result` concrete
  and run lint/test before reporting when you can.
- **Stalled state**: first check whether you rewrote/summarized `task` (matching is exact-equality) or
  skipped `ack`.
- **A task stuck in `delivered` is usually "nobody acked it", not "the node is offline"** — the hub's
  `delivered_stale_*` patrol warnings say exactly that, and a manual node (§7) can be heartbeating
  happily while its task sits untouched. Read the task row, not the session row.
- **A node has ONE task slot.** Dispatching two tasks to a manual node does not make it work on two:
  the second overwrites the first in the session row, and the first disappears from the node's status
  view while still sitting in the task table. Take one, finish it, then take the next.
- **`report_status` is node-only**: a user token gets `network_token_required`. A manual node needs
  its own `ntok_`, which is why `anet node create` is not the way to make one — its runtime
  whitelist has seven entries and `manual` is not among them.
- **`alias_not_found`**: the target alias has no session row on the hub. Confirm the node is online
  first, and don't re-send repeatedly (re-sends enter the dedupe window).
- **Status unchanged after `report_completion`**: the `task` argument is not character-for-character
  identical to the stored body, or the token in the environment is not that node's token at all
  (reporting progress under the same token for a different node).
- **Environment-variable contamination**: with multiple machines sharing a session or several hubs
  around, `COMMHUB_URL` / `COMMHUB_TOKEN` bleed across; sanitize with
  `env -u COMMHUB_URL -u COMMHUB_TOKEN` or pass values explicitly, then re-run.
- **MCP returns `401 unauthorized`**: check the token before blaming the hub — `anet whoami` or the
  curl from §0.2 will tell you; with no token, **no** tool on `/mcp` is callable. Issuing / expiring
  (idle timeout) / revoking tokens, and "whose token is this", are in §0.1.1.
- **Don't dispatch via the `anet` CLI**: `anet` has no `send_task` / `get_inbox` / `report_*`
  commands — the protocol lives on MCP only (§0.3).
- **A node card shows task text that reads like half a sentence / carries stray newlines**: the hub is
  not broken — `sessions.task` keeps the first 200 characters and cuts **blindly** (no
  sentence/newline awareness). Put a one-line summary on line 1 when dispatching (§1, "First line is
  a one-line summary"); the body is always intact in `get_inbox` / `get_task`.
