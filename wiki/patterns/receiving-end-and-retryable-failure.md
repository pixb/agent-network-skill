# A protocol is undirected if only one end names its move

Status: draft — not executable guidance.

## Finding

An external audit found three gaps that all had the same shape: the planner named only the sending side (send_task, get_task, get_completions) while the protocol's delivery lands in inbox(session_name=<dispatcher>) — a user token can read its own inbox (server/src/inbox-caller.ts:38), so the reading step is available and was simply never named; the worker had no failure path (report_completion always writes replied, tools.ts:1593/:1606, and retry_task accepts only failed/expired/cancelled, tools.ts:3038), so a failure reported as a completion is unretryable and counted as an arrival; and the channel facts were maintained in three places, which is how a retired claim (dm has no Dashboard page) survived next to the measured one (/messages/inbox reads it, case-9). Measured cost of the first gap: a mid-task question nobody reads keeps the task running with no warning (task-lifecycle-watcher.ts emits only delivered_stale_30s/_60s) until the TTL sweep ends the round. Fix shape: name the receiving step with its citation, name the retryable failure path with its citations, keep one table as the single source and add a text gate that refuses the retired wording.

## Evidence

- `raw/2026-11-09T035116Z-aaf50f0b5965.log.json`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
