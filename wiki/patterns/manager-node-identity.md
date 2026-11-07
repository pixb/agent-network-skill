# The manager is a user, not a node

Status: draft — not executable guidance.
Applied: accepted — shipped in v0.6.0. (The draft marker is the wiki lifecycle state, not a claim that the rule is unverified.)


## Finding

Dispatch runs with a user token, so task rows carry from_name=<username>; report_status refuses user tokens (network_token_required) and a human account has no sessions row, so a manager account needs no node. Three message channels land in three places: dm lands in the manager's user inbox, send_reply lands in the alias messages the Messages page reads, and report_completion writes only completions + tasks.result (no badge, nothing a person can see). A mid-task question must not be written as a reply. Dashboard online/offline comes from the SSE presence stream, not the heartbeat.

## Evidence

- `raw/2026-11-07T192707Z-66718fafa7e2.json` — records one step only: "validate the eval spec". Not behavioural evidence; the ledger line written from it carries the operator-supplied `--validation-score`.
- `raw/2026-11-07T201812Z-bca66563c29c.json`, `raw/2026-11-07T201902Z-f26e338e0150.log` — the 12 golden scenarios against throwaway hubs, 60 checks passed, 0 failed (the channel-landing facts of this pattern are asserted by cases 9, 10 and 11).

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
