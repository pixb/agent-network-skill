---
name: agent-network-skill
description: >-
  CommHub MCP task protocol for planners (send_task / get_task / list_tasks) and workers (get_inbox /
  ack_inbox / report_status / report_completion): token tiers (utok/atok/ntok), the task lifecycle
  state machine, the exact-match parameter rules, cross-machine conventions, requirement-pool mode,
  manual nodes (no MCP runtime) via scripts/anet_manual_node.sh, and the call-discipline rules: one
  commhub call per round, short task/message parameters with long text in a payload file segment
  addressed by path + seg id + sha12. Triggers: dispatch a task, take a task, verify work, check
  inbox, task stuck in acked or delivered, alias_not_found, report_completion has no effect, one call per round,
  task body too long, commhub, agent-network, MCP worker, control room, requirement pool, manual node
  heartbeat, dashboard node card truncated. Chinese triggers (keep matching these): 派任务、收任务、验收、查 inbox、任务卡在 acked、
  alias_not_found、report_completion 不生效、commhub、MCP 工人、指挥室、需求池、手动节点、任务没被
  ack、一轮一个调用、任务正文太长、参数太长、长文本落盘。
license: MIT
activation: /agent-network-skill
compatibility: >-
  Needs a CommHub hub reachable over HTTP. The bundled manual-node script needs bash plus node (or
  bun) on PATH; every other part of this skill is plain MCP tool calls.
metadata:
  author: pixb
  version: 0.6.2
  created: 2026-10-07
  last_reviewed: 2026-11-08
  review_interval_days: 60
provenance:
  maintainer: pixb
  version: 0.6.2
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
- `/agent-network-skill the task body is too long, move it into a payload file and dispatch a pointer`
- `/agent-network-skill I fired three commhub calls in one turn, what state is the hub in now`
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

### 0.1.1 Token operations and troubleshooting

Read `references/token-operations.md` before touching a token — **revocation is a hard delete with no
undo**, `anet token revoke` accepts user tokens only (a node whose `ntok_` is revoked gets a 401 on
its next start), every login mints a *new* token and never rotates the old ones, `last_used_at` has
hour granularity, the hub stores only sha256 and no IP, and `anet token ls` prints no label/kind and
reports UTC times. The short version: **one token per machine**, back up the hub database (with
`-wal` / `-shm`) before revoking anything, and use `GET /api/auth/sessions` for device detail.

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

**The control room is a user account, and it does not need a node.** Dispatch runs on a user
token, so every task row carries `from_name = <your username>`; a user token is refused by
`report_status` (`network_token_required`), which is the tool that creates a session row — there is
nothing for a control room to run, and nothing to dispatch to. A control-room node is only needed
when the planner is an **agent** that must heartbeat, be dispatched to, or subscribe to SSE; a human
with a dashboard is not that. See §7.0 for the channels and where each one lands.

1. **Confirm connection and token**: MCP is connected (`tools/list` shows the commhub tools); run
   `anet whoami` when in doubt.
2. **Split the work**: every task must be self-contained (background + what to do + completion
   criteria) and must state "**do this in your own working directory**", with relative paths only
   (forbidden forms in §4). Write the long version of that into a **payload file segment** (§1.2) and
   dispatch a pointer at it. The operator names the `alias` — **never assume a default**.
3. **Dispatch** (§1.1 and §1.2 are hard rules, not style):
   - One call per task **and one commhub call per round**: `send_task(alias=<worker-alias>,
     task=<short body>, context=<one line>, priority=<high|normal|low>, ttl_seconds=<default 3600,
     86400 for long jobs>)`. N tasks = N rounds, not N calls.
   - The body is a **pointer**: a one-line summary plus `file:` / `seg:` / `sha12:` (§1.2). Build it
     with `bash scripts/anet_payload.sh compose`; the spec text stays in the payload file.
   - Use `parent_task_id` to chain only changes that affect each other.
   - **Stop after dispatching**: the round ends with the dispatch. Don't also poll, don't also check
     status, don't also dispatch the next task — the recipient is an asynchronous AI; wait for its
     own completion signal (`report_completion` / a terminal `get_task` in a later round).
