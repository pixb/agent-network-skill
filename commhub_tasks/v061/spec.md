# agent-network-skill — v0.6.1 follow-up spec (post-merge precision round)

Target: the agent-network-skill repository itself (this skill's own repo). Everything below is
**portable**: no host-project paths, no runtime-specific knobs in rule text (runtime specifics are
allowed only inside a line labeled `example:`), no project vocabulary. Acceptance is always the
skill's own gates: `python3 scripts/run_evals.py`, `validate.py`, `security_scan.py`,
`skill_graph.py run`, plus `python3 scripts/run_pipeline.py` on a machine that has the hub source.

Ground rules for whoever takes a segment (SKILL.md §1.1, §1.2):

- One commhub call per round. The commhub calls are the scarce resource; reading and writing files,
  git, and running the gate scripts are free.
- Verify this file before working: `bash scripts/anet_payload.sh verify --file commhub_tasks/v061/
  spec.md --seg seg-NN --sha12 <the sha12 in your task body>`. A mismatch is a conflict to report,
  not a licence to guess.
- Do not renumber existing golden cases; append the next free id.
- Do not delete content that already exists in `SKILL.md` §7.0–§7.3 or in `references/` — cite it.
- Bump `metadata.version` / `provenance.version` **once per accepted batch** (not per segment), and
  regenerate `VERIFICATION.md` + `skill.graph.json` hashes last.

## seg-01 Make the worker flow carry the message-visibility fact

**Problem.** `SKILL.md` §2 (Role B: worker) never mentions that `report_completion` is invisible to a
human. The fact exists only in §7.0 (manual nodes) and in `AGENTS.md` triggers. A runtime worker
following §2 step 6 reports with `report_completion` and the operator's Dashboard shows nothing — the
documented incident "我发了，Dash 上看不见". §7 is not on a runtime worker's reading path.

**Do.**

1. In §2 step 6 (Report), add a short cross-reference block (4–6 lines, no new tables) stating:
   - `report_completion` writes `completions` + `tasks.result` only — no `inbox` row for the
     dispatcher, no `user_inbox` row, no unread badge for a person;
   - when the result text must be **read** by the dispatcher, use `send_reply`
     (`reply … --via send_reply` on a manual node), knowing it is **terminal** (`replied`, not
     retryable);
   - when a **person** must be notified mid-task (a question), use `state blocked` + `dm` and keep
     the task `running`;
   - cite §7.0 for the channel table; do not duplicate the table.
2. Add one bullet to **Worker discipline**: reporting the deliverable and notifying a person are
   different calls; choosing the wrong one strands the round.
3. Keep the wording runtime-neutral: it must read the same for a codex/opencode/pi/claude worker.

**Acceptance.**

- `SKILL.md` §2 contains the visibility fact and the `send_reply`-is-terminal caveat, with a pointer
  to §7.0 and no duplicated table.
- `validate.py` VALID, `skill_graph.py run` OK, `python3 scripts/run_evals.py` all green (no golden
  case changes required).
- A reader of §2 alone can decide which of `report_completion` / `send_reply` / `dm` to call.

## seg-02 Rewrite the TTL rule so it bites the incident it cites

**Problem.** The rule is `ttl_seconds ≥ 2 × node idle budget`. With a runtime whose idle budget is
1800 s the rule yields 3600 s — the hub default. The measured failures in `references/ttl-and-expiry.md`
are tasks dispatched with `ttl_seconds = 7200` expiring at the deadline, i.e. longer than 2 × idle.
The rule as written therefore authorises the default value that the same file calls the main cause.

**Do.**

1. Restate the rule in `references/ttl-and-expiry.md` and in the §7 pointer as a two-term maximum:

   ```
   ttl_seconds >= max( 2 * idle_budget_seconds,
                       2 * worst_case_task_seconds )
   worst_case_task_seconds = queue + context compaction + the work itself
   floor: ttl_seconds <= 86400 (send_task cap) — at the cap, split the task; do not extend it
   ```

2. Say explicitly: `2 × idle_budget` is a **floor**, not the answer; and reaching 86400 is a signal
   to split the deliverable, not to raise the TTL.
3. Keep the runtime-specific numbers as labeled examples only, e.g.
   `example (pi runtime): idle=1800s, one context compaction measured 7–9 min (8GB GPU, 131K ctx)` —
   keep them out of the rule line.
4. Keep the "node busy / compacting is not a failure, do not retry" paragraph (it is correct), and
   cite the hub-side read that proves TTL defaults bite:
   `GET /api/tasks?network_id=<id>&limit=200` → median TTL of `expired` rows sitting on 3600.

**Acceptance.**

- The rule text contains the `max(2 × idle, 2 × worst-case)` form, the floor label, and the split
  instruction at 86400.
- No runtime name is required to apply the rule; runtime specifics appear only on lines prefixed
  `example:`.
- `validate.py` VALID; `python3 scripts/run_evals.py` green.

## seg-03 Soften the network-scope claim to what the hub actually does

**Problem.** §7.0 says a user token has no implicit network and "every read names one", quoting a hub
error string. Measured on hub `0.9.0-preview.265` (2026-11-08, read-only):
`GET /api/messages?alias=<user>&since=…` and `GET /api/tasks?limit=5` both answer `ok:true` with **no**
`network_id`. The absolute claim is not reproducible and misleads a reader who is diagnosing.

**Do.**

1. In §7.0 and in `references/manual-node.md`, replace "every read names one" with a measured form:
   name the endpoints that **do** require `network_id` (writes and node-scoped reads), and state that
   some user-scope reads resolve the scope from the alias. Keep the "name it explicitly" habit as a
   convention (it is the safe habit), not as a hub behaviour claim.
2. Add the 3-line read-only self-check block (curl) that proves each claim, so a future reader
   measures instead of trusting prose: `alias` messages with and without `network_id`, `/api/status`,
   `/api/nodes?alias=`.
3. Label every quoted hub version in these measurement notes (the habit the skill already uses:
   `measured on 0.9.0-preview.265`).

**Acceptance.**

- No absolute "every read" claim remains; the convention and the hub behaviour are stated separately.
- The self-check block runs as written from a clean shell and prints the rows it describes.
- `validate.py` VALID; `python3 scripts/run_evals.py` green.

## seg-04 Give the presence stream a behavioural eval

**Problem.** `scripts/anet_manual_node.sh` gained ~158 lines of SSE presence logic (`GET /events/<alias>`
with the node token, `X-Anet-Instance-Id`, reconnect backoff, `node_connection_superseded` backoff,
`ANET_MANUAL_SSE=0`), and the skill's whole thesis is behavioural evaluation. `grep -rn "sse\|presence"
tests/ evals/` finds nothing. The dashboard's online dot comes from `sse_sessions` in `/health`, not
from the heartbeat, so this is exactly the code that silently changes what the control room sees.

**Do.**

1. Add scenario `presence-stream-visible` in `tests/manual_node_scenario.sh` and golden
   `case-13` (next free id — 9/10/11/12 are taken):
   - after `start`, `GET /health` shows `sse_sessions["<network_id>:<alias>"] >= 1`;
   - after `stop`, the key is 0 or absent;
   - with `ANET_MANUAL_SSE=0`, `start` still heartbeats, the log names the consequence (dashboard
     shows offline), and `/health` reports 0 for the alias;
   - record transitions of the primary task only (follow `record_other` convention).
2. Register the case in `evals/agent-network-skill.eval.md` (table row + golden entry) and keep the
   global criteria untouched.
3. Document the new case in `evals/*.eval.md` prose, consistent with existing rows.

**Acceptance.**

- `python3 scripts/run_evals.py --validate` VALID, `python3 scripts/run_evals.py` green.
- On a machine with the hub source: `python3 scripts/run_pipeline.py` PASS for the new scenario, and
  its `expected.json` baseline is the observed run (not hand-written).
- `skill_graph.py run` OK after refreshing `skill.graph.json`.

## seg-05 Repository hygiene: a red evolution gate, body size, evidence dir

**Do.**

1. `scripts/evolve.py` step 1 runs `scripts/staleness_check.py`, which is not in the repository, so
   `evolve.py` reports FAILED on every run. Either ship a minimal `staleness_check.py` implementing
   `--check-deps --check-drift --record`, or drop the step from the chain and say so in the header
   docstring and in `README.md` ("Verifying the skill"). Pick one; do not leave a permanently red
   gate.
2. `SKILL.md` body is 654 lines (`validate.py` warns above 500). Move narrative detail — not rules —
   from §7 into `references/manual-node.md` (it already duplicates that content) until the warning
   clears. Do not delete a rule, a table row, or a measured fact; the rule text stays in `SKILL.md`.
3. Add `raw/` to `.gitignore` (the wiki `capture` evidence copies are local run evidence) and record
   one `wiki_maintenance.py record-impact` entry per accepted batch, so the ledger credits the
   authors of the conventions it documents.

**Acceptance.**

- `python3 scripts/evolve.py` exits 0, or the chain documents why the step is gone.
- `validate.py` reports no line-count warning.
- `git status` clean after a `wiki_maintenance.py capture` + `record-impact` run.
- `python3 scripts/run_evals.py` green, `security_scan.py` CLEAN, `skill_graph.py run` OK.
