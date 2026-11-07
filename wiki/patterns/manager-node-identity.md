# The manager is a user, not a node

Status: draft — not executable guidance.

## Finding

Dispatch runs with a user token, so task rows carry from_name=<username>; report_status refuses user tokens (network_token_required) and a human account has no sessions row, so a manager account needs no node. Three message channels land in three places: dm lands in the manager's user inbox, send_reply lands in the alias messages the Messages page reads, and report_completion writes only completions + tasks.result (no badge, nothing a person can see). A mid-task question must not be written as a reply. Dashboard online/offline comes from the SSE presence stream, not the heartbeat.

## Evidence

- `raw/2026-11-07T192707Z-66718fafa7e2.json`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