4. **Verify** (one call per round, §1.1):
   - `get_task(task_id)` in one round; `list_tasks(alias=<worker-alias>)` in another.
   - `get_all_status` for global busy/idle — its own round.
   - `get_completions(alias=<worker-alias>)` for the actual output and the self-score (0-10).
   - Verification is read-only: don't touch the other side's directories or state; whether tasks
     from this round are left for you to dispose of is the operator's call.
5. **Ask when unsure**: vague scope, or anything touching interfaces / deleting data / production —
   ask the operator first; don't decide for them.

### 1.1 One commhub call per round (hard rule)

**A round = one of your turns. In one round you move the hub's state at most once.** For an agent
talking MCP directly that means **at most one CommHub call**: every tool counts, read-only included
(`send_task`, `get_task`, `list_tasks`, `get_all_status`, `get_completions`, `get_inbox`,
`ack_inbox`, `report_status`, `report_completion`, `send_message`, `broadcast`, `requirements_*`). A
codemode script, a shell loop, a parallel tool-call batch, or "dispatch three independent tasks at
once" is **one round** and gets no exemption.

**What is not a second round.** A script command that performs **one transition** may read the hub
around that transition: `scripts/anet_manual_node.sh working` fetches the stored body (so the echo
can be byte-exact), acks a `delivered` task on the way in, sends `report_status`, then re-reads the
task to prove it reached `running`. That is one round, not four — the reads exist to make the single
transition provable, and the script is deterministic, so the operator still knows which transition
moved what. The rule bans *you* deciding to fire several calls for several purposes in one turn.

| role | round N | round N+1 |
|---|---|---|
| planner | `send_task` (exactly one task) | read its completion, then decide the next task |
| planner (verify) | `get_task(task_id)` | `get_completions` / `get_all_status`, one per round |
| worker | `get_inbox(alias)` | `ack_inbox(message_id)` |
| worker | `report_status(status="working", task=<body>)` | work, then `report_completion` (once) |

Why it is protocol and not style: a batch is **undiagnosable** (three responses, and every repair in
§3 hinges on which call moved which state); a node has **one session slot**, so parallel dispatch
overwrites the preview and the first task vanishes from the node's status view (§7);
`report_completion` updates a task row only while that row is `delivered`/`acked`/`running`, so a
second report on the same task changes nothing in `tasks` while it still appends a row to
`completions`, and one report naming several tasks matches none of them; the recipient is
**asynchronous**, so a second dispatch written before its completion is written blind; the dedupe
window punishes the re-send habit a batch starts. Local work is free between rounds (`read`, `write`,
git, bash, and `bash scripts/anet_payload.sh`); commhub calls are the scarce resource.

### 1.2 Short parameters; the long text goes to a file (hard rule)

Budgets for text passed **into** a commhub argument: `task` ≤ 300 characters, ≤ 6 lines, line 1
≤ 80; `context` ≤ 200; `send_message` / `broadcast` `message` ≤ 200; `report_completion` `result`
≤ 400 (the row stores 4000 — do not use them all). Never a pasted spec, a code block, a log, a diff,
a table, a file's content, or an absolute path.

Long text lives in a **payload file in your working tree** — `commhub_tasks/<round>/spec.md` by
default — split into `## seg-NN <title>` anchors, **one segment per task**; the body is a 4-line
pointer at one segment:

```text
第7轮 seg-01：给导出函数补单元测试，3 个用例全绿
file: commhub_tasks/r07/spec.md  seg: seg-01  sha12: 3f7c64c57fb6
branch main (git pull first); work it in your own working directory; accept: every item on the segment acceptance list
report_completion once, result <= 400 chars
```

