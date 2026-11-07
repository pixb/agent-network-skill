# Long commhub parameters and batched calls stall the protocol

Status: draft — not executable guidance.
Applied: accepted — shipped in v0.6.0, clauses corrected in v0.6.1. (The draft marker is the wiki lifecycle state, not a claim that the rule is unverified.)


## Finding

Dispatched bodies that carry the whole spec break three hub facts at once: sessions.task keeps only the first 200 chars (blind cut), report_status(status=working) matches the body byte-for-byte (a long body drifts, the task rots in acked), and a batch of commhub calls in one turn overwrites the node's single session slot and leaves the operator unable to tell which transition landed. Fix: one commhub call per round, plus a 4-line pointer body (file + seg + sha12) with the long text in a payload-file segment.

Two clauses v0.6.0 stated too far, and v0.6.1 states exactly:

- **A round counts transitions, not shell characters.** A script command that performs one transition
  reads the hub around it (`anet_manual_node.sh working` fetches the stored body so the echo is
  byte-exact, acks a delivered task, sends report_status, re-reads to prove running). Counting that as
  four calls makes the rule contradict the tool the skill ships.
- **report_completion is not "once per task" as the hub enforces it.** The task-row update needs
  status IN ('delivered','acked','running'), so a second report on the same task changes no task row
  while it appends another completions row; and three reports naming three task_ids all land. What
  lands on nothing is one report whose task= string merges several tasks.

## Evidence

- `raw/2026-11-07T192707Z-66718fafa7e2.json` — records one step only: "validate the eval spec". It proves the spec is well-formed; it is not behavioural evidence, and the ledger line written from it is the operator-supplied `--validation-score`, not a measured score.
- `raw/2026-11-07T201812Z-bca66563c29c.json` — pipeline report: spec validation + all 12 golden scenarios against throwaway hubs, exit 0
- `raw/2026-11-07T201902Z-f26e338e0150.log` — the same run narrated: `rollout: 60 passed, 0 failed, 0 errored, 0 regressed`, `RESULT: PASS`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