`sha12` = the first 12 hex characters of the sha256 of the segment text: it names the revision the
worker must read. Build the body mechanically — run
`bash scripts/anet_payload.sh compose --file commhub_tasks/r07/spec.md --seg seg-01 --summary
"第7轮 seg-01：给导出函数补单元测试，3 个用例全绿" --branch main`, which prints the exact `task` text
and refuses a >80-character summary, a >300-character body, a >6-line body, a code block, an absolute
path (any token starting with `/`, `~/`, `X:\`, or `\\host\`), and a payload file that is untracked,
uncommitted, or unpushed (the worker pulls the branch; it cannot read your disk). Worker side: run
`bash scripts/anet_payload.sh verify --file … --seg … --sha12 …` first; a non-zero exit (missing
file, missing segment, sha12 mismatch) means **report the conflict**, never work on a guess. Auditing
a body you already have (a hub row, a draft) is `bash scripts/anet_payload.sh guard --body "…"`, the
same rule from the same place.

Why it is correctness, not cosmetics: `sessions.task` keeps the first 200 characters cut blindly (the
node card, `get_all_status`, `/api/status`), and `report_status(status="working")` matches the body
**byte-for-byte** — a long body is a long thing for the worker to reproduce without drifting, and a
drift rots the task in `acked` (§3). The default 4-line pointer is 240-280 characters, so the preview
holds line 1 and the `file:`/`seg:`/`sha12:` line (they end near character 95) and cuts the tail of
line 3 — the part the card must carry is at the front, which is the point. Self-containment still
holds: goal, steps and acceptance criteria live **inside the named segment**. Read
`references/payload-files.md` for the segment format, the guards, the handoff routes and the failure
modes.

**Hard rules for the task body** (get these wrong and the worker will build the wrong thing):

- **Self-contained**: state the goal, the paths (relative to your working directory) and the
  acceptance criteria inside the body; never reference your own previous turn's context (the other
  side cannot see it).
- **One task, one deliverable**: don't stuff several deliverables into one body — both the state
  machine and the reporting turn to mush.
- **TTL**: default 3600s for anything verified within the round; give 86400s explicitly for work
  that runs across hours or overnight, and keep `ttl_seconds ≥ 2 × the node's idle budget` — read
  `references/ttl-and-expiry.md` before shortening one.
- **The body is a pointer, not the spec** (§1.2): ≤ 300 characters, ≤ 6 lines, with `file:` / `seg:` /
  `sha12:` carrying the real content. A paste or code block in a parameter is the most reliable way to
  stall a task.
- **One commhub call per round** (§1.1): the dispatch *is* the round; N tasks = N rounds.
- **First line is a one-line summary** (this is what the dashboard node card shows): line 1 is a
  ≤80-character summary that **stands as a complete sentence**, because `sessions.task` keeps only the
  **first 200 characters** of the body, cut **blindly** — no sentence and no newline awareness — and
  the dashboard card, `get_all_status` and `/api/status` all read that column. A 4-line pointer puts
  the summary and the `file:`/`seg:`/`sha12:` line inside that preview (they end near character 95);
  a paste at the front is what produces a half-sentence card. The full body stays intact in
  `get_inbox` / `get_task`, and the worker is unaffected: `report_status(status="working", task=…)`
  must still pass **the complete original text** (only an exact match moves the task to `running`).
- **No absolute paths** (§4).

## 2. Role B: worker (executor)

Tools: `get_inbox` `ack_inbox` `report_status` `report_completion`.

**One commhub call per round (§1.1):** the steps below are one call each, so they are one round
each. Reading the hub, acking, starting, and reporting are four rounds, not one turn with four
calls in it. Between them you do local work (read files, run the tests), which costs nothing.

1. **Register**: if the hub's sessions table has no row for your alias, the planner's dispatch
   returns `alias_not_found`. Call `report_status(alias=<self>, status="idle", resume_id=<session id>)`
   first to create the row (worker nodes usually get this from `anet node create` + the runtime).
2. **Receive**: `get_inbox(alias=<self>)` for pending work; a task message's handle is the
   `message_id` in the response (which is the `task_id`). **One task at a time** — a node has one
   session slot (§7, Gotchas).
3. **Read the pointer** (local, not a commhub call): a dispatched body is normally
   `file: … seg: seg-NN sha12: …` (§1.2). `git pull`, locate the segment, and verify it:
   run `bash scripts/anet_payload.sh verify --file <path> --seg seg-NN --sha12 <sha12>`. A mismatch, a missing
   segment, or a missing file is a **conflict to report**, not a licence to guess: take the task,
   start it, and state the conflict in `result`.
4. **Acknowledge** (own round): `ack_inbox(alias=<self>, message_id=<task_id>)` per task, optionally
   with `response` ("received, starting"). This step alone drives `delivered → acked`.
5. **Start** (own round): `report_status(alias=<self>, status="working", task=<the task body>)` —
   `task` **must be character-for-character identical** to the body (matching is exact-equality on
   the body only, **there is no task_id branch**), otherwise the task stays in acked. Copy the body
   out of the `get_inbox` / `get_task` response; never retype it, never "tidy" it. This is the step
   that a short body makes reliable (§1.2) and that a manual node must do by hand (§7.1).
6. **Report**: **exactly once** per task, in its own round,
   `report_completion(alias=<self>, task=<task_id is safest; the raw body must match character-for-character if used>,
   result=<summary: conclusion / changes / how you verified — the task row keeps only the first 4000
   characters>, artifacts=[<URL or file path>])`. You may also pass `score` (self-assessed 0-10).
   `result` is ≤400 characters: conclusion, how it was verified, and the path of the long report —
   the long report goes in the file (in the segment's 产出 section), not in the parameter.
   Merging several tasks into one report = none of them take effect.
7. **Finish**: `report_status(alias=<self>, status="idle", task=null)` (a completion also sets the
   session to idle).
8. **Stuck? Fix it**: see §3 and Gotchas — **don't re-send** (the dedupe layer rejects it), and don't
   change status without reporting.

**Worker discipline**:

- Report after the work is done, not before; every verification you claim in `result` must have
  actually been run.
- One completion per task; never merge several tasks into one report.
- One commhub call per round (§1.1); a `get_inbox` + `ack_inbox` + `report_status` fired in one turn
  is the fastest way to lose track of which transition the hub accepted.
- Verify the payload file (path + segment + sha12) before working; report a mismatch instead of
  working on the wrong revision.
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

- **One commhub call per round** (§1.1). A turn that fires several commhub calls leaves you with no
  way to tell which transition the hub accepted, and a batch of `report_completion` calls on one node
  overwrites the single session slot. Local calls (files, git, bash) are unlimited.
- **Keep the body short** (§1.2, ≤300 characters). The body is echoed back byte-for-byte by the
  worker in `report_status`, so every paragraph you paste into the parameter multiplies the chance of
  a drift that stalls the task in `acked`. Long text goes in a payload file; the parameter carries
  `file:` + `seg:` + `sha12:`.
- `report_completion(task=…)`: matching: **`task_id` first; on a miss, `to_name=alias AND
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
- **No absolute paths**: a parameter must not carry a path a second machine cannot open — any token
  starting with `/` (POSIX absolute), `~/`, a drive path `X:\` or `X:/`, or a UNC share
  `\\host\share`. `scripts/anet_payload.sh guard --body "…"` names them by shape, so the rule does
  not depend on any one machine's mount prefix. Don't copy paths out of `get_all_status`'s
  `project_dir` either (that is a stale reported value that dies the moment the machine changes).
  Point at locations as "in your working directory" plus a relative path (e.g. `src/game.js`).
- **No cross-directory assumptions**: never read files in "the other side's directory" to judge their
  progress or result.
- **Delivery has exactly two routes**: git push/pull, or a hub attachment — `POST /api/upload` to get
  a `file_id`, then put it in `report_completion` / `send_task` as
  `meta.attachments: [{type:"file", file_id}]` (when a `file_id` is present the hub strips `path`,
  precisely for cross-machine safety).
- **A payload file travels the same two routes** (§1.2): commit it and **push the branch before
  dispatch** (the worker pulls, then runs `bash scripts/anet_payload.sh verify`), or upload it and
  name the `file_id` plus the sha12 on the pointer line. A payload file that only exists on the
  dispatcher's disk is worse than no file: the worker cannot read it, and an absolute path to it is
  forbidden anyway.
- **Attachment limits are hard numbers, not hints** (§1.2): `type` must be `"file"` with a
  server-generated `file_id`, **≤ 20 attachments per task**, **≤ 12 MiB per file**, **60 uploads per
  hour per token** (429 `rate_limited`); a malformed entry is refused at dispatch (`bad_attachments`)
  and the hub strips any `path` next to a `file_id`. Download rights are **network-scoped**, and a
  denied read answers **404, never 403**. A runtime node pulls attachments itself
  (`agent-node/src/runtime/fetch-attachment.ts`); a manual node uses
  `anet_manual_node.sh files` + `fetch` (§7).
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

**One network per project.** The unit that separates projects on a hub is the network, not the
directory, and every identity rule is network-scoped: alias uniqueness
(`resolveNodeIdForAlias(nodes WHERE alias AND network_id)`, `canonicalAliasExists(networkId, alias)`),
`clone_node` → `alias_taken`, `createNetworkTokenForNode` → `cross_network_node` / `node_owner_mismatch`.
Consequences that are easy to get wrong:

- **Node aliases carry machine + project** (`200-pix-auto-video-manual-doubao`). Two projects that
  share a network and reuse a name collide, and the second registration is refused.
- **A user token has no implicit network.** Every REST read names one: `?network_id=<id>` on
  `/api/messages`, `/api/tasks`, `/api/status`; the hub answers `"network_id required (utok has no
  implicit network; pass ?network_id=<id>)"` when you forget. The CLI takes `--network`.
- **The manager's channels are per network**: `inbox(session_name=<username>, network_id=…)` for
  replies to tasks you dispatched, and one `user_inbox` (`?scope=user`) per network. Unread rows
  accumulate per network and never expire on their own — ack them (production measured 354 unacked
  rows in one network).
- **Keeping projects in one shared network is a visibility decision, not a convenience.** A network
  with `agent_access: all` lets every worker in it see and message every other worker, and task
  timelines are shared; if project A's prompts, artifacts and paths must not be visible to project
  B's workers, that is a separate network.

## 6. Requirement pool mode (hub ≥ 0.9.0-preview.67)

"Public" tasks that name no worker use the requirement-pool tools (`requirements_*`) and need hub
version **≥ 0.9.0-preview.67** (on 0.9.0-preview.64/65/66 node tokens could not use this tool set):

- Publish: `requirements_create(name=..., description=..., column="pool")` (omit `agent_owner` to make
  it public).
- Claim: a worker calls `requirements_update(id=..., column="doing",
  agent_owner={kind:"node", alias=<self>})`.
- Collaborate: `requirements_comment` for progress; `requirements_checklist_toggle` to tick one item
  (it writes only that item and never overwrites anyone else's edit).
- Query: `requirements_list(q=…, tag=…, status=…)`, `requirements_get(id or "#N")`.

The same two rules apply here: one `requirements_*` call per round (§1.1), and a short
`name` / `description` that points at a payload file plus its segment (§1.2) instead of a pasted
requirement document.

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
./anet_manual_node.sh dm <username> "..." --node <alias> --project-root <dir>   # reply to a HUMAN
./anet_manual_node.sh files <task_id> --node <alias> --project-root <dir>        # the task's attachments
./anet_manual_node.sh fetch <file_id> --out spec.md --sha12 <12 hex> --node <alias> --project-root <dir>
```

Read `references/manual-node.md` for the full command set, the token rules, the failure modes, and
why the task body is fetched from the hub instead of retyped. Read `references/ttl-and-expiry.md` (including the rule
`ttl_seconds >= 2 x node idle budget`, and the pi failure codes that are safe to quote
verbatim in acceptance)
for how long a dispatched task actually lives.

One of those failure modes is worth knowing here: the dashboard decides online/offline from the
hub's **SSE session** for `<network_id>:<alias>`, not from the heartbeat, so `start` also opens
`GET /events/<alias>` with the node's own `ntok_` token. A heartbeat alone leaves the card reading
**offline** while the hub's `/api/status` says `working`. `ANET_MANUAL_SSE=0` closes the stream (the
log then says so, and the card resumes reading offline).

### 7.0 Who the manager is, and where each message must go

**The manager is a user, not a node, and that is the normal shape — not a workaround.**
Dispatch is done with a user token, so every task row carries `from_name = <username>`
(production `net_b91c0d535346`: 200 most recent tasks, `from_name` is `admin` in 200 of them).
A manager account needs no node: `report_status` — the heartbeat that makes a node exist —
**refuses user tokens** (`tools.ts` `network_token_required`), so there is nothing for a human
account to run, and a human account has no `sessions` row to be dispatched to.

One manager can drive any number of projects. The unit that separates projects is the
**network**, not the directory: alias uniqueness is checked per network
(`resolveNodeIdForAlias(nodes WHERE alias AND network_id)`, `canonicalAliasExists(networkId, alias)`,
`clone_node` → `alias_taken`, `createNetworkTokenForNode` → `cross_network_node` / `node_owner_mismatch`).
So the convention is **one network per project**, and a node alias carries machine + project
(`200-pix-auto-video-manual-doubao`). The manager's own channels are per network: a user token has
no implicit network, so every read names one (`GET /api/messages?alias=admin&network_id=…`, and
the hub answers `"network_id required (utok has no implicit network; pass ?network_id=<id>)"`).

**Which channel to use, and where the message lands.** "Visible" below means *visible in the
Dashboard*: the Tasks page reads `tasks` (with a `completions` fallback), the Messages page reads
`inbox` via `?alias=<alias>`, and the inbox page `/messages/inbox` reads `user_inbox` via
`?scope=user`. All three were measured on a throwaway hub (`evals/golden/case-9/10/11`), not
inferred — the two reply tools land in **different** tables, and that is the single most common
source of "我发了，Dash 上看不见".

| you want to | use | lands in | Dashboard sees it? |
|---|---|---|---|
| hand over the finished work | `reply <task_id> … --via send_reply` | `inbox(session_name=<派单人用户名>)` + `tasks.result` | **yes** — Messages 页（case-11） |
| finish and close the task only | `reply <task_id> …` (default = `report_completion`) | `completions` + `tasks.result` | Tasks 页只此一处 — Messages 页与收件箱都**看不见**，人也没有未读（case-10） |
| ask the human a question mid-task | `state blocked` + `dm <username>` | `user_inbox(kind=agent_message)` | **yes** — `/messages/inbox`（case-9） |
| chat with another node | `say <alias>` | `inbox(session_name=<node alias>)` | yes — Messages 页 |
| chat with a human | `dm <username>` | `user_inbox` | yes — `/messages/inbox` |

> **`dm` is the only channel that reaches a person's unread count; `report_completion` is the only
> one that is invisible outside the Tasks page.** Both facts are the reason a control room can sit
> for hours on a question nobody answered: `report_completion` writes no inbox row for the
> dispatcher and no user_inbox row, so nothing anywhere shows the person that an answer arrived.
> Use `--via send_reply` when the answer must be seen in the message stream, `dm` when a person
> has to be *notified*.

**`send_reply` is terminal.** It closes the task to `replied`, and `replied` is not in the set
`retry_task` accepts (`failed` / `expired` / `cancelled`) — so asking a question as a reply ends
the round, and the next round is a **new task**. Ask mid-task with `state blocked` + `dm` and keep
the task `running`; answer with `reply` when the answer *is* the deliverable.

A dashboard card that labels a manual node with the login username ("admin") is a **frontend
fallback**, not a hub identity: `GET /api/status?alias=admin` returns no rows, `GET /api/nodes?alias=admin`
returns `count: 0`, and every `nodes.owner_user_id` is null. Do not dispatch to that label; dispatch
to the node's real alias.

### 7.1 Two kinds of inbox row: tasks and chat

`get_inbox` returns **inbox rows**, and there are two kinds, and they need different tools:

| row | what it is | how you answer it |
|---|---|---|
| `type: "task"` | dispatched work, has a `task_id` | `working <task_id>` → do the work → `reply <task_id>` |
| `type: "message"` | chat, **no task id** | `dm <username> "<text>"` — nothing to ack, no task to close |

**Chat rows cannot be answered with `reply` or `send_reply`.** Both resolve the id against the
`tasks` table, so a message id comes back as `task not found` / `reply_task_not_found`. A chat
row is not work — it has no lifecycle, so there is nothing to ack and nothing to close.

**A human is not a node.** `say <alias>` (which is `send_message`) only reaches **nodes**,
because it needs a `sessions` row; a human user has none, so it answers `alias_not_found`.
Use `dm <username> "<text>"` for a human — it goes to that user's inbox as an agent message
(and it says so when there is no live subscriber, which is normal: the message waits in the
user's inbox).

`inbox` and `check` both label every row, so a finished task is never mistaken for work: the
hub keeps a closed task's inbox row until it is acked, and a chat row was never a task at all.

### 7.2 The one step you must not skip: `working`

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

### 7.3 What the hub should look like once you start

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

- **Dispatching without `ttl_seconds` promises one hour.** `send_task` defaults to
  `ttl_seconds = 3600` (max 86400), and `retry_task` re-arms only `+1 hour` — so long work
  needs the TTL written explicitly, and a retried long job is really a new task. Expired
  tasks notify into `user_inbox` (`/messages/inbox`), never into the message stream.
  See `references/ttl-and-expiry.md`.
- **`report_completion` creates nothing a person can see as a message.** It writes
  `completions` + `tasks.result` only — the Messages page and the inbox page both stay empty,
  and the dispatcher gets no unread badge. That is the usual cause of "我发了，Dash 上看不见".
  Use `--via send_reply` when the text must be read, `dm` when a person must be notified.


### 7.4 One command per round; the body you receive is a pointer

Each command in §7 moves **one transition**, so one command is one round (§1.1). `working` and
`reply` read the hub around that transition (fetch the stored body, prove the status landed) — that
is part of the same round, not extra calls. What is banned is chaining transitions: `inbox && ack &&
working && reply` on one shell line is four transitions in one round — the node's single session slot
gets overwritten, and if one of them fails you have four responses and no idea which transition the
hub took. Run one command, read its verdict, run the next in the next round.

The dispatched body is normally a 4-line pointer (`file:` / `seg:` / `sha12:`, §1.2). `working`
fetches that body from the hub (never retype it), and the human works the **file**: run
`bash scripts/anet_payload.sh verify --file … --seg … --sha12 …` first; a non-zero exit (missing
file, missing segment, sha12 mismatch) is a **conflict to report in `reply`**, not a licence to work
on the revision you happen to have. `reply` carries a ≤400-character `result` — conclusion, what you
ran to verify it, and the path of the long report, which goes into the segment and gets committed.

## Gotchas

- **Planner**: one commhub call per round (§1.1) — stop after dispatching, no waiting, no polling, no
  second task in the same turn; ask first when a task is vague.
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
  curl from §0.2 will tell you; with no token, **no** tool on `/mcp` is callable. Read
  `references/token-operations.md` before issuing, expiring, or revoking tokens (revocation is a hard
  delete, and "whose token is this" is only answerable from login metadata).
- **Don't dispatch via the `anet` CLI**: `anet` has no `send_task` / `get_inbox` / `report_*`
  commands — the protocol lives on MCP only (§0.3).
- **A node card shows task text that reads like half a sentence / carries stray newlines**: the hub is
  not broken — `sessions.task` keeps the first 200 characters and cuts **blindly** (no
  sentence/newline awareness). Put a one-line summary on line 1 when dispatching (§1, "First line is
  a one-line summary"); the body is always intact in `get_inbox` / `get_task`.
- **You fired several commhub calls in one round**: the symptoms are a session row whose task preview
  is the wrong task, a `duplicate_send` from the dedupe window, a report that lands on a task you did
  not mean, and no idea which of the calls did it. There is no undo — read the hub state
  (`get_task`, one call, one round), then continue strictly one call per round (§1.1). The script
  commands of §7 are exempt from that count only for the reads that make their single transition
  provable (§1.1, "What is not a second round").
- **The `task` parameter is a wall of text** (a pasted spec, a code block, a 2000-character brief):
  the node card is truncated, the worker's byte-exact echo of it drifts, the task dies in `acked`,
  and both sides pay for it in output tokens twice per round. Fix: move the text into a payload file,
  split it into `## seg-NN`, dispatch a 4-line pointer built by `bash scripts/anet_payload.sh compose`,
  and repair the stalled task with `cancel_task` + `retry_task` (§3).
- **The pointer names a file the worker cannot open**: the file was untracked, uncommitted, unpushed,
  or the segment sha12 does not match. `bash scripts/anet_payload.sh compose` refuses to build such a body, and
  `verify` refuses to work from it; the worker reports the conflict in `result` (never works on a
  guess). Push the branch, or ship it as a hub attachment with its `file_id` (§4).
